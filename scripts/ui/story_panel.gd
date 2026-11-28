class_name StoryPanel
extends Control

## 剧情屏：开场与每次穿门之后各放一次，可以跳过。
##
## 三个必须做对的地方：
## 1. **跳过键在右上角**，固定位置、固定大小。剧情一局要弹十次，
##    玩家第二次就会开始找"怎么过快点"——找不到就会开始烦。
## 2. **逐字显示 + 点击加速**。纯静态文字在手机上像一张 PPT；
##    逐字给的是节奏，而"顺手点一下就能立刻看完"给的是控制权。
## 3. **暂停必须走 Game 的 _sync_pause()**。这一屏显示期间世界是冻结的，
##    但本节点自己的 process_mode 是 ALWAYS，否则动画和点击都会跟着冻住。

signal finished(skipped: bool)

## 逐字速度（字/秒）。46 是"看得清、又不至于等"的落点：
## 一行 18 字大约 0.4 秒出完，读得比它快的人会点，读得慢的人刚好跟上。
const CHARS_PER_SEC: float = 46.0
## 一行显示完之后自动进下一行的等待。给 2.6 秒：
## 比读完略长一点，玩家不用抢；想快的随时点。
const LINE_HOLD: float = 2.6
## 换行之间的停顿。逐字之间已经有节奏，行间再停太久会显得卡。
const LINE_GAP: float = 0.18

const BOX_WIDTH: float = 620.0
const SKIP_SIZE: Vector2 = Vector2(78.0, 38.0)
const SKIP_MARGIN: float = 22.0

## 触屏上整体放大一档。1280×720 的设计稿放到手机横屏（约 844×390）上要压掉一半，
## 19 号正文落到屏幕上只剩 11 号字——剧情屏存在的意义就是让人读，读不动就白做了。
## 不加这一档，跳过键的可点区域也从 44pt 缩到不足 20pt，拇指按不准。
const TOUCH_SCALE: float = 1.28

var _s: float = 1.0
var _touch: bool = false
## 自检用：强制按触屏排版（true）或强制按桌面排版（false）。null = 按设备自动判断。
## 必须在 add_child 之前赋值——_ready 里就把尺寸算死了。
var force_touch: Variant = null
var _box: VBoxContainer
var _ordinal: Label
var _title: Label
var _rule: ColorRect
var _body: VBoxContainer
var _hint: Label
var _skip_btn: Button

var _lines: Array[String] = []
var _line_labels: Array[Label] = []
var _index: int = 0
var _reveal: float = 0.0
var _hold: float = 0.0
var _gap: float = 0.0
var _open: bool = false
var _tint: Color = Color(0.72, 0.80, 0.94)
var _torch: float = 0.0


func _ready() -> void:
	# 剧情屏出现时整棵树是暂停的：自己的动画与点击必须照常跑
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_touch = force_touch if force_touch != null else TouchControls.is_touch_device()
	_s = TOUCH_SCALE if _touch else 1.0
	_build()


