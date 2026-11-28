extends SceneTree

## Boss 招式自检：不靠"看着像"，逐项验证每只 Boss 的打法确实不同。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/boss_check.gd
## 输出 .workbuddy/boss.txt
##
## 分两层：
##   A. Enemy 层（不需要帧）：直接调 _tick_boss 推进时间，记录招式序列，
##      与 BOSS_KIT_TABLES 逐项比对；顺带验瞬移落点、追踪弹发出。
##   B. Game 层（需要真实场景）：验血条风格名、出场横幅、追踪弹真的生成了带
##      homing_turn 的子弹、死亡掉落是 8 颗而不是 1 颗。
##
## 为什么直接调 _tick_boss 而不是跑真场景：Boss 战里有一圈小怪、有随机刷怪、
## 有玩家走位，招式触发时机每局都不一样，断言"第三招应该是巨浪"会变成碰运气。
## 这里喂固定方向的假目标，招式节奏就是确定的。

const DT: float = 1.0 / 60.0
## 一轮是"连招（2~3 招）+ 破甲窗口（3.8s）+ 追击（≤2.4s）"，
## 8 招要 3~4 轮，最长的一轮（二阶段、招里有巨浪和裂地）约 11 秒——
## 留一倍余量取 60 秒。按旧的"3 秒一招"算只会得到 24 秒，连一半都跑不完。
const KIT_FRAMES: int = 3600
const MAX_FRAMES: int = 9000
## Boss 掉落应该是 8 颗（Game.BOSS_GEM_COUNT），这里写死一份是为了"两边改歪了对不上"
const EXPECT_BOSS_GEMS: int = 8

## 假目标：只要能挨打就行。真实 Player 会闪白、会震屏、会死，与读招无关。
class Dummy extends Node2D:
	var taken: float = 0.0

	func take_damage(amount: float) -> void:
		taken += amount


var _out: PackedStringArray = []
var _fails: int = 0
var _game: Node = null
var _frames: int = 0
var _wait: int = 0
var _step: int = 0
var _done: bool = false

## 当前这一帧里瞬时招式发出的信号（召唤 / 弹幕）
var _sig: Array[int] = []
## 记录到的招式序列
var _moves: Array[int] = []
var _blinks: Array[Vector2] = []
var _homing_count: int = 0
var _last_homing: int = 0
var _summons: int = 0


func _initialize() -> void:
	_out.append("=== Boss 招式自检 ===")
	_out.append("招式编号：1 冲击波 / 2 冲锋前摇 / 3 冲锋中 / 4 瞬移 / 5 追踪弹 / 6 巨浪 / 7 召唤 / 8 弹幕 / 9 裂地")
	_out.append("")
	_test_intro()
	_test_kits()
	# Game 层要真实场景，放到 _process 里逐帧推进
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		_out.append("FAIL 主场景加载失败")
		_fails += 1
		_finish()
		return
	root.add_child(packed.instantiate())


# ---------------------------------------------------------------- A. Enemy 层

## 出场定身：1.1 秒内不动、不出招。玩家要用这一秒认人。
func _test_intro() -> void:
	var dummy := Dummy.new()
	dummy.global_position = Vector2(300, 0)
	var boss := _make_boss(0, dummy)
	boss.boss_intro_t = Enemy.BOSS_INTRO_TIME
	var start: Vector2 = boss.global_position
	# 注意：GDScript 的 lambda 对局部变量是值拷贝，写进 lambda 的计数器
	# 外部读到的永远是初值——所以计数必须挂成员变量。
	_summons = 0
	boss.boss_summon.connect(func(_a: Vector2, _c: int) -> void: _summons += 1)
	# 只跑 55 帧（0.9 秒），应该完全没动
	for i in range(55):
		boss._tick_boss(DT, Vector2.RIGHT, 300.0)
	var moved: float = boss.global_position.distance_to(start)
	_check("出场定身 0.9 秒内不动", moved < 0.5, "位移 %.2f" % moved)
	_check("出场定身期间不出招", _summons == 0, "定身期间放了 %d 次召唤" % _summons)
	# 再跑 20 帧（累计 1.25 秒），定身结束，应该开始走/出招
	for i in range(20):
		boss._tick_boss(DT, Vector2.RIGHT, 300.0)
	_check("定身结束后恢复行动", boss.boss_intro_t <= 0.0, "intro 剩余 %.2f" % boss.boss_intro_t)
	boss.free()
	dummy.free()
	_out.append("")


