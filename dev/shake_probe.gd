extends SceneTree

## 屏幕震荡探针：从 dev/bot.gd 复制而来，只加"每帧采样相机震动"。
## 目的：量出后期 trauma 被推到多高、偏移多少像素、每秒来回多少次——
## "看着晃" 是主观描述，必须先变成数字才能判断是参数问题还是结构问题。
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
## 单局结果，供最后汇总中位数与死因分布
var _results: Array[Dictionary] = []
## 本局是否出现过毒圈（没有毒圈的版本用来跑基线，列位显示「—」）
var _zone_seen: bool = false

# ---------------- 震荡采样（本文件唯一新增的部分） ----------------
## 当前 30 秒窗口内的采样
var _sh_frames: int = 0
var _sh_trauma_sum: float = 0.0
var _sh_trauma_p95: Array[float] = []
var _sh_off_sum: float = 0.0
var _sh_off_max: float = 0.0
var _sh_sat_frames: int = 0      # trauma >= 0.90 的帧
var _sh_big_frames: int = 0      # 偏移 >= 6 世界单位（≈8 屏幕像素）的帧
var _sh_flips: int = 0           # offset.x 穿过 0 的次数
var _sh_last_sign: float = 0.0
## 每个窗口一行，最后打印成表
var _sh_blocks: Array[Dictionary] = []


func _initialize() -> void:
	_limit = _zone_cap() + 120.0
	# idle（完全不动）作为下限只留两个种子：它必然在 60~80 秒死，多跑几局没有信息量，
	# 却会把"总体中位数"拖到没有意义的低值。实战口径看两个 kite 策略。
	# 种子默认写死，保证回归可复现（同配置两次跑出来的每一局数字都一样）。
	# 但"复现"只能证明没漂移，要拿新的统计口径得换种子：
	#   -- --seeds=21,22,23
	var seeds: Array[int] = SEEDS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seeds="):
			seeds = []
			for t in a.substr(8).split(",", false):
				seeds.append(int(t))
	if seeds.is_empty():
		seeds = SEEDS
	# idle 系列不跑：它 60~80 秒就死，看不到后期震荡
	for s in seeds:
		_runs.append({"strategy": "kite_skill", "seed": s, "hero": HeroClass.WARRIOR, "skill": true})
		_runs.append({"strategy": "kite_ranged", "seed": s, "hero": HeroClass.RANGER, "skill": true})
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		_emit("FAIL 主场景加载失败")
		_flush()
		quit()
		return
	root.add_child(packed.instantiate())


func _process(delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("bot", 0)
		_next_run()
		return false

	if _finished:
		return true

	# 升级暂停：按固定优先级选卡，保证流程不卡住
	if _game._state == 2:
		_game._choose(_pick_card())
		_cards += 1
		return false

	if _game._state == 3:
		_summary("死亡")
		_next_run()
		return false

	if _game._elapsed >= _limit:
		_summary("到时限")
		_next_run()
		return false

	_drive(delta)
	_sample()
	_sample_shake(delta)
	return false


## 采样相机震动。只读，不改任何状态。
## 关注三个数：
##   trauma  — 0~1，平方后进幅度，所以 0.7 已经是"半程以上"的抖动
##   offset  — 世界单位，×1.35 才是屏幕像素（zoom=1.35，实测过）
##   flips/s — 每秒穿过零线多少次，直接反映"振动频率"而不是"一次性冲击"
func _sample_shake(delta: float) -> void:
	if not is_instance_valid(_game) or _game._state != 1:
		return
	var player = _game.player
	if not is_instance_valid(player) or player.camera == null:
		return
	var trauma: float = player._trauma
	var off: Vector2 = player.camera.offset
	var mag: float = off.length()
	_sh_frames += 1
	_sh_trauma_sum += trauma
	_sh_trauma_p95.append(trauma)
	_sh_off_sum += mag
	if mag > _sh_off_max:
		_sh_off_max = mag
	if trauma >= 0.90:
		_sh_sat_frames += 1
	if mag >= 6.0:
		_sh_big_frames += 1
	var sign_now: float = signf(off.x)
	if sign_now != 0.0 and _sh_last_sign != 0.0 and sign_now != _sh_last_sign:
		_sh_flips += 1
	if sign_now != 0.0:
		_sh_last_sign = sign_now


func _drive(delta: float) -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)

	var strategy: String = _strategy()
	if strategy.begins_with("kite"):
		_angle += delta * 1.1
		var dir: Vector2 = Vector2(cos(_angle), sin(_angle)).orthogonal()
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


