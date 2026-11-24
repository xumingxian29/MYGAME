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
## 分离时每个敌人最多参考几个邻居。封顶避免人群中心出现 O(邻居数) 的推力尖刺。
const MAX_SEPARATION_NEIGHBORS: int = 8
## 每帧直接消掉最深那处重叠的比例。纯靠力的话，人群中心会长期保持 60% 左右的深度穿插。
const SEPARATION_RELAX: float = 0.6

## 刷怪间隔：0 = 最轻，1 = 最密
const SPAWN_INTERVAL_EASY: float = 0.7
const SPAWN_INTERVAL_HARD: float = 0.28
## 每过这么多秒，每波多刷一只
const WAVE_GROWTH_SECONDS: float = 35.0
## 场上同时存在的敌人上限 = BUDGET_BASE + 存活秒数 / BUDGET_STEP。
## 没有这道闸门时，刷怪速度（每秒数只）远超单目标清怪速度，屏外会堆到几百只。
const BUDGET_BASE: int = 12
const BUDGET_STEP: float = 3.0
const ENEMY_HP_BASE: float = 8.0
## 敌人血量随时间增长。0.18 而不是 0.2：升级卡改成"最多 8 张"之后，
## 玩家在同等时间点的输出约为原来的六成，血量涨得慢一点才能对齐。
const ENEMY_HP_GROWTH: float = 0.18
const ENEMY_SPEED_MIN: float = 62.0
const ENEMY_SPEED_MAX: float = 94.0
const ENEMY_SPEED_GROWTH: float = 0.35
const ENEMY_SPEED_CAP: float = 46.0
const ELITE_START_TIME: float = 45.0
const ELITE_CHANCE: float = 0.12
## 血量低于这个比例时开始出红边，0 血满强度
const DANGER_HEALTH: float = 0.35
## 每次受击生成火花的概率。全出的话高密度下每秒几百次，屏幕会糊成一片白
const HIT_SPARK_CHANCE: float = 0.5

## 升级卡节奏：升到 FIRST_CARD_LEVEL 给第一张，之后间隔逐次 +1
## （再升 2 级、3 级、4 级…），即 Lv.2 / 4 / 7 / 11 / 16 / 22 / 29 …
## 卡越来越少，但每张都更值钱：稀有度会随等级上移，见 CardRarity。
const FIRST_CARD_LEVEL: int = 2

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
## 世界容器：显式 PAUSABLE。Game 自身是 ALWAYS，若子节点用默认 INHERIT 会跟着 ALWAYS，
## 导致 get_tree().paused 形同虚设（升级选卡时后台照样掉血）。
var world: Node2D

var _enemies: Array[Enemy] = []
var _gems: Array[XpGem] = []
## 命中火花容器：整个局共用这一个节点，粒子在它内部用数组管理
var _sparks: HitSparks = null
## 每帧重建的空间网格，只服务敌人分离
var _grid: EnemyGrid = EnemyGrid.new()
## 邻域查询的复用缓冲，避免每帧为每个敌人分配一个数组
var _neighbor_buf: Array = []
var _state: State = State.MENU
var _elapsed: float = 0.0
var _kills: int = 0
var _elite_kills: int = 0
var _level: int = 1
var _xp: int = 0
var _xp_total: int = 0
var _xp_need: int = 6
var _spawn_timer: float = 0.25
## 待发奖的强化卡数量（一次升级可能连跨多级，但只有到了阈值才发卡）
var _pending_cards: int = 0
## 这张卡所在的等级，以及下一张卡还差几级
var _next_card_level: int = FIRST_CARD_LEVEL
var _card_gap: int = 1
var _choices: Array[Dictionary] = []
## 当前玩家的档案 {"name", "best", "runs", "total_kills"}，由 ScoreBoard 读写
var _profile: Dictionary = {}
## 本局职业，以及菜单里上次选的职业（换人时沿用，不用每次重选）
var _hero: int = HeroClass.WARRIOR
var _last_hero: int = HeroClass.WARRIOR


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	RenderingServer.set_default_clear_color(Color(0.055, 0.062, 0.082))
	world = Node2D.new()
	world.name = "World"
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(world)
	_build_hud()
	_build_menu()
	_open_menu()


func _build_hud() -> void:
	hud = GameHud.new()
	add_child(hud)
	hud.card_chosen.connect(_choose)


func _build_menu() -> void:
	start_menu = StartMenu.new()
	add_child(start_menu)
	start_menu.started.connect(_on_menu_started)