## 三套 kit：一阶段 8 招、二阶段 8 招，都要对上各自表。
func _test_kits() -> void:
	for kit in range(Enemy.BOSS_KIT_TABLES.size()):
		var dummy := Dummy.new()
		dummy.global_position = Vector2(260, 0)
		var boss := _make_boss(kit, dummy)
		boss.boss_intro_t = 0.0
		var name: String = Enemy.BOSS_KIT_NAMES[kit]
		_out.append("— kit %d · %s（%s）" % [kit, name, _names(Enemy.BOSS_KIT_TABLES[kit]["one"])])

		# 一阶段
		_run(boss, dummy, KIT_FRAMES)
		var one: Array = Enemy.BOSS_KIT_TABLES[kit]["one"]
		_expect_cycle("一阶段", one, 2)

		# 二阶段：把血打到 40%，phase 会在下一帧切过去
		boss._health = boss.max_health * 0.4
		_run(boss, dummy, 5)
		# 注意 %% ：这是 % 格式化串，写单个 "40%" 会被解析成格式符，
		# Godot 会报 "unsupported format character" 并中断整个自检（曾经整脚本静默不出结果）
		_check("二阶段切换", boss._boss_phase_index == 1,
			"血量 40%% 时仍未进入二阶段（phase=%d）" % boss._boss_phase_index)
		_out.append("    二阶段表：%s" % _names(Enemy.BOSS_KIT_TABLES[kit]["two"]))
		_run(boss, dummy, KIT_FRAMES)
		var two: Array = Enemy.BOSS_KIT_TABLES[kit]["two"]
		_expect_cycle("二阶段", two, 2)

		# kit 1 的招牌是瞬移：必须真的换位置，且要从玩家背后出现
		if kit == 1:
			_check("蚀影会瞬移", _blinks.size() >= 2,
				"两阶段合计只记录了 %d 次瞬移" % _blinks.size())
			if not _blinks.is_empty():
				var landing: Vector2 = _blinks[_blinks.size() - 1]
				var behind: float = landing.distance_to(dummy.global_position)
				_check("瞬移落点在玩家 240 处", absf(behind - Enemy.BOSS_BLINK_DIST) < 2.0,
					"落点距玩家 %.1f，期望 %.1f" % [behind, Enemy.BOSS_BLINK_DIST])
		# kit 2 的招牌是追踪弹
		if kit == 2:
			_check("深潜者会放追踪弹", _homing_count >= 2,
				"两阶段合计只放了 %d 次追踪弹" % _homing_count)
			_check("追踪弹每次 3 发", _homing_count > 0 and _last_homing == Enemy.BOSS_HOMING_COUNT,
				"上次发射数量 %d" % _last_homing)

		boss.free()
		dummy.free()
		_out.append("")


func _make_boss(kit: int, dummy: Node2D) -> Enemy:
	var boss := Enemy.new()
	boss.configure_boss(1000.0, 60.0, Enemy.BOSS_KIT_NAMES[kit], kit)
	boss.target = dummy
	boss.global_position = Vector2.ZERO
	boss.boss_summon.connect(func(_a: Vector2, _c: int) -> void: _sig.append(Enemy.MOVE_SUMMON))
	boss.boss_barrage.connect(func(_a: Vector2, _c: int) -> void: _sig.append(Enemy.MOVE_BARRAGE))
	boss.boss_homing.connect(func(_a: Vector2, c: int) -> void:
		_sig.append(Enemy.MOVE_HOMING)
		_homing_count += 1
		_last_homing = c)
	boss.boss_blink.connect(func(_from: Vector2, to: Vector2) -> void:
		_blinks.append(to))
	return boss


## 推进 frames 帧，把招式起始按顺序记进 _moves。
## 瞬时招式（召唤/弹幕）不占状态，只能从信号里认；有前摇的招式看状态跳变。
func _run(boss: Enemy, dummy: Node2D, frames: int) -> void:
	var prev: int = boss._boss_move
	for i in range(frames):
		var to_target: Vector2 = dummy.global_position - boss.global_position
		var dist: float = to_target.length()
		var dir: Vector2 = to_target / dist if dist > 0.001 else Vector2.RIGHT
		_sig.clear()
		boss._tick_boss(DT, dir, dist)
		if boss._boss_move != prev:
			# 突进是"冲锋"这个招式的第二段，不是新的一招——否则每次冲锋都会被记成两招
			if boss._boss_move != Enemy.MOVE_IDLE and boss._boss_move != Enemy.MOVE_CHARGE_DASH:
				_moves.append(boss._boss_move)
			prev = boss._boss_move
		elif prev == Enemy.MOVE_IDLE and not _sig.is_empty():
			_moves.append(_sig[0])


## 断言 _moves 里连续的 min_cycles 轮都等于表本身
func _expect_cycle(label: String, table: Array, cycles: int) -> void:
	var want: Array[int] = []
	for c in range(cycles):
		for v in table:
			want.append(int(v))
	var got: Array[int] = []
	for i in range(mini(want.size(), _moves.size())):
		got.append(_moves[i])
	_check("%s 轮换顺序" % label, got == want,
		"期望 %s，实际 %s" % [_names(want), _names(got)])
	_moves.clear()


func _names(table: Array) -> String:
	var parts: PackedStringArray = []
	for v in table:
		parts.append(_move_name(int(v)))
	return " → ".join(parts)


