class_name BossStrike
extends Node2D

## 裂地落点：地面上的一处预警圈，0.95 秒后炸开。
##
## 为什么单独做成节点而不是画在 Boss 身上：
## 落点在**世界坐标**里，和 Boss 的位置无关（它会飘在玩家脚下），
## 而 Boss 的 _draw 只能在自身局部坐标里画。硬画在 Boss 身上要么每帧换算，
## 要么跟着 Boss 一起动——后者会让"落点"变成"跟踪导弹"。
##
## 时间比招式短、数量比招式多：一次裂地会同时存在 3~4 个落点，
## 玩家要读的不是单个圈，而是"这几个圈之间哪块地是空的"。

## 炸开时发出。Game 用它放火花、震屏、音效——
## 落点自己只知道"我炸了、谁在圈里"，不知道世界长什么样。
signal detonated(at: Vector2, strike_radius: float)

## 预警时长。0.95 秒 ≈ 玩家从圈心跑到圈外（半径 76 + 玩家 12，240 移速）的两倍，
## 站着不动必中，起步晚半秒也还能出去。
const WARMUP: float = 0.95

var target: Node2D = null
var radius: float = 76.0
var damage: float = 20.0
var tint: Color = Color(1.0, 0.52, 0.24)

var _t: float = 0.0
var _done: bool = false


func _physics_process(delta: float) -> void:
	if _done:
		return
	_t += delta
	queue_redraw()
	if _t >= WARMUP:
		_detonate()


## 炸开。判定用"圆心距离 ≤ 半径"，和冲击波同一套语义：
## 边缘擦到算中，视觉上圈在哪就打到哪。
func _detonate() -> void:
	_done = true
	detonated.emit(global_position, radius)
	if is_instance_valid(target) and global_position.distance_to(target.global_position) <= radius:
		if target.has_method("take_damage"):
			target.call("take_damage", damage)
	queue_free()


func _draw() -> void:
	var t: float = clampf(_t / WARMUP, 0.0, 1.0)
	# 外圈是判定边界（定死不动），内圈是涨上来的进度。
	# 只画外圈的话玩家分不清"刚亮起"和"快炸了"；只画内圈则看不出边界在哪。
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(tint, 0.42 + 0.35 * t), 2.0, true)
	draw_circle(Vector2.ZERO, radius * t, Color(tint, 0.10 + 0.18 * t))
	draw_arc(Vector2.ZERO, radius * t, 0.0, TAU, 40, Color(tint.lightened(0.25), 0.5 + 0.45 * t), 3.0, true)

	# 中心十字：地裂是"从这一点裂开"，给一个明确的落点中心，
	# 玩家才知道该往哪个方向迈第一步。
	var arm: float = radius * (0.25 + 0.35 * t)
	draw_line(Vector2(-arm, 0.0), Vector2(arm, 0.0), Color(tint, 0.35 + 0.4 * t), 2.0)
	draw_line(Vector2(0.0, -arm), Vector2(0.0, arm), Color(tint, 0.35 + 0.4 * t), 2.0)
