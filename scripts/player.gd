class_name Player
extends Node2D

## 玩家：WASD 移动、承受伤害，本身不含任何武器逻辑。
## 武器是子节点组件（BulletWeapon / OrbitWeapon / BoomerangWeapon），各自持有自己的可升级属性。
## enemies 数组由 Game 注入（同一引用），并转发给各武器。

signal health_changed(current: float, maximum: float)
signal mana_changed(current: float, maximum: float)
signal died
## 技能释放成功时发出，HUD 用来做一次性提示（目前只用来震一下技能文字）
signal skill_cast(hero: int)

## 相机缩放。Game 的刷怪距离按“刚好在视野外”计算，改动此处需同步刷怪距离。
const CAMERA_ZOOM: float = 1.35
const INVULN_TIME: float = 0.45

## 脱战回血：最后 REGEN_DELAY 秒没挨打，就按最大生命的 REGEN_RATE/秒 往回补。
##
## 为什么需要一条独立于成长的回血曲线：实测 seed 11~13（n=6）里，活到 394 秒的
## 三局和 136~209 秒就死的三局，在场敌人（50.0 / 49.9）、等级（29 / 28）、
## 卡数（15 / 15）几乎完全相同，唯一的差别是血量 168 / 9。
## 原来回血只有升级那一下（Game.LEVEL_HEAL_RATIO 6%），于是"缺血 → 清怪慢 →
## 经验少 → 升级慢 → 回得更少"构成死亡螺旋，强者满血溢出、弱者一路滑到 0。
## 续航必须和成长解耦，否则它只会放大方差。
##
## 2.5 秒这个值不是拍的：实测受击频率 0.18 次/秒（平均 5.5 秒挨一下），
## 窗口比间隔短一半，实战里大多数时候都成立。
const REGEN_DELAY: float = 2.5
## 战士 180 血 → 1.08/秒，约等于实测掉血率（第 1 局 90~195 秒掉 126 血 = 1.2/秒）
## 的九成：足够把"必死"拖成"能撑过第二只 Boss"，又不至于让满血的人变无敌。
const REGEN_RATE: float = 0.006
## 每 0.25 秒结算一次。逐帧 heal() 会逐帧发 health_changed，HUD 的血条与低血红边
## 就会以 60Hz 重建，看起来像条在自己抖。
const REGEN_TICK: float = 0.25
const BODY_RADIUS: float = 14.0
const FLASH_TIME: float = 0.18
const FLASH_COLOR: Color = Color(2.2, 1.2, 1.2)
## 技能特效（扩散圆环）的持续时间
const SKILL_FX_TIME: float = 0.45

## 屏幕震动用 trauma 模型：伤害累加 trauma，随时间线性衰减，位移取 trauma² 作幅度。
## 平方的意义是"轻击几乎不抖、重击抖得明显"，比直接用线性强度更像有重量。
const TRAUMA_DECAY: float = 1.9
## 位移幅度上限（世界单位，1 单位 = 1.35 屏幕像素，zoom=1.35）。
## 实测 trauma=0.50（一次受击）时峰值约 5 单位 ≈ 7 屏幕像素：
## 打在 853 宽的世界视野里刚好"看得见但不晕"，再大就开始影响读屏了。
## 注意峰值 = amp × 0.78（两个轴四项正弦之和最大 1.3，再乘 0.6）。
const SHAKE_MAX_OFFSET: float = 26.0

## 震动主频（Hz）。这是"后期屏幕看着震荡"的真正病根，改之前是等效 12~27Hz：
## 每帧相位推进 = 360° × hz / 60，旧版 46rad/s × (1.7~3.7) 落在 12.4/16.8/21.2/27.1Hz，
## 也就是**每帧推进 75°~127°**。一帧转过 90°，下一帧的方向和这一帧没有关系，
## 采样出来是白噪声——玩家看到的不是"晃了一下"，而是画面每帧随机跳一个位置。
## 5.4Hz 每帧只推进 32°，约 5.6 帧走完半个周期，才读得出"整块画面被推了一下"的惯性。
const SHAKE_HZ: float = 5.4
## 细节分量：倍频与权重。倍频不能高——1.6×5.4=8.6Hz 已经是每帧 52°，
## 再往上又会回到"每帧换方向"，所以只给 0.3 权重当纹理，不当主体。
const SHAKE_FINE_MUL: float = 1.6
const SHAKE_FINE_WEIGHT: float = 0.3
## 幅度死区（世界单位）。amp 低于它时整屏位移不到 1 像素：玩家看不见，
## 但会一直"嗡"。改之前后期击杀密集（13~25 只/秒 × 0.04）会把 trauma
## 顶到稳态 0.4（amp≈4），正好落在"看得见一点、又永远不停"这个最难受的区间。
## 现在击杀已不再注入 trauma，加这道死区是第二重保险：
## 宁可少一点"战场在动"，也不要永不停歇的微抖。
const SHAKE_DEADZONE: float = 0.9

