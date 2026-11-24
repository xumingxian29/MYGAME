class_name Enemy
extends Node2D

## 敌人：追踪目标、接触造成伤害、死亡上报。
## 目标由 Game 在生成时注入（target），敌人自身不查找玩家，避免场景耦合。

## 死亡时发出，由 Game 结算击杀数与经验。
signal died(enemy: Enemy, xp: int)

## 每次受击发出。位置和颜色随信号传，上层不用再读私有字段，也避免为此加 getter。
signal hit(at: Vector2, tint: Color)

const TOUCH_COOLDOWN: float = 1.0
## 分离力权重。1.6 足够把重叠的怪推开，又不至于让它们绕着玩家转圈。
const SEPARATION_WEIGHT: float = 1.6
## 受击闪白时长（秒）
const FLASH_TIME: float = 0.14
const FLASH_COLOR: Color = Color(2.6, 2.6, 2.6)

var target: Node2D = null

## 由 Game 每帧写入的分离方向（单位向量，没有邻居时为零）。
## 敌人自己不查找邻居：数据向下注入、事件向上发信号，保持单向依赖。
var separation: Vector2 = Vector2.ZERO

var max_health: float = 12.0
var touch_damage: float = 8.0
var xp_value: int = 1
var radius: float = 10.0
## 敌人等级：0 普通 / 1 精英。评分按等级分档，结算界面会分开统计。
var tier: int = 0

var _health: float = 0.0
var _speed: float = 70.0
var _color: Color = Color(0.85, 0.35, 0.42)
var _touch_cd: float = 0.0
var _drift: float = 0.0
var _dead: bool = false
## 闪白剩余时长。用倒数计时而不是 Tween：高密度下每秒会有上千次受击，
## create_tween() 会持续分配对象，而且同一敌人连续受击时多个 Tween 会互抢 modulate。
var _flash_t: float = 0.0


## 在 add_child 之前调用，一次配置好本敌人的属性。
func configure(p_health: float, p_speed: float, p_big: bool) -> void:
	max_health = p_health
	_health = p_health
	_speed = p_speed
	if p_big:
		tier = 1
		radius = 17.0
		touch_damage = 12.0
		xp_value = 6
		_color = Color(0.62, 0.34, 0.86)
	else:
		tier = 0
		radius = 10.0
		touch_damage = 6.0
		xp_value = 2
		_color = Color(0.86, 0.33, 0.41)
	queue_redraw()


func _ready() -> void:
	if _health <= 0.0:
		_health = max_health
	_drift = randf_range(-0.4, 0.4)
	queue_redraw()


func _physics_process(delta: float) -> void:
	_tick_flash(delta)
	if _dead or not is_instance_valid(target):
		return

	_touch_cd = maxf(_touch_cd - delta, 0.0)

	var to_target: Vector2 = target.global_position - global_position
	var dist: float = to_target.length()
	if dist > 0.001:
		var dir: Vector2 = to_target / dist
		# 轻微侧向漂移，避免全体敌人叠成一条直线
		dir = (dir + dir.orthogonal() * _drift).normalized()
		# 分离力只改方向不改速度：总长度封顶 1，所以被挤住时会自然减速，
		# 而不是从邻居身上穿过去
		var steer: Vector2 = (dir + separation * SEPARATION_WEIGHT).limit_length(1.0)
		global_position += steer * _speed * delta

	if dist <= radius + 16.0 and _touch_cd <= 0.0:
		if target.has_method("take_damage"):
			target.call("take_damage", touch_damage)
			_touch_cd = TOUCH_COOLDOWN


func take_damage(amount: float) -> void:
	if _dead:
		return
	_health -= amount
	# 致死那一击也要出火花，所以先发 hit 再判死
	hit.emit(global_position, _color)
	if _health <= 0.0:
		_dead = true
		died.emit(self, xp_value)
		queue_free()
		return
	queue_redraw()
	_flash()


func _flash() -> void:
	_flash_t = FLASH_TIME


## 闪白衰减：亮到白是线性回落，比 Tween 少一次对象分配，也不会被后一次受击打断
func _tick_flash(delta: float) -> void:
	if _flash_t <= 0.0:
		return
	_flash_t = maxf(_flash_t - delta, 0.0)
	if _flash_t <= 0.0:
		modulate = Color.WHITE
		return
	modulate = Color.WHITE.lerp(FLASH_COLOR, _flash_t / FLASH_TIME)


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, _color)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 20, _color.darkened(0.45), 2.0, true)
	draw_circle(Vector2.ZERO, radius * 0.35, _color.darkened(0.55))

	if _health < max_health and _health > 0.0:
		var width: float = radius * 2.0
		var ratio: float = clampf(_health / max_health, 0.0, 1.0)
		draw_rect(Rect2(-radius, -radius - 9.0, width, 3.0), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(-radius, -radius - 9.0, width * ratio, 3.0), Color(0.95, 0.25, 0.25))
