extends SceneTree

## 破甲弹自检。纯逻辑 + 接线断言，不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/breach_check.gd
##
## 覆盖五件事：
##   1. 壳的判定：普通伤害打不进 Boss、破甲弹固定伤害、锁定期不连扣
##   2. 破甲窗口：只有窗口里才吃弹，出招/追击期间不扣血也不扣弹
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

	# 没注入 gate 的 Boss 视为没壳：dev/boss_check.gd 直接 new 出来的就是这种
	var bare := _make_boss()
	_check("未注入 gate 时视为没有壳（测试通道不被拦）", bare.breach_gate.is_valid() == false)
	var hp0: float = bare._health
	bare.take_damage(100.0)
	_check("没有壳时普通伤害照常生效", is_equal_approx(bare._health, hp0 - 100.0),
		"剩 %.1f" % bare._health)
	bare.free()

	# 弹尽：gate 返回 false → 免疫
	var boss := _make_boss()
	boss.breach_gate = func() -> bool: return false
	var before: float = boss._health
	boss.take_damage(500.0)
	_check("弹尽时普通伤害被壳挡下", is_equal_approx(boss._health, before),
		"血从 %.1f 变成 %.1f" % [before, boss._health])
	_check("挡下时打冷色闪光（而不是白色掉血闪光）", boss._flash_shell)
	_check("挡下时不计入破甲锁", is_zero_approx(boss._breach_lock_t))

	# 有弹：固定伤害，不吃武器倍率
	var consumed: Array[int] = [0]
	boss.breach_gate = func() -> bool:
		consumed[0] += 1
		return true
	var hp_before: float = boss._health
	boss.take_damage(1e6)
	_check("破甲弹命中 → 伤害等于固定值 %.0f（不是传入的 1e6）" % Enemy.BREACH_HIT_DAMAGE,
		is_equal_approx(boss._health, hp_before - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp_before - boss._health))
	_check("破甲弹命中 → 只消耗一发", consumed[0] == 1, "消耗 %d 次" % consumed[0])
	_check("破甲弹命中 → 进入锁定 %.2fs" % Enemy.BREACH_LOCK_TIME,
		is_equal_approx(boss._breach_lock_t, Enemy.BREACH_LOCK_TIME))

	# 锁定期内：不再扣弹、不再掉血（轨道武器每帧贴身，没有这条会一秒烧掉 60 发）
	var hp_locked: float = boss._health
	boss.take_damage(1e6)
	_check("锁定期内第二次命中：不掉血", is_equal_approx(boss._health, hp_locked),
		"血从 %.1f 变成 %.1f" % [hp_locked, boss._health])
	_check("锁定期内第二次命中：不再扣弹", consumed[0] == 1, "消耗 %d 次" % consumed[0])

	# 锁定期走完：恢复正常吃弹
	boss._tick_flash(Enemy.BREACH_LOCK_TIME + 0.01)
	var hp_after: float = boss._health
	boss.take_damage(1e6)
	_check("锁定结束后重新吃弹", is_equal_approx(boss._health, hp_after - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp_after - boss._health))
	_check("锁定结束后再扣一发", consumed[0] == 2, "累计 %d 次" % consumed[0])

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
	bypass.breach_gate = func() -> bool: return false
	bypass.take_damage(1e9, true)
	_check("bypass_shell 可以直接打死（自检专用通道）", bypass._dead)
	boss.free()


# ---------------------------------------------------------------- 破甲窗口

