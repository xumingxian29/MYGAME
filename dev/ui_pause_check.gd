extends SceneTree

## 暂停键 / 返回键自检。纯接线断言，不开画面。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/ui_pause_check.gd
##
## 与 dev/pause_check.gd 分工：那份测**外部打断**（竖屏/切后台推 __nsPause），
## 这份测**玩家主动按的那两颗按钮**。两者都会让 get_tree().paused 变 true，
## 但入口和状态机完全不同，不能互相代替。
##
## 覆盖五件事：
##   1. 暂停真的冻结：世界推进 30 帧后 _elapsed 一点没涨
##   2. 继续真的解冻：恢复后 _elapsed 继续走
##   3. 状态边界：选卡 / 结算时按暂停必须无效（否则面板会叠面板）
##   4. 暂停中重开：状态、暂停标志、面板可见性、局内计时全部归零
##   5. 返回键：回主菜单后 HUD 隐藏、面板收起，不留一颗还挂在屏幕上的按钮
##
## _elapsed 的断言必须在 PLAYING 下推进物理帧才有意义：Game 是 PROCESS_MODE_ALWAYS，
## _physics_process 会照常被调用，靠的是它开头那句 `_state != PLAYING` 提前返回——
## 这条路径正是本自检要验的东西。

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
	game._on_menu_started("探针", HeroClass.WARRIOR)
	await process_frame

	print("\n[开局]")
	_check("开局是 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)
	_check("开局未暂停", paused == false)
	_check("暂停面板不可见", game.hud._pause_panel.visible == false)

	print("\n[暂停]")
	game._on_pause_toggled()
	_check("状态切到 PAUSED", game._state == game.State.PAUSED, "state=%d" % game._state)
	_check("整棵树已暂停", paused == true)
	_check("面板已弹出", game.hud._pause_panel.visible == true)
	_check("按钮文字变『继续』", game.hud._pause_btn.text == "继续", game.hud._pause_btn.text)
	_check("遮罩已亮", game.hud._dim.visible == true)

	var frozen: float = game._elapsed
	for i in range(30):
		await physics_frame
	_check("暂停 30 帧后 _elapsed 没动", is_equal_approx(game._elapsed, frozen),
		"%.3f → %.3f" % [frozen, game._elapsed])

	print("\n[继续]")
	game._on_pause_toggled()
	_check("状态回到 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)
	_check("整棵树已解冻", paused == false)
	_check("面板已收起", game.hud._pause_panel.visible == false)
	_check("按钮文字回『暂停』", game.hud._pause_btn.text == "暂停", game.hud._pause_btn.text)
	_check("遮罩已关", game.hud._dim.visible == false)

	var resumed: float = game._elapsed
	for i in range(10):
		await physics_frame
	_check("继续后 _elapsed 恢复推进", game._elapsed > resumed,
		"%.3f → %.3f" % [resumed, game._elapsed])

	print("\n[状态边界]")
	# 选卡：本身已经冻结整棵树，再按暂停会把暂停面板盖到选卡上
	game._state = game.State.LEVEL_UP
	game._on_pause_toggled()
	_check("选卡时按暂停无效", game._state == game.State.LEVEL_UP, "state=%d" % game._state)
	_check("选卡时面板没弹", game.hud._pause_panel.visible == false)
	game._state = game.State.PLAYING
	game._sync_pause()

	game._state = game.State.GAME_OVER
	game._on_pause_toggled()
	_check("结算时按暂停无效", game._state == game.State.GAME_OVER, "state=%d" % game._state)
	game._state = game.State.PLAYING
	game._sync_pause()

	print("\n[暂停中重开]")
	game._elapsed = 42.0
	game._on_pause_toggled()
	_check("重开前确实处于暂停", game._state == game.State.PAUSED)
	game._restart()
	await process_frame
	_check("重开后是 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)
	_check("重开后已解冻", paused == false)
	_check("重开后 _elapsed 归零", game._elapsed < 0.1, "%.3f" % game._elapsed)
	_check("重开后暂停面板已收", game.hud._pause_panel.visible == false)
	_check("重开后按钮文字复位", game.hud._pause_btn.text == "暂停", game.hud._pause_btn.text)

	print("\n[按钮链路]")
	# 直接 emit pressed，而不是调 _on_pause_toggled：验的是"按钮 → 信号 → Game"整条线。
	# 鼠标/触摸命中没法在 headless 里测，但错连信号、漏接回调这类真错都能被抓到。
	_check("暂停键在 HUD 里可见", game.hud._pause_btn.is_visible_in_tree())
	_check("战斗中看不到返回键（只在暂停面板里）", game.hud._pause_panel.visible == false)
	game.hud._pause_btn.pressed.emit()
	_check("点暂停键 → PAUSED", game._state == game.State.PAUSED, "state=%d" % game._state)
	_check("暂停后返回键可见", game.hud._pause_menu_btn.is_visible_in_tree())
	game.hud._pause_btn.pressed.emit()
	_check("再点同一颗键 → PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)

	print("\n[返回键]")
	game._on_pause_toggled()
	game.hud._pause_menu_btn.pressed.emit()
	await process_frame
	_check("返回后是 MENU", game._state == game.State.MENU, "state=%d" % game._state)
	_check("返回后 HUD 已隐藏", game.hud._root.visible == false)
	_check("返回后暂停面板不可见", game.hud._pause_panel.visible == false)
	_check("返回后按钮文字复位", game.hud._pause_btn.text == "暂停", game.hud._pause_btn.text)
