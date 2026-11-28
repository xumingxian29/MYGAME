extends SceneTree

## 整局流程自检：十道门 → 王座厅五连守门人 → 城门 → 胜利结算 → 本地积分。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/run_check.gd
##
## 这条链路跨了 10 次换图、5 次 Boss 死亡和一次存档写入，
## 任何一环写错（门计数、王座厅闸门、胜利门、存档字段）都只能靠这条自检发现——
## 单看某一段都"看起来对"。剧情在这里整体关掉（story_enabled = false），
## 剧情本身的断言在 dev/story_check.gd。

## 用一个独立昵称，避免和真实存档混在一起；跑完会把 records.json 原样写回。
const PLAYER: String = "跑通探针"
const SAVE_PATH: String = "user://records.json"

var _pass: int = 0
var _fail: int = 0
var _backup: String = ""
var _had_save: bool = false


func _initialize() -> void:
	await _run()
	_restore_save()
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
	_backup_save()

	var game: Node = load("res://MY主场景.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.story_enabled = false
	game._on_menu_started(PLAYER, HeroClass.WARRIOR)
	await process_frame
	_check("开局进入 PLAYING", game._state == 1, "state=%d" % game._state)

	var victories_before: int = int(ScoreBoard.load_profile(PLAYER)["victories"])

	print("\n[十道门]")
	for i in range(10):
		game._open_portals(game.player.global_position)
		await process_frame
		if i == 9:
			_check("第 10 道门之前仍是普通门", game._portals.size() == 4,
				"%d 扇" % game._portals.size())
		game._pending_portal = game._portals[0]
		game._confirm_portal()
		await process_frame
		if game._state == 2:
			game._choose(0)
		if i < 9:
			_check("第 %d 道门之后换图" % (i + 1),
				game._map_index == i + 1 and game._gauntlet_left == 0,
				"map=%d gauntlet=%d" % [game._map_index, game._gauntlet_left])

	_check("十道门都记了数", game._portal_count == 10, "%d" % game._portal_count)
	_check("第 10 道门之后进王座厅", game._gauntlet_left == 5, "%d" % game._gauntlet_left)
	_check("守门人总数 5", game._gauntlet_total == 5, "%d" % game._gauntlet_total)
	_check("王座厅不再开门", game._portals.is_empty(), "%d 扇" % game._portals.size())
	_check("王座厅不刷小怪", game._gauntlet_left > 0)
	# 王座厅的章节号推到第 10 幕（Stage 的越界会自动生成"回响"模板）
	_check("幕号到第十幕", game._map_index == 10, "map=%d" % game._map_index)

	print("\n[五位守门人]")
	for i in range(5):
		var waited: int = 0
		while (game._boss == null or not is_instance_valid(game._boss)) and waited < 900:
			await physics_frame
			waited += 1
			if game._state == 2:
				game._choose(0)
		var boss = game._boss
		_check("第 %d 位守门人出场" % (i + 1), boss != null and is_instance_valid(boss),
			"等待 %d 帧" % waited)
		if boss == null or not is_instance_valid(boss):
			break
		_check("第 %d 位血条带名次" % (i + 1),
			game.hud._boss_rank == "%d/5" % (i + 1), game.hud._boss_rank)
		_check("第 %d 位血量按名次递增" % (i + 1),
			is_equal_approx(boss.max_health,
				Enemy.BREACH_HIT_DAMAGE * float(game.GAUNTLET_BASE_SHOTS + game.GAUNTLET_SHOT_STEP * i)),
			"hp=%.0f" % boss.max_health)
		boss.take_damage(1e9, true)
		await process_frame
		_check("第 %d 位倒下后计数递减" % (i + 1), game._gauntlet_left == 4 - i,
			"left=%d" % game._gauntlet_left)

	print("\n[城门与胜利结算]")
	await process_frame
	_check("五位倒完只开一扇门", game._portals.size() == 1, "%d 扇" % game._portals.size())
	if game._portals.size() == 1:
		_check("那扇门是胜利门", game._portals[0].reward == Portal.Reward.VICTORY)
		_check("胜利门上写的是'离开城堡'", game._portals[0].reward_text() == "离开城堡",
			game._portals[0].reward_text())
		# 门下面那行字是"你将走向哪一个门外"，不是固定的"黎明"：
		# 这一局十次都选的是四门里的第一扇（单卡），所以走黎明线。
		_check("城门下写着这一局的结局", game._portals[0].subtitle == "西门外 · 黎明",
			game._portals[0].subtitle)
	_check("等待玩家走进城门", game._awaiting_portal)

	game._pending_portal = game._portals[0]
	game._confirm_portal()
	await process_frame
	_check("确认后进入 VICTORY", game._state == 8, "state=%d" % game._state)
	_check("这一局记为通关", game._cleared and game._victory)
	_check("结算面板已弹出", game.hud._panel.visible)
	var title_text: String = ""
	if game.hud._panel_box.get_child_count() > 0:
		title_text = str(game.hud._panel_box.get_child(0).text)
	_check("标题是'你走出了城堡'", title_text == "你走出了城堡", title_text)

	_check("十次都选单卡 → 黎明", game._ending == "dawn", game._ending)
	var ending_line: String = ""
	for i in range(game.hud._panel_box.get_child_count()):
		var node: Node = game.hud._panel_box.get_child(i)
		if node is Label and str(node.text).begins_with("结局 "):
			ending_line = str(node.text)
	_check("面板写着『结局 1/5 · 黎明』", ending_line.begins_with("结局 1/5 · 黎明"),
		ending_line)

	var profile: Dictionary = ScoreBoard.load_profile(PLAYER)
	_check("存档记了这次逃亡", int(profile["victories"]) == victories_before + 1,
		"之前 %d，现在 %d" % [victories_before, int(profile["victories"])])
	_check("最快逃亡有记录", float(profile["best_victory"]["elapsed"]) > 0.0,
		str(profile["best_victory"]))
	_check("分数已入库", int(profile["best"]["score"]) > 0, "%d" % int(profile["best"]["score"]))
	_check("结局进了图鉴", int(profile["endings"].get("dawn", 0)) >= 1, str(profile["endings"]))
	_check("已解锁结局计数", ScoreBoard.count_endings(profile) >= 1,
		"%d" % ScoreBoard.count_endings(profile))

	print("\n[通关不再由章节数触发]")
	# 老逻辑是 Stage.is_cleared(_stage_index)（index >= 3）就判通关，
	# 十幕之后那个判断会在第四幕误触发，把一局游戏提前宣判成"通关"。
	var game2: Node = load("res://MY主场景.tscn").instantiate()
	root.add_child(game2)
	await process_frame
	game2.story_enabled = false
	game2._on_menu_started(PLAYER, HeroClass.WARRIOR)
	await process_frame
	game2._map_index = 5
	game2._stage_index = 4
	game2._advance_stage()
	await process_frame
	_check("走到第 6 幕不算通关", not game2._cleared)
	game2.queue_free()
	await process_frame

	print("\n[不同选择 → 不同结局 → 各自入库]")
	# 同一台机器、同一个昵称，第二局换成"十次都拿双卡"：
	# 结局必须换一个，而且图鉴要变成两种。这一条是"选择指向结局"的端到端证据——
	# 只测 Story.resolve_ending 的话，Game 少记一次账也照样全绿。
	var game3: Node = load("res://MY主场景.tscn").instantiate()
	root.add_child(game3)
	await process_frame
	game3.story_enabled = false
	game3._on_menu_started(PLAYER, HeroClass.WARRIOR)
	await process_frame
	game3._gate_trail = {"card2": 10}
	game3._last_choice = "card2"
	game3._map_index = 9
	game3._gauntlet_total = 5
	game3._boss_kills = 5
	game3._on_victory()
	await process_frame
	_check("十次双卡 → 新的王", game3._ending == "throne", game3._ending)
	var profile3: Dictionary = ScoreBoard.load_profile(PLAYER)
	_check("新结局也进了图鉴", int(profile3["endings"].get("throne", 0)) >= 1,
		str(profile3["endings"]))
	_check("图鉴现在有两种结局", ScoreBoard.count_endings(profile3) >= 2,
		"%d" % ScoreBoard.count_endings(profile3))
	game3.queue_free()
	await process_frame


# ---------------------------------------------------------------- 存档备份

## 这条自检会真的往 user://records.json 里写一个"跑通探针"的战绩。
## 不还原的话，玩家的排行榜里会多出一个 0 分的假人。
func _backup_save() -> void:
	_had_save = FileAccess.file_exists(SAVE_PATH)
	if not _had_save:
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	_backup = f.get_as_text()
	f.close()


func _restore_save() -> void:
	if not _had_save:
		if FileAccess.file_exists(SAVE_PATH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(_backup)
	f.close()
