extends SceneTree

## 破甲弹自检。纯逻辑 + 接线断言，不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/breach_check.gd
##
## 覆盖五件事：
##   1. 壳的判定：普通伤害永远打不进 Boss；穿甲弹窗口内满额、窗口外半额并强制开窗
##   2. 破甲窗口：窗口内命中会续窗（有上限），出招/追击期间普通弹打不进
##   3. 循环：追击 → 连招（长、定身、无敌） → 破甲窗口 → 追击
##   4. 配平表：每章"要几发 / 多久掉一枚"单调变难，单场 Boss 时长落在 25~45 秒
##   5. 接线：拾取 +1、HUD 文案、击杀掉弹、Boss 生成时注入 gate
## 逃生通道（bypass_shell）仍然能直接打死，dev 自检全靠它。

var _pass: int = 0
var _fail: int = 0
const DT: float = 1.0 / 60.0


func _initialize() -> void:
	_test_shell()
	_test_vulnerable()
	_test_table()
	await _test_wiring()
	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


## 纯逻辑用例默认把 Boss 摆进破甲窗口：伤害路径的断言不该因为
## "刚好赶上它在出招"而随机失败。"出招时打不进"由 _test_vulnerable 单独断言。
func _make_boss(hp: float = 9999.0, p_kit: int = 0, p_state: int = Enemy.BOSS_STATE_VULNERABLE) -> Enemy:
	var boss := Enemy.new()
	boss.configure_boss(hp, 80.0, "测试", p_kit)
	boss._boss_state = p_state
	return boss


# ---------------------------------------------------------------- 壳的判定

func _test_shell() -> void:
	print("\n[壳 · 伤害判定]")

	# 壳不再由"库存 gate"决定，而是由"这一击是不是穿甲弹"决定。
	# 这样弹在开火时就已经花掉，命中一定有效果——不会出现"打早了白扔"。
	var boss := _make_boss()
	var hp0: float = boss._health
	boss.take_damage(500.0)
	_check("普通伤害被壳挡下（Boss 一点血都不掉）",
		is_equal_approx(boss._health, hp0), "剩 %.1f" % boss._health)
	_check("挡下时打冷色闪光（而不是白色掉血闪光）", boss._flash_shell)
	# 挡下时会开一个 0.35 秒的**闪光节流**（不再是"破甲锁"，只防轨道武器常亮）
	_check("挡下时开 0.35s 闪光节流",
		is_equal_approx(boss._breach_lock_t, 0.35), "%.2f" % boss._breach_lock_t)

	# 窗口内 + 穿甲弹：固定伤害，不吃武器倍率
	var hp1: float = boss._health
	boss.take_damage(1e6, false, true)
	_check("穿甲弹在窗口内 → 伤害等于固定值 %.0f（不是传入的 1e6）"
			% Enemy.BREACH_HIT_DAMAGE,
		is_equal_approx(boss._health, hp1 - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp1 - boss._health))

	# 窗口内命中会"续窗"：把已进入窗口的时长往回拨
	boss._boss_state_t = 1.0
	boss.take_damage(1e6, false, true)
	_check("窗口内命中续 %.1fs" % Enemy.AP_WINDOW_BONUS,
		is_equal_approx(boss._boss_state_t, 1.0 - Enemy.AP_WINDOW_BONUS),
		"%.2f" % boss._boss_state_t)
	boss._boss_state_t = 0.1
	boss.take_damage(1e6, false, true)
	_check("续窗不会把进度打成负数（上限就是窗口长度）",
		boss._boss_state_t >= 0.0, "%.2f" % boss._boss_state_t)

	# 窗口外 + 穿甲弹：半额，但立刻把 Boss 打进破甲
	var outside := _make_boss(9999.0, 0, Enemy.BOSS_STATE_ATTACK)
	var hp2: float = outside._health
	outside.take_damage(1e6, false, true)
	_check("窗口外穿甲弹 → 半额伤害",
		is_equal_approx(outside._health,
			hp2 - Enemy.BREACH_HIT_DAMAGE * Enemy.AP_OPEN_DAMAGE_RATIO),
		"掉了 %.1f" % (hp2 - outside._health))
	_check("窗口外穿甲弹 → 直接把 Boss 打进破甲", outside.is_vulnerable())
	outside.free()

	# 普通小兵不受壳影响
	var grunt := Enemy.new()
	grunt.configure(30.0, 70.0, false, Enemy.Kind.GRUNT)
	var g0: float = grunt._health
	grunt.take_damage(12.0)
	_check("普通小兵不受壳影响", is_equal_approx(grunt._health, g0 - 12.0),
		"剩 %.1f" % grunt._health)
	grunt.free()

	# 逃生通道
	var bypass := _make_boss(100.0)
	bypass.take_damage(1e9, true)
	_check("bypass_shell 可以直接打死（自检专用通道）", bypass._dead)
	boss.free()


