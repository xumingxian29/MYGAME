extends SceneTree

## 本文件是 dev/bot.gd 的副本，只改了两处：输出到 bot_boss.txt、跑动上限放宽到圈归零 + 10s。
## 原因：另一个进程同时在跑 bot.gd 写 bot.txt，两个进程互相覆盖输出分不清是谁的。

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

## 跑动上限 = 毒圈归零时刻 + 10 秒。这一份只用来量 Boss 战，圈一归零所有人必死，
## 跑更长没有信息量。从 Zone 表读而不是写 480——写死之后圈改成 5:04，
## 这份副本还在按 8:00 空跑，白烧掉一半时间。
var _limit: float = 0.0
const BLOCK: float = 30.0
const SEEDS: Array[int] = [11, 12, 13]

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


func _initialize() -> void:
	for s in SEEDS:
		_runs.append({"strategy": "idle", "seed": s, "hero": HeroClass.WARRIOR, "skill": false})
		_runs.append({"strategy": "idle_skill", "seed": s, "hero": HeroClass.WARRIOR, "skill": true})
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
	return false


func _drive(delta: float) -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)

	var strategy: String = _strategy()
	if strategy.begins_with("kite"):
		_angle += delta * 1.1
		var dir: Vector2 = Vector2(cos(_angle), sin(_angle)).orthogonal()
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
	# 职业必须在 _begin_run 之前写：_spawn_player 在 _ready 里按职业装配武器
	_game._hero = int(run["hero"])
	_game._begin_run()


## 同时写进缓冲和 stdout：一局最长 13 分钟模拟，中途看不到进度就只能干等。
func _emit(line: String) -> void:
	_out.append(line)
	print(line)


func _flush() -> void:
	_emit(_aggregate())
	var f: FileAccess = FileAccess.open("res://.workbuddy/bot_boss.txt", FileAccess.WRITE)
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
## 写死的代价：时间轴从 8:00 改成 5:04 之后，这个数还停在旧值，
## 结果要么整天报"撞上限"，要么白跑几分钟——一个改表就失效的指标比没有指标更坏。
func _zone_cap() -> float:
	var segs: Array = Zone.SEGMENTS
	return float(segs[segs.size() - 1]["to"])


## 汇总表。看三个数：中位存活（目标 5-10 分钟）、最长（不得超过圈归零时间）、
## 圈外死亡占比（目标 15%-35%）。没有毒圈的版本看"最长"就知道现在能拖多久。
func _aggregate() -> String:
	var lines: PackedStringArray = []
	lines.append("")
	lines.append("=== 汇总  n=%d 局  上限 %.0fs ===" % [_results.size(), _limit])
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
	for w in all_wall:
		if w >= _limit - 0.5:
			timeout += 1
	lines.append("总体：中位 %5.1fs  最长 %5.1fs  触及上限 %d 局（上限就是圈归零时刻）" % [
		_median(all_wall), all_wall.max() if not all_wall.is_empty() else 0.0, timeout,
	])
	return String("\n").join(lines)
