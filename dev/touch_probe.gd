extends Node

## 一次性自检：注入真实触摸事件，验证虚拟摇杆 / 技能键 / 暂停收起 / 结算按钮。
## 不是游戏的一部分，验收后删除。运行方式：
##   godot --headless --path . dev/touch_probe.tscn -- --touch

const HERO_NAME: String = "触屏测试"

var _pass: int = 0
var _fail: int = 0
## --shots：开窗跑时把关键界面存成 png，用来肉眼核对布局
var _want_shots: bool = OS.get_cmdline_user_args().has("--shots")


func _ready() -> void:
	# 无头模式的假窗口只有 64x64，会让"960 基准 + expand"算出 1:1 的方形画布，
	# 摇杆半径与拖拽距离全部失真。先钉成 1280x720，画布才是标准的 960x540。
	get_window().size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://MY主场景.tscn")
	var game: Node = scene.instantiate()
	add_child(game)
	await _wait(0.2)

	var touch: Node = game.get("touch")
	var hud: Node = game.get("hud")

	_check("触屏操作层已创建", touch != null)
	_check("识别为触屏设备", touch.call("has_touch") == true)
	_check("菜单阶段摇杆不显示", touch.call("is_active") == false)
	_check("HUD 已切到触屏文案", hud.call("is_touch_mode") == true)
	_check("逻辑分辨率 960x540",
		game.get_window().content_scale_size == Vector2i(960, 540))

	game.call("_on_menu_started", HERO_NAME, HeroClass.WARRIOR)
	await _wait(0.15)
	var player: Node = game.get("player")
	_check("开局后摇杆激活", touch.call("is_active") == true)
	_check("玩家已生成", player != null and is_instance_valid(player))
	if player == null:
		_finish()
		return

	await _test_stick(touch, player)
	await _test_skill(touch, player)
	await _test_multitouch(game, touch, player)
	await _test_pause(game, touch, player)
	await _test_death(game, touch, player)
	_finish()


# ---------------------------------------------------------------- 摇杆

func _test_stick(touch: Node, player: Node) -> void:
	var rest: Vector2 = touch.get("_stick_rest")
	var xf: Transform2D = get_viewport().get_screen_transform()

	# 1. 满推：84 半径推 70，力度 0.83
	var start: Vector2 = player.global_position
	var t0: float = _now()
	_touch_down(0, xf * rest)
	await get_tree().process_frame
	_touch_drag(0, xf * (rest + Vector2(0.0, -70.0)))
	await _wait(0.6)
	var dy: float = player.global_position.y - start.y
	var dt: float = _now() - t0
	_check("上推摇杆角色向上移动（%.0f px / %.2fs）" % [dy, dt], dy < -40.0)
	_check("垂直于推动方向几乎不漂移", absf(player.global_position.x - start.x) < 6.0)

	# 2. 半推：同样时长位移应明显更小（模拟量，不是"按下即满速"）
	await _wait(0.05)
	var mid: Vector2 = player.global_position
	_touch_drag(0, xf * (rest + Vector2(0.0, -30.0)))
	await _wait(0.6)
	var half_dy: float = player.global_position.y - mid.y
	_check("半推比满推慢（%.0f px vs %.0f px）" % [-half_dy, -dy], -half_dy < -dy * 0.3)

	# 3. 松手：动作归零、角色停住
	_touch_up(0, xf * (rest + Vector2(0.0, -30.0)))
	await get_tree().process_frame
	_check("松手后 move_up 归零", Input.get_action_strength("move_up") < 0.01)
	_check("松手后 move_right 归零", Input.get_action_strength("move_right") < 0.01)
	var stop_at: Vector2 = player.global_position
	await _wait(0.3)
	_check("松手后角色停在原地", player.global_position.distance_to(stop_at) < 1.0)

	# 4. 浮动摇杆：按在明显远离底盘的位置（> 1.6 倍半径），底盘跟到指尖下
	var far: Vector2 = Vector2(rest.x, rest.y - 200.0)
	_touch_down(0, xf * far)
	await get_tree().process_frame
	_check("浮动摇杆把底盘挪到指尖", touch.get("_stick_center").distance_to(far) < 2.0)
	_touch_drag(0, xf * (far + Vector2(70.0, 0.0)))
	await _wait(0.4)
	_check("浮动摇杆也能向右移动", player.global_position.x - stop_at.x > 20.0)
	_touch_up(0, xf * (far + Vector2(70.0, 0.0)))
	await _wait(0.1)


# ---------------------------------------------------------------- 技能键

func _test_skill(touch: Node, player: Node) -> void:
	var xf: Transform2D = get_viewport().get_screen_transform()
	var center: Vector2 = touch.get("_skill_center")

	_check("技能键位置在右下角",
		center.x > get_viewport().get_visible_rect().size.x * 0.8
		and center.y > get_viewport().get_visible_rect().size.y * 0.7)

	# 空蓝点技能：不应该放出去
	player.set("mana", 0.0)
	player.emit_signal("mana_changed", 0.0, player.get("max_mana"))
	_touch_down(1, xf * center)
	await get_tree().process_frame
	_touch_up(1, xf * center)
	await get_tree().process_frame
	_check("空蓝点技能无效", player.get("mana") < 1.0)

	# 满蓝点技能：清空蓝条 + 触发技能
	player.set("mana", player.get("max_mana"))
	player.emit_signal("mana_changed", player.get("max_mana"), player.get("max_mana"))
	await get_tree().process_frame
	_check("满蓝时摇杆层标记为就绪", touch.get("_skill_ready") == true)
	_touch_down(1, xf * center)
	await get_tree().process_frame
	_touch_up(1, xf * center)
	await get_tree().process_frame
	_check("满蓝点技能后蓝条清零", player.get("mana") < 0.5)
	_check("技能确实放出去了", player.get("_skill_fx_t") > 0.0)


