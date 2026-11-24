class_name Player
extends Node2D

## 玩家：WASD 移动、承受伤害，本身不含任何武器逻辑。
## 武器是子节点组件（BulletWeapon / OrbitWeapon / BoomerangWeapon），各自持有自己的可升级属性。
## enemies 数组由 Game 注入（同一引用），并转发给各武器。

signal health_changed(current: float, maximum: float)
signal died

## 相机缩放。Game 的刷怪距离按“刚好在视野外”计算，改动此处需同步刷怪距离。
const CAMERA_ZOOM: float = 1.35
const INVULN_TIME: float = 0.45
const BODY_RADIUS: float = 14.0
const FLASH_TIME: float = 0.18
const FLASH_COLOR: Color = Color(2.2, 1.2, 1.2)

## 屏幕震动用 trauma 模型：伤害累加 trauma，随时间线性衰减，位移取 trauma² 作幅度。
## 平方的意义是"轻击几乎不抖、重击抖得明显"，比直接用线性强度更像有重量。
const TRAUMA_DECAY: float = 1.7
## 位移幅度上限。实测 trauma=0.55（一次受击）时峰值约 6px：
## 打在 853 宽的世界视野里刚好"看得见但不晕"，再大就开始影响读屏了。
const SHAKE_MAX_OFFSET: float = 26.0

var max_health: float = 120.0
var health: float = 120.0
var move_speed: float = 240.0

var enemies: Array[Enemy] = []

var bullet_weapon: BulletWeapon
var orbit_weapon: OrbitWeapon
var boomerang_weapon: BoomerangWeapon
## 相机由玩家持有，震动直接改 offset，不需要额外的抖动节点
var camera: Camera2D

## 受击无敌帧：避免被一群敌人同时贴身时瞬间融化
var _invuln: float = 0.0
## 闪白剩余时长，倒数计时替代 Tween（理由同 Enemy）
var _flash_t: float = 0.0
## 当前震动强度 0~1，以及正弦相位（累加而不是取时间，避免暂停后跳变）
var _trauma: float = 0.0
var _shake_t: float = 0.0


func _ready() -> void:
	health = max_health

	bullet_weapon = BulletWeapon.new()
	bullet_weapon.enemies = enemies
	add_child(bullet_weapon)

	orbit_weapon = OrbitWeapon.new()
	orbit_weapon.enemies = enemies
	add_child(orbit_weapon)

	boomerang_weapon = BoomerangWeapon.new()
	boomerang_weapon.enemies = enemies
	add_child(boomerang_weapon)

	var camera_node := Camera2D.new()
	camera_node.position_smoothing_enabled = false
	camera_node.zoom = Vector2(CAMERA_ZOOM, CAMERA_ZOOM)
	add_child(camera_node)
	camera_node.make_current()
	camera = camera_node
	queue_redraw()


func _physics_process(delta: float) -> void:
	_invuln = maxf(_invuln - delta, 0.0)
	_tick_flash(delta)
	_tick_shake(delta)
	_move(delta)


## 由外部（受伤、击杀、死亡）累加。1.0 是满强度，多余部分直接夹掉，
## 避免连续受击把 trauma 叠到很大后震个没完。
func add_trauma(amount: float) -> void:
	_trauma = minf(_trauma + amount, 1.0)


## 位移用两个不同频率的正弦叠加而不是每帧 randf()：随机值在 60fps 下会变成高频噪点，
## 看起来像画面撕裂，正弦叠加才有"整块画面被推了一下"的惯性感。
func _tick_shake(delta: float) -> void:
	if camera == null:
		return
	if _trauma <= 0.0:
		if camera.offset != Vector2.ZERO:
			camera.offset = Vector2.ZERO
		return
	_trauma = maxf(_trauma - TRAUMA_DECAY * delta, 0.0)
	_shake_t += delta * 46.0
	var amp: float = SHAKE_MAX_OFFSET * _trauma * _trauma
	var offset := Vector2(
		sin(_shake_t * 1.7) + sin(_shake_t * 2.9) * 0.6,
		cos(_shake_t * 2.3) + cos(_shake_t * 3.7) * 0.6
	) * (amp * 0.5)
	camera.offset = offset


func _move(delta: float) -> void:
	var dir: Vector2 = _input_dir()
	if dir == Vector2.ZERO:
		return
	global_position += dir * move_speed * delta


## 走 InputMap（project.godot 的 [input] 段）而不是硬编码键码：
## 换键位、接手柄都不用改这里。get_vector 自带死区与归一化，斜向不会比直线快。
func _input_dir() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_up", "move_down")


func take_damage(amount: float) -> void:
	if health <= 0.0 or _invuln > 0.0:
		return
	_invuln = INVULN_TIME
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	_flash()
	if health <= 0.0:
		# 死亡会立刻暂停整棵树，抖动来不及衰减，会永久冻结在偏移位置，画面就歪了
		_trauma = 0.0
		if camera != null:
			camera.offset = Vector2.ZERO
		died.emit()
		return
	add_trauma(0.55)


func heal(amount: float) -> void:
	if health <= 0.0:
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


func _flash() -> void:
	_flash_t = FLASH_TIME


func _tick_flash(delta: float) -> void:
	if _flash_t <= 0.0:
		return
	_flash_t = maxf(_flash_t - delta, 0.0)
	if _flash_t <= 0.0:
		modulate = Color.WHITE
		return
	modulate = Color.WHITE.lerp(FLASH_COLOR, _flash_t / FLASH_TIME)


func _draw() -> void:
	draw_circle(Vector2.ZERO, BODY_RADIUS, Color(0.42, 0.83, 1.0))
	draw_arc(Vector2.ZERO, BODY_RADIUS, 0.0, TAU, 24, Color(0.9, 0.98, 1.0), 2.0, true)
	draw_circle(Vector2.ZERO, BODY_RADIUS * 0.45, Color(0.1, 0.28, 0.4))
