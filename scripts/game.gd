extends Node2D

## 游戏总控：刷怪、经验与升级规则、暂停与重开。界面全部交给 GameHud。
## 该节点 process_mode = ALWAYS，因此升级/死亡暂停时仍能接收输入。

## PAUSED 放末尾而不是插在 PLAYING 后面：前四个值会被 _publish_web_state 序列化给
## shell（数字直接写进 JSON），改序号会让前端那套"加载中 / 已暂停"判断错位。
## CONFIRM / SHOP 同属"整棵树冻结、HUD 面板可点"，靠状态名区分弹的是哪一块。
## STORY / VICTORY 追加在末尾：同样冻结世界，但走的是另一套界面
## （剧情屏 / 胜利结算）。旧值一个都不许动，shell 那边按数字判断状态。
enum State { MENU, PLAYING, LEVEL_UP, GAME_OVER, PAUSED, CONFIRM, SHOP, STORY, VICTORY }

## 前期节奏：前 GRACE_TIME 秒维持最轻压力，再在 RAMP_TIME 秒内平滑升到最重。
## 所有难度数值都从 _pressure() 取，改曲线只需要动这两个常量。
const GRACE_TIME: float = 45.0
const RAMP_TIME: float = 150.0

## 刷怪环按实际视野算，不再写死距离：默认 1152x648 配 zoom 1.35 时世界半宽只有 426.7，
## 原来 340~430 有一大截落在屏幕内，怪会从左右边缘凭空冒出来（垂直方向因为半高 240 才侥幸没露）。
## SPAWN_MARGIN 是"刚好在视野外"的余量，SPAWN_RING_SPREAD 让怪不在同一圈等距出现。
const SPAWN_MARGIN: float = 1.06
const SPAWN_RING_SPREAD: float = 0.3
const DESPAWN_DISTANCE: float = 1600.0
const MAX_ENEMIES: int = 180
## 触屏设备的敌人上限。手机上是单线程 WebGL（没有 SharedArrayBuffer），
## 420 只时自绘指令 + 每帧分离计算会把帧率压到 30 以下。
## 桌面上限已经收到 180，"少而硬"之后手机端 110 只的观感几乎一样，
## 绘制与查询开销正好再减一半。
const MOBILE_MAX_ENEMIES: int = 110

## 菜单底色。章节会改清屏色（_apply_stage_look），回菜单时必须换回这个值，
## 否则菜单会带着上一局的章节色调，和菜单自己的压暗层叠出一层脏色。
const MENU_BG: Color = Color(0.055, 0.062, 0.082)

## HUD 刷新间隔。_update_hud() 每次要拼 3 段字符串并写 5 个控件，
## 60Hz 下就是每秒 300 次字符串分配；手机上这种小分配会累积成可感知的抖动。
## 10Hz 对读数字完全够用（血条另有 health_changed 信号即时更新，不受影响）。
const HUD_INTERVAL: float = 0.1
## 章节横幅的"先读完再发卡"时长。必须短于 HUD 的横幅总时长（3.0 秒），
## 否则卡面板会把还没读完的章节名盖掉。
const BANNER_READ_TIME: float = 1.5
## 分离时每个敌人最多参考几个邻居。封顶避免人群中心出现 O(邻居数) 的推力尖刺。
const MAX_SEPARATION_NEIGHBORS: int = 8
## 每帧直接消掉最深那处重叠的比例。纯靠力的话，人群中心会长期保持 60% 左右的深度穿插。
const SEPARATION_RELAX: float = 0.6

## 圈外伤害的结算间隔。按帧结算的话，1%/秒在 0.0167 秒里只有 1.8‰ 最大生命，
## 血量数字会以每秒 60 次的频率抖动；0.5 秒一跳既看得出掉血节奏，也不至于显得钝。
const ZONE_TICK: float = 0.5

## 触屏设备的逻辑分辨率。1280×720 缩到手机横屏（约 844×390 CSS 像素）时，
## 字号只剩 8 个 CSS 像素，血量数字基本看不清；降到 960×540 后同样的字放大到
## 11~12 像素，代价是可见范围小一圈——对手机来说这笔交易是划算的。
## 桌面版仍用 1280×720，一行都不改。
const MOBILE_VIEWPORT: Vector2i = Vector2i(960, 540)

## 刷怪间隔：0 = 最轻，1 = 最密。
## 元气骑士式的地图是"房间里有几只值得打的怪"，不是"走廊里淌着一条怪河"。
## 间隔从 0.7/0.28 拉到 0.95/0.46，单波产出直接减半。
const SPAWN_INTERVAL_EASY: float = 0.95
const SPAWN_INTERVAL_HARD: float = 0.46
## 每过这么多秒，每波多刷一只。
## 35 → 55：晚期一波从 11 只降到 8 只，配合下面的预算收缩，场上总量减半。
const WAVE_GROWTH_SECONDS: float = 55.0
## 新章前 Stage.INTRO_TIME 秒的刷怪密度，从 0.5 线性回到 1.0。
## INTRO_TIME 以前只管"出什么"（前 15 秒只出小兵），不管"出多少"：
## 实测早死的 6 局，掉血全发生在新章开头 30 秒——Boss 战刚打完、技能和破甲弹都空着，
## 密度却已经按 elapsed 拉满（晚期一波 10 只以上）。这一条补的就是那个缺口。
const STAGE_INTRO_SPAWN_MIN: float = 0.5
## 场上同时存在的敌人上限 = BUDGET_BASE + 存活秒数 / BUDGET_STEP。
## 没有这道闸门时，刷怪速度（每秒数只）远超单目标清怪速度，屏外会堆到几百只。
##
## 12 / 4.0 → 9 / 5.5：这是"少而硬"这条线的第一半（另一半是下面的血量）。
## 390 秒时的上限从 109 掉到 79，场上实际数量从 90 上下掉到 55 上下——
## 一张 9 房间的图，平均每房间 6 只，接近元气骑士一个普通房间的量级。
##
## 第一版收到 8 / 7.0（390s 上限 63）时，10 局中位从 262s 掉到 124s：
## 怪少了一半，经验也少了一半，玩家升级变慢、卡变少、DPS 更低——
## 数量本身成了负循环。所以数量只减 27%，缺的经验由 xp_value 补齐（见 Enemy.configure）。
const BUDGET_BASE: int = 9
const BUDGET_STEP: float = 5.5

## 视野内敌人上限。与上面的全场预算分开：预算是"屏外可以排队多少"，
## 这条是"画面里同时最多几只"。玩家对看不见的东西没有压力感，
## 屏外堆 80 只只会让台架数据好看、手感没有任何变化。
## 20 → 40：20 那一版实测在后期"打着打着画面空了"，走廊两侧的怪被推得太干净，
## 连击手感断掉。40 仍然是"看得见来源"的量级，不至于变成一堵墙。
const VISIBLE_ENEMY_CAP: int = 40
## Boss 战单独收紧到 10。Boss 的攻防循环本身就要占掉全部注意力，
## 再加十几只小弟就不是"读招"，是"被推着走"。
const BOSS_FIGHT_ENEMY_CAP: int = 10
## 超额驱逐的检查间隔。每帧遍历 80 只敌人毫无必要，0.25 秒足够——
## 怪从视野边缘走进来的速度约 100px/s，0.25 秒只移动 25px。
const VISIBLE_CAP_TICK: float = 0.25
## 屏外允许排队的数量。不设这条的话，全场上限仍是 79，屏外会一直堆着
## 五十多只等着往视野里挤，驱逐逻辑每 0.25 秒就要推一次，边缘看起来像在抖。
## 视野上限抬到 40 之后缓冲也跟着放宽到 20：比例还是 1:0.5，
## 缓冲太薄的话"补位"会跟不上 40 只的消耗速度，画面会一阵一阵地空。
const ENEMY_OVERFLOW_ALLOWANCE: int = 20
const ENEMY_HP_BASE: float = 9.0
## 敌人血量 = BASE + 线性项 + 二次项。纯线性追不上后期的卡牌成长：
## 实测 300 秒时玩家 19 张卡、血量还剩 161/274，等于后期没有威胁。
## 二次项只在 150 秒后明显起作用（100 秒时只多 3 点血），不会反过来压死前中期。
##
## BASE 只给 11 而不是 16：16 是"血量翻倍"的第一版，实测开局三分钟内
## 9/10 局直接死（战士中位 124s），因为玩家开局 DPS 是固定的，每只怪多花一下
## 就等于被多围一秒。后期靠线性/二次项补，不用靠 BASE 补。
const ENEMY_HP_GROWTH: float = 0.30
const ENEMY_HP_QUADRATIC: float = 0.0009
const ENEMY_SPEED_MIN: float = 62.0
const ENEMY_SPEED_MAX: float = 94.0
const ENEMY_SPEED_GROWTH: float = 0.35
## 速度上限。封在 46 意味着敌人总速 140，而玩家是 226~252——差 90 像素/秒，
## 会走位的人**永远**不会被追上，后期唯一的死法就是圈缩没（实测 12 局里 8 局死时满血）。
## 但直接把上限抬到 81（总速 175）是错的方向：那一版战士的中位存活从 483s 掉到 185s，
## 变成"全程更难"而不是"后期更难"，等于把中期玩家一起劝退。
## 结论：这条线不要动，后期压力交给下面那条只跟时间走的曲线。
const ENEMY_SPEED_CAP: float = 46.0

## 后期威胁曲线：一条只跟 elapsed 走的压力，盖在章节权重与基础曲线之上。
## 为什么需要它：章节时钟会被 Boss 战拖住（见 _physics_process），而"拖住"恰好
## 集中在后期，于是玩家越强、拖得越久，难度反而越平——这是"满血拖到圈缩没"的根因。
##
## 关键是**起点**：0~240 秒必须与没有这条曲线时**一模一样**。早中期动一点，
## 死亡时间就整体前移（见上面 ENEMY_SPEED_CAP 的对照数据）。
## 两条压力同步爬升，240 秒起、390 秒爬满：
##   速度 +28（总速 140→168，仍低于所有职业，但绕圈时必须贴边）
##   吐息者占比 +0.20（它是唯一不贴身就能造成伤害的敌人，"站桩清屏"不再安全）
const THREAT_START: float = 240.0
const THREAT_RAMP: float = 150.0
const THREAT_SPEED_BONUS: float = 28.0
const THREAT_SPITTER_BONUS: float = 0.20
const THREAT_SPECIAL_CAP: float = 0.70
## 精英是**收益**不是惩罚：xp_value 6（普通 2）、血量只 ×2.4，而且 tier > 0 击杀还额外补
## 一枚破甲弹。实测把它从 45/0.12 提到 30/0.15，10 局中位反而 280.6 → 310.1、通关 4/10 → 5/10。
## 想靠精英加难度只能动血量倍率（Enemy.configure 里的 2.4）或接触伤害，别动出现时间/概率。
const ELITE_START_TIME: float = 45.0
const ELITE_CHANCE: float = 0.12

## 每穿过一道传送门，下一幕的普通怪属性按门的难度累加上去（加法，不是连乘）。
## 为什么是累乘：玩家过一关拿一张卡 + 回一部分血，成长是乘法级的（卡牌叠乘），
## 敌人用加法会被越甩越远——这正是旧版"越后期越宽裕"的根因。
## 10% 这个数不是拍的：三张图之后 1.33，五张图之后 1.61，刚好和玩家一轮成型
## （约 5~6 张核心卡）的强度同步；再高会变成"过两关就必死"。
## 只作用于普通怪（含精英）与它们的伤害，不作用于 Boss：
## Boss 血量 = 破甲弹发数 × 固定 40，随难度乘会直接破坏"捡几发打几下"的配平，
## Boss 的成长走 Stage 表自己的 hp_scale / breach_shots 曲线。
## 每层的增量不再固定 +10%，改由"走的是哪扇门"决定（见 Portal.DIFFICULTY）。
## 速度单独封顶。连乘几次之后怪速会超过玩家，风筝流直接失效；
## 更糟的是"跑不掉"不是难度，是判死刑。所以速度只吃前几层的加成，停在 1.5×。
const FLOOR_SPEED_CAP: float = 1.5

## 商人三件货。价格整体 ×10：原来的 160 金在"一张图 540 金"的尺度下，
## 半张图的收入就能拿一瓶药，商人退化成了自动售货机。
## 现在 1600 金 ≈ 一整张图的收入，买药变成"这趟还要不要继续"的决定。
## 破甲弹仍然最便宜：它是 Boss 战的入场券，不该让玩家因为穷而卡关。
const SHOP_HEAL_PRICE: int = 1600
const SHOP_BREACH_PRICE: int = 600
const SHOP_CARD_PRICE: int = 1200

## 价格随"第几张图"上涨，不随"活了多久"——玩家能理解"越深越贵"，
## 理解不了"同一瓶药过两分钟就涨价"。
const SHOP_PRICE_STEP: float = 0.45

## 回血量分两段：前三关（第 1~3 图）固定 5% 最大生命，第 4 图起固定 100 点。
## 早期血池小，5% 基本是"擦破皮"，逼玩家别把商人当回血站；
## 后期血池被卡牌抬到 300+，固定 100 点占比自然缩水，同样在收紧。
const SHOP_HEAL_RATIO_EARLY: float = 0.05
const SHOP_HEAL_FLAT_LATE: float = 100.0
const SHOP_HEAL_FLAT_FROM_FLOOR: int = 3

## Boss 战期间破甲弹掉落的加速倍率（乘在 breach_every 上）。
## 不加这一条会出人命：Boss 站着不动等你打，玩家手上没弹又等不到掉落，
## 只能干看着血条——那不是难度，是卡关。0.6 让 Boss 战里的掉率明显高于平时，
## 但还没高到"站桩捡弹就能磨死它"——弹要边躲边捡。
const BREACH_BOSS_FIGHT_SCALE: float = 0.6

## 特殊敌人的构成改由 Stage 提供（每章一张权重表），这里只保留共用参数。
## 权重按时间分批放开的历史原因还记得：开局 30 秒内只有普通敌人，先让玩家熟悉基本循环。
## 现在这件事由"每章前 INTRO_TIME 秒只出小兵"承担，粒度从整局变成了每章。
## 吐息者的子弹：比玩家慢得多（玩家 226+），所以能靠横移躲开，站桩躲不掉
const SPIT_SPEED: float = 158.0
const SPIT_DAMAGE: float = 7.0

## Boss：血量按当期普通怪血量的 22 倍给。28 倍实测下来第一只 Boss 要打 14~49 秒：
## 22 秒那局是理想情况（玩家贴着打），49 秒那局是全程在跑、武器都在打小怪。
## 49 秒塞在章节里会让 Boss 变成接力赛，所以整体压一档；
## 压缩时长后同步把出招间隔从 3.4 收到 3.0，保证一场里的出招次数不减少。
## 出场时机不再由固定秒数决定，而是由 Stage 的章节时长决定——见 _check_boss。
const BOSS_HP_MULT: float = 22.0
## 基础速度只有普通怪的 55%：玩家能拉开，但拉开太远 Boss 会自己加速追（Enemy 侧实现）
const BOSS_SPEED_SCALE: float = 0.55
const BOSS_SHOT_SPEED: float = 138.0
const BOSS_SHOT_DAMAGE: float = 9.0
## 深潜者的追踪弹：比弹幕慢（138 → 112），但会拐弯。
## 转向速度 2.2 rad/s 是"跑得动就能甩掉"的上限——低于 1.5 就变成必中，
## 高于 3.0 玩家只要不绕大圈就永远躲不开。
const BOSS_HOMING_SPEED: float = 112.0
const BOSS_HOMING_TURN: float = 2.2
## 裂地单处伤害。一处 16 ≈ 玩家满血的 9%~16%，五处全中依然必死——
## 它的定位是"站桩的惩罚"而不是磨血：能躲开的人完全无伤，不躲的人 5 秒内会被抬走。
## 20 → 16 是因为 Boss 战整体变长了（窗口机制让一场从 9 秒变成 25~40 秒），
## 单发不降的话"总伤害预算"会翻三倍，脆皮职业连第一只都过不去。
const BOSS_STRIKE_DAMAGE: float = 16.0
const BOSS_HOMING_DAMAGE: float = 11.0
## 击杀掉落：把原来的一颗大宝石拆成一圈小宝石。
## 总经验基本不变（8 颗 × 6 = 48 vs 45），但"打完炸出一地经验"是胜利的实感。
const BOSS_GEM_COUNT: int = 8
## Boss 入场时把场上普通怪压到这个数，之后全程只减不增。
## 不压的话，晚期一场 Boss 战里玩家其实是在跟 60~100 只小怪周旋，Boss 反倒成了背景板
## ——10 局实测里 7 局的死法都是"打完 Boss 血已见底、撞上下一章密集段"。
## 8 是"召唤 4 只 + 一轮连招"的场地容量：和战前压力持平，但不叠加。
## 设成 999 等于关掉这条退场逻辑。
const BOSS_ARENA_CAP: int = 8
## 击杀后的喘息窗口：不刷怪，让玩家安心捡一地的宝石
const BOSS_GRACE_TIME: float = 3.0
## 击杀回血比例。Boss 战本身就是一场资源消耗，不给回血的话下一个 Boss 必然接不住。
const BOSS_HEAL_RATIO: float = 0.15
## Boss 战期间红边的最低强度。表达的是"这一场很危险"的氛围压力，
## 而不是"你血量告急"——所以只开 0.18，比血量 35% 时的强度低得多。
const BOSS_DANGER_FLOOR: float = 0.18
## 血量低于这个比例时开始出红边，0 血满强度
const DANGER_HEALTH: float = 0.35
## 每次受击生成火花的概率。全出的话高密度下每秒几百次，屏幕会糊成一片白
const HIT_SPARK_CHANCE: float = 0.5

