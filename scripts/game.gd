extends Node2D

## 游戏总控：刷怪、经验与升级规则、暂停与重开。界面全部交给 GameHud。
## 该节点 process_mode = ALWAYS，因此升级/死亡暂停时仍能接收输入。

enum State { MENU, PLAYING, LEVEL_UP, GAME_OVER }

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
const MAX_ENEMIES: int = 420
## 触屏设备的敌人上限。手机上是单线程 WebGL（没有 SharedArrayBuffer），
## 420 只时自绘指令 + 每帧分离计算会把帧率压到 30 以下；
## 210 只的围困观感几乎一样，但绘制与查询开销正好减半。
const MOBILE_MAX_ENEMIES: int = 210

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

## 刷怪间隔：0 = 最轻，1 = 最密
const SPAWN_INTERVAL_EASY: float = 0.7
const SPAWN_INTERVAL_HARD: float = 0.28
## 每过这么多秒，每波多刷一只
const WAVE_GROWTH_SECONDS: float = 35.0
## 场上同时存在的敌人上限 = BUDGET_BASE + 存活秒数 / BUDGET_STEP。
## 没有这道闸门时，刷怪速度（每秒数只）远超单目标清怪速度，屏外会堆到几百只。
const BUDGET_BASE: int = 12
const BUDGET_STEP: float = 4.0
const ENEMY_HP_BASE: float = 8.0
## 敌人血量 = BASE + 线性项 + 二次项。纯线性追不上后期的卡牌成长：
## 实测 300 秒时玩家 19 张卡、血量还剩 161/274，等于后期没有威胁。
## 二次项只在 150 秒后明显起作用（100 秒时只多 5 点血），不会反过来压死前中期。
const ENEMY_HP_GROWTH: float = 0.16
const ENEMY_HP_QUADRATIC: float = 0.0005
const ENEMY_SPEED_MIN: float = 62.0
const ENEMY_SPEED_MAX: float = 94.0
const ENEMY_SPEED_GROWTH: float = 0.35
const ENEMY_SPEED_CAP: float = 46.0
const ELITE_START_TIME: float = 45.0
const ELITE_CHANCE: float = 0.12

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
const BOSS_HOMING_DAMAGE: float = 11.0
## 击杀掉落：把原来的一颗大宝石拆成一圈小宝石。
## 总经验基本不变（8 颗 × 6 = 48 vs 45），但"打完炸出一地经验"是胜利的实感。
const BOSS_GEM_COUNT: int = 8
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
## 每次升级回复的生命比例。没有这个，伤害就是"不可逆"的：血只会一路掉到 0，
## 走位再好也只是把死亡时间往后推——试玩反馈里"下一级血不够"说的正是这件事。
const LEVEL_HEAL_RATIO: float = 0.06

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
var _gems: Array[XpGem] = []
## 当前在场的 Boss（null 表示没有 Boss 战）。HUD 血条与危险底噪都读它
var _boss: Enemy = null
var _boss_kills: int = 0
## Boss 死后的免刷怪窗口
var _boss_grace: float = 0.0
## 当前章节序号（0 起）与本章已进行的秒数。章节时钟只在本章没有 Boss 时走，
## 这样"打了 30 秒 Boss"不会把下一章的开场时间吃掉。
var _stage_index: int = 0
var _stage_time: float = 0.0
## 是否已经走完三章。通关后继续无尽循环，所以它是"达成过"而不是"结束了"
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
	_build_hud()
	_build_touch()
	_build_menu()
	_open_menu()


## 只在触屏设备上调用。content_scale_size 就是"逻辑分辨率"，
## 与 project.godot 里的 viewport_width/height 是同一个东西，可以运行时改。
func _apply_mobile_viewport() -> void:
	var window: Window = get_window()
	if window != null:
		window.content_scale_size = MOBILE_VIEWPORT


func _build_hud() -> void:
	hud = GameHud.new()
	add_child(hud)
	hud.card_chosen.connect(_choose)
	hud.set_touch_mode(_touch_mode)
	# 手机上按不到 R / P，结算面板给两个按钮；键盘路径同时保留
	hud.restart_requested.connect(_restart)
	hud.menu_requested.connect(_open_menu)


