extends SceneTree

## 截图工具：在真实渲染窗口里跑一局，按脚本推进到几个关键画面并各存一张 PNG。
## 用法：godot --path . --script res://dev/shot.gd   （不能加 --headless，headless 没有渲染设备）
## 输出 .workbuddy/shot_*.png
##
## 只负责"摆出画面 + 存图"，不做任何断言；断言在 dev/stage_check.gd 里。

const OUT_DIR: String = "res://.workbuddy/"

var _game: Node = null
var _frames: int = 0
var _step: int = 0
var _shots: PackedStringArray = []


func _initialize() -> void:
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("截图", HeroClass.RANGER)
		_game.story_enabled = false
		if _game.story_panel != null and _game.story_panel.is_open():
			_game.story_panel.skip()
		return false

	_frames += 1
	if _game._state == 2:
		_game._choose(0)
		return false
	if is_instance_valid(_game.player) and _game._state == 1:
		# 摆拍用：不让玩家在准备画面时被打死
		_game.player.health = _game.player.max_health

	match _step:
		0:
			if _frames < 26:
				return false
			_snap("shot_1_banner")
			# 让场上有怪，画面才像在玩
			for i in range(14):
				_game._create_enemy(Enemy.Kind.GRUNT, false,
					_game.player.global_position + Vector2(randf_range(-260, 260), randf_range(-170, 170)))
			_step = 1
			_frames = 0
		1:
			if _frames < 12:
				return false
			_snap("shot_2_play")
			_game._stage_time = 999.0
			_step = 2
			_frames = 0
		2:
			if _frames < 16:
				return false
			_snap("shot_3_boss")
			if _game._boss != null and is_instance_valid(_game._boss):
				_game._boss.take_damage(1e9)
			_step = 3
			_frames = 0
		3:
			if _frames < 14:
				return false
			_snap("shot_4_chapter2")
			# 切到手机基准分辨率，验证触屏布局（Boss 血条下移后不能压住章节横幅）
			_game._touch_mode = true
			_game.hud.set_touch_mode(true)
			_game._apply_mobile_viewport()
			root.size = Vector2i(960, 540)
			_game._stage_time = 999.0
			_step = 4
			_frames = 0
		4:
			if _frames < 20:
				return false
			# 重新打一次横幅，专门看它和 Boss 血条、左上角状态条有没有打架
			_game.hud.show_banner(Stage.title(_game._stage_index),
				str(Stage.at(_game._stage_index)["subtitle"]), Stage.tint(_game._stage_index), false)
			_step = 5
			_frames = 0
		5:
			if _frames < 16:
				return false
			_snap("shot_5_mobile")
			# 受击无敌帧会吃掉这一下，先把无敌清掉再打死：
			# 摆拍时玩家正被小怪贴着，直接 take_damage 大概率空转
			_game.player._invuln = 0.0
			_game.player.take_damage(99999.0)
			_step = 6
			_frames = 0
		6:
			if _frames < 16:
				return false
			_snap("shot_6_result")
			_finish()
			return true
	return false


func _snap(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		return
	var path: String = OUT_DIR + name + ".png"
	img.save_png(path)
	_shots.append("%s  %dx%d" % [path, img.get_width(), img.get_height()])


func _finish() -> void:
	var f: FileAccess = FileAccess.open(OUT_DIR + "shots.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _shots:
		f.store_line(line)
	f.close()