## 职业：决定血量 / 速度 / 武器 / 主动技能。必须在 add_child 之前赋值，
## 因为 _ready 里要按职业装配武器节点。
var hero: int = HeroClass.WARRIOR
var mana: float = 0.0
var max_mana: float = HeroClass.MANA_MAX

var max_health: float = 120.0
var health: float = 120.0
var move_speed: float = 240.0

var enemies: Array[Enemy] = []

## 音效引用，由 Game 注入。Player 不自己建音频节点——
## 音频需要跨局复用（换角色不该重建 20 个 player），生命周期比 Player 长。
var audio: GameAudio = null

var bullet_weapon: BulletWeapon
var melee_weapon: MeleeWeapon
var orbit_weapon: OrbitWeapon
var boomerang_weapon: BoomerangWeapon
## 相机由玩家持有，震动直接改 offset，不需要额外的抖动节点
var camera: Camera2D

## 受击无敌帧：避免被一群敌人同时贴身时瞬间融化
var _invuln: float = 0.0
## 距允许回血还剩多久（任一受伤入口都会重置成 REGEN_DELAY），
## 以及回血结算的累加器（按 REGEN_TICK 合并，避免逐帧发信号）
var _regen_wait: float = 0.0
var _regen_acc: float = 0.0
## 闪白剩余时长，倒数计时替代 Tween（理由同 Enemy）
var _flash_t: float = 0.0
## 当前震动强度 0~1，以及正弦相位（累加而不是取时间，避免暂停后跳变）
var _trauma: float = 0.0
var _shake_t: float = 0.0
## 技能扩散圆环：半径与颜色由 HeroSkill 写入，这里只负责画
var _skill_fx_t: float = 0.0
## 迷宫地图由 Game 在开局时注入（组合优于反查 get_parent）。
## 为 null 时移动逻辑保持原样，单独跑 Player 场景或旧自检都不会崩。
## 赋值时顺手推给武器：子弹与回旋镖在飞行途中拿不到"玩家当前在哪张图"，
## 只能各自持一份引用。只在这一处推，避免三个武器各写一套赋值逻辑。
var maze: MazeMap = null:
	set(value):
		maze = value
		_push_maze_to_weapons()

## 穿甲弹倍率。有弹时的一次攻击（一次开火 / 一刀 / 一趟镖）对普通怪 ×2.2；
## 对 Boss 走 Enemy 的破甲分支（窗口内满额、窗口外强制开窗）。
## 2.2 这个数必须明显强于任何一张输出卡（最高档 ×4.2 但只加一项属性），
## 又不能让"有弹"变成唯一打法——弹是捡来的，捡不到就得靠卡。
const AP_DAMAGE_SCALE: float = 2.2

## 破甲弹：库存真身在 Game，这里只放两个回调，再替武器转发一次。
## 用属性 setter 而不是在 Game 里手动推给三把武器：赋值只有一处，
## 少一个武器就少一条漏掉的路径（上一版就是轨道武器不认弹、战士捡了弹没处花）。
var breach_count: Callable = Callable():
	set(value):
		breach_count = value
		_push_ammo_refs()
var breach_take: Callable = Callable():
	set(value):
		breach_take = value
		_push_ammo_refs()

var _skill_fx_radius: float = 0.0
var _skill_fx_color: Color = Color.WHITE


## 武器侧需要 maze 的只有三件：子弹、回旋镖、近战。
## 环绕飞刃是贴着身体转的，墙对它的意义只有"半径够不够"，不存在穿墙。
func _push_maze_to_weapons() -> void:
	if bullet_weapon != null:
		bullet_weapon.maze = maze
	if boomerang_weapon != null:
		boomerang_weapon.maze = maze
	if melee_weapon != null:
		melee_weapon.maze = maze