## 升级卡节奏：固定每 CARD_GAP 级发一张，即 Lv.2 / 4 / 6 / 8 / 10 / 12 …
## 早先的间隔是逐次 +1（Lv.2/4/7/11/16/22），实测 60 秒时就已 Lv.11 却只有 4 张卡，
## 之后连升 4 级一张都没有——升级铃声响了却没奖励，这是"玩得憋屈"的直接来源。
## 卡变多了，但单张价值不降：稀有度仍随等级上移，见 CardRarity。
const FIRST_CARD_LEVEL: int = 2
const CARD_GAP: int = 2
## 经验需求每级放大系数。1.22 太大：等级越升越慢的同时卡还越来越少，双重惩罚。
const XP_GROWTH: float = 1.18
## 升级**不再回血**。原来的 6% 让"刷经验"同时是续航手段，等于把"缺血"这件事
## 从游戏里删掉了：只要还在升级，血线就自己回来，商人和回血道具都没有存在意义。
## 现在回血只有四个来源：脱战自然回复、Boss 战后 15%、通关补满、商人。
const GOLD_BASE_KILL: int = 6
## 金币也随层数涨，但涨得比价格慢（0.30 vs 0.45）：两者同速的话，
## "越深越贵"就只剩下数字变大，实际负担一点没变。
const GOLD_FLOOR_STEP: float = 0.30

## 升级卡数据表。unit：flat 固定值 / pct 百分比 / count 整数层数 / unlock 解锁
const CARDS: Array[Dictionary] = [
	{"id": "bullet_damage", "icon": "伤", "name": "弹药强化", "desc": "子弹伤害", "unit": "pct", "amount": 0.22},
	{"id": "bullet_rate", "icon": "速", "name": "快速装填", "desc": "攻击速度", "unit": "pct", "amount": 0.12},
	{"id": "bullet_proj", "icon": "弹", "name": "散射", "desc": "额外弹丸", "unit": "count", "amount": 1.0},
	{"id": "bullet_pierce", "icon": "穿", "name": "穿甲", "desc": "穿透", "unit": "count", "amount": 1.0},
	{"id": "bullet_range", "icon": "程", "name": "校准", "desc": "攻击范围", "unit": "flat", "amount": 60.0},
	{"id": "orbit_unlock", "icon": "刃", "name": "环绕飞刃", "desc": "解锁环绕飞刃", "unit": "unlock", "amount": 1.0},
	{"id": "orbit_count", "icon": "舞", "name": "双刃", "desc": "飞刃数量", "unit": "count", "amount": 1.0},
	{"id": "orbit_damage", "icon": "锋", "name": "锋刃", "desc": "飞刃伤害", "unit": "flat", "amount": 6.0},
	{"id": "orbit_radius", "icon": "环", "name": "外扩", "desc": "环绕半径", "unit": "flat", "amount": 22.0},
	{"id": "orbit_speed", "icon": "旋", "name": "疾旋", "desc": "环绕速度", "unit": "pct", "amount": 0.15},
	{"id": "boomerang_unlock", "icon": "镖", "name": "回旋镖", "desc": "解锁回旋镖", "unit": "unlock", "amount": 1.0},
	{"id": "boomerang_count", "icon": "影", "name": "分影", "desc": "回旋镖数量", "unit": "count", "amount": 1.0},
	{"id": "boomerang_damage", "icon": "锐", "name": "锐镖", "desc": "回旋镖伤害", "unit": "flat", "amount": 7.0},
	{"id": "boomerang_range", "icon": "远", "name": "远掷", "desc": "投掷距离", "unit": "flat", "amount": 45.0},
	{"id": "boomerang_rate", "icon": "疾", "name": "连掷", "desc": "投掷频率", "unit": "pct", "amount": 0.12},
	{"id": "move", "icon": "行", "name": "轻身", "desc": "移动速度", "unit": "pct", "amount": 0.08},
	{"id": "hp", "icon": "命", "name": "强健体魄", "desc": "生命上限", "unit": "pct", "amount": 0.18},
	{"id": "melee_damage", "icon": "斩", "name": "重斩", "desc": "近战伤害", "unit": "pct", "amount": 0.2},
	{"id": "melee_rate", "icon": "快", "name": "疾斩", "desc": "挥砍速度", "unit": "pct", "amount": 0.14},
	{"id": "melee_reach", "icon": "延", "name": "长刃", "desc": "近战范围", "unit": "flat", "amount": 18.0},
]

var player: Player
var hud: GameHud
var start_menu: StartMenu
## 触屏操作层（虚拟摇杆 + 技能键）。桌面设备上它自己保持隐藏，
## 这里不需要到处判空，直接当"永远存在但可能不显示"的组件用。
var touch: TouchControls
## 本次是否以触屏模式运行：决定菜单文案、HUD 文案与结算按钮
var _touch_mode: bool = false
## 本局实际的敌人上限。桌面用 MAX_ENEMIES，触屏设备在 _ready 里换成 MOBILE_MAX_ENEMIES，
## 这样两套预设共存，改手机参数不影响桌面手感。
var _max_enemies: int = MAX_ENEMIES
## HUD 节流计时器，每 HUD_INTERVAL 秒才刷新一次文字与分数
var _hud_timer: float = 0.0
## 世界容器：显式 PAUSABLE。Game 自身是 ALWAYS，若子节点用默认 INHERIT 会跟着 ALWAYS，
## 导致 get_tree().paused 形同虚设（升级选卡时后台照样掉血）。
var world: Node2D

var _enemies: Array[Enemy] = []
## 属性的"出厂值"与"原始加成账本"。两者都由 _capture_stat_bases 在开局建立，
## 之后每张卡只往账本里加数，最终值永远从出厂值重算——这样上限不会因为
## "中途拿现在的值当新基准"而失效（那是数值系统里最经典的一类漏洞）。
var _stat_base: Dictionary = {}
var _stat_raw: Dictionary = {}
## 本局的下一个敌人序号。每局归零，保证同一局内"序号 → 生成顺序"完全可复现。
var _next_serial: int = 0
var _gems: Array[XpGem] = []
## 地上还没被捡走的破甲弹
var _items: Array[ItemModule] = []
## 手上还有几发破甲弹。**每次攻击花一发**（开火/挥砍/投掷各算一次），
## 所以它既是"Boss 输出预算"，也是"清场时要不要加码"的选择。
var _breach: int = 0
## 本局金币。跨图保留、跨局归零：它是"这一局的经营成果"，
## 换图清零等于逼玩家每张图都攒到刚好花完，那不叫经营，叫算术题。
var _gold: int = 0
## 距离下一次掉落攒了多久。平时攒着、等击杀时一起兑现，Boss 战里直接按时间掉
var _breach_timer: float = 0.0
## 当前在场的 Boss（null 表示没有 Boss 战）。HUD 血条与危险底噪都读它
var _boss: Enemy = null
var _boss_kills: int = 0
## Boss 死后的免刷怪窗口
var _boss_grace: float = 0.0
## 当前章节序号（0 起）与本章已进行的秒数。章节时钟只在本章没有 Boss 时走，
## 这样"打了 30 秒 Boss"不会把下一章的开场时间吃掉。
var _stage_index: int = 0
var _stage_time: float = 0.0
## 这一局是否逃出了城堡。它由 _on_victory 唯一写入——
## 十幕之后，"通关"不再等于"章节数够了"（那个判断会在第四幕误触发）。
var _cleared: bool = false
## 发卡延迟：章节开场要先把横幅读完，再弹选卡面板。
## 没有这个延迟时，横幅会被压暗层盖住，玩家只看到一张卡，不知道自己在哪一章。
var _card_delay: float = 0.0
## 背景网格颜色随章节主题色变化（见 _apply_stage_look）
var _grid_color: Color = Color(1.0, 1.0, 1.0, 0.045)
## 命中火花容器：整个局共用这一个节点，粒子在它内部用数组管理
var _sparks: HitSparks = null
## 缩圈。挂在 world 下，z_index = -1，画在所有游戏物体之下、背景网格之上。
## 它只回答三件事：圈在哪、多大、圈外掉多少血；怎么用（伤害结算、刷怪夹紧）都在 Game 里。
var zone: Zone = null

## 迷宫地图。挂在 world 下，z_index = -1，画在所有游戏物体之下。
## 去毒圈后由它承担边界：只回答「哪里能走、怎么绕」，不再有圈外伤害这一层结算。
## zone 变量暂时留着（恒为 null），旧台架读它会自动走「没有圈」的分支，P4 再清理。
var maze: MazeMap = null

## 第几张地图。三个传送门每次换图 +1，HUD 与结算面板都读它。
var _map_index: int = 0
## 一局能穿过的门数。第 10 扇门之后不是"下一张图"，而是王座厅。
## 写成常量而不是散在判断里：剧情有 10 幕、门的计数上限、HUD 上的 "N/10"
## 三处必须永远是同一个数，否则玩家会在第 9 幕看到一个空屏。
const PORTAL_LIMIT: int = 10
## 王座厅的守门人数量与出场节奏。
## 16 + 8×i 发：五位分别是 16/24/32/40/48 发，合计 160 发。
## 这个数不是拍的：一次破甲窗口 3.0 秒、按 0.25 秒的锁定间隔最多吃 4 发，
## 16 发等于"必须走完四个窗口"，而窗口之间玩家要躲招、捡弹——
## 五位连着打，节奏才刚好是"一场长战"而不是五场小战。
const GAUNTLET_BASE_SHOTS: int = 12
const GAUNTLET_SHOT_STEP: int = 2
## 王座厅的破甲弹掉率（秒/枚）。比平时快：五位连着打，中间没有普通怪给玩家
## "用击杀换弹"的机会，掉率必须直接喂到手上，否则第四位就只能看着它放招。
const GAUNTLET_BREACH_EVERY: float = 1.5
## 两位守门人之间的间隔。太短的话前一位的弹幕还没散，下一位就贴脸进场了。
const GAUNTLET_GAP: float = 2.4

## 已经穿过几道传送门。
## 和 _map_index 分开记：_map_index 是"玩家看到第几张图"（含第一张，从 0 起），
## _floor 是"被放大过几次"（第一张图是 0 次）。两者数值恰好相同但语义不同。
var _floor: int = 0
## 累计难度增量。原来是 FLOOR_POWER_STEP ^ _floor（每层固定 +10%），
## 现在由"走的是哪扇门"决定——四扇门的增量从 +20% 到 +100% 不等，
## **加法累加**而不是连乘：连乘在 +100% 那扇门之后会直接翻倍再翻倍，
## 五层就到 32 倍，那是"选错一次就死"，不是选择。
var _floor_power: float = 0.0
## Boss 已死、四扇门已开、等玩家选门的这段"间隙"。
## 它必须独立成一个标记，不能靠 _boss == null 判断：_boss 在战斗间隙也常是 null。
## 这个状态下停刷、停 Boss 检查、也不推进章节时钟——玩家可以慢慢挑门。
var _awaiting_portal: bool = false
## 场上活着的传送门。换图时统一 free，否则上一张图的门会跟着留在世界里。
var _portals: Array[Portal] = []
## 玩家踩上去、正在等确认的那扇门。null 表示当前没有待确认的门。
var _pending_portal: Portal = null
## 已经穿过的门数（0..PORTAL_LIMIT）。第 PORTAL_LIMIT 扇门之后进王座厅，
## 而不是"再换一张图"。之所以单独计数而不是用 _map_index：
## 王座厅也是一张图，但它不是"又过了一道门"。
var _portal_count: int = 0
## 十次选门的记账：{"card": n, "card2": n, "breach": n, "gold": n}。
## 键用短名而不是 Portal.Reward 的枚举值——这份账要交给 Story 判结局，
## 而 Story 是纯数据表，不该认识玩法层的枚举。
## 名字叫 trail 不叫 choices：_choices 已经是升级三选一的卡片列表，
## 两个都叫 _choices 会在赋值时互相覆盖，而且不会有任何报错。
## 最后一个选择单独记：票数并列时用"最后选的那个"破平，而不是按固定优先级——
## 玩家会觉得"我最后想要的是这个"，而不是"表里这个排在前面"。
var _gate_trail: Dictionary = {}
var _last_choice: String = ""
## 这一局走到哪个结局（由 _choices 在开门那刻算定）。金门下面的字、结算标题、
## 存档都用它。空串表示还没算（还没走完十道门）。
var _ending: String = ""
## 王座厅：还剩几位守门人 / 一共几位 / 下一位的下标 / 出场倒计时。
var _gauntlet_left: int = 0
var _gauntlet_total: int = 0
var _gauntlet_index: int = 0
var _gauntlet_delay: float = 0.0
## 这一局是不是"逃出城堡"。结算面板与存档都靠它区分胜利与阵亡。
var _victory: bool = false
## 剧情屏。开场与每次穿门各播一幕，播完由 _story_after 决定接着做什么。
var story_panel: StoryPanel = null
## 自检 / 台架开关。关掉之后 _play_story 会立刻按"已播完"收尾，
## 但横幅、新手提示、状态转换一步不少——量到的还是同一条流程，
## 只是不用等打字。默认开着，玩家那边永远走真剧情。
var story_enabled: bool = true
var _story_open: bool = false
var _story_after: String = ""
## 本图的商人。换图时旧的要显式 free：_rebuild_map 只清敌人/宝石/道具/地图，
## 商人不在那几张表里，不点名清就会跟着进下一张图。
var _merchant: Merchant = null
## 商人货架。每张图重置一次 bought 标记——同一个商人不会让你买两次，
## 但下一个迷宫里的商人有全新的库存。
var _shop_stock: Array[Dictionary] = []

## 音效总控。跨局复用：换角色、重开一局都不重建，否则每局要重新加载 14 个流。
var audio: GameAudio = null
## 新手引导提示条。同样跨局复用——"看过哪些"记在它自己身上。
var tutorial: TutorialHint = null
var _zone_dmg_timer: float = 0.0
## 每帧重建的空间网格，只服务敌人分离
var _grid: EnemyGrid = EnemyGrid.new()
## 邻域查询的复用缓冲，避免每帧为每个敌人分配一个数组
var _neighbor_buf: Array = []
var _state: State = State.MENU
var _elapsed: float = 0.0
## 死因。结算面板与 bot 都读这个字段——"圈外死亡占比"是毒圈调参的核心指标，
## 没有它就只能看存活时长，分不清玩家是被怪打死还是被圈逼死。
## 每次开局重置成"敌人"，毒圈伤害致死前会改成"圈外"。
var _death_cause: String = "敌人"
var _kills: int = 0
var _elite_kills: int = 0
var _level: int = 1
var _xp: int = 0
var _xp_total: int = 0
var _xp_need: int = 6
var _spawn_timer: float = 0.25
## 视野上限的检查计时器。与 _spawn_timer 分开：刷怪是节奏，驱逐是兜底，
## 两者同相会变成"刚刷完就清一轮"的固定抖动。
var _cap_timer: float = 0.0
## 待发奖的强化卡数量（一次升级可能连跨多级，但只有到了阈值才发卡）
var _pending_cards: int = 0
## 下一张卡要到几级才发
var _next_card_level: int = FIRST_CARD_LEVEL
var _choices: Array[Dictionary] = []
## 当前玩家的档案 {"name", "best", "runs", "total_kills"}，由 ScoreBoard 读写
var _profile: Dictionary = {}
## 本局职业，以及菜单里上次选的职业（换人时沿用，不用每次重选）
var _hero: int = HeroClass.WARRIOR
var _last_hero: int = HeroClass.WARRIOR
## 外部打断导致的暂停原因："portrait"（竖屏）/ "hidden"（切后台）。
## 用一个集合而不是几个 bool：手机可以同时"竖屏 + 切后台"，
## 只解除其中一个时游戏不该突然跑起来。
## 也不复用 _state——外力打断不是状态转移，玩家回来必须回到原来的局面
## （可能在选卡，也可能已经结算）。
var _external_pauses: Dictionary = {}
## Web 桥是否可用。非 web 平台（含 headless 自检）恒为 false，所有 JS 调用都要先问它
var _web_bridged: bool = false
## create_callback 返回的对象必须用成员变量保引用，否则会被 GC 回收、回调静默失效
var _web_pause_cb: JavaScriptObject = null
## 上一次推给 shell 的状态，用来去重：每帧调一次 _publish_web_state 也不会重复写 JSON
var _web_last_state: int = -1
var _web_last_paused: bool = false
var _web_last_reasons: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	_touch_mode = TouchControls.is_touch_device()
	# 必须在建 UI 之前切：HUD 与菜单都用锚点铺满视口，换基准分辨率后会跟着重排
	if _touch_mode:
		_apply_mobile_viewport()
		_max_enemies = MOBILE_MAX_ENEMIES
	RenderingServer.set_default_clear_color(MENU_BG)
	world = Node2D.new()
	world.name = "World"
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(world)
	_build_audio()
	_build_hud()
	_build_tutorial()
	_build_touch()
	_build_menu()
	# 剧情屏最后建：它要盖在 HUD、菜单、触屏控件之上。
	# 建在前面的话，菜单背后的剧情屏会被后建的 HUD 压住（Node2D/Control 按子节点顺序绘制）。
	_build_story()
	_open_menu()
	# 窗口尺寸变化（旋转屏幕 / 拖动浏览器窗口 / Web 端 canvas 重排）后要重设一次基准分辨率
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_setup_web_bridge()


## 只在触屏设备上调用。content_scale_size 就是"逻辑分辨率"，
## 与 project.godot 里的 viewport_width/height 是同一个东西，可以运行时改。
func _apply_mobile_viewport() -> void:
	var window: Window = get_window()
	if window != null:
		window.content_scale_size = MOBILE_VIEWPORT


## 旋转 = 屏幕尺寸变化。手机（尤其 Android）旋转会重建窗口，运行时设过的
## content_scale_size 会被引擎重置回 project.godot 的 1280x720，而 HUD 与触屏控件
## 都是按 960x540 布的局 —— 两者对不上就会看到"字突然变大、按钮跑出屏幕"。
## 所以尺寸一变就重设一次；桌面端 _touch_mode 为 false，这里是空操作。
func _on_viewport_size_changed() -> void:
	if _touch_mode:
		_apply_mobile_viewport()


# ---------------------------------------------------------------- 外部打断暂停（Web）

