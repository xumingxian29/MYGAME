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
## instance_id -> 剩余冷却秒数
var _hit_cd: Dictionary[int, float] = {}


func _physics_process(delta: float) -> void:
	if blades <= 0:
		return
	_angle = fmod(_angle + spin_speed * delta, TAU)
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
			var id: int = enemy.get_instance_id()
			if _hit_cd.has(id):
				continue
			# 刀身旋转角速度远低于子弹速度，用圆形近似即可，不会穿模
			if center.distance_squared_to(enemy.global_position) > pow(enemy.radius + blade_length * 0.45, 2.0):
				continue
			enemy.take_damage(damage)
			_hit_cd[id] = HIT_COOLDOWN


## 第 i 把飞刃的世界坐标中心
func _blade_center(i: int) -> Vector2:
	var angle: float = _angle + TAU * float(i) / float(maxi(blades, 1))
	return global_position + Vector2(cos(angle), sin(angle)) * orbit_radius


func _draw() -> void:
	if blades <= 0:
		return
	for i in range(blades):
		var angle: float = _angle + TAU * float(i) / float(maxi(blades, 1))
		var dir: Vector2 = Vector2(cos(angle), sin(angle))
		var inner: Vector2 = dir * (orbit_radius - blade_length * 0.5)
		var outer: Vector2 = dir * (orbit_radius + blade_length * 0.5)
		draw_line(inner, outer, Color(0.55, 0.95, 1.0, 0.28), BLADE_WIDTH + 6.0)
		draw_line(inner, outer, Color(0.75, 0.98, 1.0), BLADE_WIDTH)
