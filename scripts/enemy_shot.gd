class_name EnemyShot
extends Node2D

## 敌人子弹：只做"直线飞、碰到玩家扣血、超时消失"三件事。
## 由 Game 在收到 Enemy.spit 信号时创建，自己不知道 Game 的存在。

## 判定半径。玩家的碰撞近似取 16（Player.BODY_RADIUS 是 14，留 2px 宽容量）
const RADIUS: float = 5.0
const TARGET_RADIUS: float = 16.0
## 超时时间：飞出视野太久的一定打不到人，留着只是拖性能
const LIFETIME: float = 4.5

## 迷宫引用，由 Game 生成时注入。敌人子弹同样不能穿墙：
## 否则躲在拐角后面反而更危险，因为你看不见它、它却打得中你。
var maze: MazeMap = null
var velocity: Vector2 = Vector2.ZERO
var damage: float = 8.0
var target: Node2D = null
## >0 时变成追踪弹：每帧把速度方向朝目标转，单位是弧度/秒。
## 转向速度必须有上限——"绝对必中"的追踪弹不叫威胁，叫结算动画。
## 2.2 rad/s 意味着它大约要 1.4 秒才能掉头，绕圈跑得动就能甩脱。
var homing_turn: float = 0.0
## 追踪弹每帧按这个速率重算，避免"转向后总速度变短"导致追上来的速度越来越慢
var homing_speed: float = 0.0
## 弹体颜色。吐息者是青绿，Boss 弹幕是暗红——同一屏里两种弹混着飞时，
## 玩家靠颜色就能判断"这发该不该优先躲"。
var color: Color = Color(0.74, 0.99, 0.86)

var _life: float = 0.0


func _physics_process(delta: float) -> void:
	_life += delta
	if _life >= LIFETIME:
		queue_free()
		return

	global_position += velocity * delta
	if maze != null and not maze.has_floor_at(global_position):
		queue_free()
		return
	_tick_homing(delta)

	if not is_instance_valid(target):
		return
	if global_position.distance_to(target.global_position) <= RADIUS + TARGET_RADIUS:
		if target.has_method("take_damage"):
			target.call("take_damage", damage)
		queue_free()


## 追踪：先算"目标方向"，再按最大转向角速度把当前方向拧过去。
## 直接朝目标赋值会让弹道变成贴脸拐弯，玩家没有任何反制余地。
func _tick_homing(delta: float) -> void:
	if homing_turn <= 0.0 or homing_speed <= 0.0:
		return
	if not is_instance_valid(target):
		return
	var want: Vector2 = target.global_position - global_position
	if want.length_squared() < 1.0:
		return
	var current: float = velocity.angle()
	var delta_angle: float = wrapf(want.angle() - current, -PI, PI)
	var step: float = clampf(delta_angle, -homing_turn * delta, homing_turn * delta)
	velocity = Vector2.from_angle(current + step) * homing_speed


func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS, color)
	draw_arc(Vector2.ZERO, RADIUS + 3.0, 0.0, TAU, 14, Color(color.r, color.g, color.b, 0.45), 2.0, true)
	# 追踪弹多一道"锁定环"：玩家要能一眼分出"这发会拐弯，得持续跑"
	if homing_turn > 0.0:
		draw_arc(Vector2.ZERO, RADIUS + 6.5, 0.0, TAU, 18, Color(1.0, 0.62, 0.86, 0.75), 1.5, true)
