class_name StartMenu
extends CanvasLayer

## 开局菜单：选职业 + 选难度 + 输入昵称，或直接点选本机已有玩家。
## process_mode = ALWAYS，所以 get_tree().paused 时仍能打字、点按钮。
## 只负责收集"昵称 + 职业 + 难度"，通过 started 信号回传给 Game，不碰任何游戏规则。

signal started(player_name: String, hero: int, difficulty: int)

const PANEL_WIDTH: float = 640.0
## 面板上下与视口边缘的最小留白。面板高度 = 视口高 - 2×这个值，
## 内容超出时靠 ScrollContainer 滚动——以前面板被内容撑到 825px，
## 桌面 720 裁掉音效开关，触屏 540 连"开始游戏"都看不见（11/28 加难度行时实测）。
const PANEL_MARGIN: float = 12.0
## 榜单最多显示几条，避免玩家人数过多把面板撑出屏幕
const MAX_ROWS: int = 4

## 昵称框右侧的兜底按钮：万一某个浏览器没实现软键盘（Web 导出必须打开
## html/experimental_virtual_keyboard，否则 FEATURE_VIRTUAL_KEYBOARD 一直是 false），
## 玩家至少还能抽一个名字开局，不会卡在起名这一步。
const RANDOM_NAMES: Array[String] = ["守夜人", "拾骨者", "潮汐", "锈剑", "灯奴", "深潜者", "夜巡", "残灯"]

var _root: Control
var _panel: PanelContainer
var _box: VBoxContainer
var _input: LineEdit
var _random_btn: Button
var _list: VBoxContainer
var _empty_label: Label
var _desc_label: Label
var _class_buttons: Array[Button] = []
var _difficulty_buttons: Array[Button] = []
var _difficulty_desc: Label
var _difficulty: int = Difficulty.DEFAULT
var _hero: int = HeroClass.WARRIOR
## 触屏模式下换操作说明，并且不自动抢焦点（一进菜单就弹软键盘会挡住半屏）
var _touch_mode: bool = false
var _hint: Label
## 音效总控，由 Game 注入。菜单是玩家第一个能点到东西的地方，
## 点击没有声音会显得"没接上"，所以这里的按钮要自己出声。
var audio: GameAudio = null
var _mute_btn: Button
## 防止一次点击里 emit 两次（连点 / 回车混用）导致重复开局
var _locked: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	close()


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.9)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	# 面板不再用 CenterContainer 撑内容：高度固定为"视口 - 留白"，超出滚动。
	# 锚点写死左右半宽居中、上下贴边，视口怎么变（旋转 / 浏览器拖拽）都不会被裁。
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_WIDTH * 0.5
	_panel.offset_right = PANEL_WIDTH * 0.5
	_panel.offset_top = PANEL_MARGIN
	_panel.offset_bottom = -PANEL_MARGIN
	var panel_style := UiKit.panel_style(Color(0.55, 0.75, 1.0, 0.85))
	panel_style.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", panel_style)
	_root.add_child(_panel)

	# 内容包一层滚动：触屏 540 逻辑高度下，榜单和音效开关要滚一屏才能看到，
	# 但"开始游戏"必须第一眼就在屏内（见内容压缩各处的注释）。
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_panel.add_child(scroll)

	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 7)
	scroll.add_child(_box)

	var title := UiKit.label("暗夜幸存者", 26, Color(1.0, 0.92, 0.6))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(title)

	# 剧情的第一句放在菜单里。玩家点"开始"之前就该知道自己是王子、
	# 被关在城堡里——否则第一屏剧情会像是另一个游戏的开场。
	# （原来的独立副标题"王子 · 黑暗城堡 · 十道门"与这句重复，压缩高度时删掉。）
	var premise := UiKit.label(Story.prologue(), 12, Color(0.74, 0.68, 0.84))
	premise.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	premise.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	premise.custom_minimum_size = Vector2(PANEL_WIDTH - 44, 0)
	_box.add_child(premise)

	# 一局的结构直接写在这里，而不是塞一段教程：玩家在菜单停留的时间最长，
	# 一行字就能回答"这游戏要打到哪一步算赢"。没有这句话时，
	# 试玩反馈里"规则不清晰"说的正是"不知道自己在往哪打"。
	var route := UiKit.label("穿过十道门 · 王座厅连战五位守门人 · 走出西门即逃离", 12, Color(0.6, 0.74, 0.68))
	route.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(route)

	# 门的选择决定结局这件事，必须在菜单就说一次。
	# 只写在结算里的话，玩家会以为那五个结局是随机给的——
	# 而"我这一局一直在拿双卡"这种"我选的"感觉，才是二周目的理由。
	var endings_line := UiKit.label("每一道门怎么选，决定门外是哪一种结局（共 %d 种）"
		% Story.ending_order().size(), 12, Color(0.78, 0.70, 0.86))
	endings_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(endings_line)

	_box.add_child(UiKit.divider())
	_build_class_picker()

	_box.add_child(UiKit.divider())
	_build_difficulty_picker()

	_box.add_child(UiKit.divider())
	_build_columns()

	_box.add_child(UiKit.divider())

	var hint := UiKit.label(_hint_text(), 13, Color(0.6, 0.67, 0.8))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(hint)
	_hint = hint

	_build_mute_toggle()
	_select_hero(HeroClass.WARRIOR)
	_select_difficulty(_difficulty)


