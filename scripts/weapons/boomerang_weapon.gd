class_name BoomerangWeapon
extends Node2D

## 回旋镖：向四周投出后自动飞回。位移始终相对玩家计算，所以玩家跑动时飞镖也会回到手上。
## count = 0 表示尚未解锁。
## 命中用“每敌人独立冷却”：一枚镖一次飞行可多次命中同一敌人，但不会每帧都叠伤害。

## 由 Player 注入的敌人列表引用
## 掷出回旋镖时发出。和近战的 swung() 同一个用途：武器只报告动作，不碰音频。
signal thrown()

var enemies: Array[Enemy] = []
## 迷宫引用。回旋镖是"飞出去再回来"的抛物线，撞墙时不让它原地消失
## （那样玩家会觉得镖被墙吃了），但墙后的怪不再计入命中。
var maze: MazeMap = null
## 破甲弹回调，由 Player 注入。一次投掷花一发，整趟飞行都算穿甲。
var breach_count: Callable = Callable()
var breach_take: Callable = Callable()

@export var count: int = 0
@export var damage: float = 14.0
@export var fly_speed: float = 520.0
@export var fly_distance: float = 300.0
@export var cooldown: float = 2.2
@export var spin_speed: float = 15.0

const HIT_COOLDOWN: float = 0.5
const HIT_RADIUS: float = 13.0
const ARM_LENGTH: float = 13.0
const ARM_WIDTH: float = 5.0
const MAX_FLIGHTS: int = 6

var _cd: float = 0.0
var _spin: float = 0.0
## 上一 tick 的旋转角。不取模、不 fmod：只喂给 cos/sin，
## 保持单调递增才能在上一个值和这一个值之间安全插值（取模后会在 2π 处跳回去）。
var _prev_spin: float = 0.0
## 每一波投掷：{"dirs": Array[float], "t": float, "pt": float}
var _flights: Array[Dictionary] = []
## 敌人生成序号(spawn_serial) -> 剩余冷却秒数
var _hit_cd: Dictionary[int, float] = {}


## 镖不是节点，是数组里的一行数据 + 本节点自绘，引擎的物理插值管不到。
## 每渲染帧重绘一次，_draw 自己按插值分数补帧（见那里的说明）。
func _process(_delta: float) -> void:
	if count > 0 and not _flights.is_empty():
		queue_redraw()


func _physics_process(delta: float) -> void:
	if count <= 0:
		return
	_prev_spin = _spin
	_spin += spin_speed * delta
	_tick_cooldowns(delta)
	_update_flights(delta)
	_cd = maxf(_cd - delta, 0.0)
	if _cd <= 0.0:
		_throw()
	queue_redraw()


## 总飞行时长（飞出去 + 飞回来）
func _duration() -> float:
	return maxf(2.0 * fly_distance / maxf(fly_speed, 1.0), 0.15)


func _take_ap() -> bool:
	if not breach_count.is_valid() or not breach_take.is_valid():
		return false
	if int(breach_count.call()) <= 0:
		return false
	return bool(breach_take.call())


func _throw() -> void:
	thrown.emit()
	_cd = cooldown
	var ap: bool = _take_ap()
	var base: float = _aim_angle()
	var n: int = maxi(count, 1)
	var dirs: Array[float] = []
	for i in range(n):
		# 均匀铺满一圈：1 枚朝最近敌人，2 枚对向，3 枚 120° 分布
		dirs.append(base + TAU * float(i) / float(n))
	_flights.append({"dirs": dirs, "t": 0.0, "pt": 0.0, "ap": ap})
	while _flights.size() > MAX_FLIGHTS:
		_flights.remove_at(0)


func _aim_angle() -> float:
	var best: Enemy = null
	var best_dist: float = INF
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var dist: float = global_position.distance_squared_to(enemy.global_position)
		if dist < best_dist:
			best_dist = dist
			best = enemy
	if best == null:
		return 0.0
	return (best.global_position - global_position).angle()