func _build_touch() -> void:
	touch = TouchControls.new()
	add_child(touch)
	touch.skill_pressed.connect(_on_skill_button)


func _build_menu() -> void:
	start_menu = StartMenu.new()
	add_child(start_menu)
	start_menu.started.connect(_on_menu_started)


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
	# 缩圈在玩家之后建：它要读 _view_radius()，也就是当前视口与相机缩放，
	# 而那两样都在 _spawn_player 里落定（触屏设备还会改 content_scale_size）。
	zone = Zone.new()
	zone.name = "Zone"
	world.add_child(zone)
	zone.reset(_view_radius(), randi())
	_zone_dmg_timer = 0.0
	_state = State.PLAYING
	get_tree().paused = false
	if touch != null:
		touch.set_active(true)
	# 开局就把第一章的名字打出来：玩家进游戏三秒内必须知道"我在哪、要干什么"
	_apply_stage_look(Stage.at(_stage_index))
	hud.show_banner(Stage.title(_stage_index), str(Stage.at(_stage_index)["subtitle"]), Stage.tint(_stage_index), false)
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
	if touch != null:
		touch.set_hero(_hero)
		player.mana_changed.connect(touch.on_mana_changed)
		touch.on_mana_changed(player.mana, player.max_mana)
	hud.set_hero(_hero)
	hud.set_health(player.health, player.max_health)
	hud.set_mana(player.mana, player.max_mana)


func _physics_process(delta: float) -> void:
	if _state != State.PLAYING:
		return

	_elapsed += delta
	_tick_zone(delta)
	if _boss_grace > 0.0:
		_boss_grace = maxf(_boss_grace - delta, 0.0)
	if _boss == null or not is_instance_valid(_boss):
		_stage_time += delta
	_card_delay = maxf(_card_delay - delta, 0.0)
	_check_boss()
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = lerpf(SPAWN_INTERVAL_EASY, SPAWN_INTERVAL_HARD, _pressure())
		_spawn_wave()
	_cull_far_enemies()
	_grid_rebuild()
	_apply_separation()
	_cull_far_gems()
	# Boss 血条每帧推：走 HUD 的 10Hz 节流会明显看出条是"一跳一跳"掉下去的
	if _boss != null and is_instance_valid(_boss):
		hud.set_boss_health(_boss.health_ratio())
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
	if _state == State.PLAYING:
		queue_redraw()


# ---------------------------------------------------------------- 刷怪

func _spawn_wave() -> void:
	# Boss 刚死的几秒内不刷怪：玩家要捡一地宝石、喝一口血，这时再冒怪等于把奖励吃掉
	if _boss_grace > 0.0:
		return
	var count: int = 1 + int(_elapsed / WAVE_GROWTH_SECONDS)
	var budget: int = _enemy_budget()
	for i in range(count):
		if _enemies.size() >= budget:
			return
		_spawn_enemy()


## 场上敌人数量的天花板，随存活时间缓慢放开
func _enemy_budget() -> int:
	return mini(BUDGET_BASE + int(_elapsed / BUDGET_STEP), _max_enemies)


func _spawn_enemy() -> void:
	var big: bool = _elapsed > ELITE_START_TIME and randf() < ELITE_CHANCE
	# 精英固定走普通行为，特殊行为只分给普通怪
	var kind: int = Enemy.Kind.GRUNT if big else _roll_kind()
	_create_enemy(kind, big, player.global_position + _spawn_offset(randf() * TAU))


