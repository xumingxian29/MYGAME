extends SceneTree

## 平衡回归 bot：固定种子 + 固定策略，量化"站桩 vs 绕圈"和成长曲线。
## 只读游戏状态，不改玩法代码；导出预设已排除 dev/*，不会进包。
## 改玩法数值后重跑此脚本对比，别凭手感调平衡。
##
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/bot.gd
##
## 四种策略：
##   idle        不动、不放技能（下限参照）
##   idle_skill  不动、技能好了就放（"轮椅"假设的最坏情况）
##   kite_skill  战士绕圈走位、技能好了就放（近战职业的正常玩法）
##   kite_ranged 射手绕圈走位、技能好了就放（远程职业：验证"Boss 优先索敌"那条路径）
## 必须覆盖远程职业：战士没有远程武器，只用战士测的话子弹相关改动完全测不到。

## 单局模拟上限 = 圈归零时刻 + 120 秒，从 Zone 表里算，不写字面量。
## 写字面量的代价见过两次：圈从 11:30 改到 8:00 之后旧的 780 仍留在代码里，
## 每局都要空跑到 13 分钟才结算，一次回归从 7 分钟变成 13 分钟，人就不想跑了。
## 为什么留 120 秒而不是刚好的归零时刻：
##   1. 圈归零之后还要结算完 0.5 秒一跳的毒伤（~3 秒）
##   2. 要能区分"被圈毒死"和"圈根本没起作用"——两者都撞上限就分不开了
var _limit: float = 780.0
const BLOCK: float = 30.0
## 5 个种子：3 个太少了。实测存活分布是双峰的（战士要么 3 分钟撞上第二只 Boss，
## 要么一路活到圈缩没），3 个种子的"中位数"只等于中间那一局，读不出分布。
const SEEDS: Array[int] = [11, 12, 13, 14, 15]

## 选卡优先级：先把输出来源铺开，再补生存。bot 做固定策略，避免运气影响可比性。
const CARD_PRIORITY: Array[String] = [
	"orbit_unlock", "bullet_damage", "orbit_damage", "orbit_count", "bullet_rate",
	"boomerang_unlock", "boomerang_damage", "melee_damage", "melee_rate",
	"bullet_pierce", "bullet_proj", "orbit_radius", "orbit_speed",
	"boomerang_count", "boomerang_rate", "bullet_range", "boomerang_range",
	"hp", "move", "melee_reach",
]

var _game: Node = null
var _out: PackedStringArray = []
var _runs: Array[Dictionary] = []
var _run_index: int = -1

var _spawn_t: Dictionary = {}
var _life_sum: float = 0.0
var _life_n: int = 0
var _kills_at_block: int = 0
var _blocks_done: int = 0
var _cards: int = 0
var _alive_sum: int = 0
var _alive_frames: int = 0
var _angle: float = 0.0
var _finished: bool = false
var _skills: int = 0
## Boss 事件跟踪：只在状态翻转时打一行，避免每秒刷屏
var _boss_seen: bool = false
var _boss_phase: int = 0
## 上一次打 Boss 状态行的时刻
var _boss_log_t: float = 0.0
## 单局结果，供最后汇总中位数与死因分布
var _results: Array[Dictionary] = []
## 本局是否出现过毒圈（没有毒圈的版本用来跑基线，列位显示「—」）
var _zone_seen: bool = false
## --trace：逐帧打印世界状态指纹，用来判定"同种子两次跑是否逐位一致"。
## 只看结果（存活秒数）无法定位分岔点，必须逐帧对齐才能知道是哪一帧开始不一样。
var _trace: bool = false
var _frame: int = 0
## --rngtrace：把全局 RNG 的抽取值也塞进指纹。
## 每帧固定消耗一次 randi() 不会影响可比性（两遍都一样），但能把
## "某一帧偷偷多消耗了一次 randf" 的错位精确到帧，而不是等到下一次刷怪才显现。
var _rngtrace: bool = false
var _rng_probe: int = 0
## --stop-at=N：跑到第 N 个物理帧就退出，用于快速复现前 30 秒的分岔。
## 独立计数，不复用 _frame（后者只在 --trace 时增长，否则 stop-at 会永远不触发）。
var _stop_at: int = 0
var _tick: int = 0