func _test_vulnerable() -> void:
	print("\n[窗口 · 只有破甲时间吃弹]")
	var boss := _make_boss()
	var consumed: Array[int] = [0]
	boss.breach_gate = func() -> bool:
		consumed[0] += 1
		return true

	boss._boss_state = Enemy.BOSS_STATE_ATTACK
	var hp0: float = boss._health
	boss.take_damage(9999.0)
	_check("出招期间：不掉血", is_equal_approx(boss._health, hp0), "剩 %.1f" % boss._health)
	_check("出招期间：不扣弹（打早了不该罚资源）", consumed[0] == 0, "扣了 %d 发" % consumed[0])
	_check("出招期间：打冷色闪光", boss._flash_shell)
	_check("出招期间：is_vulnerable() 为假", not boss.is_vulnerable())
	_check("出招期间：状态字写「攻击中」", boss.boss_state_text().contains("攻击"))

	boss._boss_state = Enemy.BOSS_STATE_CHASE
	boss._breach_lock_t = 0.0
	boss._flash_shell = false
	var hp1: float = boss._health
	boss.take_damage(9999.0)
	_check("追击期间：同样不掉血", is_equal_approx(boss._health, hp1))
	_check("追击期间：同样不扣弹", consumed[0] == 0, "扣了 %d 发" % consumed[0])

	boss._boss_state = Enemy.BOSS_STATE_VULNERABLE
	boss._breach_lock_t = 0.0
	boss._boss_state_t = 1.2
	var hp2: float = boss._health
	boss.take_damage(9999.0)
	_check("破甲窗口内：掉固定伤害", is_equal_approx(boss._health, hp2 - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp2 - boss._health))
	_check("破甲窗口内：才扣弹", consumed[0] == 1, "扣了 %d 发" % consumed[0])
	_check("破甲窗口内：is_vulnerable() 为真", boss.is_vulnerable())
	_check("状态字带剩余秒数", boss.boss_state_text().begins_with("破甲"),
		"实际「%s」" % boss.boss_state_text())

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
	var fight_total: float = 0.0
	for i in range(Stage.COUNT):
		var st: Dictionary = Stage.at(i)
		var fight: float = float(st["breach_shots"]) * float(st["breach_every"]) * fight_scale
		fight_total += fight
		_check("第 %d 章单场 Boss 约 %.0fs（25~45s）" % [i + 1, fight],
			fight >= 25.0 and fight <= 45.0, "实际 %.1fs" % fight)
	# 时长预算：章节 + 三场 Boss 必须塞得进毒圈，而且要留出余量。
	# 这一条原来写死成「fight_total <= 130」，是"改表即失效"的同一类问题：
	# 圈从 480 压到 304 时它照样报 ok，而实际上根本打不完第三章。
	# 现在两边都从表里读——Stage 的 length 与 Zone 的末段 to，改任一表自动重算。
	var stage_total: float = 0.0
	for i in range(Stage.COUNT):
		stage_total += float(Stage.at(i)["length"])
	var zone_cap: float = float(Zone.SEGMENTS[Zone.SEGMENTS.size() - 1]["to"])
	var slack: float = zone_cap - stage_total - fight_total
	_check("章节 %.0fs + Boss %.0fs = %.0fs，毒圈 %.0fs 余 %.0fs（≥20s）" % [
		stage_total, fight_total, stage_total + fight_total, zone_cap, slack,
	], slack >= 20.0, "余量只有 %.0fs，第三章的 Boss 会在圈归零后出现" % slack)

	# 无尽轮次要更难，且不能把表里缺字段的旧章节拖崩
	var endless: Dictionary = Stage.at(Stage.COUNT)
	_check("无尽轮次的发数高于第三章",
		int(endless["breach_shots"]) > int(Stage.at(Stage.COUNT - 1)["breach_shots"]),
		"%d vs %d" % [int(endless["breach_shots"]), int(Stage.at(Stage.COUNT - 1)["breach_shots"])])


# ---------------------------------------------------------------- 接线

func _test_wiring() -> void:
	print("\n[Game 接线]")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
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
	_check("Boss 已注入破甲判定", boss.breach_gate.is_valid())

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

	# 补一发再打：扣血且弹药 -1。
	# 上一次被挡下不进入锁定，但为了不依赖这条实现细节，这里显式清一次锁。
	game._breach = 3
	boss._breach_lock_t = 0.0
	var hp1: float = boss._health
	boss.take_damage(9999.0)
	_check("有弹时 Boss 掉固定伤害", is_equal_approx(boss._health, hp1 - Enemy.BREACH_HIT_DAMAGE),
		"掉了 %.1f" % (hp1 - boss._health))
	_check("打一发消耗一发", game._breach == 2, "实际 %d" % game._breach)
	_check("Boss 战期间 HUD 同步", game.hud._breach_label.text == "破甲弹 ×2",
		"实际「%s」" % game.hud._breach_label.text)
