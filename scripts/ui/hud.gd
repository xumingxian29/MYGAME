class_name GameHud
extends CanvasLayer

## 纯展示层：血条 / 经验条 / 统计文本 / 分数、升级选卡面板、结算面板。
## 不含任何游戏规则，玩家选中哪张卡只通过 card_chosen 信号回传给 Game。
## process_mode = ALWAYS，因此 get_tree().paused 时卡片仍可点击、文字仍可显示。

signal card_chosen(index: int)
## 结算面板上的按钮（只在触屏设备出现：手机上既没有 R 也没有 P）
signal restart_requested
signal menu_requested

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
var _mp_bar: ProgressBar
var _hp_text: Label
var _xp_text: Label
var _mp_text: Label
var _hp_gauge: Control
var _xp_gauge: Control
var _mp_gauge: Control
## 当前职业与蓝量缓存：蓝条文字要显示"空格 · 技能名"，且只在数值变化时重建字符串
var _hero: int = HeroClass.WARRIOR
var _mp_current: float = 0.0
var _mp_max: float = HeroClass.MANA_MAX
var _mp_ready: bool = false
## 触屏模式下文案换成"点按"，结算面板补两个可点按钮——手机上没有空格键，也没有 R / P
var _touch_mode: bool = false
var _stats_label: Label
var _next_label: Label
var _name_label: Label
var _score_label: Label
var _best_label: Label
var _panel: PanelContainer
var _panel_box: VBoxContainer
var _dim: ColorRect
## 屏顶 Boss 血条：名字 + 阶段 + 一条长血。只在 Boss 战期间显示。
var _boss_panel: PanelContainer
var _boss_bar: ProgressBar
var _boss_name_label: Label
var _boss_phase_label: Label
## 章节栏：标题 + 进度条。进度条在 Boss 战期间停在一半（章节时钟也停着），
## 打完 Boss 换章时归零，所以"条走到头"和"Boss 出现"在玩家眼里是同一件事。
var _stage_label: Label
var _stage_bar: ProgressBar
var _stage_bar_color: Color = Color.WHITE
## 上一帧是否处于关底状态：只在翻转时改一次控件主题色，
## 否则 10Hz 的 HUD 刷新会每 0.1 秒重建一次 StyleBox
var _stage_boss: bool = false
## 屏外方向箭头：圈心滑出屏幕后唯一的"往哪跑"提示
var _zone_arrow: ZoneArrow
## 安全区倒计时：常驻一行，收缩时变成"收缩中 + 秒数"，圈外时整行变红。
## 不放在屏幕中央——那会挡住走位视线；玩家只要能用余光读到"还有多久就要缩"就够。
var _zone_label: Label
var _zone_danger: bool = false
## 章节横幅：进章/通关时在屏幕上方短暂显示的大字。
## 不做成暂停式弹窗——玩家在打怪，突然被一张"第一章"挡住两秒会挨打。
var _banner: Control
var _banner_box: VBoxContainer
var _banner_title: Label
var _banner_sub: Label
var _banner_t: float = 0.0

