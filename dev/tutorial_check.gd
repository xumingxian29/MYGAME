extends SceneTree

## 新手引导自检。不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/tutorial_check.gd
##
## 这套引导最容易错的三件事，也是这里主要的断言：
##   1. 时序 —— 淡入/停留/淡出的时长算错，提示会"闪一下就没"或者赖着不走
##   2. 去重 —— 同一条在一局里弹两次，比不弹更烦人
##   3. 跨局记忆 —— 写盘失败的话，老玩家每次进来都要重看一遍
##
## 时间推进全部手动调 _process()，不依赖引擎帧率。

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	# 从干净状态开始：上一轮测试或玩家真实存档不能影响断言
	_wipe_save()
	# 必须等一帧：_initialize 阶段 root 还没真正进入树，
	# 这时候 add_child 不会触发 _ready，节点的可见性/锚点/process_mode 全都还是默认值，
	# 后面每条断言都会莫名其妙地失败（而不是报错），极难排查。
	await process_frame

	_test_initial()
	_test_sequence()
	_test_dedupe()
	_test_queue()
	_test_delay()
	_test_persist()
	_test_reset_keeps_history()
	_test_clear_history()

	_wipe_save()
	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


func _wipe_save() -> void:
	if FileAccess.file_exists(TutorialHint.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TutorialHint.SAVE_PATH))


func _make() -> TutorialHint:
	var t := TutorialHint.new()
	root.add_child(t)
	return t


## 手动推进，按 1/60 秒小步走，避免一步跨过整个阶段
func _advance(t: TutorialHint, seconds: float) -> void:
	var left: float = seconds
	while left > 0.0:
		var step: float = minf(1.0 / 60.0, left)
		t._process(step)
		left -= step


# ---------------------------------------------------------------- 初始

