class_name BoomerangWeapon
extends Node2D

## 回旋镖：向四周投出后自动飞回。位移始终相对玩家计算，所以玩家跑动时飞镖也会回到手上。
## count = 0 表示尚未解锁。
## 命中用“每敌人独立冷却”：一枚镖一次飞行可多次命中同一敌人，但不会每帧都叠伤害。

## 由 Player 注入的敌人列表引用
var enemies: Array[Enemy] = []

@export var count: int = 0
@export var damage: float = 14.0
@export var fly_speed: float = 520.0
@export var fly_distance: float = 300.0
@export var cooldown: float = 2.2
@export var spin_speed: float = 15.0

const HIT_COOLDOWN: float = 0.5
const HIT_RADIUS: float = 13.0
const ARM_LENGTH: float = 13.0
const ARM_WIDTH: float = 5.0
const MAX_FLIGHTS: int = 6

var _cd: float = 0.0
var _spin: float = 0.0
## 每一波投掷：{"dirs": Array[float], "t": float}
var _flights: Array[Dictionary] = []
## instance_id -> 剩余冷却秒数
var _hit_cd: Dictionary[int, float] = {}


func _physics_process(delta: float) -> void:
	if count <= 0:
		return
	_spin = fmod(_spin + spin_speed * delta, TAU)
	_tick_cooldowns(delta)
	_update_flights(delta)
	_cd = maxf(_cd - delta, 0.0)
	if _cd <= 0.0:
		_throw()
	queue_redraw()


## 总飞行时长（飞出去 + 飞回来）
func _duration() -> float:
	return maxf(2.0 * fly_distance / maxf(fly_speed, 1.0), 0.15)


func _throw() -> void:
	_cd = cooldown
	var base: float = _aim_angle()
	var n: int = maxi(count, 1)
	var dirs: Array[float] = []
	for i in range(n):
		# 均匀铺满一圈：1 枚朝最近敌人，2 枚对向，3 枚 120° 分布
		dirs.append(base + TAU * float(i) / float(n))
	_flights.append({"dirs": dirs, "t": 0.0})
	while _flights.size() > MAX_FLIGHTS:
		_flights.remove_at(0)


func _aim_angle() -> float:
	var best: Enemy = null
	var best_dist: float = INF
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var dist: float = global_position.distance_squared_to(enemy.global_position)
		if dist < best_dist:
			best_dist = dist
			best = enemy
	if best == null:
		return 0.0
	return (best.global_position - global_position).angle()


func _update_flights(delta: float) -> void:
	if _flights.is_empty():
		return
	var duration: float = _duration()
	var index: int = _flights.size() - 1
	while index >= 0:
		var flight: Dictionary = _flights[index]
		flight["t"] = float(flight["t"]) + delta
		var progress: float = clampf(float(flight["t"]) / duration, 0.0, 1.0)
		# 三角波：去程与回程速度都是 fly_speed，不会出现中途突然加速
		var reach: float = progress * 2.0
		if reach > 1.0:
			reach = 2.0 - reach
		var radius: float = fly_distance * reach
		for dir in flight["dirs"]:
			_resolve_hit(Vector2(cos(dir), sin(dir)) * radius)

		if progress >= 1.0:
			_flights.remove_at(index)
		index -= 1


func _resolve_hit(local_pos: Vector2) -> void:
	var world_pos: Vector2 = global_position + local_pos
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var id: int = enemy.get_instance_id()
		if _hit_cd.has(id):
			continue
		var reach: float = enemy.radius + HIT_RADIUS
		if world_pos.distance_squared_to(enemy.global_position) > reach * reach:
			continue
		enemy.take_damage(damage)
		_hit_cd[id] = HIT_COOLDOWN


func _tick_cooldowns(delta: float) -> void:
	if _hit_cd.is_empty():
		return
	for key in _hit_cd.keys():
		var left: float = _hit_cd[key] - delta
		if left <= 0.0:
			_hit_cd.erase(key)
		else:
			_hit_cd[key] = left


func _draw() -> void:
	if count <= 0:
		return
	var duration: float = _duration()
	for flight in _flights:
		var progress: float = clampf(float(flight["t"]) / duration, 0.0, 1.0)
		var reach: float = progress * 2.0
		if reach > 1.0:
			reach = 2.0 - reach
		var radius: float = fly_distance * reach
		for i in range(flight["dirs"].size()):
			var dir: float = flight["dirs"][i]
			var pos: Vector2 = Vector2(cos(dir), sin(dir)) * radius
			var spin: float = _spin + float(i) * 1.3
			# 两片呈 V 形的镖臂，一眼能认出是回旋镖而不是子弹
			draw_colored_polygon(_arm_points(pos, spin - 0.95), Color(1.0, 0.72, 0.3))
			draw_colored_polygon(_arm_points(pos, spin + 0.95), Color(1.0, 0.88, 0.56))
			draw_circle(pos, 3.2, Color(0.28, 0.16, 0.06))


func _arm_points(center: Vector2, angle: float) -> PackedVector2Array:
	var dir := Vector2(cos(angle), sin(angle))
	var side := dir.orthogonal() * ARM_WIDTH
	var tip: Vector2 = center + dir * ARM_LENGTH
	return PackedVector2Array([
		center - side,
		tip - side * 0.7,
		tip + side * 0.7,
		center + side,
	])
