extends SceneTree

## 主菜单（含新增的难度三选一）截图。验证 960×540 触屏逻辑分辨率下
## 难度行没把"开始游戏"顶出屏幕，以及三档选中态 / 说明行能正常切换。
## 用法：godot --path . --resolution 960x540 --script res://dev/menu_shot.gd
## 输出 .workbuddy/menu_*.png
##
## 不做断言——数据断言在 dev/difficulty_check.gd，布局断言在 dev/ui_pause_check.gd。
## 这里只负责"看一眼"。

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
		return false

	_frames += 1
	match _step:
		0:
			# _ready 里已经 _open_menu()，等布局稳定再拍
			if _frames < 8:
				return false
			_snap("menu_1_default")
			_step = 1
			_frames = 0
		1:
			if _frames < 4:
				return false
			# 切到硬核：选中态描边 + 说明行都要跟着变
			var menu = _game.start_menu
			var no_players: Array[Dictionary] = []
			menu.open("玩家", no_players, HeroClass.WARRIOR, true, Difficulty.HARD)
			_step = 2
			_frames = 0
		2:
			if _frames < 5:
				return false
			_snap("menu_2_hard")
			_step = 3
			_frames = 0
		3:
			if _frames < 4:
				return false
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
	var f: FileAccess = FileAccess.open(OUT_DIR + "menu_shots.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _shots:
		f.store_line(line)
	f.close()
	quit()
