extends SceneTree

## 毒圈自检。纯逻辑 + 接线断言，不开画面。
## 用法：godot --headless --path . --script res://dev/zone_probe.gd
##
## 覆盖三件事：
##   1. 时间轴与半径/毒伤数值对不对（表驱动，改动 SEGMENTS 后必须重跑）
##   2. 缩圈不变量：新圈一定完整落在旧圈里（破坏它会出现无解的必死局面）
##   3. 接线：圈外掉血、圈内不掉、无敌帧不吞毒伤、刷怪点落在圈内、致死写对死因

var _pass: int = 0
var _fail: int = 0
## --shots：开窗跑时把圈的几个关键时刻截图，肉眼核对「圈画在哪、HUD 写了什么」
var _want_shots: bool = OS.get_cmdline_user_args().has("--shots")


func _initialize() -> void:
	_test_timeline()
	_test_containment()
	await _test_wiring()
	await _test_shots()
	await _test_lethal()
	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


# ---------------------------------------------------------------- 时间轴

func _test_timeline() -> void:
	print("\n[时间轴·按表校验]")
	var view: float = 545.0
	var segs: Array = Zone.SEGMENTS
	var zone := Zone.new()
	root.add_child(zone)
	zone.reset(view, 11)

	_check("开局半径 = 第一段 r0（%.2fV）" % float(segs[0]["r0"]),
		is_equal_approx(zone.radius, float(segs[0]["r0"]) * view), "实际 %.1f" % zone.radius)
	_check("开局毒伤 = 0", is_zero_approx(zone.dps()))
	_check("开局圈心在原点", zone.center == Vector2.ZERO)

	# 逐段推进到段尾，验半径与毒伤。表驱动：以后调时间轴不用改这个测试。
	var prev_end: float = 0.0
	for i in range(segs.size()):
		var seg: Dictionary = segs[i]
		_advance(zone, float(seg["to"]) - prev_end)
		prev_end = float(seg["to"])
		var want_r: float = float(seg["r1"]) * view
		_check("t=%3.0fs 收到 %.2fV（%.0fpx）" % [float(seg["to"]), float(seg["r1"]), want_r],
			absf(zone.radius - want_r) < 2.0, "实际 %.1f" % zone.radius)
		# 段边界上读到的可能是本段段尾的毒伤，也可能已经切到下一段的台阶值
		# （浮点累加让 "正好 185.0s" 有时落在前一段、有时落在后一段），两个都对
		var end_dps: float = float(seg.get("dps_to", seg["dps"]))
		var next_dps: float = float(segs[i + 1]["dps"]) if i + 1 < segs.size() else end_dps
		_check("t=%3.0fs 毒伤 %.1f%%/s" % [float(seg["to"]), end_dps * 100.0],
			absf(zone.dps() - end_dps) < 0.0002 or absf(zone.dps() - next_dps) < 0.0002,
			"实际 %.4f" % zone.dps())

	# 表本身的自洽性：
	#   半径必须段段相接——断一截就意味着画面上那条紫线会瞬移
	#   毒伤**允许**在段首台阶式上调（那是故意的难度台阶），但只能单调不减
	for i in range(1, segs.size()):
		var a: Dictionary = segs[i - 1]
		var b: Dictionary = segs[i]
		var a_end_dps: float = float(a.get("dps_to", a["dps"]))
		_check("第 %d 段与上一段半径相接" % i, absf(float(a["r1"]) - float(b["r0"])) < 1e-6)
		_check("第 %d 段毒伤不倒退" % i, float(b["dps"]) >= a_end_dps - 1e-6,
			"%.3f → %.3f" % [a_end_dps, float(b["dps"])])
		_check("第 %d 段时间不倒退" % i, float(b["from"]) < float(b["to"]) and float(a["to"]) <= float(b["from"]) + 1e-6)

	var total: float = float(segs[segs.size() - 1]["to"])
	_check("整局上限 %.0fs（%.0f:%02.0f）" % [total, floor(total / 60.0), fmod(total, 60.0)], total > 240.0 and total <= 720.0)
	_check("半径归零后处处是圈外", zone.is_outside(zone.center + Vector2(100, 0)))

	zone.queue_free()


## 一次推进 delta 秒，按 0.1 秒一步——tick 内部是按段插值的，
## 一步跨过整段会把段内过渡直接跳过，测不出"到底是哪一秒收完"。
func _advance(zone: Zone, delta: float) -> void:
	var left: float = delta
	while left > 0.0:
		var step: float = minf(0.1, left)
		zone.tick(step)
		left -= step


# ---------------------------------------------------------------- 缩圈不变量

