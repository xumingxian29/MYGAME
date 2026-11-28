class_name MeleeWeapon
extends Node2D

## 战士的武器：朝最近敌人挥出一道扇形斩击。
## 不做弹道——近战判定就是"挥砍瞬间扇形内所有敌人同时受伤"，
## 这样刀光和伤害范围严格一致，不会出现"刀光扫过去了却没打中"。

## 挥出一道斩击时发出。音效靠它触发——武器本身不认识音频系统，
## 只负责说"我砍了"，谁来听是上层的事。
signal swung()

## 由 Player 注入的敌人列表引用
var enemies: Array[Enemy] = []
## 迷宫引用。近战是扇形挥砍，判定只在角度和半径上——不加视线检查的话，
## 隔着一堵墙也能把墙后的怪砍死，而玩家看不到那一刀打到了什么。
var maze: MazeMap = null
## 破甲弹回调，由 Player 注入（同 BulletWeapon）。战士没有远程武器，
## 破甲弹完全靠挥砍花出去——没有这两行，战士捡到的弹一件都用不掉。
var breach_count: Callable = Callable()
var breach_take: Callable = Callable()

@export var enabled: bool = true
@export var damage: float = 26.0
@export var interval: float = 0.62
@export var reach: float = 100.0
@export var arc: float = deg_to_rad(110.0)

## 刀光持续时间。只影响绘制，判定在按下攻击那一刻就已经完成。
const SWING_TIME: float = 0.16

var _cooldown: float = 0.0
var _swing_t: float = 0.0
## 上一 tick 的挥砍剩余时间，供 _draw 补帧
var _prev_swing_t: float = 0.0
var _swing_angle: float = 0.0


## 刀光是自绘的，不走节点变换，引擎插值管不到。挥砍只有 0.16 秒（≈10 tick），
## 不补帧的话整段动画只有 10 个位置，120Hz 下每格要停两帧——最容易被看成"卡"的正是它。
func _process(_delta: float) -> void:
	if _swing_t > 0.0:
		queue_redraw()


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	_prev_swing_t = _swing_t
	if _swing_t > 0.0:
		_swing_t = maxf(_swing_t - delta, 0.0)
		queue_redraw()
	if _cooldown > 0.0:
		return
	var target: Enemy = _nearest_enemy()
	if target == null:
		return
	_cooldown = interval
	_swing_at(target.global_position)


func _nearest_enemy() -> Enemy:
	var best: Enemy = null
	var best_dist: float = (reach + 40.0) * (reach + 40.0)
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var dist: float = global_position.distance_squared_to(enemy.global_position)
		if dist < best_dist:
			best_dist = dist
			best = enemy
	return best


## 整刀最多花一发弹：扇形一刀能砍到五六只，按命中数扣弹会在两秒内清空库存。
func _take_ap() -> bool:
	if not breach_count.is_valid() or not breach_take.is_valid():
		return false
	if int(breach_count.call()) <= 0:
		return false
	return bool(breach_take.call())


func _swing_at(target_pos: Vector2) -> void:
	var to_target: Vector2 = target_pos - global_position
	_swing_angle = to_target.angle() if to_target.length() > 0.001 else 0.0
	_swing_t = SWING_TIME
	# 起手这一帧的"上一值"直接给成满时长，否则第一帧会被插到动画中段
	_prev_swing_t = SWING_TIME
	swung.emit()

	var ap: bool = _take_ap()
	var hit_damage: float = damage * (Player.AP_DAMAGE_SCALE if ap else 1.0)
	var half: float = arc * 0.5
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var off: Vector2 = enemy.global_position - global_position
		var dist: float = off.length()
		# 用 enemy.radius 放宽一点点：贴着刀光边缘的大块头也应该吃到伤害
		if dist > reach + enemy.radius:
			continue
		if dist > 0.001 and absf(angle_difference(_swing_angle, off.angle())) > half:
			continue
		# 视线检查放在最后：它是这里唯一做 4 次格查询的判定，
		# 前面几条距离/角度都是纯算术，先筛掉大部分才不会让挥砍变贵。
		if not _has_line_of_sight(enemy.global_position):
			continue
		enemy.take_damage(hit_damage, false, ap)
	queue_redraw()


## 刀光能不能"看到"目标。沿连线取 4 个点查可走格——
## 不取 8 个是因为一格 96 像素、刀长最多 180，4 个点已经保证不会跨过整格；
## 取多了只是重复查同一个格子。
func _has_line_of_sight(to_world: Vector2) -> bool:
	if maze == null:
		return true
	for i in range(1, 5):
		var t: float = float(i) / 5.0
		if not maze.has_floor_at(global_position.lerp(to_world, t)):
			return false
	return true


func _draw() -> void:
	if _swing_t <= 0.0:
		return
	# 在上一 tick 和这一 tick 的剩余时间之间取一次，整段刀光就从 10 个位置变成 60 个
	var f: float = Engine.get_physics_interpolation_fraction()
	var left: float = lerpf(_prev_swing_t, _swing_t, f)
	var progress: float = clampf(1.0 - left / SWING_TIME, 0.0, 1.0)
	var half: float = arc * 0.5
	# 刀光从内向外扫出去，配合透明度衰减，读起来像"甩了一下"
	var radius: float = reach * (0.74 + 0.26 * progress)
	var alpha: float = 1.0 - progress
	var steps: int = 16

	var sector := PackedVector2Array([Vector2.ZERO])
	var edge := PackedVector2Array()
	for i in range(steps + 1):
		var angle: float = _swing_angle - half + arc * float(i) / float(steps)
		var point := Vector2(cos(angle), sin(angle)) * radius
		sector.append(point)
		edge.append(point)
	draw_colored_polygon(sector, Color(1.0, 0.68, 0.4, 0.3 * alpha))
	draw_polyline(edge, Color(1.0, 0.92, 0.78, alpha), 3.0, true)