## 每 30 秒结一次窗口，和 bot 原有的 BLOCK 节奏对齐
func _flush_shake_block() -> void:
	if _sh_frames <= 0:
		return
	var t: float = _game._elapsed
	var sorted: Array[float] = _sh_trauma_p95.duplicate()
	sorted.sort()
	var p95: float = sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)] if not sorted.is_empty() else 0.0
	_sh_blocks.append({
		"t": t,
		"frames": _sh_frames,
		"trauma_mean": _sh_trauma_sum / float(_sh_frames),
		"trauma_p95": p95,
		"sat": float(_sh_sat_frames) / float(_sh_frames),
		"off_mean": _sh_off_sum / float(_sh_frames),
		"off_max": _sh_off_max,
		"big": float(_sh_big_frames) / float(_sh_frames),
		"flips": float(_sh_flips) * 60.0 / float(_sh_frames),
	})
	_sh_frames = 0
	_sh_trauma_sum = 0.0
	_sh_trauma_p95.clear()
	_sh_off_sum = 0.0
	_sh_off_max = 0.0
	_sh_sat_frames = 0
	_sh_big_frames = 0
	_sh_flips = 0
	_sh_last_sign = 0.0


func _sample() -> void:
	var now: float = _game._elapsed
	var alive: int = 0
	var seen: Dictionary = {}
	for enemy in _game._enemies:
		if not is_instance_valid(enemy):
			continue
		alive += 1
		var id: int = enemy.get_instance_id()
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
	_flush_shake_block()
	if not _sh_blocks.is_empty():
		var b: Dictionary = _sh_blocks[-1]
		_emit("      震动 trauma 均=%.2f p95=%.2f 满格=%2.0f%% | 偏移 均=%.1f 峰=%.1f 世界单位(×1.35=%2.0f 像素) >8px占%2.0f%% | 抖动 %.0f Hz" % [
			float(b["trauma_mean"]), float(b["trauma_p95"]), float(b["sat"]) * 100.0,
			float(b["off_mean"]), float(b["off_max"]), float(b["off_max"]) * 1.35,
			float(b["big"]) * 100.0, float(b["flips"]) * 0.5,
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
			_emit("  [Boss] 入场 t=%3d  %s  血=%4.0f  速=%2.0f" % [
				int(now), boss.boss_name, boss.max_health, boss._speed,
			])
		elif _boss_phase == 0 and int(boss._boss_phase_index) == 1:
			_boss_phase = 1
			_emit("  [Boss] 二阶段 t=%3d  剩余 %2.0f%%" % [int(now), boss.health_ratio() * 100.0])
		return
	if _boss_seen:
		_boss_seen = false
		_emit("  [Boss] 结束   t=%3d  （本局累计击杀 Boss %d）" % [int(now), int(_game._boss_kills)])


func _summary(reason: String) -> void:
	_flush_shake_block()
	var hp: float = _game.player.health if is_instance_valid(_game.player) else 0.0
	# 死因由 game._death_cause 给（毒圈致死时是「圈外」，其余是「敌人」）。
	# 到时限还活着 = 没死，单独记一类，否则会混进"敌人"里把分布看歪。
	var cause: String = "未死" if reason == "到时限" else str(_game._death_cause)
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
	_boss_seen = false
	_boss_phase = 0
	_zone_seen = false
	_sh_frames = 0
	_sh_trauma_sum = 0.0
	_sh_trauma_p95.clear()
	_sh_off_sum = 0.0
	_sh_off_max = 0.0
	_sh_sat_frames = 0
	_sh_big_frames = 0
	_sh_flips = 0
	_sh_last_sign = 0.0
	_sh_blocks.clear()
	# 职业必须在 _begin_run 之前写：_spawn_player 在 _ready 里按职业装配武器
	_game._hero = int(run["hero"])
	_game._begin_run()


## 同时写进缓冲和 stdout：一局最长 13 分钟模拟，中途看不到进度就只能干等。
func _emit(line: String) -> void:
	_out.append(line)
	print(line)


func _flush() -> void:
	_emit(_aggregate())
	var f: FileAccess = FileAccess.open("res://.workbuddy/shake_after.txt", FileAccess.WRITE)
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
				_:
					by_enemy += 1
			if bool(r["outside"]):
				ended_outside += 1
		lines.append("%-13s 中位 %5.1fs  最短 %5.1fs  最长 %5.1fs  敌人 %d / 圈外 %d / 未死 %d  终局在圈外 %d" % [
			s, _median(walls), walls.min(), walls.max(), by_enemy, by_zone, never, ended_outside,
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
	return String("\n").join(lines)