## 音效开关。放在菜单而不是战斗中：战斗里没人会停下来找静音键，
## 而外放玩游戏的人第一次进菜单就需要它能关。
## 用 Button 而不是 CheckBox，是为了和整个菜单的视觉一致（CheckBox 会带一套系统样式）。
func _build_mute_toggle() -> void:
	_mute_btn = Button.new()
	_mute_btn.focus_mode = Control.FOCUS_NONE
	_mute_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_mute_btn.flat = true
	_mute_btn.add_theme_font_override("font", UiKit.font())
	_mute_btn.add_theme_font_size_override("font_size", 12)
	_mute_btn.add_theme_color_override("font_color", Color(0.55, 0.62, 0.76))
	_mute_btn.add_theme_color_override("font_hover_color", Color(0.78, 0.85, 0.96))
	_mute_btn.pressed.connect(_on_mute_pressed)
	_box.add_child(_mute_btn)
	_refresh_mute_text()


func _refresh_mute_text() -> void:
	if _mute_btn == null:
		return
	var muted: bool = audio != null and audio.is_muted()
	_mute_btn.text = "音效：关（点击开启）" if muted else "音效：开（点击关闭）"


func _on_mute_pressed() -> void:
	if audio == null:
		return
	# 先切换再播音：静音时切换成"开"要立刻听到一声确认，
	# 切换成"关"时这一声会被 _muted 挡住——两种情况的听感都正确。
	audio.toggle_muted()
	audio.play("ui")
	_refresh_mute_text()


func _ui_sound() -> void:
	if audio != null:
		audio.play("ui")


func _hint_text() -> String:
	if _touch_mode:
		return "左侧拖动移动 · 自动攻击 · 右下角放技能 · 升级点卡片\n结算页可直接再来一局或换人"
	return "WASD / 方向键移动 · 自动攻击 · 空格放技能 · 升级点击卡片\n死亡后 R 再来一局 · P 换人 · M 静音"


## 三张职业卡 + 下方一句说明。说明跟着选择切换，而不是三张卡各写一段——
## 卡片里塞不下 30 个字，写小了看不清，写大了撑破布局。
func _build_class_picker() -> void:
	var caption := UiKit.label("选择职业", 14, Color(0.72, 0.8, 0.92))
	_box.add_child(caption)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_box.add_child(row)
	for i in range(HeroClass.COUNT):
		row.add_child(_make_class_button(i))

	_desc_label = UiKit.label("", 12, Color(0.8, 0.86, 0.96))
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.custom_minimum_size = Vector2(0, 30)
	_box.add_child(_desc_label)


## 难度三选一。做成一行三个小按钮 + 一行说明，而不是三张职业卡那种大卡：
## 菜单在触屏上只有 540 逻辑高度，职业卡那 74px 再来一份会把"开始游戏"顶出屏幕。
## 说明行跟着选择切换（和职业说明同一个思路），不占三份固定高度。
func _build_difficulty_picker() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_box.add_child(row)
	for i in range(Difficulty.COUNT):
		row.add_child(_make_difficulty_button(i))

	_difficulty_desc = UiKit.label("", 12, Color(0.72, 0.80, 0.94))
	_difficulty_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_difficulty_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_difficulty_desc.custom_minimum_size = Vector2(0, 18)
	_box.add_child(_difficulty_desc)


