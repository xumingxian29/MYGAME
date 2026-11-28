extends SceneTree

## 迷宫地图自检：纯数据断言，不开画面、不接主游戏。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/maze_check.gd
##
## 覆盖：多 seed 建图、全图连通（BFS 流场覆盖 1.0）、坐标互逆、
## 位移夹紧不穿墙且幂等、流场不指进墙、同 seed 逐格可复现、刷怪落点合法。
## 全连通是最要紧的一条：只要出现一块到不了的地板，Boss 密室就可能刷在里面。

var _pass: int = 0
var _fail: int = 0
var _maps: Array[MazeMap] = []


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


func _make(seed_value: int) -> MazeMap:
	var m := MazeMap.new()
	root.add_child(m)
	m.build(seed_value)
	m.rebuild_flow(m.start_pos())
	_maps.append(m)
	return m


func _run() -> void:
	print("── 多 seed 建图与连通 ──")
	var signatures: Dictionary = {}
	for seed_value in [11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 77, 99]:
		var m: MazeMap = _make(seed_value)
		var rooms_ok: bool = m.room_count() >= 6
		var floor_ok: bool = m.floor_cell_count() > 100
		var coverage: float = m.flow_coverage()
		_check("seed %d 房间数 ≥ 6" % seed_value, rooms_ok, "实际 %d" % m.room_count())
		_check("seed %d 地板格 > 100" % seed_value, floor_ok, "实际 %d" % m.floor_cell_count())
		_check("seed %d 全图连通" % seed_value, is_equal_approx(coverage, 1.0), "覆盖 %.3f" % coverage)
		_check("seed %d 起点/密室都在地板上" % seed_value,
			m.has_floor_at(m.start_pos()) and m.has_floor_at(m.boss_room_pos()))
		var key: String = "%d_%s" % [m.floor_cell_count(), str(m.start_pos())]
		signatures[key] = true
	_check("12 个 seed 至少产出 2 种不同布局", signatures.size() >= 2, "实际 %d 种" % signatures.size())

	print("── 坐标与几何 ──")
	var m: MazeMap = _make(77)
	var samples: Array[Vector2i] = [Vector2i(0, 0), Vector2i(12, 9), Vector2i(23, 17)]
	for c in samples:
		_check("格 %s 的 cell_center / world_to_cell 互逆" % str(c),
			m.world_to_cell(m.cell_center(c)) == c)
	var sc: Vector2i = m.world_to_cell(m.start_pos())
	var bc: Vector2i = m.world_to_cell(m.boss_room_pos())
	var manhattan: int = absi(sc.x - bc.x) + absi(sc.y - bc.y)
	_check("Boss 密室离起点 ≥ 6 格", manhattan >= 6, "实际 %d 格" % manhattan)

	print("── 位移夹紧 ──")
	var from: Vector2 = m.start_pos()
	var probes: Array[Vector2] = [
		from + Vector2(MazeMap.CELL * 4.0, 0.0),
		from + Vector2(-MazeMap.CELL * 6.0, MazeMap.CELL * 3.0),
		from + Vector2(MazeMap.CELL * 2.0, -MazeMap.CELL * 7.0),
		from + Vector2(MazeMap.CELL * 1.0, MazeMap.CELL * 1.0),
	]
	var clamp_ok: bool = true
	for to in probes:
		var landed: Vector2 = m.constrain(from, to, 12.0)
		if m.constrain(from, landed, 12.0) != landed:
			clamp_ok = false
		if not m.has_floor_at(landed):
			clamp_ok = false
	_check("夹紧结果不穿墙且幂等", clamp_ok)

	print("── 流场方向 ──")
	var checked: int = 0
	var bad: int = 0
	for y in range(MazeMap.GRID_H):
		for x in range(MazeMap.GRID_W):
			var c := Vector2i(x, y)
			if not m.is_walkable_cell(c):
				continue
			var d: Vector2 = m.flow_dir(m.cell_center(c))
			if d == Vector2.ZERO:
				continue
			checked += 1
			var ahead: Vector2 = m.cell_center(c) + d * MazeMap.CELL * 0.5
			if not m.has_floor_at(ahead):
				bad += 1
	_check("流场不会把敌人指进墙（检查 %d 格）" % checked, bad == 0, "%d 格越界" % bad)

	print("── 确定性与落点 ──")
	var twin: MazeMap = _make(77)
	_check("同 seed 地板数一致", m.floor_cell_count() == twin.floor_cell_count())
	_check("同 seed 起点一致", m.start_pos() == twin.start_pos())
	_check("同 seed 密室一致", m.boss_room_pos() == twin.boss_room_pos())
	var spawn_ok: bool = true
	for i in range(30):
		var p: Vector2 = m.random_spawn_point(m.start_pos(), 200.0, 900.0)
		var dist: float = p.distance_to(m.start_pos())
		if not m.has_floor_at(p):
			spawn_ok = false
		if p != m.start_pos() and (dist < 200.0 or dist > 900.0):
			spawn_ok = false
	_check("刷怪落点合法且满足距离约束", spawn_ok)

	print("── 运行时夹紧（真实主循环）──")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	await process_frame
	var gm: MazeMap = game.maze
	_check("开局后迷宫节点已建好", gm != null and is_instance_valid(gm))
	if gm != null and is_instance_valid(gm):
		_check("玩家出生在可走格", gm.has_floor_at(game.player.global_position))
		# 让主循环自己刷怪、敌人自己追一段，再看有没有谁嵌进墙里
		for i in range(90):
			await process_frame
		var wall_bad: int = 0
		var live_count: int = 0
		for enemy in game._enemies:
			if not is_instance_valid(enemy):
				continue
			live_count += 1
			if not gm.has_floor_at(enemy.global_position):
				wall_bad += 1
		_check("主循环里 %d 只敌人全在可走格" % live_count, wall_bad == 0, "%d 只嵌墙" % wall_bad)
		_check("主循环推进后玩家仍在可走格", gm.has_floor_at(game.player.global_position))
	game.queue_free()

	for node in _maps:
		node.queue_free()
	await process_frame