## 把"还能打几发穿甲弹"的两个回调推给会用弹的武器。
## 环绕飞刃不在列表里：它每秒命中几十次，按次扣弹会在两秒内清空库存，
## 而"贴着脸转的刀"本身就不该是消耗破甲弹的地方。
func _push_ammo_refs() -> void:
	for w in [bullet_weapon, melee_weapon, boomerang_weapon]:
		if w != null:
			w.breach_count = breach_count
			w.breach_take = breach_take


func _ready() -> void:
	hero = clampi(hero, 0, HeroClass.COUNT - 1)
	max_health = HeroClass.HEALTH[hero]
	health = max_health
	move_speed = HeroClass.SPEED[hero]
	max_mana = HeroClass.MANA_MAX
	mana = 0.0

	bullet_weapon = BulletWeapon.new()
	bullet_weapon.enemies = enemies
	_configure_ranged_weapon()
	add_child(bullet_weapon)

	if hero == HeroClass.WARRIOR:
		melee_weapon = MeleeWeapon.new()
		melee_weapon.enemies = enemies
		add_child(melee_weapon)

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
	# maze 有可能在 add_child 之前就被 Game 赋过值（那时武器还不存在），
	# 所以装配完再推一次，两条路径都覆盖。
	_push_maze_to_weapons()
	_push_ammo_refs()
	# 玩家画在所有敌人之上。敌人是后加入 World 的，默认层级会盖住玩家——
	# 被围住时自己的角色直接看不见，Boss 站到身上更是完全遮住。
	# z_as_relative 保持默认，所以武器子节点也会跟着抬到同一层。
	z_index = 1
	queue_redraw()


## 远程武器的职业参数。战士没有远程，但仍保留节点并 enabled=false——
## 卡池、升级、结算里大量直接读 bullet_weapon 的字段，置空会到处判空。
func _configure_ranged_weapon() -> void:
	match hero:
		HeroClass.MAGE:
			bullet_weapon.damage = 34.0
			bullet_weapon.interval = 1.0
			bullet_weapon.projectile_speed = 430.0
			bullet_weapon.attack_range = 400.0
			bullet_weapon.splash_radius = 52.0
			bullet_weapon.shot_radius = 8.0
			bullet_weapon.shot_color = Color(0.74, 0.52, 1.0)
		HeroClass.RANGER:
			bullet_weapon.damage = 10.0
			bullet_weapon.interval = 0.20
			bullet_weapon.projectile_speed = 980.0
			bullet_weapon.attack_range = 470.0
			bullet_weapon.shot_radius = 3.2
			bullet_weapon.shot_color = Color(0.6, 1.0, 0.74)
			# 穿透 3 而不是 1。射手原来只有单体 36 dps，而中后期刷怪速度是 5.2 只/秒，
			# 清场速度永远追不上，人堆一满就被围死（探针：45 秒身边 0~1 只，85 秒 3~6 只，
			# 一半以上伤害来自小怪接触）。射手的"范围"不该是一圈爆发，而是一箭串三只——
			# 这样人越密收益越高，与"靠走位把敌人排成一条线"的玩法同向。
			bullet_weapon.pierce = 3
			# 箭矢"钉住"：命中后减速 0.55 秒。射手没有任何创造空间的手段
			# （战士靠击退，法师靠 285 半径新星），只能靠拉开距离活命。
			# 让每一箭都稍微拖慢追兵，走位的收益才是可累积的。
			# 敌人身上会出现冰蓝外圈，玩家看得见自己"钉住"了谁。
			bullet_weapon.slow_time = 0.55
			bullet_weapon.slow_factor = 0.3
		_:
			bullet_weapon.enabled = false


## 震动只在渲染帧推进，不放在 _physics_process 里。
## 物理固定 60 次/秒，渲染可能是 30（掉帧）或 120（高刷屏）。
## 两者不对齐时，同一个 offset 会被连续两帧共用、第三天再补两格，
## 阶梯式位移比原本的抖动还难看。凡是"只影响画面"的量，就该跟着渲染帧走。
func _process(delta: float) -> void:
	_tick_shake(delta)


