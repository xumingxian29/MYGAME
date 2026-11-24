class_name GameHud
extends CanvasLayer

## 纯展示层：血条 / 经验条 / 统计文本 / 分数、升级选卡面板、结算面板。
## 不含任何游戏规则，玩家选中哪张卡只通过 card_chosen 信号回传给 Game。
## process_mode = ALWAYS，因此 get_tree().paused 时卡片仍可点击、文字仍可显示。

signal card_chosen(index: int)

const VIGNETTE_SHADER: Shader = preload("res://scripts/ui/damage_vignette.gdshader")

var _root: Control
## 低血红边：一个全屏 ColorRect + shader，单次绘制搞定，比用渐变贴图或
## 多层 draw_rect 都便宜（后者每帧要几十到上百条绘制命令）
var _vignette: ColorRect
var _vignette_mat: ShaderMaterial
## 目标强度由 Game 按血量写入，实际显示值在这里平滑追随并叠加心跳脉动
var _danger_target: float = 0.0
var _danger: float = 0.0
var _danger_t: float = 0.0
var _hp_bar: ProgressBar
var _xp_bar: ProgressBar
var _stats_label: Label
var _next_label: Label
var _name_label: Label
var _score_label: Label
var _best_label: Label
var _panel: PanelContainer
var _panel_box: VBoxContainer
var _dim: ColorRect


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 红边作为 _root 的第一个子节点 → 画在所有 HUD 元素之下，文字不会被染红。
	# 必须 IGNORE 鼠标，否则这个全屏矩形会把升级卡的点击全部吃掉。
	_vignette = ColorRect.new()
	_vignette.name = "DamageVignette"
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color.WHITE
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette_mat = ShaderMaterial.new()
	_vignette_mat.shader = VIGNETTE_SHADER
	# 显式写入初值：ShaderMaterial 没写过的 uniform，get_shader_parameter() 返回 null，
	# 后面 float(null) 会每帧报 "Nonexistent 'float' constructor"，暗角也永远不会更新。
	_vignette_mat.set_shader_parameter("intensity", 0.0)
	_vignette.material = _vignette_mat
	_root.add_child(_vignette)

	var corner := VBoxContainer.new()
	corner.set_anchors_preset(Control.PRESET_TOP_LEFT)
	corner.position = Vector2(20, 16)
	corner.add_theme_constant_override("separation", 6)
	_root.add_child(corner)

	_hp_bar = _make_bar(Color(0.9, 0.28, 0.32), Vector2(260, 14))
	_xp_bar = _make_bar(Color(0.38, 0.74, 1.0), Vector2(260, 8))
	corner.add_child(_hp_bar)
	corner.add_child(_xp_bar)
	_stats_label = _make_label("", 16, Color(0.82, 0.88, 0.98))
	corner.add_child(_stats_label)
	# 卡越到后期间隔越长，必须让玩家看得见"下一张卡在哪一级"
	_next_label = _make_label("", 13, Color(0.58, 0.68, 0.84))
	corner.add_child(_next_label)

	# 右上角：当前玩家昵称 + 本局实时分数 + 该玩家的个人最高分
	var right := VBoxContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.offset_left = -360.0
	right.offset_right = -20.0
	right.offset_top = 14.0
	right.add_theme_constant_override("separation", 2)
	_root.add_child(right)

	_name_label = _make_label("", 14, Color(0.62, 0.72, 0.86))
	_score_label = _make_label("分数 0", 26, Color(1.0, 0.93, 0.7))
	_best_label = _make_label("个人最高 0", 15, Color(0.66, 0.74, 0.86))
	for label in [_name_label, _score_label, _best_label]:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		right.add_child(label)

	# 压暗遮罩：升级与死亡时都复用，避免游戏物体压住面板文字
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.02, 0.03, 0.05, 0.62)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.visible = false
	_root.add_child(_dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.5, 0.72, 1.0, 0.85)))
	center.add_child(_panel)

	_panel_box = VBoxContainer.new()
	_panel_box.add_theme_constant_override("separation", 10)
	_panel.add_child(_panel_box)


# ---------------------------------------------------------------- 对外接口

func set_health(current: float, maximum: float) -> void:
	if _hp_bar == null:
		return
	_hp_bar.max_value = maximum
	_hp_bar.value = current


func set_progress(value: float, need: float) -> void:
	_xp_bar.max_value = maxf(need, 1.0)
	_xp_bar.value = value


func set_stats(text: String) -> void:
	_stats_label.text = text


func set_next_upgrade(next_level: int) -> void:
	if _next_label == null:
		return
	_next_label.text = "下次强化卡  Lv.%d" % next_level


func set_score(player_name: String, current: int, best: int) -> void:
	if _name_label == null:
		return
	_name_label.text = player_name
	_score_label.text = "分数 %d" % current
	_best_label.text = "个人最高 %d" % best


## 开始菜单打开时整块 HUD 让位（菜单自带压暗层）
func set_hud_visible(shown: bool) -> void:
	_root.visible = shown


