class_name ItemModule
extends Node2D

## 破甲弹（道具模组）：地上的一枚金色壳片，捡起来才打得动 Boss。
##
## 为什么做成"捡起来就走"的掉落物而不是背包/装备：
## 一局只有 5~8 分钟，任何需要打开界面操作的系统都会打断节奏。
## 玩家要做的决定只有一个——"这个位置危不危险，值不值得绕过去捡"。
##
## 磁吸半径比经验宝石小（220 vs 360）：破甲弹是有限资源，
## 如果隔着半个屏幕自动飞过来，"要不要冒险去捡"这个决定就不存在了。

signal collected(item: ItemModule)

const MAGNET_RADIUS: float = 220.0
const PICKUP_RADIUS: float = 18.0
const MAX_SPEED: float = 760.0
const ACCEL: float = 1400.0
## 掉在毒圈外的自己飘回来，否则会变成"看得见捡不到"
const RETURN_DISTANCE: float = 620.0

var target: Node2D = null

var _speed: float = 0.0
var _phase: float = 0.0
var _age: float = 0.0


func _ready() -> void:
	_phase = randf() * TAU
	queue_redraw()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return

	_age += delta
	_phase += delta * 3.2
	# 呼吸 + 缓慢自转：静止的掉落物在满屏敌人里几乎看不见，必须有点动静
	scale = Vector2.ONE * (1.0 + sin(_phase) * 0.12)
	rotation = sin(_age * 1.6) * 0.18

	var to_target: Vector2 = target.global_position - global_position
	var dist: float = to_target.length()
	if dist <= PICKUP_RADIUS:
		collected.emit(self)
		queue_free()
		return
	if dist <= MAGNET_RADIUS:
		_speed = minf(_speed + ACCEL * delta, MAX_SPEED)
		global_position += to_target / dist * _speed * delta
	elif dist > RETURN_DISTANCE:
		_speed = 0.0
		global_position += to_target / dist * minf(620.0, dist * 1.15) * delta
	else:
		_speed = 0.0


func _draw() -> void:
	var gold := Color(1.0, 0.78, 0.32)
	# 外层光和内层实体：先画大圈的淡光，再画实心，压在一起才像"在发光"
	draw_circle(Vector2.ZERO, 17.0, Color(gold.r, gold.g, gold.b, 0.16))
	draw_circle(Vector2.ZERO, 11.0, Color(gold.r, gold.g, gold.b, 0.34))

	# 六边形壳片：和圆形的小兵、菱形的经验宝石在形状上彻底区分开，
	# 满屏敌人时玩家靠轮廓就能认出"那是破甲弹"。
	var points := PackedVector2Array()
	for i in range(6):
		var angle: float = TAU * float(i) / 6.0 - PI * 0.5
		points.append(Vector2(cos(angle), sin(angle)) * 9.0)
	draw_colored_polygon(points, gold)
	var outline: PackedVector2Array = points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, Color(1.0, 0.95, 0.8), 1.6)

	# 中心一道竖裂：暗示"这是用来破壳的"，不是又一种经验值
	draw_line(Vector2(0.0, -5.0), Vector2(0.0, 5.0), Color(0.22, 0.12, 0.02), 1.8)
	draw_line(Vector2(-3.4, -1.2), Vector2(3.4, 1.2), Color(0.22, 0.12, 0.02), 1.4)
