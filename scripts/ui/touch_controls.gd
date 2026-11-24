class_name TouchControls
extends CanvasLayer

## 移动端触屏操作层：左下虚拟摇杆 + 右下技能键。
##
## 只在"确认有触摸屏"的设备上出现（Web / 移动端导出 + 系统报告支持触摸），
## 桌面浏览器与桌面版完全不显示，也不会吃掉任何鼠标事件。
##
## 摇杆不是直接改 Player 的坐标，而是通过 Input.action_press() 写进 InputMap 的
## move_left/right/up/down 四个动作里——Player 走的是 Input.get_vector()，
## 所以模拟量（推一半 = 半速）与键盘天然共存，玩家代码一行都不用改。
##
## 触摸事件用 _input 而不是 _gui_input：摇杆的感应区覆盖了大半块屏幕，
## 做成 Control 会把整块区域变成"吃掉点击"的控件，暂停时还要额外收拾。

## 触摸技能键。Game 收到后调 Player.try_use_skill()，蓝不满自然不会放
signal skill_pressed

## 摇杆推到这么小的幅度就当作没推：手指按上去必然有几像素的抖动，
## 不设死区的话玩家一碰屏幕角色就开始飘。
const STICK_DEADZONE: float = 0.14

## 所有尺寸都按 540 逻辑高度缩放。移动端切了更小的基准分辨率（见 Game.MOBILE_VIEWPORT），
## 桌面强制调试时又是 720，写死像素在这两种情况下会一大一小。
const STICK_RADIUS: float = 84.0
const KNOB_RADIUS: float = 32.0
const SKILL_RADIUS: float = 56.0
const EDGE_MARGIN: float = 30.0

var _enabled: bool = false
var _active: bool = false
## 桌面强制开触摸（godot -- --touch）时，鼠标也能拖摇杆，方便不开手机验证
var _mouse_fallback: bool = false

var _view: Control
var _size: Vector2 = Vector2(1280.0, 720.0)
var _s: float = 1.0
var _stick_r: float = STICK_RADIUS
var _knob_r: float = KNOB_RADIUS
var _skill_r: float = SKILL_RADIUS
## 摇杆的"家"位置（没在拖动时画在这里），以及拖动时浮到的位置
var _stick_rest: Vector2 = Vector2.ZERO
var _stick_center: Vector2 = Vector2.ZERO
var _skill_center: Vector2 = Vector2.ZERO
## 摇杆手柄相对底盘中心的偏移（长度已夹到半径内）
var _knob: Vector2 = Vector2.ZERO

## 当前按住摇杆 / 技能键的手指 id。id 互不干扰，因此左手推着走也能右手点技能。
var _stick_id: int = -1
var _skill_id: int = -1

var _hero: int = HeroClass.WARRIOR
var _mana_ratio: float = 0.0
var _skill_ready: bool = false
## 按下技能键的一次性高亮，以及满蓝时的呼吸光环
var _press_flash: float = 0.0
var _pulse: float = 0.0


## 设备是否有触摸屏。桌面浏览器（哪怕带触屏笔记本）默认不开，避免鼠标玩家
## 屏幕上多出两个挡视线的圆圈；需要调试时用 `-- --touch` 强制打开。
static func is_touch_device() -> bool:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-touch"):
		return false
	if args.has("--touch"):
		return true
	if not DisplayServer.is_touchscreen_available():
		return false
	return OS.has_feature("web") or OS.has_feature("mobile")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# HUD 与开始菜单都在 layer 1，操作层放 2 才会画在压暗层之上；
	# 暂停（升级选卡 / 结算 / 菜单）时整层隐藏，卡片与按钮照常可点。
	layer = 2
	_enabled = is_touch_device()
	_mouse_fallback = OS.get_cmdline_user_args().has("--touch")
	_build()
	set_active(false)


func _build() -> void:
	var view := _TouchView.new()
	view.name = "View"
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 整层不吃鼠标：真正的输入在 _input 里按区域判定，画面上没有任何可点的 Control
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(view)
	_view = view
	if not get_viewport().size_changed.is_connected(_relayout):
		get_viewport().size_changed.connect(_relayout)
	_relayout()


func _relayout() -> void:
	if _view == null:
		return
	_size = get_viewport().get_visible_rect().size
	_s = clampf(_size.y / 540.0, 0.7, 2.4)
	_stick_r = STICK_RADIUS * _s
	_knob_r = KNOB_RADIUS * _s
	_skill_r = SKILL_RADIUS * _s
	_stick_rest = Vector2(_stick_r + EDGE_MARGIN * _s, _size.y - _stick_r - EDGE_MARGIN * _s)
	_skill_center = Vector2(_size.x - _skill_r - EDGE_MARGIN * _s, _size.y - _skill_r - EDGE_MARGIN * _s)
	if _stick_id < 0:
		_stick_center = _stick_rest
		_knob = Vector2.ZERO
	_view.queue_redraw()


# ---------------------------------------------------------------- 对外接口