## 只在 Web 导出里跑。桥是双向的：
##   shell → 引擎  window.__nsPause(reason, 1/0)：reason 是 "portrait" 或 "hidden"
##   引擎 → shell  window.__nsState(JSON)：让前端提示能区分"正在加载"和"已暂停"
func _setup_web_bridge() -> void:
	if not OS.has_feature("web"):
		return
	var win: JavaScriptObject = JavaScriptBridge.get_interface("window")
	if win == null:
		return
	_web_bridged = true
	_web_pause_cb = JavaScriptBridge.create_callback(_on_web_pause)
	win.__nsPause = _web_pause_cb
	# 引擎起来之前 shell 可能已经推过原因（玩家竖着打开页面、或者标签页在后台），
	# 那时候回调还不存在，消息直接丢了。所以反过来主动要一次当前状态。
	JavaScriptBridge.eval("window.__nsResync && window.__nsResync();", true)
	_publish_web_state()


## shell 传进来的是个 Array（JavaScriptBridge 的回调永远给数组）：
## [reason: String, on: int]
func _on_web_pause(args: Array) -> void:
	if args.size() < 2:
		return
	var reason: String = str(args[0])
	if reason.is_empty():
		return
	var on: bool = int(args[1]) != 0
	# 同一个原因重复推（真机上 change 事件会连发）不该有第二次副作用
	if on == _external_pauses.has(reason):
		return
	if on:
		_external_pauses[reason] = true
	else:
		_external_pauses.erase(reason)
	_sync_pause()
	_publish_web_state()


## 统一算一次"该不该暂停"。所有解除暂停的路径都必须走这里，
## 不能直接写 paused = false —— 否则"选卡时切后台"会被开局/选卡结束那两行放跑。
func _sync_pause() -> void:
	get_tree().paused = not _external_pauses.is_empty() or _state != State.PLAYING


## 把暂停状态写给 shell。只在变化时写（每帧调用也只是一次 int 比较 + 一次 join）。
func _publish_web_state() -> void:
	if not _web_bridged:
		return
	var paused: bool = get_tree().paused
	var reasons: String = ",".join(_external_pauses.keys())
	if _state == _web_last_state and paused == _web_last_paused and reasons == _web_last_reasons:
		return
	_web_last_state = _state
	_web_last_paused = paused
	_web_last_reasons = reasons
	var win: JavaScriptObject = JavaScriptBridge.get_interface("window")
	if win == null:
		return
	win.__nsState = JSON.stringify({
		"paused": paused,
		"reasons": _external_pauses.keys(),
		"state": _state,
		"elapsed": snappedf(_elapsed, 0.1),
	})


func _build_audio() -> void:
	audio = GameAudio.new()
	audio.name = "Audio"
	add_child(audio)


func _build_hud() -> void:
	hud = GameHud.new()
	add_child(hud)
	hud.audio = audio
	hud.card_chosen.connect(_choose)
	hud.set_touch_mode(_touch_mode)
	# 手机上按不到 R / P，结算面板给两个按钮；键盘路径同时保留
	hud.restart_requested.connect(_restart)
	hud.menu_requested.connect(_open_menu)
	# 暂停键与暂停面板里的"继续"共用同一条信号：语义是"切换"，不是"暂停"。
	hud.pause_toggled.connect(_on_pause_toggled)
	hud.portal_confirmed.connect(_confirm_portal)
	hud.portal_cancelled.connect(_cancel_portal)
	hud.shop_buy.connect(_on_shop_buy)
	hud.shop_closed.connect(_close_shop)


func _build_tutorial() -> void:
	tutorial = TutorialHint.new()
	tutorial.name = "Tutorial"
	add_child(tutorial)


func _build_touch() -> void:
	touch = TouchControls.new()
	add_child(touch)
	touch.skill_pressed.connect(_on_skill_button)


func _build_menu() -> void:
	start_menu = StartMenu.new()
	add_child(start_menu)
	start_menu.audio = audio
	# 每次回菜单都要刷新一次静音文案：玩家可能在结算页之外用别的方式改过状态
	start_menu._refresh_mute_text()
	start_menu.started.connect(_on_menu_started)


func _build_story() -> void:
	# 剧情屏必须挂在一个 CanvasLayer 下面：Control 的锚点是相对"父节点的矩形"算的，
	# 而 Game 是 Node2D，没有矩形——直接 add_child 之后 PRESET_FULL_RECT 会失效，
	# 整块面板缩到左上角一小团（截图抓到的）。
	# 项目里 HUD / 触屏 / 菜单全是 CanvasLayer，这里沿用同一套。
	var layer := CanvasLayer.new()
	layer.name = "StoryLayer"
	# layer 5：压在 HUD（默认 1）与菜单之上。剧情的语义就是"盖住一切"。
	layer.layer = 5
	add_child(layer)
	story_panel = StoryPanel.new()
	story_panel.name = "Story"
	layer.add_child(story_panel)
	story_panel.finished.connect(_on_story_finished)


## 播一幕剧情。after 决定播完之后接哪一段流程：
##   "start"  —— 新一局的开场，播完才把世界放开
##   "portal" —— 刚穿过一道门，新图已经建好了（**先建地图再播剧情**：
##               剧情播完玩家睁眼就在新房间里，而不是先看到旧房间再闪一下）
##   "final"  —— 第 10 扇门之后，王座厅，播完开始放第一位守门人
func _play_story(act_index: int, after: String) -> void:
	if not story_enabled:
		# 直接把"播完"这一刻走一遍。不能只是 return——那是跳过整段流程，
		# 状态会永远停在 STORY，自检跑不起来。
		_story_open = true
		_story_after = after
		_on_story_finished(true)
		return
	if story_panel == null:
		# 剧情屏建不出来也不能把流程卡死：直接按"已播完"处理
		_story_open = true
		_story_after = after
		_on_story_finished(true)
		return
	_story_after = after
	_story_open = true
	_state = State.STORY
	hud.clear_overlays()
	if touch != null:
		touch.set_active(false)
	_sync_pause()
	var act: Dictionary = Story.act(act_index)
	story_panel.play(act["lines"], Story.title(act_index),
		Story.progress_text(act_index), Story.tint(act_index))


## 终章（王座厅）。和 _play_story 只差"取哪份数据"，
## 但它在流程上是一次性的：播完不再有"下一幕"，只有五位守门人。
func _play_finale(after: String) -> void:
	if not story_enabled:
		_story_open = true
		_story_after = after
		_on_story_finished(true)
		return
	if story_panel == null:
		_story_open = true
		_story_after = after
		_on_story_finished(true)
		return
	_story_after = after
	_story_open = true
	_state = State.STORY
	hud.clear_overlays()
	if touch != null:
		touch.set_active(false)
	_sync_pause()
	story_panel.play(Story.finale_lines(), Story.finale_title(), "十道门 · 走完了",
		Story.finale_tint())


func _on_story_finished(_skipped: bool) -> void:
	if not _story_open:
		return
	_story_open = false
	var after: String = _story_after
	_story_after = ""
	_state = State.PLAYING
	if touch != null:
		touch.set_active(true)
	_sync_pause()
	var act_index: int = mini(_map_index, Story.ACT_COUNT - 1)
	match after:
		"start":
			# 开局那一段：横幅与新手提示都要等剧情播完再出，
			# 否则它们在剧情屏背后放完，玩家一个字都看不到
			_apply_stage_look(Stage.at(_stage_index))
			hud.show_banner(Story.title(0), Story.beat(0), Story.tint(0), false)
			if tutorial != null:
				tutorial.reset_session()
				tutorial.notify("move",
					"WASD / 方向键 移动 · 攻击是自动的，专心走位就行",
					"左侧拖动 移动 · 攻击是自动的，专心走位就行",
					3.2, 1.6)
		"portal":
			hud.show_banner(Story.title(act_index), Story.beat(act_index),
				Story.tint(act_index), false)
		"final":
			hud.show_banner(Story.finale_title(), Story.finale_beat(), Story.finale_tint(), true)
	_update_hud()


## 开局菜单：默认填入上次玩的昵称，并列出本机所有玩家
func _open_menu() -> void:
	_state = State.MENU
	get_tree().paused = true
	RenderingServer.set_default_clear_color(MENU_BG)
	if touch != null:
		touch.set_active(false)
	hud.clear_overlays()
	hud.set_danger(0.0)
	hud.set_hud_visible(false)
	if tutorial != null:
		tutorial.flush()
	start_menu.open(ScoreBoard.last_player(), ScoreBoard.list_players(), _last_hero, _touch_mode)


func _on_menu_started(player_name: String, hero: int) -> void:
	_hero = clampi(hero, 0, HeroClass.COUNT - 1)
	_last_hero = _hero
	_profile = ScoreBoard.load_profile(player_name)
	start_menu.close()
	_begin_run()


## 新一局：清空世界与计数，重新上人。菜单开始与死亡后 R 重开都走这里。
func _begin_run() -> void:
	_clear_world()
	_enemies.clear()
	_gems.clear()
	_items.clear()
	_next_serial = 0
	_breach = 0
	_breach_timer = 0.0
	_gold = 0
	_pending_portal = null
	_cap_timer = 0.0
	if hud != null:
		hud.set_breach(0)
		hud.set_gold(0)

	_elapsed = 0.0
	_death_cause = "敌人"
	_kills = 0
	_elite_kills = 0
	_level = 1
	_xp = 0
	_xp_total = 0
	_xp_need = 6
	_spawn_timer = 0.25
	_pending_cards = 0
	_next_card_level = FIRST_CARD_LEVEL
	_choices.clear()
	_boss = null
	_boss_kills = 0
	_boss_grace = 0.0
	_awaiting_portal = false
	_portals.clear()
	_floor = 0
	_floor_power = 0.0
	_portal_count = 0
	_gate_trail.clear()
	_last_choice = ""
	_ending = ""
	_gauntlet_left = 0
	_gauntlet_total = 0
	_gauntlet_index = 0
	_gauntlet_delay = 0.0
	_victory = false
	_story_open = false
	_story_after = ""
	_stage_index = 0
	_stage_time = 0.0
	_cleared = false
	_card_delay = 0.0

	hud.clear_overlays()
	hud.hide_boss()
	hud.set_hud_visible(true)
	# 火花层在玩家之前加入 World，但 z_index 更高，绘制时仍在所有游戏物体之上
	_sparks = HitSparks.new()
	if _touch_mode:
		_sparks.max_particles = HitSparks.MOBILE_MAX_PARTICLES
	world.add_child(_sparks)
	_spawn_player()
	# 迷宫在玩家之后建，建完把玩家放到起点房间中心。
	# 墙是数据不是物理体，玩家/敌人各自在位移末尾夹紧（见 Player._move / Enemy._move_toward）。
	maze = MazeMap.new()
	maze.name = "MazeMap"
	world.add_child(maze)
	maze.build(randi())
	player.global_position = maze.start_pos()
	player.reset_physics_interpolation()
	player.maze = maze
	maze.rebuild_flow(maze.start_pos())
	_spawn_merchant()
	_map_index = 0
	# 不直接进 PLAYING：先播第一幕。剧情期间整棵树冻结，
	# 横幅与新手提示都在剧情播完之后才出（见 _on_story_finished），
	# 否则它们会在剧情屏背后放完，玩家一个字都看不到。
	_play_story(0, "start")
	_update_hud()


func _clear_world() -> void:
	for child in world.get_children():
		world.remove_child(child)
		child.queue_free()
	player = null
	zone = null


func _spawn_player() -> void:
	player = Player.new()
	# hero 必须在 add_child 之前赋值：Player._ready 里要按职业装配武器
	player.hero = _hero
	player.enemies = _enemies
	world.add_child(player)
	player.health_changed.connect(hud.set_health)
	player.mana_changed.connect(hud.set_mana)
	player.died.connect(_on_player_died)
	player.audio = audio
	# 破甲弹的库存真身在本类；武器拿到的是"还剩几发 / 花掉一发"两个回调。
	# 换武器、换职业都不需要重新接线——回调永远指向这一个计数器。
	player.breach_count = func() -> int: return _breach
	player.breach_take = _consume_breach
	player.mana_changed.connect(_on_mana_changed)
	# 自动攻击的音效只给"低频动作"：近战 1.6 次/秒、回旋镖 1 次/秒左右。
	# 子弹是 5 发/秒，逐发配音会变成一段单调的噪声墙，所以射手不配发射音——
	# 它的反馈来自命中音（hit），那才是玩家真正在意的"打到了没有"。
	if player.melee_weapon != null:
		player.melee_weapon.swung.connect(_play_swing)
	if player.boomerang_weapon != null:
		player.boomerang_weapon.thrown.connect(_play_swing)
	if touch != null:
		touch.set_hero(_hero)
		player.mana_changed.connect(touch.on_mana_changed)
		touch.on_mana_changed(player.mana, player.max_mana)
	hud.set_hero(_hero)
	hud.set_health(player.health, player.max_health)
	hud.set_mana(player.mana, player.max_mana)
	# 出厂值必须在"武器已经按职业装配好、还没有任何卡生效"的这一刻抓
	_capture_stat_bases()


## 蓝满只在"第一次"值得提示：之后玩家已经知道技能键在哪，
## 再提就是噪音。去重由 TutorialHint 内部的 _seen 负责，这里可以放心每帧触发。
func _on_mana_changed(current: float, maximum: float) -> void:
	if tutorial == null or maximum <= 0.0:
		return
	if current >= maximum - 0.01:
		tutorial.notify("skill", "蓝条满了 · 空格 释放技能", "蓝条满了 · 点右下角按钮释放技能", 2.8)


func _play_swing() -> void:
	if audio != null:
		audio.play("shoot")


func _physics_process(delta: float) -> void:
	if _state != State.PLAYING:
		return

	_elapsed += delta
	_tick_maze(delta)
	if _boss_grace > 0.0:
		_boss_grace = maxf(_boss_grace - delta, 0.0)
	if _boss == null or not is_instance_valid(_boss):
		_stage_time += delta
	_card_delay = maxf(_card_delay - delta, 0.0)
	_check_boss()
	if _gauntlet_left > 0:
		_tick_gauntlet(delta)
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = lerpf(SPAWN_INTERVAL_EASY, SPAWN_INTERVAL_HARD, _pressure())
		_spawn_wave()
	_cull_far_enemies()
	_tick_visible_cap(delta)
	_grid_rebuild()
	_apply_separation()
	_cull_far_gems()
	_tick_breach(delta)
	# Boss 血条每帧推：走 HUD 的 10Hz 节流会明显看出条是"一跳一跳"掉下去的。
	# 状态字（攻击中 / 破甲 2.4s）也一起每帧推——窗口只开 3.8 秒，
	# 晚 0.1 秒显示就等于少打一下；HUD 内部对"没变化"的情况是零开销的。
	if _boss != null and is_instance_valid(_boss):
		hud.set_boss_health(_boss.health_ratio())
		hud.set_boss_state(_boss.boss_state_text(), _boss.is_vulnerable())
	# 章节开场发的卡等横幅读完再弹（_advance_stage 会写 _card_delay）
	if _pending_cards > 0 and _card_delay <= 0.0:
		_open_level_up()
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = HUD_INTERVAL
		_update_hud()


## 0 = 刚开局的最轻压力，1 = 压力拉满
func _pressure() -> float:
	return clampf((_elapsed - GRACE_TIME) / RAMP_TIME, 0.0, 1.0)


func _process(_delta: float) -> void:
	# 暂停状态统一在这里对齐：_state 的写点散在开局/选卡/结算/菜单四处，
	# 与其到处埋调用，不如让主循环兜住。内部去重，没变化时只是一次 int 比较。
	_publish_web_state()
	if _state == State.PLAYING:
		queue_redraw()


# ---------------------------------------------------------------- 刷怪

func _spawn_wave() -> void:
	# Boss 刚死的几秒内不刷怪：玩家要捡一地宝石、喝一口血，这时再冒怪等于把奖励吃掉
	if _boss_grace > 0.0:
		return
	# Boss 在场期间**完全停刷**。Boss 战的设计是"读招 + 抓破甲窗口"，
	# 场上再叠一层小怪，玩家就只能在两头之间来回，哪边都做不好——
	# 实测那 7 局的死法全是这样堆出来的。
	# 停刷不会饿死破甲弹：_tick_breach 是独立计时，Boss 在场时直接把弹掉在玩家周围 180 处。
	if _boss != null and is_instance_valid(_boss):
		return
	# 王座厅"只刷新 Boss"：这一段的压力全部来自守门人的招式。
	# 再叠小怪就不是读招，是被推着走——和 Boss 战停刷是同一条理由。
	if _gauntlet_left > 0:
		return
	# 等玩家挑门的这段也不刷：四扇门是"打完收工、慢慢选"的节拍，
	# 脚下还在刷怪，那个节拍就变成了"一边挨打一边选"。
	if _awaiting_portal:
		return
	# 视野内已经到顶就先攒着：屏外预算还有空位也没用，
	# 再多刷只会立刻被 _tick_visible_cap 推回去，白跑一趟随机数。
	if _visible_enemy_count() >= _visible_cap():
		return
	var count: int = 1 + int(_elapsed / WAVE_GROWTH_SECONDS)
	# 新章开场压密度：每波只出 count × 密度，至少 1 只（0 只会让"开局 15 秒没有怪"，
	# 那不是缓冲，是空转）。round 而不是 int：晚期 6 只 × 0.75 该给 4.5 → 5，
	# 直接截断会一直是 4，斜坡的手感会变成阶梯。
	count = maxi(1, int(round(float(count) * _spawn_density())))
	var budget: int = _enemy_budget()
	for i in range(count):
		if _enemies.size() >= budget:
			return
		_spawn_enemy()


## 场上敌人数量的天花板，随存活时间缓慢放开。
## 注意这是**全场**预算（含屏外排队），视野内的上限由 _visible_cap() 单独管：
## 两条分开，屏外才有"下一批"可换，视野内又不会一次涌进来十几只。
func _enemy_budget() -> int:
	var curve: int = BUDGET_BASE + int(_elapsed / BUDGET_STEP)
	# 第三条闸门：全场 = 视野上限 + 少量屏外缓冲。
	# 前两条（时间曲线 / 设备上限）允许屏外堆 60 只，而视野内只放 20 只，
	# 结果是"驱逐"每拍都在跑、边缘的怪反复被弹回去。加上这一条之后，
	# 排队长度和视野容量是同一个量级，怪被推开一次就能安静等下一轮。
	return mini(mini(curve, _max_enemies), _visible_cap() + ENEMY_OVERFLOW_ALLOWANCE)


