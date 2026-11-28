extends SceneTree

## 剧情自检：数据完整性 + 字体覆盖 + 剧情屏行为 + 与主流程的接线。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/story_check.gd
##
## 为什么字体也要在这里断言：Web 上的中文字体是子集（ASCII + GB2312 + 项目文案），
## 新写的一句台词如果带了子集外的字，本地 Windows 会退回系统字体、看起来完全正常，
## 只有导到网页上才变成方块。这条必须能在提交前跑出来。

const PLAYER: String = "剧情探针"

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
	print("\n[剧情数据]")
	_check("一共十幕", Story.act_count() == 10, "%d" % Story.act_count())

	var titles: Array[String] = []
	var longest: int = 0
	var lines_ok: bool = true
	var tint_ok: bool = true
	for i in range(Story.act_count()):
		var act: Dictionary = Story.act(i)
		titles.append(str(act["name"]))
		var lines: Array = act["lines"]
		if lines.size() < 2 or lines.size() > 5:
			lines_ok = false
		for line in lines:
			longest = maxi(longest, str(line).length())
		var tint: Color = act["tint"]
		if tint.a < 0.99:
			tint_ok = false
		if str(act["beat"]).is_empty():
			lines_ok = false
	_check("每幕 2~5 行台词且都有横幅副标题", lines_ok)
	# 手机横屏一行最多 24~26 个汉字：超过就要换行，换行之后整块排版会散
	_check("单行不超过 26 字", longest <= 26, "最长 %d" % longest)
	_check("每幕配色都不透明", tint_ok)
	var unique: Dictionary = {}
	for t in titles:
		unique[t] = true
	_check("十幕名字不重复", unique.size() == Story.act_count(), "%d 个不同名字" % unique.size())

	_check("菜单引子提到王子", Story.prologue().contains("王子"), Story.prologue())
	_check("商人有台词", not Story.merchant_line().is_empty())
	_check("死亡标题带幕号", Story.defeat_title(6).contains("第七幕"), Story.defeat_title(6))
	_check("终章有独立台词", Story.finale_lines().size() == 3)
	_check("终章标题写着终章", Story.finale_title().contains("终章"), Story.finale_title())
	_check("终章不占幕号", not Story.finale_title().contains("幕"), Story.finale_title())

	print("\n[五个结局]")
	var order: Array[String] = Story.ending_order()
	_check("一共五个结局", order.size() == 5, "%d" % order.size())
	var unique_endings: Dictionary = {}
	var ending_ok: bool = true
	var longest_ending: int = 0
	for key in order:
		var e: Dictionary = Story.ending(key)
		unique_endings[str(e["name"])] = true
		# 三行是有原因的：结算面板的高度是按三行留的（手机逻辑高只有 540）
		if Story.ending_lines(key).size() != 3:
			ending_ok = false
		if str(e["gate"]).is_empty() or str(e["lead"]).is_empty():
			ending_ok = false
		if not str(e["gate"]).begins_with("西门外"):
			ending_ok = false
		if str(e["title"]).is_empty():
			ending_ok = false
		for line in Story.ending_lines(key):
			longest_ending = maxi(longest_ending, line.length())
	_check("每个结局 3 行 + 有门外名/一句由来/大标题", ending_ok)
	_check("五个名字不重复", unique_endings.size() == 5, "%d 个" % unique_endings.size())
	_check("结局台词单行不超过 26 字", longest_ending <= 26, "最长 %d" % longest_ending)
	_check("序号与顺序表一致",
		Story.ending_index("dawn") == 1 and Story.ending_index("mixed") == 5,
		"%d / %d" % [Story.ending_index("dawn"), Story.ending_index("mixed")])

	# 判定表。每一行 = [账本, 最后一次选的, 期望结局]。
	# 这几行是这个系统的全部规则：一个数错了，玩家会走到"我明明一直拿双卡却看到黎明"。
	var cases: Array = [
		[{"card": 10}, "", "dawn"],
		[{"card2": 10}, "", "throne"],
		[{"breach": 10}, "", "ash"],
		[{"gold": 10}, "", "gold"],
		[{"card": 3, "card2": 3, "breach": 2, "gold": 2}, "", "mixed"],
		[{"card": 4, "card2": 4, "breach": 1, "gold": 1}, "card2", "throne"],
		[{"card": 4, "card2": 4, "breach": 1, "gold": 1}, "card", "dawn"],
		[{"card2": 5, "gold": 3, "card": 2}, "", "throne"],
		[{"breach": 4, "gold": 3, "card": 3}, "gold", "ash"],
		[{}, "", "dawn"],
	]
	var resolve_ok: bool = true
	var resolve_detail: String = ""
	for row in cases:
		var got: String = Story.resolve_ending(row[0], str(row[1]))
		if got != str(row[2]):
			resolve_ok = false
			resolve_detail += "%s+%s→%s(期望 %s) " % [str(row[0]), str(row[1]), got, str(row[2])]
	_check("十种账本 → 五个结局", resolve_ok, resolve_detail)

	_check("路径文案只列选过的门",
		Story.trail_text({"card": 2}) == "走过的路：稳 2", Story.trail_text({"card": 2}))
	_check("路径文案把正在选的这扇也算进去",
		Story.trail_text({"card": 2}, "gold").contains("财 1"),
		Story.trail_text({"card": 2}, "gold"))
	_check("空账本不显示路径", Story.trail_text({}).is_empty())

	print("\n[王座厅]")
	_check("五位守门人", Story.gauntlet_count() == 5, "%d" % Story.gauntlet_count())
	var kit_ok: bool = true
	var names: PackedStringArray = PackedStringArray()
	for i in range(Story.gauntlet_count()):
		var info: Dictionary = Story.gauntlet(i)
		var boss_name: String = str(info["name"])
		names.append(boss_name)
		# 招式风格按名字查（Stage.BOSS_KITS）。查不到会静默退回 kit 0，
		# 结果五位守门人全用同一套招式——必须在数据层就挡住。
		if not Stage.BOSS_KITS.has(boss_name):
			kit_ok = false
		if str(info["line"]).is_empty():
			kit_ok = false
	_check("五位都能查到招式风格且都有台词", kit_ok, str(names))
	# 后两位必须是新名字：如果五位都是老面孔，王座厅就只是"再打一遍"
	_check("后两位是新守门人",
		names[3] == "暗影王子" and names[4] == "无光之王", str(names))

	print("\n[字体覆盖]")
	var font: Font = UiKit.font()
	var missing: String = ""
	for text in _all_texts():
		for i in range(text.length()):
			var code: int = text.unicode_at(i)
			if code == 32:
				continue
			if not font.has_char(code):
				missing += "%s(U+%04X)" % [text[i], code]
	_check("所有剧情文字都在字体子集里", missing.is_empty(), missing)

	print("\n[剧情屏行为]")
	var panel := StoryPanel.new()
	root.add_child(panel)
	await process_frame
	_check("默认不可见", not panel.visible)
	_check("铺满视口", absf(panel.size.x - float(root.get_visible_rect().size.x)) < 2.0,
		"panel=%.0f viewport=%.0f" % [panel.size.x, root.get_visible_rect().size.x])

	var events: Array[bool] = []
	panel.finished.connect(func(skipped: bool) -> void: events.append(skipped))
	var act: Dictionary = Story.act(0)
	panel.play(act["lines"], Story.title(0), Story.progress_text(0), Story.tint(0))
	await process_frame
	_check("播放入口打开", panel.is_open() and panel.visible)

	# 跳过键必须在右上角：锚点写死，但"写死"和"实际渲染出来"是两回事
	var btn: Rect2 = panel._skip_btn.get_global_rect()
	var panel_rect: Rect2 = panel.get_global_rect()
	_check("跳过键在右半屏", btn.position.x > panel_rect.position.x + panel_rect.size.x * 0.5,
		"btn.x=%.0f" % btn.position.x)
	_check("跳过键在上沿", btn.position.y < panel_rect.position.y + 60.0,
		"btn.y=%.0f" % btn.position.y)
	_check("跳过键没超出右边界", btn.end.x <= panel_rect.end.x + 1.0,
		"btn.right=%.0f panel.right=%.0f" % [btn.end.x, panel_rect.end.x])

	# 逐字：一帧之后第一行还没显示完
	await create_timer(0.12, true).timeout
	var first_line: String = str(act["lines"][0])
	_check("逐字显示中（未显示完）", panel._line_labels[0].text.length() < first_line.length(),
		"已显示 %d/%d" % [panel._line_labels[0].text.length(), first_line.length()])
	panel.advance()
	_check("点一下立即补完当前行", panel._line_labels[0].text == first_line)
	_check("补完时还没有结束", panel.is_open())

	# 把剩下的行推完
	var count: int = act["lines"].size()
	for i in range(count):
		panel.advance()
		if panel.is_open():
			panel.advance()
	_check("走完所有行后自动结束", not panel.is_open())
	_check("结束时 visible=false", not panel.visible)
	_check("结束事件只发一次且 skipped=false",
		events.size() == 1 and events[0] == false, str(events))

	# 跳过
	panel.play(Story.act(5)["lines"], Story.title(5), Story.progress_text(5), Story.tint(5))
	await process_frame
	panel.skip()
	_check("跳过立刻结束", not panel.is_open())
	_check("跳过事件带 skipped=true", events.size() == 2 and events[1] == true, str(events))

	# 手机横屏：整屏只有 720 虚拟高，设计稿要压到 0.54 倍，
	# 桌面那套字号落到手机上只剩 11 号字。触屏必须单独放大一档，
	# 而且提示不能叫触屏玩家去按一个不存在的空格键。
	print("\n[触屏排版]")
	var desktop_skip: Rect2 = btn
	var touch_panel := StoryPanel.new()
	touch_panel.force_touch = true
	root.add_child(touch_panel)
	await process_frame
	_check("触屏走放大档", is_equal_approx(touch_panel._s, StoryPanel.TOUCH_SCALE),
		"s=%.2f" % touch_panel._s)
	touch_panel.play(act["lines"], Story.title(0), Story.progress_text(0), Story.tint(0))
	await process_frame
	var t_btn: Rect2 = touch_panel._skip_btn.get_global_rect()
	var t_panel: Rect2 = touch_panel.get_global_rect()
	_check("触屏跳过键没被右边界裁掉", t_btn.end.x <= t_panel.end.x + 1.0,
		"btn.right=%.0f panel.right=%.0f" % [t_btn.end.x, t_panel.end.x])
	_check("触屏跳过键比桌面大一档", t_btn.size.y > desktop_skip.size.y + 4.0,
		"touch=%.0f desktop=%.0f" % [t_btn.size.y, desktop_skip.size.y])
	_check("触屏提示不叫玩家按空格",
		touch_panel._hint.text.contains("点一下") and not touch_panel._hint.text.contains("空格"),
		touch_panel._hint.text)
	_check("触屏正文字号更大",
		touch_panel._line_labels[0].get_theme_font_size("font_size")
			> panel._line_labels[0].get_theme_font_size("font_size"),
		"touch=%d desktop=%d" % [
			touch_panel._line_labels[0].get_theme_font_size("font_size"),
			panel._line_labels[0].get_theme_font_size("font_size")])
	touch_panel.queue_free()

	print("\n[与主流程接线]")
	var game: Node = load("res://MY主场景.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started(PLAYER, HeroClass.WARRIOR)
	await process_frame
	_check("开局先进剧情", game._state == 7, "state=%d" % game._state)
	_check("剧情屏正在显示", game.story_panel.visible)
	_check("剧情期间世界冻结", paused, "paused=%s" % paused)
	_check("第一幕标题", game.story_panel._title.text.contains("铁门之后"),
		game.story_panel._title.text)

	game.story_panel.skip()
	await process_frame
	_check("跳过后回到游戏", game._state == 1, "state=%d" % game._state)
	_check("跳过后解除冻结", not paused)
	_check("跳过后打第一幕横幅", game.hud._banner.visible and game.hud._banner_title.text.contains("铁门之后"),
		game.hud._banner_title.text)

	# 穿一道门：第 2 幕的剧情必须马上接上
	game._open_portals(game.player.global_position)
	await process_frame
	_check("Boss 死后开门", game._portals.size() == 4, "%d 扇" % game._portals.size())
	game._pending_portal = game._portals[0]
	game._confirm_portal()
	await process_frame
	_check("穿门后立刻进剧情", game._state == 7, "state=%d" % game._state)
	_check("剧情是第 2 幕", game.story_panel._title.text.contains("第二幕"),
		game.story_panel._title.text)
	_check("门计数 +1", game._portal_count == 1, "%d" % game._portal_count)
	game.story_panel.skip()
	await process_frame
	_check("第 2 幕开始后幕号推进", game._map_index == 1, "map=%d" % game._map_index)
	# 选门要记进账本：结算时判结局、确认面板上"走过的路"都读这份账。
	# 不记账的话，十个选择就白选了——而玩家不会知道，因为结算照样能出。
	_check("穿门记了一笔账", int(game._gate_trail.get("card", 0)) == 1,
		str(game._gate_trail))
	_check("最后一次选择被记住", game._last_choice == "card", game._last_choice)


func _all_texts() -> Array[String]:
	var out: Array[String] = []
	out.append(Story.prologue())
	out.append(Story.merchant_line())
	for i in range(Story.act_count()):
		var act: Dictionary = Story.act(i)
		out.append(Story.title(i))
		out.append(Story.beat(i))
		out.append(Story.defeat_title(i))
		out.append(Story.defeat_line(i, false))
		out.append(Story.defeat_line(i, true))
		for line in act["lines"]:
			out.append(str(line))
	for i in range(Story.gauntlet_count()):
		out.append(str(Story.gauntlet(i)["name"]))
		out.append(str(Story.gauntlet(i)["line"]))
	# 五个结局的全部文字（名字、门外名、一句由来、三行收尾）
	for key in Story.ending_order():
		out.append(Story.ending_title(key))
		out.append(Story.ending_name(key))
		out.append(Story.ending_gate(key))
		out.append(Story.ending_lead(key))
		for line in Story.ending_lines(key):
			out.append(line)
	# 终章
	out.append(Story.finale_title())
	out.append(Story.finale_beat())
	out.append("十道门 · 走完了")
	for line in Story.finale_lines():
		out.append(str(line))

	# 界面上新增的固定文案。字体子集少一个字，这几句里就会出现一个方块，
	# 所以它们和台词一样要过一遍 has_char。
	var ui_strings: Array[String] = [
		"点击 或 空格 继续　·　右上角可跳过",
		"点一下继续　·　右上角可跳过",
		"跳过",
		"你走出了城堡",
		"打开西城门 · 附带奖励",
		"第 %d 次逃出城堡 · 累计击杀 %d",
		"守门人 · ",
		"关底 · ",
		"西城门开了",
		"走出去，这一局就结束了",
		"还站着 %d 位",
		"守门人倒下",
		"离开城堡",
		"西门外 · 黎明",
		"塔里的商人",
		"走出城堡？",
		"进入下一幕？",
		"西门外是「%s」。",
		"这扇门给的是：结算本局，记下分数",
		"走出去",
		"再逛逛",
		"第 %d/%d 幕",
		"王子 · 黑暗城堡 · 十道门",
		"穿过十道门 · 王座厅连战五位守门人 · 走出西门即逃离",
		"每一道门怎么选，决定门外是哪一种结局（共 %d 种）",
		"结局 %d/%d · %s　——　%s",
		"已解锁 %d/%d 个结局",
		"五个结局，你都见过了",
		"走过的路：%s",
		"稳 0 · 贪 0 · 战 0 · 财 0",
		"门外是「%s」——十道门是怎么走的，这里就长什么样",
		"逃出 %d",
		"第 %d 幕 · 王座厅　·　守门人 %d/%d",
		"击杀",
		"时长",
		"成长",
		"逃离",
		"总分",
		"个人最高 %d · 新纪录！",
		"再来一局",
		"换人",
		"死因：被敌人淹没",
		"死因：倒在安全区外",
		"第二阶段",
		"第一阶段",
		"%d/%d · 第一阶段",
	]
	for text in ui_strings:
		out.append(text)
	return out