func _initialize() -> void:
	# 一局完整逃亡 = 十幕（每幕约三分钟）+ 王座厅约三分钟 ≈ 三十三分钟。
	# 跑动上限跟着抬到 2400 秒：上限低了，"逃出"会被统计成"到时限"，
	# 通关率就永远是 0，而这个版本唯一重要的新指标就是通关率。
	# 代价只是"活到最后的局跑得更久"，死得早的局一秒都不多花。
	_limit = maxf(_zone_cap() + 120.0, 2400.0)
	# idle（完全不动）作为下限只留两个种子：它必然在 60~80 秒死，多跑几局没有信息量，
	# 却会把"总体中位数"拖到没有意义的低值。实战口径看两个 kite 策略。
	#
	# 确定性（2026-11-25 修好，此前那段「n=6 分辨不出 20%」的结论已作废）：
	#   · 决策从 _process 迁到 _physics_process：此前 idle 帧会领先/落后物理帧 1~N 帧，
	#     领先量取决于引擎初始化耗时，每个进程不同，输入注入与游戏读输入错开一帧。
	#   · audio.gd 改用私有 RNG：音高抖动原先用全局 randf()，而限流按渲染帧推进，
	#     放行数每进程不同，把玩法随机序列整体推歪。
	#   · 完整 6 局批次连跑两遍：106537 帧逐帧指纹 diff = 0，六局结果逐位相同。
	# 现在同一份构建 + 同一颗种子就是同一局，可以做单种子 A/B，不必硬堆种子数。
	# 注意：修好后 RNG 序列变了，**此前所有历史基线数字不可直接沿用，必须重测**。
	# 要拿新的统计口径就换种子：-- --seeds=21,22,23
	var seeds: Array[int] = SEEDS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seeds="):
			seeds = []
			for t in a.substr(8).split(",", false):
				seeds.append(int(t))
	if seeds.is_empty():
		seeds = SEEDS
	# --only=kite 只跑策略名里含该子串的局。调参时要的是"某一类玩法"的数据，
	# 一局 5 分钟 × 4 策略跑一轮要十几分钟，过滤掉没在改的玩法能省一半以上。
	var only: String = ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	_trace = OS.get_cmdline_user_args().has("--trace")
	_rngtrace = OS.get_cmdline_user_args().has("--rngtrace")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stop-at="):
			_stop_at = int(a.substr(10))
	for s in seeds:
		_runs.append({"strategy": "kite_skill", "seed": s, "hero": HeroClass.WARRIOR, "skill": true})
		_runs.append({"strategy": "kite_ranged", "seed": s, "hero": HeroClass.RANGER, "skill": true})
	_runs.append({"strategy": "idle", "seed": 11, "hero": HeroClass.WARRIOR, "skill": false})
	_runs.append({"strategy": "idle_skill", "seed": 11, "hero": HeroClass.WARRIOR, "skill": true})
	if not only.is_empty():
		var kept: Array[Dictionary] = []
		for r in _runs:
			if str(r["strategy"]).contains(only):
				kept.append(r)
		_runs = kept
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		_emit("FAIL 主场景加载失败")
		_flush()
		quit()
		return
	root.add_child(packed.instantiate())


## 决策必须挂在物理帧，不能挂 idle 帧。
##
## 之前挂在 _process 时，同一份构建 + 同一颗种子跑两遍会分岔（181.5s / 240.9s）。
## 实测 Engine.get_physics_frames() 会领先 get_process_frames() 一到几帧——
## 引擎初始化、加载场景耗掉的墙钟时间决定领先多少，**每个进程不同**。
## bot 在 idle 帧里注入 Input、按 idle delta 累加走位角、按 idle 帧采样，
## 而游戏在物理帧读输入、推进世界：起点错开一帧，整条轨迹就岔了。
## 移到 _physics_process 后，输入注入与游戏读输入同频，delta 恒等于物理步长。
func _process(_delta: float) -> bool:
	return _finished