## 视野内允许的敌人数。Boss 在场时收紧到 10。
func _visible_cap() -> int:
	if _boss != null and is_instance_valid(_boss):
		return BOSS_FIGHT_ENEMY_CAP
	return VISIBLE_ENEMY_CAP


## 视口的半宽/半高（世界坐标）。用矩形而不是圆形：
## 圆形近似等于把四个角也算进"视野"，会让上限虚高 27%，
## 而玩家真正看见的就是这块矩形。
func _view_half() -> Vector2:
	var half: Vector2 = get_viewport_rect().size / (2.0 * Player.CAMERA_ZOOM)
	return Vector2(maxf(half.x, 1.0), maxf(half.y, 1.0))


## 1.06 是边缘余量：刚好压在屏幕边界上的那只已经算"看见了"，
## 判活判死用一个阈值，不然会出现"看着它在屏幕里但计数没涨"。
func _in_view(p: Vector2) -> bool:
	if not is_instance_valid(player):
		return false
	var d: Vector2 = (p - player.global_position).abs()
	var half: Vector2 = _view_half() * 1.06
	return d.x <= half.x and d.y <= half.y


## 视野内非 Boss 敌人数量。Boss 自己不算：它是场地的中心，
## 把它算进去会让"10 只小弟"变成"9 只"，数字对不上玩家的直觉。
func _visible_enemy_count() -> int:
	if not is_instance_valid(player):
		return 0
	var n: int = 0
	for e in _enemies:
		if not is_instance_valid(e) or e.kind == Enemy.Kind.BOSS:
			continue
		if _in_view(e.global_position):
			n += 1
	return n


## 视野超额驱逐。
##
## 为什么是"推回屏外"而不是"删掉"：删掉会让怪在玩家眼前凭空消失，
## 而且不给经验——玩家会觉得"我明明看见一只，怎么没了"。
## 推回屏外只是让它晚几秒再走进来，视觉上完全说得通（它在往这边走）。
## 只推最远的那几只：近身怪突然后跳比消失还假，而近身怪多到超过 20 的情况
## 本身说明玩家已经被围死，那时候该发生的是死亡，不是清场。
func _tick_visible_cap(delta: float) -> void:
	if not is_instance_valid(player):
		return
	_cap_timer -= delta
	if _cap_timer > 0.0:
		return
	_cap_timer = VISIBLE_CAP_TICK
	var cap: int = _visible_cap()
	var inside: Array[Enemy] = []
	for e in _enemies:
		if not is_instance_valid(e) or e.kind == Enemy.Kind.BOSS:
			continue
		if _in_view(e.global_position):
			inside.append(e)
	if inside.size() <= cap:
		return
	inside.sort_custom(_farther_first)
	for i in range(inside.size() - cap):
		_push_out_of_view(inside[i])


## 远的排前面：sort_custom 升序，所以"距离大的先被处理"。
## 写成成员函数而不是 lambda——lambda 里带换行的长表达式在 GDScript 里
## 没有续行符，一行写不下就只能拆，反而更难读。
func _farther_first(a: Enemy, b: Enemy) -> bool:
	# 不写反斜杠续行：GDScript 不支持，写一次语法检查就报一次
	var da: float = a.global_position.distance_squared_to(player.global_position)
	var db: float = b.global_position.distance_squared_to(player.global_position)
	return da > db


## 沿"玩家 → 敌人"的方向把它推到视口外 30%。
## 落点要过一遍可走格：推到墙里会被 constrain 夹回来，等于没推。
## 被夹回视野内时改用随机可走格；随机也找不到（极小地图）就放弃这一次，
## 下一个 tick 再试——宁可短暂超编，也不能把怪瞬移到玩家脸上。
func _push_out_of_view(enemy: Enemy) -> void:
	var dir: Vector2 = enemy.global_position - player.global_position
	if dir.length() < 1.0:
		dir = Vector2.RIGHT
	var half: Vector2 = _view_half()
	var kx: float = half.x * 1.30 / maxf(absf(dir.x), 1.0)
	var ky: float = half.y * 1.30 / maxf(absf(dir.y), 1.0)
	var spot: Vector2 = player.global_position + dir * minf(kx, ky)
	if maze != null:
		spot = maze.nearest_floor_point(spot)
		if _in_view(spot):
			var far: Vector2 = maze.random_spawn_point(player.global_position,
				_view_radius() * 1.4, _view_radius() * 2.2)
			if _in_view(far):
				return
			spot = far
	enemy.global_position = spot
	enemy.reset_physics_interpolation()


## 新章开场的密度系数：前 Stage.INTRO_TIME 秒从 STAGE_INTRO_SPAWN_MIN 线性回到 1。
## 用 _stage_time 而不是 _elapsed——要缓冲的是"刚换章"这个时刻，
## 不是每局的第一个 15 秒（开局本来就慢，压它没有意义）。
## Boss 在场时 _stage_time 是冻住的，所以 Boss 战结束后它从 0 重新走一遍斜坡，
## 正好接上"打完 Boss、技能和弹都空着"的那段。
func _spawn_density() -> float:
	if _stage_time >= Stage.INTRO_TIME:
		return 1.0
	return lerpf(STAGE_INTRO_SPAWN_MIN, 1.0, _stage_time / Stage.INTRO_TIME)


func _spawn_enemy() -> void:
	var big: bool = _elapsed > ELITE_START_TIME and randf() < ELITE_CHANCE
	# 精英固定走普通行为，特殊行为只分给普通怪
	var kind: int = Enemy.Kind.GRUNT if big else _roll_kind()
	# 迷宫里"视野外的环"大概率落在墙里，所以直接让地图挑一个远处的可走格。
	# 无地图时（旧自检直接调 _spawn_enemy）保持原来的环形刷法。
	var at: Vector2 = player.global_position + _spawn_offset(randf() * TAU)
	if maze != null:
		# 距离下限必须压过视野半径：480 在 1280×720 / zoom 1.35 下只有半宽 474，
		# 斜向落点会直接落在矩形视野里，"刷在屏幕内"看起来像凭空冒出来。
		# random_spawn_point 只有 40 次尝试，密集迷宫里可能挑不到，所以试几次取第一个视野外的；
		# 实在挑不到就交给 _tick_visible_cap 下一拍推走，绝不把怪塞到玩家脸上。
		var min_d: float = maxf(_view_radius() * 1.15, 300.0)
		at = maze.random_spawn_point(player.global_position, min_d, 1400.0)
		for i in range(5):
			if not _in_view(at):
				break
			at = maze.random_spawn_point(player.global_position, min_d, 1400.0)
	_create_enemy(kind, big, at)


## 造一只敌人并挂进 world。位置由调用方给：普通刷怪用视野外的环，
## Boss 召唤用 Boss 周围的固定环——后者不该让这里自己去猜。
## 所有来源都在这里统一收进安全区：这是唯一的建怪出入口，只在这里夹一次就够。
## 后期威胁系数：0~THREAT_START 秒恒为 0，之后线性爬满。
## 所有"后期才该出现的压力"都乘这一项，调起点只改一个数，
## 不会出现"速度已经在爬、吐息者还没动"的错位。
func _threat() -> float:
	return clampf((_elapsed - THREAT_START) / THREAT_RAMP, 0.0, 1.0)


## 当前图层（第几张图）的难度乘数。每穿过一道传送门 ×1.10，累乘。
## 单独一个函数而不是散在 _create_enemy 里：吐息伤害、Boss 召唤物、自检脚本
## 都要读同一个数，写两遍迟早对不上。
func _power_scale() -> float:
	return 1.0 + _floor_power


func _create_enemy(kind: int, big: bool, at: Vector2, minion: bool = false) -> void:
	at = _clamp_into_walkable(at)
	var hp: float = ENEMY_HP_BASE + _elapsed * ENEMY_HP_GROWTH + _elapsed * _elapsed * ENEMY_HP_QUADRATIC
	# 章节倍率乘在全局时间曲线之上：全局曲线负责"越拖越硬"，
	# 章节倍率负责"越往下越硬"。两者分开，改一章的难度不会影响另一章。
	hp *= float(Stage.at(_stage_index)["hp_scale"])
	var speed: float = randf_range(ENEMY_SPEED_MIN, ENEMY_SPEED_MAX)
	speed += minf(_elapsed * ENEMY_SPEED_GROWTH, ENEMY_SPEED_CAP) + THREAT_SPEED_BONUS * _threat()
	if big:
		hp *= 2.4
		# 只减速 15%：太慢的话精英会一直落在队伍后面，永远打不到也杀不掉
		speed *= 0.85
	else:
		match kind:
			Enemy.Kind.CHARGER:
				# 冲锋者是"特定快怪"的第一只：平时就比小兵快 18%，冲刺 ×3.6。
				# 旧值 0.92（略慢）让它只有冲刺那一下有存在感，数量减半后它就彻底
				# 变成背景板了——现在它负责把玩家从走廊里撵出去。
				speed *= 1.18
			Enemy.Kind.SPITTER:
				# 贫血 + 慢：让它"好杀但难躲"，玩家正确的应对是优先点掉它。
				# 远程怪不提速：它一旦跟得上近战，就没有任何安全的应对方式了。
				hp *= 0.85
				speed *= 0.8
			Enemy.Kind.BOMBER:
				# 自爆怪提速到 1.22：它要在玩家没反应过来之前贴上来才吓人，
				# 但碰撞无伤 + 有引信，快不等于必中。
				hp *= 0.7
				speed *= 1.22

	# 楼层倍率放在所有身份修正之后：它是对"最终数值"的放大，
	# 不是对基础值的放大——否则精英/自爆怪的相对关系会随层数漂移。
	var power: float = _power_scale()
	hp *= power
	speed *= minf(power, FLOOR_SPEED_CAP)

	var enemy := Enemy.new()
	enemy.spawn_serial = _next_serial
	_next_serial += 1
	enemy.configure(hp, speed, big, kind)
	enemy.minion = minion
	enemy.power_scale = power
	enemy.maze = maze
	enemy.target = player
	enemy.died.connect(_on_enemy_died)
	enemy.hit.connect(_on_enemy_hit)
	enemy.spit.connect(_on_enemy_spit)
	world.add_child(enemy)
	# 物理插值（project.godot 的 physics/common/physics_interpolation）会在
	# "上一个 tick 的变换"和"这一个 tick 的变换"之间补帧。刚出生的节点上一个变换
	# 是默认值（世界原点），不重置的话它会在屏幕上从原点滑到出生点——
	# 实测 240Hz 下要滑 197 像素，也就是每只怪都从地图左上角飞出来。
	# 凡是"设完位置就再也不会连续移动"的节点，设完必须重置一次。
	enemy.global_position = at
	enemy.reset_physics_interpolation()
	_enemies.append(enemy)


# ---------------------------------------------------------------- Boss

## 本章时间走完就放章节 Boss。上一只还没死就不放（章节时钟也停着，见 _physics_process），
## 两只 Boss 同屏会同时放弹幕和冲击波，那是必死而不是难。
## 原来的实现是"90/180/270 秒各一只"，问题是 Boss 和玩家的进度毫无关系：
## 玩家 90 秒时正在被围，Boss 照样插进来；清得再干净也换不来任何节奏变化。
func _check_boss() -> void:
	if not is_instance_valid(player):
		return
	# 王座厅的五位守门人由 _tick_gauntlet 按顺序放，不走"本章时间到"这条线。
	# 不挡的话，王座厅的章节时钟一满就会额外再放一只，变成六位。
	if _gauntlet_left > 0:
		return
	if _boss != null and is_instance_valid(_boss):
		return
	# 门开着的时候不能刷下一只 Boss：这段时间章节时钟仍在走，
	# 不挡的话玩家在门口挑十秒，就会凭空多出一只 Boss 站在门外。
	if _awaiting_portal:
		return
	if _stage_time < float(Stage.at(_stage_index)["length"]):
		return
	_spawn_boss()


func _spawn_boss() -> void:
	var stage: Dictionary = Stage.at(_stage_index)
	# Boss 的生命不再是"随时间的血量公式 × 倍率"，而是 **发数 × 单发固定伤害**。
	# 旧公式让它和小怪一起随 elapsed 膨胀，而玩家武器也在膨胀，两边互相抵消——
	# 结果就是后期站着对拼、谁也不觉得危险（实测 4:44 已经 3585 杀、12 万分）。
	# 改成"发数"之后，Boss 的血条等价于一张弹匣清单：
	# 打得动打不动只取决于捡了几发，和卡片强度彻底解耦。
	var shots: int = int(stage.get("breach_shots", 12))
	var boss_name: String = str(stage["boss"])
	# 横幅只有一行，剧情台词和机制提示都得说，所以用"·"隔开。
	# 机制提示不能删：不知道"它抬手浪就到了"的玩家会白挨一轮。
	var beat: String = Story.boss_line(boss_name)
	var hint: String = Stage.boss_hint(boss_name)
	if not beat.is_empty() and not hint.is_empty():
		beat = "%s　·　%s" % [beat, hint]
	elif beat.is_empty():
		beat = hint
	_create_boss(boss_name, Enemy.BREACH_HIT_DAMAGE * float(shots), "", beat)


## 王座厅的守门人。血量按名次涨（16/24/32/40/48 发，合计 160 发）。
## 名字与台词来自 Story.GAUNTLET：前三位是前面见过的守门人，
## 第四位是王子自己的影子，第五位是城堡本身——"越打越像自己"。
func _spawn_gauntlet_boss() -> void:
	if _gauntlet_index >= _gauntlet_total:
		return
	var info: Dictionary = Story.gauntlet(_gauntlet_index)
	var boss_name: String = str(info["name"])
	var shots: int = GAUNTLET_BASE_SHOTS + GAUNTLET_SHOT_STEP * _gauntlet_index
	var beat: String = str(info["line"])
	var hint: String = Stage.boss_hint(boss_name)
	if not hint.is_empty():
		beat = "%s　·　%s" % [beat, hint]
	_create_boss(boss_name, Enemy.BREACH_HIT_DAMAGE * float(shots),
		"%d/%d" % [_gauntlet_index + 1, _gauntlet_total], beat)
	# 名次在这里推进，而不是在死亡结算里：死亡结算只管"还剩几位"，
	# 两处都改的话，某次异常死亡会让名次跳号。
	_gauntlet_index += 1


## 造一只 Boss 并把它推进场。名字、血、名次、横幅台词是唯一的四个输入：
## 普通关底和王座厅只在这四样上不同，其余（信号接线、入场保护、停刷、压场）
## 必须一模一样。分开写两份的话，迟早出现"王座厅的 Boss 不播受击音"这种漏。
func _create_boss(boss_name: String, hp: float, rank: String, beat: String) -> void:
	var speed: float = (randf_range(ENEMY_SPEED_MIN, ENEMY_SPEED_MAX) \
		+ minf(_elapsed * ENEMY_SPEED_GROWTH, ENEMY_SPEED_CAP) + THREAT_SPEED_BONUS * _threat()) * BOSS_SPEED_SCALE
	# 招式风格跟着名字走，不跟着章号：王座厅会把三只老面孔再放一遍，
	# 玩家记住的是"潮主会拍浪"，而不是"第几幕的 Boss 会什么"。
	var kit: int = Stage.boss_kit(boss_name)
	var boss := Enemy.new()
	boss.spawn_serial = _next_serial
	_next_serial += 1
	boss.configure_boss(hp, speed, boss_name, kit)
	boss.target = player
	# 出场定身：Boss 从视野外走进来的那 1.1 秒不出招，
	# 玩家需要用这一秒确认"它来了、它叫什么、血条在哪"。
	boss.boss_intro_t = Enemy.BOSS_INTRO_TIME
	boss.died.connect(_on_enemy_died)
	boss.hit.connect(_on_enemy_hit)
	boss.boss_summon.connect(_on_boss_summon)
	boss.boss_barrage.connect(_on_boss_barrage)
	boss.boss_phase.connect(_on_boss_phase)
	boss.boss_blink.connect(_on_boss_blink)
	boss.boss_homing.connect(_on_boss_homing)
	boss.boss_strike.connect(_on_boss_strike)
	# 破甲窗口的开/关必须"看得见听得见"：玩家在满屏弹幕里很难只靠血条换色发现
	# "现在能打了"，所以这里再加一道火花 + 一记提示音。
	boss.vulnerable_changed.connect(_on_boss_vulnerable)
	boss.maze = maze
	world.add_child(boss)
	# 出现在普通刷怪环外侧 1.25 倍处：玩家看得见它从远处走进来，而不是凭空贴脸出现。
	boss.global_position = _clamp_into_walkable(player.global_position + _spawn_offset(randf() * TAU) * 1.25)
	boss.reset_physics_interpolation()
	_enemies.append(boss)
	_boss = boss
	# 血条带风格名（潮主 · 潮汐）。王座厅还要带名次：
	# 玩家必须知道"还剩几位"，否则第五位出来时他会以为这是一只无限血的 Boss。
	hud.show_boss(boss_name, Enemy.BOSS_KIT_NAMES[kit], rank)
	if audio != null:
		audio.play("boss_in")
	if tutorial != null:
		# 横幅已经说了"它是谁、它怎么打"，这里只补横幅没说、但必须知道的机制：
		# 壳 + 窗口。不知道"打不动"的玩家会以为游戏卡了；
		# 不知道"只有窗口能打"的玩家会一直贴着它开枪，然后以为弹是坏的。
		tutorial.notify("boss", "它有壳：普通攻击打不进 · 穿甲弹随时能打，还能把它打穿",
			"", 3.8)
	var prefix: String = "关底 · " if rank.is_empty() else "守门人 · "
	hud.show_banner(prefix + boss_name, beat, Story.tint(_map_index), false)
	# 立刻刷一次 HUD：章节条要当场变成"关底"，
	# 等 10Hz 的节流刷新会有最多 0.1 秒的延迟，玩家会先看到 Boss 出场再看到条变红
	_update_hud()
	if is_instance_valid(player):
		player.add_trauma(0.4)
	# 入场这一步是这次改动的关键：只停刷不处理已经站在场上的那 60~100 只，等于没改。
	_thin_for_boss_fight()
	# 刷怪计时也归位。不归位的话，停刷的几十秒里它一路跑负，
	# Boss 一死就是"满编一波 + 一地宝石"同时砸下来。
	_spawn_timer = lerpf(SPAWN_INTERVAL_EASY, SPAWN_INTERVAL_HARD, _pressure())