# ---------------------------------------------------------------- 破甲窗口

func _test_vulnerable() -> void:
	print("\n[窗口 · 壳只认穿甲弹]")
	var boss := _make_boss()

	boss._boss_state = Enemy.BOSS_STATE_ATTACK
	var hp0: float = boss._health
	boss.take_damage(9999.0)
	_check("出招期间：普通伤害不掉血", is_equal_approx(boss._health, hp0), "剩 %.1f" % boss._health)
	_check("出招期间：打冷色闪光", boss._flash_shell)
	_check("出招期间：is_vulnerable() 为假", not boss.is_vulnerable())
	_check("出招期间：状态字写「攻击中」", boss.boss_state_text().contains("攻击"))

	boss._boss_state = Enemy.BOSS_STATE_CHASE
	boss._breach_lock_t = 0.0
	boss._flash_shell = false
	var hp1: float = boss._health
	boss.take_damage(9999.0)
	_check("追击期间：普通伤害同样不掉血", is_equal_approx(boss._health, hp1))

	# 关键新语义：**即使窗口开着，普通弹也打不进去**。
	# 上一版是"窗口内随便什么武器都能打，只要库存 gate 通过"，
	# 结果是破甲弹本身没有存在感——反正打进去的是同一发子弹。
	boss._boss_state = Enemy.BOSS_STATE_VULNERABLE
	boss._breach_lock_t = 0.0
	boss._flash_shell = false
	var hp2: float = boss._health
	boss.take_damage(9999.0)
	_check("窗口内普通弹仍然打不进（壳只认穿甲弹）",
		is_equal_approx(boss._health, hp2), "掉了 %.1f" % (hp2 - boss._health))
	_check("窗口内普通弹被挡下也闪光", boss._flash_shell)
	_check("破甲窗口内：is_vulnerable() 为真", boss.is_vulnerable())
	_check("状态字带剩余秒数", boss.boss_state_text().begins_with("破甲"),
		"实际「%s」" % boss.boss_state_text())

	# 穿甲弹：同一状态、同一位置，只有这一击是穿甲，结果必须不同
	var hp3: float = boss._health
	boss.take_damage(9999.0, false, true)
	_check("同一窗口内，穿甲弹能打进去（固定伤害）",
		is_equal_approx(boss._health, hp3 - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp3 - boss._health))

	# 状态机时序：追击 → 连招 → 窗口 → 追击，且"连招"必须是一段够长的定身期。
	# 这是用户要的核心手感：出招三秒打不动、窗口几秒才能打。
	var b2 := _make_boss(9999.0, 0, Enemy.BOSS_STATE_CHASE)
	# 出场定身 1.1 秒会挡住第一次状态推进，测时序时先跳过它
	b2.boss_intro_t = 0.0
	var dummy := Node2D.new()
	dummy.global_position = Vector2(600.0, 0.0)
	b2.target = dummy
	var order: Array[int] = []
	var enter_t: Array[float] = []
	var t: float = 0.0
	for i in range(int(30.0 / DT)):
		t += DT
		var to_dummy: Vector2 = dummy.global_position - b2.global_position
		var dist: float = to_dummy.length()
		var dir: Vector2 = to_dummy / dist if dist > 0.001 else Vector2.RIGHT
		b2._tick_boss(DT, dir, dist)
		if order.is_empty() or order[order.size() - 1] != b2._boss_state:
			order.append(b2._boss_state)
			enter_t.append(t)
	_check("30 秒内走完三种状态", order.size() >= 3,
		"只记录了 %d 次切换" % order.size())
	if order.size() >= 3:
		_check("轮转顺序是 追击 → 连招 → 破甲",
			order[0] == Enemy.BOSS_STATE_CHASE and order[1] == Enemy.BOSS_STATE_ATTACK
			and order[2] == Enemy.BOSS_STATE_VULNERABLE,
			"实际 %s" % str(order))
		var attack_len: float = enter_t[2] - enter_t[1]
		_check("连招阶段超过 2 秒（%.1fs）" % attack_len, attack_len >= 2.0,
			"只有 %.2fs，玩家来不及读懂招式" % attack_len)
		var vuln_len: float = enter_t[3] - enter_t[2] if order.size() >= 4 else 0.0
		_check("破甲窗口 %.1fs 与常量一致" % Enemy.BOSS_VULN_TIME,
			absf(vuln_len - Enemy.BOSS_VULN_TIME) <= 0.1, "实际 %.2fs" % vuln_len)
	b2.free()
	dummy.free()

	# 裂地：五处落点、整招跨过 1.6 秒以上、落点在玩家附近
	var b3 := _make_boss(9999.0, 2)
	b3.boss_intro_t = 0.0
	var dummy3 := Node2D.new()
	dummy3.global_position = Vector2(120.0, 0.0)
	b3.target = dummy3
	var points: Array[Vector2] = []
	b3.boss_strike.connect(func(at: Vector2, _r: float) -> void: points.append(at))
	b3._enter_boss_state(Enemy.BOSS_STATE_ATTACK)
	b3._boss_combo = 1
	b3._boss_gap_t = 0.0
	var first_t: float = -1.0
	var last_t: float = 0.0
	var clock: float = 0.0
	for i in range(int(6.0 / DT)):
		clock += DT
		b3._tick_boss(DT, Vector2.RIGHT, 120.0)
		if not points.is_empty():
			if first_t < 0.0:
				first_t = clock
			last_t = clock
	_check("裂地落满 %d 处" % Enemy.BOSS_STRIKE_COUNT, points.size() == Enemy.BOSS_STRIKE_COUNT,
		"实际 %d 处" % points.size())
	_check("裂地整招跨过 1.5 秒（这才叫攻击时间长）", last_t - first_t >= 1.5,
		"只持续了 %.2fs" % (last_t - first_t))
	_check("首处落点在抬手之后（%.2fs）" % Enemy.BOSS_STRIKE_WINDUP, first_t >= Enemy.BOSS_STRIKE_WINDUP - DT)
	if not points.is_empty():
		_check("落点跟着玩家走（不是砸在 Boss 脚下）",
			points[0].distance_to(dummy3.global_position) <= 120.0,
			"落点距玩家 %.0f" % points[0].distance_to(dummy3.global_position))
	b3.free()
	dummy3.free()
	boss.free()


