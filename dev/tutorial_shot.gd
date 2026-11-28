extends SceneTree

## 截图：新手引导提示条在真实画面里的位置与可读性。
## 用法：godot --path . --script res://dev/tutorial_shot.gd   （不能加 --headless）
## 输出 .workbuddy/tutorial_*.png
##
## 为什么必须看图：位置这件事代码说了不算。提示条要和顶部血条、左下摇杆、右下技能键
## 都不打架，还要压在战场上能读清字——只有实际渲染出来才能判断。
##
## 三张图分别对应最容易撞车的三个时刻：
##   move   开局（顶部有章节横幅、左下有摇杆提示）
##   skill  战斗中（底部就是技能键，提示条会不会压到它）
##   zone   圈收缩（屏幕上有紫圈线穿过）

const OUT_DIR: String = "res://.workbuddy/"

var _game: Node = null
var _frames: int = 0
var _step: int = 0


func _initialize() -> void:
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("引导截图", HeroClass.RANGER)
		_game.story_enabled = false
		if _game.story_panel != null and _game.story_panel.is_open():
			_game.story_panel.skip()
		# 截图为的是看"新玩家第一局"，所以要把历史清掉，否则提示不会出现
		_game.tutorial.clear_history()
		return false

	_frames += 1
	if _game._state == 2:
		_game._choose(0)
		return false
	# 摆拍不打死：血量锁满，避免拍到结算画面
	if is_instance_valid(_game.player) and _game._state == 1:
		_game.player.health = _game.player.max_health

	match _step:
		0:
			# move 提示 delay 1.6s + 淡入 0.22s，第 130 帧（2.16s）已经完全显形
			if _frames < 130:
				return false
			_shot("tutorial_move")
			_step = 1
			_frames = 0
		1:
			if _frames == 2:
				_isolate("skill")
				_game.player.mana = 0.0
				_game.player.add_mana(9999.0)
			# 提示是排队显示的：move 还要走完停留+淡出+间隔，skill 才轮得到。
			# 等太短会拍到上一条还没退场，三张图变成同一句文案。
			if _frames < 42:
				return false
			_shot("tutorial_skill")
			_step = 2
			_frames = 0
		2:
			if _frames == 2:
				_isolate("zone")
				# 推时间轴到第一次收缩：_tick_zone 会在下一帧发现 is_shrinking 并提示
				# 要推进到"正在收缩"的段（110~140），推到稳定段的话
				# is_shrinking() 是 false，提示根本不会触发
				_game.zone.tick(120.0)
			if _frames < 42:
				return false
			_shot("tutorial_zone")
			_step = 3
			_frames = 0
		_:
			# 截图过程中的"已看过"记录不能留给玩家，否则真机首局没有引导
			_game.tutorial._seen_dirty = false
			if FileAccess.file_exists(TutorialHint.SAVE_PATH):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(TutorialHint.SAVE_PATH))
			return true
	return false


## 让"这一条提示"独占画面：清掉排在后面的队列、结束正在播的那条、
## 并抹掉它的"已看过"记录。截图要验证的是布局，不能让排队顺序决定拍到谁。
func _isolate(id: String) -> void:
	var t: TutorialHint = _game.tutorial
	t._queue.clear()
	t._phase = TutorialHint.Phase.IDLE
	t.visible = false
	t._seen.erase(id)


func _shot(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("FAIL 拿不到帧缓冲")
		return
	var path: String = OUT_DIR + name + ".png"
	img.save_png(path)
	var t: TutorialHint = _game.tutorial
	print("%-16s layer=%d vis=%s alpha=%.2f" % [name, t.layer, str(t.visible), t._root.modulate.a])
	if t._panel != null:
		print("                 panel size=%s pos=%s vis=%s mod=%s in_tree=%s" % [
			str(t._panel.size), str(t._panel.position), str(t._panel.visible),
			str(t._panel.modulate), str(t._panel.is_inside_tree())])
	if t._label != null:
		print("                 label size=%s vis=%s text=「%s」" % [
			str(t._label.size), str(t._label.visible), t._label.text])
	print("                 viewport=%s" % str(t.get_viewport().get_visible_rect().size))
