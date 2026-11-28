class_name MazeMap
extends Node2D

## 房间 + 走廊网格地图。只回答「哪里能走、怎么绕、画成什么样」，
## 不持有玩家/敌人引用，也不反向 get_parent()。
##
## 墙为什么不是 StaticBody2D：player.gd:319 与 enemy.gd:412 都直接改
## global_position，物理碰撞体对它们完全无效。所以墙是网格数据，由调用方
## 在位移末尾用 constrain(from, to) 夹一次；敌人绕路靠 rebuild_flow()
## 从玩家所在格做一次 BFS 得到的方向场，而不是给上百只怪各跑一次寻路。
##
## 坐标：地图中心 = 世界原点；格 (0,0) 的中心见 cell_center()。

## 建图完成时发出。P2 的任务布点、P3 的换图都监听它，而不是反向查 Game。
signal map_built(seed_value: int, room_count: int)

const CELL: float = 96.0
const GRID_W: int = 24
const GRID_H: int = 18
const WALL: int = 0
const FLOOR: int = 1
const NO_FLOW: int = 255
const FLOW_HERE: int = 8

const ROOM_MIN: int = 3
const ROOM_MAX: int = 5
const ROOM_TRIES: int = 60
const ROOM_TARGET: int = 9

## 8 邻方向。flow 里存的是「往玩家走该选哪个下标」。
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]
## 连通性判定只用 4 邻。流场用 8 邻是为了让敌人斜着抄近路，
## 但"玩家能不能走过去"是另一回事：身体有半径，斜穿墙角实际过不去。
## 用 8 邻做连通性检测会把"只能斜着过"的死角判成通路，等于自欺欺人。
const CARDINALS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]
const OPPOSITE: Array[int] = [1, 0, 3, 2, 7, 6, 5, 4]
const CORNERS: Array[Vector2] = [
	Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1),
]
const WALL_COLOR: Color = Color(0.26, 0.29, 0.37)
const FLOOR_COLOR: Color = Color(0.085, 0.10, 0.13)

var _cells: PackedByteArray = PackedByteArray()
var _flow: PackedByteArray = PackedByteArray()
var _rooms: Array[Rect2i] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _flow_origin: Vector2i = Vector2i(-999, -999)
var _start_cell: Vector2i = Vector2i.ZERO
var _boss_cell: Vector2i = Vector2i.ZERO
## 商人密室。离起点第二远的那间——最远的留给 Boss，第二远的位置
## 既有"要专门跑一趟"的分量，又不会和 Boss 房挤在同一头。
var _shop_cell: Vector2i = Vector2i.ZERO


func _ready() -> void:
	z_index = -1
	z_as_relative = false


## 生成一张新图。同一 seed 必须逐格可复现（台架靠这个做 A/B）。
func build(seed_value: int) -> void:
	_rng.seed = seed_value
	_cells.resize(GRID_W * GRID_H)
	_cells.fill(WALL)
	_flow.resize(GRID_W * GRID_H)
	_flow.fill(NO_FLOW)
	_rooms.clear()
	for i in range(ROOM_TRIES):
		if _rooms.size() >= ROOM_TARGET:
			break
		var w: int = _rng.randi_range(ROOM_MIN, ROOM_MAX)
		var h: int = _rng.randi_range(ROOM_MIN, ROOM_MAX)
		var x: int = _rng.randi_range(1, GRID_W - w - 2)
		var y: int = _rng.randi_range(1, GRID_H - h - 2)
		var room := Rect2i(x, y, w, h)
		if _overlaps_any(room):
			continue
		_rooms.append(room)
		_carve_rect(room)
	for i in range(1, _rooms.size()):
		_carve_corridor(_center_of(_rooms[i - 1]), _center_of(_rooms[i]))
	_start_cell = _center_of(_rooms[0])
	_boss_cell = _farthest_room_center(_start_cell)
	_shop_cell = _second_farthest_room_center(_start_cell, _boss_cell)
	# 连通性硬保证放在最后：房间、走廊、密室都挖完了才算得准。
	# 这条不是"应该不会有问题"，是"只要有一次孤岛，那一局就有一个房间永远进不去"。
	_ensure_connected()
	_flow_origin = Vector2i(-999, -999)
	queue_redraw()
	map_built.emit(seed_value, _rooms.size())


func _overlaps_any(room: Rect2i) -> bool:
	var padded := Rect2i(room.position - Vector2i(1, 1), room.size + Vector2i(2, 2))
	for other in _rooms:
		if padded.intersects(other):
			return true
	return false


func _center_of(r: Rect2i) -> Vector2i:
	return Vector2i(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2)


func _carve_rect(r: Rect2i) -> void:
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			_cells[y * GRID_W + x] = FLOOR


func _carve_corridor(a: Vector2i, b: Vector2i) -> void:
	if _rng.randf() < 0.5:
		_carve_line_h(a.x, b.x, a.y)
		_carve_line_v(a.y, b.y, b.x)
	else:
		_carve_line_v(a.y, b.y, a.x)
		_carve_line_h(a.x, b.x, b.y)


