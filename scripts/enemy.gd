class_name Enemy
extends Node2D

## 敌人：追踪目标、接触造成伤害、死亡上报。
## 目标由 Game 在生成时注入（target），敌人自身不查找玩家，避免场景耦合。

## 死亡时发出，由 Game 结算击杀数与经验。
signal died(enemy: Enemy, xp: int)

## 每次受击发出。位置和颜色随信号传，上层不用再读私有字段，也避免为此加 getter。
signal hit(at: Vector2, tint: Color)

## 吐息者开火。方向由敌人算好（带预判），谁去生成子弹由 Game 决定：
## 敌人不知道 world 长什么样，也不该知道。
signal spit(at: Vector2, direction: Vector2)

## Boss 血量过半换阶段。HUD 用它换血条颜色与文案，Game 用它补一记震动。
signal boss_phase(phase: int)
## Boss 召唤小怪。数量和位置由 Boss 给，具体生成归 Game（敌人不该碰 world）。
signal boss_summon(at: Vector2, count: int)
## Boss 环形弹幕。铺哪个方向、飞多快由 Game 定，Boss 只负责说"我要放这一招"。
signal boss_barrage(at: Vector2, count: int)
## 蚀影瞬移。两端坐标都给出来，Game 才能在原地和落点各留一道残影——
## 只报落点的话，玩家会觉得"它是凭空刷在我脸上"而不是"它跳过来了"。
signal boss_blink(from: Vector2, to: Vector2)
## 深潜者追踪弹。数量和起点由 Boss 给，转向速度归 Game 定。
signal boss_homing(at: Vector2, count: int)

## 敌人行为类型。数值全部在 Game 里按波次抽样，这里只管"怎么动、怎么打"。
enum Kind { GRUNT, CHARGER, SPITTER, BOMBER, BOSS }

const TOUCH_COOLDOWN: float = 1.0
## 分离力权重。1.6 足够把重叠的怪推开，又不至于让它们绕着玩家转圈。
const SEPARATION_WEIGHT: float = 1.6
## 受击闪白时长（秒）
const FLASH_TIME: float = 0.14
const FLASH_COLOR: Color = Color(2.6, 2.6, 2.6)

## 冲锋者：站定蓄力 → 直线冲刺 → 僵直。三段节奏给了玩家"看预警 → 侧移 → 反击"的窗口。
const CHARGE_WINDUP: float = 0.55
const CHARGE_DASH: float = 0.34
const CHARGE_REST: float = 0.55
const CHARGE_SPEED_SCALE: float = 3.6
const CHARGE_TRIGGER_MIN: float = 130.0
const CHARGE_TRIGGER_MAX: float = 340.0
const CHARGE_DAMAGE: float = 11.0

## 吐息者：不进杀伤圈，在射程边缘绕圈放慢速弹。站桩的人躲不掉，走位的人能溜掉。
const SPIT_INTERVAL: float = 2.7
const SPIT_MIN_RANGE: float = 235.0
const SPIT_MAX_RANGE: float = 325.0
const SPIT_LEAD_TIME: float = 0.3

## 自爆者：贴身到触发距离后闪烁，然后范围爆炸。逼玩家在它靠近前清掉或拉开。
const BOMB_TRIGGER: float = 72.0
const BOMB_FUSE: float = 0.78
const BOMB_RADIUS: float = 94.0
const BOMB_DAMAGE: float = 24.0

## Boss：威胁全部来自"看得见前摇的大招"，不靠贴身磨血。
## 每招前摇都在 0.7 秒以上：玩家能不能躲开，取决于有没有在读招式而不是数值。
##
## 三只 Boss 曾经共用一套招式（一阶段冲击波/召唤、二阶段弹幕/冲锋），
## 结果除了名字和颜色，打起来一模一样——第三只 Boss 和第一只的唯一区别就是血更多。
## 现在按 kit 给每只一套轮换表（见 BOSS_KIT_TABLES）：招式池一样，节奏不一样。
const BOSS_PHASE_TWO_RATIO: float = 0.5
const BOSS_ATTACK_INTERVAL: float = 3.0
const BOSS_SUMMON_COUNT: int = 6

