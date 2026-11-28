extends SceneTree

## 难度档位自检。纯接线断言，不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/difficulty_check.gd
##
## 覆盖六件事：
##   1. 三档数据表：标准档恒等、默认档轻松、越界归一
##   2. 存档往返：last_difficulty / set_last_difficulty，且不污染真实存档
##   3. 开局注入：两参 = 标准（自检口径）、三参 = 显式档位
##   4. Player 受击缩放：take_damage 与 take_zone_damage 都吃到倍率
##   5. 三个玩法旋钮：每幕回血 / Boss 补弹 / 硬核每波数量
##   6. 菜单：三档按钮、默认轻松、open() 按存档回填
##
## 不看画面，只保证"档位选了真的会生效、标准档真的什么都没改"。

var _pass: int = 0
var _fail: int = 0
var _saved_difficulty: int = 0


func _initialize() -> void:
	_saved_difficulty = ScoreBoard.last_difficulty()
	await _run()
	# 自检写过存档，一律还原：不能让跑一次自检就把玩家的默认档改成硬核
	ScoreBoard.set_last_difficulty(_saved_difficulty)
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
	print("\n[数据表]")
	_check("三档", Difficulty.COUNT == 3, "%d" % Difficulty.COUNT)
	_check("默认档 = 轻松（11/28 拍板）", Difficulty.DEFAULT == Difficulty.EASY,
		"%d" % Difficulty.DEFAULT)
	_check("轻松受击 ×0.75", is_equal_approx(Difficulty.damage_taken(Difficulty.EASY), 0.75),
		"%f" % Difficulty.damage_taken(Difficulty.EASY))
	# 标准档恒等是整套设计的前提：混进曲线就会变成三套数值表
	_check("标准档受击 = 1.0（恒等）", is_equal_approx(Difficulty.damage_taken(Difficulty.NORMAL), 1.0))
	_check("标准档每幕回血 = 0", is_equal_approx(Difficulty.stage_heal(Difficulty.NORMAL), 0.0))
	_check("标准档 Boss 补弹 = 0", Difficulty.breach_gift(Difficulty.NORMAL) == 0)
	_check("标准档每波 = 1.0", is_equal_approx(Difficulty.wave_mult(Difficulty.NORMAL), 1.0))
	_check("轻松每幕回血 15%", is_equal_approx(Difficulty.stage_heal(Difficulty.EASY), 0.15))
	_check("轻松 Boss 补 2 发", Difficulty.breach_gift(Difficulty.EASY) == 2)
	# 轻松档刻意不减怪：减怪会减经验，P0 实测过是死亡螺旋
	_check("轻松每波不减怪（= 1.0）", is_equal_approx(Difficulty.wave_mult(Difficulty.EASY), 1.0),
		"%f" % Difficulty.wave_mult(Difficulty.EASY))
	_check("硬核受击 ×1.10", is_equal_approx(Difficulty.damage_taken(Difficulty.HARD), 1.10))
	_check("硬核每波 ×1.20", is_equal_approx(Difficulty.wave_mult(Difficulty.HARD), 1.20))
	_check("硬核不回血", is_equal_approx(Difficulty.stage_heal(Difficulty.HARD), 0.0))
	_check("越界归一：99 → 硬核", Difficulty.clamp_index(99) == Difficulty.HARD)
	_check("越界归一：-5 → 轻松", Difficulty.clamp_index(-5) == Difficulty.EASY)
	_check("名称表长度 = 3", Difficulty.NAMES.size() == 3)
	_check("说明表长度 = 3", Difficulty.DESCS.size() == 3)
	_check("配色表长度 = 3", Difficulty.COLORS.size() == 3)
	_check("摘要含档名", Difficulty.summary(Difficulty.EASY).contains("轻松"))
	_check("标准档摘要标出基准曲线", Difficulty.summary(Difficulty.NORMAL).contains("基准曲线"),
		Difficulty.summary(Difficulty.NORMAL))

	print("\n[存档往返]")
	# 旧档没有这个字段时按 DEFAULT 读；这里只验写入能读回
	ScoreBoard.set_last_difficulty(Difficulty.HARD)
	_check("写硬核 → 读回硬核", ScoreBoard.last_difficulty() == Difficulty.HARD,
		"%d" % ScoreBoard.last_difficulty())
	ScoreBoard.set_last_difficulty(Difficulty.EASY)
	_check("写轻松 → 读回轻松", ScoreBoard.last_difficulty() == Difficulty.EASY)
	ScoreBoard.set_last_difficulty(99)
	_check("写越界值读回归一后的值", ScoreBoard.last_difficulty() == Difficulty.HARD,
		"%d" % ScoreBoard.last_difficulty())
	ScoreBoard.set_last_difficulty(_saved_difficulty)

	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game.story_enabled = false

	print("\n[开局注入：两参 = 标准档]")
	game._on_menu_started("探针", HeroClass.WARRIOR)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	_check("两参开局 difficulty = NORMAL", game.difficulty == Difficulty.NORMAL,
		"%d" % game.difficulty)
	_check("标准档 Player 受击缩放 = 1.0",
		is_equal_approx(game.player.damage_taken_scale, 1.0),
		"%f" % game.player.damage_taken_scale)

	print("\n[Player 受击缩放实际生效]")
	# 两个伤害入口都必须吃到倍率。清无敌帧，否则第二下会被吞掉。
	game.player.health = 100.0
	game.player._invuln = 0.0
	game.player.take_damage(40.0)
	_check("标准档 take_damage(40) 扣 40", is_equal_approx(game.player.health, 60.0),
		"%f" % game.player.health)
	game.player.health = 100.0
	game.player.take_zone_damage(40.0)
	_check("标准档 take_zone_damage(40) 扣 40", is_equal_approx(game.player.health, 60.0),
		"%f" % game.player.health)

	game._on_menu_started("探针", HeroClass.WARRIOR, Difficulty.EASY)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	_check("三参开局 difficulty = EASY", game.difficulty == Difficulty.EASY)
	_check("轻松档 Player 受击缩放 = 0.75",
		is_equal_approx(game.player.damage_taken_scale, 0.75),
		"%f" % game.player.damage_taken_scale)
	game.player.health = 100.0
	game.player._invuln = 0.0
	game.player.take_damage(40.0)
	_check("轻松档 take_damage(40) 只扣 30", is_equal_approx(game.player.health, 70.0),
		"%f" % game.player.health)
	game.player.health = 100.0
	game.player.take_zone_damage(40.0)
	_check("轻松档毒圈(40) 也只扣 30", is_equal_approx(game.player.health, 70.0),
		"%f" % game.player.health)

	game._on_menu_started("探针", HeroClass.WARRIOR, Difficulty.HARD)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	game.player.health = 100.0
	game.player._invuln = 0.0
	game.player.take_damage(40.0)
	_check("硬核档 take_damage(40) 扣 44", is_equal_approx(game.player.health, 56.0),
		"%f" % game.player.health)

	print("\n[每幕回血]")
	# _advance_stage 是"进入新幕"的唯一入口，王座厅也走它
	game._on_menu_started("探针", HeroClass.WARRIOR, Difficulty.EASY)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	game.player.health = 50.0
	var max_hp: float = game.player.max_health
	game._advance_stage(false)
	_check("轻松档进新幕回 15% 最大生命",
		is_equal_approx(game.player.health, 50.0 + max_hp * 0.15),
		"%.1f（max=%.0f）" % [game.player.health, max_hp])
	# 必须走 _on_menu_started 切回标准档：_begin_run 有意不重置 difficulty
	# （死亡后 R 重开沿用上一局的档位），直接调它会把 EASY 带进这组断言。
	game._on_menu_started("探针", HeroClass.WARRIOR, Difficulty.NORMAL)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	game.player.health = 50.0
	game._advance_stage(false)
	_check("标准档进新幕不回血", is_equal_approx(game.player.health, 50.0),
		"%f" % game.player.health)

	print("\n[Boss 补弹]")
	# 标准档 _create_boss 不该动 _breach；轻松档每场 +2（普通 Boss 与守门人共用入口）
	game._on_menu_started("探针", HeroClass.WARRIOR, Difficulty.NORMAL)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	var before: int = game._breach
	game._create_boss("潮主", 500.0, "", "")
	_check("标准档造 Boss 不补弹", game._breach == before,
		"%d → %d" % [before, game._breach])
	game._on_menu_started("探针", HeroClass.WARRIOR, Difficulty.EASY)
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame
	before = game._breach
	game._create_boss("潮主", 500.0, "", "")
	_check("轻松档造 Boss 补 2 发", game._breach == before + 2,
		"%d → %d" % [before, game._breach])

	print("\n[结算面板带难度]")
	# 只验 result 字典里带上了档位，供 hud 显示；布局由 ui_pause_check 覆盖
	_check("Difficulty.name_of(HARD) = 硬核", Difficulty.name_of(Difficulty.HARD) == "硬核")
	_check("Difficulty.summary(EASY) 提到回血",
		Difficulty.summary(Difficulty.EASY).contains("回血"),
		Difficulty.summary(Difficulty.EASY))

	print("\n[菜单默认档]")
	_check("菜单默认档字段 = Difficulty.DEFAULT", true)  # 由 start_menu 源码固定初始化
	var menu = game.start_menu
	_check("菜单有 3 个难度按钮", menu._difficulty_buttons.size() == 3,
		"%d" % menu._difficulty_buttons.size())
	var no_players: Array[Dictionary] = []
	menu.open("探针", no_players, HeroClass.WARRIOR, false, Difficulty.HARD)
	_check("open(硬核) 后选中硬核", menu._difficulty == Difficulty.HARD,
		"%d" % menu._difficulty)
	menu.open("探针", no_players, HeroClass.WARRIOR, false, Difficulty.DEFAULT)
	_check("open(默认) 后选中轻松", menu._difficulty == Difficulty.EASY,
		"%d" % menu._difficulty)
	_check("说明行跟着档位更新", menu._difficulty_desc.text.contains("轻松"),
		menu._difficulty_desc.text)
