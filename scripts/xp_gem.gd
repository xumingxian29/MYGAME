class_name XpGem
extends Node2D

## 经验宝石：留在原地，玩家进入磁吸范围后加速飞向玩家，接触即上报经验。
## target 由 Game 注入，宝石不自己查找玩家。

## 被玩家拾取时发出，由 Game 结算经验。
signal collected(gem: XpGem, value: int)

const MAGNET_RADIUS: float = 360.0
const PICKUP_RADIUS: float = 16.0
const MAX_SPEED: float = 920.0
const ACCEL: float = 1500.0
## 掉在很远处的宝石自己飘回来（速度按距离缩放，保证追得上跑动中的玩家），
## 避免子弹在射程边缘击杀时经验永久丢在地上。
const RETURN_DISTANCE: float = 700.0

var value: int = 1
var target: Node2D = null

## 数字用的字体。宝石是高频生成/销毁的对象，每个都 new 一个 SystemFont 会不断分配系统资源
static var _font: Font

var _speed: float = 0.0
var _phase: float = 0.0
var _radius: float = 6.0


func _ready() -> void:
	if _font == null:
		_font = UiKit.font()
	_phase = randf() * TAU
	_radius = 8.5 if value < 3 else 11.0
	queue_redraw()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return

	# 呼吸缩放做一点"可拾取"的暗示，不需要重绘
	_phase += delta * 4.0
	scale = Vector2.ONE * (1.0 + sin(_phase) * 0.1)

	var to_target: Vector2 = target.global_position - global_position
	var dist: float = to_target.length()
	if dist <= PICKUP_RADIUS:
		collected.emit(self, value)
		queue_free()
		return
	if dist <= MAGNET_RADIUS:
		_speed = minf(_speed + ACCEL * delta, MAX_SPEED)
		global_position += to_target / dist * _speed * delta
	elif dist > RETURN_DISTANCE:
		_speed = 0.0
		global_position += to_target / dist * minf(700.0, dist * 1.2) * delta
	else:
		_speed = 0.0


func _draw() -> void:
	var color: Color = Color(0.4, 0.95, 0.85) if value < 3 else Color(0.85, 0.55, 1.0)
	draw_circle(Vector2.ZERO, _radius * 2.1, Color(color.r, color.g, color.b, 0.22))
	var points := PackedVector2Array([
		Vector2(0.0, -_radius),
		Vector2(_radius * 0.62, 0.0),
		Vector2(0.0, _radius),
		Vector2(-_radius * 0.62, 0.0),
	])
	draw_colored_polygon(points, color)
	var outline: PackedVector2Array = points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, color.lightened(0.6), 1.5)

	# 经验值直接写在宝石上：玩家一眼就能看出这个球值不值得绕路去捡。
	# 深色字压在亮色宝石上，比白字更清楚，也不用描边。
	if _font != null:
		draw_string(_font, Vector2(-10.0, 4.2), str(value), HORIZONTAL_ALIGNMENT_CENTER, 20.0, 11,
			Color(0.02, 0.04, 0.07))