func _test_initial() -> void:
	print("\n[初始状态]")
	var t := _make()
	_check("默认不可见", not t.visible)
	_check("默认无队列", t._queue.is_empty())
	_check("默认处于 IDLE", int(t._phase) == TutorialHint.Phase.IDLE)
	_check("是独立画布层（要压在 HUD 之上）", t is CanvasLayer)
	_check("层级高于 HUD 与触屏层（layer=%d）" % t.layer, t.layer > 1)
	_check("不拦鼠标（不能挡住操作）", t._root.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("根节点铺满全屏", t._root.anchor_right == 1.0 and t._root.anchor_bottom == 1.0)
	_check("跟随暂停（选卡时不显示）", t.process_mode == Node.PROCESS_MODE_PAUSABLE)
	t.free()


# ---------------------------------------------------------------- 时序

func _test_sequence() -> void:
	print("\n[显示时序]")
	var t := _make()
	t.notify("move", "测试文案", "", 1.0)
	_check("notify 后入队", t._queue.size() == 1, "队列 %d" % t._queue.size())
	_check("尚未开始显示", int(t._phase) == TutorialHint.Phase.IDLE)

	# 一帧之后进入淡入
	_advance(t, 1.0 / 60.0)
	_check("开始淡入", int(t._phase) == TutorialHint.Phase.FADE_IN and t.visible)
	_check("文案已写入 Label", t._label.text == "测试文案", "实际「%s」" % t._label.text)

	# 淡入中点：透明度应在 0~1 之间
	_advance(t, TutorialHint.FADE_IN * 0.5)
	var mid_alpha: float = t._root.modulate.a
	_check("淡入过程中半透明（%.2f）" % mid_alpha, mid_alpha > 0.1 and mid_alpha < 1.0)

	_advance(t, TutorialHint.FADE_IN)
	_check("淡入结束进入停留", int(t._phase) == TutorialHint.Phase.HOLD)
	_check("停留时不透明", is_equal_approx(t._root.modulate.a, 1.0), "alpha=%.2f" % t._root.modulate.a)

	# 停留时间还没到就不该开始淡出
	_advance(t, 0.5)
	_check("停留未满时仍在 HOLD", int(t._phase) == TutorialHint.Phase.HOLD)

	_advance(t, 0.6)
	_check("停留期满开始淡出", int(t._phase) == TutorialHint.Phase.FADE_OUT)

	_advance(t, TutorialHint.FADE_OUT + 0.05)
	_check("淡出后回到 IDLE", int(t._phase) == TutorialHint.Phase.IDLE)
	_check("淡出后隐藏", not t.visible)
	_check("淡出后完全透明", is_zero_approx(t._root.modulate.a), "alpha=%.3f" % t._root.modulate.a)

	# 全流程耗时应该接近 FADE_IN + hold + FADE_OUT + QUEUE_GAP 的量级，
	# 差太多说明某个阶段的时长算错了
	t.free()


func _test_dedupe() -> void:
	print("\n[去重]")
	var t := _make()
	# 用专属 id：上一个用例的节点析构时会 flush 存档，
	# 复用 "move" 会让这条断言变成"测上一个用例有没有写盘"
	t.notify("dedupe_x", "第一条")
	t.notify("dedupe_x", "第二条")
	_check("同一 id 只入队一次", t._queue.size() == 1, "队列 %d" % t._queue.size())
	_check("保留第一次的文案", str(t._queue[0]["text"]) == "第一条")
	_check("id 已记为看过", t.has_seen("dedupe_x"))

	t.notify("pickup", "另一条")
	_check("不同 id 可以入队", t._queue.size() == 2)
	t.free()


func _test_queue() -> void:
	print("\n[排队]")
	var t := _make()
	t.notify("a", "A")
	t.notify("b", "B")
	_advance(t, 1.0 / 60.0)
	_check("先显示 A", t._label.text == "A")
	# A 播完（含间隔）后 B 才出现
	_advance(t, TutorialHint.FADE_IN + 2.4 + TutorialHint.FADE_OUT + 0.1)
	_check("A 播完后 B 仍在队列里等待", t._queue.size() == 1 and str(t._queue[0]["text"]) == "B",
		"队列 %d" % t._queue.size())
	_advance(t, TutorialHint.QUEUE_GAP + 0.05)
	_check("间隔结束后显示 B", t._label.text == "B", "实际「%s」" % t._label.text)
	t.free()


func _test_delay() -> void:
	print("\n[延迟]")
	var t := _make()
	t.notify("late", "晚一点", "", 0.5, 1.0)
	_advance(t, 0.5)
	_check("延迟未到时不出现在屏幕上", int(t._phase) == TutorialHint.Phase.IDLE)
	_advance(t, 0.6)
	_check("延迟到期后开始显示", int(t._phase) != TutorialHint.Phase.IDLE)
	t.free()


# ---------------------------------------------------------------- 跨局记忆

func _test_persist() -> void:
	print("\n[跨局记忆]")
	var t := _make()
	t.notify("move", "移动")
	t.notify("pickup", "拾取")
	t.flush()
	_check("存档已写出", FileAccess.file_exists(TutorialHint.SAVE_PATH))

	var second := _make()
	_check("新实例记得 move", second.has_seen("move"))
	_check("新实例记得 pickup", second.has_seen("pickup"))
	_check("新实例没记过 zone", not second.has_seen("zone"))

	# 关键行为：记忆生效时 notify 应该完全不产生队列
	second.notify("move", "再说一遍")
	_check("已看过的条目不再入队", second._queue.is_empty(), "队列 %d" % second._queue.size())
	second.notify("zone", "新的一条")
	_check("没看过的仍会入队", second._queue.size() == 1)

	# 存档内容应该是排序过的稳定结构，方便人肉排查
	var f: FileAccess = FileAccess.open(TutorialHint.SAVE_PATH, FileAccess.READ)
	var raw: String = f.get_as_text()
	f.close()
	_check("存档是可读 JSON 且含 seen 数组", raw.contains("\"seen\"") and raw.contains("move"), raw.substr(0, 80))

	t.free()
	second.free()


func _test_reset_keeps_history() -> void:
	print("\n[重开一局]")
	var t := _make()
	t.notify("reset_x", "移动")
	_advance(t, TutorialHint.FADE_IN + 0.1)
	_check("正在显示中", t.visible)
	t.reset_session()
	_check("reset 后隐藏", not t.visible)
	_check("reset 后队列清空", t._queue.is_empty())
	_check("reset 不清历史（第二局不该重看）", t.has_seen("reset_x"))
	t.free()


func _test_clear_history() -> void:
	print("\n[重置引导]")
	var t := _make()
	t.clear_history()
	_check("clear 后历史为空", not t.has_seen("move") and not t.has_seen("pickup"))
	# 清完能重新入队
	t.notify("move", "重新教一次")
	_check("清空后可以重新提示", t._queue.size() == 1)
	# clear_history 会写盘，别把空档留给下一轮测试
	_check("已写盘", FileAccess.file_exists(TutorialHint.SAVE_PATH))
	t.free()