## 暂停时 _process 不再推进，相机偏移会永久冻在最后一帧的位置——
## 升级选卡面板、结算页背后的世界就是歪的，最多歪 34 像素。
## 这里在暂停瞬间回正，比在每个暂停入口手动清理更可靠（暂停入口还会继续增加）。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED and _trauma > 0.0:
		_trauma = 0.0
		if camera != null:
			camera.offset = Vector2.ZERO


func _physics_process(delta: float) -> void:
	_invuln = maxf(_invuln - delta, 0.0)
	_tick_regen(delta)
	_tick_flash(delta)
	_tick_mana(delta)
	_tick_skill_fx(delta)
	_move(delta)


## 脱战回血。两个受伤入口都会把 _regen_wait 重置成 REGEN_DELAY，
## 所以"一直在挨打"时这条曲线完全不工作——它只奖励成功脱离接触。
func _tick_regen(delta: float) -> void:
	if health <= 0.0 or health >= max_health:
		# 满血时也把累加器清掉，否则下一次掉血会立刻吐出一大口"攒着"的回复
		_regen_acc = 0.0
		return
	if _regen_wait > 0.0:
		_regen_wait = maxf(_regen_wait - delta, 0.0)
		_regen_acc = 0.0
		return
	_regen_acc += delta
	if _regen_acc < REGEN_TICK:
		return
	heal(max_health * REGEN_RATE * _regen_acc)
	_regen_acc = 0.0


## 自然回蓝。只在整数变化时才发信号：每帧发信号会让 HUD 每帧重建一次字符串，
## 而条状进度用 1 点精度看起来已经足够连续。
func _tick_mana(delta: float) -> void:
	if mana >= max_mana:
		return
	var before: int = int(mana)
	mana = minf(mana + HeroClass.MANA_REGEN[hero] * delta, max_mana)
	if int(mana) != before or mana >= max_mana:
		mana_changed.emit(mana, max_mana)


## 击杀回蓝，由 Game 调用
func add_mana(amount: float) -> void:
	if mana >= max_mana or amount <= 0.0:
		return
	mana = minf(mana + amount, max_mana)
	mana_changed.emit(mana, max_mana)


func is_skill_ready() -> bool:
	return mana >= max_mana - 0.01


## 满蓝才能放，放完清零。返回是否真的放出去了，方便 Game 给音效 / 提示。
func try_use_skill() -> bool:
	if health <= 0.0 or not is_skill_ready():
		return false
	mana = 0.0
	mana_changed.emit(mana, max_mana)
	HeroSkill.cast(hero, self, enemies)
	skill_cast.emit(hero)
	return true


## 技能给的临时无敌：取最大值而不是覆盖，避免短无敌把长无敌顶掉
func grant_invuln(duration: float) -> void:
	_invuln = maxf(_invuln, duration)


func spawn_skill_fx(radius: float, color: Color) -> void:
	_skill_fx_radius = radius
	_skill_fx_color = color
	_skill_fx_t = SKILL_FX_TIME
	queue_redraw()


func _tick_skill_fx(delta: float) -> void:
	if _skill_fx_t <= 0.0:
		return
	_skill_fx_t = maxf(_skill_fx_t - delta, 0.0)
	queue_redraw()


## 由外部（受伤、击杀、死亡）累加。1.0 是满强度，多余部分直接夹掉，
## 避免连续受击把 trauma 叠到很大后震个没完。
func add_trauma(amount: float) -> void:
	_trauma = minf(_trauma + amount, 1.0)


