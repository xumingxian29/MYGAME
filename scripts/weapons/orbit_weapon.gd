class_name OrbitWeapon
extends Node2D

## 环绕飞刃：围绕玩家旋转的近身武器，用“每敌人独立冷却”防止一个敌人被连续多帧刮到秒杀。
## blades = 0 表示尚未解锁，节点不绘制也不判定。

## 由 Player 注入的敌人列表引用
var enemies: Array[Enemy] = []

@export var blades: int = 0
@export var damage: float = 9.0
@export var orbit_radius: float = 62.0
@export var spin_speed: float = 2.6
@export var blade_length: float = 28.0

const HIT_COOLDOWN: float = 0.45
const BLADE_WIDTH: float = 7.0

var _angle: float = 0.0
## 只给 _draw 用的不取模累加角。判定必须继续用取模的 _angle——
## 那是纯逻辑量，动它的末位就会改变命中判定（实测同一颗种子的整局时长因此从
## 307.4s 飘到 161.5s）。绘制量单独记一份，两不相干。
var _draw_angle: float = 0.0
var _prev_draw_angle: float = 0.0
## 敌人生成序号(spawn_serial) -> 剩余冷却秒数
var _hit_cd: Dictionary[int, float] = {}


## 飞刃是自绘的，不走节点变换，所以引擎的物理插值管不到——
## 每渲染帧重绘一次，_draw 自己按插值分数补帧。
func _process(_delta: float) -> void:
	if blades > 0:
		queue_redraw()


func _physics_process(delta: float) -> void:
	if blades <= 0:
		return
	_angle = fmod(_angle + spin_speed * delta, TAU)
	_prev_draw_angle = _draw_angle
	_draw_angle += spin_speed * delta
	_tick_cooldowns(delta)
	_resolve_hits()
	queue_redraw()


func _tick_cooldowns(delta: float) -> void:
	for key in _hit_cd.keys():
		var left: float = _hit_cd[key] - delta
		if left <= 0.0:
			_hit_cd.erase(key)
		else:
			_hit_cd[key] = left


func _resolve_hits() -> void:
	for i in range(blades):
		var center: Vector2 = _blade_center(i)
		for enemy in enemies:
			if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
				continue
			# 键用本局生成序号而不是 instance_id：id 每个进程取值都不同，
			# 同一颗种子跑两次的日志没法对账（见 enemy.gd 的 spawn_serial）
			var key: int = enemy.spawn_serial
			if _hit_cd.has(key):
				continue
			# 刀身旋转角速度远低于子弹速度，用圆形近似即可，不会穿模
			if center.distance_squared_to(enemy.global_position) > pow(enemy.radius + blade_length * 0.45, 2.0):
				continue
			enemy.take_damage(damage)
			_hit_cd[key] = HIT_COOLDOWN


## 第 i 把飞刃的世界坐标中心
func _blade_center(i: int) -> Vector2:
	var angle: float = _angle + TAU * float(i) / float(maxi(blades, 1))
	return global_position + Vector2(cos(angle), sin(angle)) * orbit_radius


func _draw() -> void:
	if blades <= 0:
		return
	# 角度插值：飞刃切向速度约 160 像素/秒，一 tick 走 2.7 单位（≈3.6 屏幕像素），
	# 不补帧的话 120Hz 下每片刃会"顿两下再跳"。
	var f: float = Engine.get_physics_interpolation_fraction()
	var angle_now: float = fposmod(lerpf(_prev_draw_angle, _draw_angle, f), TAU)
	for i in range(blades):
		var angle: float = angle_now + TAU * float(i) / float(maxi(blades, 1))
		var dir: Vector2 = Vector2(cos(angle), sin(angle))
		var inner: Vector2 = dir * (orbit_radius - blade_length * 0.5)
		var outer: Vector2 = dir * (orbit_radius + blade_length * 0.5)
		draw_line(inner, outer, Color(0.55, 0.95, 1.0, 0.28), BLADE_WIDTH + 6.0)
		draw_line(inner, outer, Color(0.75, 0.98, 1.0), BLADE_WIDTH)