## 横幅总时长与淡入/淡出段：淡入要快（玩家在等结果），淡出要慢（不然像闪烁）
const BANNER_TIME: float = 3.0
const BANNER_FADE_IN: float = 0.28
const BANNER_FADE_OUT: float = 0.85


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

	# 方向箭头紧跟红边之后：都在所有文字之下，不会盖住任何读数
	_zone_arrow = ZoneArrow.new()
	_zone_arrow.name = "ZoneArrow"
	_root.add_child(_zone_arrow)

	var corner := VBoxContainer.new()
	corner.set_anchors_preset(Control.PRESET_TOP_LEFT)
	corner.position = Vector2(20, 16)
	corner.add_theme_constant_override("separation", 6)
	_root.add_child(corner)

	# 三条状态条：血 / 经验 / 蓝。每条都是"进度条 + 居中数值"，
	# 数值叠在条上而不是另起一行，省纵向空间，也不会让眼睛在两处之间来回跑。
	_hp_gauge = _make_gauge("HpGauge", Color(0.9, 0.28, 0.32), Vector2(260, 18), 12)
	_hp_bar = _hp_gauge.get_node("Bar") as ProgressBar
	_hp_text = _hp_gauge.get_node("Text") as Label
	corner.add_child(_hp_gauge)

	_xp_gauge = _make_gauge("XpGauge", Color(0.38, 0.74, 1.0), Vector2(260, 14), 10)
	_xp_bar = _xp_gauge.get_node("Bar") as ProgressBar
	_xp_text = _xp_gauge.get_node("Text") as Label
	corner.add_child(_xp_gauge)

	_mp_gauge = _make_gauge("MpGauge", Color(0.34, 0.56, 1.0), Vector2(260, 16), 12)
	_mp_bar = _mp_gauge.get_node("Bar") as ProgressBar
	_mp_text = _mp_gauge.get_node("Text") as Label
	corner.add_child(_mp_gauge)

	# 章节：紧贴三条状态条下面。玩家最常看的两个数就是"我还有多少血"和
	# "这一章还剩多少"，放在同一列才不用来回找。
	_stage_label = _make_label("", 13, Color(0.7, 0.86, 0.92))
	corner.add_child(_stage_label)
	_stage_bar = _make_bar(Color(0.42, 0.82, 0.78), Vector2(260, 5))
	_stage_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_bar_color = Color(0.42, 0.82, 0.78)
	corner.add_child(_stage_bar)

	# 安全区倒计时紧跟在章节条后面：两者都是"限时"信息，放一起形成一个时间区。
	_zone_label = _make_label("", 13, Color(0.78, 0.66, 1.0))
	corner.add_child(_zone_label)

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

	_build_boss_bar()
	_build_banner()

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


## 屏顶 Boss 血条。不抢左右两栏的位置：桌面上居中贴顶，触屏上整体下移到状态条
## 下方（960 基准下左右两栏已经吃到 280 / 600，中间只剩 320 宽，塞不下 460 的条）。
func _build_boss_bar() -> void:
	_boss_panel = PanelContainer.new()
	_boss_panel.name = "BossBar"
	_boss_panel.anchor_left = 0.5
	_boss_panel.anchor_right = 0.5
	_boss_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_panel.visible = false
	_boss_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.95, 0.36, 0.4, 0.9)))
	_root.add_child(_boss_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_panel.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(head)

	_boss_name_label = _make_label("", 17, Color(1.0, 0.87, 0.87))
	_boss_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_boss_name_label)

	_boss_phase_label = _make_label("", 13, Color(0.96, 0.74, 0.74))
	_boss_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_boss_phase_label)

	_boss_bar = _make_bar(Color(0.92, 0.27, 0.32), Vector2(420, 15))
	_boss_bar.max_value = 1.0
	_boss_bar.value = 1.0
	_boss_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_boss_bar)
	_layout_boss_bar()


## 触屏的基准分辨率小一圈，但左右两栏的像素宽度不变，所以条要缩窄并下移，
## 否则会盖到左上角的血条和右上角的分数。
func _layout_boss_bar() -> void:
	if _boss_panel == null:
		return
	var width: float = 340.0 if _touch_mode else 460.0
	_boss_panel.offset_left = -width * 0.5
	_boss_panel.offset_right = width * 0.5
	_boss_panel.offset_top = 104.0 if _touch_mode else 12.0
	if _boss_bar != null:
		_boss_bar.custom_minimum_size = Vector2(width - 24.0, 15.0)


## 章节横幅。整块 Control 铺满屏幕但 IGNORE 鼠标，文字用描边而不是底色块：
## 战场上每帧都在变，一块半透明底板会跟着怪一起晃眼，描边字更干净。
## 位置放在纵向 16%，避开左上角的状态条和屏顶的 Boss 血条。
func _build_banner() -> void:
	_banner = Control.new()
	_banner.name = "StageBanner"
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	_root.add_child(_banner)

	_banner_box = VBoxContainer.new()
	_banner_box.anchor_left = 0.0
	_banner_box.anchor_right = 1.0
	_banner_box.anchor_top = 0.16
	_banner_box.anchor_bottom = 0.16
	_banner_box.offset_left = 32.0
	_banner_box.offset_right = -32.0
	_banner_box.add_theme_constant_override("separation", 4)
	_banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(_banner_box)

	_banner_title = _make_label("", 42, Color.WHITE)
	_apply_banner_outline(_banner_title, 8)
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_box.add_child(_banner_title)

	_banner_sub = _make_label("", 17, Color(0.86, 0.92, 1.0))
	_apply_banner_outline(_banner_sub, 5)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner_box.add_child(_banner_sub)
	_layout_banner()


