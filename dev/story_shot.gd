extends SceneTree

## 剧情屏 / 选门确认面板 / 结局结算的截图。
## 用法：godot --path . --script res://dev/story_shot.gd   （不能 headless，headless 没有渲染设备）
##      加 `-- --touch` 走触屏排版，配 `--resolution 844x390` 看手机横屏的实际效果。
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
			# 中途的选门确认面板：底下那行"走过的路"是这一版的决策可视化的全部
			if _frames < 6:
				return false
			_game._map_index = 4
			_game._gate_trail = {"card": 2, "card2": 3, "breach": 1, "gold": 1}
			_game._last_choice = "card2"
			_game._open_portals(_game.player.global_position)
			_step = 3
			_frames = 0
		3:
			# 面板是在这一帧建出来的，但截图抓的是上一帧的画面：
			# 同一个 _process 里建完就拍，拍到的是还没有面板的那一帧。
			if _frames < 3:
				return false
			_game._on_portal_requested(_game._portals[1])
			_step = 4
			_frames = 0
		4:
			if _frames < 4:
				return false
			_snap("story_3_confirm")
			_step = 5
			_frames = 0
		5:
			# 结局：这一局一路双卡，门外是"新的王"
			if _frames < 4:
				return false
			_game._cancel_portal()
			for p in _game._portals:
				if is_instance_valid(p):
					p.queue_free()
			_game._portals.clear()
			_game._awaiting_portal = false
			_game._map_index = 9
			_game._gauntlet_total = 5
			_game._boss_kills = 5
			_game._elapsed = 1812.0
			_game._kills = 1348
			_game._level = 41
			_game._gate_trail = {"card2": 7, "card": 2, "breach": 1}
			_game._last_choice = "card2"
			_game._on_victory()
			_step = 6
			_frames = 0
		6:
			if _frames < 6:
				return false
			_snap("story_4_victory")
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