func _make_difficulty_button(index: int) -> Button:
	var button := Button.new()
	button.text = Difficulty.name_of(index)
	button.custom_minimum_size = Vector2(0, 32)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.tooltip_text = Difficulty.desc_of(index)
	button.add_theme_font_override("font", UiKit.font())
	button.add_theme_font_size_override("font_size", 15)
	button.pressed.connect(_ui_sound)
	button.pressed.connect(_select_difficulty.bind(index))
	_difficulty_buttons.append(button)
	return button


func _style_difficulty_button(button: Button, index: int, selected: bool) -> void:
	var color: Color = Difficulty.color_of(index)
	var bg: Color = Color(0.17, 0.20, 0.28) if selected else Color(0.08, 0.10, 0.15)
	var border: Color = color if selected else Color(1.0, 1.0, 1.0, 0.12)
	button.add_theme_stylebox_override("normal", UiKit.flat(bg, border, 8, 2 if selected else 1))
	button.add_theme_stylebox_override("hover", UiKit.flat(Color(0.19, 0.23, 0.31), color, 8, 2))
	button.add_theme_stylebox_override("pressed", UiKit.flat(Color(0.23, 0.27, 0.36), color, 8, 2))
	button.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0) if selected else Color(0.6, 0.67, 0.8))


func _select_difficulty(index: int) -> void:
	_difficulty = Difficulty.clamp_index(index)
	for i in range(_difficulty_buttons.size()):
		_style_difficulty_button(_difficulty_buttons[i], i, i == _difficulty)
	if _difficulty_desc != null:
		_difficulty_desc.text = "难度：%s —— %s" % [
			Difficulty.name_of(_difficulty), Difficulty.desc_of(_difficulty)]


## 左列放输入与开始按钮，右列放战绩榜：竖着排会超出 648 的画面高度
func _build_columns() -> void:
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 18)
	_box.add_child(columns)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	columns.add_child(left)

	var name_caption := UiKit.label("昵称（读取你自己的历史最高分）", 13, Color(0.8, 0.86, 0.96))
	left.add_child(name_caption)

	_input = LineEdit.new()
	_input.max_length = ScoreBoard.MAX_NAME_LENGTH
	_input.placeholder_text = "昵称（最多 %d 字）" % ScoreBoard.MAX_NAME_LENGTH
	_input.custom_minimum_size = Vector2(0, 42)
	_input.add_theme_font_override("font", UiKit.font())
	_input.add_theme_font_size_override("font_size", 19)
	_input.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_input.add_theme_color_override("font_placeholder_color", Color(0.5, 0.57, 0.68))
	_input.add_theme_color_override("caret_color", Color(1.0, 0.9, 0.6))
	var input_normal := UiKit.flat(Color(0.1, 0.13, 0.19), Color(1.0, 1.0, 1.0, 0.18), 8, 1)
	input_normal.content_margin_left = 14.0
	input_normal.content_margin_right = 14.0
	var input_focus := UiKit.flat(Color(0.12, 0.16, 0.23), Color(0.55, 0.75, 1.0, 0.9), 8, 2)
	input_focus.content_margin_left = 14.0
	input_focus.content_margin_right = 14.0
	_input.add_theme_stylebox_override("normal", input_normal)
	_input.add_theme_stylebox_override("focus", input_focus)
	_input.text_submitted.connect(_on_submitted)
	_input.gui_input.connect(_on_name_gui_input)

	# 输入框与兜底按钮并排；按钮平时隐藏，只在"没有软键盘可用"的设备上才出现
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	left.add_child(name_row)
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_input)
	_random_btn = _make_random_name_button()
	name_row.add_child(_random_btn)

	left.add_child(_make_start_button())

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(252, 0)
	right.add_theme_constant_override("separation", 6)
	columns.add_child(right)

	right.add_child(UiKit.label("本机战绩", 13, Color(0.62, 0.7, 0.84)))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 5)
	right.add_child(_list)
	_empty_label = UiKit.label("还没有任何记录，你将是第一个。", 13, Color(0.55, 0.62, 0.74))
	_list.add_child(_empty_label)