## 招式编号。1/2/3 沿用第一版的编号（1 冲击波 / 2 冲锋前摇 / 3 冲锋中），
## 新招式往后排，_draw_boss_marks 的 match 与读招标记都按这套编号走。
const MOVE_IDLE: int = 0
const MOVE_SHOCK: int = 1
const MOVE_CHARGE_WINDUP: int = 2
const MOVE_CHARGE_DASH: int = 3
const MOVE_BLINK: int = 4
const MOVE_HOMING: int = 5
const MOVE_TIDE: int = 6
## 召唤与弹幕是瞬时生效的招式，不占 _boss_move 状态，只在轮换表里占一格
const MOVE_SUMMON: int = 7
const MOVE_BARRAGE: int = 8

## 冲击波：0.85 秒前摇后按半径判一次伤害。半径 168 略大于玩家 0.8 秒的移动距离
## （226×0.8≈180），所以「看到环就往外走」刚好能跑出去，晚一步就会被扫到。
const BOSS_SHOCK_RADIUS: float = 168.0
const BOSS_SHOCK_TELEGRAPH: float = 0.85
const BOSS_SHOCK_DAMAGE: float = 15.0
## 巨浪：潮主二阶段的招牌。半径 250、前摇 1.25 秒——更疼也更慢，
## 在圈内站着不动必死，但给足了"往外跑"的时间。
const BOSS_TIDE_RADIUS: float = 250.0
const BOSS_TIDE_TELEGRAPH: float = 1.25
const BOSS_TIDE_DAMAGE: float = 20.0
const BOSS_BARRAGE_COUNT: int = 14
const BOSS_CHARGE_WINDUP: float = 0.7
const BOSS_CHARGE_DASH: float = 0.5
const BOSS_CHARGE_SCALE: float = 4.2
## 蚀影瞬移：先原地聚形 0.4 秒（看得见它要走），落到玩家背后 240 处，再僵 0.3 秒。
## 落点选了"玩家身后"而不是"玩家脸上"——瞬移到脸上等于一次无法反应的接触伤害。
const BOSS_BLINK_WINDUP: float = 0.4
const BOSS_BLINK_RECOVER: float = 0.3
const BOSS_BLINK_DIST: float = 240.0
## 深潜者追踪弹：3 发、0.7 秒前摇。转向速度在 Game 侧给，这里只负责"我要放"。
const BOSS_HOMING_COUNT: int = 3
const BOSS_HOMING_WINDUP: float = 0.7
## 出场定身：Boss 从视野外走进来的那 1 秒不该已经在放招。
## 玩家需要这 1 秒来确认"它来了、它叫什么、血条在哪"。
const BOSS_INTRO_TIME: float = 1.1

## 三套招式轮换表。每套 4 招，一阶段与二阶段各一张——
## 二阶段要换的是节奏（更激进的招），而不是单纯提高频率。
const BOSS_KIT_TABLES: Array = [
	{
		"one": [MOVE_SHOCK, MOVE_SUMMON, MOVE_SHOCK, MOVE_SUMMON],
		"two": [MOVE_TIDE, MOVE_SUMMON, MOVE_SHOCK, MOVE_SUMMON],
	},
	{
		"one": [MOVE_BARRAGE, MOVE_BLINK, MOVE_BARRAGE, MOVE_SHOCK],
		"two": [MOVE_BARRAGE, MOVE_BLINK, MOVE_CHARGE_WINDUP, MOVE_BARRAGE],
	},
	{
		"one": [MOVE_SUMMON, MOVE_CHARGE_WINDUP, MOVE_BARRAGE, MOVE_CHARGE_WINDUP],
		"two": [MOVE_HOMING, MOVE_CHARGE_WINDUP, MOVE_SUMMON, MOVE_HOMING],
	},
]
## 血条上给玩家看的风格名。招式一样的时候"潮主/蚀影"只是三个字，
## 配上风格名才能让玩家记住"这只爱放浪""那只爱跳"。
const BOSS_KIT_NAMES: Array[String] = ["潮汐", "游影", "深噬"]
## 三只 Boss 的本体配色。原来三只都是同一套暗红，和普通小怪撞色，
## 混在人群里只能靠"个头大"认它——可它们的打法完全不同，颜色是最省事的身份标识。
const BOSS_KIT_COLORS: Array[Color] = [
	Color(0.30, 0.80, 0.74),
	Color(0.88, 0.60, 0.26),
	Color(0.62, 0.44, 0.96),
]
## Boss 基础速度只有普通怪的 55%（在 Game 里乘），玩家能轻松拉开——
## 但拉得太开就追不上战斗了，所以超过这个距离直接加速追。
const BOSS_CATCHUP_DIST: float = 620.0
const BOSS_CATCHUP_SCALE: float = 2.1

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
## 行为类型，见 Kind。精英固定走 GRUNT：精英换成吐息者或冲锋者会让难度曲线失控。
var kind: int = Kind.GRUNT
## Boss 名字，显示在屏顶血条上。普通敌人留空。
var boss_name: String = ""
## 分离时是否不被推动。Boss 半径是小怪的 3 倍，如果也参与位置修正，
## 它会被一圈小怪持续顶偏，"巨物"的体积感立刻消失。
var immovable: bool = false