## 王座厅的出场节奏。上一只还在场就不放下一只——两只同屏会同时放弹幕，
## 那是必死而不是难（和 _check_boss 里"两只 Boss 不共存"是同一条规矩）。
func _tick_gauntlet(delta: float) -> void:
	if _boss != null and is_instance_valid(_boss):
		return
	if _awaiting_portal:
		return
	if _gauntlet_left <= 0:
		return
	_gauntlet_delay = maxf(_gauntlet_delay - delta, 0.0)
	if _gauntlet_delay > 0.0:
		return
	if is_instance_valid(player):
		player.grant_invuln(1.2)
	_spawn_gauntlet_boss()


## Boss 入场时把场上的普通怪压到 BOSS_ARENA_CAP 只。
## 按离玩家由远到近移除：远处消失玩家看不见，近身那几只在眼前凭空蒸发才假。
## 走静默移除而不是 take_damage——不给经验也不计击杀，
## 否则 Boss 入场反倒成了刷经验的机会。
func _thin_for_boss_fight() -> void:
	var crowd: Array[Enemy] = []
	for enemy in _enemies:
		if is_instance_valid(enemy) and enemy.kind != Enemy.Kind.BOSS:
			crowd.append(enemy)
	if crowd.size() <= BOSS_ARENA_CAP:
		return
	var origin: Vector2 = player.global_position if is_instance_valid(player) else Vector2.ZERO
	crowd.sort_custom(func(a, b) -> bool:
		return a.global_position.distance_squared_to(origin) > b.global_position.distance_squared_to(origin)
	)
	for i in range(crowd.size() - BOSS_ARENA_CAP):
		var enemy: Enemy = crowd[i]
		_enemies.erase(enemy)
		enemy.queue_free()


## Boss 一死，它召唤出来的小弟跟着爆。走正常死亡路径：掉经验、计击杀。
## "Boss 倒了但它的兵还围着"在观感上就是这一场没打完，
## 而且 3 秒无敌 + 15% 回血撑得过 8 只残留，撑不过 16~32 只贴身。
func _detonate_minions() -> void:
	var doomed: Array[Enemy] = []
	for enemy in _enemies:
		if is_instance_valid(enemy) and enemy.minion:
			doomed.append(enemy)
	# 先收集再处理：take_damage 会同步触发 _on_enemy_died 从 _enemies 里 erase，
	# 边遍历边删会漏掉后面的元素。
	for enemy in doomed:
		if is_instance_valid(enemy):
			enemy.take_damage(1e9, true)


## Boss 召唤小怪：围着自己一圈生成，强迫玩家在"打 Boss"和"清小怪"之间取舍
func _on_boss_summon(at: Vector2, count: int) -> void:
	# Boss 战的 10 只上限在这里也要挡：召唤发生在 Boss 身边（离玩家 ≤150），
	# 每一只都会当场进视野，不在这里算的话 _tick_visible_cap 会把刚召唤出来的
	# 小弟推回屏外——玩家看到的是"Boss 一挥手，四只怪往外飞"，比不召唤还怪。
	var room: int = _visible_cap() - _visible_enemy_count()
	if room <= 0:
		return
	count = mini(count, room)
	for i in range(count):
		if _enemies.size() >= _max_enemies:
			return
		var angle: float = TAU * float(i) / float(maxi(count, 1))
		_create_enemy(Enemy.Kind.GRUNT, false, at + Vector2(cos(angle), sin(angle)) * 78.0, true)


## Boss 环形弹幕：从半径 60 处起步而不是圆心——圆心起步的话贴脸就是必中，
## 60 的间隙刚好留出"看到环就往外跑"的反应窗口。
func _on_boss_barrage(at: Vector2, count: int) -> void:
	if not is_instance_valid(player):
		return
	var start: float = randf() * TAU
	for i in range(count):
		var angle: float = start + TAU * float(i) / float(maxi(count, 1))
		var dir: Vector2 = Vector2(cos(angle), sin(angle))
		var shot := EnemyShot.new()
		shot.target = player
		shot.maze = maze
		shot.velocity = dir * BOSS_SHOT_SPEED
		shot.damage = BOSS_SHOT_DAMAGE
		# 暗红色弹体：和吐息者的青绿弹区分开，玩家靠颜色就能判断优先级
		shot.color = Color(0.98, 0.46, 0.5)
		world.add_child(shot)
		shot.global_position = at + dir * 60.0
		shot.reset_physics_interpolation()


func _on_boss_phase(phase: int) -> void:
	hud.set_boss_phase(phase)
	if is_instance_valid(player):
		player.add_trauma(0.4)


## 蚀影瞬移：原地和落点各炸一团紫色火花。
## 这一招的危险不在伤害（瞬移本身不伤人），而在"你刚算好的走位作废了"——
## 所以必须让玩家看见"它从哪走、去了哪"，否则只会觉得是瞬移刷脸。
func _on_boss_blink(from: Vector2, to: Vector2) -> void:
	if _sparks != null:
		var tint := Color(0.78, 0.55, 1.0)
		_sparks.burst(from, tint, 14)
		_sparks.burst(to, tint, 20)
	if is_instance_valid(player):
		player.add_trauma(0.25)


## 深潜者追踪弹：扇形铺开而不是三发同向——同向的三发等于一发三倍伤害。
## 初速方向朝玩家，之后靠 EnemyShot 的 homing_turn 慢慢拧过来。
func _on_boss_homing(at: Vector2, count: int) -> void:
	if not is_instance_valid(player):
		return
	var to_player: Vector2 = (player.global_position - at).normalized()
	for i in range(count):
		var spread: float = (float(i) - float(count - 1) * 0.5) * 0.34
		var dir: Vector2 = to_player.rotated(spread)
		var shot := EnemyShot.new()
		shot.target = player
		shot.maze = maze
		shot.velocity = dir * BOSS_HOMING_SPEED
		shot.damage = BOSS_HOMING_DAMAGE
		shot.homing_turn = BOSS_HOMING_TURN
		shot.homing_speed = BOSS_HOMING_SPEED
		# 紫粉色：和弹幕的暗红、吐息者的青绿都不同，一眼能认出"这发会追人"
		shot.color = Color(0.95, 0.52, 0.86)
		world.add_child(shot)
		shot.global_position = at + dir * 48.0
		shot.reset_physics_interpolation()


## 裂地：在 Boss 算好的位置落一处预警圈。落点已经在 Player 附近，
## 所以这里不做夹紧——地裂本来就该跟着人走，夹进安全区反而会让它"追不上"。
func _on_boss_strike(at: Vector2, strike_radius: float) -> void:
	var strike := BossStrike.new()
	strike.target = player
	strike.radius = strike_radius
	strike.damage = BOSS_STRIKE_DAMAGE
	strike.tint = Color(1.0, 0.52, 0.24) if _stage_index % 2 == 0 else Color(1.0, 0.42, 0.46)
	strike.detonated.connect(_on_strike_detonated)
	world.add_child(strike)
	strike.global_position = at
	# 和出生点同一条规则：设完位置立刻重置插值，否则它会从上一次的位置滑过来
	strike.reset_physics_interpolation()


func _on_strike_detonated(at: Vector2, strike_radius: float) -> void:
	if _sparks != null:
		_sparks.burst(at, Color(1.0, 0.62, 0.3), 10)
	if is_instance_valid(player) and player.global_position.distance_to(at) <= strike_radius * 1.6:
		player.add_trauma(0.18)
	if audio != null:
		audio.play("hit", 0.7)


## 窗口开：金色火花 + 一记上行提示音；窗口关：什么都不做。
## 关的时候不出声是刻意的——"打不动了"应该是熄火，而不是又一次报警，
## 否则整场战斗会被提示音填满，真正重要的那一下反而听不出来。
func _on_boss_vulnerable(active: bool) -> void:
	if not active:
		return
	if _sparks != null and _boss != null and is_instance_valid(_boss):
		_sparks.burst(_boss.global_position, Color(1.0, 0.84, 0.36), 22)
	if audio != null:
		audio.play("levelup", 1.25)


func _on_boss_killed(at: Vector2) -> void:
	_boss = null
	if audio != null:
		audio.play("boss_die")
	hud.hide_boss()
	_boss_grace = BOSS_GRACE_TIME
	# 小弟先爆，再回血：这一帧结束时场上只剩 8 只以内的残留
	_detonate_minions()
	if is_instance_valid(player):
		player.heal(player.max_health * BOSS_HEAL_RATIO)
		player.add_trauma(0.6)
		# 无敌从"Boss 倒下的这一帧"开始算。这 3 秒玩家要做的是走过去捡宝石，
		# 而不是一边躲残留一边捡——顺手捡的东西不该用命换。
		player.grant_invuln(BOSS_GRACE_TIME)
	# 王座厅：倒一位放下一场，五位移除完才开城门。
	# 这里不能走"开四扇门"那条路径——王座厅没有下一幕，只有出口。
	if _gauntlet_left > 0:
		_gauntlet_left -= 1
		if _gauntlet_left > 0:
			_gauntlet_delay = GAUNTLET_GAP
			hud.show_banner("守门人倒下", "还站着 %d 位" % _gauntlet_left,
				Story.tint(Story.ACT_COUNT - 1), false)
			_update_hud()
			return
		_open_final_portal(at)
		return
	_open_portals(at)


## 最后一位守门人倒下：只开一扇门，而且不是"选择"，是"出口"。
## 它开在尸体原地——玩家此刻就站在那儿，ARM_TIME 那 1.6 秒是留给他的
## "先捡完这一地的宝石和弹"的时间。
func _open_final_portal(at: Vector2) -> void:
	_awaiting_portal = true
	_spawn_timer = 0.0
	# 十次选择到这里已经全部记完，结局现在就定下来——
	# 不是"踩上门那一刻才抽"，否则门下面的字说不出来，玩家也就看不到
	# "我这一路的选择指向哪个门外"。
	_ending = Story.resolve_ending(_gate_trail, _last_choice)
	var center: Vector2 = at
	if maze != null:
		center = maze.nearest_floor_point(at)
	var portal := Portal.new()
	portal.index = 0
	portal.reward = Portal.Reward.VICTORY
	portal.target = player
	# 门下面写的是"你将走向哪一个门外"，不是固定的"黎明"。
	portal.subtitle = Story.ending_gate(_ending)
	portal.request_enter.connect(_on_portal_requested)
	world.add_child(portal)
	portal.global_position = center
	portal.reset_physics_interpolation()
	_portals.append(portal)
	if audio != null:
		audio.play("clear")
	hud.show_banner("西城门开了", "门外是「%s」——十道门是怎么走的，这里就长什么样"
		% Story.ending_name(_ending), Story.ending_tint(_ending), true)
	_update_hud()


## 走进胜利门：结算、存档、给胜利面板。
## 和死亡结算共用 Score 的同一套算法，只多一项"逃离奖励"——
## 两套公式的话，玩家会算不清"到底哪种结局分高"。
func _on_victory() -> void:
	_victory = true
	_cleared = true
	_state = State.VICTORY
	if audio != null:
		audio.play("clear")
	_sync_pause()
	if touch != null:
		touch.set_active(false)
	hud.close_level_up()
	hud.hide_boss()
	hud.set_danger(0.0)

	var breakdown: Dictionary = Score.compute(_kills, _elite_kills, _elapsed,
		_level, _xp_total, true, true)
	# 结局兜底：正常路径上 _open_final_portal 已经算过了（玩家是从金门走进来的），
	# 但自检会直接调 _on_victory()，那时账本可能是空的——空账本按"黎明"结。
	if _ending.is_empty():
		_ending = Story.resolve_ending(_gate_trail, _last_choice)
	var outcome: Dictionary = ScoreBoard.submit(str(_profile.get("name", ScoreBoard.DEFAULT_NAME)), {
		"score": int(breakdown["total"]),
		"kills": _kills,
		"elite_kills": _elite_kills,
		"level": _level,
		"xp_total": _xp_total,
		"elapsed": _elapsed,
		"stage": _map_index,
		"cleared": true,
		"victory": true,
		"ending": _ending,
	})
	_profile = outcome["profile"]
	hud.set_score(str(_profile["name"]), int(breakdown["total"]), int(_profile["best"]["score"]))

	var result: Dictionary = breakdown.duplicate()
	result["kills"] = _kills
	result["elite_kills"] = _elite_kills
	result["boss_kills"] = _boss_kills
	result["level"] = _level
	result["xp_total"] = _xp_total
	result["time_text"] = _time_text()
	result["score"] = int(breakdown["total"])
	result["profile"] = _profile
	result["is_best"] = outcome["is_best"]
	result["victory_points"] = int(breakdown.get("victory_points", 0))
	result["acts"] = Story.ACT_COUNT
	result["bosses"] = _gauntlet_total
	result["ending"] = _ending
	hud.show_victory(result)


## 进王座厅：换图、锁定"只放守门人"的模式。
## 破甲弹先补 4 发：五位守门人合计要 80 发，掉率再快也需要时间，
## 而从上一场带过来的余弹很可能已经见底——空手进王座厅等于直接判死。
func _enter_final_hall() -> void:
	_gauntlet_total = Story.gauntlet_count()
	_gauntlet_left = _gauntlet_total
	_gauntlet_index = 0
	_gauntlet_delay = BANNER_READ_TIME + 0.8
	_rebuild_map()
	_breach += 4
	if hud != null:
		hud.set_breach(_breach)


## "第 4/10 幕 · 镜厅"。确认面板与暂停面板都用它，
## 拼串只写一处，才不会出现"暂停里写第 4 幕、面板里写第 4 图"。
func _act_text(index: int) -> String:
	return "%s · %s" % [Story.progress_text(index), Story.name_at(index)]


## 四扇门开在 Boss 尸体周围，扇形铺开。
## 位置全部过一遍"吸到最近可走格"：Boss 有可能死在走廊口或墙角，
## 门落进墙里就等于这一局没有出口——这是必须防的死锁，不是美观问题。
## 沿着 8 个方向逐个试，被墙吸回同一点就换下一个方向、再不行就扩半径：
## 只按固定角度放一次的话，Boss 死在窄走廊里四扇门会全部叠在走廊中线上，
## 玩家看到的是"一扇门"。
func _open_portals(at: Vector2) -> void:
	_awaiting_portal = true
	# 停刷期间也不该再累积计时：否则玩家挑门挑了十秒，进门第一帧就是满编一波。
	_spawn_timer = 0.0
	var center: Vector2 = at
	if maze != null:
		center = maze.nearest_floor_point(at)
	var rewards: Array[int] = [
		Portal.Reward.CARD, Portal.Reward.CARD2,
		Portal.Reward.BREACH, Portal.Reward.GOLD,
	]
	var slots: Array[Vector2] = []
	var dir: int = 0
	var radius: float = 130.0
	while slots.size() < rewards.size() and dir < 24:
		var angle: float = TAU * float(dir % 8) / 8.0 + (PI * 0.25) * float(dir / 8)
		var probe: Vector2 = center + Vector2.RIGHT.rotated(angle) * radius
		if maze != null:
			probe = maze.nearest_floor_point(probe)
		var free: bool = true
		for taken in slots:
			if taken.distance_to(probe) < 100.0:
				free = false
				break
		if free:
			slots.append(probe)
		dir += 1
		if dir % 8 == 0:
			radius += 90.0
	# 极端情况下（整张图只有一条 1 格宽走廊）位置凑不够：宁可贴着中心放，
	# 也不能少一扇门——玩家会以为没开门，直接卡死在这一层。
	while slots.size() < rewards.size():
		var fallback: Vector2 = center + Vector2.RIGHT.rotated(
			TAU * float(slots.size()) / float(rewards.size())) * 70.0
		# 兜底位置也要过一遍可走判断：门开在墙里 = 玩家点得到却进不去。
		slots.append(maze.nearest_floor_point(fallback) if maze != null else fallback)

	for i in range(rewards.size()):
		var portal := Portal.new()
		portal.index = i
		portal.reward = rewards[i]
		portal.target = player
		portal.request_enter.connect(_on_portal_requested)
		world.add_child(portal)
		portal.global_position = slots[i]
		portal.reset_physics_interpolation()
		_portals.append(portal)
	# 横幅要说"现在该干什么"。只说"Boss 已击败"等于把玩家扔在原地。
	if audio != null:
		audio.play("clear")
	hud.show_banner("四扇门已开", "奖励越好的门，下一幕越难（+20% ~ +100%）",
		Stage.tint(_stage_index), true)


## 进门：发奖励 → 记一层难度 → 推章节 → 重建地图。
## 顺序不能换：_advance_stage 会改 _stage_index，而 _rebuild_map 之后刷的怪
## 必须吃到新章节的 hp_scale；反过来先重建地图，第一波怪还是旧章的数值。
func _on_portal_requested(portal: Portal) -> void:
	if not _awaiting_portal or _state != State.PLAYING:
		return
	_pending_portal = portal
	_state = State.CONFIRM
	# 提示里给的是"走这扇门之后"的累计数值，不是增量：
	# 玩家真正要判断的是"下一幕有多难"，"+40%" 单独看没有参照。
	var final: bool = portal.reward == Portal.Reward.VICTORY
	var next_power: float = 1.0 + _floor_power + portal.difficulty()
	# 确认面板要把"这一路是怎么走的"摊开：十个选择决定门外是什么，
	# 但玩家在第 9 道门前已经记不清自己前 8 次选了什么。不给他看账本，
	# "选择指向结局"这件事在游玩过程中就是隐形的，只在结算时才揭晓一次。
	var trail: String = Story.trail_text(_gate_trail, _choice_key(portal.reward))
	hud.open_portal_confirm(portal.reward_text(), _act_text(_map_index),
		_act_text(_map_index + 1), int(round((next_power - 1.0) * 100.0)), final,
		trail, Story.ending_name(_ending) if final else "")
	_sync_pause()