## 开局菜单：默认填入上次玩的昵称，并列出本机所有玩家
func _open_menu() -> void:
	_state = State.MENU
	get_tree().paused = true
	hud.clear_overlays()
	hud.set_danger(0.0)
	hud.set_hud_visible(false)
	start_menu.open(ScoreBoard.last_player(), ScoreBoard.list_players(), _last_hero)


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
	_kills = 0
	_elite_kills = 0
	_level = 1
	_xp = 0
	_xp_total = 0
	_xp_need = 6
	_spawn_timer = 0.25
	_pending_cards = 0
	_next_card_level = FIRST_CARD_LEVEL
	_card_gap = 1
	_choices.clear()

	hud.clear_overlays()
	hud.set_hud_visible(true)
	# 火花层在玩家之前加入 World，但 z_index 更高，绘制时仍在所有游戏物体之上
	_sparks = HitSparks.new()
	world.add_child(_sparks)
	_spawn_player()
	_state = State.PLAYING
	get_tree().paused = false
	_update_hud()


func _clear_world() -> void:
	for child in world.get_children():
		world.remove_child(child)
		child.queue_free()
	player = null


func _spawn_player() -> void:
	player = Player.new()
	# hero 必须在 add_child 之前赋值：Player._ready 里要按职业装配武器
	player.hero = _hero
	player.enemies = _enemies
	world.add_child(player)
	player.health_changed.connect(hud.set_health)
	player.mana_changed.connect(hud.set_mana)
	player.died.connect(_on_player_died)
	hud.set_hero(_hero)
	hud.set_health(player.health, player.max_health)
	hud.set_mana(player.mana, player.max_mana)


func _physics_process(delta: float) -> void:
	if _state != State.PLAYING:
		return

	_elapsed += delta
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = lerpf(SPAWN_INTERVAL_EASY, SPAWN_INTERVAL_HARD, _pressure())
		_spawn_wave()
	_cull_far_enemies()
	_grid_rebuild()
	_apply_separation()
	_cull_far_gems()
	_update_hud()


## 0 = 刚开局的最轻压力，1 = 压力拉满
func _pressure() -> float:
	return clampf((_elapsed - GRACE_TIME) / RAMP_TIME, 0.0, 1.0)


func _process(_delta: float) -> void:
	if _state == State.PLAYING:
		queue_redraw()


# ---------------------------------------------------------------- 刷怪

func _spawn_wave() -> void:
	var count: int = 1 + int(_elapsed / WAVE_GROWTH_SECONDS)
	var budget: int = _enemy_budget()
	for i in range(count):
		if _enemies.size() >= budget:
			return
		_spawn_enemy()


## 场上敌人数量的天花板，随存活时间缓慢放开
func _enemy_budget() -> int:
	return mini(BUDGET_BASE + int(_elapsed / BUDGET_STEP), MAX_ENEMIES)


func _spawn_enemy() -> void:
	var big: bool = _elapsed > ELITE_START_TIME and randf() < ELITE_CHANCE

	var hp: float = ENEMY_HP_BASE + _elapsed * ENEMY_HP_GROWTH
	var speed: float = randf_range(ENEMY_SPEED_MIN, ENEMY_SPEED_MAX) + minf(_elapsed * ENEMY_SPEED_GROWTH, ENEMY_SPEED_CAP)
	if big:
		hp *= 3.2
		# 只减速 15%：太慢的话精英会一直落在队伍后面，永远打不到也杀不掉
		speed *= 0.85

	var enemy := Enemy.new()
	enemy.configure(hp, speed, big)
	enemy.target = player
	enemy.died.connect(_on_enemy_died)
	enemy.hit.connect(_on_enemy_hit)
	world.add_child(enemy)
	enemy.global_position = player.global_position + _spawn_offset(randf() * TAU)
	_enemies.append(enemy)


## 刷怪点：视野椭圆的外接环。用视口尺寸 / 相机缩放反推世界可见范围，
## 换分辨率、换宽高比都不会再露边；写死常量做不到这一点。
func _spawn_offset(angle: float) -> Vector2:
	var extent: Vector2 = get_viewport_rect().size / (2.0 * Player.CAMERA_ZOOM) * SPAWN_MARGIN
	var grow: float = 1.0 + randf() * SPAWN_RING_SPREAD
	return Vector2(cos(angle) * extent.x, sin(angle) * extent.y) * grow


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
		_neighbor_buf.clear()
		_grid.query(enemy.global_position, _neighbor_buf)

		var push := Vector2.ZERO
		var deepest: float = 0.0
		var deepest_dir: Vector2 = Vector2.ZERO
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
			used += 1
			if used >= MAX_SEPARATION_NEIGHBORS:
				break

		if deepest <= 0.0:
			continue
		enemy.separation = push.normalized()
		# 位置修正：只施加力的话人群中心会一直保持深度穿插（实测残留 60%），
		# 这里按"最深的那一处"直接消掉一部分重叠，几帧内就收敛干净。
		# 只改最深的一处而不是全部相加，避免人群中心被叠加推力弹飞。
		enemy.global_position += deepest_dir * deepest * SEPARATION_RELAX * enemy.radius


