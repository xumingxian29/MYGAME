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
## 裂地：在指定位置落一处地裂。落点由 Boss 算（它知道玩家在哪、跑多快），
## 具体的地面预警与伤害结算归 Game——和"敌人不碰 world"是同一条边界。
signal boss_strike(at: Vector2, strike_radius: float)
## 破甲窗口开/关。HUD 换字体颜色、Game 播提示音都靠它：
## 这是玩家唯一能输出的几秒，切换必须有一个"看得见听得见"的仪式感。
signal vulnerable_changed(active: bool)

## 敌人行为类型。数值全部在 Game 里按波次抽样，这里只管"怎么动、怎么打"。
enum Kind { GRUNT, CHARGER, SPITTER, BOMBER, BOSS }

const TOUCH_COOLDOWN: float = 1.0
## 分离力权重。1.6 足够把重叠的怪推开，又不至于让它们绕着玩家转圈。
const SEPARATION_WEIGHT: float = 1.6
## 受击闪白时长（秒）
const FLASH_TIME: float = 0.14
const FLASH_COLOR: Color = Color(2.6, 2.6, 2.6)
## 破甲弹打穿壳之后的固定伤害。**不吃武器倍率、不吃卡片加成**——
## 这是整个机制的意义所在：后期卡片再多，对 Boss 的输出也只由"捡到几发"决定。
const BREACH_HIT_DAMAGE: float = 40.0
## 同一只 Boss 两次"吃弹"之间的最短间隔。轨道武器每帧都贴在 Boss 身上，
## 没有这个间隔一发弹只活 1/60 秒；有了它，上限就是每秒 4 发。
const BREACH_LOCK_TIME: float = 0.25
## 打在壳上的冷色闪光，和普通受击的白色闪光区分开：
## 白色代表"掉血了"，冷色代表"这一下没用"。
const SHELL_FLASH_COLOR: Color = Color(0.72, 0.82, 1.0)

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
## 6 → 4：连招让"召唤"出现的频率变高了（原来每 3~4 招一次，现在每轮连招都可能轮到），
## 数量不减的话 Boss 战里的怪会从 18 只涨到 45 只——那不是"Boss 战有压力"，
## 是"Boss 战变成了清屏"，而且玩家根本没空去打 Boss。
const BOSS_SUMMON_COUNT: int = 4

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
## 裂地：唯一一招"持续三秒、逼玩家一直换向"的招式。
## 旧招式全是"一发，躲完就结束"，玩家的最优解永远是站着输出、看到前摇再侧移一步。
## 裂地连续五处落点、每处都带 0.5 秒位移预判，站桩必中、直线跑也会被算到，只有变向能躲。
const MOVE_STRIKE: int = 9
## 抬手 0.7 秒 → 之后每 0.42 秒落一处，共 5 处，整招 2.4 秒
const BOSS_STRIKE_WINDUP: float = 0.7
const BOSS_STRIKE_GAP: float = 0.42
const BOSS_STRIKE_COUNT: int = 5
## 落点半径 76：玩家半径 12 + 一个身位的余量，跑出去是"两三步"的事，不该是长途奔袭
const BOSS_STRIKE_RADIUS: float = 76.0
## 位移预判系数（秒）。乘在玩家当前速度上：0.55 秒正好是"从看到落点跑到边缘"的时间，
## 所以直线跑的人会被正好算中，变向的人能把落点甩在原地。
const BOSS_STRIKE_LEAD: float = 0.55

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

## ---------------------------------------------------------------- Boss 循环
## 一场 Boss 战是「追击 → 连招 → 破甲窗口 → 追击」的循环，而不是"随时可以打"。
##
## 为什么要这么改：壳把 Boss 和玩家强度解耦之后，实测射手 3 场 Boss 各 8~9 秒打完
## （破甲锁 0.25s，12 发弹 3 秒就能倾泻完），战士却要 39 秒（他只是捡得慢）。
## 也就是说原来的时长完全由"手上攒了几发弹"决定，玩家做什么都不影响——
## 既没有节奏，也谈不上难度。加了窗口之后，单场最短时长被钉在"窗口数 × 一轮时长"，
## 和 DPS 无关；打得好是"每个窗口都装满"，打得差是"窗口开了你还在圈外"。
const BOSS_STATE_CHASE: int = 0
const BOSS_STATE_ATTACK: int = 1
const BOSS_STATE_VULNERABLE: int = 2