## 造一只敌人并挂进 world。位置由调用方给：普通刷怪用视野外的环，
## Boss 召唤用 Boss 周围的固定环——后者不该让这里自己去猜。
## 所有来源都在这里统一收进安全区：这是唯一的建怪出入口，只在这里夹一次就够。
func _create_enemy(kind: int, big: bool, at: Vector2) -> void:
	at = _clamp_point_into_zone(at)
	var hp: float = ENEMY_HP_BASE + _elapsed * ENEMY_HP_GROWTH + _elapsed * _elapsed * ENEMY_HP_QUADRATIC
	# 章节倍率乘在全局时间曲线之上：全局曲线负责"越拖越硬"，
	# 章节倍率负责"越往下越硬"。两者分开，改一章的难度不会影响另一章。
	hp *= float(Stage.at(_stage_index)["hp_scale"])
	var speed: float = randf_range(ENEMY_SPEED_MIN, ENEMY_SPEED_MAX) + minf(_elapsed * ENEMY_SPEED_GROWTH, ENEMY_SPEED_CAP)
	if big:
		hp *= 2.4
		# 只减速 15%：太慢的话精英会一直落在队伍后面，永远打不到也杀不掉
		speed *= 0.85
	else:
		match kind:
			Enemy.Kind.CHARGER:
				# 平时略慢，威胁全在冲刺那一下
				speed *= 0.92
			Enemy.Kind.SPITTER:
				# 贫血 + 慢：让它"好杀但难躲"，玩家正确的应对是优先点掉它
				hp *= 0.85
				speed *= 0.8
			Enemy.Kind.BOMBER:
				hp *= 0.7
				speed *= 1.06

	var enemy := Enemy.new()
	enemy.configure(hp, speed, big, kind)
	enemy.target = player
	enemy.died.connect(_on_enemy_died)
	enemy.hit.connect(_on_enemy_hit)
	enemy.spit.connect(_on_enemy_spit)
	world.add_child(enemy)
	enemy.global_position = at
	_enemies.append(enemy)


# ---------------------------------------------------------------- Boss

## 本章时间走完就放章节 Boss。上一只还没死就不放（章节时钟也停着，见 _physics_process），
## 两只 Boss 同屏会同时放弹幕和冲击波，那是必死而不是难。
## 原来的实现是"90/180/270 秒各一只"，问题是 Boss 和玩家的进度毫无关系：
## 玩家 90 秒时正在被围，Boss 照样插进来；清得再干净也换不来任何节奏变化。
func _check_boss() -> void:
	if not is_instance_valid(player):
		return
	if _boss != null and is_instance_valid(_boss):
		return
	if _stage_time < float(Stage.at(_stage_index)["length"]):
		return
	_spawn_boss()


func _spawn_boss() -> void:
	var stage: Dictionary = Stage.at(_stage_index)
	var hp: float = (ENEMY_HP_BASE + _elapsed * ENEMY_HP_GROWTH + _elapsed * _elapsed * ENEMY_HP_QUADRATIC) \
		* BOSS_HP_MULT * float(stage["hp_scale"])
	var speed: float = (randf_range(ENEMY_SPEED_MIN, ENEMY_SPEED_MAX) + minf(_elapsed * ENEMY_SPEED_GROWTH, ENEMY_SPEED_CAP)) * BOSS_SPEED_SCALE
	var boss_name: String = str(stage["boss"])
	# 招式风格跟着名字走，不跟着章号：无尽轮次会把这三只循环放出来，
	# 玩家记住的是"潮主会拍浪"，而不是"第三章的 Boss 会什么"。
	var kit: int = Stage.boss_kit(boss_name)
	var boss := Enemy.new()
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
	world.add_child(boss)
	# 出现在普通刷怪环外侧 1.25 倍处：玩家看得见它从远处走进来，而不是凭空贴脸出现。
	# 圈变小之后这个点会掉到毒里，所以同样要夹一次——Boss 不吃毒，但"从紫幕外走进来"
	# 看着像逃课；夹在壁外侧 1.03R 处，它仍然从远处入画。
	boss.global_position = _clamp_point_into_zone(player.global_position + _spawn_offset(randf() * TAU) * 1.25)
	_enemies.append(boss)
	_boss = boss
	# 血条带风格名（潮主 · 潮汐）：三只 Boss 的招式不同，名字后面得跟上"它怎么打"
	hud.show_boss(boss_name, Enemy.BOSS_KIT_NAMES[kit])
	# 出场横幅只报"关底 + 它怎么威胁你"。同一时间换章横幅已经用掉了，
	# 这里不写章节信息，只让玩家知道"接下来这一场是读招，不是拼血"。
	hud.show_banner("关底 · " + boss_name, Stage.boss_hint(boss_name), Stage.tint(_stage_index), false)
	# 立刻刷一次 HUD：章节条要当场变成"关底"，
	# 等 10Hz 的节流刷新会有最多 0.1 秒的延迟，玩家会先看到 Boss 出场再看到条变红
	_update_hud()
	if is_instance_valid(player):
		player.add_trauma(0.4)


