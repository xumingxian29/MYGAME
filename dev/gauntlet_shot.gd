extends SceneTree

## 王座厅截图：HUD 的幕名、血条上的名次（2/5）、守门人横幅。
## 用法：godot --path . --script res://dev/gauntlet_shot.gd   （不能 headless）
## 输出 .workbuddy/gauntlet_*.png
##
## 这三处都是"只能靠眼睛验"的排版：名次挤不挤得下、幕名会不会被裁、
## 横幅和血条会不会叠在一起。断言在 dev/run_check.gd。

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
		_game.story_enabled = false
		_game._on_menu_started("gauntlet_shot", HeroClass.WARRIOR)
		return false

	_frames += 1
	if _game._state == 2:
		_game._choose(0)
		return false

	match _step:
		0:
			# 直接跳到王座厅：十道门走完的状态
			if _frames < 3:
				return false
			_game._map_index = 10
			_game._portal_count = 10
			_game._stage_index = 10
			_game._enter_final_hall()
			_step = 1
			_frames = 0
		1:
			# 等第二位守门人出场：名次是 2/5，血条与阶段字同时在场
			if _frames < 6:
				return false
			_game._gauntlet_index = 1
			_game._gauntlet_left = 4
			_game._spawn_gauntlet_boss()
			if is_instance_valid(_game.player):
				_game.player.health = _game.player.max_health
			_game.hud.show_banner(Story.finale_title(), Story.finale_beat(), Story.finale_tint(), true)
			_step = 2
			_frames = 0
		2:
			if _frames < 20:
				return false
			_snap("gauntlet_1_rank")
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
	var f: FileAccess = FileAccess.open(OUT_DIR + "gauntlet_shots.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _shots:
		f.store_line(line)
	f.close()
	quit()
