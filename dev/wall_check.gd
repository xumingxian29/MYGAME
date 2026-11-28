extends SceneTree

## 墙体自检：玩家 / 小怪 / Boss / 掉落物都不能出现在墙里。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/wall_check.gd
##
## 为什么单独拉一份：这类问题不报错、不崩，只是"偶尔有一只怪从墙里钻出来"。
## 靠手玩很难复现，靠台架更看不出来（台架只看存活时长）。
## 这里把"生成点"和"位移结果"两个入口分开断言：
##   生成点错了 → 地图函数（random_spawn_point / nearest_floor_point）的问题
##   位移错了   → 约束（constrain）或夹紧顺序的问题

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


## 随机取一个"墙心"：从全图随机格子里挑不可走的。找不到就返回 null。
func _random_wall(maze: MazeMap, rng: RandomNumberGenerator) -> Variant:
	for i in range(400):
		var c := Vector2i(rng.randi_range(0, maze.GRID_W - 1), rng.randi_range(0, maze.GRID_H - 1))
		if not maze.is_walkable_cell(c):
			return maze.cell_center(c)
	return null


func _run() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261128

	print("\n[地图层：12 个种子]")
	var bad_spawn: int = 0
	var bad_floor: int = 0
	var bad_constrain: int = 0
	var seeds: int = 12
	for i in range(seeds):
		var maze := MazeMap.new()
		root.add_child(maze)
		maze.build(1000 + i)
		var start: Vector2 = maze.start_pos()
		for k in range(16):
			var p: Vector2 = maze.random_spawn_point(start, 300.0, 1200.0)
			if not maze.has_floor_at(p):
				bad_spawn += 1
			var wall: Variant = _random_wall(maze, rng)
			if wall != null:
				var near: Vector2 = maze.nearest_floor_point(wall)
				if not maze.has_floor_at(near):
					bad_floor += 1
				# 从可走点朝墙心硬走 300 像素，身体半径 14 的结果必须还在可走上
				var dir: Vector2 = (near - (wall as Vector2)).normalized()
				if dir == Vector2.ZERO:
					dir = Vector2.RIGHT
				var moved: Vector2 = maze.constrain(near, near - dir * 300.0, 14.0)
				if not maze.has_floor_at(moved):
					bad_constrain += 1
		maze.queue_free()
	_check("random_spawn_point 落点全在可走格（%d 次采样）" % (seeds * 16),
		bad_spawn == 0, "%d 个落进墙里" % bad_spawn)
	_check("nearest_floor_point 对墙心点也能给出可走格",
		bad_floor == 0, "%d 次失败" % bad_floor)
	_check("constrain 撞墙后仍在可走格（半径 14）",
		bad_constrain == 0, "%d 次失败" % bad_constrain)

	print("\n[游戏层：生成点]")
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	await process_frame
	var maze: MazeMap = game.maze
	_check("开局有迷宫", maze != null)

	# 故意把生成点指到墙心：_create_enemy 是唯一的建怪入口，它必须自己夹回来
	var wall_count: int = 0
	var made: int = 0
	for i in range(20):
		var wall: Variant = _random_wall(maze, rng)
		if wall == null:
			continue
		wall_count += 1
		game._create_enemy(Enemy.Kind.GRUNT, false, wall as Vector2)
		made += 1
	await process_frame
	var in_wall: int = 0
	for e in game._enemies:
		if is_instance_valid(e) and not maze.has_floor_at(e.global_position):
			in_wall += 1
	_check("指定墙心造怪 %d 只，全部被夹到可走格" % wall_count,
		made > 0 and in_wall == 0, "%d 只嵌墙" % in_wall)

	print("\n[游戏层：跑 2 秒后没人嵌墙]")
	# 把玩家丢到几个不同的可走点，逼敌人穿过走廊追过来——撞墙最容易在这时暴露
	for round_i in range(4):
		var spot: Vector2 = maze.random_spawn_point(maze.start_pos(), 200.0, 900.0)
		game.player.global_position = spot
		for f in range(30):
			await physics_frame
	var stuck: int = 0
	var sampled: int = 0
	for e in game._enemies:
		if not is_instance_valid(e):
			continue
		sampled += 1
		if not maze.has_floor_at(e.global_position):
			stuck += 1
	_check("追击过程中没有怪进墙（样本 %d）" % sampled,
		stuck == 0, "%d 只嵌墙" % stuck)
	_check("玩家自己在可走格", maze.has_floor_at(game.player.global_position))

	print("\n[游戏层：Boss / 门 / 掉落物]")
	game._spawn_boss()
	await process_frame
	_check("Boss 入场点在可走格",
		is_instance_valid(game._boss) and maze.has_floor_at(game._boss.global_position))
	for f in range(40):
		await physics_frame
	_check("Boss 跑动后仍在可走格",
		is_instance_valid(game._boss) and maze.has_floor_at(game._boss.global_position))

	# 在墙心开门：门的兜底位置与 8 向试探都可能落在墙上
	var portal_wall: Variant = _random_wall(maze, rng)
	if portal_wall != null:
		game._open_portals(portal_wall as Vector2)
		await process_frame
		var off: int = 0
		for p in game._portals:
			if is_instance_valid(p) and not maze.has_floor_at(p.global_position):
				off += 1
		_check("墙心开出的 %d 扇门都在可走格" % game._portals.size(),
			game._portals.size() >= 4 and off == 0, "%d 扇嵌墙" % off)

	var gem_wall: Variant = _random_wall(maze, rng)
	if gem_wall != null:
		game._spawn_gem(gem_wall as Vector2, 1)
		game._spawn_breach(gem_wall as Vector2)
		await process_frame
		var gem_ok: bool = not game._gems.is_empty() \
			and maze.has_floor_at(game._gems[game._gems.size() - 1].global_position)
		var item_ok: bool = not game._items.is_empty() \
			and maze.has_floor_at(game._items[game._items.size() - 1].global_position)
		_check("墙心掉落的宝石被夹到可走格", gem_ok)
		_check("墙心掉落的破甲弹被夹到可走格", item_ok)
