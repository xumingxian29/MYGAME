class_name StartMenu
extends CanvasLayer

## 开局菜单：选职业 + 输入昵称，或直接点选本机已有玩家。
## process_mode = ALWAYS，所以 get_tree().paused 时仍能打字、点按钮。
## 只负责收集"昵称 + 职业"，通过 started 信号回传给 Game，不碰任何游戏规则。

signal started(player_name: String, hero: int)

const PANEL_WIDTH: float = 640.0
## 榜单最多显示几条，避免玩家人数过多把面板撑出屏幕
const MAX_ROWS: int = 6

var _root: Control
var _panel: PanelContainer
var _box: VBoxContainer
var _input: LineEdit
var _list: VBoxContainer
var _empty_label: Label
var _desc_label: Label
var _class_buttons: Array[Button] = []
var _hero: int = HeroClass.WARRIOR
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

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var panel_style := UiKit.panel_style(Color(0.55, 0.75, 1.0, 0.85))
	panel_style.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(_panel)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 8)
	_panel.add_child(_box)

	var title := UiKit.label("暗夜幸存者", 34, Color(1.0, 0.92, 0.6))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(title)

	var subtitle := UiKit.label("选择职业 · 躲避怪潮 · 升级强化", 13, Color(0.68, 0.76, 0.9))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(subtitle)

	_box.add_child(UiKit.divider())
	_build_class_picker()

	_box.add_child(UiKit.divider())
	_build_columns()

	_box.add_child(UiKit.divider())

	var hint := UiKit.label(
		"WASD / 方向键移动 · 自动攻击 · 空格放技能 · 升级点击卡片\n死亡后 R 再来一局 · P 换人",
		13, Color(0.6, 0.67, 0.8),
	)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box.add_child(hint)

	_select_hero(HeroClass.WARRIOR)


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

	_desc_label = UiKit.label("", 13, Color(0.8, 0.86, 0.96))
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.custom_minimum_size = Vector2(0, 38)
	_box.add_child(_desc_label)


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
	left.add_child(_input)

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
	button.custom_minimum_size = Vector2(0, 74)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
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
	button.pressed.connect(_on_start_pressed)
	return button


# ---------------------------------------------------------------- 对外接口

func open(default_name: String, players: Array[Dictionary], hero: int = HeroClass.WARRIOR) -> void:
	_locked = false
	_root.visible = true
	_refresh(players)
	_select_hero(hero)
	_input.text = default_name
	# 预选整段，直接打字即覆盖旧昵称
	_input.grab_focus()
	_input.select_all()


func close() -> void:
	_root.visible = false
	_input.release_focus()


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
	started.emit(ScoreBoard.sanitize(raw), _hero)


func _on_start_pressed() -> void:
	_start_with(_input.text)


func _on_submitted(text: String) -> void:
	_start_with(text)