func _physics_process(delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("bot", 0)
		_game.story_enabled = false
		if _game.story_panel != null and _game.story_panel.is_open():
			_game.story_panel.skip()
		_next_run()
		return false

	if _finished:
		return true

	# 升级暂停：按固定优先级选卡，保证流程不卡住
	if _game._state == 2:
		_game._choose(_pick_card())
		_cards += 1
		return false

	# 传送确认（State.CONFIRM = 5）。台架每次都确认：
	# 不点的话每一局都会停在门口，量到的是"卡在门上的时间"而不是下一张图。
	# 这里用序号而不是 _game.State.CONFIRM：状态是 Game 的内部枚举，
	# bot 通过实例读枚举在 --script 模式下偶尔会拿到未初始化的类。
	if _game._state == 5:
		_game._confirm_portal()
		return false

	# 剧情（State.STORY = 7）。台架一律跳过：剧情是给人看的，
	# 台架要量的是战斗时长，让 bot 一屏一屏点"继续"只会把 10 局变成 40 屏。
	if _game._state == 7:
		if _game.story_panel != null:
			_game.story_panel.skip()
		return false

	# 胜利（State.VICTORY = 8）。走到这里说明这一局通关了，
	# 记一笔"逃出"再开下一局——不然台架会把胜利当成卡死。
	if _game._state == 8:
		_summary("逃出")
		_next_run()
		return false

	# 商店（State.SHOP = 6）。bot 一律只逛不买：
	# 买不买、买什么都是变量，会让 10 局基线不可比；
	# 金币与商店的数值由 dev/shop_check.gd 单独覆盖。
	if _game._state == 6:
		_game._close_shop()
		return false

	if _game._state == 3:
		_summary("死亡")
		_next_run()
		return false

	if _game._elapsed >= _limit:
		_summary("到时限")
		_next_run()
		return false

	_tick += 1
	_drive(delta)
	_sample()
	_trace_frame()
	if _stop_at > 0 and _tick >= _stop_at:
		print("=== stop-at %d 命中，提前退出" % _stop_at)
		quit()
		return true
	return false


## 逐帧世界指纹。刻意用字节序列而不是 "%.6f" 文本：
## 文本格式化会把 1e-7 级的差异抹平，而那正好是分岔的起点。
## 同一份构建 + 同一种子跑两次，两个日志应该在第一个不同的 T 行处分岔；
## 那一帧之前的状态完全一致，就能反推出是哪个函数开始引入不确定性。
func _trace_frame() -> void:
	if not _trace:
		return
	_frame += 1
	if not is_instance_valid(_game.player):
		return
	if _rngtrace:
		# 诊断专用：每帧固定抽一次全局随机数。它本身不参与玩法，
		# 但会让"某帧被别处多抽了一次"立刻体现在下一帧的指纹上。
		_rng_probe = randi()
	var buf: PackedByteArray = PackedByteArray()
	if _rngtrace:
		buf.append_array(var_to_bytes(_rng_probe))
	buf.append_array(var_to_bytes(_game.player.global_position))
	buf.append_array(var_to_bytes(_game.player.health))
	buf.append_array(var_to_bytes(_game._elapsed))
	buf.append_array(var_to_bytes(_game._kills))
	buf.append_array(var_to_bytes(_game._level))
	buf.append_array(var_to_bytes(_game._enemies.size()))
	# 顺手验一条不变量：_enemies 的生成序号必须严格递增。
	# 它成立，数组顺序就等于生成顺序，所有"遍历敌人"的判定顺序才是确定的。
	var ordered: bool = true
	var prev_serial: int = -1
	for e in _game._enemies:
		if not is_instance_valid(e):
			continue
		if e.spawn_serial <= prev_serial:
			ordered = false
		prev_serial = e.spawn_serial
		buf.append_array(var_to_bytes(e.spawn_serial))
		buf.append_array(var_to_bytes(e.global_position))
		buf.append_array(var_to_bytes(e._health))
		buf.append_array(var_to_bytes(e.kind))
	var boss = _game._boss
	if boss != null and is_instance_valid(boss):
		buf.append_array(var_to_bytes(boss.global_position))
		buf.append_array(var_to_bytes(boss._health))
	var digest: String = Marshalls.raw_to_base64(buf).sha256_text().substr(0, 16)
	print("T%06d t=%7.3f %s hp=%7.3f kill=%d lv=%d n=%d %s pf=%d phf=%d" % [
		_frame, _game._elapsed, digest, _game.player.health,
		_game._kills, _game._level, _game._enemies.size(),
		"ord=OK" if ordered else "ord=BAD",
		Engine.get_process_frames(), Engine.get_physics_frames(),
	])


func _drive(delta: float) -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)

	var strategy: String = _strategy()
	if strategy.begins_with("kite"):
		_angle += delta * 1.1
		var dir: Vector2 = Vector2(cos(_angle), sin(_angle)).orthogonal()
		dir = _steer_with_portal(dir.normalized(), delta)
		dir = _steer_with_boss(dir.normalized())
		dir = _steer_with_zone(dir.normalized())
		if dir.x > 0.38:
			Input.action_press("move_right")
		elif dir.x < -0.38:
			Input.action_press("move_left")
		if dir.y > 0.38:
			Input.action_press("move_down")
		elif dir.y < -0.38:
			Input.action_press("move_up")

	if bool(_runs[_run_index]["skill"]) and is_instance_valid(_game.player):
		if _game.player.try_use_skill():
			_skills += 1


