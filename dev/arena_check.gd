extends SceneTree

## Boss 战清场自检。纯接线断言，不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/arena_check.gd
##
## 覆盖四件事：
##   1. 入场退场：场上 30 只 → 压到 BOSS_ARENA_CAP，且留下的是离玩家最近的那批
##   2. 停刷：Boss 在场时 _spawn_wave 不产怪，刷怪计时已归位（不会战后砸一波）
##   3. 弹的供应：破甲弹走 _tick_breach 独立计时，停刷不会饿死它
##   4. 战后：召唤物全部爆掉（计击杀）、3 秒无敌挂上、呼吸计时开始
##
## 退场是静默移除（不走 take_damage），所以还要断言它**不算击杀**。
##
## 全部断言在同一帧里同步做完：一旦 await 推进物理帧，玩家的自动武器就会
## 把贴脸的小兵打死（开局只有 8 血），"30 只"和"近身 5 只都还在"这两条
## 会被自己的武器证伪——这不是逻辑错，是台架污染。

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	await _run()
	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


func _grunts(game: Node) -> int:
	var n: int = 0
	for enemy in game._enemies:
		if is_instance_valid(enemy) and enemy.kind != Enemy.Kind.BOSS:
			n += 1
	return n


func _minions(game: Node) -> int:
	var n: int = 0
	for enemy in game._enemies:
		if is_instance_valid(enemy) and enemy.minion:
			n += 1
	return n


func _run() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	await process_frame

	print("\n[入场退场]")
	# 5 只贴脸 + 25 只在外圈：退场要留下贴脸那批，远的那批静默消失
	var near_ids: Array[int] = []
	for i in range(5):
		var p: Vector2 = game.player.global_position + Vector2.RIGHT.rotated(TAU * float(i) / 5.0) * 80.0
		game._create_enemy(Enemy.Kind.GRUNT, false, p)
		near_ids.append(game._enemies[game._enemies.size() - 1].get_instance_id())
	for i in range(25):
		var p: Vector2 = game.player.global_position + Vector2.RIGHT.rotated(TAU * float(i) / 25.0) * 260.0
		game._create_enemy(Enemy.Kind.GRUNT, false, p)

	var before: int = _grunts(game)
	_check("摆好 30 只小怪", before == 30, "实际 %d" % before)

	var kills_before_thin: int = game._kills
	game._spawn_boss()

	var after: int = _grunts(game)
	_check("Boss 入场后场上小怪压到上限 %d 只" % game.BOSS_ARENA_CAP,
		after <= game.BOSS_ARENA_CAP, "实际 %d" % after)
	_check("退场是静默的：不算击杀、不给经验", game._kills == kills_before_thin,
		"击杀从 %d 变成 %d" % [kills_before_thin, game._kills])

	var kept: int = 0
	for enemy in game._enemies:
		if is_instance_valid(enemy) and near_ids.has(enemy.get_instance_id()):
			kept += 1
	_check("贴脸那 5 只全部留下（移除的是远处的）", kept == near_ids.size(),
		"%d/%d" % [kept, near_ids.size()])

	print("\n[停刷]")
	_check("Boss 入场后刷怪计时已归位", game._spawn_timer > 0.0,
		"实际 %.3f" % game._spawn_timer)

	var total_before: int = game._enemies.size()
	game._spawn_timer = 0.0
	for i in range(12):
		game._spawn_wave()
	_check("Boss 在场时 _spawn_wave 不产怪", game._enemies.size() == total_before,
		"从 %d 变成 %d" % [total_before, game._enemies.size()])

	print("\n[破甲弹供应]")
	var items_before: int = game._items.size()
	game._breach_timer = game._breach_interval() * game.BREACH_BOSS_FIGHT_SCALE + 0.1
	game._tick_breach(0.0)
	_check("Boss 在场时破甲弹照常掉（不依赖刷怪）",
		game._items.size() == items_before + 1,
		"地上从 %d 变成 %d" % [items_before, game._items.size()])

	print("\n[战后]")
	# 塞 12 只召唤物：Boss 战里一次召唤 4 只、连招三五轮就是这么堆起来的
	for i in range(12):
		var p: Vector2 = game._boss.global_position + Vector2.RIGHT.rotated(TAU * float(i) / 12.0) * 70.0
		game._create_enemy(Enemy.Kind.GRUNT, false, p, true)
	_check("召唤物已打上 minion 标记", _minions(game) == 12, "实际 %d" % _minions(game))

	var kills_before_burst: int = game._kills
	var boss: Enemy = game._boss
	boss.take_damage(1e9, true)

	_check("Boss 死时召唤物全部清除", _minions(game) == 0, "剩 %d" % _minions(game))
	_check("残留小怪不超过上限 %d" % game.BOSS_ARENA_CAP,
		_grunts(game) <= game.BOSS_ARENA_CAP, "实际 %d" % _grunts(game))
	_check("召唤物爆掉计入击杀（走正常死亡路径）",
		game._kills >= kills_before_burst + 12,
		"至少该 +12，实际 %d" % (game._kills - kills_before_burst))
	_check("战后 3 秒无敌已挂上", game.player._invuln >= 2.9,
		"实际 %.2f" % game.player._invuln)
	_check("战后呼吸计时开始（不刷怪）", game._boss_grace >= 2.9,
		"实际 %.2f" % game._boss_grace)
	_check("战后进入挑门状态", game._awaiting_portal == true,
		"awaiting=%s" % str(game._awaiting_portal))
	_check("战后还没换章（等玩家进门）", game._stage_index == 0, "实际 %d" % game._stage_index)

	print("\n[新章密度斜坡]")
	# 现在的换章由"进门"驱动，测试里直接推一章：
	# 密度斜坡本身没变，变的是它被谁触发。
	game._awaiting_portal = false
	game._advance_stage()
	_check("章节开场密度 0.5", is_equal_approx(game._spawn_density(), 0.5),
		"实际 %.2f" % game._spawn_density())
	game._stage_time = Stage.INTRO_TIME * 0.5
	_check("半程 0.75", is_equal_approx(game._spawn_density(), 0.75),
		"实际 %.2f" % game._spawn_density())
	game._stage_time = Stage.INTRO_TIME
	_check("走完回到 1.0", is_equal_approx(game._spawn_density(), 1.0),
		"实际 %.2f" % game._spawn_density())

	# 数量层面也验一次：晚期一波 7 只（WAVE_GROWTH_SECONDS 55），新章开场该只出 4 只
	game._boss_grace = 0.0
	_clear_enemies(game)
	game._elapsed = 350.0
	game._stage_time = 0.0
	game._spawn_wave()
	_check("晚期新章开场每波 4 只（满密度是 7 只）", game._enemies.size() == 4,
		"实际 %d" % game._enemies.size())

	_clear_enemies(game)
	game._stage_time = Stage.INTRO_TIME
	game._spawn_wave()
	_check("斜坡走完后每波回到 7 只", game._enemies.size() == 7,
		"实际 %d" % game._enemies.size())


## 静默清场：不走 take_damage，避免把经验/击杀数与破甲弹卷进断言
func _clear_enemies(game: Node) -> void:
	for enemy in game._enemies.duplicate():
		game._enemies.erase(enemy)
		if is_instance_valid(enemy):
			enemy.queue_free()