var _health: float = 0.0
var _speed: float = 70.0
var _color: Color = Color(0.85, 0.35, 0.42)
var _touch_cd: float = 0.0
var _drift: float = 0.0
var _dead: bool = false
## 冲锋者的阶段：0 接近 / 1 蓄力 / 2 冲刺 / 3 僵直
var _phase: int = 0
var _phase_t: float = 0.0
var _dash_dir: Vector2 = Vector2.ZERO
## 吐息者的开火冷却与玩家速度预判用的上一帧位置
var _spit_t: float = 0.0
var _last_target: Vector2 = Vector2.ZERO
var _has_last_target: bool = false
## 自爆者是否已点燃引线
var _fused: bool = false
## 闪白剩余时长。用倒数计时而不是 Tween：高密度下每秒会有上千次受击，
## create_tween() 会持续分配对象，而且同一敌人连续受击时多个 Tween 会互抢 modulate。
var _flash_t: float = 0.0
## 减速剩余时长与强度（法师新星、战士击退后的迟滞）
var _slow_t: float = 0.0
var _slow_factor: float = 0.0
## Boss：哪一套招式轮换表（见 BOSS_KIT_TABLES）。0 潮主 / 1 蚀影 / 2 深潜者
var boss_kit: int = 0
## Boss：当前阶段（0 一阶段 / 1 二阶段）、下一招倒计时、招式轮换序号
var _boss_phase_index: int = 0
var _boss_act_t: float = BOSS_ATTACK_INTERVAL
## 从 0 起手，所以第一招一定是当前 kit 表的第一项：
## 潮主先拍浪、蚀影先弹幕、深潜者先召唤。玩家两次遭遇记得住"它先干什么"。
var _boss_act: int = 0
## Boss 正在执行的招式，见 MOVE_* 常量
var _boss_move: int = 0
var _boss_move_t: float = 0.0
var _boss_dash_dir: Vector2 = Vector2.ZERO
## 出场定身剩余时长。>0 时完全不动（也不出招），只让玩家认人
var boss_intro_t: float = 0.0
## 瞬移的起点，用于发信号时把两端一起报出去
var _boss_blink_from: Vector2 = Vector2.ZERO
## 瞬移是否已经发生（前摇结束只该跳一次）
var _boss_blink_done: bool = false


## 在 add_child 之前调用，一次配置好本敌人的属性。
func configure(p_health: float, p_speed: float, p_big: bool, p_kind: int = Kind.GRUNT) -> void:
	max_health = p_health
	_health = p_health
	_speed = p_speed
	# 精英永远走普通行为：精英吐息者一次吐一片，难度会直接失控
	kind = Kind.GRUNT if p_big else p_kind
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
	match kind:
		Kind.CHARGER:
			radius = 9.0
			touch_damage = 9.0
			_color = Color(0.98, 0.62, 0.24)
		Kind.SPITTER:
			radius = 11.0
			touch_damage = 4.0
			xp_value = 3
			_color = Color(0.42, 0.86, 0.72)
		Kind.BOMBER:
			radius = 9.5
			# 碰撞不造成伤害，伤害全在爆炸里：不然贴一下就掉血，玩家读不懂它想干嘛
			touch_damage = 0.0
			xp_value = 3
			_color = Color(0.96, 0.84, 0.30)
	queue_redraw()