## 位移用两个不同频率的正弦叠加而不是每帧 randf()：随机值在 60fps 下会变成高频噪点，
## 看起来像画面撕裂，正弦叠加才有"整块画面被推了一下"的惯性感。
## 但**正弦的频率必须落在 60fps 能表达的范围里**——这一条以前没被当回事，
## 见 SHAKE_HZ 的注释：12~27Hz 的正弦在 60fps 下的采样结果和随机数没有区别。
func _tick_shake(delta: float) -> void:
	if camera == null:
		return
	if _trauma <= 0.0:
		if camera.offset != Vector2.ZERO:
			camera.offset = Vector2.ZERO
		return
	_trauma = maxf(_trauma - TRAUMA_DECAY * delta, 0.0)
	_shake_t += delta * TAU * SHAKE_HZ
	var amp: float = SHAKE_MAX_OFFSET * _trauma * _trauma
	# 死区：屏幕位移不到 1 像素的震动一律不发。这里不做平滑过渡，
	# 因为"逐渐消失到 0"的过程本身就是一段永远停不下来的微抖。
	if amp < SHAKE_DEADZONE:
		if camera.offset != Vector2.ZERO:
			camera.offset = Vector2.ZERO
		return
	# 两个轴用略微不同的倍频（1.0 / 1.19），避免 x、y 同相时走成一条斜直线。
	# 四项之和最大 1.3，乘 0.6 后峰值为 0.78×amp，与旧版 0.8×amp 的力度一致。
	var t: float = _shake_t
	var offset := Vector2(
		sin(t) + sin(t * SHAKE_FINE_MUL) * SHAKE_FINE_WEIGHT,
		cos(t * 1.19) + cos(t * SHAKE_FINE_MUL * 1.05) * SHAKE_FINE_WEIGHT
	) * (amp * 0.6)
	camera.offset = offset


func _move(delta: float) -> void:
	var dir: Vector2 = _input_dir()
	if dir == Vector2.ZERO:
		return
	var to: Vector2 = global_position + dir * move_speed * delta
	# 墙是网格数据不是物理体，位移末尾夹一次：先试完整位移，再试沿轴滑动，能贴墙走
	if maze != null:
		to = maze.constrain(global_position, to, BODY_RADIUS)
	global_position = to


## 走 InputMap（project.godot 的 [input] 段）而不是硬编码键码：
## 换键位、接手柄都不用改这里。get_vector 自带死区与归一化，斜向不会比直线快。
func _input_dir() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_up", "move_down")


func take_damage(amount: float) -> void:
	if health <= 0.0 or _invuln > 0.0:
		return
	_invuln = INVULN_TIME
	_regen_wait = REGEN_DELAY
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
	add_trauma(0.50)
	# 致死的那一下不播受伤音：死亡音效（dead）更长更明确，
	# 两个叠在一起会把"你死了"这个信息糊掉。
	if audio != null:
		audio.play("hurt")


## 圈外（毒）伤害：独立入口，不走 take_damage()。
##
## 两个理由，都是必须的：
## 1. take_damage() 第一行是"无敌帧内直接返回"，而受击无敌 0.45 秒比毒伤 0.5 秒一跳还长。
##    走那个入口的话，被怪贴身打的时候毒伤会被整段吞掉——越是危险的时刻反而越不掉毒血。
## 2. 毒伤不该闪白、不该抖屏、不该给受击无敌。它该做的是"持续、可预期地扣血"，
##    让玩家从血条和红边读出"我得进圈了"，而不是被一阵闪光干扰判断。
##
## 红边由 Game 侧的 hud.set_danger() 负责（血量下降自然变强），这里只改数值。
func take_zone_damage(amount: float) -> void:
	if health <= 0.0 or amount <= 0.0:
		return
	# 毒伤同样算"挨打"：站在圈外还想回血，等于把圈外惩罚抹掉
	_regen_wait = REGEN_DELAY
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_trauma = 0.0
		if camera != null:
			camera.offset = Vector2.ZERO
		died.emit()


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
	var tint: Color = HeroClass.color(hero)
	draw_circle(Vector2.ZERO, BODY_RADIUS, tint)
	draw_arc(Vector2.ZERO, BODY_RADIUS, 0.0, TAU, 24, tint.lightened(0.55), 2.0, true)
	draw_circle(Vector2.ZERO, BODY_RADIUS * 0.45, tint.darkened(0.68))

	if _skill_fx_t > 0.0:
		var progress: float = 1.0 - _skill_fx_t / SKILL_FX_TIME
		var radius: float = _skill_fx_radius * (0.35 + 0.65 * progress)
		var alpha: float = 1.0 - progress
		# 只画一圈扩散的环，不填整片颜色：填满会盖住脚下的敌人和掉落物，
		# 技能放完的那一秒恰好是最需要看清战场的时刻。
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48,
			Color(_skill_fx_color.r, _skill_fx_color.g, _skill_fx_color.b, alpha * 0.9), 3.5, true)
