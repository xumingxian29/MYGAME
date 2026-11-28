class_name Minimap
extends Control

## 右上角小地图。只回答三个问题：我在哪、这层长什么样、值得走过去的那个点在哪。
##
## 网格是 24×18，每格画 5 像素 → 120×90。**用整数缩放不是随手选的**：
## 迷宫最窄的走廊只有 1 格宽，5 像素是"刚好还看得见一条线"的下限；
## 而 4.8 这种非整数倍会把那条线糊成半透明——小地图一旦分不清哪是走廊、
## 哪是墙缝，它就不再是地图，只是噪点。
##
## 墙和地板**预烘焙成一张纹理**（setup 时一次，432 个格子），
## 每帧只画十来个点。每帧重画 432 个 draw_rect 在这个游戏里是纯浪费：
## 地图在整幕里根本不变。


## 每格几像素。5 → 120×90，见开头那段。
const CELL_PX: int = 5

## 视野半径（世界坐标）。**只画这个范围内的敌人**，不是全图透视。
## 1280×720 @ zoom 1.35 时半对角线约 543，取 560 就是"屏幕能看到的范围"：
## 小地图因此不会变成隔墙看怪的雷达，它只帮你把屏幕之外那一小圈补上，
## 让绕回来的怪不至于完全没预兆。手机（960×540）看到的是同一片区域，
## 平台上不会因为小地图变成另一种游戏。
const RADAR: float = 560.0

## 墙（底色）与地板。对比度刻意压得低：小地图是背景信息，
## 跳出来的应该是点，不是地图本身。
const BG_COLOR: Color = Color(0.055, 0.065, 0.09, 0.82)
const FLOOR_COLOR: Color = Color(0.30, 0.34, 0.43, 0.95)
const BORDER_COLOR: Color = Color(0.52, 0.62, 0.78, 0.55)
const ENEMY_COLOR: Color = Color(0.92, 0.34, 0.34, 0.85)
const PLAYER_COLOR: Color = Color(1.0, 0.95, 0.78)
const BOSS_COLOR: Color = Color(1.0, 0.42, 0.30)
const SHOP_COLOR: Color = Color(1.0, 0.84, 0.36)
const GATE_COLOR: Color = Color(0.55, 0.88, 1.0)

var _bg: ImageTexture = null
var _has_map: bool = false

var _player_pos: Vector2 = Vector2.ZERO
var _has_player: bool = false
var _enemies: PackedVector2Array = PackedVector2Array()
var _boss_pos: Vector2 = Vector2.ZERO
var _has_boss: bool = false
var _shop_pos: Vector2 = Vector2.ZERO
var _has_shop: bool = false
var _gates: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	# 整数倍放大必须用最近邻，否则地板会被插值糊成一片灰。
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(MazeMap.GRID_W * CELL_PX, MazeMap.GRID_H * CELL_PX)
	size = custom_minimum_size
	visible = false


## 换图时调用一次。传 null 表示当前没有地图（比如回到主菜单），整块隐藏。
func setup(maze: MazeMap) -> void:
	if maze == null:
		_has_map = false
		_bg = null
		visible = false
		queue_redraw()
		return
	var img := Image.create(MazeMap.GRID_W, MazeMap.GRID_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y in range(MazeMap.GRID_H):
		for x in range(MazeMap.GRID_W):
			if maze.is_walkable_cell(Vector2i(x, y)):
				img.set_pixel(x, y, FLOOR_COLOR)
	_bg = ImageTexture.create_from_image(img)
	_has_map = true
	_has_player = false
	_has_boss = false
	_has_shop = false
	_enemies.clear()
	_gates.clear()
	visible = true
	queue_redraw()


## 每帧推一次。敌人只传"雷达范围内"的坐标，过滤在 Game 里做：
## 那是玩法判断（谁算威胁），不该藏在一个画图控件里。
func update_blips(player_pos: Vector2, enemies: PackedVector2Array,
		boss_pos: Vector2, has_boss: bool,
		shop_pos: Vector2, has_shop: bool, gates: PackedVector2Array) -> void:
	if not _has_map:
		return
	_player_pos = player_pos
	_has_player = true
	_enemies = enemies
	_boss_pos = boss_pos
	_has_boss = has_boss
	_shop_pos = shop_pos
	_has_shop = has_shop
	_gates = gates
	queue_redraw()


func has_map() -> bool:
	return _has_map


## 世界坐标 → 小地图像素。地图中心是世界原点，所以偏移量是半张图而不是左上角。
func _to_px(p: Vector2) -> Vector2:
	return Vector2(
		p.x / MazeMap.CELL + float(MazeMap.GRID_W) * 0.5,
		p.y / MazeMap.CELL + float(MazeMap.GRID_H) * 0.5) * float(CELL_PX)


func _draw() -> void:
	var full := Vector2(MazeMap.GRID_W * CELL_PX, MazeMap.GRID_H * CELL_PX)
	draw_rect(Rect2(Vector2.ZERO, full), BG_COLOR)
	if _bg != null:
		draw_texture_rect(_bg, Rect2(Vector2.ZERO, full), false)
	if not _has_player:
		draw_rect(Rect2(Vector2.ZERO, full), BORDER_COLOR, false, 1.0)
		return

	# 敌人：2×2 的点。再大就会把走廊整条染红，反而看不清路。
	for p in _enemies:
		var e: Vector2 = _to_px(p)
		draw_rect(Rect2(e - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), ENEMY_COLOR)

	# 商人：菱形。它是"要不要绕回去"的唯一决策点，必须一眼能认出来。
	if _has_shop:
		_shop_mark(_to_px(_shop_pos))

	# 传送门：亮青色方点。开门的十几秒里，它就是玩家要走去的地方。
	# 比敌人点大一号：四扇门常常挤在同一条走廊上，小点会连成一条虚线。
	for p in _gates:
		var g: Vector2 = _to_px(p)
		draw_rect(Rect2(g - Vector2(2.0, 2.0), Vector2(4.0, 4.0)), GATE_COLOR)

	# Boss：外圈 + 实心，比其他点大一号——它值得单独一个形状。
	if _has_boss:
		var b: Vector2 = _to_px(_boss_pos)
		draw_circle(b, 3.4, BOSS_COLOR)
		draw_arc(b, 4.8, 0.0, TAU, 18, Color(1.0, 0.72, 0.62, 0.75), 1.0)

	# 玩家：白心 + 暗边 + 一圈微光。暗边是为了在任何地板上都不糊
	# （纯白点落在浅色地板上会直接消失），微光是为了让眼睛先找到它——
	# 这块图唯一的用法就是"先找自己，再看别的"。
	var me: Vector2 = _to_px(_player_pos)
	draw_circle(me, 5.2, Color(1.0, 0.95, 0.78, 0.16))
	draw_circle(me, 3.8, Color(0.05, 0.06, 0.09, 0.92))
	draw_circle(me, 2.7, PLAYER_COLOR)

	draw_rect(Rect2(Vector2.ZERO, full), BORDER_COLOR, false, 1.0)


## 商人标记：实心菱形。折线画出来只有 1.4 像素宽，在 5 像素一格的比例尺上
## 会断成一个小 "C"——试过，看起来像渲染错误而不是标记。
func _shop_mark(c: Vector2) -> void:
	var r: float = 3.6
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(0.0, -r), c + Vector2(r, 0.0),
		c + Vector2(0.0, r), c + Vector2(-r, 0.0),
	]), SHOP_COLOR)