## 一轮连招里排几招。一阶段 3 招、二阶段 4 招：
## 二阶段的压迫感来自"喘不过气的连招"，而不是单纯多放几发。
## 3 招大约是 4.1 秒的连续出招——比破甲窗口（3.0s）长，这是有意的：
## "躲"必须比"打"更久，否则整场战斗会变成轮流互殴，读招就没有价值了。
const BOSS_COMBO_ONE: int = 3
const BOSS_COMBO_TWO: int = 4
## 起手抬手与两招之间的间隔。间隔不是"空转"——它是玩家躲完一招之后
## 唯一的呼吸空当，也是读下一招前摇的起点。低于 0.4 秒连招就没有节奏感了。
const BOSS_ATTACK_WINDUP: float = 0.55
const BOSS_MOVE_GAP: float = 0.5
## 破甲窗口。3.0 秒是按"从 300 距离跑回来（240 移速约 1.2s）+ 打出 3~4 发"定的：
## 低于 2.5 秒，"跑回来"这件事本身会变成惩罚；高于 4 秒，一次窗口就能把弹打空，
## 窗口就没有意义了。它必须短于连招段（约 4.1s），否则节奏是"打多躲少"，会反过来。
const BOSS_VULN_TIME: float = 3.0
## 追击阶段：走向玩家，最多追这么久；进到 200 以内就提前开打。
## 没有这一段的话 Boss 全程定身，玩家退到射程外它就永远打不到人也打不着它。
const BOSS_CHASE_TIME: float = 2.4
## 150 而不是 200：200 时它站在近战射程（刀 100 + 半径 38）之外出招，
## 窗口一开玩家还得先走两步——而窗口只有 3 秒。站到 150 之内再开打，
## "躲招"和"贴上去打"才在同一段距离里，不然近战职业的窗口天生比远程短一截。
const BOSS_CHASE_RANGE: float = 150.0
## 破甲窗口里的移动速度倍率。半速：它会蹭过来，但永远追不上玩家，
## "迎上去打"是玩家的选择，不是被迫的近身。
const BOSS_VULN_MOVE_SCALE: float = 0.5