## Boss 召唤小怪：围着自己一圈生成，强迫玩家在"打 Boss"和"清小怪"之间取舍
func _on_boss_summon(at: Vector2, count: int) -> void:
	for i in range(count):
		if _enemies.size() >= _max_enemies:
			return
		var angle: float = TAU * float(i) / float(maxi(count, 1))
		_create_enemy(Enemy.Kind.GRUNT, false, at + Vector2(cos(angle), sin(angle)) * 78.0)


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
		shot.velocity = dir * BOSS_SHOT_SPEED
		shot.damage = BOSS_SHOT_DAMAGE
		# 暗红色弹体：和吐息者的青绿弹区分开，玩家靠颜色就能判断优先级
		shot.color = Color(0.98, 0.46, 0.5)
		world.add_child(shot)
		shot.global_position = at + dir * 60.0


func _on_boss_phase(phase: int) -> void:
	hud.set_boss_phase(phase)
	if is_instance_valid(player):
		player.add_trauma(0.5)


## 蚀影瞬移：原地和落点各炸一团紫色火花。
## 这一招的危险不在伤害（瞬移本身不伤人），而在"你刚算好的走位作废了"——
## 所以必须让玩家看见"它从哪走、去了哪"，否则只会觉得是瞬移刷脸。
func _on_boss_blink(from: Vector2, to: Vector2) -> void:
	if _sparks != null:
		var tint := Color(0.78, 0.55, 1.0)
		_sparks.burst(from, tint, 14)
		_sparks.burst(to, tint, 20)
	if is_instance_valid(player):
		player.add_trauma(0.3)


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
		shot.velocity = dir * BOSS_HOMING_SPEED
		shot.damage = BOSS_HOMING_DAMAGE
		shot.homing_turn = BOSS_HOMING_TURN
		shot.homing_speed = BOSS_HOMING_SPEED
		# 紫粉色：和弹幕的暗红、吐息者的青绿都不同，一眼能认出"这发会追人"
		shot.color = Color(0.95, 0.52, 0.86)
		world.add_child(shot)
		shot.global_position = at + dir * 48.0


func _on_boss_killed() -> void:
	_boss = null
	hud.hide_boss()
	_boss_grace = BOSS_GRACE_TIME
	if is_instance_valid(player):
		player.heal(player.max_health * BOSS_HEAL_RATIO)
		player.add_trauma(0.7)
	_advance_stage()


## 关卡推进：击杀章节 Boss 就是"过了一关"。这里是 P2-8 的落点——
## 换配色、弹横幅、发一张卡，玩家能明确感到节奏翻页了，
## 而不是"又打了一只血多的怪"。
func _advance_stage() -> void:
	_stage_index += 1
	_stage_time = 0.0
	_apply_stage_look(Stage.at(_stage_index))
	_card_delay = BANNER_READ_TIME

	if not _cleared and Stage.is_cleared(_stage_index):
		_cleared = true
		hud.show_banner("通关 · 三章走完", "深渊没有底，但你已经在最深处站住了", Stage.tint(_stage_index), true)
		if is_instance_valid(player):
			# 通关把血补满：后面是无尽轮次，血量在这里清零等于把奖励变成了惩罚
			player.heal(player.max_health)
			player.add_trauma(0.9)
		# 通关奖励两张卡，后续每章一张
		_pending_cards += 2
		_update_hud()
		return

	var stage: Dictionary = Stage.at(_stage_index)
	hud.show_banner(Stage.title(_stage_index), str(stage["subtitle"]), Stage.tint(_stage_index), false)
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
	var p_spitter: float = float(stage["spitter"])
	var p_bomber: float = float(stage["bomber"])
	# 三者之和就是"这只怪是特殊怪"的总概率，剩下的一律普通小兵。
	# 不能给普通小兵也写一个权重再按总和归一：那样每章加一种特殊怪，
	# 普通小兵的占比就会被稀释，包围感跟着一起变弱。
	var total: float = p_charger + p_spitter + p_bomber
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
	shot.velocity = direction * SPIT_SPEED
	shot.damage = SPIT_DAMAGE
	world.add_child(shot)
	shot.global_position = at