## 危血强度 0~1：0 完全不显示，1 满强度。缓动与心跳脉动都在 HUD 内完成，
## Game 只负责"按血量换算成一个数"，不需要关心动画细节。
func set_danger(level: float) -> void:
	_danger_target = clampf(level, 0.0, 1.0)


func _process(delta: float) -> void:
	if _vignette_mat == null:
		return
	# 用缓动追随而不是直接赋值：血量回满时红边是"退下去"，不是啪一下消失
	_danger = move_toward(_danger, _danger_target, delta * 2.2)
	if _danger <= 0.001:
		if _danger != 0.0:
			_danger = 0.0
			_vignette_mat.set_shader_parameter("intensity", 0.0)
		return
	_danger_t += delta
	# 心跳：约 1.5Hz 起步，濒死时提到 3Hz——越接近死亡跳得越快
	var hz: float = lerpf(1.5, 3.0, _danger)
	var pulse: float = 0.75 + sin(_danger_t * TAU * hz) * 0.25
	var value: float = _danger * pulse
	var prev: float = float(_vignette_mat.get_shader_parameter("intensity"))
	# 差值太小就不写 uniform，避免每帧无意义地触发材质更新
	if absf(prev - value) < 0.004:
		return
	_vignette_mat.set_shader_parameter("intensity", value)


## 打开升级选卡面板。每张卡需带 icon / name / body / rarity / unit 五个字段。
func open_level_up(level: int, choices: Array[Dictionary], next_level: int) -> void:
	_clear_panel()
	_panel.custom_minimum_size = Vector2.ZERO
	_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.5, 0.72, 1.0, 0.85)))

	_panel_box.add_child(_make_label("升级！  Lv.%d" % level, 28, Color(1.0, 0.94, 0.68)))
	_panel_box.add_child(_make_label(
		"点击卡片，或按 1 / 2 / 3 选择        下一张在 Lv.%d" % next_level,
		14, Color(0.72, 0.8, 0.92),
	))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel_box.add_child(row)
	for i in range(choices.size()):
		row.add_child(_make_card(i, choices[i]))

	_dim.visible = true
	_panel.visible = true


func close_level_up() -> void:
	_panel.visible = false
	_dim.visible = false


## 结算面板：result 由 Game 构建，含总分拆解与该昵称的个人纪录。
func show_game_over(result: Dictionary) -> void:
	_clear_panel()
	_panel.custom_minimum_size = Vector2(540, 0)
	_panel.add_theme_stylebox_override("panel", _panel_style(Color(1.0, 0.45, 0.45, 0.7)))

	var profile: Dictionary = result["profile"]
	var best: Dictionary = profile["best"]

	var title := _make_label("你被淹没了", 30, Color(1.0, 0.86, 0.86))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(title)

	var who := _make_label("玩家 %s" % str(profile["name"]), 15, Color(0.78, 0.85, 0.96))
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(who)

	_panel_box.add_child(_divider())
	_panel_box.add_child(_stat_row(
		"击杀",
		"%d 只 · 精英 %d" % [int(result["kills"]), int(result["elite_kills"])],
		"+%d" % int(result["kill_points"]),
		Color(0.9, 0.72, 0.72),
	))
	_panel_box.add_child(_stat_row(
		"存活",
		str(result["time_text"]),
		"+%d" % int(result["time_points"]),
		Color(0.72, 0.86, 0.98),
	))
	_panel_box.add_child(_stat_row(
		"成长",
		"Lv.%d · 经验 %d" % [int(result["level"]), int(result["xp_total"])],
		"+%d" % int(result["growth_points"]),
		Color(0.78, 0.92, 0.78),
	))
	_panel_box.add_child(_divider())

	var total_row := HBoxContainer.new()
	total_row.add_theme_constant_override("separation", 12)
	var total_label := _make_label("总分", 22, Color(0.9, 0.95, 1.0))
	total_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total_row.add_child(total_label)
	var total_value := _make_label(str(int(result["score"])), 34, Color(1.0, 0.9, 0.55))
	total_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	total_row.add_child(total_value)
	_panel_box.add_child(total_row)

	var is_best: bool = bool(result["is_best"])
	var best_text: String = "个人最高 %d" % int(best["score"])
	if is_best:
		best_text = "个人最高 %d · 新纪录！" % int(result["score"])
	var best_label := _make_label(
		best_text, 16,
		Color(1.0, 0.85, 0.45) if is_best else Color(0.72, 0.79, 0.9),
	)
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(best_label)

	var record := _make_label(
		"第 %d 次挑战 · 累计击杀 %d%s" % [
			int(profile["runs"]), int(profile["total_kills"]), _best_suffix(result),
		],
		13, Color(0.62, 0.68, 0.8),
	)
	record.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(record)

	var hint := _make_label("R 再来一局        P 换人", 15, Color(0.8, 0.86, 0.94))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(hint)

	_dim.visible = true
	_panel.visible = true


func clear_overlays() -> void:
	_panel.visible = false
	_dim.visible = false


