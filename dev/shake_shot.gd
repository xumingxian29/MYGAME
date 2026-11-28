extends SceneTree

## 震动"观感"的客观量化：清空敌人，只留静态网格背景，
## 然后给一个固定 trauma，连拍 12 帧连续图。
##
## 为什么这样能量出"抖不抖"：
##   场上没有敌人、玩家不动、HUD 不变，**唯一的画面变化就来自相机震动**。
##   于是"相邻帧的平均像素差"直接等于震动强度，不需要人眼判断，
##   也不受"这片区域打斗激烈"之类主观因素干扰。
##
## 用法：
##   godot --path . --fixed-fps 60 --script res://dev/shake_shot.gd -- --tag=before --trauma=0.7
## 输出 .workbuddy/shake_<tag>_<n>.png 与 .workbuddy/shake_<tag>.txt（逐帧 offset）

const OUT_DIR: String = "res://.workbuddy/"

var _game: Node = null
var _frames: int = 0
var _shot_index: int = 0
var _tag: String = "x"
var _trauma: float = 0.7
var _log: PackedStringArray = []
var _warmup: int = 40

const SHOT_COUNT: int = 12


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--trauma="):
			_trauma = float(a.substr(9))
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("震动", HeroClass.WARRIOR)
		return false

	if _game._state == 2:
		_game._choose(0)
		return false
	if _game._state != 1:
		return false

	_frames += 1

	# 隔离变量：清空敌人、关掉刷怪、血锁满。
	# 不清的话，逐帧像素差里混进了敌人移动，就分不清"画面抖"还是"敌人在动"。
	_game._max_enemies = 0
	for e in _game._enemies.duplicate():
		if is_instance_valid(e):
			e.queue_free()
	_game._enemies.clear()
	if is_instance_valid(_game.player):
		_game.player.health = _game.player.max_health
		# 每帧重置 trauma，把幅度钉在这个值上，只让相位推进——
		# 这样拍到的就是"稳态震动"，而不是一个会衰减掉的冲击。
		_game.player._trauma = _trauma

	if _frames < _warmup:
		return false

	var cam = _game.player.camera if is_instance_valid(_game.player) else null
	if cam != null:
		_log.append("%d offset=%.3f,%.3f trauma=%.3f" % [
			_frames, cam.offset.x, cam.offset.y, _game.player._trauma,
		])

	# 先取再拍：get_texture() 拿到的是上一帧完成的画面，
	# 多等一帧能保证拍到的 offset 与画面一致（这个坑之前踩过）。
	var img: Image = root.get_texture().get_image()
	img.save_png("%sshake_%s_%02d.png" % [OUT_DIR, _tag, _shot_index])
	_shot_index += 1
	if _shot_index >= SHOT_COUNT:
		var f: FileAccess = FileAccess.open("%sshake_%s.txt" % [OUT_DIR, _tag], FileAccess.WRITE)
		f.store_string("\n".join(_log))
		f.close()
		print("拍完 %d 帧 → .workbuddy/shake_%s_*.png" % [_shot_index, _tag])
		quit(0)
	return false