func _make_class_button(index: int) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 64)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_ui_sound)
	button.pressed.connect(_select_hero.bind(index))

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	button.add_child(box)

	var name_label := UiKit.label(HeroClass.NAMES[index], 21, HeroClass.color(index))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var role_label := UiKit.label(HeroClass.ROLES[index], 12, Color(0.7, 0.77, 0.9))
	role_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	role_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(role_label)

	_class_buttons.append(button)
	return button


## 选中态靠边框颜色 + 提亮底色，不用额外图标：三职业的配色本来就不一样，
## 一眼能对上"刚才点了哪个"。
func _style_class_button(button: Button, index: int, selected: bool) -> void:
	var color: Color = HeroClass.color(index)
	var bg: Color = Color(0.17, 0.20, 0.28) if selected else Color(0.08, 0.10, 0.15)
	var border: Color = color if selected else Color(1.0, 1.0, 1.0, 0.12)
	var width: int = 2 if selected else 1
	button.add_theme_stylebox_override("normal", UiKit.flat(bg, border, 10, width))
	button.add_theme_stylebox_override("hover", UiKit.flat(Color(0.19, 0.23, 0.31), color, 10, 2))
	button.add_theme_stylebox_override("pressed", UiKit.flat(Color(0.23, 0.27, 0.36), color, 10, 2))


func _make_start_button() -> Button:
	var button := Button.new()
	button.text = "开始游戏"
	button.custom_minimum_size = Vector2(0, 46)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UiKit.font())
	button.add_theme_font_size_override("font_size", 20)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(key, Color(0.06, 0.08, 0.12))
	button.add_theme_stylebox_override("normal", UiKit.flat(Color(1.0, 0.85, 0.48), Color(1.0, 0.9, 0.6), 10, 0))
	button.add_theme_stylebox_override("hover", UiKit.flat(Color(1.0, 0.9, 0.62), Color(1.0, 0.95, 0.75), 10, 0))
	button.add_theme_stylebox_override("pressed", UiKit.flat(Color(0.9, 0.74, 0.4), Color(1.0, 0.9, 0.6), 10, 0))
	button.pressed.connect(_ui_sound)
	button.pressed.connect(_on_start_pressed)
	return button


func _make_random_name_button() -> Button:
	var button := Button.new()
	button.text = "随机"
	button.custom_minimum_size = Vector2(72, 42)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.visible = false
	button.add_theme_font_override("font", UiKit.font())
	button.add_theme_font_size_override("font_size", 16)
	for key in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(key, Color(0.86, 0.92, 1.0))
	button.add_theme_stylebox_override("normal", UiKit.flat(Color(0.13, 0.17, 0.24), Color(1.0, 1.0, 1.0, 0.22), 8, 1))
	button.add_theme_stylebox_override("hover", UiKit.flat(Color(0.18, 0.23, 0.32), Color(0.55, 0.75, 1.0, 0.8), 8, 1))
	button.add_theme_stylebox_override("pressed", UiKit.flat(Color(0.22, 0.28, 0.38), Color(0.55, 0.75, 1.0, 0.9), 8, 1))
	button.pressed.connect(_ui_sound)
	button.pressed.connect(_on_random_name)
	return button


## 点输入框必须主动请求软键盘。Web 导出如果没打开 html/experimental_virtual_keyboard，
## DisplayServer 根本不实现 FEATURE_VIRTUAL_KEYBOARD，键盘永远不出现（试玩反馈的根因）。
## 请求要写在同一次输入事件里：等下一帧再调，iOS 会判成"非用户手势"直接拒绝。
func _on_name_gui_input(event: InputEvent) -> void:
	var tapped: bool = false
	var touch := event as InputEventScreenTouch
	if touch != null:
		tapped = touch.pressed
	var mouse := event as InputEventMouseButton
	if mouse != null:
		tapped = mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT
	if not tapped:
		return
	_input.grab_focus()
	_input.select_all()
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_show(
			_input.text,
			Rect2(_input.get_screen_position(), _input.size),
			DisplayServer.KEYBOARD_TYPE_DEFAULT,
			_input.max_length,
		)