# ---------------------------------------------------------------- 双指同时

func _test_multitouch(game: Node, touch: Node, player: Node) -> void:
	var xf: Transform2D = get_viewport().get_screen_transform()
	var rest: Vector2 = touch.get("_stick_rest")
	var center: Vector2 = touch.get("_skill_center")

	var start: Vector2 = player.global_position
	player.set("mana", player.get("max_mana"))
	player.emit_signal("mana_changed", player.get("max_mana"), player.get("max_mana"))

	_touch_down(0, xf * rest)
	await get_tree().process_frame
	_touch_drag(0, xf * (rest + Vector2(0.0, -70.0)))
	await get_tree().process_frame
	_touch_down(1, xf * center)
	await get_tree().process_frame
	# 蓝条会自然回复（战士 2.2 / 秒），所以必须当场读，不能等 0.4 秒后
	var mana_after_press: float = player.get("mana")
	_touch_up(1, xf * center)
	await _wait(0.4)

	_check("一指推摇杆时另一指点技能不打断移动",
		player.global_position.y - start.y < -15.0)
	_check("同一次双指操作技能也放出来了（蓝条 %.1f）" % mana_after_press, mana_after_press < 0.5)
	_touch_up(0, xf * (rest + Vector2(0.0, -70.0)))
	await get_tree().process_frame
	_check("抬起摇杆那只手后动作归零", Input.get_action_strength("move_up") < 0.01)


# ---------------------------------------------------------------- 暂停收起

func _test_pause(game: Node, touch: Node, player: Node) -> void:
	var xf: Transform2D = get_viewport().get_screen_transform()
	var rest: Vector2 = touch.get("_stick_rest")

	# 按住摇杆时升级：摇杆必须收起，并且残留动作要松开，否则暂停里角色还在滑
	_touch_down(0, xf * rest)
	await get_tree().process_frame
	_touch_drag(0, xf * (rest + Vector2(70.0, 0.0)))
	await get_tree().process_frame

	game.call("_open_level_up")
	await get_tree().process_frame
	await _shot("probe_levelup.png")
	_check("升级选卡时摇杆收起", touch.call("is_active") == false)
	_check("暂停时残留的移动动作被松开", Input.get_action_strength("move_right") < 0.01)

	game.call("_choose", 0)
	await get_tree().process_frame
	_check("选完卡摇杆恢复", touch.call("is_active") == true)
	_touch_up(0, xf * (rest + Vector2(70.0, 0.0)))
	await get_tree().process_frame


# ---------------------------------------------------------------- 结算

func _test_death(game: Node, touch: Node, player: Node) -> void:
	var hud: Node = game.get("hud")
	# 前面很可能刚被贴身的小怪打过，无敌帧还没过：先清掉，否则伤害会被直接吞掉
	player.set("_invuln", 0.0)
	player.call("take_damage", 99999.0)
	await _wait(0.2)
	_check("死亡后摇杆收起", touch.call("is_active") == false)
	_check("结算面板出现", hud.get("_panel").visible == true)

	var buttons: Array[Button] = []
	_collect_buttons(hud.get("_panel_box"), buttons)
	await _shot("probe_gameover.png")
	_check("结算面板有 2 个可点按钮（再来一局 / 换人）", buttons.size() == 2)
	if buttons.size() == 2:
		_check("按钮文案：%s / %s" % [buttons[0].text, buttons[1].text],
			buttons[0].text == "再来一局" and buttons[1].text == "换人")
		_check("按钮尺寸够手指点（≥ 150x48）",
			buttons[0].custom_minimum_size.x >= 150.0 and buttons[0].custom_minimum_size.y >= 48.0)
		buttons[0].emit_signal("pressed")
		await _wait(0.2)
		_check("点「再来一局」重新开局", touch.call("is_active") == true
			and game.get("player") != null)


func _collect_buttons(node: Node, out: Array[Button]) -> void:
	for child in node.get_children():
		if child is Button:
			out.append(child)
		_collect_buttons(child, out)


# ---------------------------------------------------------------- 工具

func _shot(file_name: String) -> void:
	if not _want_shots:
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/" + file_name)
	print("  shot -> ", file_name)


func _touch_down(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = true
	Input.parse_input_event(ev)


func _touch_drag(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	Input.parse_input_event(ev)


func _touch_up(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = false
	Input.parse_input_event(ev)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _check(name: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS  ", name)
	else:
		_fail += 1
		print("  FAIL  ", name)


func _finish() -> void:
	print("")
	print("==== 触屏自检：%d 通过 / %d 失败 ====" % [_pass, _fail])
	get_tree().quit(0 if _fail == 0 else 1)