## 绕圈路线要受圈约束。真实玩家不会站在毒里继续画圆，也不会等圈缩到脚下才动：
##   圆外      → 直接朝圈心跑
##   0.75R 外  → 切向 + 朝内的合力，边绕边往中间靠
##   还安全     → 原来的纯绕圈
## 不做这一步的话，bot 会在圈外一路画圆到被毒死，量出来的是"bot 有多笨"，
## 而不是"毒圈让一局短了多少"。没有圈的版本 `_zone()` 返回空字典，行为完全不变，
## 所以基线仍然可比。
func _steer_with_zone(dir: Vector2) -> Vector2:
	var info: Dictionary = _zone()
	if info.is_empty() or not is_instance_valid(_game.player):
		return dir
	var to_center: Vector2 = (info["center"] as Vector2) - _game.player.global_position
	var ratio: float = to_center.length() / float(info["radius"])
	if ratio > 1.0:
		return to_center.normalized()
	if ratio > 0.75:
		return (dir + to_center.normalized() * 1.2).normalized()
	return dir


## 门优先于 Boss 和绕圈：Boss 已经倒了，场上没有需要拉扯的东西，
## 唯一该做的就是走进最近的一扇门。bot 不会进门的话，每一局都会卡在
## "Boss 已死但不换图"，台架量出来的是一个静止场景，不是下一关。
##
## 墙是数据不是碰撞体，直线朝门走会贴着墙角滑不出去（实测 t=300 之后
## 场上敌人数恒为 0、血量满格，就是卡住了）。所以加两层兜底：
##   1. 位移不足就侧向试探（绕 63°），再卡就把试探方向翻面
##   2. 挑门超过 3 秒直接把玩家放到门口——这里量的是"进门之后数值对不对"，
##      不是"bot 会不会走迷宫"。真人靠 HUD 箭头和会绕路，不存在这个问题。
var _portal_stuck: float = 0.0
var _portal_wait: float = 0.0
var _portal_last_pos: Vector2 = Vector2.ZERO
var _portal_turn: float = 1.0


func _steer_with_portal(dir: Vector2, delta: float) -> Vector2:
	if not _game._awaiting_portal or _game._portals.is_empty():
		_portal_stuck = 0.0
		_portal_wait = 0.0
		return dir
	if not is_instance_valid(_game.player):
		return dir
	var best: Portal = null
	var best_dist: float = 99999.0
	for p in _game._portals:
		if not is_instance_valid(p):
			continue
		var d: float = p.global_position.distance_to(_game.player.global_position)
		if d < best_dist:
			best = p
			best_dist = d
	if best == null:
		return dir

	var to: Vector2 = best.global_position - _game.player.global_position
	if to.length() < 1.0:
		return Vector2.ZERO
	_portal_wait += delta

	if _portal_last_pos.distance_to(_game.player.global_position) < 12.0:
		_portal_stuck += delta
	else:
		_portal_stuck = 0.0
		_portal_last_pos = _game.player.global_position

	var want: Vector2 = to.normalized()
	if _portal_stuck > 0.5:
		want = want.rotated(_portal_turn * 1.1)
		if _portal_stuck > 1.6:
			_portal_stuck = 0.0
			_portal_turn = -_portal_turn

	if _portal_wait > 3.0 and to.length() > 60.0:
		_game.player.global_position = best.global_position
		_game.player.reset_physics_interpolation()
		_portal_wait = 0.0
		_portal_stuck = 0.0
	return want


