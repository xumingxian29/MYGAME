extends SceneTree

## 开插值之后必须验的一件事：**新建 / 瞬移的节点会不会从旧位置滑过来**。
##
## 物理插值的工作原理是"每帧在上一 tick 和这一 tick 之间插值"，
## 所以一个刚 add_child 的节点如果没有重置插值状态，它会被从"默认位置 (0,0)"插过来——
## 屏幕上就是每只敌人、每颗宝石都从世界原点飞出来。
##
## GDScript 读不到 2D 的插值后坐标，所以这里改看**真实像素**：
## 在玩家右侧 300 处放一个品红色圆点，连拍几帧，算它的质心。
##   质心各帧一致（<2px）   → 瞬移是瞬移，正确
##   质心逐帧移动           → 在被插值"滑行"，说明少了 reset_physics_interpolation()
##
## 用法（必须带窗口，headless 出不了图）：
##   godot --path . --fixed-fps 240 --script res://dev/spawn_probe.gd -- --mode=plain
##   godot --path . --fixed-fps 240 --script res://dev/spawn_probe.gd -- --mode=reset

const WARMUP: int = 20
## 连拍帧数。240Hz 下 4 帧 = 一个物理 tick，取 6 帧足够看清是否在滑
const SHOTS: int = 6

var _game: Node = null
var _marker: Node2D = null
var _mode: String = "plain"
var _frame: int = 0
var _phase: int = 0
var _shot: int = 0
var _c1: Array[Vector2] = []
var _c2: Array[Vector2] = []
var _spawn_at: Vector2 = Vector2.ZERO
var _tele_to: Vector2 = Vector2.ZERO


class Marker extends Node2D:
	## 纯品红：场上没有任何别的东西是这个颜色（毒圈是紫、受伤红边是红、HUD 是白/青）
	func _draw() -> void:
		draw_circle(Vector2.ZERO, 32.0, Color(1.0, 0.0, 1.0))


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			_mode = a.substr(7)
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("probe", HeroClass.WARRIOR)
		return false
	if _game._state == 2:
		_game._choose(0)
		return false
	if _game._state != 1 or not is_instance_valid(_game.player):
		return false

	_frame += 1
	# 清场：只要玩家 + 背景网格 + 那个点
	_game._max_enemies = 0
	for e in _game._enemies.duplicate():
		if is_instance_valid(e):
			e.queue_free()
	_game._enemies.clear()
	_game.player.health = _game.player.max_health
	_game.player._trauma = 0.0
	_game.player.camera.offset = Vector2.ZERO

	if _frame < WARMUP:
		return false

	match _phase:
		0:
			_spawn_at = _game.player.global_position + Vector2(300.0, 0.0)
			_marker = Marker.new()
			_game.world.add_child(_marker)
			_marker.global_position = _spawn_at
			if _mode == "reset":
				_marker.reset_physics_interpolation()
			_phase = 1
			_shot = 0
		1:
			# 拍第 _shot 帧：get_texture() 拿到的是上一帧已完成的画面
			_shot += 1
			if _shot > 1:
				_c1.append(_centroid_magenta())
			if _shot > SHOTS:
				_phase = 2
				_shot = 0
				# 往左瞬移而不是往右：往右会在 1280 宽的画布外，质心算不出来
				_tele_to = _spawn_at - Vector2(240.0, 0.0)
				_marker.global_position = _tele_to
				if _mode == "reset":
					_marker.reset_physics_interpolation()
		2:
			_shot += 1
			if _shot > 1:
				_c2.append(_centroid_magenta())
			if _shot > SHOTS:
				_report()
				quit()
				return true
	return false


## 品红像素质心。返回 (-1,-1) 表示画面里找不到点。
func _centroid_magenta() -> Vector2:
	var img: Image = root.get_texture().get_image()
	if img == null:
		return Vector2(-1.0, -1.0)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var data: PackedByteArray = img.get_data()
	var sum: Vector2 = Vector2.ZERO
	var count: int = 0
	for p in range(w * h):
		var i: int = p * 4
		if data[i] > 190 and data[i + 1] < 80 and data[i + 2] > 190:
			sum += Vector2(float(p % w), float(p / w))
			count += 1
	if count == 0:
		return Vector2(-1.0, -1.0)
	return sum / float(count)


func _spread(points: Array[Vector2]) -> float:
	var valid: Array[Vector2] = []
	for p in points:
		if p.x >= 0.0:
			valid.append(p)
	if valid.size() < 2:
		return -1.0
	var lo: Vector2 = valid[0]
	var hi: Vector2 = valid[0]
	for p in valid:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	return (hi - lo).length()


func _report() -> void:
	print("")
	print("== 生成/瞬移插值采样（mode=%s）==" % _mode)
	print("  生成点   %s" % str(_spawn_at))
	print("  瞬移点   %s" % str(_tele_to))
	print("  生成后质心 %s" % str(_c1))
	print("  瞬移后质心 %s" % str(_c2))
	var s1: float = _spread(_c1)
	var s2: float = _spread(_c2)
	print("  生成帧间位移 %.2f 像素" % s1)
	print("  瞬移帧间位移 %.2f 像素" % s2)
	var ok: bool = s1 >= 0.0 and s1 < 2.0 and s2 >= 0.0 and s2 < 2.0
	print("  判定 %s（<2 像素视为瞬移到位，否则是在被插值滑行）" % ("通过" if ok else "不通过"))
	print("")