## Boss 走独立入口而不是给 configure 再加参数：它的血量、速度、体积、伤害
## 全部来自 Game 的 Boss 公式，和普通怪的"基础值 × 时间增长"不是同一套算法。
func configure_boss(p_health: float, p_speed: float, p_name: String, p_kit: int = 0) -> void:
	max_health = p_health
	_health = p_health
	_speed = p_speed
	kind = Kind.BOSS
	tier = 2
	boss_kit = clampi(p_kit, 0, BOSS_KIT_TABLES.size() - 1)
	# 38 而不是 34：34 时它在 125 只小怪里只比精英大一圈，看不出是"这一个"。
	# 顺带扩大判定体积，长 TTK 的局面能稍微好一点。
	radius = 38.0
	touch_damage = 18.0
	xp_value = 45
	boss_name = p_name
	immovable = true
	_drift = 0.0
	# 本体配色跟着 kit 走：潮主青、蚀影橙、深潜者紫
	_color = BOSS_KIT_COLORS[boss_kit]
	queue_redraw()


## 供 HUD 血条读取。Boss 的 _health 是私有字段，UI 不该直接摸。
func health_ratio() -> float:
	return clampf(_health / maxf(max_health, 0.0001), 0.0, 1.0)


func _ready() -> void:
	if _health <= 0.0:
		_health = max_health
	if kind != Kind.BOSS:
		_drift = randf_range(-0.4, 0.4)
	queue_redraw()


func _physics_process(delta: float) -> void:
	_tick_flash(delta)
	_tick_slow(delta)
	if _dead or not is_instance_valid(target):
		return

	_touch_cd = maxf(_touch_cd - delta, 0.0)
	var to_target: Vector2 = target.global_position - global_position
	var dist: float = to_target.length()
	var dir: Vector2 = to_target / dist if dist > 0.001 else Vector2.ZERO

	match kind:
		Kind.CHARGER:
			_tick_charger(delta, dir, dist)
		Kind.SPITTER:
			_tick_spitter(delta, dir, dist)
		Kind.BOMBER:
			_tick_bomber(delta, dist)
		Kind.BOSS:
			_tick_boss(delta, dir, dist)
		_:
			_move_toward(dir, delta)
			_touch(dist, touch_damage)

	_last_target = target.global_position
	_has_last_target = true


func _current_speed() -> float:
	return _speed * (1.0 - _slow_factor) if _slow_t > 0.0 else _speed


## 朝某个方向走一步。分离力只改方向不改速度：总长封顶 1，被挤住时自然减速，
## 而不是从邻居身上穿过去。speed_scale 只给 Boss 用（追不上玩家时加速）。
func _move_toward(dir: Vector2, delta: float, speed_scale: float = 1.0) -> void:
	if dir == Vector2.ZERO:
		return
	var steered: Vector2 = (dir + dir.orthogonal() * _drift).normalized()
	var steer: Vector2 = (steered + separation * SEPARATION_WEIGHT).limit_length(1.0)
	global_position += steer * _current_speed() * speed_scale * delta


func _touch(dist: float, damage: float) -> void:
	if damage <= 0.0 or dist > radius + 16.0 or _touch_cd > 0.0:
		return
	if target.has_method("take_damage"):
		target.call("take_damage", damage)
		_touch_cd = TOUCH_COOLDOWN


## 冲锋者：接近 → 蓄力（画预警线）→ 直线冲刺 → 冲过头僵直。
## 冲刺段无视分离力，直接从人堆里穿过去，所以躲不开就是实打实的一下。
func _tick_charger(delta: float, dir: Vector2, dist: float) -> void:
	if _phase == 0:
		_move_toward(dir, delta)
		_touch(dist, touch_damage)
		if dist < CHARGE_TRIGGER_MAX and dist > CHARGE_TRIGGER_MIN:
			_phase = 1
			_phase_t = 0.0
			queue_redraw()
		return

	_phase_t += delta
	match _phase:
		1:
			# 蓄力期间原地不动：玩家看到预警线侧移一步就能让冲刺落空
			queue_redraw()
			if _phase_t >= CHARGE_WINDUP:
				_dash_dir = dir
				_phase = 2
				_phase_t = 0.0
		2:
			global_position += _dash_dir * _current_speed() * CHARGE_SPEED_SCALE * delta
			_touch(dist, CHARGE_DAMAGE)
			queue_redraw()
			if _phase_t >= CHARGE_DASH:
				_phase = 3
				_phase_t = 0.0
		3:
			if _phase_t >= CHARGE_REST:
				_phase = 0
				_phase_t = 0.0
				queue_redraw()