func _build() -> void:
	# 不铺一层 ColorRect 做底：子节点在父节点之后绘制，
	# 一层不透明底板会把 _draw 里的烛光与城堡剪影整个盖掉（第一版就是这样，
	# 截图里只剩一块纯黑）。底色由 _draw 自己画，装饰才有地方落。

	# 正文整体垂直居中。用 CenterContainer 而不是手算 offset：
	# 台词行数会变（2~4 行），手算的话每一幕都要对一次。
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_box = VBoxContainer.new()
	_box.custom_minimum_size = Vector2(BOX_WIDTH * _s, 0.0)
	_box.add_theme_constant_override("separation", int(10.0 * _s))
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_box)

	_ordinal = UiKit.label("", int(16.0 * _s), Color(0.62, 0.72, 0.86))
	_ordinal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(_ordinal)

	_title = UiKit.label("", int(34.0 * _s), Color(0.98, 0.94, 0.86))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(_title)

	# 标题下的一条细金线：这一屏没有别的装饰，一条线就够了——
	# 它把"标题"和"台词"分成两块，视线不会一路滑到屏幕底部。
	_rule = ColorRect.new()
	_rule.color = Color(0.86, 0.72, 0.42, 0.55)
	_rule.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_rule.custom_minimum_size = Vector2(180.0 * _s, 2.0)
	_box.add_child(_rule)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 14.0 * _s)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(spacer)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", int(12.0 * _s))
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(_body)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0.0, 22.0 * _s)
	spacer2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(spacer2)

	_hint = UiKit.label("", int(13.0 * _s), Color(0.60, 0.68, 0.80))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(_hint)

	# 跳过：右上角，固定尺寸。位置用锚点写死，不跟着正文的排版走。
	_skip_btn = Button.new()
	_skip_btn.text = "跳过"
	_skip_btn.custom_minimum_size = SKIP_SIZE * _s
	_skip_btn.focus_mode = Control.FOCUS_NONE
	_skip_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_skip_btn.add_theme_font_override("font", UiKit.font())
	_skip_btn.add_theme_font_size_override("font_size", int(15.0 * _s))
	for key in ["font_color", "font_hover_color", "font_pressed_color"]:
		_skip_btn.add_theme_color_override(key, Color(0.08, 0.10, 0.15))
	var accent := Color(0.86, 0.74, 0.48)
	_skip_btn.add_theme_stylebox_override("normal", UiKit.flat(accent, accent.lightened(0.30), 9, 0))
	_skip_btn.add_theme_stylebox_override("hover", UiKit.flat(accent.lightened(0.12), accent.lightened(0.45), 9, 0))
	_skip_btn.add_theme_stylebox_override("pressed", UiKit.flat(accent.darkened(0.14), accent.lightened(0.28), 9, 0))
	var margin: float = SKIP_MARGIN * _s
	var skip_size := SKIP_SIZE * _s
	_skip_btn.anchor_left = 1.0
	_skip_btn.anchor_right = 1.0
	_skip_btn.anchor_top = 0.0
	_skip_btn.anchor_bottom = 0.0
	_skip_btn.offset_left = -margin - skip_size.x
	_skip_btn.offset_right = -margin
	_skip_btn.offset_top = margin
	_skip_btn.offset_bottom = margin + skip_size.y
	_skip_btn.pressed.connect(skip)
	add_child(_skip_btn)

	resized.connect(_on_resized)
	queue_redraw()


## 播一幕。lines 为空时立刻结束，不让 Game 卡在一个空屏上。
## 参数用 Array 而不是 Array[String]：调用方传的是 Story 表里的常量数组，
## 那是无类型 Array，直接传给 Array[String] 在运行时会报类型错误。
func play(lines: Array, title_text: String, ordinal_text: String, tint: Color) -> void:
	_open = true
	_lines.clear()
	for line in lines:
		_lines.append(str(line))
	_tint = tint
	_index = 0
	_reveal = 0.0
	_hold = 0.0
	_gap = 0.0
	visible = true
	_ordinal.text = ordinal_text
	_ordinal.add_theme_color_override("font_color", Color(tint.r, tint.g, tint.b, 0.92))
	_title.text = title_text
	_rule.color = Color(tint.r, tint.g, tint.b, 0.55)
	_skip_btn.disabled = false
	_skip_btn.visible = true
	# 手机上没有空格键：提示按设备换一句，别让触屏玩家去找一个不存在的键
	_hint.text = ("点一下继续　·　右上角可跳过" if _touch
		else "点击 或 空格 继续　·　右上角可跳过")
	for label in _line_labels:
		label.queue_free()
	_line_labels.clear()
	for line in _lines:
		var node := UiKit.label("", int(19.0 * _s), Color(0.88, 0.90, 0.95))
		node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		node.custom_minimum_size = Vector2(BOX_WIDTH * _s, 0.0)
		_body.add_child(node)
		_line_labels.append(node)
	set_process(true)
	queue_redraw()
	if _lines.is_empty():
		_finish(false)


func is_open() -> bool:
	return _open