# ---------------------------------------------------------------- 配平表

func _test_table() -> void:
	print("\n[配平 · 章节表驱动]")
	var prev_shots: int = 0
	var prev_every: float = 0.0
	for i in range(Stage.COUNT):
		var st: Dictionary = Stage.at(i)
		var shots: int = int(st["breach_shots"])
		var every: float = float(st["breach_every"])
		_check("第 %d 章 breach_shots 存在（%d 发）" % [i + 1, shots], shots > 0)
		_check("第 %d 章 breach_every 存在（%.1fs）" % [i + 1, every], every > 0.0)
		if i > 0:
			_check("第 %d 章比上一章要更多发（%d > %d）" % [i + 1, shots, prev_shots],
				shots > prev_shots)
			_check("第 %d 章掉率比上一章更慢（%.1f > %.1f）" % [i + 1, every, prev_every],
				every > prev_every)
		prev_shots = shots
		prev_every = every

	# 单场 Boss 战的时长 = 发数 × Boss 战期间的掉率间隔。
	# 这是"一局能不能打完三章"的唯一决定项，必须钉在 25~45 秒：
	#   短于 25 秒，破甲窗口机制还来不及展开（两个窗口就打完了，等于没做）；
	#   长于 45 秒，三场 Boss 会吃掉毒圈给的全部余量。
	# 0.6 从 Game 读而不是写死——bot.gd 曾把圈归零写死成 690，
	# 表一改断言就永远报 0，那种"改表即失效"的校验比没有更坏。
	var fight_scale: float = float(load("res://scripts/game.gd").BREACH_BOSS_FIGHT_SCALE)
	for i in range(Stage.COUNT):
		var st: Dictionary = Stage.at(i)
		var fight: float = float(st["breach_shots"]) * float(st["breach_every"]) * fight_scale
		_check("第 %d 章单场 Boss 约 %.0fs（25~45s）" % [i + 1, fight],
			fight >= 25.0 and fight <= 45.0, "实际 %.1fs" % fight)
	# 时长预算（2026-11-28 重定口径）：毒圈已经不在 world 里，"三章 + 三场 Boss
	# 塞进 390 秒"这条旧断言随之作废——它量的是一个已经不存在的东西。
	# 现在的目标是**每章约三分钟**：一章 = 刷怪 length + 一场 Boss + 挑门与剧情。
	# 一律从表里算，改 length 或改发数都会自动重算这一条。
	const PORTAL_OVERHEAD: float = 12.0
	var run_total: float = 0.0
	for i in range(Story.ACT_COUNT):
		var st: Dictionary = Stage.at(i)
		var fight: float = float(st["breach_shots"]) * float(st["breach_every"]) * fight_scale
		var chapter: float = float(st["length"]) + fight + PORTAL_OVERHEAD
		run_total += chapter
		_check("第 %d 幕约 %.0fs（165~200s，三分钟上下）" % [i + 1, chapter],
			chapter >= 165.0 and chapter <= 200.0, "实际 %.1fs" % chapter)
	# 王座厅：五位守门人 12/14/16/18/20 发 + 四次 2.4 秒的空档，按每发一个窗口算。
	var throne: float = 0.0
	for i in range(Story.gauntlet_count()):
		var shots: int = int(load("res://scripts/game.gd").GAUNTLET_BASE_SHOTS) \
			+ int(load("res://scripts/game.gd").GAUNTLET_SHOT_STEP) * i
		throne += float(shots) * float(load("res://scripts/game.gd").GAUNTLET_BREACH_EVERY)
	throne += float(Story.gauntlet_count() - 1) * float(load("res://scripts/game.gd").GAUNTLET_GAP)
	var run_min: float = (run_total + throne) / 60.0
	_check("一局 %d 幕 + 王座厅约 %.1f 分钟（25~35 分）" % [Story.ACT_COUNT, run_min],
		run_min >= 25.0 and run_min <= 35.0, "实际 %.1f 分钟" % run_min)

	# 第四幕起的发数**不再逐幕上涨**。十幕 + 王座厅的一局里，
	# 每幕 +4 发、掉率每幕慢 0.6 秒，到第 10 幕就是"60 发 × 4.4 秒 = 四分钟一场"，
	# 一场就把整局拖垮。后期的难度交给 Stage.POWER（按幕查表，1.00→2.10），
	# Boss 的血量只由"发数"决定——两条压力不该再叠。
	var endless: Dictionary = Stage.at(Stage.COUNT)
	_check("第四幕的破甲需求与第三章持平",
		int(endless["breach_shots"]) == int(Stage.at(Stage.COUNT - 1)["breach_shots"]),
		"%d vs %d" % [int(endless["breach_shots"]), int(Stage.at(Stage.COUNT - 1)["breach_shots"])])
	# 掉率也不能逐幕变慢：单场时长 = 发数 × 掉率 × 0.6，两个乘数一起涨就是平方。
	_check("第四幕的掉率与第三章持平",
		is_equal_approx(float(endless["breach_every"]),
			float(Stage.at(Stage.COUNT - 1)["breach_every"])),
		"%.2f vs %.2f" % [float(endless["breach_every"]), float(Stage.at(Stage.COUNT - 1)["breach_every"])])
	# 单场时长上限：十幕之后每一场都要落在 25~50 秒，否则一局打不完
	var worst: float = 0.0
	for i in range(Stage.COUNT - 1, 11):
		var shots: int = int(Stage.at(i).get("breach_shots", 12))
		var every: float = float(Stage.at(i).get("breach_every", 4.5))
		worst = maxf(worst, float(shots) * every * 0.6)
	_check("第 3~11 幕的 Boss 单场都不超过 50 秒", worst <= 50.0, "最长 %.1fs" % worst)


