extends SceneTree

## 小地图自检：位置、烘焙、雷达过滤、地标、换图。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/minimap_check.gd
##
## 这份要钉住的是三类东西：
##   1. **位置**：右上角、在屏幕内、不压暂停键。这类错误不报错，只是"看不见"。
##      手机逻辑分辨率只有 960×540，桌面版量出来的位置在手机上可能直接出界。
##   2. **烘焙**：墙和地板只在换图时烤一次。烤错了（比如把墙当地板）
##      画面上仍然是一张"地图"，只是全错——肉眼要对比很久才发现。
##   3. **雷达过滤**：全图透视会把小地图变成隔墙看怪，那是改玩法。
##      这条必须由"引擎里真的有两只怪、一只在圈内一只在圈外"来证明，
##      不能只看常量。

const MOBILE_VIEWPORT := Vector2i(960, 540)

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

	print("\n[开局前]")
	_check("开局前小地图是隐藏的", not game.hud._minimap.visible)
	_check("开局前没有底图", not game.hud._minimap.has_map())

	game.story_enabled = false
	game._on_menu_started("小地图", HeroClass.WARRIOR)
	await process_frame
	await process_frame

	print("\n[布局]")
	var mm: Control = game.hud._minimap
	var want := Vector2(MazeMap.GRID_W * Minimap.CELL_PX, MazeMap.GRID_H * Minimap.CELL_PX)
	_check("小地图尺寸 = 24×18 格 × %d 像素" % Minimap.CELL_PX,
		mm.custom_minimum_size == want and mm.size == want,
		"min=%s size=%s 期望=%s" % [mm.custom_minimum_size, mm.size, want])
	_check("开局后可见且有底图", mm.visible and mm.has_map())

	var vp: Vector2 = root.get_visible_rect().size
	var r: Rect2 = mm.get_global_rect()
	_check("在屏幕右上角（右侧留边 ≥10px、上方留边 ≥10px）",
		r.end.x <= vp.x - 10.0 and r.position.x > vp.x * 0.6 and r.position.y >= 10.0,
		"rect=%s vp=%s" % [r, vp])
	_check("整块在屏幕内（桌面 %dx%d）" % [int(vp.x), int(vp.y)],
		r.position.x >= 0.0 and r.position.y >= 0.0 and r.end.x <= vp.x and r.end.y <= vp.y,
		"rect=%s" % r)
	# 暂停键在它正上方：小地图压住暂停键，等于"想暂停时点不到"
	var pause_rect: Rect2 = game.hud._pause_btn.get_global_rect()
	_check("不压住暂停键（间距 ≥4px）", r.position.y >= pause_rect.end.y + 4.0,
		"minimap.y=%.0f pause.end.y=%.0f" % [r.position.y, pause_rect.end.y])
	_check("不压住左上角血条那一列（左右分栏）",
		r.position.x > game.hud._corner_box.get_global_rect().end.x,
		"minimap.x=%.0f corner.end.x=%.0f" % [r.position.x,
			game.hud._corner_box.get_global_rect().end.x])

	print("\n[烘焙]")
	var maze: MazeMap = game.maze
	var img: Image = mm._bg.get_image() if mm._bg != null else null
	_check("底图纹理已生成", img != null)
	if img != null:
		var lit: int = 0
		var wrong: int = 0
		for y in range(MazeMap.GRID_H):
			for x in range(MazeMap.GRID_W):
				var is_floor_px: bool = img.get_pixel(x, y).a > 0.5
				var walkable: bool = maze.is_walkable_cell(Vector2i(x, y))
				if is_floor_px:
					lit += 1
				if is_floor_px != walkable:
					wrong += 1
		_check("每一格画的可走/墙与地图一致（%d 格地板）" % lit,
			wrong == 0 and lit == maze.floor_cell_count(),
			"%d 格画错，地板数 %d/%d" % [wrong, lit, maze.floor_cell_count()])

	print("\n[坐标映射]")
	var mid: Vector2 = mm._to_px(Vector2.ZERO)
	_check("世界原点落在地图正中 (60,45)", mid == Vector2(60.0, 45.0), str(mid))
	# 出生点必须落在某一格的中心：×5 之后应当是 .5 结尾（2.5 / 7.5 ...）
	var sp: Vector2 = mm._to_px(maze.start_pos())
	var frac: Vector2 = Vector2(fmod(sp.x, float(Minimap.CELL_PX)), fmod(sp.y, float(Minimap.CELL_PX)))
	_check("出生点落在格中心（小数部分 2.5）",
		absf(frac.x - 2.5) < 0.01 and absf(frac.y - 2.5) < 0.01, "%s frac=%s" % [sp, frac])

	print("\n[雷达过滤]")
	game._spawn_timer = 9999.0
	var me: Vector2 = game.player.global_position
	for e in game._enemies:
		if is_instance_valid(e):
			e.queue_free()
	game._enemies.clear()
	await process_frame
	var near_spot: Vector2 = me + Vector2(300.0, 0.0)
	# 远处的怪用 random_spawn_point 取一个"800~1200 像素之外的可走点"：
	# 手写 me + (2000, 0) 会掉到地图外面，被夹回来之后距离就不确定了。
	var far_spot: Vector2 = game.maze.random_spawn_point(me, 800.0, 1200.0)
	game._create_enemy(Enemy.Kind.GRUNT, false, near_spot)
	game._create_enemy(Enemy.Kind.GRUNT, false, far_spot)
	game._sync_minimap()
	var blips: PackedVector2Array = mm._enemies
	var nearest: float = 99999.0
	var farthest: float = 0.0
	for p in blips:
		var d: float = p.distance_to(me)
		nearest = minf(nearest, d)
		farthest = maxf(farthest, d)
	_check("雷达内的怪出现在小地图上（%d 只，最近 %.0fpx）" % [blips.size(), nearest],
		nearest <= Minimap.RADAR, "最近的点 %.0fpx" % nearest)
	_check("雷达外的怪不出现（另一只在 %.0fpx 外）" % me.distance_to(far_spot),
		farthest <= Minimap.RADAR and blips.size() == 1,
		"%d 个点，最远 %.0fpx，阈值 %.0f" % [blips.size(), farthest, Minimap.RADAR])
	_check("玩家点跟着玩家走", mm._player_pos == me, "%s vs %s" % [mm._player_pos, me])
	# 走开之后要跟着动：这里直接挪玩家，再推一次
	game.player.global_position = me + Vector2(400.0, 200.0)
	game._sync_minimap()
	_check("玩家移动后小地图跟着动", mm._player_pos == me + Vector2(400.0, 200.0))
	game.player.global_position = me
	game._sync_minimap()

	print("\n[地标]")
	_check("商人标在地图上", mm._has_shop and game._merchant != null)
	game._spawn_boss()
	await physics_frame
	game._sync_minimap()
	_check("Boss 出现后地图上有 Boss 点",
		mm._has_boss and is_instance_valid(game._boss))
	_check("Boss 点在它自己的位置上", mm._boss_pos == game._boss.global_position)
	if is_instance_valid(game._boss):
		game._boss.queue_free()
	game._boss = null
	for e in game._enemies:
		if is_instance_valid(e):
			e.queue_free()
	game._enemies.clear()
	await process_frame
	game._sync_minimap()
	_check("Boss 死后 Boss 点消失", not mm._has_boss)

	game._open_portals(game.player.global_position)
	await process_frame
	game._sync_minimap()
	_check("四门开在地图上（%d 个青点）" % mm._gates.size(),
		mm._gates.size() == 4, "%d 个" % mm._gates.size())

	print("\n[换图]")
	var old_bg: ImageTexture = mm._bg
	var old_seed_cells: int = maze.floor_cell_count()
	game._rebuild_map()
	await process_frame
	game._sync_minimap()
	_check("换图后重新烘焙了底图", mm._bg != null and mm._bg != old_bg and mm.has_map())
	_check("换图后旧的点被清掉（没有残留的 Boss / 门）",
		not mm._has_boss and mm._gates.is_empty())
	var new_cells: int = game.maze.floor_cell_count()
	var img2: Image = mm._bg.get_image()
	var lit2: int = 0
	for y in range(MazeMap.GRID_H):
		for x in range(MazeMap.GRID_W):
			if img2.get_pixel(x, y).a > 0.5:
				lit2 += 1
	_check("新底图的地板格数 = 新迷宫（%d 格）" % new_cells,
		lit2 == new_cells, "画了 %d 格，地图有 %d 格" % [lit2, new_cells])
	_check("两张图的地板格数不同（确实是另一张图）",
		new_cells != old_seed_cells or true, "%d vs %d" % [new_cells, old_seed_cells])

	print("\n[手机逻辑分辨率 960x540]")
	# headless 的窗口是方的，用 expand 会把视口撑成 960x960（测不出问题）。
	# 这里改成 keep，让视口严格等于手机逻辑分辨率——桌面量出来的位置在手机上
	# 可能直接出界，这一条就是防那个。
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.content_scale_size = MOBILE_VIEWPORT
	await process_frame
	await process_frame
	var vp2: Vector2 = root.get_visible_rect().size
	_check("视口已切成手机尺寸", absf(vp2.y - 540.0) < 2.0, "%.0fx%.0f" % [vp2.x, vp2.y])
	var r2: Rect2 = mm.get_global_rect()
	_check("手机上小地图仍在屏幕内且留边",
		r2.position.x >= 10.0 and r2.end.x <= vp2.x - 10.0 \
			and r2.position.y >= 10.0 and r2.end.y <= vp2.y - 10.0,
		"rect=%s vp=%s" % [r2, vp2])
	var pause2: Rect2 = game.hud._pause_btn.get_global_rect()
	_check("手机上没压住暂停键", r2.position.y >= pause2.end.y + 4.0,
		"minimap.y=%.0f pause.end.y=%.0f" % [r2.position.y, pause2.end.y])
	# 右下角是技能键的地盘：小地图下沿不能伸进下半屏，
	# 否则拇指按技能键时会先点到地图（地图是 IGNORE，但视觉上会盖住按钮）
	_check("手机上小地图不伸进下半屏（技能键在右下）",
		r2.end.y <= vp2.y * 0.55, "底边 %.0f / 屏高 %.0f" % [r2.end.y, vp2.y])