func _confirm_portal() -> void:
	var portal: Portal = _pending_portal
	_pending_portal = null
	if portal == null or not is_instance_valid(portal):
		_close_portal_confirm()
		return
	var reward: int = portal.reward
	hud.clear_overlays()
	_state = State.PLAYING
	_awaiting_portal = false
	for p in _portals:
		if is_instance_valid(p) and p != portal:
			p.queue_free()
	_portals.clear()
	portal.consume()
	# 胜利门不是"下一张图"：它直接把这一局结算掉。
	# 奖励和难度都不发——门外没有下一幕可拿。
	if reward == Portal.Reward.VICTORY:
		_on_victory()
		return
	_grant_portal_reward(reward)
	_record_choice(reward)
	_floor_power += portal.difficulty()
	_floor += 1
	_map_index += 1
	_portal_count += 1
	# 第 PORTAL_LIMIT 扇门之后是王座厅。顺序：先推章节（换配色/发卡）、
	# 再建地图、最后播剧情——剧情播完玩家睁眼就在新房间里。
	var final_hall: bool = _portal_count >= PORTAL_LIMIT
	_advance_stage(false)
	if final_hall:
		_enter_final_hall()
	else:
		_rebuild_map()
	# 幕号直接用"第几道门"：第 1 道门之后是第二幕，第 9 道门之后是第十幕，
	# 第 10 道门之后不是第十一幕——是终章。十幕 + 终章 + 10 道门，
	# 三个数字必须能对上，否则玩家会在第 10 幕之后看到"第 11 幕"这种不存在的东西。
	if final_hall:
		_play_finale("final")
	else:
		_play_story(_portal_count, "portal")


func _cancel_portal() -> void:
	_close_portal_confirm()
	if is_instance_valid(_pending_portal):
		_pending_portal.cancel_pending()
	_pending_portal = null


func _close_portal_confirm() -> void:
	hud.clear_overlays()
	_state = State.PLAYING
	_sync_pause()


# ---------------------------------------------------------------- 商人与金币

## 把商人放到本图的密室。位置由 MazeMap 算（离起点第二远的房间），
## Game 只负责建节点——迷宫不该知道"商人"这种玩法概念。
func _spawn_merchant() -> void:
	if maze == null or not is_instance_valid(player):
		return
	var m := Merchant.new()
	m.target = player
	m.request_shop.connect(_on_merchant_request)
	world.add_child(m)
	m.global_position = maze.shop_room_pos()
	m.reset_physics_interpolation()
	_merchant = m
	_shop_stock_reset()


## 货架。每次进新图都重置：商人不是便利店，是"这张图的额外机会"。
## 三个货位对应 Merchant._draw 里画的那三个小方块——视觉和逻辑对上，
## 玩家看到柜台上摆着三样东西，面板里就是三行。
func _shop_stock_reset() -> void:
	_shop_stock.clear()
	_shop_stock.append({
		"id": "heal", "name": "治疗药剂",
		"desc": _shop_heal_text(), "price": _shop_price(SHOP_HEAL_PRICE), "bought": false,
	})
	_shop_stock.append({
		"id": "breach", "name": "破甲弹 ×3",
		"desc": "装填到武器上，普通攻击自动变成穿甲弹", "price": _shop_price(SHOP_BREACH_PRICE), "bought": false,
	})
	_shop_stock.append({
		"id": "card", "name": "战术手册",
		"desc": "立刻拿到一张升级卡", "price": _shop_price(SHOP_CARD_PRICE), "bought": false,
	})


## 价格随层数上涨。四舍五入到整数：面板上写 1634 比 1633.6 更像个价签。
func _shop_price(base: int) -> int:
	return int(round(float(base) * (1.0 + SHOP_PRICE_STEP * float(_floor))))


## 这一关药回多少血：前三关 5% 最大生命，第 4 图起固定 100 点。
## 写成函数而不是常量，是因为它同时被"货架说明"和"买入结算"两处读，
## 分开写迟早出现"面板写 100、实际回 5%"。
func _shop_heal_amount() -> float:
	if _floor < SHOP_HEAL_FLAT_FROM_FLOOR:
		var pool: float = player.max_health if is_instance_valid(player) else 180.0
		return pool * SHOP_HEAL_RATIO_EARLY
	return SHOP_HEAL_FLAT_LATE


func _shop_heal_text() -> String:
	if _floor < SHOP_HEAL_FLAT_FROM_FLOOR:
		return "回复 5%% 最大生命（%d 点）" % roundi(_shop_heal_amount())
	return "回复 %d 点生命" % roundi(_shop_heal_amount())


func _on_merchant_request(merchant: Merchant) -> void:
	if _state != State.PLAYING:
		return
	_merchant = merchant
	_state = State.SHOP
	hud.open_shop(_gold, _shop_stock, Story.merchant_line())
	if audio != null:
		audio.play("ui")
	_sync_pause()


## 买货。校验顺序是 状态 → 索引 → 是否已买 → 钱够不够：
## 钱放最后，因为前三项是"面板状态过期"（比如连点两次），
## 只有钱不够是玩家操作本身的问题，那一种才需要"什么都不发生"地拒绝。
func _on_shop_buy(index: int) -> void:
	if _state != State.SHOP:
		return
	if index < 0 or index >= _shop_stock.size():
		return
	var item: Dictionary = _shop_stock[index]
	if bool(item["bought"]):
		return
	var price: int = int(item["price"])
	if _gold < price:
		return
	_gold -= price
	item["bought"] = true
	_shop_stock[index] = item
	match str(item["id"]):
		"heal":
			if is_instance_valid(player):
				player.heal(_shop_heal_amount())
		"breach":
			_breach += 3
			if hud != null:
				hud.set_breach(_breach)
		"card":
			_pending_cards += 1
	if hud != null:
		hud.set_gold(_gold)
	if audio != null:
		audio.play("pickup")
	# 整块重画：金币数、售罄状态都变了。局部改一个按钮要维护两套状态，
	# 而这张面板每帧的刷新成本是零（它只在暂停时存在）。
	hud.open_shop(_gold, _shop_stock, Story.merchant_line())


func _close_shop() -> void:
	if _state != State.SHOP:
		return
	hud.clear_overlays()
	_state = State.PLAYING
	_sync_pause()
	if is_instance_valid(_merchant):
		_merchant.consume()
	# 买到战术手册时 _pending_cards 会 +1，但那条路径不会经过 _gain_xp，
	# 所以必须在这里补一次开卡——否则卡会一直挂着，直到下一次升级才弹出来。
	if _pending_cards > 0:
		_open_level_up()


## 三选一的兑现。数值都刻意给得"能用一次"而不是"能翻盘"：
## 门是节奏点，不是奖励关卡——真正的成长曲线在卡牌上。
func _grant_portal_reward(reward: int) -> void:
	if not is_instance_valid(player):
		return
	match reward:
		Portal.Reward.BREACH:
			# 直接进账而不是掉在地上：换图会清空 _items，掉地上的会当场消失
			_breach += 3
			if hud != null:
				hud.set_breach(_breach)
		Portal.Reward.GOLD:
			_add_gold(90)
		Portal.Reward.CARD2:
			_pending_cards += 2
		_:
			_pending_cards += 1


## 记一笔"这一道门是怎么选的"。只记账，不发奖励——奖励和账目分开，
## 是因为并不是所有门都给东西（金门什么都不发），但它们都不是"选择"。
func _record_choice(reward: int) -> void:
	var key: String = _choice_key(reward)
	if key.is_empty():
		return
	_gate_trail[key] = int(_gate_trail.get(key, 0)) + 1
	_last_choice = key


## Portal.Reward → Story 记账用的短名。金门返回空串：它不是四个选择之一。
func _choice_key(reward: int) -> String:
	match reward:
		Portal.Reward.CARD:
			return "card"
		Portal.Reward.CARD2:
			return "card2"
		Portal.Reward.BREACH:
			return "breach"
		Portal.Reward.GOLD:
			return "gold"
	return ""


## 换图：清场 + 重铺迷宫 + 把玩家放到新起点。
## 这里不清 _elapsed：它是"这一局活了多久"，跨图必须连续；
## 清掉的话每张图都从头算血量曲线，难度会被反复拉回开局。
func _rebuild_map() -> void:
	for e in _enemies:
		if is_instance_valid(e):
			e.queue_free()
	_enemies.clear()
	for g in _gems:
		if is_instance_valid(g):
			g.queue_free()
	_gems.clear()
	for item in _items:
		if is_instance_valid(item):
			item.queue_free()
	_items.clear()
	# 商人不在上面几张表里，必须点名清：不清的话上一张图的柜台会跟着
	# 新迷宫的坐标系统留在原地，玩家下一局会在墙里看见一个商人
	if is_instance_valid(_merchant):
		_merchant.queue_free()
	_merchant = null
	_boss = null
	_boss_grace = 0.0
	if is_instance_valid(maze):
		# 先摘再 free：同名节点在同一帧里共存会触发 Node 重命名，
		# 而 MazeMap 的 z_index 与绘制顺序都依赖它老老实实叫 MazeMap。
		world.remove_child(maze)
		maze.queue_free()
	maze = MazeMap.new()
	maze.name = "MazeMap"
	world.add_child(maze)
	maze.build(randi())
	if is_instance_valid(player):
		player.global_position = maze.start_pos()
		player.reset_physics_interpolation()
		player.maze = maze
		# 落地保护：新图的怪从零开始刷，但玩家刚在上一张图打完 Boss，
		# 血和弹都不是满的，前 1.5 秒不该被算作"操作失误"。
		player.grant_invuln(1.5)
	maze.rebuild_flow(maze.start_pos())
	_spawn_merchant()
	# 给新图的第一次刷怪留两秒：玩家要看清自己在哪、宝箱（宝石）在哪
	_spawn_timer = 2.0
	_update_hud()


## 关卡推进：击杀章节 Boss 就是"过了一关"。这里是 P2-8 的落点——
## 换配色、弹横幅、发一张卡，玩家能明确感到节奏翻页了，
## 而不是"又打了一只血多的怪"。
func _advance_stage(show_banner: bool = true) -> void:
	_stage_index += 1
	_stage_time = 0.0
	_apply_stage_look(Stage.at(_stage_index))
	_card_delay = BANNER_READ_TIME
	# 界面上的"第几章"现在由剧情决定（Story），Stage 只管敌人构成、Boss 与配色。
	# 老版本在这里判 Stage.is_cleared(index >= 3) 并弹"通关 · 三章走完"——
	# 十幕之后那个判断会在第四幕就触发，把一局游戏提前宣判成通关，已经删掉。
	# 现在的"通关"只有一个来源：王座厅五位守门人全部倒下（见 _on_victory）。
	var act_index: int = mini(_map_index, Story.ACT_COUNT - 1)
	if show_banner:
		hud.show_banner(Story.title(act_index), Story.beat(act_index),
			Story.tint(act_index), false)
	_pending_cards += 1
	_update_hud()


## 章节主题色同时改背景清屏色与网格色。两处都改而不是只改一处：
## 只改清屏色的话，网格线还是原来的白，整片地面看起来像"贴了一层色纸"。
func _apply_stage_look(stage: Dictionary) -> void:
	RenderingServer.set_default_clear_color(stage["bg"])
	var tint: Color = stage["tint"]
	_grid_color = Color(tint.r, tint.g, tint.b, 0.075)
	queue_redraw()


## 按本章的权重表抽样特殊敌人。每章开场 INTRO_TIME 秒内只出普通小兵：
## 新章的第一印象必须是"看得懂的局面"，一进来就被吐息加自爆夹击，
## 玩家只会觉得难度是随机跳的，而不是"这一章更难"。
func _roll_kind() -> int:
	if _stage_time < Stage.INTRO_TIME:
		return Enemy.Kind.GRUNT
	var stage: Dictionary = Stage.at(_stage_index)
	var p_charger: float = float(stage["charger"])
	# 时间威胁曲线压在章节点权重之上：后期同一个章节里吐息者也越来越多。
	# 用 _threat() 而不是自己算一遍，是为了让这条曲线只有一个起点（240 秒）。
	var threat: float = _threat()
	var p_spitter: float = float(stage["spitter"]) + THREAT_SPITTER_BONUS * threat
	var p_bomber: float = float(stage["bomber"])
	# 三者之和就是"这只怪是特殊怪"的总概率，剩下的一律普通小兵。
	# 不能给普通小兵也写一个权重再按总和归一：那样每章加一种特殊怪，
	# 普通小兵的占比就会被稀释，包围感跟着一起变弱。
	# 但特殊怪也不能无限挤：全靠特殊怪时场上就没有"人墙"了，
	# 反而更好清。所以封在 0.7，普通小兵至少留三成。
	var total: float = minf(p_charger + p_spitter + p_bomber, THREAT_SPECIAL_CAP)
	if total <= 0.0:
		return Enemy.Kind.GRUNT
	var roll: float = randf()
	if roll >= total:
		return Enemy.Kind.GRUNT
	if roll < p_charger:
		return Enemy.Kind.CHARGER
	if roll < p_charger + p_spitter:
		return Enemy.Kind.SPITTER
	return Enemy.Kind.BOMBER


## 吐息者开火：方向由敌人算好（含预判），子弹归 Game 生成，敌人不需要知道 world
func _on_enemy_spit(at: Vector2, direction: Vector2) -> void:
	if not is_instance_valid(player):
		return
	var shot := EnemyShot.new()
	shot.target = player
	shot.maze = maze
	shot.velocity = direction * SPIT_SPEED
	shot.damage = SPIT_DAMAGE * _power_scale()
	world.add_child(shot)
	shot.global_position = at
	shot.reset_physics_interpolation()


## 视野外接半径：视口半尺寸 / 相机缩放 得到的半宽半高，取对角线长度。
## 缩圈表用它的倍数写，于是手机（960×540）和桌面（1280×720）看到的是
## "这个圈占几屏"，而不是同一串像素在两种屏幕上差出 33%。
func _view_radius() -> float:
	var half: Vector2 = get_viewport_rect().size / (2.0 * Player.CAMERA_ZOOM)
	return maxf(half.length(), 1.0)


## 迷宫流场每帧刷新。rebuild_flow 内部有「玩家没换格就跳过」的短路，
## 所以每帧调用也只有一次 int 比较；真正重算只发生在跨格时（432 格 BFS）。
## 去毒圈后这里不再有圈外伤害 / 警告音 / 死因改写那一层结算——地图边界由
## MazeMap.constrain 在玩家与敌人各自的位移末尾挡住，不需要每帧轮询。
func _tick_maze(_delta: float) -> void:
	if maze == null or not is_instance_valid(maze):
		return
	if is_instance_valid(player):
		maze.rebuild_flow(player.global_position)


## 刷怪点：视野椭圆的外接环。用视口尺寸 / 相机缩放反推世界可见范围，
## 换分辨率、换宽高比都不会再露边；写死常量做不到这一点。
func _spawn_offset(angle: float) -> Vector2:
	var extent: Vector2 = get_viewport_rect().size / (2.0 * Player.CAMERA_ZOOM) * SPAWN_MARGIN
	var grow: float = 1.0 + randf() * SPAWN_RING_SPREAD
	return Vector2(cos(angle) * extent.x, sin(angle) * extent.y) * grow


## 把任何落点收进迷宫的可走格。去毒圈后不再有"安全区外沿"，
## 敌人 / Boss / 宝石 / 破甲弹四类落点都从这里过一遍：
## 已经在可走格就原样返回，落在墙里就吸到最近的可走格中心——
## 吸到近处而不是随机远处，是为了宝石不会因为掉在墙边就飞到地图另一头。
func _clamp_into_walkable(at: Vector2) -> Vector2:
	if maze == null or not is_instance_valid(maze):
		return at
	if maze.has_floor_at(at):
		return at
	return maze.nearest_floor_point(at)


## 每物理帧重建一次网格。Game 是 World 的父节点，_physics_process 先于敌人执行，
## 所以敌人跑动时读到的永远是本帧的邻居分布。
func _grid_rebuild() -> void:
	_grid.clear()
	for enemy in _enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		_grid.insert(enemy)


## 分离：把每个敌人从重叠的邻居身上推开。没有这一步，所有怪会收敛到玩家同一个坐标，
## 视觉上只有一个红点，玩家也完全看不出自己被围住了。
## 只算出方向（单位向量），加减速由敌人自己决定，避免这里直接改坐标造成抖动。
func _apply_separation() -> void:
	for enemy in _enemies:
		if not is_instance_valid(enemy):
			continue
		enemy.separation = Vector2.ZERO
		# Boss 只把别人推开，自己不被推：它的位置修正量是小怪的 3 倍，
		# 参与修正的话会被一圈小怪持续顶偏，"巨物"的体积感立刻消失。
		if enemy.immovable:
			continue
		_neighbor_buf.clear()
		_grid.query(enemy.global_position, _neighbor_buf)

		var push := Vector2.ZERO
		var deepest: float = 0.0
		var deepest_dir: Vector2 = Vector2.ZERO
		var deepest_hard: bool = false
		var used: int = 0
		for node in _neighbor_buf:
			var mate := node as Enemy
			if mate == null or mate == enemy:
				continue
			if not is_instance_valid(mate) or mate.is_queued_for_deletion():
				continue
			var offset: Vector2 = enemy.global_position - mate.global_position
			var min_dist: float = enemy.radius + mate.radius
			var dist: float = offset.length()
			if dist >= min_dist:
				continue
			var overlap: float
			var normal: Vector2
			if dist < 0.01:
				# 完全重合（同一帧同点生成）时给个随机方向，否则除零后原地不动
				overlap = 1.0
				normal = Vector2.RIGHT.rotated(randf() * TAU)
			else:
				# 越近推得越狠：重叠 100% 时权重 1，刚好贴着时权重 0
				overlap = 1.0 - dist / min_dist
				normal = offset / dist
			push += normal * overlap
			if overlap > deepest:
				deepest = overlap
				deepest_dir = normal
				deepest_hard = mate.immovable
			used += 1
			if used >= MAX_SEPARATION_NEIGHBORS:
				break

		if deepest <= 0.0:
			continue
		enemy.separation = push.normalized()
		# 位置修正：只施加力的话人群中心会一直保持深度穿插（实测残留 60%），
		# 这里按"最深的那一处"直接消掉一部分重叠，几帧内就收敛干净。
		# 只改最深的一处而不是全部相加，避免人群中心被叠加推力弹飞。
		# 对 Boss 这种推不动的目标用满额修正：对方不参与修正，这边再只消 60%
		# 就会留下可见的穿模（实测 -1.9px）。
		var relax: float = 1.0 if deepest_hard else SEPARATION_RELAX
		enemy.global_position += deepest_dir * deepest * relax * enemy.radius