## 视野外接半径：视口半尺寸 / 相机缩放 得到的半宽半高，取对角线长度。
## 缩圈表用它的倍数写，于是手机（960×540）和桌面（1280×720）看到的是
## "这个圈占几屏"，而不是同一串像素在两种屏幕上差出 33%。
func _view_radius() -> float:
	var half: Vector2 = get_viewport_rect().size / (2.0 * Player.CAMERA_ZOOM)
	return maxf(half.length(), 1.0)


## 缩圈每帧 tick + 圈外伤害结算。
## 毒伤必须走 Player.take_zone_damage()：take_damage() 开头就是"无敌帧内直接返回"，
## 而 0.45 秒无敌比 0.5 秒的毒伤跳还长——被怪贴身打的时候，毒会被整段吞掉，
## 变成"挨打反而不中毒"。这条路不吃无敌帧、不触发闪白，但会点亮红边。
func _tick_zone(delta: float) -> void:
	if zone == null or not is_instance_valid(zone):
		return
	zone.tick(delta)
	_zone_dmg_timer += delta
	if _zone_dmg_timer < ZONE_TICK:
		return
	var step: float = _zone_dmg_timer
	_zone_dmg_timer = 0.0
	var rate: float = zone.dps()
	if rate <= 0.0 or not is_instance_valid(player):
		return
	if not zone.is_outside(player.global_position):
		return
	var amount: float = player.max_health * rate * step
	# 死因要在伤害生效前写：take_zone_damage 会同步 emit died，_on_player_died 当场读这个字段
	if player.health <= amount:
		_death_cause = "圈外"
	player.take_zone_damage(amount)


## 刷怪点：视野椭圆的外接环。用视口尺寸 / 相机缩放反推世界可见范围，
## 换分辨率、换宽高比都不会再露边；写死常量做不到这一点。
func _spawn_offset(angle: float) -> Vector2:
	var extent: Vector2 = get_viewport_rect().size / (2.0 * Player.CAMERA_ZOOM) * SPAWN_MARGIN
	var grow: float = 1.0 + randf() * SPAWN_RING_SPREAD
	return Vector2(cos(angle) * extent.x, sin(angle) * extent.y) * grow


## 把生成点收进安全区外沿。
## 圈半径小于视野半径时，"视野外"和"圈内"会打架：按视野外接椭圆算出来的点落在毒里，
## 怪刷出来就站在圈外，永远追不到玩家，看起来还像从紫幕里凭空冒出来。
## 这里统一收到 1.03R——刚好在壁外一点，视觉上就是"从紫幕里钻出来"，然后自己走进圈。
## 敌人不吃毒（见 Zone 的说明），所以站在壁外这一小段完全无害。
func _clamp_point_into_zone(at: Vector2) -> Vector2:
	if zone == null or not is_instance_valid(zone):
		return at
	var limit: float = zone.radius * 1.03
	if limit <= 1.0:
		return at
	var offset: Vector2 = at - zone.center
	if offset.length() <= limit:
		return at
	return zone.center + offset.normalized() * limit


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


func _on_enemy_died(enemy: Enemy, xp: int) -> void:
	_enemies.erase(enemy)
	_kills += 1
	# Boss 单独计数：它同时打乱"精英数"和"击杀数"的语义，结算面板要分开显示
	var is_boss: bool = enemy.kind == Enemy.Kind.BOSS
	if is_boss:
		_boss_kills += 1
	elif enemy.tier > 0:
		_elite_kills += 1
	# 普通击杀几乎无感（靠连杀累积出"战场在动"），精英击杀单独给一记明显的顿挫
	if is_instance_valid(player):
		player.add_trauma(0.25 if enemy.tier > 0 else 0.04)
		# 击杀是回蓝的主要来源，自然回蓝只是保底
		player.add_mana(HeroClass.MANA_PER_KILL[_hero])
	if is_boss:
		_on_boss_killed()
		_boss_gem_burst(enemy.global_position, _gem_value(xp))
	else:
		_spawn_gem(enemy.global_position, _gem_value(xp))