func _move_name(move: int) -> String:
	match move:
		Enemy.MOVE_SHOCK: return "冲击波"
		Enemy.MOVE_CHARGE_WINDUP: return "冲锋"
		Enemy.MOVE_CHARGE_DASH: return "突进"
		Enemy.MOVE_BLINK: return "瞬移"
		Enemy.MOVE_HOMING: return "追踪弹"
		Enemy.MOVE_TIDE: return "巨浪"
		Enemy.MOVE_SUMMON: return "召唤"
		Enemy.MOVE_BARRAGE: return "弹幕"
		Enemy.MOVE_STRIKE: return "裂地"
	return "待机"


# ---------------------------------------------------------------- B. Game 层

func _process(_delta: float) -> bool:
	if _done:
		return true
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("bosscheck", HeroClass.WARRIOR)
		_game.story_enabled = false
		if _game.story_panel != null and _game.story_panel.is_open():
			_game.story_panel.skip()
		_wait = 5
		return false
	if _wait > 0:
		_wait -= 1
		return false

	_frames += 1
	if _frames > MAX_FRAMES:
		_out.append("FAIL 超过 %d 帧未跑完" % MAX_FRAMES)
		_fails += 1
		_finish()
		return true

	# 升级面板会暂停整棵树
	if _game._state == 2:
		_game._choose(0)
		return false
	if _game._state == 3:
		_out.append("FAIL 玩家在自检过程中死亡（不应由 Boss 逻辑导致）")
		_fails += 1
		_finish()
		return true
	if is_instance_valid(_game.player):
		_game.player.health = _game.player.max_health

	match _step:
		0:
			_test_game_stage(0)
		1:
			_test_game_stage(1)
		2:
			_test_game_stage(2)
		_:
			_finish()
			return true
	return false


## 逐章验证：血条风格名、出场横幅、追踪弹生成、击杀掉落
func _test_game_stage(idx: int) -> void:
	var stage: Dictionary = Stage.at(idx)
	_game._stage_index = idx
	_game._stage_time = float(stage["length"])
	_game._check_boss()
	var boss: Enemy = _game._boss
	if boss == null or not is_instance_valid(boss):
		_check("第 %d 章 Boss 出场" % (idx + 1), false, "时间走满后没有生成 Boss")
		_step += 1
		return

	var expect_kit: int = Stage.boss_kit(str(stage["boss"]))
	_check("第 %d 章 Boss 用 kit %d" % [idx + 1, expect_kit], boss.boss_kit == expect_kit,
		"实际 kit %d" % boss.boss_kit)
	var label: String = _game.hud._boss_name_label.text
	_check("血条带风格名", label.contains(Enemy.BOSS_KIT_NAMES[expect_kit]),
		"血条文字是「%s」，缺 %s" % [label, Enemy.BOSS_KIT_NAMES[expect_kit]])
	_check("出场横幅", _game.hud._banner.visible and _game.hud._banner_title.text.contains("关底"),
		"横幅标题「%s」" % _game.hud._banner_title.text)
	_out.append("  第 %d 章 %s：血条「%s」 横幅「%s / %s」" % [
		idx + 1, stage["boss"], label,
		_game.hud._banner_title.text, _game.hud._banner_sub.text,
	])
	_check("出场定身已生效", boss.boss_intro_t > 0.0, "intro 未设置")

	# 追踪弹：直接让 Game 放一次，数一数生成的子弹
	if idx == 2:
		var before: int = _count_homing_shots()
		_game._on_boss_homing(boss.global_position, Enemy.BOSS_HOMING_COUNT)
		var after: int = _count_homing_shots()
		_check("追踪弹生成 3 发且带转向", after - before == 3,
			"新增 %d 发" % (after - before))

	# 击杀：掉 8 颗宝石，且章节推进
	var gems_before: int = _game._gems.size()
	# bypass_shell=true：这里验的是"打死之后掉什么、章怎么推进"，
	# 不是破甲机制本身（那部分在 dev/breach_check.gd）。Boss 现在有壳，
	# 不带第二个参数的话这一击会被判免疫，整个自检卡在这里。
	boss.take_damage(1e9, true)
	_check("击杀后进入下一章", _game._stage_index == idx + 1,
		"章节序号 %d，期望 %d" % [_game._stage_index, idx + 1])
	_check("Boss 掉落 8 颗宝石", _game._gems.size() - gems_before == EXPECT_BOSS_GEMS,
		"新增 %d 颗" % (_game._gems.size() - gems_before))
	_check("Boss 战结束清空血条", not _game.hud._boss_panel.visible, "血条仍然显示")
	_out.append("")
	_step += 1


func _count_homing_shots() -> int:
	var total: int = 0
	for child in _game.world.get_children():
		if child is EnemyShot and (child as EnemyShot).homing_turn > 0.0:
			total += 1
	return total


# ---------------------------------------------------------------- 工具

func _check(label: String, ok: bool, detail: String) -> void:
	if ok:
		_out.append("  [OK] %s" % label)
	else:
		_out.append("  [FAIL] %s —— %s" % [label, detail])
		_fails += 1


func _finish() -> void:
	_done = true
	_out.append("")
	_out.append("=== %s（失败 %d 项）===" % ["全部通过" if _fails == 0 else "存在问题", _fails])
	var file := FileAccess.open("res://.workbuddy/boss.txt", FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_out))
		file.close()
	quit()