func _cull_far_enemies() -> void:
	var limit: float = DESPAWN_DISTANCE * DESPAWN_DISTANCE
	for i in range(_enemies.size() - 1, -1, -1):
		var enemy: Enemy = _enemies[i]
		if not is_instance_valid(enemy):
			_enemies.remove_at(i)
			continue
		# Boss 不清场：玩家跑得快，一甩就是一千多像素，清了它就等于白刷一只 Boss
		if enemy.kind == Enemy.Kind.BOSS:
			continue
		if enemy.global_position.distance_squared_to(player.global_position) > limit:
			_enemies.remove_at(i)
			enemy.queue_free()


## 一只怪值多少金币。故意做成"数量级"而不是按血量线性：
## 金币的用途只有商人三件货，玩家需要的是"攒两三张图能买一件"的节奏感，
## 而不是一个精确到个位的经济体。精英 8 是普通怪的 4 倍，
## 和它 xp_value 的 3 倍大致同步——"打精英划算"这件事要在所有资源上都成立。
func _coin_reward(enemy: Enemy) -> int:
	var base: int
	if enemy.kind == Enemy.Kind.BOSS:
		base = 120
	elif enemy.tier > 0:
		base = 24
	# 特殊怪（冲锋者 / 吐息者 / 自爆怪）多给一份：它们更难处理，
	# 而"优先点掉吐息者"这件事必须在金币上也划算，否则玩家只会挑软的打。
	elif enemy.kind == Enemy.Kind.GRUNT:
		base = GOLD_BASE_KILL
	else:
		base = GOLD_BASE_KILL + 3
	return maxi(int(round(float(base) * (1.0 + GOLD_FLOOR_STEP * float(_floor)))), 1)


func _add_gold(amount: int) -> void:
	if amount <= 0:
		return
	_gold += amount
	if hud != null:
		hud.set_gold(_gold)


func _on_enemy_died(enemy: Enemy, xp: int) -> void:
	_enemies.erase(enemy)
	_kills += 1
	_add_gold(_coin_reward(enemy))
	# Boss 单独计数：它同时打乱"精英数"和"击杀数"的语义，结算面板要分开显示
	var is_boss: bool = enemy.kind == Enemy.Kind.BOSS
	if is_boss:
		_boss_kills += 1
	elif enemy.tier > 0:
		_elite_kills += 1
	if not is_boss and audio != null:
		audio.play("kill")
	# 普通击杀**不给震动**。单个 0.04 的震动幅度只有 0.06 像素，本来就看不见，
	# 它的作用全部来自累加：后期 13~25 击杀/秒 → 0.5~1.0/s 的持续注入，
	# trauma 稳态被顶到 0.4 左右，屏幕就一直抖。这是"后期很震荡"的直接原因。
	# "战场在动"已经由音效、火花、伤害数字给了，不需要靠震屏表达。
	# 精英击杀保留一记，但降到 0.15（0.25 在 60fps 下已经是 2 像素，偏重）。
	if is_instance_valid(player):
		player.add_trauma(0.15 if enemy.tier > 0 else 0.0)
		# 击杀是回蓝的主要来源，自然回蓝只是保底
		player.add_mana(HeroClass.MANA_PER_KILL[_hero])
	if is_boss:
		# 位置要在这里取：节点已经 queue_free，但同一帧里 transform 还读得到。
		# 四扇门就开在 Boss 倒下的地方，玩家不用回头找。
		_on_boss_killed(enemy.global_position)
		_boss_gem_burst(enemy.global_position, _gem_value(xp))
	else:
		_spawn_gem(enemy.global_position, _gem_value(xp))
		# 破甲弹按"攒够一个间隔就在尸体处掉一枚"兑现。
		# Boss 战期间不在这里掉：那段由 _tick_breach 独占，否则召唤物一多就会
		# 变成"杀小怪刷弹 → 站着输出 Boss"的循环，Boss 战反而比平时轻松。
		if _boss == null:
			var interval: float = _breach_interval()
			if _breach_timer >= interval:
				_breach_timer -= interval
				_spawn_breach(enemy.global_position)
				# 精英额外补一枚：它本来就要多花几秒，回报要能当场看见
				if enemy.tier > 0:
					_spawn_breach(enemy.global_position + Vector2(0.0, 22.0))


## Boss 掉落：原来只给一颗大宝石，捡起来一下就没了。
## 拆成一圈散开的 8 颗，总经验基本不变（8×6 vs 45），
## 但"打完炸出一地经验"是这场战斗胜利的实感——这是唯一一处玩家会主动停下来捡的掉落。
func _boss_gem_burst(at: Vector2, total: int) -> void:
	var each: int = maxi(1, int(round(float(total) / float(BOSS_GEM_COUNT))))
	for i in range(BOSS_GEM_COUNT):
		var angle: float = TAU * float(i) / float(BOSS_GEM_COUNT) + randf() * 0.25
		var point: Vector2 = at + Vector2(cos(angle), sin(angle)) * randf_range(26.0, 56.0)
		_spawn_gem(_clamp_into_walkable(point), each)


## 波次越高每颗宝石越值钱（1 分钟 ×2、2 分钟 ×3、3 分钟以后 ×4）。
## 不这么做的话，敌人越硬、清场越慢，升级进度反而越推不动，玩家会感觉"越玩越沉"。
func _gem_value(base: int) -> int:
	return base * (1 + mini(int(_elapsed / 60.0), 3))


## 受击火花。概率过滤 + 粒子上限双保险：前者的作用是别让画面糊掉，
## 后者的作用是保证再极端的情况也不会因为绘制量爆掉而掉帧。
func _on_enemy_hit(at: Vector2, tint: Color) -> void:
	# 音效放在火花概率判断之前：火花是"给眼睛看的采样"，声音是"给耳朵听的确认"，
	# 两者的密度上限完全不同。被随机数拦掉的那一半命中，玩家一样打中了。
	if audio != null:
		audio.play("hit")
	if _sparks == null or randf() > HIT_SPARK_CHANCE:
		return
	_sparks.burst(at, tint.lightened(0.35), 3)


func _spawn_gem(at: Vector2, value: int) -> void:
	var gem := XpGem.new()
	gem.value = value
	gem.target = player
	gem.collected.connect(_on_gem_collected)
	world.add_child(gem)
	# 宝石统一在这里夹一次：它是"唯一入口"，从敌人死亡点、Boss 爆宝石、
	# 以及将来的宝箱都要走这条路径，散在各处夹迟早漏一个。
	gem.global_position = _clamp_into_walkable(at)
	gem.reset_physics_interpolation()
	_gems.append(gem)


func _on_gem_collected(gem: XpGem, value: int) -> void:
	_gems.erase(gem)
	# Boss 死时会炸出 8 颗，连收 8 声会堆成一片。pickup 的 gap 是 0.04 秒、
	# 带 ±10% 音高抖动，所以听起来是"叮叮叮"的连续上行，正是"捡到一堆"的感觉。
	if audio != null:
		audio.play("pickup")
	if tutorial != null:
		tutorial.notify("pickup", "靠近发光的小点会拾取经验，那是变强的唯一来源", "", 2.8)
	_gain_xp(value)


# ---------------------------------------------------------------- 破甲弹

## 每章"多久掉一枚"从 Stage 读，不在这里写死：三章的难度差异本来就该由章节表表达，
## 写在 Game 里的话，改一章就得回来翻这份代码。
func _breach_interval() -> float:
	if _gauntlet_left > 0:
		return GAUNTLET_BREACH_EVERY
	return float(Stage.at(_stage_index).get("breach_every", 4.5))


## 掉落节奏。计时器一直在走，但"落在哪"分两种情况：
##   Boss 在场 —— 直接掉在玩家周围一圈：弹堆在杀怪点的话，Boss 战里根本绕不过去捡
##   平时     —— 攒着，等下一次击杀掉在尸体处（玩家看得见自己"为什么得到它"）
func _tick_breach(delta: float) -> void:
	_breach_timer += delta
	if _boss == null or not is_instance_valid(_boss):
		return
	if _breach_timer < _breach_interval() * BREACH_BOSS_FIGHT_SCALE:
		return
	_breach_timer = 0.0
	var angle: float = randf() * TAU
	_spawn_breach(_clamp_into_walkable(
		player.global_position + Vector2.RIGHT.rotated(angle) * 180.0))


func _spawn_breach(at: Vector2) -> void:
	var item := ItemModule.new()
	item.target = player
	item.collected.connect(_on_item_collected)
	world.add_child(item)
	item.global_position = _clamp_into_walkable(at)
	item.reset_physics_interpolation()
	_items.append(item)


func _on_item_collected(item: ItemModule) -> void:
	_items.erase(item)
	_breach += 1
	if hud != null:
		hud.set_breach(_breach)
	if audio != null:
		audio.play("pickup")
	if tutorial != null:
		tutorial.notify("breach",
			"破甲弹：会自动装填 · 下一次攻击变成穿甲弹（消耗 1 发）", "", 3.2)


## 武器开火前问一句"还有弹吗"，命中前花掉一发。
## 返回 false 表示弹尽，这一次攻击按普通攻击处理（不扣血、不消耗）。
## 这是整个机制的开关：想改成"破甲持续 N 秒"只需改这一个函数，武器侧不用动。
func _consume_breach() -> bool:
	if _breach <= 0:
		return false
	_breach -= 1
	if hud != null:
		hud.set_breach(_breach)
	return true


func _cull_far_gems() -> void:
	var limit: float = DESPAWN_DISTANCE * DESPAWN_DISTANCE
	for i in range(_gems.size() - 1, -1, -1):
		var gem: XpGem = _gems[i]
		if not is_instance_valid(gem):
			_gems.remove_at(i)
			continue
		if gem.global_position.distance_squared_to(player.global_position) > limit:
			_gems.remove_at(i)
			gem.queue_free()


# ---------------------------------------------------------------- 经验与升级

func _gain_xp(amount: int) -> void:
	_xp += amount
	_xp_total += amount
	while _xp >= _xp_need:
		_xp -= _xp_need
		_level += 1
		_xp_need = int(float(_xp_need) * XP_GROWTH) + 1
		# 这里原来有一口 6% 回血。删掉之后"升级"只给卡，不再兼作续航——
		# 血要回就得脱战、或者去找商人买。升级同时回血会把这两条路一起废掉。
		if _level >= _next_card_level:
			_pending_cards += 1
			_next_card_level = _level + CARD_GAP
	# 章节横幅正在读的时候不弹面板：_physics_process 会在 _card_delay 归零后补开，
	# 否则玩家眼前只有一张卡，不知道自己是"升级了"还是"过关了"。
	if _pending_cards > 0 and _state == State.PLAYING and _card_delay <= 0.0:
		_open_level_up()


func _open_level_up() -> void:
	# 防重入：发卡有三条路径（升级、章节奖励、选完卡后连开），
	# 重复调用会把面板重建一次并重抽三张卡，玩家会看到卡片闪一下换了内容。
	if _state != State.PLAYING:
		return
	_state = State.LEVEL_UP
	# 升级音在暂停之前播：此刻 paused 还没置位，不受暂停分流影响。
	# 万一调用顺序被改动，SPECS 里 levelup 也标了 paused_ok，两条路都能出声。
	if audio != null:
		audio.play("levelup")
	get_tree().paused = true
	# 摇杆的感应区盖着半块屏幕，不收起来会把三张卡的点击全吃掉
	if touch != null:
		touch.set_active(false)
	_update_hud()
	_choices = _pick_choices()
	hud.open_level_up(_level, _choices, _next_card_level)


# ---------------------------------------------------------------- 升级卡

## 只把当前有意义的卡放进池子：某把武器未解锁时先出「解锁」，满了不再出对应成长卡。
func _eligible_cards() -> Array[Dictionary]:
	var orbit_unlocked: bool = player.orbit_weapon.blades > 0
	var boomerang_unlocked: bool = player.boomerang_weapon.count > 0
	# 战士只有近战，远程卡对他来说等于空卡；法师/射手反过来
	var melee: bool = _hero == HeroClass.WARRIOR
	var pool: Array[Dictionary] = []
	for card in CARDS:
		var id: String = card["id"]
		if id.begins_with("melee") and not melee:
			continue
		if id.begins_with("bullet") and melee:
			continue
		if id == "orbit_unlock":
			if not orbit_unlocked:
				pool.append(card)
			continue
		if id == "boomerang_unlock":
			if not boomerang_unlocked:
				pool.append(card)
			continue
		if id.begins_with("orbit") and not orbit_unlocked:
			continue
		if id.begins_with("boomerang") and not boomerang_unlocked:
			continue
		if id == "bullet_proj" and player.bullet_weapon.projectiles_per_shot >= 8:
			continue
		if id == "orbit_count" and player.orbit_weapon.blades >= 8:
			continue
		if id == "boomerang_count" and player.boomerang_weapon.count >= 6:
			continue
		pool.append(card)
	return pool


## 三张里至少一张是"直接抬输出"的卡。没有这条约束时，一局可能连抽三次
## 移动/穿甲/生命这类卡，同等级强度只有另一局的一半——自动跑分实测同策略
## 存活 155s ~ 497s，手感忽难忽易的原因主要在这里，而不是整体数值偏高。
const OUTPUT_IDS: Array[String] = [
	"bullet_damage", "bullet_rate", "bullet_proj", "bullet_pierce",
	"melee_damage", "melee_rate", "melee_reach",
	"orbit_damage", "boomerang_damage",
]


func _pick_choices() -> Array[Dictionary]:
	var pool: Array[Dictionary] = _eligible_cards()
	pool.shuffle()
	var picked: Array[Dictionary] = []
	for i in range(mini(3, pool.size())):
		picked.append(_make_choice(pool[i]))

	# 一张输出卡都没有时，把档位最低的那张换成池子里的随机输出卡。
	# 不能固定换第三张：万一三张里唯一的高档卡正好在第三位，等于用传说换普通。
	if picked.size() == 3 and not _has_output_card(picked):
		var replace_at: int = -1
		var taken: Array[String] = []
		for i in range(picked.size()):
			var id: String = str(picked[i]["id"])
			if id in OUTPUT_IDS:
				continue
			if replace_at < 0 or int(picked[i]["rarity"]) < int(picked[replace_at]["rarity"]):
				replace_at = i
		for i in range(picked.size()):
			if i != replace_at:
				taken.append(str(picked[i]["id"]))
		var subs: Array[Dictionary] = []
		for card in pool:
			if str(card["id"]) in OUTPUT_IDS and not (str(card["id"]) in taken):
				subs.append(card)
		if replace_at >= 0 and not subs.is_empty():
			picked[replace_at] = _make_choice(subs.pick_random())
	return picked


func _has_output_card(picked: Array[Dictionary]) -> bool:
	for card in picked:
		if str(card["id"]) in OUTPUT_IDS:
			return true
	return false


## 把数据表里的一张卡按当前等级抽档、套上倍率，变成界面与结算共用的结构
func _make_choice(card: Dictionary) -> Dictionary:
	var rarity: int = _roll_rarity(card)
	var amount: float = float(card["amount"]) * CardRarity.MULTIPLIERS[rarity]
	return {
		"id": card["id"],
		"icon": card["icon"],
		"name": card["name"],
		"body": _body_text(card, amount),
		"unit": card["unit"],
		"amount": amount,
		"rarity": rarity,
	}


## 解锁卡只是把武器置成 1 把，倍率对它没有任何作用，所以固定按普通出货，
## 不占一次"高品质"的运气，界面上也不会出现"传说·解锁"这种空欢喜。
func _roll_rarity(card: Dictionary) -> int:
	if str(card["unit"]) == "unlock":
		return CardRarity.COMMON
	return CardRarity.roll(_level)


func _body_text(card: Dictionary, amount: float) -> String:
	var unit: String = card["unit"]
	if unit == "unlock":
		return str(card["desc"])
	if unit == "pct":
		return "%s +%d%%" % [card["desc"], int(round(amount * 100.0))]
	return "%s +%d" % [card["desc"], int(round(amount))]


func _choose(index: int) -> void:
	if _state != State.LEVEL_UP:
		return
	if index < 0 or index >= _choices.size():
		return
	if audio != null:
		audio.play("card")
	_apply_upgrade(_choices[index])
	_pending_cards = maxi(_pending_cards - 1, 0)
	hud.close_level_up()
	_state = State.PLAYING
	# 走 _sync_pause 而不是直接 false：竖屏/切后台时开局或选完卡都必须保持冻结
	# （正常点不到按钮，但 bot 与自检会直接调），否则玩家回来已经挨了两秒打
	_sync_pause()
	if touch != null:
		touch.set_active(true)
	_update_hud()
	if _pending_cards > 0:
		_open_level_up()


## 选卡兑现。分两类：
##   - **计数/解锁类**（弹数、穿透、刀刃数、回旋镖数、解锁）：直接改整数，本来就有上限
##   - **数值类**（伤害、射速、射程、移速、生命…）：只累加"原始加成"，再由
##     _recompute_stats() 统一换算成最终值。上限与递减都在 StatCurve 里。
##
## 为什么不再直接乘：乘算是"每张卡都全款"，十几张之后属性会失控；
## 而直接封顶又让前期几张卡白拿。累加 + 饱和曲线是唯一能同时满足两头的写法。
func _apply_upgrade(card: Dictionary) -> void:
	var id: String = str(card["id"])
	var amount: float = float(card["amount"])
	var bullet: BulletWeapon = player.bullet_weapon
	var orbit: OrbitWeapon = player.orbit_weapon
	var boomerang: BoomerangWeapon = player.boomerang_weapon
	match id:
		"bullet_proj":
			# 高档卡一次 +4，不夹一下会越过 8 的上限
			bullet.projectiles_per_shot = mini(bullet.projectiles_per_shot + int(round(amount)), 8)
		"bullet_pierce":
			bullet.pierce += int(round(amount))
		"orbit_unlock":
			orbit.blades = maxi(orbit.blades, 1)
		"orbit_count":
			orbit.blades = mini(orbit.blades + int(round(amount)), 8)
		"boomerang_unlock":
			boomerang.count = maxi(boomerang.count, 1)
		"boomerang_count":
			boomerang.count = mini(boomerang.count + int(round(amount)), 6)
		_:
			_accumulate_stat(id, amount, str(card["unit"]))