## 触屏上 Boss 血条被下移到 y=104（否则会盖住左上角状态条），
## 横幅必须跟着让开，不然章节名会被血条压住——而"这是第几章"正是横幅唯一的信息。
func _layout_banner() -> void:
	if _banner_box == null:
		return
	var anchor: float = 0.36 if _touch_mode else 0.16
	_banner_box.anchor_top = anchor
	_banner_box.anchor_bottom = anchor


func _apply_banner_outline(label: Label, size: int) -> void:
	label.add_theme_constant_override("outline_size", size)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.92))


# ---------------------------------------------------------------- 对外接口

func set_health(current: float, maximum: float) -> void:
	if _hp_bar == null:
		return
	_hp_bar.max_value = maxf(maximum, 1.0)
	_hp_bar.value = current
	_set_text(_hp_text, "%d / %d" % [roundi(maxf(current, 0.0)), roundi(maximum)])


func set_progress(value: float, need: float) -> void:
	if _xp_bar == null:
		return
	_xp_bar.max_value = maxf(need, 1.0)
	_xp_bar.value = value
	_set_text(_xp_text, "%d / %d" % [roundi(maxf(value, 0.0)), roundi(need)])


## 蓝条。满了把条和文字都切成金色，并直接写"空格 · 技能名"，
## 玩家不用记满蓝该按什么键。
func set_mana(current: float, maximum: float) -> void:
	if _mp_bar == null:
		return
	_mp_current = current
	_mp_max = maxf(maximum, 1.0)
	_mp_bar.max_value = _mp_max
	_mp_bar.value = current

	var ready: bool = current >= _mp_max - 0.01
	if ready != _mp_ready:
		_mp_ready = ready
		var fill_color: Color = Color(1.0, 0.85, 0.42) if ready else Color(0.34, 0.56, 1.0)
		_mp_bar.add_theme_stylebox_override("fill", UiKit.flat(fill_color, Color.TRANSPARENT, 4, 0))
	_refresh_mana_text()


func set_hero(hero: int) -> void:
	_hero = clampi(hero, 0, HeroClass.COUNT - 1)
	_mp_ready = false
	_mp_bar.add_theme_stylebox_override("fill", UiKit.flat(Color(0.34, 0.56, 1.0), Color.TRANSPARENT, 4, 0))
	_refresh_mana_text()


## 触屏模式开关：只影响文案与结算面板的操作方式，数值与布局不变。
## Boss 血条例外——它的宽度和下移量依赖基准分辨率，必须重排一次。
func set_touch_mode(enabled: bool) -> void:
	_touch_mode = enabled
	_refresh_mana_text()
	_layout_boss_bar()
	_layout_banner()


func is_touch_mode() -> bool:
	return _touch_mode


func _refresh_mana_text() -> void:
	if _mp_text == null:
		return
	if _mp_ready:
		_set_text(_mp_text, "%s · %s" % ["点按" if _touch_mode else "空格", HeroClass.skill_name(_hero)])
		# 满蓝时条是金色，文字必须反过来用深色，否则金底金字看不出写了什么
		_mp_text.add_theme_color_override("font_color", Color(0.13, 0.1, 0.04))
	else:
		_set_text(_mp_text, "%d / %d" % [roundi(_mp_current), roundi(_mp_max)])
		_mp_text.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))


## 只在内容真的变化时才赋值：Label.text 的 setter 会触发重新排版，
## 每帧无条件写一次在 60fps 下等于每帧重排三次文本。
func _set_text(label: Label, text: String) -> void:
	if label != null and label.text != text:
		label.text = text


func set_stats(text: String) -> void:
	_stats_label.text = text


func set_next_upgrade(next_level: int) -> void:
	if _next_label == null:
		return
	_next_label.text = "下次强化卡  Lv.%d" % next_level