## Boss：破甲窗口一开就往它身上贴，窗口外拉远。
## 这条不是为了"让 bot 更强"，是因为 Boss 只在窗口里吃弹——
## bot 不会抓时机的话，量出来的是"bot 有多笨"，而不是"这套机制把 Boss 战拉长了多少"。
## 90 是"贴到武器都在射程内"的距离；320 是"出招时站到冲击波圈外"的距离。
func _steer_with_boss(dir: Vector2) -> Vector2:
	var boss: Enemy = _game._boss
	if boss == null or not is_instance_valid(boss) or not is_instance_valid(_game.player):
		return dir
	var to_boss: Vector2 = boss.global_position - _game.player.global_position
	var dist: float = to_boss.length()
	if dist < 0.001:
		return dir
	if boss.is_vulnerable():
		return to_boss / dist if dist > 70.0 else dir.orthogonal()
	# 出招期间站到 210：贴着冲击波边缘（168）外侧，离得够近，窗口一开两步就能进射程。
	# 原来写 320 是错的——Boss 出招时定身，退到 320 再跑回来要 1 秒多，
	# 3 秒的窗口还没打就结束了，量出来的会是"bot 不会站位"。
	if dist < 210.0:
		return -to_boss / dist
	return dir


func _pick_card() -> int:
	var best: int = 0
	var best_rank: int = 9999
	for i in range(_game._choices.size()):
		var id: String = str(_game._choices[i]["id"])
		var rank: int = CARD_PRIORITY.find(id)
		if rank < 0:
			rank = 500
		if rank < best_rank:
			best_rank = rank
			best = i
	return best


func _strategy() -> String:
	return str(_runs[_run_index]["strategy"])


## 毒圈对外的契约：`radius`（当前半径，像素）+ `center`（圈心世界坐标）。
## 还没实现毒圈的版本这里返回空字典，所有跟圈有关的列显示「—」。
## 摘要里的「圈外死亡占比」是调参核心指标：太低说明圈没起作用，太高说明玩家是被圈逼死的。
func _zone() -> Dictionary:
	if _game == null or not ("zone" in _game):
		return {}
	var zone_node: Node = _game.zone
	if zone_node == null or not is_instance_valid(zone_node):
		return {}
	var radius: float = float(zone_node.get("radius"))
	if radius <= 0.5:
		return {}
	_zone_seen = true
	return {"center": zone_node.get("center"), "radius": radius}


## 玩家到圈心的距离 / 圈半径。> 1 表示在圈外吃毒。没圈时返回 -1。
func _zone_ratio(pos: Vector2, zone_info: Dictionary) -> float:
	if zone_info.is_empty():
		return -1.0
	return pos.distance_to(zone_info["center"]) / float(zone_info["radius"])


func _sample() -> void:
	var now: float = _game._elapsed
	var alive: int = 0
	var seen: Dictionary = {}
	for enemy in _game._enemies:
		if not is_instance_valid(enemy):
			continue
		alive += 1
		# 同样用生成序号而不是 instance_id：id 会被回收，
		# 新怪会顶替死怪的身份，让「平均存活」这个指标把两段寿命算成一段。
		var id: int = enemy.spawn_serial
		seen[id] = true
		if not _spawn_t.has(id):
			_spawn_t[id] = now
	for id in _spawn_t.keys():
		if seen.has(id):
			continue
		_life_sum += now - float(_spawn_t[id])
		_life_n += 1
		_spawn_t.erase(id)

	_alive_sum += alive
	_alive_frames += 1
	_track_boss(now)

	if now < float(_blocks_done + 1) * BLOCK:
		return
	_blocks_done += 1
	var kills: int = _game._kills - _kills_at_block
	_kills_at_block = _game._kills
	var avg_life: float = (_life_sum / float(_life_n)) if _life_n > 0 else 0.0
	var avg_alive: float = float(_alive_sum) / float(maxi(_alive_frames, 1))
	var zr: float = -1.0
	if is_instance_valid(_game.player):
		zr = _zone_ratio(_game.player.global_position, _zone())
	var zone_txt: String = "圈=    —" if zr < 0.0 else "圈=%5.0f%%" % (zr * 100.0)
	_emit("  t=%3d lv=%2d 卡=%2d 杀+%3d 存活=%5.2fs 在场=%5.1f %s 血=%3.0f/%3.0f" % [
		int(now), _game._level, _cards, kills, avg_life, avg_alive, zone_txt,
		_game.player.health, _game.player.max_health,
	])
	_life_sum = 0.0
	_life_n = 0
	_alive_sum = 0
	_alive_frames = 0