## 吐息者：远距离绕圈，定时吐带预判的慢速弹。它不会自己走进杀伤圈，
## 所以"站着不动"的人躲不掉，走位的人能把它甩在射程外。
func _tick_spitter(delta: float, dir: Vector2, dist: float) -> void:
	if dist > SPIT_MAX_RANGE:
		_move_toward(dir, delta)
	elif dist < SPIT_MIN_RANGE:
		_move_toward(-dir, delta)
	else:
		var side: float = 1.0 if _drift >= 0.0 else -1.0
		_move_toward(dir.orthogonal() * side, delta)
	_touch(dist, touch_damage)

	_spit_t = maxf(_spit_t - delta, 0.0)
	if _spit_t > 0.0 or dist > SPIT_MAX_RANGE * 1.35:
		return
	_spit_t = SPIT_INTERVAL
	var aim: Vector2 = dir
	if _has_last_target and delta > 0.0001:
		var velocity: Vector2 = (target.global_position - _last_target) / delta
		var flight: float = clampf(dist / 175.0, 0.15, 0.6)
		aim = (target.global_position + velocity * SPIT_LEAD_TIME - global_position).normalized()
	spit.emit(global_position, aim)


## 自爆者：贴到触发距离就点燃引线，闪烁 0.78 秒后范围爆炸。
## 逼玩家在它靠近前清掉，或者干脆拉开——两种应对都要动。
func _tick_bomber(delta: float, dist: float) -> void:
	if not _fused:
		_move_toward((target.global_position - global_position).normalized(), delta)
		if dist <= BOMB_TRIGGER:
			_fused = true
			_phase_t = 0.0
			queue_redraw()
		return

	_phase_t += delta
	queue_redraw()
	if _phase_t >= BOMB_FUSE:
		_explode()


func _explode() -> void:
	if _dead:
		return
	_dead = true
	if is_instance_valid(target) and global_position.distance_to(target.global_position) <= BOMB_RADIUS:
		if target.has_method("take_damage"):
			target.call("take_damage", BOMB_DAMAGE)
	hit.emit(global_position, _color)
	died.emit(self, xp_value)
	queue_free()


## Boss：一直朝玩家走，按固定节奏出招。出招期间原地不动——
## 只有站着不动，"前摇"才是真的可读可躲；边走边放的话玩家永远算不准该往哪躲。
func _tick_boss(delta: float, dir: Vector2, dist: float) -> void:
	# 出场定身：这一秒里它既不动也不出招。玩家要先确认"它来了"，才谈得上读招。
	if boss_intro_t > 0.0:
		boss_intro_t = maxf(boss_intro_t - delta, 0.0)
		queue_redraw()
		return

	if _boss_phase_index == 0 and _health <= max_health * BOSS_PHASE_TWO_RATIO:
		_boss_phase_index = 1
		# 换阶段时丢掉正在走的招式，否则会出现"已经进二阶段还在放一阶段的冲击波"
		_boss_move = MOVE_IDLE
		_boss_move_t = 0.0
		_boss_act_t = BOSS_ATTACK_INTERVAL
		# 轮换序号也归零：二阶段的第一招固定是它那张表的头一项，
		# 这样"潮主二阶段第一波是巨浪"是可预测的，玩家能学会、也能被测试断言。
		_boss_act = 0
		boss_phase.emit(1)
		queue_redraw()

	_boss_move_t += delta
	match _boss_move:
		MOVE_SHOCK:
			queue_redraw()
			if _boss_move_t >= BOSS_SHOCK_TELEGRAPH:
				_boss_shock(BOSS_SHOCK_RADIUS, BOSS_SHOCK_DAMAGE)
				_end_boss_move()
		MOVE_TIDE:
			queue_redraw()
			if _boss_move_t >= BOSS_TIDE_TELEGRAPH:
				_boss_shock(BOSS_TIDE_RADIUS, BOSS_TIDE_DAMAGE)
				_end_boss_move()
		MOVE_CHARGE_WINDUP:
			queue_redraw()
			if _boss_move_t >= BOSS_CHARGE_WINDUP:
				_boss_dash_dir = dir
				_boss_move = MOVE_CHARGE_DASH
				_boss_move_t = 0.0
		MOVE_CHARGE_DASH:
			global_position += _boss_dash_dir * _current_speed() * BOSS_CHARGE_SCALE * delta
			_touch(dist, 22.0)
			queue_redraw()
			if _boss_move_t >= BOSS_CHARGE_DASH:
				_end_boss_move()
		MOVE_BLINK:
			queue_redraw()
			if not _boss_blink_done and _boss_move_t >= BOSS_BLINK_WINDUP:
				_boss_blink_done = true
				_boss_teleport(dir)
			if _boss_move_t >= BOSS_BLINK_WINDUP + BOSS_BLINK_RECOVER:
				_end_boss_move()
		MOVE_HOMING:
			queue_redraw()
			if _boss_move_t >= BOSS_HOMING_WINDUP:
				boss_homing.emit(global_position, BOSS_HOMING_COUNT)
				_end_boss_move()
		_:
			_move_toward(dir, delta, _boss_catchup_scale())
			_touch(dist, touch_damage)
			_boss_act_t -= delta
			if _boss_act_t <= 0.0:
				_start_boss_move()


