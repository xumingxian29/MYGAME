extends SceneTree

## 属性上限自检：所有乘算属性的加成封在 3 倍以内，且"前面给得多、后面给得少"。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/stat_check.gd
##
## 这里测的是曲线本身 + 真实选卡路径，不测某个具体数值好不好玩：
##   - 曲线：起点斜率 1、渐近 3、严格单调、反解自洽
##   - 选卡：40 张同类卡之后仍 <= 3 倍；第 1 张卡几乎不打折
##   - 计数类（穿透/弹数）不该被曲线管到，它们各自有整数上限

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_curve()
	await _test_cards()
	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


func _test_curve() -> void:
	print("\n[曲线]")
	_check("raw=0 时倍率正好 1.0", is_equal_approx(StatCurve.mult(0.0), 1.0),
		"%.4f" % StatCurve.mult(0.0))
	# 起点斜率 = 1：第一张 +22% 的卡拿到 19.8%（比标称少 2 个点，是曲线本身的弯）。
	# 这 2 个点是有意留的学费：不打这点折，就没有"后段递减"可言。
	var first: float = StatCurve.mult(0.22) - 1.0
	_check("第一张 +22%% 的卡实际给 %.1f%%（>= 19%%，几乎全款）" % (first * 100.0),
		first >= 0.19, "%.4f" % first)

	var prev: float = 0.0
	var monotonic: bool = true
	for i in range(1, 200):
		var raw: float = float(i) * 0.25
		var m: float = StatCurve.mult(raw)
		if m <= prev:
			monotonic = false
		prev = m
	_check("严格单调递增（0 → 50）", monotonic)

	_check("raw=2 时正好 2 倍", is_equal_approx(StatCurve.mult(2.0), 2.0),
		"%.4f" % StatCurve.mult(2.0))
	_check("raw 再大也到不了 3 倍", StatCurve.mult(1000.0) < StatCurve.CAP,
		"%.4f" % StatCurve.mult(1000.0))
	_check("raw 极大时逼近 3 倍（> 2.99）", StatCurve.mult(1000.0) > 2.99,
		"%.4f" % StatCurve.mult(1000.0))
	# 后段递减：从 2 叠到 6 只多 0.5 倍，而从 0 到 2 就拿了 1 倍
	var gain_late: float = StatCurve.mult(6.0) - StatCurve.mult(2.0)
	_check("后段收益明显小于前段（%.2f < 1.0）" % gain_late, gain_late < 1.0,
		"%.4f" % gain_late)
	# 反解自洽
	var need: float = StatCurve.raw_for(2.5)
	_check("raw_for(2.5) 反解回去还是 2.5",
		absf(StatCurve.mult(need) - 2.5) < 0.001, "raw=%.4f → %.4f" % [need, StatCurve.mult(need)])


func _test_cards() -> void:
	print("\n[真实选卡路径]")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	# 射手：远程武器可用，弹道属性有意义
	game._on_menu_started("上限探针", HeroClass.RANGER)
	game.story_enabled = false
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame

	var bullet: BulletWeapon = game.player.bullet_weapon
	var base_damage: float = bullet.damage
	var base_interval: float = bullet.interval
	var base_move: float = game.player.move_speed
	var base_hp: float = game.player.max_health
	_check("出厂值已记录", game._stat_base.has("bullet_damage"))

	# 第 1 张卡：几乎不打折
	game._apply_upgrade({"id": "bullet_damage", "amount": 0.22, "unit": "pct"})
	var after_one: float = bullet.damage
	_check("第 1 张 +22%% 的卡实际提升 %.1f%%" % ((after_one / base_damage - 1.0) * 100.0),
		after_one / base_damage >= 1.19, "%.4f" % (after_one / base_damage))

	# 40 张同类卡：仍然不许越过 3 倍
	for i in range(40):
		game._apply_upgrade({"id": "bullet_damage", "amount": 0.22, "unit": "pct"})
	_check("40 张伤害卡之后 <= 3 倍",
		bullet.damage <= base_damage * 3.0 + 0.001,
		"%.2f / %.2f = %.3f" % [bullet.damage, base_damage, bullet.damage / base_damage])
	# 40 张卡 = raw 8.8 → 2.63 倍。3 倍是个天花板而不是目标：
	# 要摸到 2.99 得 raw ≈ 200（约 900 张卡），实战里永远到不了，
	# 这正是"前面多、后面少"该有的样子——否则封顶就变成"堆够张数就无敌"。
	_check("40 张伤害卡之后落在 2.5~3.0 倍之间",
		bullet.damage / base_damage > 2.5 and bullet.damage / base_damage < 3.0,
		"%.3f" % (bullet.damage / base_damage))

	for i in range(40):
		game._apply_upgrade({"id": "move", "amount": 0.08, "unit": "pct"})
	_check("移速封在 3 倍以内",
		game.player.move_speed <= base_move * 3.0 + 0.001,
		"%.1f / %.1f = %.3f" % [game.player.move_speed, base_move, game.player.move_speed / base_move])

	for i in range(40):
		game._apply_upgrade({"id": "hp", "amount": 0.18, "unit": "pct"})
	_check("生命上限封在 3 倍以内",
		game.player.max_health <= base_hp * 3.0 + 0.001,
		"%.1f / %.1f = %.3f" % [game.player.max_health, base_hp, game.player.max_health / base_hp])
	_check("血不会超过上限", game.player.health <= game.player.max_health + 0.001,
		"%.1f / %.1f" % [game.player.health, game.player.max_health])

	for i in range(40):
		game._apply_upgrade({"id": "bullet_rate", "amount": 0.12, "unit": "pct"})
	_check("射速封在 3 倍（间隔 >= 基础/3）",
		bullet.interval >= base_interval / 3.0 - 0.001,
		"%.4f vs %.4f" % [bullet.interval, base_interval / 3.0])

	# 计数类不受曲线管：它们各自有整数上限
	var pierce0: int = bullet.pierce
	for i in range(3):
		game._apply_upgrade({"id": "bullet_pierce", "amount": 1.0, "unit": "count"})
	_check("穿透 +3（计数类不吃曲线）", bullet.pierce == pierce0 + 3,
		"%d → %d" % [pierce0, bullet.pierce])
	_check("穿透没有进属性账本", not game._stat_raw.has("bullet_pierce"))