func _test_containment() -> void:
	print("\n[缩圈不变量：新圈必须完整落在旧圈内]")
	var view: float = 545.0
	var zone := Zone.new()
	root.add_child(zone)
	# 三个种子各跑一遍：圈心方向是随机的，单种子过不代表所有方向都对
	for seed_value in [11, 12, 13]:
		zone.reset(view, int(seed_value))
		var worst: float = 0.0
		var prev_center: Vector2 = zone.center
		var prev_radius: float = zone.radius
		var t: float = 0.0
		while t < 700.0:
			zone.tick(0.1)
			t += 0.1
			# 只在半径明显变小之后比一次（每 0.1 秒都比会算出很多无意义的中间态）
			if prev_radius - zone.radius > 5.0:
				var gap: float = prev_center.distance_to(zone.center) + zone.radius - prev_radius
				worst = maxf(worst, gap)
				prev_center = zone.center
				prev_radius = zone.radius
		_check("seed=%d 全程新圈不越界（最大越界 %.2f px）" % [int(seed_value), worst], worst <= 1.0)


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

	var zone: Zone = game.zone
	var player: Player = game.player
	_check("开局有圈", zone != null and is_instance_valid(zone))
	_check("圈心与玩家起始位置重合", zone.center.distance_to(player.global_position) < 1.0,
		"圈心 %s 玩家 %s" % [zone.center, player.global_position])

	# 圈外掉血
	# 推到第一个"稳定段"中部：那一段 dps 恒定，量出来才好比对
	var stable: Dictionary = Zone.SEGMENTS[2]
	_advance(zone, (float(stable["from"]) + float(stable["to"])) * 0.5)
	var rate: float = float(stable["dps"])
	player.global_position = zone.center + Vector2(zone.radius + 120.0, 0.0)
	var hp0: float = player.health
	# 计时器要先清零：await 期间物理帧已经跑过，残留的零头会让这一跳变成 0.53 秒
	game._zone_dmg_timer = 0.0
	# 一次调用正好攒满 ZONE_TICK，结算一跳；调两次会结算两跳，读数就对不上了
	game._tick_zone(0.5)
	var expect: float = player.max_health * rate * 0.5
	var lost: float = hp0 - player.health
	_check("圈外 0.5 秒掉 %.1f%% 生命（掉 %.2f，期望 %.2f）" % [rate * 100.0, lost, expect], absf(lost - expect) < 0.05)

	# 圈内不掉
	player.global_position = zone.center
	var hp1: float = player.health
	game._tick_zone(0.5)
	_check("圈内不掉血", is_equal_approx(player.health, hp1), "掉了 %.3f" % (hp1 - player.health))

	# 无敌帧不吞毒伤（这是独立入口存在的唯一理由）
	player.set("_invuln", 99.0)
	var hp2: float = player.health
	player.take_zone_damage(12.0)
	_check("无敌帧拦不住毒伤", absf(player.health - (hp2 - 12.0)) < 0.01, "实际 %.2f" % player.health)
	var hp3: float = player.health
	player.take_damage(12.0)
	_check("普通伤害仍被无敌帧拦下（对照组）", is_equal_approx(player.health, hp3))
	player.set("_invuln", 0.0)

	# 刷怪点夹紧
	var limit: float = zone.radius * 1.03
	var far_point: Vector2 = zone.center + Vector2(limit * 3.0, 0.0)
	var clamped: Vector2 = game._clamp_point_into_zone(far_point)
	_check("远到离谱的刷怪点被收进 1.03R", clamped.distance_to(zone.center) <= limit + 0.5,
		"距圈心 %.1f，上限 %.1f" % [clamped.distance_to(zone.center), limit])
	var near_point: Vector2 = zone.center + Vector2(limit * 0.5, 0.0)
	_check("圈内的点保持原样", game._clamp_point_into_zone(near_point).is_equal_approx(near_point))

	_check("HUD 安全区文案非空", game._zone_text(false) != "" and game._zone_text(true).begins_with("圈外"))

	game.queue_free()
	await process_frame


# ---------------------------------------------------------------- 截图

## 只看图不看数：把圈推到 4:00（第一次进屏幕）、7:00（边界在屏幕内）、10:00（终局），
## 各存一张 png。headless 下拿不到帧，必须开窗跑（去掉 --headless）。
## 三个关键时刻：第二次缩完（边界进屏幕）、决战开始、终局中点。
## 从表里取，改时间轴后截图点自动跟着变。
func _shot_times() -> Array:
	var segs: Array = Zone.SEGMENTS
	return [
		float(segs[3]["to"]),
		float(segs[8]["from"]),
		(float(segs[9]["from"]) + float(segs[9]["to"])) * 0.5,
	]


func _test_shots() -> void:
	if not _want_shots:
		return
	print("\n[截图]")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	game.story_enabled = false
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	var zone: Zone = game.zone
	for t in _shot_times():
		_advance(zone, float(t) - zone.elapsed())
		game._update_hud()
		await RenderingServer.frame_post_draw
		var path: String = "res://build/zone_%d.png" % int(t)
		root.get_texture().get_image().save_png(path)
		print("  shot -> ", path, "  R=%.0f dps=%.1f%%" % [zone.radius, zone.dps() * 100.0])
	# 再补一张"人在圈外、圈心已滑出屏幕"的：这张才是方向箭头真正存在的理由
	game.player.global_position = zone.center - Vector2(760.0, 0.0)
	game._update_hud()
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/zone_outside.png")
	print("  shot -> res://build/zone_outside.png  （玩家在圈外，圈心在右前方）")
	game.queue_free()
	await process_frame


# ---------------------------------------------------------------- 致死与死因

func _test_lethal() -> void:
	print("\n[致死]")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	game.story_enabled = false
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame

	var zone: Zone = game.zone
	var player: Player = game.player
	# 终局段起点 + 10 秒：这一段 10%~18%/s，足够把 1 点血烧掉
	_advance(zone, float(Zone.SEGMENTS[Zone.SEGMENTS.size() - 1]["from"]) + 10.0)
	player.global_position = zone.center + Vector2(zone.radius + 200.0, 0.0)
	player.health = 1.0
	game._tick_zone(0.5)
	await process_frame
	_check("圈外能把人毒死", not is_instance_valid(player) or player.health <= 0.0)
	_check("死因记为「圈外」", str(game._death_cause) == "圈外", "实际 %s" % game._death_cause)
	_check("进入结算状态", int(game._state) == 3, "state=%d" % int(game._state))
