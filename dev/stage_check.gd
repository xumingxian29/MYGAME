extends SceneTree

## 关卡流程自检：不靠眼睛看截图，逐项验证 P2-8 的每条规则。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/stage_check.gd
## 输出 .workbuddy/stage.txt
##
## 验证项：
##   1. 每章时间走满 → 出对应章节 Boss（名字要对得上 Stage 表）
##   2. 击杀 Boss → 章节序号 +1、横幅亮起、章节条归零、延迟发卡
##   3. 第三章打完 → cleared=true、横幅走"通关"金色分支、结算面板出现 +2500
##   4. 通关后进入无尽轮次，"无尽 · 回响 1"这类命名与血量倍率生效
##
## 直接改 _stage_time 而不是真打 70 秒：这是流程测试，不是手感测试。
## 手感与数值归 dev/bot.gd 管，两件事分开跑才不会被对方的随机性污染。

const MAX_STAGE: int = 5

var _game: Node = null
var _out: PackedStringArray = []
var _wait: int = 0
var _step: int = 0
var _fails: int = 0
## 死循环兜底：任何分支忘了推进 _step 时，最多跑这么多帧就收工。
## 加它是因为第一版脚本真的挂住了——headless 下没有任何输出，只能等超时。
const MAX_FRAMES: int = 6000
var _frames: int = 0
var _done: bool = false
var _endless_logged: bool = false


