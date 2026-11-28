class_name Merchant
extends Node2D

## 密室里的商人：走近就开商店面板。
##
## 为什么不是"按键交互"：手机上没有多余的键，而"走近自动触发"在这个游戏里
## 已经被传送门训练过一次。两者的区别是门会先问一句（错传代价是一整张图），
## 商人直接开面板——商店面板本身有"离开"，误触的代价只是多看一屏。
##
## 和 Portal 一样有 leave_gate：关店后必须走出 LEAVE_RADIUS 才允许再次申请，
## 否则玩家站在柜台前关一次店，面板会立刻再弹一次。

signal request_shop(merchant: Merchant)

## 触发半径。比传送门大得多：商人是"目的地"，玩家是特意走过来的，
## 不该要求在柜台前精确站位。
const OPEN_RADIUS: float = 104.0
## 关店后必须走出这个距离。
const LEAVE_RADIUS: float = 168.0
## 走近时脚下那圈光晕的半径，只是视觉提示，不参与判定。
const HALO_RADIUS: float = 58.0

var target: Node2D = null

var _pending: bool = false
var _leave_gate: bool = false
var _age: float = 0.0


func _ready() -> void:
	# 和传送门同一层：在敌人之上、HUD 之下
	z_index = 2
	z_as_relative = false
	queue_redraw()


func _physics_process(delta: float) -> void:
	_age += delta
	queue_redraw()
	if _pending or not is_instance_valid(target):
		return
	var dist: float = global_position.distance_to(target.global_position)
	if _leave_gate:
		if dist > LEAVE_RADIUS:
			_leave_gate = false
		return
	if dist <= OPEN_RADIUS:
		_pending = true
		request_shop.emit(self)


## 关店后调用：进入"等你走开"的状态。
func consume() -> void:
	_pending = false
	_leave_gate = true


func is_pending() -> bool:
	return _pending


## 一个柜台 + 一个戴帽子的商人 + 脚下一圈金色光晕。
## 自绘而不是用图标：项目里没有人物贴图，而"金色圆顶 + 柜台"这两笔
## 足够让玩家在迷宫尽头一眼认出这是个能交易的地方。
func _draw() -> void:
	var bob: float = sin(_age * 1.8) * 2.0
	var halo: float = 0.5 + 0.5 * sin(_age * 2.4)

	# 脚下光晕：可交互的唯一提示
	draw_circle(Vector2.ZERO, HALO_RADIUS * (0.92 + 0.06 * halo),
		Color(1.0, 0.86, 0.34, 0.06))
	draw_arc(Vector2.ZERO, HALO_RADIUS * (0.96 + 0.05 * halo), 0.0, TAU, 36,
		Color(1.0, 0.86, 0.34, 0.22), 2.0, true)

	# 柜台
	draw_rect(Rect2(-30.0, 12.0, 60.0, 18.0), Color(0.40, 0.31, 0.22))
	draw_rect(Rect2(-30.0, 12.0, 60.0, 4.0), Color(0.56, 0.44, 0.30))
	# 柜台上摆的货：三枚小方块，和三个货位对应
	for i in range(3):
		var x: float = -18.0 + float(i) * 18.0
		draw_rect(Rect2(x - 4.0, 4.0, 8.0, 8.0), Color(0.98, 0.86, 0.46))

	# 身体 + 头 + 帽子
	draw_circle(Vector2(0.0, 2.0 + bob), 14.0, Color(0.34, 0.29, 0.42))
	draw_circle(Vector2(0.0, -14.0 + bob), 9.0, Color(0.86, 0.72, 0.56))
	draw_rect(Rect2(-11.0, -27.0 + bob, 22.0, 5.0), Color(0.22, 0.19, 0.28))
	draw_rect(Rect2(-7.0, -33.0 + bob, 14.0, 7.0), Color(0.22, 0.19, 0.28))
