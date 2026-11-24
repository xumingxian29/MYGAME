extends SceneTree

## 单职业伤害来源探针：只读游戏状态，每帧比对血量，把每次掉血连同"当时身边有什么"记下来。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/probe.gd
##
## 为什么不改 Player 加 source 字段：那样测的是"改过的游戏"，而且伤害调用点分散在
## Enemy/EnemyShot 两处。这里用"掉血量 + 邻接敌人构成"反推来源更省事：
##   6 普通接触 / 9 冲锋接触 / 4 吐息接触 / 12 精英接触 / 11 冲锋突刺
##   24 自爆 / 7 吐息弹 / 15 Boss 冲击波 / 18 Boss 接触 / 22 Boss 突刺
## 每次事件记录身边 34px（接触判定半径）内各 Kind 的数量，接触伤害必然有同伴。
## 输出 .workbuddy/probe.txt

const LIMIT: float = 300.0
const SEEDS: Array[int] = [11, 12, 13]
const HERO: int = 2

const KIND_NAMES: Array[String] = ["兵", "冲", "吐", "爆", "王"]

var _game: Node = null
var _out: PackedStringArray = []
var _run: int = -1
var _finished: bool = false
var _angle: float = 0.0

var _last_hp: float = 0.0
var _last_max: float = 0.0
## 本次受击事件 {"t", "dmg", "near", "all", "hp"}
var _events: Array[Dictionary] = []
## 每秒采样行
var _sec: int = 0
var _sec_hp: float = 0.0


func _initialize() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		_out.append("FAIL 主场景加载失败")
		_flush()
		quit()
		return
	root.add_child(packed.instantiate())


func _process(delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("probe", HERO)
		_next_run()
		return false
	if _finished:
		return true

	if _game._state == 2:
		_game._choose(_pick_card())
		return false
	if _game._state == 3:
		_finish_run("死亡")
		_next_run()
		return false
	if _game._elapsed >= LIMIT:
		_finish_run("到时限")
		_next_run()
		return false

	_drive(delta)
	_watch()
	return false


func _drive(delta: float) -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)
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
	if is_instance_valid(_game.player):
		_game.player.try_use_skill()


func _pick_card() -> int:
	const PRIORITY: Array[String] = [
		"orbit_unlock", "bullet_damage", "orbit_damage", "orbit_count", "bullet_rate",
		"boomerang_unlock", "boomerang_damage", "melee_damage", "melee_rate",
		"bullet_pierce", "bullet_proj", "orbit_radius", "orbit_speed",
		"boomerang_count", "boomerang_rate", "bullet_range", "boomerang_range",
		"hp", "move", "melee_reach",
	]
	var best: int = 0
	var best_rank: int = 9999
	for i in range(_game._choices.size()):
		var rank: int = PRIORITY.find(str(_game._choices[i]["id"]))
		if rank < 0:
			rank = 500
		if rank < best_rank:
			best_rank = rank
			best = i
	return best