## Boss 掉落：原来只给一颗大宝石，捡起来一下就没了。
## 拆成一圈散开的 8 颗，总经验基本不变（8×6 vs 45），
## 但"打完炸出一地经验"是这场战斗胜利的实感——这是唯一一处玩家会主动停下来捡的掉落。
func _boss_gem_burst(at: Vector2, total: int) -> void:
	var each: int = maxi(1, int(round(float(total) / float(BOSS_GEM_COUNT))))
	for i in range(BOSS_GEM_COUNT):
		var angle: float = TAU * float(i) / float(BOSS_GEM_COUNT) + randf() * 0.25
		var point: Vector2 = at + Vector2(cos(angle), sin(angle)) * randf_range(26.0, 56.0)
		_spawn_gem(_clamp_point_into_zone(point), each)


## 波次越高每颗宝石越值钱（1 分钟 ×2、2 分钟 ×3、3 分钟以后 ×4）。
## 不这么做的话，敌人越硬、清场越慢，升级进度反而越推不动，玩家会感觉"越玩越沉"。
func _gem_value(base: int) -> int:
	return base * (1 + mini(int(_elapsed / 60.0), 3))


## 受击火花。概率过滤 + 粒子上限双保险：前者的作用是别让画面糊掉，
## 后者的作用是保证再极端的情况也不会因为绘制量爆掉而掉帧。
func _on_enemy_hit(at: Vector2, tint: Color) -> void:
	if _sparks == null or randf() > HIT_SPARK_CHANCE:
		return
	_sparks.burst(at, tint.lightened(0.35), 3)


func _spawn_gem(at: Vector2, value: int) -> void:
	var gem := XpGem.new()
	gem.value = value
	gem.target = player
	gem.collected.connect(_on_gem_collected)
	world.add_child(gem)
	gem.global_position = at
	_gems.append(gem)


func _on_gem_collected(gem: XpGem, value: int) -> void:
	_gems.erase(gem)
	_gain_xp(value)


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
		# 升级顺手回一口血：让"刷经验"同时是续航手段，而不是只能靠打到回血卡
		if is_instance_valid(player):
			player.heal(player.max_health * LEVEL_HEAL_RATIO)
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
	_apply_upgrade(_choices[index])
	_pending_cards = maxi(_pending_cards - 1, 0)
	hud.close_level_up()
	_state = State.PLAYING
	get_tree().paused = false
	if touch != null:
		touch.set_active(true)
	_update_hud()
	if _pending_cards > 0:
		_open_level_up()


func _apply_upgrade(card: Dictionary) -> void:
	var id: String = str(card["id"])
	var amount: float = float(card["amount"])
	var bullet: BulletWeapon = player.bullet_weapon
	var orbit: OrbitWeapon = player.orbit_weapon
	var boomerang: BoomerangWeapon = player.boomerang_weapon
	match id:
		"bullet_damage":
			bullet.damage *= (1.0 + amount)
		"bullet_rate":
			bullet.interval = maxf(bullet.interval * (1.0 - amount), 0.1)
		"bullet_proj":
			# 高档卡一次 +4，不夹一下会越过 8 的上限
			bullet.projectiles_per_shot = mini(bullet.projectiles_per_shot + int(round(amount)), 8)
		"bullet_pierce":
			bullet.pierce += int(round(amount))
		"bullet_range":
			bullet.attack_range += amount
		"orbit_unlock":
			orbit.blades = maxi(orbit.blades, 1)
		"orbit_count":
			orbit.blades = mini(orbit.blades + int(round(amount)), 8)
		"orbit_damage":
			orbit.damage += amount
		"orbit_radius":
			orbit.orbit_radius += amount
		"orbit_speed":
			orbit.spin_speed *= (1.0 + amount)
		"boomerang_unlock":
			boomerang.count = maxi(boomerang.count, 1)
		"boomerang_count":
			boomerang.count = mini(boomerang.count + int(round(amount)), 6)
		"boomerang_damage":
			boomerang.damage += amount
		"boomerang_range":
			boomerang.fly_distance += amount
		"boomerang_rate":
			boomerang.cooldown = maxf(boomerang.cooldown * (1.0 - amount), 0.6)
		"move":
			player.move_speed *= (1.0 + amount)
		"hp":
			# 生命也按百分比：战士 180 与法师 100 吃同样的 +25 差距太大
			var bonus: float = player.max_health * amount
			player.max_health += bonus
			player.heal(bonus)
		"melee_damage":
			if player.melee_weapon != null:
				player.melee_weapon.damage *= (1.0 + amount)
		"melee_rate":
			if player.melee_weapon != null:
				player.melee_weapon.interval = maxf(player.melee_weapon.interval * (1.0 - amount), 0.12)
		"melee_reach":
			if player.melee_weapon != null:
				player.melee_weapon.reach += amount