func set_score(player_name: String, current: int, best: int) -> void:
	if _name_label == null:
		return
	_name_label.text = "%s · %s" % [player_name, HeroClass.NAMES[_hero]] if player_name != "" else ""
	_score_label.text = "分数 %d" % current
	_best_label.text = "个人最高 %d" % best


## 开始菜单打开时整块 HUD 让位（菜单自带压暗层）
func set_hud_visible(shown: bool) -> void:
	_root.visible = shown


## 危血强度 0~1：0 完全不显示，1 满强度。缓动与心跳脉动都在 HUD 内完成，
## Game 只负责"按血量换算成一个数"，不需要关心动画细节。
func set_danger(level: float) -> void:
	_danger_target = clampf(level, 0.0, 1.0)


# ---------------------------------------------------------------- 章节

## 章节标题 + 进度。progress 由 Game 按"本章已过秒数 / 本章时长"给，
## 关底期间章节时钟是停的，所以条会走到 100% 停住并变红——
## "条满了"和"Boss 出来了"在玩家眼里是同一件事。
func set_stage(title: String, progress: float, boss_alive: bool, tint: Color) -> void:
	if _stage_label == null:
		return
	_set_text(_stage_label, "%s　·　关底" % title if boss_alive else title)
	_stage_bar.value = clampf(progress, 0.0, 1.0) * 100.0

	var fill: Color = Color(0.94, 0.34, 0.36) if boss_alive else tint
	if fill != _stage_bar_color:
		_stage_bar_color = fill
		_stage_bar.add_theme_stylebox_override("fill", UiKit.flat(fill, Color.TRANSPARENT, 3, 0))
	if boss_alive != _stage_boss:
		_stage_boss = boss_alive
		_stage_label.add_theme_color_override(
			"font_color",
			Color(1.0, 0.68, 0.64) if boss_alive else Color(0.72, 0.9, 0.95),
		)


## 屏外方向箭头。dir_px 是玩家指向圈心的屏幕像素位移（世界位移 × 相机缩放）。
func set_zone_direction(dir_px: Vector2, outside: bool) -> void:
	if _zone_arrow == null:
		return
	_zone_arrow.set_target(dir_px, outside)


## 安全区倒计时。文字由 Game 拼好（它才知道阶段名与剩余秒数），
## HUD 只负责"显示 + 换色"。圈外时用红色，和右下角的血量告急区分开：
## 血量红边是"你要死了"，圈外红字是"你现在正在掉血"。
func set_zone_status(text: String, danger: bool) -> void:
	if _zone_label == null:
		return
	_set_text(_zone_label, text)
	# 10Hz 刷新下每帧都 add_theme_color_override 会持续重建 ThemeItem，
	# 和 _stage_boss 一样只在翻转时改一次
	if danger != _zone_danger:
		_zone_danger = danger
		_zone_label.add_theme_color_override(
			"font_color",
			Color(1.0, 0.42, 0.42) if danger else Color(0.78, 0.66, 1.0),
		)


## 章节横幅。cleared 时换成金色，和"进新章"区分开：
## 通关是这一局唯一的一次性事件，不能和普通的换章长得一样。
func show_banner(title: String, subtitle: String, tint: Color, cleared: bool) -> void:
	if _banner == null:
		return
	_set_text(_banner_title, title)
	_set_text(_banner_sub, subtitle)
	var accent: Color = Color(1.0, 0.88, 0.46) if cleared else tint.lightened(0.35)
	_banner_title.add_theme_color_override("font_color", accent)
	_banner_sub.add_theme_color_override("font_color", accent.lightened(0.4))
	_banner.modulate.a = 0.0
	_banner.visible = true
	_banner_t = BANNER_TIME


func hide_banner() -> void:
	_banner_t = 0.0
	if _banner != null:
		_banner.visible = false
		_banner.modulate.a = 0.0


## 淡入快、淡出慢：淡入时玩家在等结果，拖沓会像卡了；淡出时不该打断读字。
func _tick_banner(delta: float) -> void:
	if _banner_t <= 0.0:
		if _banner != null and _banner.visible:
			_banner.visible = false
		return
	_banner_t = maxf(_banner_t - delta, 0.0)
	var shown: float = BANNER_TIME - _banner_t
	var alpha: float = minf(shown / BANNER_FADE_IN, _banner_t / BANNER_FADE_OUT)
	_banner.modulate.a = clampf(alpha, 0.0, 1.0)