func _carve_line_h(x0: int, x1: int, y: int) -> void:
	for x in range(mini(x0, x1), maxi(x0, x1) + 1):
		_cells[y * GRID_W + x] = FLOOR


func _carve_line_v(y0: int, y1: int, x: int) -> void:
	for y in range(mini(y0, y1), maxi(y0, y1) + 1):
		_cells[y * GRID_W + x] = FLOOR


func _farthest_room_center(from: Vector2i) -> Vector2i:
	var best: Vector2i = from
	var best_d: int = -1
	for r in _rooms:
		var c: Vector2i = _center_of(r)
		var d: int = absi(c.x - from.x) + absi(c.y - from.y)
		if d > best_d:
			best_d = d
			best = c
	return best


## 排除 boss 房之后离起点最远的那间。房间不足 3 个时退回起点，
## 那样商人会站在出生点——难看，但总比没有商人好。
func _second_farthest_room_center(from: Vector2i, boss: Vector2i) -> Vector2i:
	var best: Vector2i = from
	var best_d: int = -1
	for r in _rooms:
		var c: Vector2i = _center_of(r)
		if c == boss or c == from:
			continue
		var d: int = absi(c.x - from.x) + absi(c.y - from.y)
		if d > best_d:
			best_d = d
			best = c
	return best


## 从起点做一次 4 邻洪水填充，返回「哪些格可达」。
## 用 PackedByteArray 而不是 Array[bool]：432 格的分配在换图时发生，
## 每局都要跑一次，没必要为布尔值付装箱开销。
func _flood_from(start: Vector2i) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(_cells.size())
	seen.fill(0)
	if not is_walkable_cell(start):
		return seen
	var queue: Array[Vector2i] = [start]
	seen[_idx(start)] = 1
	var head: int = 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in CARDINALS:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= GRID_W or n.y >= GRID_H:
				continue
			if seen[_idx(n)] == 1 or not is_walkable_cell(n):
				continue
			seen[_idx(n)] = 1
			queue.append(n)
	return seen


## 找离 c 最近的可达格。扫描全图而不是试着往外扩：
## 432 格的扫描只在真的有孤岛时才发生，而孤岛本身是异常情况，不值得优化。
func _nearest_reached(c: Vector2i, reached: PackedByteArray) -> Vector2i:
	var best: Vector2i = c
	var best_d: int = 1 << 30
	for i in range(_cells.size()):
		if reached[i] != 1:
			continue
		var p := Vector2i(i % GRID_W, i / GRID_W)
		var d: int = absi(p.x - c.x) + absi(p.y - c.y)
		if d < best_d:
			best_d = d
			best = p
	return best


## 把每一块孤岛接到最近的连通格上，直到全图连通。
## 走廊是 L 形硬挖的，理论上永远不会断开；但"理论上"这三个字已经在这项目里
## 出过太多次事（毒圈预算、Boss 预算都栽在"理论上"上）。多花一次 432 格的
## 洪水填充，换"任何 seed 都不会出现进不去的房间"。
func _ensure_connected() -> void:
	for guard in range(64):
		var reached: PackedByteArray = _flood_from(_start_cell)
		var stray: Vector2i = Vector2i(-1, -1)
		for i in range(_cells.size()):
			if _cells[i] == FLOOR and reached[i] == 0:
				stray = Vector2i(i % GRID_W, i / GRID_W)
				break
		if stray.x < 0:
			return
		var anchor: Vector2i = _nearest_reached(stray, reached)
		if anchor == stray:
			return
		_carve_corridor(anchor, stray)


func _idx(c: Vector2i) -> int:
	return c.y * GRID_W + c.x


