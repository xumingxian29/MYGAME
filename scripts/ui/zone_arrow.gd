class_name ZoneArrow
extends Control

## 屏外方向箭头：把"安全区在那边"画成屏幕边缘的一个三角。
##
## 为什么必须有：圈心每轮会挪位，缩到 0.85V 之后整条边界可能整块滑出屏幕。
## 这时玩家只看到"圈外！-11%/秒"的红字，却不知道往哪个方向跑——只能乱撞。
## 箭头把方向信息补上，它与地面紫圈是同一件事的两种表达：圈在屏幕内看圈，出屏了看箭头。
##
## 只画一个三角，不画文字：文字在 10Hz 刷新下会闪，箭头靠颜色就够了
## （紫色=还活着但圈远了，红色=你正在圈外掉血）。

const COLOR_SAFE: Color = Color(0.74, 0.52, 1.0, 0.85)
const COLOR_OUTSIDE: Color = Color(1.0, 0.36, 0.36, 0.95)
## 箭头到屏幕边缘的留白。贴着边会被圆角/刘海切掉一截。
const EDGE_MARGIN: float = 46.0
const SIZE_PX: float = 16.0

var _dir: Vector2 = Vector2.ZERO
var _outside: bool = false
var _pulse: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false


## 每帧都可以调，但只有"方向或状态变了"才会真的重绘。
## dir 是玩家指向圈心的**屏幕像素位移**（世界位移 × 相机缩放），长度要和屏幕尺寸同量级，
## 否则"圈心还在屏幕上"这个判断会算错量级。outside 表示玩家此刻在圈外。
func set_target(dir: Vector2, outside: bool) -> void:
	var should_show: bool = dir.length() > 1.0 and (outside or dir.length() > _edge_reach())
	if not should_show:
		if visible:
			visible = false
		return
	_dir = dir.normalized()
	_outside = outside
	if not visible:
		visible = true
	queue_redraw()


## 圈心在屏幕上还看得见时不画箭头：这时候玩家看地面那条紫线更直观。
func _edge_reach() -> float:
	var half: Vector2 = size * 0.5
	return minf(half.x, half.y) * 1.2


func _process(delta: float) -> void:
	# 菜单/结算时 HUD 的 _root 被藏起来，但本节点的 visible 仍是 true；
	# 不查 is_visible_in_tree 的话会白跑每帧一次重绘
	if not visible or not is_visible_in_tree():
		return
	_pulse = fmod(_pulse + delta, TAU)
	queue_redraw()


func _draw() -> void:
	if not visible or _dir == Vector2.ZERO:
		return
	var half: Vector2 = size * 0.5 - Vector2(EDGE_MARGIN, EDGE_MARGIN)
	if half.x <= 8.0 or half.y <= 8.0:
		return
	# 从屏幕中心沿方向推到边缘：取两个轴里更早撞墙的那个比例
	var scale_x: float = absf(half.x / _dir.x) if absf(_dir.x) > 0.001 else INF
	var scale_y: float = absf(half.y / _dir.y) if absf(_dir.y) > 0.001 else INF
	var at: Vector2 = size * 0.5 + _dir * minf(scale_x, scale_y)

	var side: Vector2 = _dir.orthogonal()
	var tip: Vector2 = at + _dir * SIZE_PX
	var back: Vector2 = at - _dir * SIZE_PX * 0.35
	var base: Color = COLOR_OUTSIDE if _outside else COLOR_SAFE
	# 圈外时呼吸更急：这是"立刻要动"的信号，不是装饰
	var speed: float = 6.0 if _outside else 3.2
	var alpha: float = base.a * (0.72 + 0.28 * sin(_pulse * speed))
	var color: Color = Color(base.r, base.g, base.b, alpha)
	draw_colored_polygon(PackedVector2Array([
		tip,
		back + side * SIZE_PX * 0.85,
		back - side * SIZE_PX * 0.85,
	]), color)