# ---------------------------------------------------------------- 接线

func _test_wiring() -> void:
	print("\n[Game 接线]")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	game.story_enabled = false
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame

	_check("开局破甲弹为 0", game._breach == 0)
	_check("开局 HUD 显示 ×0", game.hud._breach_label.text == "破甲弹 ×0",
		"实际「%s」" % game.hud._breach_label.text)

	# 拾取
	game._spawn_breach(game.player.global_position + Vector2(40.0, 0.0))
	await process_frame
	_check("地上的破甲弹被登记", game._items.size() == 1, "实际 %d" % game._items.size())
	var item: ItemModule = game._items[0]
	game._on_item_collected(item)
	_check("拾取后 +1 发", game._breach == 1, "实际 %d" % game._breach)
	_check("拾取后 HUD 跟着变", game.hud._breach_label.text == "破甲弹 ×1",
		"实际「%s」" % game.hud._breach_label.text)

	# 消耗
	_check("消耗一发返回 true", game._consume_breach() == true)
	_check("消耗后归零", game._breach == 0)
	_check("弹尽时返回 false（Boss 会判免疫）", game._consume_breach() == false)
	_check("弹尽不会变成负数", game._breach == 0, "实际 %d" % game._breach)

	# 击杀掉弹：把计时器直接推满，模拟"攒够一个间隔"
	var victim := Enemy.new()
	victim.configure(10.0, 60.0, false, Enemy.Kind.GRUNT)
	victim._health = 0.0
	game.world.add_child(victim)
	game._breach_timer = game._breach_interval() + 0.1
	var items_before: int = game._items.size()
	game._on_enemy_died(victim, 1)
	_check("攒满间隔后击杀会掉一枚", game._items.size() == items_before + 1,
		"实际多了 %d" % (game._items.size() - items_before))
	_check("掉落后计时器扣掉一个间隔（不会连着掉两枚）",
		game._breach_timer < game._breach_interval(), "剩 %.2f" % game._breach_timer)

	# Boss：血量 = 发数 × 单发伤害，且 gate 已注入
	game._spawn_boss()
	await process_frame
	var boss: Enemy = game._boss
	_check("Boss 已生成", boss != null and is_instance_valid(boss))
	var want_hp: float = Enemy.BREACH_HIT_DAMAGE * float(Stage.at(game._stage_index)["breach_shots"])
	_check("Boss 血量 = 发数 × 单发伤害（%.0f）" % want_hp,
		is_equal_approx(boss.max_health, want_hp), "实际 %.0f" % boss.max_health)
	_check("玩家侧已接线破甲弹回调",
		game.player.breach_count.is_valid() and game.player.breach_take.is_valid())
	_check("子弹武器拿到了破甲弹回调",
		game.player.bullet_weapon.breach_count.is_valid()
		and game.player.bullet_weapon.breach_take.is_valid())
	_check("近战武器也拿到了（战士没有远程，靠挥砍花弹）",
		game.player.melee_weapon != null
		and game.player.melee_weapon.breach_count.is_valid())

	# 刚出场是追击阶段：壳完整，打不进也不扣弹
	game._breach = 5
	boss._boss_state = Enemy.BOSS_STATE_CHASE
	boss._breach_lock_t = 0.0
	var hp_chase: float = boss._health
	boss.take_damage(9999.0)
	_check("刚出场（追击阶段）Boss 免疫", is_equal_approx(boss._health, hp_chase),
		"血从 %.1f 变成 %.1f" % [hp_chase, boss._health])
	_check("追击阶段打不进也不扣弹", game._breach == 5, "实际 %d 发" % game._breach)

	# 弹尽时打 Boss：不扣血。
	# 先把手上的弹清零、把地上的弹清掉：上一步掉的那枚会被磁吸在下一帧自动捡走，
	# 不清的话这里测的其实是"手上还有 1 发"，而不是"弹尽"。
	game._items.clear()
	game._breach = 0
	boss._boss_state = Enemy.BOSS_STATE_VULNERABLE
	boss._breach_lock_t = 0.0
	var hp0: float = boss._health
	boss.take_damage(9999.0)
	_check("弹尽时 Boss 免疫普通伤害", is_equal_approx(boss._health, hp0),
		"血从 %.1f 变成 %.1f" % [hp0, boss._health])

	# 补一发再打：走真实路径——武器开火时花一发，然后由穿甲弹造成固定伤害
	game._breach = 3
	boss._boss_state = Enemy.BOSS_STATE_VULNERABLE
	boss._breach_lock_t = 0.0
	var took: bool = game.player.bullet_weapon._take_ap()
	_check("武器开火时花掉一发破甲弹", took and game._breach == 2,
		"took=%s 剩 %d" % [str(took), game._breach])
	_check("Boss 战期间 HUD 同步", game.hud._breach_label.text == "破甲弹 ×2",
		"实际「%s」" % game.hud._breach_label.text)
	var hp1: float = boss._health
	boss.take_damage(9999.0, false, true)
	_check("穿甲弹命中 Boss 掉固定伤害",
		is_equal_approx(boss._health, hp1 - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp1 - boss._health))