## 每帧比对血量。只记掉血；回血（升级 / Boss 击杀）单独记一行，避免把回血当成负伤害。
func _watch() -> void:
	var p: Node = _game.player
	if not is_instance_valid(p):
		return
	var hp: float = p.health
	var mx: float = p.max_health
	if _last_hp <= 0.0:
		_last_hp = hp
		_last_max = mx
		return
	if hp > _last_hp + 0.01:
		_out.append("    ↑ 回血 t=%5.1f  %3.0f → %3.0f（上限 %3.0f）" % [_game._elapsed, _last_hp, hp, mx])
	elif hp < _last_hp - 0.01:
		var near: Array[int] = [0, 0, 0, 0, 0]
		var all: int = 0
		var closest: float = 9999.0
		for e in _game._enemies:
			if not is_instance_valid(e) or e.is_queued_for_deletion():
				continue
			all += 1
			var d: float = e.global_position.distance_to(p.global_position)
			closest = minf(closest, d)
			if d <= 34.0:
				near[clampi(e.kind, 0, 4)] += 1
		_events.append({
			"t": _game._elapsed,
			"dmg": _last_hp - hp,
			"near": near,
			"all": all,
			"closest": closest,
			"hp": hp,
		})
	_last_hp = hp
	_last_max = mx

	var now: int = int(_game._elapsed)
	if now > _sec:
		_sec = now
		var near_n: int = 0
		var all_n: int = 0
		var ring: Array[int] = [0, 0, 0, 0, 0]
		for e in _game._enemies:
			if not is_instance_valid(e) or e.is_queued_for_deletion():
				continue
			all_n += 1
			var d: float = e.global_position.distance_to(p.global_position)
			if d <= 120.0:
				near_n += 1
			if d <= 320.0:
				ring[clampi(e.kind, 0, 4)] += 1
		_out.append("  t=%3d lv=%2d 血=%3.0f/%3.0f 在场=%3d 近身120=%2d 环320:%s" % [
			now, _game._level, hp, mx, all_n, near_n, _kind_text(ring),
		])


func _kind_text(counts: Array[int]) -> String:
	var parts: PackedStringArray = []
	for i in range(counts.size()):
		if counts[i] > 0:
			parts.append("%s%d" % [KIND_NAMES[i], counts[i]])
	return "空" if parts.is_empty() else " ".join(parts)


func _finish_run(reason: String) -> void:
	_out.append("  → %s：存活 %5.1fs  Lv.%d  击杀 %d  卡 %d" % [
		reason, _game._elapsed, _game._level, _game._kills, 0,
	])
	# 按掉血量聚合：同一个数值就是同一个来源，直接对上表
	var by_dmg: Dictionary = {}
	var total: float = 0.0
	for ev in _events:
		var key: int = int(round(float(ev["dmg"])))
		if not by_dmg.has(key):
			by_dmg[key] = {"n": 0, "sum": 0.0, "first": float(ev["t"]), "last": float(ev["t"]), "near": 0, "closest": 9999.0}
		var rec: Dictionary = by_dmg[key]
		rec["n"] = int(rec["n"]) + 1
		rec["sum"] = float(rec["sum"]) + float(ev["dmg"])
		rec["last"] = float(ev["t"])
		rec["near"] = int(rec["near"]) + (1 if (ev["near"] as Array)[0] + (ev["near"] as Array)[1] + (ev["near"] as Array)[2] + (ev["near"] as Array)[4] > 0 else 0)
		rec["closest"] = minf(float(rec["closest"]), float(ev["closest"]))
		total += float(ev["dmg"])
	_out.append("     掉血 %d 次，合计 %.0f 点（终血 %.0f）" % [_events.size(), total, _last_hp])
	var keys: Array = by_dmg.keys()
	keys.sort()
	for key in keys:
		var rec: Dictionary = by_dmg[key]
		_out.append("       %2d 点 × %2d 次 = %3.0f 点   首次 %5.1fs 末次 %5.1fs  身边有敌人 %d/%d 次  最近 %4.0fpx" % [
			key, int(rec["n"]), float(rec["sum"]), float(rec["first"]), float(rec["last"]),
			int(rec["near"]), int(rec["n"]), float(rec["closest"]),
		])
	_out.append("")
	_events.clear()


func _next_run() -> void:
	_run += 1
	if _run >= SEEDS.size():
		_flush()
		_finished = true
		return
	_out.append("=== 第 %d 局  %s  seed=%d ===" % [_run + 1, HeroClass.NAMES[HERO], SEEDS[_run]])
	seed(SEEDS[_run])
	_angle = 0.0
	_sec = 0
	_last_hp = 0.0
	_events.clear()
	_game._hero = HERO
	_game._begin_run()


func _flush() -> void:
	var f: FileAccess = FileAccess.open("res://.workbuddy/probe.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _out:
		f.store_line(line)
	f.close()