# ---------------------------------------------------------------- Boss 血条

## 开一场 Boss 战。血量与阶段随后由 set_boss_health / set_boss_phase 推进，
## 这里只负责把条亮出来并归位。
## style 是这只 Boss 的招式风格名（潮汐/游影/深噬）。三只 Boss 的招式不同，
## 光写名字玩家分不出"这次打的是不是同一套"，所以名字后面带上它怎么打。
func show_boss(boss_name: String, style: String = "") -> void:
	if _boss_panel == null:
		return
	_set_text(_boss_name_label, boss_name if style.is_empty() else "%s · %s" % [boss_name, style])
	set_boss_phase(0)
	_boss_bar.value = 1.0
	_boss_panel.visible = true


func set_boss_health(ratio: float) -> void:
	if _boss_bar == null:
		return
	_boss_bar.value = clampf(ratio, 0.0, 1.0)


## 二阶段把血条换成橙红：光看条长短玩家不一定注意到"它换招式了"
func set_boss_phase(phase: int) -> void:
	if _boss_phase_label == null:
		return
	_set_text(_boss_phase_label, "第二阶段" if phase >= 1 else "第一阶段")
	var fill: Color = Color(1.0, 0.62, 0.24) if phase >= 1 else Color(0.92, 0.27, 0.32)
	_boss_bar.add_theme_stylebox_override("fill", UiKit.flat(fill, Color.TRANSPARENT, 4, 0))


func hide_boss() -> void:
	if _boss_panel != null:
		_boss_panel.visible = false


