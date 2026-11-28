class_name TutorialHint
extends CanvasLayer

## 局内新手引导：底部一条轻提示，按事件出现、自己消失、不拦输入。
##
## 设计上刻意避开三件事：
##
## 1. **不做全屏教程弹窗**。这是"再来一局"型游戏，玩家第二次进来时最烦的就是
##    又要关一次教程。所以提示条只占屏幕底部一条，不暂停、不拦输入，
##    玩家可以一边读一边打。
##
## 2. **不定时弹**。定时弹出来的提示经常和"此刻正在发生的事"错位
##    （比如你正在被围，它告诉你"按空格放技能"）。这里每条提示都挂在真实事件上：
##    第一次掉经验、第一次蓝满、圈第一次开始缩。
##
## 3. **不重复**。见过的条目会写进 user://tutorial.json，下一局不再出现。
##    所以这套引导对老玩家是**完全静音**的，不需要"跳过教程"按钮。
##
## 文案分键鼠 / 触屏两套：手机上没有 WASD，写"按空格"等于没写。

const SAVE_PATH: String = "user://tutorial.json"

## 提示条从出现到消失的节奏。
## 淡入要快（玩家眼睛已经在那儿了），停留要够读完 16 个字（约 2.2 秒），
## 淡出慢一点，免得像闪一下就没。
const FADE_IN: float = 0.22
const FADE_OUT: float = 0.35
## 默认停留时长。字数多的时候调用方可以传更长的。
const DEFAULT_HOLD: float = 2.4
## 两条提示之间的最短间隔：连着弹两条会让人来不及读第一条
const QUEUE_GAP: float = 0.35

## 距屏幕底部的距离（逻辑像素）。放在 12% 高度处：
## 上面避开血条和章节栏，下面避开触屏的左摇杆与右下技能键。
const BOTTOM_MARGIN: float = 66.0
## 提示条固定尺寸。不用"按内容自适应"是因为 PanelContainer 的 minimum size
## 在 Label 刚换文字的那一帧还是 0，reset_size() 会把面板算成 0x0 —— 表现是
## "代码说可见、画面上什么都没有"，极难排查。最长的一句是圈收缩提示（26 字），
## 15px 字号下约 426px，460 留了余量。
const WIDTH: float = 460.0
const HEIGHT: float = 38.0

enum Phase { IDLE, FADE_IN, HOLD, FADE_OUT }

var _root: Control
var _panel: PanelContainer
var _label: Label
var _phase: int = Phase.IDLE
var _t: float = 0.0
var _hold: float = 0.0
## 待显示的提示。每个元素 {text, hold, delay}
var _queue: Array[Dictionary] = []
## 已经展示过的条目 id。写盘后跨局生效。
var _seen: Dictionary = {}
var _seen_dirty: bool = false
## 队列空档的冷却，避免两条提示首尾相接
var _gap: float = 0.0


func _ready() -> void:
	# 跟随暂停：选卡界面不该盖着一条提示，而且暂停时提示的"读秒"也该停
	process_mode = Node.PROCESS_MODE_PAUSABLE
	# 层级要压在 HUD（CanvasLayer）和触屏层之上，否则控件虽然存在却画在它们底下去。
	# 这个 bug 的表现极具迷惑性：尺寸、坐标、alpha 全部正确，截图里什么都没有。
	layer = 3
	_load()
	_build()
	visible = false


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "HintPanel"
	# 绝对定位 + 每帧自己算坐标，不用锚点。
	# 试过 PRESET_BOTTOM_WIDE：Control 的父节点是 Node 而不是 Control 时，
	# 锚点要等容器完成一次布局才有效，_ready 里设出来的位置会落在屏幕中间。
	# 这个提示条一共就一个元素，自己算比跟布局系统较劲可靠。
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var style := StyleBoxFlat.new()
	# 深底 + 细边：压在战场上必须能读清字，又不能亮到抢视线
	style.bg_color = Color(0.055, 0.07, 0.105, 0.86)
	style.border_color = Color(0.46, 0.62, 0.92, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.set_content_margin_all(10)
	style.content_margin_left = 18
	style.content_margin_right = 18
	_panel.add_theme_stylebox_override("panel", style)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_root.add_child(_panel)

	_label = Label.new()
	_label.add_theme_font_override("font", UiKit.font())
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)