func _initialize() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		_out.append("FAIL 主场景加载失败")
		_flush()
		quit()
		return
	root.add_child(packed.instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("check", HeroClass.WARRIOR)
		_out.append("=== 关卡流程自检 ===")
		_out.append("Stage.COUNT=%d  手写章节=%s" % [Stage.COUNT, _titles()])
		_wait = 5
		return false

	if _wait > 0:
		_wait -= 1
		return false

	_frames += 1
	if _frames > MAX_FRAMES:
		_out.append("FAIL 超过 %d 帧仍未跑完，测试自身可能卡在某一步" % MAX_FRAMES)
		_fails += 1
		_finish()
		return true
	if _step >= 99:
		_finish()
		return true

	# 升级面板会暂停整棵树，测试里直接选第一张继续
	if _game._state == 2:
		_game._choose(0)
		return false
	if _game._state == 3 and _step < 4:
		_out.append("FAIL 玩家在测试过程中死亡（不应该是关卡逻辑导致的）")
		_fails += 1
		_finish()
		return true

	# 这是流程测试，不是生存测试：每帧把血补满，免得被 Boss 召唤的小怪打死，
	# 干扰"关卡逻辑是否正确"的断言。伤害与生存归 dev/bot.gd 管。
	if _game._state == 1 and is_instance_valid(_game.player):
		_game.player.health = _game.player.max_health

	match _step:
		0:
			_check("开局", _game._stage_index == 0, "章节序号应为 0，实际 %d" % _game._stage_index)
			_check("开局横幅", _game.hud._banner.visible, "开局必须打出第一章的名字")
			_out.append("  左上角章节：%s" % _game.hud._stage_label.text)
			_step = 1
			continue_to_boss()
		1:
			_on_boss_spawned()
		2:
			_on_boss_killed()
		3:
			_on_cleared_check()
		4:
			_on_game_over_check()
		_:
			_finish()
			return true
	return false


## 把本章时间推到尽头，下一帧 _check_boss 就会放 Boss
func continue_to_boss() -> void:
	_game._stage_time = 999.0
	_wait = 4
	_step = 1


func _on_boss_spawned() -> void:
	var idx: int = _game._stage_index
	var boss = _game._boss
	if boss == null or not is_instance_valid(boss):
		_check("第 %d 章 Boss 出场" % (idx + 1), false, "时间走满后没有生成 Boss")
		_step = 99
		return
	var stage: Dictionary = Stage.at(idx)
	var expect: String = str(stage["boss"])
	_check("第 %d 章 Boss 名字" % (idx + 1), boss.boss_name == expect,
		"期望 %s，实际 %s" % [expect, boss.boss_name])
	_out.append("  第 %d 章 %s：Boss=%s  血=%.0f  时长=%.0fs" % [
		idx + 1, Stage.title(idx), boss.boss_name, boss.max_health, float(stage["length"]),
	])
	_check("Boss 战区块", _game.hud._boss_panel.visible, "Boss 血条没有显示")
	_check("章节条变红", _game.hud._stage_boss, "Boss 期间章节栏应切成关底状态")
	_game._boss.take_damage(1e9, true)
	_wait = 3
	_step = 2


func _on_boss_killed() -> void:
	var idx: int = _game._stage_index
	var cleared: bool = _game._cleared
	_check("章节推进", idx >= 1, "击杀 Boss 后章节序号没有增加")
	_out.append("  → 击杀后进入 index=%d（%s）通关=%s 横幅=%s 待发卡=%d 发卡延迟=%.1fs" % [
		idx, Stage.title(idx), str(cleared), str(_game.hud._banner.visible),
		_game._pending_cards, _game._card_delay,
	])
	_check("换章横幅", _game.hud._banner.visible, "换章时横幅没有亮")
	_check("章节条归零", _game.hud._stage_bar.value <= 1.0,
		"换章后章节条应归零，实际 %.0f" % _game.hud._stage_bar.value)
	_check("章节栏文案", _game.hud._stage_label.text.begins_with(Stage.title(idx)),
		"左上角章节栏没跟上：%s" % _game.hud._stage_label.text)
	_check("延迟发卡", _game._card_delay > 0.0, "换章后应延迟发卡，读横幅的时间被吃掉了")

	if idx < Stage.COUNT:
		continue_to_boss()
		return
	# 已经进入无尽轮次：先验证通关那一章
	_step = 3


func _on_cleared_check() -> void:
	_check("通关标记", _game._cleared, "走完三章后 _cleared 应为 true")
	_check("无尽命名", Stage.title(_game._stage_index).begins_with("无尽"),
		"通关后章节名应为『无尽 · …』，实际 %s" % Stage.title(_game._stage_index))
	var base: Dictionary = Stage.LIST[Stage.COUNT - 1]
	var endless: Dictionary = Stage.at(Stage.COUNT)
	if not _endless_logged:
		_endless_logged = true
		_out.append("  无尽第 1 轮：%s  Boss=%s  血倍率 %.2f→%.2f  时长 %.0f→%.0f" % [
			Stage.title(Stage.COUNT), endless["boss"],
			float(base["hp_scale"]), float(endless["hp_scale"]),
			float(base["length"]), float(endless["length"]),
		])
	_check("无尽血量更高", float(endless["hp_scale"]) > float(base["hp_scale"]),
		"无尽轮次血量倍率没有提升")

	# 剩下两轮继续推，确认无尽循环不会卡死或重复同一章
	if _game._stage_index < MAX_STAGE:
		continue_to_boss()
		_step = 1
		return

	# 最后：让玩家死掉，检查结算面板
	_game.player.take_damage(99999.0)
	_wait = 5
	_step = 4


func _on_game_over_check() -> void:
	if _game._state != 3:
		_check("结算状态", false, "玩家死亡后未进入 GAME_OVER")
		_step = 99
		return
	var texts: String = _panel_text()
	_check("结算标题", texts.find("你走完了三章") >= 0, "通关局结算标题不对")
	_check("通关加分行", texts.find("三章通关 · 附加奖励") >= 0, "结算缺少通关加分行")
	_check("通关加分值", texts.find("+%d" % Score.CLEAR_BONUS) >= 0,
		"结算没有显示 +%d" % Score.CLEAR_BONUS)
	_check("关卡进度行", texts.find(Stage.title(_game._stage_index)) >= 0,
		"结算的存活行没有带章节名")
	_out.append("  结算面板文本：%s" % texts.replace("\n", " | "))
	_finish()


func _panel_text() -> String:
	var parts: PackedStringArray = []
	_collect(_game.hud._panel_box, parts)
	return " ".join(parts)


func _collect(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		_collect(child, parts)


func _titles() -> String:
	var parts: PackedStringArray = []
	for i in range(Stage.COUNT):
		parts.append(Stage.title(i))
	return " / ".join(parts)


func _check(what: String, ok: bool, detail: String) -> void:
	if ok:
		_out.append("  [OK] %s" % what)
		return
	_fails += 1
	_out.append("  [FAIL] %s — %s" % [what, detail])


func _finish() -> void:
	# 幂等：多条失败路径都会调到这里，重复写会把结论覆盖成两行
	if _done:
		return
	_done = true
	_step = 99
	_out.append("")
	_out.append("=== %s（失败 %d 项）===" % ["全部通过" if _fails == 0 else "存在问题", _fails])
	_flush()


func _flush() -> void:
	var f: FileAccess = FileAccess.open("res://.workbuddy/stage.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _out:
		f.store_line(line)
	f.close()