# ---------------------------------------------------------------- 结束与输入

## 触摸技能键。真正的判定（蓝够不够、是否已死）都在 Player.try_use_skill() 里，
## 这里只补一记轻震：手机上没有键盘反馈，点下去必须"有手感"。
func _on_skill_button() -> void:
	if _state != State.PLAYING or not is_instance_valid(player):
		return
	if player.try_use_skill():
		player.add_trauma(0.2)


func _on_player_died() -> void:
	_state = State.GAME_OVER
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
	# 关卡进度：结算面板要能回答"我这局走到哪了"，只给一个存活秒数是不够的
	result["stage_index"] = _stage_index
	result["stage_name"] = Stage.title(_stage_index)
	result["cleared"] = _cleared
	result["death_cause"] = _death_cause
	hud.show_game_over(result)


func _input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return

	match _state:
		State.PLAYING:
			if key_event.is_action_pressed("cast_skill") and is_instance_valid(player):
				player.try_use_skill()
		State.LEVEL_UP:
			if key_event.keycode >= KEY_1 and key_event.keycode <= KEY_9:
				_choose(key_event.keycode - KEY_1)
		State.GAME_OVER:
			if key_event.keycode == KEY_R:
				_restart()
			elif key_event.keycode == KEY_P or key_event.keycode == KEY_ESCAPE:
				_open_menu()


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


## 安全区那一行字。三种状态一眼能分：
##   收缩中 → "安全区收缩中 00:45"（现在就得挪）
##   稳定   → "安全区 02:00 后收缩"（还有多久）
##   圈外   → 换成伤害速率，整行由 HUD 染红
## 不报"当前半径"这种数字：玩家真正需要的是时间，半径用眼睛看那条紫线就够了。
func _zone_text(outside: bool) -> String:
	if outside:
		return "圈外！  -%.1f%% 生命/秒" % (zone.dps() * 100.0)
	if zone.segment_label() == "终局":
		return "终局  %s" % _mmss(zone.segment_time_left())
	if zone.is_shrinking():
		return "安全区收缩中  %s" % _mmss(zone.segment_time_left())
	return "安全区  %s 后收缩" % _mmss(zone.segment_time_left())


func _update_hud() -> void:
	hud.set_progress(float(_xp), float(_xp_need))
	var stage: Dictionary = Stage.at(_stage_index)
	var boss_alive: bool = _boss != null and is_instance_valid(_boss)
	hud.set_stage(
		Stage.title(_stage_index),
		clampf(_stage_time / maxf(float(stage["length"]), 1.0), 0.0, 1.0),
		boss_alive,
		Stage.tint(_stage_index),
	)
	# 时间放进来是为了让老玩家还能对表：章节推进多少秒是可变节奏，
	# 但"我这局撑了多久"仍然是排行榜和手感的共同基准。
	hud.set_stats("%s  Lv.%d    击杀 %d    时间 %s" % [HeroClass.NAMES[_hero], _level, _kills, _time_text()])
	hud.set_next_upgrade(_next_card_level)
	hud.set_danger(_danger_level())
	var outside: bool = false
	if zone != null and is_instance_valid(zone) and is_instance_valid(player):
		outside = zone.is_outside(player.global_position)
		hud.set_zone_status(_zone_text(outside), outside)
		# 屏幕位移 = 世界位移 × 相机缩放（相机始终跟着玩家，玩家就在屏幕中心）
		hud.set_zone_direction((zone.center - player.global_position) * Player.CAMERA_ZOOM, outside)
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


