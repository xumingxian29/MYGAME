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

## 职业差异化的表现层：法师的能量球更大更紫，射手的箭矢细而绿
@export var shot_radius: float = 4.5
@export var shot_color: Color = Color(1.0, 0.95, 0.6)
## >0 时命中后对周围再造成 60% 伤害（法师能量球）
@export var splash_radius: float = 0.0
## >0 时命中附加减速（射手箭矢的"钉住"）。减速圈 Enemy 自己会画出来，
## 所以这是个玩家看得见的效果，不是暗改数值。
@export var slow_time: float = 0.0
@export var slow_factor: float = 0.0
## 战士没有远程武器，但节点仍然建出来并置 false，
## 避免卡池和升级逻辑里到处判空（那些代码大量引用本节的字段）
@export var enabled: bool = true

const SPLASH_FACTOR: float = 0.6
const SHOT_LIFETIME: float = 1.4
const HIT_RADIUS_PAD: float = 4.0

var _cooldown: float = 0.0
var _shots: Array[Dictionary] = []


func _physics_process(delta: float) -> void:
	if not enabled:
		return
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


## 只锁射程内最近的敌人，扩大射程才有实际收益。
## 但 Boss 在场时优先锁 Boss：Boss 慢、玩家一直在跑，它的位置通常在小怪后面，
## 按"最近"锁定的话子弹会被一路的小怪全部吃掉，Boss 血条几乎不动
## （实测同一只 Boss 的击杀时间从 14 秒飘到 49 秒，全看路上有多少小怪）。
func _nearest_enemy() -> Enemy:
	var best: Enemy = null
	var best_dist: float = attack_range * attack_range
	var boss: Enemy = null
	var boss_dist: float = best_dist
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var dist: float = global_position.distance_squared_to(enemy.global_position)
		if enemy.kind == Enemy.Kind.BOSS:
			if dist < boss_dist:
				boss_dist = dist
				boss = enemy
			continue
		if dist < best_dist:
			best_dist = dist
			best = enemy
	return boss if boss != null else best


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
		if slow_time > 0.0:
			enemy.apply_slow(slow_time, slow_factor)
		hit_ids.append(enemy.get_instance_id())
		if splash_radius > 0.0:
			_splash_at(pos, hit_ids)
		if int(shot["pierce"]) <= 1:
			return true
		shot["pierce"] = int(shot["pierce"]) - 1
	return false


## 命中点溅射：只打"这一发还没打过的"敌人，避免同一发子弹对同一目标算两次伤害
func _splash_at(at: Vector2, hit_ids: Array) -> void:
	var splash_damage: float = damage * SPLASH_FACTOR
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		if hit_ids.has(enemy.get_instance_id()):
			continue
		if enemy.global_position.distance_to(at) > splash_radius + enemy.radius:
			continue
		enemy.take_damage(splash_damage)
		hit_ids.append(enemy.get_instance_id())


## 射手技能的齐射：以自身为圆心均匀铺开，不索敌。
## 复用同一套弹道与命中判定，规则和普攻完全一致。
func fire_ring(count: int, damage_scale: float, pierce_override: int) -> void:
	var shots: int = maxi(count, 1)
	var start: float = randf() * TAU
	for i in range(shots):
		var angle: float = start + TAU * float(i) / float(shots)
		_shots.append({
			"pos": global_position,
			"vel": Vector2(cos(angle), sin(angle)) * projectile_speed,
			"life": SHOT_LIFETIME,
			"damage": damage * damage_scale,
			"pierce": pierce_override,
			"hits": [],
		})


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
		var tail: Vector2 = (shot["vel"] as Vector2).normalized() * shot_radius * 3.4
		draw_line(shot_pos - tail, shot_pos, Color(shot_color.r, shot_color.g, shot_color.b, 0.45), shot_radius * 0.9, true)
		draw_circle(shot_pos, shot_radius * 1.9, Color(shot_color.r, shot_color.g, shot_color.b, 0.2))
		draw_circle(shot_pos, shot_radius, shot_color)