func _end_boss_move() -> void:
	_boss_move = MOVE_IDLE
	_boss_move_t = 0.0
	_boss_blink_done = false
	# 必须重画一次：否则招式结束后上一帧的预警环会一直留在屏幕上，
	# 直到下一次前摇才被覆盖——玩家会以为"这招还在放"。
	queue_redraw()


## 蚀影的瞬移：落到"玩家背后"。dir 是 Boss → 玩家的方向，
## 所以 玩家 + dir*距离 正好是穿过玩家之后的位置——视觉上是"它从你身上穿过去了"，
## 而不是"凭空出现在你脸上"（后者等于一次躲不掉的接触伤害）。
func _boss_teleport(dir: Vector2) -> void:
	_boss_blink_from = global_position
	if not is_instance_valid(target):
		return
	var landing: Vector2 = target.global_position + dir * BOSS_BLINK_DIST
	global_position = landing
	boss_blink.emit(_boss_blink_from, landing)
	queue_redraw()


## 玩家跑速是 Boss 的 4 倍，不加速的话打两下就能永久甩掉它，Boss 会变成背景板
func _boss_catchup_scale() -> float:
	if not is_instance_valid(target):
		return 1.0
	if global_position.distance_to(target.global_position) <= BOSS_CATCHUP_DIST:
		return 1.0
	return BOSS_CATCHUP_SCALE


## 按 kit 表取下一招。表里四项一轮，_boss_act 只增不减，取模就是"第几招"。
## 召唤与弹幕是瞬时生效的招式，当帧就结束；其余招式进入 _boss_move 走前摇。
func _start_boss_move() -> void:
	_boss_act_t = BOSS_ATTACK_INTERVAL
	_boss_move_t = 0.0
	var kit: Dictionary = BOSS_KIT_TABLES[boss_kit]
	var table: Array = kit["two"] if _boss_phase_index == 1 else kit["one"]
	var move: int = int(table[_boss_act % table.size()])
	_boss_act += 1
	match move:
		MOVE_SUMMON:
			boss_summon.emit(global_position, BOSS_SUMMON_COUNT)
		MOVE_BARRAGE:
			boss_barrage.emit(global_position, BOSS_BARRAGE_COUNT)
		MOVE_BLINK:
			_boss_blink_done = false
			_boss_move = MOVE_BLINK
		_:
			_boss_move = move
	queue_redraw()


## 冲击波结算：涨满时玩家还在圈里才挨打。走位躲开就完全无伤，这是 Boss 战的核心交互。
## 半径与伤害做成参数，巨浪和普通冲击波共用这一条判定。
func _boss_shock(shock_radius: float, shock_damage: float) -> void:
	hit.emit(global_position, _color)
	if not is_instance_valid(target):
		return
	if global_position.distance_to(target.global_position) > shock_radius:
		return
	if target.has_method("take_damage"):
		target.call("take_damage", shock_damage)


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


## 减速可以叠加取最强值，不刷新更弱的减速：连续吃两发新星不会互相覆盖变慢
func apply_slow(duration: float, factor: float) -> void:
	if duration <= 0.0 or factor <= 0.0:
		return
	_slow_t = maxf(_slow_t, duration)
	_slow_factor = maxf(_slow_factor, factor)
	queue_redraw()