## 点一下 / 按空格：还没显示完就立刻显示完，显示完就进下一行。
func advance() -> void:
	if not _open or _line_labels.is_empty():
		return
	var line: String = _lines[_index]
	if _reveal < float(line.length()):
		_reveal = float(line.length())
		_line_labels[_index].text = line
		_hold = 0.0
		return
	_next_line()


## 跳过整幕。整局十次剧情，跳过必须是"一次点击就到底"，
## 而不是"跳到下一行"——那样玩家要点十几次。
func skip() -> void:
	if not _open:
		return
	_finish(true)


func _next_line() -> void:
	if _index + 1 >= _lines.size():
		_finish(false)
		return
	_index += 1
	_reveal = 0.0
	_hold = 0.0
	_gap = LINE_GAP


func _finish(skipped: bool) -> void:
	if not _open:
		return
	_open = false
	visible = false
	set_process(false)
	finished.emit(skipped)


func _process(delta: float) -> void:
	if not _open:
		return
	_torch += delta
	if _line_labels.is_empty():
		return
	var line: String = _lines[_index]
	var label: Label = _line_labels[_index]

	if _gap > 0.0:
		_gap = maxf(_gap - delta, 0.0)
		return

	var total: int = line.length()
	if _reveal < float(total):
		_reveal = minf(_reveal + CHARS_PER_SEC * delta, float(total))
		var shown: int = int(_reveal)
		label.text = line.substr(0, shown)
		if shown >= total:
			_hold = 0.0
		queue_redraw()
		return

	# 这一行已经完整显示：按住一会儿自动进下一行
	_hold += delta
	if _hold >= LINE_HOLD:
		_next_line()


func _gui_input(event: InputEvent) -> void:
	if not _open:
		return
	# 鼠标与触摸都走这里：手机上点屏幕等于"继续"，
	# 而不是像快捷键那样需要键盘
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			advance()
			accept_event()


func _on_resized() -> void:
	queue_redraw()


## 背板：一层近黑的底 + 远处的城堡剪影 + 三点烛光。
## 全部用 draw_ 画，不引贴图：这一屏要能在一局里反复出现十次，
## 每次加载一张 1080p 背景图，内存和加载时间都不划算。
func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.015, 0.02, 0.03, 1.0))

	# 烛光：三团极暗的暖色，位置偏上，像走廊尽头
	var torches: Array[Vector2] = [
		Vector2(w * 0.18, h * 0.24),
		Vector2(w * 0.50, h * 0.16),
		Vector2(w * 0.82, h * 0.24),
	]
	for i in range(torches.size()):
		var flick: float = 0.86 + 0.14 * sin(_torch * 2.1 + float(i) * 2.3)
		for k in range(5):
			var r: float = (78.0 + float(k) * 46.0) * flick
			var a: float = (0.030 - float(k) * 0.005) * flick
			draw_circle(torches[i], r, Color(_tint.r, _tint.g * 0.86, _tint.b * 0.7, maxf(a, 0.0)))

	# 城堡剪影：一排锯齿 + 两座塔，压在最下方 18%。
	# alpha 比背景亮一点点就够——它是"我还在城堡里"的暗示，不是插画。
	var silhouette := Color(0.045, 0.052, 0.072, 0.95)
	var base_y: float = h * 0.86
	draw_rect(Rect2(Vector2(0.0, base_y), Vector2(w, h - base_y)), silhouette)
	var teeth: int = 26
	var tooth_w: float = w / float(teeth)
	for i in range(teeth):
		if i % 2 == 0:
			var x: float = float(i) * tooth_w
			draw_rect(Rect2(Vector2(x, base_y - 16.0), Vector2(tooth_w, 16.0)), silhouette)
	for tower in [0.12, 0.88]:
		var tx: float = w * tower
		draw_rect(Rect2(Vector2(tx - 26.0, base_y - 96.0), Vector2(52.0, 96.0)), silhouette)
		for j in range(3):
			draw_rect(Rect2(Vector2(tx - 26.0 + float(j) * 18.0, base_y - 110.0),
				Vector2(10.0, 14.0)), silhouette)