func _on_random_name() -> void:
	var name: String = RANDOM_NAMES[randi() % RANDOM_NAMES.size()]
	_input.text = ScoreBoard.sanitize("%s%02d" % [name, randi_range(2, 99)])
	_input.caret_column = _input.text.length()


# ---------------------------------------------------------------- 对外接口

func open(default_name: String, players: Array[Dictionary], hero: int = HeroClass.WARRIOR,
		touch: bool = false, difficulty: int = Difficulty.DEFAULT) -> void:
	_locked = false
	_touch_mode = touch
	_root.visible = true
	if _hint != null:
		_hint.text = _hint_text()
	_refresh(players)
	_select_hero(hero)
	_select_difficulty(difficulty)
	_input.text = default_name
	# 没有软键盘可用时才亮出"随机"按钮，正常桌面端和开了软键盘的手机都看不到它
	if _random_btn != null:
		_random_btn.visible = _touch_mode and not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD)
	# 触屏上不抢焦点：点输入框时系统才弹软键盘，否则一进菜单半个屏幕都是键盘
	if not _touch_mode:
		# 预选整段，直接打字即覆盖旧昵称
		_input.grab_focus()
		_input.select_all()


func close() -> void:
	_root.visible = false
	_input.release_focus()
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()


func is_open() -> bool:
	return _root.visible


# ---------------------------------------------------------------- 内部

func _select_hero(index: int) -> void:
	_hero = clampi(index, 0, HeroClass.COUNT - 1)
	for i in range(_class_buttons.size()):
		_style_class_button(_class_buttons[i], i, i == _hero)
	_desc_label.text = "%s\n主动技能「%s」：%s" % [
		HeroClass.DESCS[_hero],
		HeroClass.skill_name(_hero),
		HeroClass.SKILL_DESCS[_hero],
	]


func _refresh(players: Array[Dictionary]) -> void:
	for child in _list.get_children():
		if child == _empty_label:
			continue
		_list.remove_child(child)
		child.queue_free()
	_empty_label.visible = players.is_empty()

	var rows: int = mini(players.size(), MAX_ROWS)
	for i in range(rows):
		_list.add_child(_make_row(i + 1, players[i]))


func _make_row(rank: int, entry: Dictionary) -> Button:
	var player_name: String = str(entry["name"])

	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 34)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_stylebox_override("normal", UiKit.flat(Color(0.1, 0.13, 0.19), Color(1.0, 1.0, 1.0, 0.08), 8, 1))
	button.add_theme_stylebox_override("hover", UiKit.flat(Color(0.16, 0.21, 0.29), Color(0.55, 0.75, 1.0, 0.75), 8, 1))
	button.add_theme_stylebox_override("pressed", UiKit.flat(Color(0.2, 0.26, 0.35), Color(0.55, 0.75, 1.0, 0.9), 8, 2))
	button.pressed.connect(_ui_sound)
	button.pressed.connect(_start_with.bind(player_name))

	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10.0
	row.offset_right = -10.0
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	button.add_child(row)

	var rank_label := UiKit.label("%d" % rank, 12, Color(0.55, 0.62, 0.74))
	rank_label.custom_minimum_size = Vector2(16, 0)
	rank_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(rank_label)

	var name_label := UiKit.label(player_name, 15, Color(0.94, 0.96, 1.0))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var score_label := UiKit.label("最高 %d" % int(entry["score"]), 15, Color(1.0, 0.9, 0.58))
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(score_label)

	var runs_label := UiKit.label("%d 局" % int(entry["runs"]), 11, Color(0.58, 0.65, 0.78))
	runs_label.custom_minimum_size = Vector2(42, 0)
	runs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	runs_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(runs_label)
	return button


func _start_with(raw: String) -> void:
	if _locked or not _root.visible:
		return
	_locked = true
	# 只在真的开局时才写存档：光在菜单里点来点去不该改"上次选择"，
	# 否则玩家点开菜单、换了个档又退出，下次进来看到的就不是上次玩的那一档了。
	ScoreBoard.set_last_difficulty(_difficulty)
	started.emit(ScoreBoard.sanitize(raw), _hero, _difficulty)


func _on_start_pressed() -> void:
	_start_with(_input.text)


func _on_submitted(text: String) -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()
	_start_with(text)