# ---------------------------------------------------------------- 面板零件

func _clear_panel() -> void:
	for child in _panel_box.get_children():
		_panel_box.remove_child(child)
		child.queue_free()


func _best_suffix(result: Dictionary) -> String:
	if bool(result["is_best"]):
		return ""
	var best: Dictionary = result["profile"]["best"]
	var gap: int = int(best["score"]) - int(result["score"])
	if gap <= 0:
		return ""
	return " · 距个人最高差 %d" % gap


func _stat_row(title: String, detail: String, points: String, accent: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var left := _make_label(title, 17, accent)
	left.custom_minimum_size = Vector2(64, 0)
	row.add_child(left)

	var mid := _make_label(detail, 16, Color(0.86, 0.9, 0.97))
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(mid)

	var right := _make_label(points, 18, accent)
	right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.custom_minimum_size = Vector2(90, 0)
	row.add_child(right)
	return row


func _divider() -> ColorRect:
	return UiKit.divider()


func _panel_style(border: Color) -> StyleBoxFlat:
	return UiKit.panel_style(border)


# ---------------------------------------------------------------- 卡片

func _make_card(index: int, card: Dictionary) -> Button:
	var rarity: int = clampi(int(card["rarity"]), 0, CardRarity.COUNT - 1)
	var accent: Color = CardRarity.COLORS[rarity]
	# 卡片底色向档位色偏一点：史诗/传说在深色面板里靠底色就能认出来
	var base: Color = Color(0.09, 0.11, 0.16).lerp(accent, 0.035 * float(rarity))
	var border_width: int = 2 if rarity <= CardRarity.RARE else 3

	var button := Button.new()
	button.custom_minimum_size = Vector2(184, 226)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_stylebox_override("normal", _card_style(base, accent, border_width))
	button.add_theme_stylebox_override("hover", _card_style(base.lightened(0.07), accent.lightened(0.3), border_width + 1))
	button.add_theme_stylebox_override("pressed", _card_style(base.lightened(0.13), accent.lightened(0.45), border_width + 1))
	button.pressed.connect(card_chosen.emit.bind(index))

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12.0
	box.offset_top = 14.0
	box.offset_right = -12.0
	box.offset_bottom = -14.0
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(box)

	box.add_child(_make_icon(str(card["icon"]), accent, rarity))
	box.add_child(_make_label(str(card["name"]), 18, Color(0.95, 0.97, 1.0)))

	var body := _make_label(str(card["body"]), 14, Color(0.78, 0.85, 0.95))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(body)

	# 把稀有度徽章压到底部，三张卡对齐
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer)
	box.add_child(_make_badge(rarity, str(card["unit"])))
	return button


## 稀有度徽章：颜色 + 文字同时说明档位和强度倍率
func _make_badge(rarity: int, unit: String) -> Control:
	var accent: Color = CardRarity.COLORS[rarity]
	var strength: String
	if unit == "unlock":
		strength = "解锁武器"
	else:
		strength = "强度 " + CardRarity.strength_text(rarity)

	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style: StyleBoxFlat = UiKit.flat(
		Color(accent.r, accent.g, accent.b, 0.18),
		Color(accent.r, accent.g, accent.b, 0.65), 9, 1,
	)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	pill.add_theme_stylebox_override("panel", style)

	var text := _make_label("%s · %s" % [CardRarity.NAMES[rarity], strength], 12, accent)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pill.add_child(text)

	var holder := CenterContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(pill)
	return holder


## 图标用单个汉字（微软雅黑一定有字形），避免依赖美术资源或缺字形方块
func _make_icon(glyph: String, accent: Color, rarity: int) -> Control:
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(0.0, 74.0)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var plate := PanelContainer.new()
	plate.custom_minimum_size = Vector2(64.0, 64.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(accent.r, accent.g, accent.b, 0.16 + 0.05 * float(rarity))
	style.set_corner_radius_all(12)
	style.border_color = Color(accent.r, accent.g, accent.b, 0.55 + 0.1 * float(rarity))
	style.set_border_width_all(1 if rarity < CardRarity.EPIC else 2)
	plate.add_theme_stylebox_override("panel", style)

	var glyph_label := _make_label(glyph, 30, accent)
	glyph_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plate.add_child(glyph_label)

	holder.add_child(plate)
	return holder


func _card_style(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(12)
	style.border_color = border
	style.set_border_width_all(width)
	return style


# ---------------------------------------------------------------- 基础控件

func _make_label(text: String, size: int, color: Color) -> Label:
	return UiKit.label(text, size, color)


func _make_bar(fill_color: Color, bar_size: Vector2) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = bar_size
	bar.show_percentage = false
	bar.max_value = 100.0

	var background := StyleBoxFlat.new()
	background.bg_color = Color(1.0, 1.0, 1.0, 0.13)
	background.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(4)

	bar.add_theme_stylebox_override("background", background)
	bar.add_theme_stylebox_override("fill", fill)
	return bar