func _tick_slow(delta: float) -> void:
	if _slow_t <= 0.0:
		return
	_slow_t = maxf(_slow_t - delta, 0.0)
	if _slow_t <= 0.0:
		_slow_factor = 0.0
		queue_redraw()


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
	_draw_kind_marks()
	# 减速标记：外圈一道冰蓝色，让玩家能看出"哪几只被冻住了"
	if _slow_t > 0.0:
		draw_arc(Vector2.ZERO, radius + 4.0, 0.0, TAU, 18, Color(0.55, 0.82, 1.0, 0.8), 2.0, true)

	if _health < max_health and _health > 0.0:
		var width: float = radius * 2.0
		var ratio: float = clampf(_health / max_health, 0.0, 1.0)
		draw_rect(Rect2(-radius, -radius - 9.0, width, 3.0), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(-radius, -radius - 9.0, width * ratio, 3.0), Color(0.95, 0.25, 0.25))


## 三种特殊敌人的读招标记。全部用绘制做，不接美术资源也能让玩家一眼分辨
## "这只在蓄力，那只在点引线"——行为难不难是一回事，看不看得懂是另一回事。
func _draw_kind_marks() -> void:
	match kind:
		Kind.CHARGER:
			var aim: Vector2 = _dash_dir
			if _phase != 2 and is_instance_valid(target):
				aim = (target.global_position - global_position).normalized()
			if _phase == 1:
				var glow: float = clampf(_phase_t / CHARGE_WINDUP, 0.0, 1.0)
				draw_line(Vector2.ZERO, aim * 190.0, Color(1.0, 0.55, 0.15, 0.25 + 0.45 * glow), 2.0)
				draw_arc(Vector2.ZERO, radius + 6.0, 0.0, TAU, 22, Color(1.0, 0.62, 0.2, glow), 2.5, true)
			elif _phase == 2:
				draw_line(Vector2.ZERO, aim * 26.0, Color(1.0, 0.78, 0.35, 0.95), 3.0)
		Kind.SPITTER:
			draw_arc(Vector2.ZERO, radius + 4.5, 0.0, TAU, 20, Color(0.42, 0.86, 0.72, 0.55), 1.5, true)
			draw_circle(Vector2.ZERO, radius * 0.48, Color(0.78, 0.99, 0.9, 0.9))
		Kind.BOMBER:
			if _fused:
				var t: float = clampf(_phase_t / BOMB_FUSE, 0.0, 1.0)
				draw_arc(Vector2.ZERO, radius + 4.0 + 10.0 * t, 0.0, TAU, 24,
					Color(1.0, 0.28, 0.18, 0.35 + 0.55 * t), 2.5, true)
			for i in range(4):
				var angle: float = TAU * 0.25 * float(i)
				var unit: Vector2 = Vector2(cos(angle), sin(angle))
				draw_line(unit * radius * 0.85, unit * radius * 1.45, Color(0.5, 0.36, 0.08, 0.9), 2.0)
		Kind.BOSS:
			_draw_boss_marks()


