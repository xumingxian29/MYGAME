extends SceneTree

## 攻击不能穿墙自检。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/cross_check.gd
##
## 四条通道分别验：玩家子弹 / 回旋镖 / 近战 / 敌人子弹。
## 判定口径统一是"墙另一侧的目标血量一点都不能掉"——比"弹丸是否消失"更接近玩家感受：
## 弹在墙上炸掉只是表现，真正的 bug 是"隔墙打死了看不见的怪"。

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


## 找一段"可走 - 墙 - 可走"的三连格，四个方向都找。
## 只找水平方向的话，某些种子的墙永远是两格厚，测试就会随机报"没找到"——
## 那种失败是测试自己的问题，不是游戏的。
func _find_wall_gap(maze: MazeMap) -> Dictionary:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	for y in range(2, maze.GRID_H - 2):
		for x in range(2, maze.GRID_W - 2):
			var c := Vector2i(x, y)
			if maze.is_walkable_cell(c):
				continue
			for d in dirs:
				if not maze.is_walkable_cell(c - d):
					continue
				if not maze.is_walkable_cell(c + d):
					continue
				return {
					"before": maze.cell_center(c - d),
					"wall": maze.cell_center(c),
					"after": maze.cell_center(c + d),
					"dir": Vector2(d),
				}
	return {}


func _run() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("穿墙探针", HeroClass.RANGER)
	game.story_enabled = false
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	var maze: MazeMap = game.maze
	_check("开局有迷宫", maze != null)

	var gap: Dictionary = _find_wall_gap(maze)
	_check("找到一段「可走-墙-可走」", not gap.is_empty(),
		"整张图里没有一格墙夹在两块可走格之间")
	if gap.is_empty():
		return
	var before: Vector2 = gap["before"]
	var wall: Vector2 = gap["wall"]
	var after: Vector2 = gap["after"]
	var axis: Vector2 = gap["dir"]

	# 清场：只留测试用的这一只，避免自动索敌把水搅浑
	for e in game._enemies:
		if is_instance_valid(e):
			e.free()
	game._enemies.clear()
	await process_frame

	# 墙后 40 像素放一只，速度归零：它会一直待在墙后面，不会自己挪出来
	game._create_enemy(Enemy.Kind.GRUNT, false, after + axis * 40.0)
	var target: Enemy = game._enemies[game._enemies.size() - 1]
	target._speed = 0.0
	target.global_position = after + axis * 40.0
	target.reset_physics_interpolation()

	print("\n[玩家子弹]")
	var bullet: BulletWeapon = game.player.bullet_weapon
	# 关掉自动开火：射程压到 1，玩家离目标 300 像素，锁不到人
	bullet.attack_range = 1.0
	bullet._shots.clear()
	game.player.global_position = before
	game.player.reset_physics_interpolation()
	await physics_frame

	bullet._shots.append({
		"pos": before, "lpos": Vector2.ZERO, "plpos": Vector2.ZERO,
		"vel": axis * 900.0, "life": 1.4,
		"damage": 5.0, "pierce": 1, "ap": false, "hits": [],
	})
	var hp_before: float = target._health
	for i in range(40):
		await physics_frame
	_check("子弹在墙上消失（没有继续飞到墙后）", bullet._shots.is_empty(),
		"还剩 %d 发" % bullet._shots.size())
	_check("墙后的怪一点血都没掉", is_equal_approx(target._health, hp_before),
		"%.1f → %.1f" % [hp_before, target._health])

	print("\n[敌人子弹]")
	var shot := EnemyShot.new()
	shot.target = game.player
	shot.maze = maze
	shot.velocity = axis * 600.0
	shot.damage = 5.0
	game.world.add_child(shot)
	shot.global_position = before
	shot.reset_physics_interpolation()
	for i in range(30):
		await physics_frame
	_check("敌人子弹撞墙后销毁", not is_instance_valid(shot))

	print("\n[近战]")
	# 战士的武器池才有近战：这里单独造一把挂在 world 上，位置与玩家无关
	var melee := MeleeWeapon.new()
	melee.enemies = game._enemies
	melee.maze = maze
	melee.damage = 20.0
	melee.reach = 320.0
	game.world.add_child(melee)
	melee.global_position = before
	melee.reset_physics_interpolation()
	var hp_melee: float = target._health
	melee._swing_at(target.global_position)
	_check("隔墙挥砍：墙后的怪不掉血", is_equal_approx(target._health, hp_melee),
		"%.1f → %.1f" % [hp_melee, target._health])

	# 把同一只怪挪到没有遮挡的位置：同一把刀必须能砍到，否则上面那条是假通过
	# 挪到同一格里、刀的正后方 40 像素：仍在可走格内（半格 48），没有墙挡
	target.global_position = before - axis * 40.0
	target.reset_physics_interpolation()
	var hp_open: float = target._health
	melee._swing_at(target.global_position)
	_check("无遮挡挥砍：同一把刀能造成伤害", target._health < hp_open - 0.01,
		"%.1f → %.1f" % [hp_open, target._health])
	melee.free()

	print("\n[回旋镖]")
	# 换一只满血的：上一只已经被刀砍死（血量负数），take_damage 会直接返回，
	# 那样测出来的"没掉血"是死亡状态造成的假通过。
	game._create_enemy(Enemy.Kind.GRUNT, false, after + axis * 40.0)
	target = game._enemies[game._enemies.size() - 1]
	target._speed = 0.0
	var boomerang: BoomerangWeapon = game.player.boomerang_weapon
	var hp_r0: float = target._health
	target.global_position = after + axis * 40.0
	target.reset_physics_interpolation()
	boomerang.global_position = before
	boomerang.reset_physics_interpolation()
	boomerang._hit_cd.clear()
	boomerang._resolve_hit(after + axis * 40.0 - before)
	_check("回旋镖穿墙不算命中", is_equal_approx(target._health, hp_r0),
		"%.1f → %.1f" % [hp_r0, target._health])

	# 无遮挡：把镖和镖同一位置放
	boomerang.global_position = target.global_position - axis * 12.0
	boomerang.reset_physics_interpolation()
	boomerang._hit_cd.clear()
	var hp_r1: float = target._health
	boomerang._resolve_hit(axis * 12.0)
	_check("回旋镖无遮挡时能命中", target._health < hp_r1 - 0.01,
		"%.1f → %.1f" % [hp_r1, target._health])

	# 对照组：墙本身确实不可走（防止"这段根本不是墙"导致上面全部假通过）
	_check("对照组：中间那格确实不可走", not maze.has_floor_at(wall))