## Boss 的三个关键时间点：入场 / 进二阶段 / 结束。
## 这三个数决定 Boss 战节奏——入场太晚没机会见到，结束太晚下一只就要叠上来。
func _track_boss(now: float) -> void:
	var boss: Node = _game._boss
	var alive: bool = boss != null and is_instance_valid(boss)
	if alive:
		if not _boss_seen:
			_boss_seen = true
			_boss_phase = 0
			_boss_log_t = now
			_emit("  [Boss] 入场 t=%3d  %s  血=%4.0f  速=%2.0f" % [
				int(now), boss.boss_name, boss.max_health, boss._speed,
			])
		elif _boss_phase == 0 and int(boss._boss_phase_index) == 1:
			_boss_phase = 1
			_emit("  [Boss] 二阶段 t=%3d  剩余 %2.0f%%" % [int(now), boss.health_ratio() * 100.0])
		# 每 5 秒一行状态：窗口期究竟有没有在输出，看"血% 的下降是否只发生在破甲段"。
		if now - _boss_log_t >= 5.0:
			_boss_log_t = now
			var dist: float = 0.0
			if is_instance_valid(_game.player):
				dist = boss.global_position.distance_to(_game.player.global_position)
			_emit("    t=%3d %-12s 血=%3.0f%% 弹=%2d 地面=%2d 距=%3.0f 己血=%3.0f" % [
				int(now), boss.boss_state_text(), boss.health_ratio() * 100.0,
				int(_game._breach), _game._items.size(), dist,
				_game.player.health if is_instance_valid(_game.player) else 0.0,
			])
		return
	if _boss_seen:
		_boss_seen = false
		_emit("  [Boss] 结束   t=%3d  （本局累计击杀 Boss %d）" % [int(now), int(_game._boss_kills)])


func _summary(reason: String) -> void:
	var hp: float = _game.player.health if is_instance_valid(_game.player) else 0.0
	# 死因由 game._death_cause 给（毒圈致死时是「圈外」，其余是「敌人」）。
	# 到时限还活着 = 没死，单独记一类，否则会混进"敌人"里把分布看歪。
	var cause: String = str(_game._death_cause)
	if reason == "逃出":
		cause = "逃出"
	elif reason == "到时限":
		cause = "未死"
	var zr: float = -1.0
	if is_instance_valid(_game.player):
		zr = _zone_ratio(_game.player.global_position, _zone())
	var zone_note: String = "圈外" if zr > 1.0 else ("圈内" if zr >= 0.0 else "无圈")
	_emit("  → %s：存活 %5.1fs  等级 %2d  卡 %2d  击杀 %3d  Boss %d  技能 %d 次  终血 %3.0f  死因=%s  %s\n" % [
		reason, _game._elapsed, _game._level, _cards, _game._kills, int(_game._boss_kills),
		_skills, hp, cause, zone_note,
	])
	_results.append({
		"strategy": _strategy(),
		"hero": int(_runs[_run_index]["hero"]),
		"wall": _game._elapsed,
		"cause": cause,
		"outside": zr > 1.0,
		"has_zone": zr >= 0.0,
	})
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)


func _next_run() -> void:
	_run_index += 1
	if _run_index >= _runs.size():
		_flush()
		_finished = true
		return
	var run: Dictionary = _runs[_run_index]
	_emit("=== 第 %d 局：%s  %s  seed=%d ===" % [
		_run_index + 1, run["strategy"], HeroClass.NAMES[int(run["hero"])], int(run["seed"]),
	])
	seed(int(run["seed"]))
	_spawn_t.clear()
	_life_sum = 0.0
	_life_n = 0
	_kills_at_block = 0
	_blocks_done = 0
	_cards = 0
	_alive_sum = 0
	_alive_frames = 0
	_angle = 0.0
	_skills = 0
	_frame = 0
	_boss_seen = false
	_boss_phase = 0
	_zone_seen = false
	# 职业必须在 _begin_run 之前写：_spawn_player 在 _ready 里按职业装配武器
	_game._hero = int(run["hero"])
	_game._begin_run()


