class_name Portal
extends Node2D

## 关底传送门：Boss 倒下后原地开四扇，走进任意一扇进入下一张地图。
##
## 为什么要有门，而不是 Boss 一死直接换图：
## 元气骑士的地图循环里，"打完了 → 挑一件带走 → 走门"是一个完整的节拍。
## 直接换图等于把这个节拍压成一次闪白，玩家既没机会确认战利品，
## 也没机会做选择——而"选哪扇门"本身就是这轮改动里唯一的新决策点。
##
## 四扇门给四种奖励：卡 / 双卡 / 破甲弹 / 金币。
## 难度递增是**必然**发生的（每张图 +10%），玩家能选的只有"带着什么进去"。
## 做成"选难度"的话，玩家永远选最简单的，那个选择就退化成一次点击。

## 玩家踩上来时不直接传送，而是先问一句。回到这里只是"申请"。
signal entered(portal: Portal)
signal request_enter(portal: Portal)

## 回血门已经删掉：传送不再回血是这一版的设计前提。
## HEAL 腾出来的位置给了双卡门——同样是"立刻变强"，但不碰血线。
enum Reward { CARD, CARD2, BREACH, GOLD }

## 环的半径。比玩家半径大得多：门要"看着能走进去"，而不是一个贴地的小图标。
const RADIUS: float = 46.0
## 触发半径。比外环小一圈——贴着边缘擦过去不该被吸进去，
## 玩家必须是真的往门里走。
const ENTER_RADIUS: float = 30.0
## 开门后的保护期。Boss 死的那一帧玩家通常就站在尸体上（在捡宝石），
## 门又正好开在尸体周围——不设保护期会变成"Boss 一死就被传走"，
## 一地的宝石和破甲弹全留给空气。
const ARM_TIME: float = 1.6
## 取消之后必须走出这个倍数才允许再次申请。只按 ENTER_RADIUS 判"离开"太窄：
## 玩家点了取消、往后挪半步，立刻又被判定进门，面板会反复弹。
const LEAVE_RATIO: float = 1.7

var target: Node2D = null
var reward: int = Reward.CARD
var index: int = 0

var _age: float = 0.0
var _armed: bool = false
var _done: bool = false
## 已经发出 request_enter、正在等玩家点确定
var _pending: bool = false
## 玩家取消过：必须先走出触发半径，才允许再次申请
var _leave_gate: bool = false


func _ready() -> void:
	# 门画在敌人之上、HUD 之下：玩家被怪围住时也要能看见"出口在哪"。
	z_index = 2
	z_as_relative = false
	set_process(true)


func _physics_process(delta: float) -> void:
	if _done or _pending:
		return
	_age += delta
	if not _armed and _age >= ARM_TIME:
		_armed = true
		queue_redraw()
	if not _armed or not is_instance_valid(target):
		return
	var dist: float = global_position.distance_to(target.global_position)
	if _leave_gate and dist > ENTER_RADIUS * LEAVE_RATIO:
		_leave_gate = false
	if dist <= ENTER_RADIUS and not _leave_gate:
		# 不在这里 _done：玩家还没答应。状态交给 Game，由它弹面板。
		_pending = true
		request_enter.emit(self)
		return
	queue_redraw()


## 玩家点了确定。Game 在真正换图前调用。
func consume() -> void:
	_done = true
	_pending = false
	queue_free()


## 玩家点了取消。门留着，但要等他走出去才重新可触发。
func cancel_pending() -> void:
	_pending = false
	_leave_gate = true


func is_pending() -> bool:
	return _pending


func reward_color() -> Color:
	match reward:
		Reward.CARD2:
			return Color(0.88, 0.66, 1.0)
		Reward.BREACH:
			return Color(0.98, 0.72, 0.30)
		Reward.GOLD:
			return Color(1.0, 0.86, 0.34)
		_:
			return Color(0.62, 0.72, 1.0)


func reward_text() -> String:
	match reward:
		Reward.CARD2:
			return "额外两张卡"
		Reward.BREACH:
			return "破甲弹 +3"
		Reward.GOLD:
			return "金币 +90"
		_:
			return "额外一张卡"


## 门的三层结构：外环（边界）、内旋涡（方向感）、中心符号（选的是什么）。
## 没开的时候整圈压暗且不转——"还不能进"必须一眼看出来，
## 否则玩家会站在门上等，以为游戏卡住了。
func _draw() -> void:
	var col: Color = reward_color()
	var open: float = 1.0 if _armed else 0.28
	var pulse: float = 0.5 + 0.5 * sin(_age * 2.6)
	var spin: float = _age * 1.1 if _armed else 0.0

	# 外环：两圈反向旋转的短弧，视觉上像"在转的洞口"
	for i in range(3):
		var r: float = RADIUS - float(i) * 5.0
		var seg: float = TAU / 6.0
		var start: float = spin * (1.0 if i % 2 == 0 else -1.0)
		for k in range(6):
			var a0: float = start + float(k) * seg
			draw_arc(Vector2.ZERO, r, a0, a0 + seg * 0.62, 10,
				Color(col.r, col.g, col.b, (0.30 + 0.22 * float(i)) * open), 2.0, true)

	# 内圈：随呼吸放大的实心盘，开门瞬间会明显亮一下
	draw_circle(Vector2.ZERO, RADIUS * (0.42 + 0.05 * pulse),
		Color(col.r, col.g, col.b, 0.16 * open))
	draw_circle(Vector2.ZERO, RADIUS * 0.30,
		Color(col.r, col.g, col.b, 0.22 + 0.16 * pulse * open))

	# 中心符号
	var glyph: Color = Color(col.r, col.g, col.b, 0.95 * open)
	match reward:
		Reward.BREACH:
			# 六边形，和地上那枚破甲弹同一个形状
			var pts := PackedVector2Array()
			for i in range(6):
				pts.append(Vector2.RIGHT.rotated(TAU * float(i) / 6.0 + spin * 0.4) * 15.0)
			draw_polyline(pts + PackedVector2Array([pts[0]]), glyph, 2.4, true)
		Reward.GOLD:
			# 硬币：一个圆 + 中间一道横线，和 HUD 上的金币读数同一个符号
			draw_arc(Vector2.ZERO, 13.0, 0.0, TAU, 20, glyph, 2.2, true)
			draw_line(Vector2(-6.0, 0.0), Vector2(6.0, 0.0), glyph, 2.2)
		Reward.CARD2:
			# 五张叠卡：比单卡门多两张，靠数量就能认出来
			for i in range(5):
				var off := Vector2(float(i - 2) * 6.0, float(i - 2) * -3.5)
				var rect := Rect2(off - Vector2(5.0, 8.0), Vector2(10.0, 16.0))
				draw_rect(rect, glyph, false, 1.6)
		_:
			# 三张叠起来的卡
			for i in range(3):
				var off := Vector2(float(i - 1) * 7.0, float(i - 1) * -4.0)
				var rect := Rect2(off - Vector2(6.0, 9.0), Vector2(12.0, 18.0))
				draw_rect(rect, glyph, false, 1.8)