## 三套招式轮换表。每套 4 招，一阶段与二阶段各一张——
## 二阶段要换的是节奏（更激进的招），而不是单纯提高频率。
## 裂地（MOVE_STRIKE）刻意排在三套表的四个位置之一：它是唯一的长招，
## 每只 Boss 都得会，否则"出招三秒、全程无敌"这个节奏只有一只 Boss 能体现。
const BOSS_KIT_TABLES: Array = [
	{
		"one": [MOVE_SHOCK, MOVE_SUMMON, MOVE_STRIKE, MOVE_SHOCK],
		"two": [MOVE_TIDE, MOVE_STRIKE, MOVE_SUMMON, MOVE_TIDE],
	},
	{
		"one": [MOVE_BARRAGE, MOVE_BLINK, MOVE_STRIKE, MOVE_BARRAGE],
		"two": [MOVE_BARRAGE, MOVE_BLINK, MOVE_CHARGE_WINDUP, MOVE_STRIKE],
	},
	{
		"one": [MOVE_STRIKE, MOVE_SUMMON, MOVE_CHARGE_WINDUP, MOVE_BARRAGE],
		"two": [MOVE_HOMING, MOVE_STRIKE, MOVE_SUMMON, MOVE_HOMING],
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

## 本局内单调递增的生成序号，由 Game 分配，从 0 开始。
##
## 为什么不直接用 `get_instance_id()`：实测（dev/id_recycle_probe.gd，4000 个对象
## 建了删、删了建）Godot 4 的实例 id 是单调递增的，**不会重复**，所以拿它当键不会串号。
## 但它**每个进程取值都不一样**：同一颗种子跑两次，日志里的 id、按 id 排出的顺序、
## 按 id 记的存活时长，都没法逐项对账，也就没法判断"这次改动到底有没有效果"。
## 序号在本局内唯一且从小往大连续，于是它同时是"跨进程可比的身份"和"确定的排序键"。
var spawn_serial: int = 0

## 由 Game 每帧写入的分离方向（单位向量，没有邻居时为零）。
## 敌人自己不查找邻居：数据向下注入、事件向上发信号，保持单向依赖。
var separation: Vector2 = Vector2.ZERO

var max_health: float = 12.0
var touch_damage: float = 8.0
## 本层难度乘数：Game 按"穿过的传送门数"算好后注入（1.0 / 1.1 / 1.21 …）。
## 乘在**所有伤害出口**上（接触、冲刺、自爆、Boss 冲击波、Boss 冲撞），
## 而不是乘在血量或速度这类单个字段——"全部属性 +10%"必须是一条全出口的规则，
## 漏掉任何一条，玩家就会找到"只吃那一种伤害"的躲避方式。
## Boss 的 power_scale 恒为 1.0：它的血量是按破甲弹发数配平的，不参与楼层放大。
var power_scale: float = 1.0
var xp_value: int = 1
## 迷宫地图由 Game 在造怪时注入；为 null 时保持原来的直线追击（自检单跑怪也安全）。
var maze: MazeMap = null

var radius: float = 10.0
## 敌人等级：0 普通 / 1 精英。评分按等级分档，结算界面会分开统计。
var tier: int = 0
## 行为类型，见 Kind。精英固定走 GRUNT：精英换成吐息者或冲锋者会让难度曲线失控。
var kind: int = Kind.GRUNT
## 是不是 Boss 召唤出来的。一场 Boss 战会召出十几到三十只，Boss 一死它们必须跟着走
## （见 Game._detonate_minions）——留着的话战后 3 秒无敌一结束就是一片贴身。
var minion: bool = false
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
## 这次闪光是"打在壳上"还是"打掉血"。决定 _tick_flash 用冷色还是白色
var _flash_shell: bool = false
## 破甲锁：>0 时 Boss 忽略伤害，且不扣弹
var _breach_lock_t: float = 0.0
## 破甲判定。由 Game 注入，返回 true 表示"这一发弹还活着"（同时扣掉一发）。
## 不注入（dev/boss_check.gd 直接 new 出来的 Boss）时视为没有壳，照常掉血。
var breach_gate: Callable = Callable()
## 减速剩余时长与强度（法师新星、战士击退后的迟滞）
var _slow_t: float = 0.0
var _slow_factor: float = 0.0
## Boss：哪一套招式轮换表（见 BOSS_KIT_TABLES）。0 潮主 / 1 蚀影 / 2 深潜者
var boss_kit: int = 0
## Boss：当前阶段（0 一阶段 / 1 二阶段）、招式轮换序号
var _boss_phase_index: int = 0
## 从 0 起手，所以第一招一定是当前 kit 表的第一项：
## 潮主先拍浪、蚀影先弹幕、深潜者先召唤。玩家两次遭遇记得住"它先干什么"。
var _boss_act: int = 0
## Boss 循环状态，见 BOSS_STATE_*
var _boss_state: int = BOSS_STATE_CHASE
## 当前状态已经持续多久。破甲窗口的倒计时、追击的时限都读它
var _boss_state_t: float = 0.0
## 本轮连招还剩几招。归零后进入破甲窗口
var _boss_combo: int = 0
## 距离下一招还有多久（招式之间、以及起手抬手的空闲）
var _boss_gap_t: float = 0.0
## 裂地已经落了几处。逐处计数而不是按时间算，
## 因为一帧跨过两个落点时要补发两处，靠时间取模会漏掉
var _boss_strike_n: int = 0
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
		xp_value = 24
		_color = Color(0.62, 0.34, 0.86)
	else:
		tier = 0
		radius = 10.0
		touch_damage = 6.0
		# 经验值第二次整体 ×2（普通 4→8、精英 12→24、特殊 6→12）。
		# 原因是视野内 20 只上限：能被杀的怪从"屏外排队几十只"变成"画面里 20 只"，
		# 单局击杀数从 1430 掉到 174（实测），等级只到 25。
		# 数量是手感、经验是成长——上限压下去之后，必须把每只怪的经验补上，
		# 否则玩家不是"打得更难"，而是"永远长不起来"。
		xp_value = 8
		_color = Color(0.86, 0.33, 0.41)
	match kind:
		Kind.CHARGER:
			radius = 9.0
			touch_damage = 9.0
			_color = Color(0.98, 0.62, 0.24)
		Kind.SPITTER:
			radius = 11.0
			touch_damage = 4.0
			xp_value = 12
			_color = Color(0.42, 0.86, 0.72)
		Kind.BOMBER:
			radius = 9.5
			# 碰撞不造成伤害，伤害全在爆炸里：不然贴一下就掉血，玩家读不懂它想干嘛
			touch_damage = 0.0
			xp_value = 12
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
	# 迷宫里沿 BFS 流场绕墙走，直线只在"这格不可达"时退化用；
	# 分离力照样叠上去，否则走廊里几十只怪会完全重合。
	if maze != null:
		var flow: Vector2 = maze.flow_dir(global_position)
		if flow != Vector2.ZERO:
			steer = (flow + separation * SEPARATION_WEIGHT).limit_length(1.0)
	var to: Vector2 = global_position + steer * _current_speed() * speed_scale * delta
	if maze != null:
		to = maze.constrain(global_position, to, radius)
	global_position = to


func _touch(dist: float, damage: float) -> void:
	if damage <= 0.0 or dist > radius + 16.0 or _touch_cd > 0.0:
		return
	if target.has_method("take_damage"):
		target.call("take_damage", damage * power_scale)
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
			target.call("take_damage", BOMB_DAMAGE * power_scale)
	hit.emit(global_position, _color)
	died.emit(self, xp_value)
	queue_free()


## Boss：追击 → 连招 → 破甲窗口 → 追击。
##
## 出招期间**定身且无敌**：定身是因为"前摇可读"的前提是它站着，边走边放玩家永远算不准该往哪躲；
## 无敌是因为输出时机必须是一个明确的窗口，而不是"谁先摸到谁赢"。
## 破甲窗口是唯一能吃破甲弹的几秒——判定在 take_damage 里，见 is_vulnerable()。
func _tick_boss(delta: float, dir: Vector2, dist: float) -> void:
	# 出场定身：这一秒里它既不动也不出招。玩家要先确认"它来了"，才谈得上读招。
	if boss_intro_t > 0.0:
		boss_intro_t = maxf(boss_intro_t - delta, 0.0)
		queue_redraw()
		return

	if _boss_phase_index == 0 and _health <= max_health * BOSS_PHASE_TWO_RATIO:
		_boss_phase_index = 1
		# 轮换序号归零：二阶段的第一招固定是它那张表的头一项，
		# 这样"潮主二阶段第一波是巨浪"是可预测的，玩家能学会、也能被测试断言。
		_boss_act = 0
		# 换阶段把窗口也关掉：一次换阶段不该顺带白送一段输出时间
		_enter_boss_state(BOSS_STATE_CHASE)
		boss_phase.emit(1)

	_boss_state_t += delta
	match _boss_state:
		BOSS_STATE_VULNERABLE:
			# 窗口里"跛着走"：以半速朝玩家挪。它必须能挪，否则会出现一个死局——
			# Boss 出招时定身，玩家为了躲招退到 400 开外，窗口一开它原地不动，
			# 3 秒根本跑不回来，于是整场战斗变成"谁离得近谁赢"。
			# 半速的意义是"它会靠近你，但绝不比你快"：想打就得迎上去，想跑也跑得掉。
			# 贴身仍然会挨接触伤害——破甲不等于没体积，"贴着它打"应该有代价。
			_move_toward(dir, delta, BOSS_VULN_MOVE_SCALE)
			_touch(dist, touch_damage)
			queue_redraw()
			if _boss_state_t >= BOSS_VULN_TIME:
				_enter_boss_state(BOSS_STATE_CHASE)
		BOSS_STATE_ATTACK:
			_tick_boss_attack(delta, dir, dist)
		_:
			# 追击：能走、能贴身，但壳是完整的
			_move_toward(dir, delta, _boss_catchup_scale())
			_touch(dist, touch_damage)
			if dist <= BOSS_CHASE_RANGE or _boss_state_t >= BOSS_CHASE_TIME:
				_enter_boss_state(BOSS_STATE_ATTACK)


## 状态切换的唯一入口。集中在这里是因为"切状态要重置哪些字段"最容易漏——
## 漏一个 _boss_move 就会带着上一招的预警环进新状态，玩家会以为招式还在放。
func _enter_boss_state(state: int) -> void:
	_boss_state = state
	_boss_state_t = 0.0
	_boss_move = MOVE_IDLE
	_boss_move_t = 0.0
	_boss_blink_done = false
	_boss_strike_n = 0
	match state:
		BOSS_STATE_ATTACK:
			# 一阶段两招、二阶段三招：二阶段的压迫感来自连招长度，不是单纯多放几发
			_boss_combo = BOSS_COMBO_TWO if _boss_phase_index == 1 else BOSS_COMBO_ONE
			_boss_gap_t = BOSS_ATTACK_WINDUP
		BOSS_STATE_VULNERABLE:
			vulnerable_changed.emit(true)
		_:
			vulnerable_changed.emit(false)
	queue_redraw()


## 连招阶段：一招接一招地放，中间留 _boss_gap_t 的空当。
## 空当不是"空转"，它是玩家躲完一招之后唯一的呼吸，也是读下一招前摇的起点。
func _tick_boss_attack(delta: float, dir: Vector2, dist: float) -> void:
	if _boss_move == MOVE_IDLE:
		queue_redraw()
		_boss_gap_t -= delta
		if _boss_gap_t > 0.0:
			return
		if _boss_combo <= 0:
			_enter_boss_state(BOSS_STATE_VULNERABLE)
		else:
			_start_boss_move()
		return

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
		MOVE_STRIKE:
			queue_redraw()
			_tick_boss_strike()
		_:
			# 表里出现了没实现的状态：结束这一招，不要让 Boss 卡在定身里
			_end_boss_move()


## 裂地：抬手之后每 0.42 秒落一处，落点带 0.55 秒的位移预判。
## 按"已落几处"计数而不是时间取模——一帧跨过两个落点时会漏掉一处，
## 而漏掉的那处正好是"本该躲掉的人站进去"的那种不公平。
func _tick_boss_strike() -> void:
	if _boss_move_t < BOSS_STRIKE_WINDUP:
		return
	while _boss_strike_n < BOSS_STRIKE_COUNT:
		var due: float = BOSS_STRIKE_WINDUP + BOSS_STRIKE_GAP * float(_boss_strike_n)
		if _boss_move_t < due:
			break
		_boss_strike_n += 1
		boss_strike.emit(_boss_strike_point(), BOSS_STRIKE_RADIUS)
	if _boss_strike_n >= BOSS_STRIKE_COUNT:
		_end_boss_move()


## 落点 = 玩家当前位置 + 速度 × 预判系数。
## 读 velocity 而不是自己差分：差分在玩家急停的那一帧会给出一个巨大的假速度，
## 落点会甩到屏幕外；CharacterBody2D 的 velocity 是引擎保证的当前速度。
## 目标不是 CharacterBody2D（自检里的 Dummy）时退化成"落在脚下"。
func _boss_strike_point() -> Vector2:
	if not is_instance_valid(target):
		return global_position
	var lead := Vector2.ZERO
	var v: Variant = target.get("velocity")
	if v is Vector2:
		lead = (v as Vector2) * BOSS_STRIKE_LEAD
	return target.global_position + lead


## 破甲窗口判定。Game / HUD / 武器都读它，是"能不能伤到它"的唯一答案。
func is_vulnerable() -> bool:
	return kind == Kind.BOSS and _boss_state == BOSS_STATE_VULNERABLE


## 血条旁边那行状态字。倒计时精确到 0.1 秒：
## 玩家要据此判断"够不够跑过去打两发"，写成整数会丢掉最关键的那一下。
func boss_state_text() -> String:
	if boss_intro_t > 0.0:
		return "登场"
	match _boss_state:
		BOSS_STATE_VULNERABLE:
			return "破甲 %.1fs" % maxf(BOSS_VULN_TIME - _boss_state_t, 0.0)
		BOSS_STATE_ATTACK:
			return "攻击中 · 无敌"
		_:
			return "逼近"


func _end_boss_move() -> void:
	_boss_move = MOVE_IDLE
	_boss_move_t = 0.0
	_boss_blink_done = false
	_boss_strike_n = 0
	# 招式之间留一个空当：玩家要靠它判断"这一招放完了、下一招还没来"
	_boss_gap_t = BOSS_MOVE_GAP
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
	# 瞬移是"跳"不是"走"。开了物理插值之后，不重置的话引擎会在旧位置和落点之间
	# 补 1 个 tick 的帧——玩家看到的是 Boss 从原地滑过去，招式就变成了"它慢慢挪过来了"。
	reset_physics_interpolation()
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
## 召唤与弹幕是瞬时生效的招式，当帧就结束（但仍占一格连招、仍留空当）；
## 其余招式进入 _boss_move 走前摇。
func _start_boss_move() -> void:
	_boss_move_t = 0.0
	_boss_gap_t = 0.0
	_boss_combo -= 1
	var kit: Dictionary = BOSS_KIT_TABLES[boss_kit]
	var table: Array = kit["two"] if _boss_phase_index == 1 else kit["one"]
	var move: int = int(table[_boss_act % table.size()])
	_boss_act += 1
	match move:
		MOVE_SUMMON:
			boss_summon.emit(global_position, BOSS_SUMMON_COUNT)
			_end_boss_move()
		MOVE_BARRAGE:
			boss_barrage.emit(global_position, BOSS_BARRAGE_COUNT)
			_end_boss_move()
		MOVE_BLINK:
			_boss_blink_done = false
			_boss_move = MOVE_BLINK
		MOVE_STRIKE:
			_boss_strike_n = 0
			_boss_move = MOVE_STRIKE
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
		target.call("take_damage", shock_damage * power_scale)


func take_damage(amount: float, bypass_shell: bool = false) -> void:
	if _dead:
		return
	# Boss 有壳：普通武器/技能的伤害打不进去，只能靠破甲弹，而且**只在破甲窗口里**。
	# 判定放在这里而不是在每个武器里，是因为伤害入口只有这一条——
	# 将来加新武器不需要记得"要不要处理 Boss"。
	if kind == Kind.BOSS and not bypass_shell and breach_gate.is_valid():
		if not is_vulnerable():
			# 出招/追击期间壳是完整的：不扣血、**也不扣弹**。
			# 不扣弹这一条很重要——否则"打早了"会白扔资源，玩家会变成不敢开枪。
			# 冷色闪光按 0.35 秒节流：轨道武器每秒 60 次贴着打，
			# 不节流的话 Boss 会被常亮成一片蓝色，反而看不出"没打进去"。
			if _breach_lock_t <= 0.0:
				_breach_lock_t = 0.35
				_flash_shell = true
				_flash_t = FLASH_TIME
			return
		if _breach_lock_t > 0.0:
			# 锁定期内静默忽略：不扣弹、不闪壳、不发声。
			# 否则轨道武器贴着 Boss 每秒 60 次"叮叮叮"，玩家会以为弹白扔了。
			return
		if not bool(breach_gate.call()):
			_flash_shell = true
			_flash_t = FLASH_TIME
			return
		_breach_lock_t = BREACH_LOCK_TIME
		amount = BREACH_HIT_DAMAGE
	_flash_shell = false
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


## 闪白衰减：亮到白是线性回落，比 Tween 少一次对象分配，也不会被后一次受击打断。
## 打在壳上是冷色：颜色不该只表示"挨了一下"，还要表示"这一下有没用"。
func _tick_flash(delta: float) -> void:
	if _breach_lock_t > 0.0:
		_breach_lock_t = maxf(_breach_lock_t - delta, 0.0)
	if _flash_t <= 0.0:
		return
	_flash_t = maxf(_flash_t - delta, 0.0)
	if _flash_t <= 0.0:
		modulate = Color.WHITE
		return
	modulate = Color.WHITE.lerp(SHELL_FLASH_COLOR if _flash_shell else FLASH_COLOR,
		_flash_t / FLASH_TIME)


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
		var pulse: float = 0.5 + 0.5 * sin(_boss_move_t * 3.0 + _boss_state_t)
		draw_arc(Vector2.ZERO, radius + 9.0, 0.0, TAU, 40,
			Color(1.0, 0.34, 0.3, 0.35 + 0.4 * pulse), 3.0, true)
	else:
		draw_arc(Vector2.ZERO, radius + 9.0, 0.0, TAU, 40, Color(0.95, 0.42, 0.45, 0.42), 2.0, true)

	# 状态环：这是整场 Boss 战唯一需要"一眼看懂"的信息——现在能不能打。
	# 金色裂纹 = 破甲窗口（倒计时弧逆时针缩短）；冷色闭锁环 = 壳完整。
	if _boss_state == BOSS_STATE_VULNERABLE:
		var left: float = clampf(1.0 - _boss_state_t / BOSS_VULN_TIME, 0.0, 1.0)
		var gold := Color(1.0, 0.84, 0.36)
		for i in range(6):
			var ca: float = TAU * float(i) / 6.0 + 0.4
			var cu := Vector2(cos(ca), sin(ca))
			# 裂纹从内核裂到边缘：形状上就是"壳碎了"，不是"套了个光环"
			draw_line(cu * radius * 0.45, cu * radius * 1.06, Color(gold, 0.5 + 0.4 * left), 2.5)
		draw_arc(Vector2.ZERO, radius + 13.0, -PI * 0.5, -PI * 0.5 + TAU * left, 44,
			Color(gold, 0.92), 4.0, true)
		var glow: float = 0.5 + 0.5 * sin(_boss_state_t * 9.0)
		draw_arc(Vector2.ZERO, radius + 20.0, 0.0, TAU, 44,
			Color(gold, 0.16 + 0.2 * glow), 2.0, true)
	elif _boss_state == BOSS_STATE_ATTACK:
		# 出招：冷色闭锁环，和破甲窗口的金色正好相反。
		# 用冷色而不是红色——红色在这个游戏里已经有"伤害"的意思了。
		draw_arc(Vector2.ZERO, radius + 13.0, 0.0, TAU, 44, Color(0.62, 0.74, 0.95, 0.34), 2.5, true)

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
		MOVE_STRIKE:
			# 抬手：本体脚下先亮一圈，告诉玩家"接下来三秒我一直在砸地"。
			# 具体的落点预警由 BossStrike 自己画——它才是那个会被躲开的东西。
			var kt: float = clampf(_boss_move_t / BOSS_STRIKE_WINDUP, 0.0, 1.0)
			draw_arc(Vector2.ZERO, radius + 8.0 + 26.0 * (1.0 - kt), 0.0, TAU, 30,
				Color(1.0, 0.56, 0.24, 0.25 + 0.55 * kt), 3.0, true)
			draw_circle(Vector2.ZERO, radius * 0.7, Color(1.0, 0.5, 0.2, 0.10 + 0.2 * kt))