## Boss 的全部读招标记。原则和三种小怪一致：不接美术资源，也要让玩家一眼看出
## "它现在要放什么、我该往哪躲"。
func _draw_boss_marks() -> void:
	# 内核用六边形：普通怪是圆点，混在人群里也能一眼认出哪个是 Boss
	var points := PackedVector2Array()
	for i in range(6):
		var a: float = TAU * float(i) / 6.0 - PI * 0.5
		points.append(Vector2(cos(a), sin(a)) * radius * 0.44)
	draw_colored_polygon(points, Color(0.16, 0.05, 0.08, 0.92))

	if _boss_phase_index == 1:
		# 二阶段外圈常亮脉动环：不看血条也能知道它换阶段了
		var pulse: float = 0.5 + 0.5 * sin(_boss_move_t * 3.0 + _boss_act_t)
		draw_arc(Vector2.ZERO, radius + 9.0, 0.0, TAU, 40,
			Color(1.0, 0.34, 0.3, 0.35 + 0.4 * pulse), 3.0, true)
	else:
		draw_arc(Vector2.ZERO, radius + 9.0, 0.0, TAU, 40, Color(0.95, 0.42, 0.45, 0.42), 2.0, true)

	# 出场定身：一圈向外散的环，说明"它刚到、还没开始打"
	if boss_intro_t > 0.0:
		var arrive: float = 1.0 - boss_intro_t / BOSS_INTRO_TIME
		draw_arc(Vector2.ZERO, radius + 14.0 + 46.0 * arrive, 0.0, TAU, 40,
			Color(1.0, 0.9, 0.62, 0.55 * (1.0 - arrive)), 3.0, true)

	match _boss_move:
		MOVE_SHOCK:
			# 冲击波：外圈是判定边界（一直亮），内圈是从中心涨上来的进度，
			# 中间补一层半透明填充——只画两条线时，"现在圈里有多危险"要靠玩家自己脑补。
			var t: float = clampf(_boss_move_t / BOSS_SHOCK_TELEGRAPH, 0.0, 1.0)
			draw_arc(Vector2.ZERO, BOSS_SHOCK_RADIUS, 0.0, TAU, 72, Color(1.0, 0.32, 0.3, 0.5), 2.0, true)
			draw_circle(Vector2.ZERO, BOSS_SHOCK_RADIUS * t, Color(1.0, 0.3, 0.24, 0.12))
			draw_arc(Vector2.ZERO, BOSS_SHOCK_RADIUS * t, 0.0, TAU, 72, Color(1.0, 0.46, 0.36, 0.6), 4.0, true)
		MOVE_TIDE:
			var tt: float = clampf(_boss_move_t / BOSS_TIDE_TELEGRAPH, 0.0, 1.0)
			var tide_color := Color(0.55, 0.86, 1.0, 0.55)
			draw_arc(Vector2.ZERO, BOSS_TIDE_RADIUS, 0.0, TAU, 84, tide_color, 3.0, true)
			draw_circle(Vector2.ZERO, BOSS_TIDE_RADIUS * tt, Color(0.32, 0.66, 1.0, 0.17))
			draw_arc(Vector2.ZERO, BOSS_TIDE_RADIUS * tt, 0.0, TAU, 84,
				Color(0.72, 0.94, 1.0, 0.72), 6.0, true)
		MOVE_CHARGE_WINDUP:
			var aim: Vector2 = Vector2.RIGHT
			if is_instance_valid(target):
				aim = (target.global_position - global_position).normalized()
			var warn: float = clampf(_boss_move_t / BOSS_CHARGE_WINDUP, 0.0, 1.0)
			draw_line(Vector2.ZERO, aim * 460.0, Color(1.0, 0.36, 0.3, 0.18 + 0.55 * warn), 4.0)
			draw_arc(Vector2.ZERO, radius + 6.0, 0.0, TAU, 26, Color(1.0, 0.6, 0.3, warn), 2.5, true)
		MOVE_CHARGE_DASH:
			draw_line(Vector2.ZERO, _boss_dash_dir * 64.0, Color(1.0, 0.76, 0.42, 0.95), 6.0)
		MOVE_BLINK:
			# 聚形：环向内收，收满就消失（瞬移）。玩家看到"往里缩"就知道它要跳了
			var bt: float = clampf(_boss_move_t / BOSS_BLINK_WINDUP, 0.0, 1.0)
			draw_arc(Vector2.ZERO, radius + 40.0 - 34.0 * bt, 0.0, TAU, 32,
				Color(0.78, 0.55, 1.0, 0.35 + 0.5 * bt), 2.5, true)
			for i in range(4):
				var a: float = TAU * 0.25 * float(i) + _boss_move_t * 6.0
				var unit: Vector2 = Vector2(cos(a), sin(a))
				draw_line(unit * (radius + 16.0), unit * (radius + 30.0),
					Color(0.86, 0.68, 1.0, 0.5 + 0.4 * bt), 2.0)
		MOVE_HOMING:
			# 锁定：三条线一直拉到玩家身上，末端套一个锁定环。
			# 只画三条线的话玩家看不出"锁定的是我"——环压在谁身上，谁就该动。
			var ht: float = clampf(_boss_move_t / BOSS_HOMING_WINDUP, 0.0, 1.0)
			if is_instance_valid(target):
				var to_target: Vector2 = target.global_position - global_position
				var aim2: Vector2 = to_target.normalized()
				var side: Vector2 = aim2.orthogonal()
				var reach: float = to_target.length()
				for i in range(BOSS_HOMING_COUNT):
					var offset: Vector2 = side * (float(i) - 1.0) * 22.0
					draw_line(offset, aim2 * reach + offset,
						Color(1.0, 0.55, 0.85, 0.22 + 0.5 * ht), 2.0 + 1.5 * ht)
				draw_arc(aim2 * reach, 26.0, 0.0, TAU, 26,
					Color(1.0, 0.62, 0.88, 0.25 + 0.55 * ht), 2.0 + 1.5 * ht, true)
			draw_arc(Vector2.ZERO, radius + 12.0, 0.0, TAU, 30,
				Color(1.0, 0.6, 0.86, 0.3 + 0.55 * ht), 2.5, true)
