class_name BulletWeapon
extends Node2D

## 自动索敌子弹武器。作为 Player 的子节点，坐标与玩家重合，因此局部坐标可直接绘制弹丸。
## enemies 由 Player 注入（同一数组引用），不由本节点自己查找父节点。

## 由 Player 注入的敌人列表引用
var enemies: Array[Enemy] = []

@export var damage: float = 14.0
@export var interval: float = 0.5
@export var attack_range: float = 420.0
@export var projectile_speed: float = 780.0
@export var projectiles_per_shot: int = 1
@export var pierce: int = 1

const SHOT_LIFETIME: float = 1.4
const HIT_RADIUS_PAD: float = 4.0

var _cooldown: float = 0.0
var _shots: Array[Dictionary] = []


func _physics_process(delta: float) -> void:
	_update_fire(delta)
	_update_shots(delta)


func _update_fire(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _cooldown > 0.0:
		return
	var target: Enemy = _nearest_enemy()
	if target == null:
		return
	_cooldown = interval
	_fire_at(target.global_position)


## 只锁射程内最近的敌人，扩大射程才有实际收益
func _nearest_enemy() -> Enemy:
	var best: Enemy = null
	var best_dist: float = attack_range * attack_range
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var dist: float = global_position.distance_squared_to(enemy.global_position)
		if dist < best_dist:
			best_dist = dist
			best = enemy
	return best


func _fire_at(target_pos: Vector2) -> void:
	var dir: Vector2 = (target_pos - global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var count: int = maxi(projectiles_per_shot, 1)
	var spread: float = deg_to_rad(9.0)
	for i in range(count):
		var offset: float = 0.0
		if count > 1:
			offset = (float(i) - float(count - 1) * 0.5) * spread
		_shots.append({
			"pos": global_position,
			"vel": dir.rotated(offset) * projectile_speed,
			"life": SHOT_LIFETIME,
			"damage": damage,
			"pierce": pierce,
			"hits": [],
		})


func _update_shots(delta: float) -> void:
	if _shots.is_empty():
		return
	var index: int = _shots.size() - 1
	while index >= 0:
		var shot: Dictionary = _shots[index]
		var pos: Vector2 = shot["pos"]
		var vel: Vector2 = shot["vel"]
		pos += vel * delta
		shot["pos"] = pos
		shot["life"] = float(shot["life"]) - delta

		var remove: bool = float(shot["life"]) <= 0.0
		if not remove:
			remove = _resolve_hit(shot, pos, vel)
		if remove:
			_shots.remove_at(index)
		index -= 1
	queue_redraw()


## 返回 true 表示该弹丸应当销毁。命中后按剩余穿透次数决定是否继续飞行。
func _resolve_hit(shot: Dictionary, pos: Vector2, vel: Vector2) -> bool:
	var hit_ids: Array = shot["hits"]
	# 用本帧步进线段近似判定，避免高速弹丸穿过敌人
	var prev_pos: Vector2 = pos - vel * get_physics_process_delta_time()
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		if hit_ids.has(enemy.get_instance_id()):
			continue
		if _segment_distance(prev_pos, pos, enemy.global_position) > enemy.radius + HIT_RADIUS_PAD:
			continue
		enemy.take_damage(float(shot["damage"]))
		hit_ids.append(enemy.get_instance_id())
		if int(shot["pierce"]) <= 1:
			return true
		shot["pierce"] = int(shot["pierce"]) - 1
	return false


func _segment_distance(from: Vector2, to: Vector2, point: Vector2) -> float:
	var segment: Vector2 = to - from
	var length_sq: float = segment.length_squared()
	if length_sq <= 0.0001:
		return from.distance_to(point)
	var t: float = clampf((point - from).dot(segment) / length_sq, 0.0, 1.0)
	return (from + segment * t).distance_to(point)


func _draw() -> void:
	for shot in _shots:
		var shot_pos: Vector2 = shot["pos"] - global_position
		draw_circle(shot_pos, 8.0, Color(1.0, 0.85, 0.3, 0.2))
		draw_circle(shot_pos, 4.5, Color(1.0, 0.95, 0.6))