func set_hero(hero: int) -> void:
	_hero = clampi(hero, 0, HeroClass.COUNT - 1)
	_queue_redraw()


## 由 Player.mana_changed 驱动。只在变化够明显时重绘：
## 回蓝是按整点跳的，每帧无条件重绘等于白白重画一层圆形与文字。
func on_mana_changed(current: float, maximum: float) -> void:
	var ratio: float = clampf(current / maxf(maximum, 1.0), 0.0, 1.0)
	var ready: bool = ratio >= 0.999
	if absf(ratio - _mana_ratio) < 0.005 and ready == _skill_ready:
		return
	_mana_ratio = ratio
	_skill_ready = ready
	_queue_redraw()


func set_active(active: bool) -> void:
	_active = active and _enabled
	if _view != null:
		_view.visible = _active
	if not _active:
		_release_stick()
		_skill_id = -1


func is_active() -> bool:
	return _active


func has_touch() -> bool:
	return _enabled


# ---------------------------------------------------------------- 输入

func _input(event: InputEvent) -> void:
	if not _active:
		return

	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			_press(touch.position, touch.index)
		else:
			_release(touch.index)
		return

	var drag := event as InputEventScreenDrag
	if drag != null:
		_move(drag.position, drag.index)
		return

	if not _mouse_fallback:
		return
	# 桌面调试通道：把鼠标当一根手指，id 固定 -1，与真手指的 id 不会撞
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_press(button.position, -1)
		else:
			_release(-1)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _stick_id == -1 and _skill_id == -1:
		return
	if motion != null:
		_move(motion.position, -1)


func _press(pos: Vector2, id: int) -> void:
	if _skill_id < 0 and _skill_hit(pos):
		_skill_id = id
		_press_flash = 1.0
		_queue_redraw()
		skill_pressed.emit()
		get_viewport().set_input_as_handled()
		return

	if _stick_id < 0 and _stick_hit(pos):
		_stick_id = id
		# 手指落在摇杆圈里就沿用画的这个圈；落在别处则把底盘挪到指尖下（浮动摇杆），
		# 手机上手掌位置每次都不同，固定底盘经常按不到。
		if pos.distance_to(_stick_rest) <= _stick_r * 1.6:
			_stick_center = _stick_rest
		else:
			_stick_center = _clamp_center(pos)
		_knob = Vector2.ZERO
		_apply_stick()
		_queue_redraw()
		get_viewport().set_input_as_handled()


func _move(pos: Vector2, id: int) -> void:
	if id != _stick_id or _stick_id == -1:
		return
	_knob = (pos - _stick_center).limit_length(_stick_r)
	_apply_stick()
	_queue_redraw()
	get_viewport().set_input_as_handled()


func _release(id: int) -> void:
	if id == _stick_id and _stick_id != -1:
		_release_stick()
		get_viewport().set_input_as_handled()
	elif id == _skill_id:
		_skill_id = -1
		_queue_redraw()
		get_viewport().set_input_as_handled()


## 底盘不能被拖出屏幕：贴着右下角按下去时圆心还在屏内，但半径会出去一半
func _clamp_center(pos: Vector2) -> Vector2:
	var margin: float = _stick_r + 4.0
	return Vector2(
		clampf(pos.x, margin, maxf(_size.x - margin, margin)),
		clampf(pos.y, margin, maxf(_size.y - margin, margin)),
	)


## 左手半屏（且不在顶端 HUD 上）算摇杆区
func _stick_hit(pos: Vector2) -> bool:
	return pos.x <= _size.x * 0.58 and pos.y >= _size.y * 0.30


## 技能键本身 + 右半屏下部都算技能区：手机上拇指按技能很少精确落在圆里
func _skill_hit(pos: Vector2) -> bool:
	if pos.distance_to(_skill_center) <= _skill_r * 1.7:
		return true
	return pos.x >= _size.x * 0.62 and pos.y >= _size.y * 0.55


func _release_stick() -> void:
	_stick_id = -1
	_knob = Vector2.ZERO
	_stick_center = _stick_rest
	_clear_actions()
	_queue_redraw()


## 把摇杆偏移写进 InputMap。用 action_press 的 strength 参数而不是四舍五入成
## "按下/松开"：推一半走半速，绕小圈微调身位时才不会变成满速乱跑。
func _apply_stick() -> void:
	var raw: Vector2 = _knob / _stick_r
	var strength: float = raw.length()
	if strength < STICK_DEADZONE:
		_clear_actions()
		return

	var dir: Vector2 = raw / strength
	# 归一化后再乘回力度：斜向推到底不该比直推更快，但轻推要真的慢
	var x: float = dir.x * strength
	var y: float = dir.y * strength
	_axis("move_right", "move_left", x)
	_axis("move_down", "move_up", y)


func _axis(positive: StringName, negative: StringName, value: float) -> void:
	if value > 0.0:
		Input.action_press(positive, value)
		Input.action_release(negative)
	else:
		Input.action_press(negative, -value)
		Input.action_release(positive)


func _clear_actions() -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)