func _cull_far_enemies() -> void:
	var limit: float = DESPAWN_DISTANCE * DESPAWN_DISTANCE
	for i in range(_enemies.size() - 1, -1, -1):
		var enemy: Enemy = _enemies[i]
		if not is_instance_valid(enemy):
			_enemies.remove_at(i)
			continue
		if enemy.global_position.distance_squared_to(player.global_position) > limit:
			_enemies.remove_at(i)
			enemy.queue_free()


func _on_enemy_died(enemy: Enemy, xp: int) -> void:
	_enemies.erase(enemy)
	_kills += 1
	if enemy.tier > 0:
		_elite_kills += 1
	# 普通击杀几乎无感（靠连杀累积出"战场在动"），精英击杀单独给一记明显的顿挫
	if is_instance_valid(player):
		player.add_trauma(0.25 if enemy.tier > 0 else 0.04)
		# 击杀是回蓝的主要来源，自然回蓝只是保底
		player.add_mana(HeroClass.MANA_PER_KILL[_hero])
	_spawn_gem(enemy.global_position, xp)


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
		_xp_need = int(float(_xp_need) * 1.22) + 1
		if _level >= _next_card_level:
			_pending_cards += 1
			# 间隔逐次 +1：这次之后要再升 _card_gap 级才发下一张
			_card_gap += 1
			_next_card_level = _level + _card_gap
	if _pending_cards > 0 and _state == State.PLAYING:
		_open_level_up()


func _open_level_up() -> void:
	_state = State.LEVEL_UP
	get_tree().paused = true
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

func _on_player_died() -> void:
	_state = State.GAME_OVER
	get_tree().paused = true
	player.visible = false
	hud.close_level_up()
	# 结算界面背后不该一直闪红光：死亡后红边退掉，交给压暗遮罩做视觉切换
	hud.set_danger(0.0)

	var breakdown: Dictionary = Score.compute(_kills, _elite_kills, _elapsed, _level, _xp_total)
	var outcome: Dictionary = ScoreBoard.submit(str(_profile.get("name", ScoreBoard.DEFAULT_NAME)), {
		"score": breakdown["total"],
		"kills": _kills,
		"elite_kills": _elite_kills,
		"level": _level,
		"xp_total": _xp_total,
		"elapsed": _elapsed,
	})
	_profile = outcome["profile"]
	hud.set_score(str(_profile["name"]), int(breakdown["total"]), int(_profile["best"]["score"]))

	var result: Dictionary = breakdown.duplicate()
	result["kills"] = _kills
	result["elite_kills"] = _elite_kills
	result["level"] = _level
	result["xp_total"] = _xp_total
	result["time_text"] = _time_text()
	result["score"] = breakdown["total"]
	result["profile"] = _profile
	result["is_best"] = outcome["is_best"]
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
			elif key_event.keycode == KEY_P:
				_open_menu()


## 同一个人再来一局：不重载场景，昵称与个人最高分都保留
func _restart() -> void:
	if _profile.is_empty():
		_open_menu()
		return
	_begin_run()


func _time_text() -> String:
	return "%02d:%02d" % [int(_elapsed) / 60, int(_elapsed) % 60]


func _update_hud() -> void:
	hud.set_progress(float(_xp), float(_xp_need))
	hud.set_stats("%s  Lv.%d    击杀 %d    时间 %s" % [HeroClass.NAMES[_hero], _level, _kills, _time_text()])
	hud.set_next_upgrade(_next_card_level)
	hud.set_danger(_danger_level())
	var best_score: int = 0
	if _profile.has("best"):
		best_score = int(_profile["best"].get("score", 0))
	hud.set_score(str(_profile.get("name", "")), _current_score(), best_score)


## 血量越低红边越强。线性映射而不是台阶：玩家能从红边变浓的速率上
## 预判"再挨一下会不会死"，这比只在某个阈值突然亮起来有用。
func _danger_level() -> float:
	if not is_instance_valid(player) or player.max_health <= 0.0:
		return 0.0
	var ratio: float = player.health / player.max_health
	return clampf((DANGER_HEALTH - ratio) / DANGER_HEALTH, 0.0, 1.0)


## 实时分数：与结算用同一套公式，保证界面上的数字和最终得分一致
func _current_score() -> int:
	return Score.total(_kills, _elite_kills, _elapsed, _level, _xp_total)


# ---------------------------------------------------------------- 背景网格

func _draw() -> void:
	if player == null:
		return
	const GRID: float = 90.0
	const EXTENT: float = 900.0
	var base: Vector2 = (player.global_position / GRID).floor() * GRID
	var start: Vector2 = base - Vector2(EXTENT, EXTENT)
	var color := Color(1.0, 1.0, 1.0, 0.045)
	var steps: int = int(EXTENT * 2.0 / GRID) + 1
	for i in range(steps):
		var x: float = start.x + float(i) * GRID
		draw_line(Vector2(x, start.y), Vector2(x, start.y + EXTENT * 2.0), color, 1.0)
		var y: float = start.y + float(i) * GRID
		draw_line(Vector2(start.x, y), Vector2(start.x + EXTENT * 2.0, y), color, 1.0)