func is_walkable_cell(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= GRID_W or c.y >= GRID_H:
		return false
	return _cells[_idx(c)] == FLOOR


func world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(
		int(floorf(p.x / CELL)) + GRID_W / 2,
		int(floorf(p.y / CELL)) + GRID_H / 2)


func cell_center(c: Vector2i) -> Vector2:
	return Vector2(
		(float(c.x) - float(GRID_W) * 0.5 + 0.5) * CELL,
		(float(c.y) - float(GRID_H) * 0.5 + 0.5) * CELL)


func has_floor_at(p: Vector2) -> bool:
	return is_walkable_cell(world_to_cell(p))


func start_pos() -> Vector2:
	return cell_center(_start_cell)


func boss_room_pos() -> Vector2:
	return cell_center(_boss_cell)


## 商人密室的位置。和 boss_room_pos 一样，Game 只读这个坐标，
## 不需要知道它是"第几远"算出来的。
func shop_room_pos() -> Vector2:
	return cell_center(_shop_cell)


func room_count() -> int:
	return _rooms.size()


func floor_cell_count() -> int:
	var n: int = 0
	for v in _cells:
		if v == FLOOR:
			n += 1
	return n


## 位移后夹紧：先试完整位移，再试沿 X / 沿 Y 滑动，都不行就停在原地。
## 四个角都要求可走，等价于给圆形身体留了半径，不会半身嵌进墙里。
func constrain(from: Vector2, to: Vector2, body_radius: float) -> Vector2:
	if _walkable_at(to, body_radius):
		return to
	var slide_x := Vector2(to.x, from.y)
	if _walkable_at(slide_x, body_radius):
		return slide_x
	var slide_y := Vector2(from.x, to.y)
	if _walkable_at(slide_y, body_radius):
		return slide_y
	return from


func _walkable_at(p: Vector2, radius: float) -> bool:
	for corner in CORNERS:
		if not is_walkable_cell(world_to_cell(p + corner * radius)):
			return false
	return true


## 从玩家所在格做一次 BFS，给每格算出「下一步往哪走」。玩家没换格就跳过，
## 所以每帧调用也只有一次 int 比较的开销；换格时重算 432 格，足够便宜。
func rebuild_flow(player_pos: Vector2) -> void:
	var origin: Vector2i = world_to_cell(player_pos)
	if not is_walkable_cell(origin) or origin == _flow_origin:
		return
	_flow_origin = origin
	_flow.fill(NO_FLOW)
	var start: int = _idx(origin)
	_flow[start] = FLOW_HERE
	var queue: PackedInt32Array = PackedInt32Array()
	queue.append(start)
	var head: int = 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		var cx: int = cur % GRID_W
		var cy: int = cur / GRID_W
		for d in range(DIRS.size()):
			var nx: int = cx + DIRS[d].x
			var ny: int = cy + DIRS[d].y
			if nx < 0 or ny < 0 or nx >= GRID_W or ny >= GRID_H:
				continue
			var ni: int = ny * GRID_W + nx
			if _cells[ni] != FLOOR or _flow[ni] != NO_FLOW:
				continue
			# 对角不许贴着墙角穿过去，否则敌人会卡在走廊拐角
			if d >= 4 and (_cells[cy * GRID_W + nx] != FLOOR or _cells[ny * GRID_W + cx] != FLOOR):
				continue
			_flow[ni] = OPPOSITE[d]
			queue.append(ni)


## 敌人调用：返回朝下一格中心的单位方向。不可达格返回零向量，
## 由调用方退化成直线追击，不会出现「站住不动」的死局。
func flow_dir(pos: Vector2) -> Vector2:
	var c: Vector2i = world_to_cell(pos)
	if not is_walkable_cell(c):
		return Vector2.ZERO
	var f: int = _flow[_idx(c)]
	if f == NO_FLOW or f == FLOW_HERE:
		return Vector2.ZERO
	return (cell_center(c + DIRS[f]) - pos).normalized()


## 可达地板格 / 全部地板格。自检用它断言全图连通；也是 P3 换图后的诊断量。
func flow_coverage() -> float:
	var total: int = 0
	var reached: int = 0
	for i in range(_cells.size()):
		if _cells[i] != FLOOR:
			continue
		total += 1
		if _flow[i] != NO_FLOW:
			reached += 1
	if total == 0:
		return 0.0
	return float(reached) / float(total)


## 把任意点吸到最近的可走格中心。掉落物用这个：宝石不能因为落在墙里
## 就被传送到地图另一头；敌人刷怪则走 random_spawn_point，专门挑远处。
func nearest_floor_point(p: Vector2) -> Vector2:
	var origin: Vector2i = world_to_cell(p)
	if is_walkable_cell(origin):
		return p
	for ring in range(1, maxi(GRID_W, GRID_H)):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var c := Vector2i(origin.x + dx, origin.y + dy)
				if is_walkable_cell(c):
					return cell_center(c)
	return start_pos()


## 在可走格里挑一个离 near 满足距离约束的落点，供刷怪 / 掉落使用。
## 试不到就退回起点，保证调用方永远拿到一个合法坐标。
func random_spawn_point(near: Vector2, min_dist: float, max_dist: float) -> Vector2:
	for i in range(40):
		var c := Vector2i(_rng.randi_range(0, GRID_W - 1), _rng.randi_range(0, GRID_H - 1))
		if _cells[_idx(c)] != FLOOR:
			continue
		var p: Vector2 = cell_center(c)
		var d: float = p.distance_to(near)
		if d >= min_dist and d <= max_dist:
			return p
	return start_pos()


func _draw() -> void:
	for y in range(GRID_H):
		for x in range(GRID_W):
			var c := Vector2i(x, y)
			var top_left: Vector2 = cell_center(c) - Vector2(CELL * 0.5, CELL * 0.5)
			var col: Color = FLOOR_COLOR if _cells[_idx(c)] == FLOOR else WALL_COLOR
			draw_rect(Rect2(top_left, Vector2(CELL, CELL)), col)