## 把一张卡的加成折成"原始比例"记进账本。
## 百分比卡直接加；固定值卡先除以基础值（+18 范围在 60 的基础上就是 +30%），
## 这样两类卡走同一条曲线，不会出现"固定值卡永远封不了顶"。
func _accumulate_stat(id: String, amount: float, unit: String) -> void:
	if not _stat_base.has(id):
		return
	var raw: float = 0.0
	if unit == "pct":
		raw = amount
	else:
		var base: float = float(_stat_base[id])
		if base <= 0.0:
			return
		raw = amount / base
	_stat_raw[id] = float(_stat_raw.get(id, 0.0)) + raw
	_recompute_stats()


## 记住每项属性的"出厂值"。只在开局建好玩家后抓一次：
## 中途再抓的话，已经被卡牌抬高过的值会变成新的基准，上限就形同虚设。
func _capture_stat_bases() -> void:
	_stat_base.clear()
	_stat_raw.clear()
	if not is_instance_valid(player):
		return
	var bullet: BulletWeapon = player.bullet_weapon
	var orbit: OrbitWeapon = player.orbit_weapon
	var boomerang: BoomerangWeapon = player.boomerang_weapon
	var melee: MeleeWeapon = player.melee_weapon
	_stat_base = {
		"bullet_damage": bullet.damage,
		"bullet_rate": bullet.interval,
		"bullet_range": bullet.attack_range,
		"orbit_damage": orbit.damage,
		"orbit_speed": orbit.spin_speed,
		"orbit_radius": orbit.orbit_radius,
		"boomerang_damage": boomerang.damage,
		"boomerang_rate": boomerang.cooldown,
		"boomerang_range": boomerang.fly_distance,
		"melee_damage": melee.damage if melee != null else 0.0,
		"melee_rate": melee.interval if melee != null else 0.0,
		"melee_reach": melee.reach if melee != null else 0.0,
		"move": player.move_speed,
		"hp": player.max_health,
	}


func _stat_mult(id: String) -> float:
	return StatCurve.mult(float(_stat_raw.get(id, 0.0)))


## 从"原始加成"重算所有最终值。幂等：同一份账本算多少遍结果都一样，
## 所以选卡、开新局、自检里直接调都不会出问题。
func _recompute_stats() -> void:
	if not is_instance_valid(player) or _stat_base.is_empty():
		return
	var bullet: BulletWeapon = player.bullet_weapon
	var orbit: OrbitWeapon = player.orbit_weapon
	var boomerang: BoomerangWeapon = player.boomerang_weapon
	var melee: MeleeWeapon = player.melee_weapon
	bullet.damage = float(_stat_base["bullet_damage"]) * _stat_mult("bullet_damage")
	# 射速存的是"间隔"，所以倍率要取倒数；0.08 兜底防手滑叠到除零附近
	bullet.interval = maxf(float(_stat_base["bullet_rate"]) / _stat_mult("bullet_rate"), 0.08)
	bullet.attack_range = float(_stat_base["bullet_range"]) * _stat_mult("bullet_range")
	orbit.damage = float(_stat_base["orbit_damage"]) * _stat_mult("orbit_damage")
	orbit.spin_speed = float(_stat_base["orbit_speed"]) * _stat_mult("orbit_speed")
	orbit.orbit_radius = float(_stat_base["orbit_radius"]) * _stat_mult("orbit_radius")
	boomerang.damage = float(_stat_base["boomerang_damage"]) * _stat_mult("boomerang_damage")
	boomerang.cooldown = maxf(float(_stat_base["boomerang_rate"]) / _stat_mult("boomerang_rate"), 0.42)
	boomerang.fly_distance = float(_stat_base["boomerang_range"]) * _stat_mult("boomerang_range")
	if melee != null:
		melee.damage = float(_stat_base["melee_damage"]) * _stat_mult("melee_damage")
		melee.interval = maxf(float(_stat_base["melee_rate"]) / _stat_mult("melee_rate"), 0.12)
		melee.reach = float(_stat_base["melee_reach"]) * _stat_mult("melee_reach")
	player.move_speed = float(_stat_base["move"]) * _stat_mult("move")
	# 生命上限：增长量当场补成血。不补的话"买了上限"反而让血条百分比瞬间变难看，
	# 玩家会觉得这张卡在坑他。
	var new_max: float = float(_stat_base["hp"]) * _stat_mult("hp")
	var gain: float = new_max - player.max_health
	player.max_health = new_max
	if gain > 0.0:
		player.heal(gain)
	else:
		player.health = minf(player.health, player.max_health)


# ---------------------------------------------------------------- 结束与输入

## 触摸技能键。真正的判定（蓝够不够、是否已死）都在 Player.try_use_skill() 里，
## 这里只补一记轻震：手机上没有键盘反馈，点下去必须"有手感"。
func _on_skill_button() -> void:
	if _state != State.PLAYING or not is_instance_valid(player):
		return
	if player.try_use_skill():
		player.add_trauma(0.2)
		if audio != null:
			audio.play("skill")


func _on_player_died() -> void:
	_state = State.GAME_OVER
	# dead 在 paused 之前播；SPECS 里也标了 paused_ok，因为死亡的同一帧里
	# _on_player_died 是先设 state 后暂停，顺序一变这里就会哑掉。
	if audio != null:
		audio.play("dead")
	if tutorial != null:
		tutorial.flush()
	get_tree().paused = true
	player.visible = false
	if touch != null:
		touch.set_active(false)
	hud.close_level_up()
	hud.hide_boss()
	# 结算界面背后不该一直闪红光：死亡后红边退掉，交给压暗遮罩做视觉切换
	hud.set_danger(0.0)

	var breakdown: Dictionary = Score.compute(_kills, _elite_kills, _elapsed, _level, _xp_total, _cleared)
	var outcome: Dictionary = ScoreBoard.submit(str(_profile.get("name", ScoreBoard.DEFAULT_NAME)), {
		"score": breakdown["total"],
		"kills": _kills,
		"elite_kills": _elite_kills,
		"level": _level,
		"xp_total": _xp_total,
		"elapsed": _elapsed,
		"stage": _stage_index,
		"cleared": _cleared,
	})
	_profile = outcome["profile"]
	hud.set_score(str(_profile["name"]), int(breakdown["total"]), int(_profile["best"]["score"]))

	var result: Dictionary = breakdown.duplicate()
	result["kills"] = _kills
	result["elite_kills"] = _elite_kills
	result["boss_kills"] = _boss_kills
	result["level"] = _level
	result["xp_total"] = _xp_total
	result["time_text"] = _time_text()
	result["score"] = breakdown["total"]
	result["profile"] = _profile
	result["is_best"] = outcome["is_best"]
	# 关卡进度：结算面板要能回答"我这局走到哪了"，只给一个存活秒数是不够的。
	# 给的是幕号与幕名：十幕的一局里，"第 7 幕"才是玩家记得住的坐标。
	result["act_index"] = mini(_map_index, Story.ACT_COUNT - 1)
	result["act_name"] = Story.name_at(_map_index)
	result["stage_index"] = _stage_index
	result["stage_name"] = Stage.title(_stage_index)
	result["cleared"] = _cleared
	result["death_cause"] = _death_cause
	hud.show_game_over(result)


func _input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return

	# 静音是唯一一个"战斗中也可能马上要用"的开关：外放玩到一半需要安静，
		# 不该逼玩家先死一次回菜单。放在 match 之前，任何状态都响应。
	if key_event.keycode == KEY_M and audio != null:
		audio.toggle_muted()
		return

	match _state:
		State.PLAYING:
			if key_event.is_action_pressed("cast_skill") and is_instance_valid(player):
				player.try_use_skill()
			elif key_event.keycode == KEY_P or key_event.keycode == KEY_ESCAPE:
				_on_pause_toggled()
		State.PAUSED:
			# 暂停时同一个键就是"继续"。不额外接受 R：键盘玩家在暂停面板里按 R，
			# 十次里有九次是手滑，而"重新开始"在面板上是一颗要看清才敢点的按钮。
			if key_event.keycode == KEY_P or key_event.keycode == KEY_ESCAPE:
				_on_pause_toggled()
		State.CONFIRM:
			# 确认门：默认不传，ESC 等于"再想想"。错传的代价是一整张图，
			# 所以这里没有"回车确认"这种一按就走的路径。
			if key_event.keycode == KEY_ESCAPE or key_event.keycode == KEY_P:
				_cancel_portal()
		State.SHOP:
			if key_event.keycode == KEY_ESCAPE or key_event.keycode == KEY_P:
				_close_shop()
		State.LEVEL_UP:
			if key_event.keycode >= KEY_1 and key_event.keycode <= KEY_9:
				_choose(key_event.keycode - KEY_1)
		State.GAME_OVER:
			if key_event.keycode == KEY_R:
				_restart()
			elif key_event.keycode == KEY_P or key_event.keycode == KEY_ESCAPE:
				_open_menu()
		State.STORY:
			# 空格 / 回车 继续；ESC / P 直接跳过（和右上角那颗按钮完全等价）。
			# 两条路径都要有：键盘玩家会本能地按 ESC，而手机上只有那颗按钮。
			if key_event.is_action_pressed("cast_skill") or key_event.keycode == KEY_ENTER:
				if story_panel != null:
					story_panel.advance()
			elif key_event.keycode == KEY_ESCAPE or key_event.keycode == KEY_P:
				if story_panel != null:
					story_panel.skip()
		State.VICTORY:
			if key_event.keycode == KEY_R:
				_restart()
			elif key_event.keycode == KEY_P or key_event.keycode == KEY_ESCAPE:
				_open_menu()


## 战斗中暂停 / 继续。只允许 PLAYING ↔ PAUSED 这一条边：
## 选卡（LEVEL_UP）本身就已经冻结了整棵树，再按暂停会变成"面板叠面板"；
## 结算与菜单里也不该出现"继续"——那里按继续没有任何东西可恢复。
## 真正的冻结仍然由 _sync_pause() 统一裁决，这里只负责换状态。
func _on_pause_toggled() -> void:
	if _state == State.PLAYING:
		_state = State.PAUSED
		# 摇杆跟着收起：暂停时背后还露着两个圆圈，既挡面板又让玩家以为还能推。
		# 顺带把 InputMap 里的方向动作清掉——手指压在摇杆上按暂停，不会在恢复瞬间窜出去。
		if touch != null:
			touch.set_active(false)
		# 副标题带上进度：暂停是玩家唯一会"回头看一眼自己打到哪了"的时刻
		hud.show_pause(true, "%s　·　Lv.%d　·　击杀 %d" % [_map_text(), _level, _kills])
		_sync_pause()
	elif _state == State.PAUSED:
		_state = State.PLAYING
		hud.show_pause(false)
		if touch != null:
			touch.set_active(true)
		_sync_pause()


## 同一个人再来一局：不重载场景，昵称与个人最高分都保留
func _restart() -> void:
	if _profile.is_empty():
		_open_menu()
		return
	_begin_run()


func _time_text() -> String:
	return "%02d:%02d" % [int(_elapsed) / 60, int(_elapsed) % 60]


func _mmss(seconds: float) -> String:
	var whole: int = maxi(int(ceil(seconds)), 0)
	return "%02d:%02d" % [whole / 60, whole % 60]


## 地图状态行。去毒圈后没有倒计时可报，改为「第几张图 + 本图用时」。
## P2 的完成度提示会接着往这行里加字，箭头复用 ZoneArrow（传零向量时自动隐藏）。
func _map_text() -> String:
	# 难度百分比直接写出来：+10% 的递增如果只藏在数值里，玩家永远感受不到"我在变强/敌人在变强"，
	# 只会觉得"后面莫名其妙打不动了"。这个数字就是这条机制的可见面。
	if _gauntlet_total > 0:
		return "%s · %s" % [Story.finale_title(), _time_text()]
	if _floor <= 0:
		return "%s · 探索 %s" % [Story.progress_text(_map_index), _time_text()]
	return "%s · 敌 +%d%% · %s" % [
		Story.progress_text(_map_index), int(round((_power_scale() - 1.0) * 100.0)), _time_text()]


## HUD 状态行（血条下面那一行）。**不带幕号**：上一行 set_stage 已经写了
## 「第 N/10 幕 · 幕名」，这里再写一次，两行都以"第 1/10 幕"开头——
## 桌面 1280 宽只是重复，844x390 的手机上两行挤在一起像串行。
## 手机截图（.workbuddy/web_m_4_battle.png）里量出来的，不是推测。
func _status_text() -> String:
	if _gauntlet_total > 0:
		# 王座厅没有难度增益可报，改成"还站着几位"——这里玩家的唯一问题是还要打几个
		if _gauntlet_left > 0:
			return "还站着 %d 位 · %s" % [_gauntlet_left, _time_text()]
		return "城门已开 · %s" % _time_text()
	if _floor <= 0:
		return "探索 " + _time_text()
	# 难度百分比直接写出来：只藏在数值里的话，玩家只会觉得"后面莫名其妙打不动了"。
	return "敌 +%d%% · %s" % [int(round((_power_scale() - 1.0) * 100.0)), _time_text()]


## 离玩家最近的一扇门的位移。没有门时返回零向量（箭头会自动隐藏）。
func _nearest_portal_offset() -> Vector2:
	if not is_instance_valid(player):
		return Vector2.ZERO
	var best: Vector2 = Vector2.ZERO
	var best_dist: float = 99999.0
	for p in _portals:
		if not is_instance_valid(p):
			continue
		var delta: Vector2 = p.global_position - player.global_position
		if delta.length() < best_dist:
			best_dist = delta.length()
			best = delta
	return best


func _update_hud() -> void:
	hud.set_progress(float(_xp), float(_xp_need))
	var stage: Dictionary = Stage.at(_stage_index)
	var boss_alive: bool = _boss != null and is_instance_valid(_boss)
	var progress: float = clampf(_stage_time / maxf(float(stage["length"]), 1.0), 0.0, 1.0)
	if _awaiting_portal:
		# 挑门期间进度条钉在满格：章节其实已经在 100%，只是还没翻页。
		# 让它继续涨会把 1.0 之后的部分截掉，看起来像"卡住了"。
		progress = 1.0
	# 界面上的幕名来自 Story，章节数据（敌人构成 / 长度 / Boss）来自 Stage。
	# 两者分开：剧情可以改名字，但改名字不该影响刷什么怪。
	if _gauntlet_left > 0 or _gauntlet_total > 0:
		# 王座厅不是"第 11 幕"：十幕走完之后它是终章，幕号到此为止。
		hud.set_stage(Story.finale_title(), 1.0, boss_alive, Story.finale_tint())
	else:
		var act_index: int = mini(_map_index, Story.ACT_COUNT - 1)
		hud.set_stage(_act_text(act_index), progress, boss_alive, Story.tint(act_index))
	# 时间放进来是为了让老玩家还能对表：章节推进多少秒是可变节奏，
	# 但"我这局撑了多久"仍然是排行榜和手感的共同基准。
	# 玩家行不再带"时间"：上面状态行的"探索 00:07"和它是同一个 _elapsed，
	# 手机截图里两行都顶着 00:07——同一个数写两遍，白占一行宽度。
	hud.set_stats("%s  Lv.%d    击杀 %d" % [HeroClass.NAMES[_hero], _level, _kills])
	hud.set_next_upgrade(_next_card_level)
	hud.set_danger(_danger_level())
	hud.set_zone_status(_status_text(), false)
	# 箭头复用：挑门时指向最近的门。门开在 Boss 尸体周围，玩家常常被击退到
	# 走廊另一头，没有指向的话"四扇门已开"就只是一句横幅。其余时候零向量自动隐藏。
	if _awaiting_portal:
		hud.set_zone_direction(_nearest_portal_offset() * Player.CAMERA_ZOOM, false)
	else:
		hud.set_zone_direction(Vector2.ZERO, false)
	var best_score: int = 0
	if _profile.has("best"):
		best_score = int(_profile["best"].get("score", 0))
	hud.set_score(str(_profile.get("name", "")), _current_score(), best_score)


## 血量越低红边越强。线性映射而不是台阶：玩家能从红边变浓的速率上
## 预判"再挨一下会不会死"，这比只在某个阈值突然亮起来有用。
## Boss 战期间给一个很低的底噪（0.18），让整场战斗有压力感，但不至于被误读成"血快没了"。
func _danger_level() -> float:
	if not is_instance_valid(player) or player.max_health <= 0.0:
		return 0.0
	var ratio: float = player.health / player.max_health
	var level: float = clampf((DANGER_HEALTH - ratio) / DANGER_HEALTH, 0.0, 1.0)
	if _boss != null and is_instance_valid(_boss):
		return maxf(level, BOSS_DANGER_FLOOR)
	return level


## 实时分数：与结算用同一套公式，保证界面上的数字和最终得分一致
func _current_score() -> int:
	return Score.total(_kills, _elite_kills, _elapsed, _level, _xp_total, _cleared)


# ---------------------------------------------------------------- 背景网格

func _draw() -> void:
	if player == null:
		return
	const GRID: float = 90.0
	const EXTENT: float = 900.0
	var base: Vector2 = (player.global_position / GRID).floor() * GRID
	var start: Vector2 = base - Vector2(EXTENT, EXTENT)
	var color: Color = _grid_color
	var steps: int = int(EXTENT * 2.0 / GRID) + 1
	for i in range(steps):
		var x: float = start.x + float(i) * GRID
		draw_line(Vector2(x, start.y), Vector2(x, start.y + EXTENT * 2.0), color, 1.0)
		var y: float = start.y + float(i) * GRID
		draw_line(Vector2(start.x, y), Vector2(start.x + EXTENT * 2.0, y), color, 1.0)


