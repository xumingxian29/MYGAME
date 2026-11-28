extends SceneTree

## 剧情屏截图：开场（逐字进行中）与全显示两种状态各一张，
## 再加一张胜利结算。用来确认"跳过键在右上角"和排版没有溢出。
## 用法：godot --path . --script res://dev/story_shot.gd   （不能 headless，headless 没有渲染设备）
## 输出 .workbuddy/story_*.png
##
## 不做断言——断言在 dev/story_check.gd。这里只负责"看一眼"。

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
		_game._on_menu_started("story_shot", HeroClass.WARRIOR)
		return false

	_frames += 1

	match _step:
		0:
			# 剧情第 0 幕正在打字：等 0.35 秒，截图要能看出"逐字"这件事
			if _frames < 22:
				return false
			_snap("story_1_typing")
			_step = 1
			_frames = 0
		1:
			# 把三行全部显示完，看完整排版 + 右上角跳过键
			if _frames < 4:
				return false
			if _game.story_panel != null:
				_game.story_panel.advance()
			if _frames < 8:
				return false
			_game.story_panel.advance()
			_game.story_panel.advance()
			_game.story_panel.advance()
			_snap("story_2_full")
			_step = 2
			_frames = 0
		2:
			# 进游戏，直接摆一场"胜利结算"
			if _frames < 6:
				return false
			_game._map_index = 9
			_game._gauntlet_total = 5
			_game._boss_kills = 5
			_game._elapsed = 823.0
			_game._kills = 612
			_game._level = 34
			_game._on_victory()
			_step = 3
			_frames = 0
		3:
			if _frames < 6:
				return false
			_snap("story_3_victory")
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
	var f: FileAccess = FileAccess.open(OUT_DIR + "story_shots.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _shots:
		f.store_line(line)
	f.close()
	quit()