func _process(delta: float) -> void:
	# 暂停时只冻结横幅，不冻结红边。
	# 横幅是"这一章开始了"的一次性提示，暂停期间不该偷偷放完（升级面板一压暗就看不见了）；
	# 但红边必须继续衰减：死亡时整棵树被暂停，如果连红边也冻住，
	# 结算面板背后会永远挂着一圈满强度红光。
	if not get_tree().paused:
		_tick_banner(delta)
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
	var how_to: String = "点按卡片选择" if _touch_mode else "点击卡片，或按 1 / 2 / 3 选择"
	_panel_box.add_child(_make_label(
		"%s        下一张在 Lv.%d" % [how_to, next_level],
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
	# 面板一压暗，横幅就只剩一层灰底，留着只会让标题和卡片抢注意力。
	# 章节名已经在左上角常驻，横幅的使命（"你换章了"）在面板弹出前就完成了。
	hide_banner()


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
	var cleared: bool = bool(result.get("cleared", false))

	# 通关局不该说"你被淹没了"：那会让唯一的正面结果读起来像失败。
	var title := _make_label(
		"你走完了三章" if cleared else "你被淹没了",
		30, Color(1.0, 0.9, 0.62) if cleared else Color(1.0, 0.86, 0.86),
	)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(title)

	var who := _make_label("玩家 %s" % str(profile["name"]), 15, Color(0.78, 0.85, 0.96))
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_box.add_child(who)

	# 死因单独一行：不加这句，"怎么死的"只能靠玩家自己回忆最后两秒。
	# 通关局不显示——那局不是被打死的。
	if not cleared:
		var by_zone: bool = str(result.get("death_cause", "敌人")) == "圈外"
		var cause := _make_label(
			"死因：倒在安全区外" if by_zone else "死因：被敌人淹没",
			13, Color(0.86, 0.7, 1.0) if by_zone else Color(0.82, 0.66, 0.66),
		)
		cause.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_panel_box.add_child(cause)

	_panel_box.add_child(_divider())
	# Boss 数单独列出来：它是这局唯一的里程碑，混在"击杀 N 只"里等于没发生
	var kill_detail: String = "%d 只 · 精英 %d" % [int(result["kills"]), int(result["elite_kills"])]
	var boss_kills: int = int(result.get("boss_kills", 0))
	if boss_kills > 0:
		kill_detail += " · Boss %d" % boss_kills
	_panel_box.add_child(_stat_row(
		"击杀",
		kill_detail,
		"+%d" % int(result["kill_points"]),
		Color(0.9, 0.72, 0.72),
	))
	# 存活行带上章节名：只给一个秒数回答不了"我这局打到哪了"，
	# 而对刷怪游戏来说，"推进到第几章"才是玩家真正记得住的进度。
	_panel_box.add_child(_stat_row(
		"存活",
		"%s · %s" % [str(result["time_text"]), str(result.get("stage_name", ""))],
		"+%d" % int(result["time_points"]),
		Color(0.72, 0.86, 0.98),
	))
	_panel_box.add_child(_stat_row(
		"成长",
		"Lv.%d · 经验 %d" % [int(result["level"]), int(result["xp_total"])],
		"+%d" % int(result["growth_points"]),
		Color(0.78, 0.92, 0.78),
	))
	# 通关行只在对局真的走完三章时出现：没通关的人不该看到一行 "+0"，
	# 那会把"没做到"变成显式的扣分，而不是留白。
	if cleared:
		_panel_box.add_child(_stat_row(
			"关卡",
			"三章通关 · 附加奖励",
			"+%d" % int(result.get("clear_points", 0)),
			Color(1.0, 0.84, 0.42),
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

	# 鼠标和触屏都必须能点：早先桌面端只给一行快捷键文字，用鼠标的玩家在结算页点不动
	# （试玩反馈：只能靠快捷键回主界面）。快捷键保留为附加路径，不再是唯一路径。
	_panel_box.add_child(_make_action_row())
	if not _touch_mode:
		var hint := _make_label("快捷键：R 再来一局　P / ESC 换人", 13, Color(0.62, 0.7, 0.84))
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_panel_box.add_child(hint)

	_dim.visible = true
	_panel.visible = true


## 结算的两个大按钮，桌面与触屏共用。尺寸按 960 基准的设计宽度给（约 120×38 CSS 像素），
## 再小就点不准；键盘的 R / P / ESC 依然有效，两条路径互不干扰。
func _make_action_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	var retry := _make_action_button("再来一局", Color(1.0, 0.85, 0.48), restart_requested.emit)
	var swap := _make_action_button("换人", Color(0.52, 0.68, 0.92), menu_requested.emit)
	# 默认选中「再来一局」：键盘党死亡后直接按回车就重开，不用先摸鼠标去点
	retry.focus_mode = Control.FOCUS_ALL
	row.add_child(retry)
	row.add_child(swap)
	retry.call_deferred("grab_focus")
	return row


func _make_action_button(text: String, accent: Color, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(176, 54)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UiKit.font())
	button.add_theme_font_size_override("font_size", 20)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(key, Color(0.07, 0.09, 0.13))
	button.add_theme_stylebox_override("normal", UiKit.flat(accent, accent.lightened(0.35), 10, 0))
	button.add_theme_stylebox_override("hover", UiKit.flat(accent.lightened(0.12), accent.lightened(0.5), 10, 0))
	button.add_theme_stylebox_override("pressed", UiKit.flat(accent.darkened(0.12), accent.lightened(0.3), 10, 0))
	# 键盘选中态：外圈加一道亮边，否则拿到焦点也看不出来
	button.add_theme_stylebox_override("focus", UiKit.flat(accent.lightened(0.16), accent.lightened(0.75), 10, 3))
	button.pressed.connect(callback)
	return button


func clear_overlays() -> void:
	_panel.visible = false
	_dim.visible = false
	hide_banner()


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
	# PanelContainer 默认 STOP，会把点在图标上的这次点击整口吃掉，卡片看上去"点不动"。
	# 卡片的可点区域必须是整张卡，包括这个图标。
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
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


## 进度条 + 叠在上面的数值。返回的 Control 尺寸固定，条与文字都铺满它，
## 因此不需要任何手动对齐；子节点用名字取回（Bar / Text）。
func _make_gauge(node_name: String, fill: Color, size: Vector2, font_size: int) -> Control:
	var holder := Control.new()
	holder.name = node_name
	holder.custom_minimum_size = size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar := _make_bar(fill, size)
	bar.name = "Bar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var text := UiKit.label("", font_size, Color(1.0, 1.0, 1.0, 0.95))
	text.name = "Text"
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(text)
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return holder


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
