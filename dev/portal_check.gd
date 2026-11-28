extends SceneTree

## 传送门 + 楼层难度自检。纯接线断言，不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/portal_check.gd
##
## 覆盖五件事：
##   1. 难度乘数：_floor 每加一层 ×1.10，累乘而不是加法
##   2. Boss 死 → 四扇门：数量、位置可走、彼此不重叠、开门保护期
##   3. 挑门期间停刷停 Boss
##   4. 踩门**不直接传送**：先进确认态，取消后必须走开才允许再问
##   5. 确认 → 发奖励 / 难度 +1 / 换章 / 重建地图 / 清场，且**不回血**
##
## 不看"门画得好不好看"——那是手搓一眼的事。这里只保证规则对。

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


func _run() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	await process_frame

	print("\n[门 → 难度增量]")
	# 四扇门各自带增量，不再是"每层固定 +10%"
	_check("单卡门 +20%", is_equal_approx(Portal.DIFFICULTY[Portal.Reward.CARD], 0.20),
		"%f" % Portal.DIFFICULTY[Portal.Reward.CARD])
	_check("破甲弹门 +40%", is_equal_approx(Portal.DIFFICULTY[Portal.Reward.BREACH], 0.40),
		"%f" % Portal.DIFFICULTY[Portal.Reward.BREACH])
	_check("金币门 +60%", is_equal_approx(Portal.DIFFICULTY[Portal.Reward.GOLD], 0.60),
		"%f" % Portal.DIFFICULTY[Portal.Reward.GOLD])
	_check("双卡门 +100%（最大）", is_equal_approx(Portal.DIFFICULTY[Portal.Reward.CARD2], 1.00),
		"%f" % Portal.DIFFICULTY[Portal.Reward.CARD2])

	print("\n[难度乘数]")
	game._floor = 0
	game._floor_power = 0.0
	_check("第 1 图 = 1.00", is_equal_approx(game._power_scale(), 1.0),
		"%f" % game._power_scale())
	game._floor_power = 0.2
	_check("走一扇单卡门 = 1.20", is_equal_approx(game._power_scale(), 1.2),
		"%f" % game._power_scale())
	# 加法累加：两次 +20% 和一次 +40% 一样难。连乘的话后者会明显更狠，
	# 走三次双卡门直接 ×8，那不是选择，是判死刑。
	game._floor_power = 0.4
	_check("两次 +20% 等于一次 +40%（加法累加）",
		is_equal_approx(game._power_scale(), 1.4), "%f" % game._power_scale())
	game._floor_power = 3.0
	_check("累加没有上限，但速度仍封顶 1.5×",
		absf(minf(game._power_scale(), 1.5) - 1.5) < 0.0001,
		"power=%f" % game._power_scale())

	# 同一时刻、同一章造两只同类怪，唯一变量是难度系数
	game._floor = 0
	game._floor_power = 0.0
	game._create_enemy(Enemy.Kind.GRUNT, false, game.player.global_position + Vector2(600.0, 0.0))
	var base_enemy: Enemy = game._enemies[game._enemies.size() - 1]
	var base_hp: float = base_enemy.max_health
	game._floor = 1
	game._floor_power = 0.2
	game._create_enemy(Enemy.Kind.GRUNT, false, game.player.global_position + Vector2(620.0, 0.0))
	var hard_enemy: Enemy = game._enemies[game._enemies.size() - 1]
	_check("血量吃到 +20%", absf(hard_enemy.max_health - base_hp * 1.2) < 0.01,
		"%.1f → %.1f" % [base_hp, hard_enemy.max_health])
	_check("伤害倍率注入到敌人", is_equal_approx(hard_enemy.power_scale, 1.2),
		"%f" % hard_enemy.power_scale)
	_check("第 1 图的怪不带倍率", is_equal_approx(base_enemy.power_scale, 1.0),
		"%f" % base_enemy.power_scale)

	# 清掉两只探针怪，别让它们干扰后面的数量断言
	for e in game._enemies:
		if is_instance_valid(e):
			e.queue_free()
	game._enemies.clear()
	game._floor = 0
	game._floor_power = 0.0
	await process_frame

	print("\n[Boss 死 → 四扇门]")
	var old_maze_id: int = game.maze.get_instance_id()
	# 关掉升级弹窗：Boss 死会炸出 8 颗宝石，玩家原地一吸就升级，
	# 选卡面板会把整棵场景树暂停——门的 _physics_process 停了，后面所有等待都变成空转。
	game._xp_need = 9999999
	game._card_delay = 99999.0
	game._spawn_boss()
	await process_frame
	var boss: Enemy = game._boss
	_check("Boss 已入场", boss != null and is_instance_valid(boss))
	boss.take_damage(1.0e9, true)
	await process_frame
	_check("没有弹出选卡（台架前提）", paused == false,
		"paused=%s state=%d" % [str(paused), game._state])

	_check("进入挑门状态", game._awaiting_portal == true)
	_check("开了四扇门", game._portals.size() == 4, "实际 %d" % game._portals.size())

	var all_walkable: bool = true
	var min_gap: float = 99999.0
	for i in range(game._portals.size()):
		var p: Portal = game._portals[i]
		if not is_instance_valid(p):
			all_walkable = false
			continue
		if not game.maze.has_floor_at(p.global_position):
			all_walkable = false
		for j in range(i + 1, game._portals.size()):
			var q: Portal = game._portals[j]
			if is_instance_valid(q):
				min_gap = minf(min_gap, p.global_position.distance_to(q.global_position))
	_check("四扇门都在可走格", all_walkable)
	_check("四扇门彼此分开（≥90）", min_gap >= 90.0, "最近 %.1f" % min_gap)

	var rewards: Array[int] = []
	for p in game._portals:
		rewards.append(p.reward)
	rewards.sort()
	_check("四种奖励各一扇", rewards == [
		Portal.Reward.CARD, Portal.Reward.CARD2,
		Portal.Reward.BREACH, Portal.Reward.GOLD,
	], str(rewards))
	_check("战后无敌仍在", game.player._invuln >= 2.5, "%f" % game.player._invuln)

	print("\n[开门保护期]")
	# 保护期从"门生成"开始算，所以这一步必须紧跟在门生成之后。
	var gate: Portal = game._portals[0]
	var gate_pos: Vector2 = gate.global_position
	var floor_before: int = game._floor
	game.player.global_position = gate_pos
	game.player.reset_physics_interpolation()
	for i in range(20):
		await physics_frame
	_check("保护期内不武装", gate._armed == false, "age=%.2f" % gate._age)
	_check("保护期内贴门不触发", game._awaiting_portal == true
		and game._floor == floor_before and game._state == game.State.PLAYING,
		"awaiting=%s floor=%d" % [str(game._awaiting_portal), game._floor])

	print("\n[挑门期间停刷]")
	# 门已经过了保护期，玩家必须先离开门口，否则测的是进门不是停刷。
	# random_spawn_point 挑不到时会退回起点，而起点就在门旁边——
	# 所以取多次采样里离**所有**门最远的那个。
	var away: Vector2 = game.maze.start_pos()
	var away_dist: float = 0.0
	for attempt in range(16):
		var cand: Vector2 = game.maze.random_spawn_point(gate_pos, 300.0, 1200.0)
		var min_d: float = 99999.0
		for p in game._portals:
			if is_instance_valid(p):
				min_d = minf(min_d, cand.distance_to(p.global_position))
		if min_d > away_dist:
			away = cand
			away_dist = min_d
	game.player.global_position = away
	game.player.reset_physics_interpolation()
	_check("测试点离四扇门都足够远", away_dist >= 150.0, "%.1f" % away_dist)
	var before_count: int = game._enemies.size()
	for i in range(60):
		await physics_frame
		if game.player.global_position.distance_to(gate_pos) < 300.0:
			break
	var after_count: int = game._enemies.size()
	_check("挑门期间不产怪", after_count <= before_count,
		"%d → %d" % [before_count, after_count])
	_check("挑门期间不生成 Boss", not is_instance_valid(game._boss))

	print("\n[踩门 → 先确认，不传送]")
	# 推到保护期之后：这里要验的是"解锁后的判定"，不是计时器本身
	gate._age = Portal.ARM_TIME + 0.01
	await physics_frame
	game.player.global_position = gate_pos
	game.player.reset_physics_interpolation()
	var cards_at_ask: int = game._pending_cards
	for i in range(30):
		await physics_frame
		if game._state == game.State.CONFIRM:
			break
	_check("踩门后进入 CONFIRM", game._state == game.State.CONFIRM, "state=%d" % game._state)
	_check("确认面板已开", game.hud._panel.visible == true)
	_check("确认时还没换图", game._map_index == 0 and game.maze.get_instance_id() == old_maze_id,
		"map=%d" % game._map_index)
	_check("确认时还没发卡", game._pending_cards == cards_at_ask)
	_check("踩门后仍然停刷（_awaiting_portal 未被提前清掉）", game._awaiting_portal == true)

	print("\n[取消]")
	game._cancel_portal()
	await process_frame
	_check("取消后回到 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)
	_check("取消后仍在挑门状态", game._awaiting_portal == true)
	_check("门没有被回收", is_instance_valid(gate) and game._portals.has(gate))
	_check("门进入『先走开』状态", gate._leave_gate == true)
	# 站在原地推 40 帧，不能再弹一次
	var re_asked: bool = false
	for i in range(40):
		await physics_frame
		if game._state == game.State.CONFIRM:
			re_asked = true
			break
	_check("站原地不会反复弹面板", re_asked == false)

	print("\n[确认 → 换图]")
	var cards_before: int = game._pending_cards
	var breach_before: int = game._breach
	var gold_before: int = game._gold
	var reward: int = gate.reward
	var gate_id: int = gate.get_instance_id()
	# 绕过 Portal 的 leave_gate 直接发申请（Portal 的判定已在上一步单独验过）
	game.player.global_position = gate_pos
	game.player.reset_physics_interpolation()
	game._on_portal_requested(gate)
	_check("再次踩门又进 CONFIRM", game._state == game.State.CONFIRM, "state=%d" % game._state)
	game._confirm_portal()
	await process_frame
	_check("确认后回到 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)
	_check("门已回收", game._portals.is_empty())
	_check("难度上升一层", game._floor == 1, "实际 %d" % game._floor)
	_check("累计难度 = 这扇门的增量（单卡 +20%）",
		is_equal_approx(game._floor_power, 0.2), "%f" % game._floor_power)
	_check("地图序号 +1", game._map_index == 1, "实际 %d" % game._map_index)
	_check("章节推进一章", game._stage_index == 1, "实际 %d" % game._stage_index)
	_check("换了一张新图", game.maze.get_instance_id() != old_maze_id)
	_check("旧图的敌人已清空", game._enemies.is_empty(), "剩 %d" % game._enemies.size())
	_check("新图也有商人", is_instance_valid(game._merchant))
	_check("玩家落在新起点", game.player.global_position.distance_to(game.maze.start_pos()) < 1.0,
		"%s vs %s" % [str(game.player.global_position), str(game.maze.start_pos())])
	_check("落地点有保护", game.player._invuln >= 1.0, "%f" % game.player._invuln)
	_check("旧门已 free", not is_instance_valid(instance_from_id(gate_id)))

	# 奖励核对：按进门那扇门的类型验一条
	match reward:
		Portal.Reward.CARD:
			# 章节推进本身会 +1 张，门再 +1，所以差 2
			_check("选卡门多给一张卡", game._pending_cards - cards_before == 2,
				"%d → %d" % [cards_before, game._pending_cards])
		Portal.Reward.BREACH:
			_check("选弹门给 3 发破甲弹", game._breach - breach_before == 3,
				"%d → %d" % [breach_before, game._breach])
		Portal.Reward.GOLD:
			_check("金币门给 90 金", game._gold - gold_before == 90,
				"%d → %d" % [gold_before, game._gold])
		Portal.Reward.CARD2:
			_check("双卡门多给两张卡", game._pending_cards - cards_before == 3,
				"%d → %d" % [cards_before, game._pending_cards])
	# 清掉待选卡：不清理的话下一帧 _open_level_up 会把状态切成暂停，
	# 后续断言全部读不到主循环
	game._pending_cards = 0

	print("\n[三种奖励的兑现 + 传送不回血]")
	var breach_at: int = game._breach
	game._grant_portal_reward(Portal.Reward.BREACH)
	_check("BREACH +3", game._breach == breach_at + 3, "%d → %d" % [breach_at, game._breach])

	var gold_at: int = game._gold
	game._grant_portal_reward(Portal.Reward.GOLD)
	_check("GOLD +90", game._gold == gold_at + 90, "%d → %d" % [gold_at, game._gold])

	var cards_at2: int = game._pending_cards
	game._grant_portal_reward(Portal.Reward.CARD2)
	_check("CARD2 +2 张", game._pending_cards == cards_at2 + 2,
		"%d → %d" % [cards_at2, game._pending_cards])
	game._pending_cards = 0

	# 传送不回血：这是这一版明确的设计，必须有一条反向断言钉住它
	game.player.health = game.player.max_health * 0.35
	var hp_at: float = game.player.health
	game._grant_portal_reward(Portal.Reward.GOLD)
	game._grant_portal_reward(Portal.Reward.CARD)
	_check("传送不回血", is_equal_approx(game.player.health, hp_at),
		"%.1f → %.1f" % [hp_at, game.player.health])
	game._pending_cards = 0

	print("\n[新图的怪吃新倍率]")
	game._create_enemy(Enemy.Kind.GRUNT, false, game.player.global_position + Vector2(500.0, 0.0))
	var fresh: Enemy = game._enemies[game._enemies.size() - 1]
	# 走的这扇门是单卡（+20%），所以新图的怪带 1.2×，不再是固定的 1.1×
	_check("第 2 图的怪带 1.2×（这扇门 +20%）", is_equal_approx(fresh.power_scale, 1.2),
		"%f" % fresh.power_scale)