## 同时写进缓冲和 stdout：一局最长 13 分钟模拟，中途看不到进度就只能干等。
func _emit(line: String) -> void:
	_out.append(line)
	print(line)


func _flush() -> void:
	_emit(_aggregate())
	var f: FileAccess = FileAccess.open("res://.workbuddy/bot.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _out:
		f.store_line(line)
	f.close()


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	if n % 2 == 1:
		return sorted[n / 2]
	return (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5


## 一局的理论上限从 Zone 表里读，不在测试里写死。
## 第一版这里写的是字面量 690.0，时间轴改成 8:00 之后这个指标就永远报 0 了——
## 一个"改表就失效"的断言比没有断言更坏：它看起来还在工作。
func _zone_cap() -> float:
	var segs: Array = Zone.SEGMENTS
	return float(segs[segs.size() - 1]["to"])


## 汇总表。看三个数：中位存活（目标 5-10 分钟）、最长（不得超过圈归零时间）、
## 圈外死亡占比（目标 15%-35%）。没有毒圈的版本看"最长"就知道现在能拖多久。
func _aggregate() -> String:
	var lines: PackedStringArray = []
	lines.append("")
	# 两个"上限"要分开写清楚，否则读表的人会以为跑动上限就是缩圈时间：
	# _limit 只是跑动硬截止（用来区分"撞测试上限"和"被毒死"），圈归零是 _zone_cap()。
	lines.append("=== 汇总  n=%d 局  跑动上限 %.0fs（圈 %.0fs 归零）===" % [
		_results.size(), _limit, _zone_cap(),
	])
	var order: Array[String] = []
	var all_wall: Array[float] = []
	for r in _results:
		var s: String = str(r["strategy"])
		if not order.has(s):
			order.append(s)
		all_wall.append(float(r["wall"]))
	for s in order:
		var walls: Array[float] = []
		var by_enemy: int = 0
		var by_zone: int = 0
		var never: int = 0
		var escaped: int = 0
		var ended_outside: int = 0
		for r in _results:
			if str(r["strategy"]) != s:
				continue
			walls.append(float(r["wall"]))
			match str(r["cause"]):
				"圈外":
					by_zone += 1
				"未死":
					never += 1
				"逃出":
					escaped += 1
				_:
					by_enemy += 1
			if bool(r["outside"]):
				ended_outside += 1
		lines.append("%-13s 中位 %5.1fs  最短 %5.1fs  最长 %5.1fs  敌人 %d / 圈外 %d / 未死 %d / 逃出 %d  终局在圈外 %d" % [
			s, _median(walls), walls.min(), walls.max(), by_enemy, by_zone, never, escaped, ended_outside,
		])
	var timeout: int = 0
	var zone_deaths: int = 0
	var deaths: int = 0
	var over_cap: int = 0
	for r in _results:
		var w: float = float(r["wall"])
		if w >= _limit - 0.5:
			timeout += 1
		# 圈在 _zone_cap() 秒归零，毒伤是 0.5 秒一跳，最后一跳最晚晚 3 秒——
		# 留 10 秒判定余量，否则"正常结算"会被统计成"超时"（上一轮就报了 5 局）。
		if w > _zone_cap() + 10.0:
			over_cap += 1
		if str(r["cause"]) != "未死":
			deaths += 1
			if str(r["cause"]) == "圈外":
				zone_deaths += 1
	var zone_pct: float = 100.0 * float(zone_deaths) / float(maxi(deaths, 1))
	lines.append("总体：中位 %5.1fs  最长 %5.1fs  触及上限 %d 局  超过圈归零（%.0fs）的 %d 局" % [
		_median(all_wall), all_wall.max() if not all_wall.is_empty() else 0.0, timeout, _zone_cap(), over_cap,
	])
	lines.append("死因：圈外致死 %d/%d 局 = %.0f%%（目标 15%%-35%% 之间）" % [zone_deaths, deaths, zone_pct])
	var escaped_total: int = 0
	for r in _results:
		if str(r["cause"]) == "逃出":
			escaped_total += 1
	lines.append("通关：%d/%d 局逃出城堡 = %.0f%%" % [
		escaped_total, _results.size(), 100.0 * float(escaped_total) / float(maxi(_results.size(), 1)),
	])
	return String("\n").join(lines)
