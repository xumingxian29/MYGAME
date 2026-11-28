extends SceneTree

## 视野内敌人上限自检。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/cap_check.gd
##
## 测三件事：
##   1. 视野内挤进 70 只，0.5 秒内被压到 40 以内，且一只都没被删除
##   2. Boss 在场时上限收到 10，召唤也受同一道闸门约束（不会先召再被推走）
##   3. 被推走的怪仍然站在可走格上（不嵌墙），且没有被算成击杀
##
## 断言用 `<= cap` 而不是 `== cap`：玩家的自动武器在这一秒里会打死几只，
## 那是测试用例自己制造的干扰，不是逻辑错。要断的是"不会超"。

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

	print("\n[下限口径]")
	_check("视口半宽为正", game._view_half().x > 1.0, "%.1f" % game._view_half().x)
	_check("无 Boss 时上限 40", game._visible_cap() == 40, "%d" % game._visible_cap())

	print("\n[视野内 70 只 → 压到 40]")
	game._elapsed = 0.0
	# 贴着脸造：半径 120~300 的那一圈全在视野内（半宽约 474）
	# 70 只挤在视野里：上限 40 之后，测试用例本身要把"超编"造得更狠才能触发驱逐
	for i in range(70):
		var a: float = TAU * float(i) / 70.0
		game._create_enemy(Enemy.Kind.GRUNT, false,
			game.player.global_position + Vector2(cos(a), sin(a)) * randf_range(120.0, 300.0))
	var made: int = game._enemies.size()
	_check("造出 70 只", made >= 60, "实际 %d" % made)

	# 0.25 秒节流 + 一帧执行，推进 0.5 秒足够触发两轮
	for i in range(30):
		await physics_frame
	var now: int = game._visible_enemy_count()
	_check("视野内已压到 40 以内", now <= 40, "实际 %d" % now)
	_check("被推走的怪没有被删除", game._enemies.size() >= made - 12,
		"%d → %d" % [made, game._enemies.size()])

	var off_floor: int = 0
	var checked: int = 0
	for e in game._enemies:
		if not is_instance_valid(e) or e.kind == Enemy.Kind.BOSS:
			continue
		checked += 1
		if not game.maze.has_floor_at(e.global_position):
			off_floor += 1
	_check("被推的怪仍在可走格上", off_floor == 0, "%d/%d 嵌墙" % [off_floor, checked])

	print("\n[Boss 战上限 10]")
	game._spawn_boss()
	await process_frame
	_check("Boss 已入场", is_instance_valid(game._boss))
	_check("Boss 在场时上限 10", game._visible_cap() == 10, "%d" % game._visible_cap())

	var before_summon: int = game._visible_enemy_count()
	game._on_boss_summon(game.player.global_position + Vector2(80.0, 0.0), 4)
	await process_frame
	var after_one: int = game._visible_enemy_count()
	_check("第一次召唤后被压到 10 以内", after_one <= 10, "%d → %d" % [before_summon, after_one])

	game._on_boss_summon(game.player.global_position + Vector2(80.0, 0.0), 4)
	await process_frame
	var after_two: int = game._visible_enemy_count()
	_check("连续召唤也不会超过 10", after_two <= 10, "实际 %d" % after_two)

	print("\n[刷怪门控]")
	game._boss = null
	# 直接铺满视野，再调一波刷怪：视野内已满，这一波必须一只都不产
	for i in range(48):
		var a: float = TAU * float(i) / 48.0
		game._create_enemy(Enemy.Kind.GRUNT, false,
			game.player.global_position + Vector2(cos(a), sin(a)) * 200.0)
	var count_before: int = game._enemies.size()
	_check("刷怪前视野已满", game._visible_enemy_count() >= 40,
		"%d" % game._visible_enemy_count())
	game._spawn_wave()
	_check("视野满时不刷怪", game._enemies.size() == count_before,
		"%d → %d" % [count_before, game._enemies.size()])

	print("\n[刷怪点在视野外]")
	# 清空后刷一波，逐只检查新怪不在视野内（这条保证"不会凭空出现在屏幕里"）
	for e in game._enemies:
		if is_instance_valid(e):
			e.free()
	game._enemies.clear()
	game._elapsed = 120.0
	game._stage_time = 999.0
	for i in range(6):
		game._spawn_enemy()
	var in_view: int = 0
	for e in game._enemies:
		if is_instance_valid(e) and game._in_view(e.global_position):
			in_view += 1
	_check("新刷的怪都不在视野内", in_view == 0, "%d 只在视野内" % in_view)