func _update_flights(delta: float) -> void:
	if _flights.is_empty():
		return
	var duration: float = _duration()
	var index: int = _flights.size() - 1
	while index >= 0:
		var flight: Dictionary = _flights[index]
		flight["pt"] = flight["t"]
		flight["t"] = float(flight["t"]) + delta
		var progress: float = clampf(float(flight["t"]) / duration, 0.0, 1.0)
		# 三角波：去程与回程速度都是 fly_speed，不会出现中途突然加速
		var reach: float = progress * 2.0
		if reach > 1.0:
			reach = 2.0 - reach
		var radius: float = fly_distance * reach
		for dir in flight["dirs"]:
			_resolve_hit(Vector2(cos(dir), sin(dir)) * radius, bool(flight.get("ap", false)))

		if progress >= 1.0:
			_flights.remove_at(index)
		index -= 1


func _resolve_hit(local_pos: Vector2, ap: bool = false) -> void:
	var world_pos: Vector2 = global_position + local_pos
	# 只判端点不够：镖的飞行是参数化的，端点可能正好落在墙后的可走格里，
	# 于是"隔着一堵墙把墙后的怪削掉"。必须沿连线采样，和近战用同一套口径。
	if not _has_line_to(world_pos):
		return
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var key: int = enemy.spawn_serial
		if _hit_cd.has(key):
			continue
		var reach: float = enemy.radius + HIT_RADIUS
		if world_pos.distance_squared_to(enemy.global_position) > reach * reach:
			continue
		enemy.take_damage(damage * (Player.AP_DAMAGE_SCALE if ap else 1.0), false, ap)
		_hit_cd[key] = HIT_COOLDOWN


## 从玩家到落点，墙有没有挡住。8 段是"镖最远 400 像素 / 一格 96"的下限：
## 再少就可能整格跳过去（两端都在可走格、中间的墙被跳过）。
func _has_line_to(to_world: Vector2) -> bool:
	if maze == null:
		return true
	for i in range(1, 8):
		var t: float = float(i) / 8.0
		if not maze.has_floor_at(global_position.lerp(to_world, t)):
			return false
	return true


func _tick_cooldowns(delta: float) -> void:
	if _hit_cd.is_empty():
		return
	for key in _hit_cd.keys():
		var left: float = _hit_cd[key] - delta
		if left <= 0.0:
			_hit_cd.erase(key)
		else:
			_hit_cd[key] = left


func _draw() -> void:
	if count <= 0:
		return
	# 与子弹同一个做法：位置不是节点变换，得自己在上一 tick 和这一 tick 之间取值。
	# 飞行进度 t 是几何参数的唯一输入（半径由三角波算出来），所以插 t 就够了；
	# 镖自身的旋转角同理插 _prev_spin → _spin。
	var f: float = Engine.get_physics_interpolation_fraction()
	var spin: float = lerpf(_prev_spin, _spin, f)
	var duration: float = _duration()
	for flight in _flights:
		var t: float = lerpf(float(flight["pt"]), float(flight["t"]), f)
		var progress: float = clampf(t / duration, 0.0, 1.0)
		var reach: float = progress * 2.0
		if reach > 1.0:
			reach = 2.0 - reach
		var radius: float = fly_distance * reach
		for i in range(flight["dirs"].size()):
			var dir: float = flight["dirs"][i]
			var pos: Vector2 = Vector2(cos(dir), sin(dir)) * radius
			var arm_spin: float = spin + float(i) * 1.3
			# 两片呈 V 形的镖臂，一眼能认出是回旋镖而不是子弹
			draw_colored_polygon(_arm_points(pos, arm_spin - 0.95), Color(1.0, 0.72, 0.3))
			draw_colored_polygon(_arm_points(pos, arm_spin + 0.95), Color(1.0, 0.88, 0.56))
			draw_circle(pos, 3.2, Color(0.28, 0.16, 0.06))


func _arm_points(center: Vector2, angle: float) -> PackedVector2Array:
	var dir := Vector2(cos(angle), sin(angle))
	var side := dir.orthogonal() * ARM_WIDTH
	var tip: Vector2 = center + dir * ARM_LENGTH
	return PackedVector2Array([
		center - side,
		tip - side * 0.7,
		tip + side * 0.7,
		center + side,
	])