## 请求显示一条提示。同一个 id 只会出现一次（跨局记忆）。
##
## id      稳定标识，存盘用。改文案不用改 id，否则老玩家会重看一遍。
## keys    键鼠文案
## touch   触屏文案（和键鼠不同时才需要传）
## hold    停留秒数，0 用默认
## delay   延迟多少秒后才进入队列（开局提示要等镜头稳下来）
func notify(id: String, keys: String, touch: String = "", hold: float = 0.0, delay: float = 0.0) -> void:
	if _seen.has(id):
		return
	_seen[id] = true
	_seen_dirty = true
	var text: String = touch if (_touch_mode() and not touch.is_empty()) else keys
	if text.is_empty():
		return
	_queue.append({
		"text": text,
		"hold": hold if hold > 0.0 else DEFAULT_HOLD,
		"delay": maxf(delay, 0.0),
	})


## 开局前清空运行时状态，但**保留**已看过的记录——
## 这是"第二次进游戏不再啰嗦"的实现点。
func reset_session() -> void:
	_queue.clear()
	_phase = Phase.IDLE
	_gap = 0.0
	visible = false
	_root.modulate.a = 0.0


func _process(delta: float) -> void:
	# 延迟到期的提示才进队：延迟期间不该占用显示窗口
	for i in range(_queue.size() - 1, -1, -1):
		_queue[i]["delay"] = float(_queue[i]["delay"]) - delta
		if float(_queue[i]["delay"]) <= 0.0:
			_queue[i]["delay"] = 0.0

	if _gap > 0.0:
		_gap = maxf(_gap - delta, 0.0)

	match _phase:
		Phase.IDLE:
			if _queue.is_empty() or _gap > 0.0:
				return
			var item: Dictionary = _queue[0]
			if float(item["delay"]) > 0.0:
				return
			_queue.pop_front()
			_label.text = str(item["text"])
			_layout()
			_hold = float(item["hold"])
			_phase = Phase.FADE_IN
			_t = 0.0
			visible = true
			_root.modulate.a = 0.0
		Phase.FADE_IN:
			# 每帧重算位置：Label 刚换过文字，第一帧的 minimum size 还是旧值，
			# 只算一次会把面板摆成 0 尺寸（看起来就是"什么都没出现"）。
			# 淡入只有 0.22 秒，这几帧重算的代价可以忽略。
			_layout()
			_t += delta
			_root.modulate.a = clampf(_t / FADE_IN, 0.0, 1.0)
			if _t >= FADE_IN:
				_phase = Phase.HOLD
				_t = 0.0
		Phase.HOLD:
			_t += delta
			if _t >= _hold:
				_phase = Phase.FADE_OUT
				_t = 0.0
		Phase.FADE_OUT:
			_t += delta
			_root.modulate.a = 1.0 - clampf(_t / FADE_OUT, 0.0, 1.0)
			if _t >= FADE_OUT:
				_phase = Phase.IDLE
				visible = false
				_root.modulate.a = 0.0
				_gap = QUEUE_GAP


## 摆到"屏幕底部居中"。每次显示前重算：旋转屏幕、换分辨率、窗口拉伸之后
## 视口尺寸会变，缓存一次坐标就会错位。
func _layout() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# 先让 PanelContainer 缩到内容大小，否则读到的是上一句的宽度
	_panel.size = Vector2(WIDTH, HEIGHT)
	_panel.position = Vector2(
		(vp.x - WIDTH) * 0.5,
		vp.y - BOTTOM_MARGIN - HEIGHT,
	)


## 触屏判断直接问 HUD 那一套实现，避免两处判断标准不一致
## （HUD 已经在用的那个判断考虑了 viewport 宽度，这里不该另写一套）。
func _touch_mode() -> bool:
	return TouchControls.is_touch_device()


func has_seen(id: String) -> bool:
	return _seen.has(id)


## 只在真正退出时写盘：每显示一条就写一次会把 user:// 写得很频繁，
## Web 上每次写都要过 IndexedDB，没必要。
func flush() -> void:
	if not _seen_dirty:
		return
	_seen_dirty = false
	var ids: Array = _seen.keys()
	ids.sort()
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"seen": ids}, "\t"))
	f.close()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		flush()


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var raw: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var ids: Variant = (parsed as Dictionary).get("seen", [])
	if typeof(ids) != TYPE_ARRAY:
		return
	for id in (ids as Array):
		_seen[str(id)] = true


## 测试与"重置新手引导"用
func clear_history() -> void:
	_seen.clear()
	_seen_dirty = true
	flush()