## 节点被删（重开一局、关游戏）时一定要松手，否则动作会永远停在按下状态
func _exit_tree() -> void:
	_clear_actions()


# ---------------------------------------------------------------- 动画

func _process(delta: float) -> void:
	if not _active:
		return
	var dirty: bool = false
	if _press_flash > 0.0:
		_press_flash = maxf(_press_flash - delta * 2.6, 0.0)
		dirty = true
	if _skill_ready:
		_pulse = fmod(_pulse + delta, 10.0)
		dirty = true
	if dirty:
		_queue_redraw()


func _queue_redraw() -> void:
	if _view != null:
		_view.queue_redraw()


# ---------------------------------------------------------------- 绘制

## 由内部 _TouchView 在 _draw 里回调。所有 draw_* 都打在 view 上。
func paint_into(view: Control) -> void:
	_paint_stick(view)
	_paint_skill(view)


func _paint_stick(view: Control) -> void:
	var dragging: bool = _stick_id != -1
	var center: Vector2 = _stick_center
	var base_alpha: float = 0.20 if dragging else 0.10
	var ring_alpha: float = 0.55 if dragging else 0.28

	view.draw_circle(center, _stick_r, Color(0.62, 0.72, 0.95, base_alpha))
	view.draw_arc(center, _stick_r, 0.0, TAU, 48, Color(0.72, 0.82, 1.0, ring_alpha), 2.0 * _s, true)
	# 内圈虚线感：四个方向各来一小段，只当"这里是摇杆"的提示，不做刻度
	for i in range(4):
		var a: float = TAU * float(i) / 4.0 + PI / 4.0
		view.draw_arc(center, _stick_r * 0.62, a - 0.18, a + 0.18, 8,
			Color(0.72, 0.82, 1.0, ring_alpha * 0.5), 1.5 * _s, true)

	var knob_pos: Vector2 = center + _knob
	var knob_tint: Color = HeroClass.color(_hero)
	view.draw_circle(knob_pos, _knob_r, Color(knob_tint.r, knob_tint.g, knob_tint.b, 0.72))
	view.draw_arc(knob_pos, _knob_r, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.85), 2.0 * _s, true)

	if not dragging:
		_draw_text(view, "拖动移动", center + Vector2(0.0, _stick_r + 16.0 * _s), int(11.0 * _s),
			Color(0.72, 0.8, 0.95, 0.6))


func _paint_skill(view: Control) -> void:
	var ready: bool = _skill_ready
	var accent: Color = Color(1.0, 0.84, 0.42) if ready else Color(0.5, 0.66, 0.95)

	# 满蓝时外圈呼吸：两秒一轮，幅度很小，避免在血量告急时抢走注意力
	var glow: float = 0.0
	if ready:
		glow = (sin(_pulse * TAU * 0.5) * 0.5 + 0.5) * 0.5 + 0.5
		view.draw_arc(_skill_center, _skill_r + 8.0 * _s, 0.0, TAU, 48,
			Color(1.0, 0.86, 0.45, 0.25 * glow), 3.0 * _s, true)

	view.draw_circle(_skill_center, _skill_r, Color(accent.r, accent.g, accent.b, 0.26))
	# 蓝量环：0 弧度画不出来，留一点点，让"空蓝"和"没有这个按钮"在视觉上分得开
	var span: float = TAU * clampf(_mana_ratio, 0.0, 1.0)
	if span > 0.02:
		view.draw_arc(_skill_center, _skill_r, -PI / 2.0, -PI / 2.0 + span, 48,
			Color(accent.r, accent.g, accent.b, 0.95), 5.0 * _s, true)
	view.draw_arc(_skill_center, _skill_r, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.34), 1.5 * _s, true)

	if _press_flash > 0.0:
		view.draw_circle(_skill_center, _skill_r * (1.0 + 0.18 * (1.0 - _press_flash)),
			Color(1.0, 1.0, 1.0, 0.16 * _press_flash))

	var glyph: String = HeroClass.skill_name(_hero).substr(0, 1)
	_draw_text(view, glyph, _skill_center, int(26.0 * _s),
		Color(0.12, 0.1, 0.06) if ready else Color(0.92, 0.95, 1.0, 0.9))
	_draw_text(view, "技能", _skill_center + Vector2(0.0, _skill_r + 16.0 * _s), int(11.0 * _s),
		Color(accent.r, accent.g, accent.b, 0.75))


func _draw_text(view: Control, text: String, center: Vector2, size: int, color: Color) -> void:
	var font: Font = UiKit.font()
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	# draw_string 的坐标是基线左端，不是中心：手动减半宽、加约 0.35 字高把字摆正
	view.draw_string(font, Vector2(center.x - width * 0.5, center.y + float(size) * 0.35),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


## 只为了有个 _draw 回调的壳。拆成内部类是因为 CanvasLayer 自己不是 CanvasItem，
## 它画不了东西，必须挂一个 Control 上去。
class _TouchView:
	extends Control

	func _draw() -> void:
		var host: Node = get_parent()
		if host != null:
			host.call("paint_into", self)
