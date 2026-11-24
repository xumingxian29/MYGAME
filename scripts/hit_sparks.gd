class_name HitSparks
extends Node2D

## 命中火花：所有粒子存在几组并行的 Packed 数组里，由这**一个**节点统一 _draw。
## 不为每颗火花建节点——高密度下每秒数百次命中，节点分配 + 场景树遍历的开销
## 远大于绘制本身，而且 Godot 不会跨节点合批自绘命令，节点化只会更慢。

## 粒子数硬上限。超出后新的直接丢弃：视觉上早已乱成一团，多画也看不出来。
const MAX_PARTICLES: int = 260
const BASE_LIFE: float = 0.24
const SPEED_MIN: float = 90.0
const SPEED_MAX: float = 260.0
## 每秒阻尼系数与重力，给火花一点"重量"，纯匀速看起来像静止的线
const DAMP: float = 5.5
const GRAVITY: float = 340.0

var _pos: PackedVector2Array = PackedVector2Array()
var _vel: PackedVector2Array = PackedVector2Array()
var _col: PackedColorArray = PackedColorArray()
var _age: PackedFloat32Array = PackedFloat32Array()
var _life: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	# 画在敌人（z_index 0）之上，又不至于盖住 HUD（CanvasLayer 独立于本层）
	z_index = 2


## 在 [param at] 处炸开 count 颗火花，方向全随机（命中方向由武器决定，
## 但火花只是装饰，全向喷散在任何角度下都成立）。
func burst(at: Vector2, tint: Color, count: int) -> void:
	var free: int = MAX_PARTICLES - _pos.size()
	if free <= 0:
		return
	for i in range(mini(count, free)):
		var angle: float = randf() * TAU
		var speed: float = randf_range(SPEED_MIN, SPEED_MAX)
		_pos.append(at)
		_vel.append(Vector2(cos(angle), sin(angle)) * speed)
		_col.append(tint)
		_age.append(0.0)
		_life.append(BASE_LIFE * randf_range(0.7, 1.2))


func _process(delta: float) -> void:
	if _pos.is_empty():
		return
	# 倒序遍历：删除时用末尾元素填补，不会跳过还没处理的粒子
	var i: int = _pos.size() - 1
	while i >= 0:
		_age[i] += delta
		if _age[i] >= _life[i]:
			_remove_at(i)
		else:
			_vel[i] = _vel[i] * (1.0 - DAMP * delta)
			_vel[i].y += GRAVITY * delta
			_pos[i] += _vel[i] * delta
		i -= 1
	queue_redraw()


## 末尾交换删除：O(1)，代价是粒子顺序被打乱——对于一堆随机火花完全无所谓
func _remove_at(index: int) -> void:
	var last: int = _pos.size() - 1
	_pos[index] = _pos[last]
	_vel[index] = _vel[last]
	_col[index] = _col[last]
	_age[index] = _age[last]
	_life[index] = _life[last]
	_pos.resize(last)
	_vel.resize(last)
	_col.resize(last)
	_age.resize(last)
	_life.resize(last)


func _draw() -> void:
	var n: int = _pos.size()
	for i in range(n):
		var t: float = _age[i] / _life[i]
		var alpha: float = 1.0 - t
		# 尾巴长度跟速度走：慢下来的火花自己会变短，不需要额外插值
		var tail: Vector2 = _vel[i] * 0.022
		draw_line(_pos[i], _pos[i] - tail, Color(_col[i], alpha), 2.2 - t * 1.4, true)
