extends SceneTree

## 外部打断暂停自检：竖屏 / 切后台 都不能让游戏偷跑。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/pause_check.gd
## 输出 .workbuddy/pause.txt
##
## 这里测的是判断逻辑，不是浏览器：headless 没有 JavaScriptBridge，
## 所以直接调 _on_web_pause() —— 它只读参数、改一个集合，
## 与"回调被 JS 调用"这条路径走的是同一段代码。
## shell 是否真的发出了这次调用，归 dev/web_pause_check.mjs 管。

const MAX_FRAMES: int = 4000

var _game: Node = null
var _out: PackedStringArray = []
var _step: int = 0
var _wait: int = 0
var _fails: int = 0
var _frames: int = 0
var _done: bool = false


func _initialize() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		_out.append("FAIL 主场景加载失败")
		_flush()
		quit()
		return
	root.add_child(packed.instantiate())


func _process(_delta: float) -> bool:
	if _done:
		return true
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_out.append("=== 外部打断暂停自检 ===")
		_wait = 3
		return false

	if _wait > 0:
		_wait -= 1
		return false

	_frames += 1
	if _frames > MAX_FRAMES:
		_out.append("FAIL 超过 %d 帧仍未跑完，测试自身可能卡住了" % MAX_FRAMES)
		_fails += 1
		_finish()
		return true

	match _step:
		0:
			# 基线：没在跑的话后面所有暂停断言都没意义
			_game._on_menu_started("check", HeroClass.WARRIOR)
			_check("开局后进入 PLAYING", _game._state == 1, "state=%d" % _game._state)
			_check("开局后没有暂停", not paused, "paused=true")
			_check("开局时没有外部原因", _has("portrait") == false and _has("hidden") == false, _reasons())
			_next()
		1:
			# 竖屏：冻结，但状态机不许动
			var before: int = _game._state
			_game._on_web_pause(["portrait", 1])
			_check("竖屏后暂停", paused, "paused=false")
			_check("竖屏不改 _state", _game._state == before, "state %d→%d" % [before, _game._state])
			_check("竖屏记入原因集合", _has("portrait"), _reasons())
			_next()
		2:
			# 幂等：真机上 change 事件会连发
			var t0: float = _game._elapsed
			_game._on_web_pause(["portrait", 1])
			_check("重复竖屏仍暂停", paused, "")
			_check("重复竖屏不推进时间", is_equal_approx(_game._elapsed, t0), "")
			_next()
		3:
			_game._on_web_pause(["portrait", 0])
			_check("横屏后恢复", not paused, "paused=true")
			_check("横屏后 _state 仍是 PLAYING", _game._state == 1, "state=%d" % _game._state)
			_check("横屏清掉原因", not _has("portrait"), _reasons())
			_next()
		4:
			# 切后台
			_game._on_web_pause(["hidden", 1])
			_check("切后台后暂停", paused, "paused=false")
			_check("切后台不改 _state", _game._state == 1, "state=%d" % _game._state)
			_check("切后台记入原因集合", _has("hidden"), _reasons())
			_next()
		5:
			_game._on_web_pause(["hidden", 0])
			_check("回前台后恢复", not paused, "paused=true")
			_check("回前台后 _state 仍是 PLAYING", _game._state == 1, "state=%d" % _game._state)
			_next()
		6:
			# 两个原因同时成立：解除一个不能恢复。
			# 手机上的真实场景是"竖着切到微信，再切回来还竖着"——
			# 如果这里用两个独立 bool 的 or，就会在横屏的瞬间把游戏放跑。
			_game._on_web_pause(["portrait", 1])
			_game._on_web_pause(["hidden", 1])
			_check("双原因都记下", _has("portrait") and _has("hidden"), _reasons())
			_game._on_web_pause(["portrait", 0])
			_check("只解除竖屏仍然暂停", paused, "还在后台却把游戏放跑了")
			_check("此时只剩 hidden", _has("hidden") and not _has("portrait"), _reasons())
			_game._on_web_pause(["hidden", 0])
			_check("两个都解除才恢复", not paused, "paused=true")
			_next()
		7:
			# 核心诉求：选卡时切后台，回来必须还停在卡片上。
			# 这里直接改 _state 而不是真弹面板：测的是 _sync_pause 的判断，
			# 面板本身的构建早被 stage_check 覆盖过了。
			_game._state = 2
			_game.get_tree().paused = true
			_game._on_web_pause(["hidden", 1])
			_game._on_web_pause(["hidden", 0])
			_check("选卡时切后台回来不偷跑", paused, "paused=false —— 玩家会带着没选的卡挨打")
			_check("选卡时切后台仍是选卡态", _game._state == 2, "state=%d" % _game._state)
			_check("选卡时切后台后原因已清空", _game._external_pauses.is_empty(), str(_game._external_pauses))
			_next()
		8:
			# 结算同理：直接跳回游戏等于把死因藏了
			_game._state = 3
			_game.get_tree().paused = true
			_game._on_web_pause(["hidden", 1])
			_game._on_web_pause(["hidden", 0])
			_check("结算时切后台回来不偷跑", paused, "paused=false")
			_next()
		9:
			# 菜单：本来就是暂停态
			_game._open_menu()
			_game._on_web_pause(["portrait", 1])
			_game._on_web_pause(["portrait", 0])
			_game._on_web_pause(["hidden", 1])
			_game._on_web_pause(["hidden", 0])
			_check("菜单时切后台/旋转仍暂停", paused, "paused=false")
			_check("菜单时 _state 是 MENU", _game._state == 0, "state=%d" % _game._state)
			_next()
		10:
			# 竖屏/后台状态下真正开局（bot 与自检会直接调，玩家点不到按钮）：
			# 开局那行不能把 paused 硬写 false
			_game._on_web_pause(["hidden", 1])
			_game._on_menu_started("check", HeroClass.MAGE)
			_check("后台开局仍冻结", paused, "paused=false —— 玩家没看见就挨打了")
			_check("后台开局 _state 是 PLAYING", _game._state == 1, "state=%d" % _game._state)
			_game._on_web_pause(["hidden", 0])
			_check("切回前台后恢复", not paused, "paused=true")
			_next()
		11:
			# 异常入参不能崩：JS 侧是数组，但没人保证长度
			_game._on_web_pause([])
			_game._on_web_pause(["portrait"])
			_game._on_web_pause(["", 1])
			_check("缺参数/空原因不崩溃且不改状态", not paused, "被坏参数弄成了暂停或崩溃")
			_next()
		12:
			# 非 web 平台 _publish_web_state 必须是空操作（headless 就是这一档）
			_check("非 web 平台不建立桥", not _game._web_bridged, "_web_bridged=true 说明 OS.has_feature 判断失效")
			_game._publish_web_state()
			_check("非 web 平台 publish 不崩溃", true, "")
			_finish()

	# 每一步只推进一步，下一帧再判断：暂停/恢复要真的经过一次帧边界才算数
	return _done


func _has(reason: String) -> bool:
	return _game._external_pauses.has(reason)


func _reasons() -> String:
	var keys: Array = _game._external_pauses.keys()
	return "reasons=[]" if keys.is_empty() else "reasons=" + str(keys)


func _next() -> void:
	_step += 1
	_wait = 2


func _check(label: String, ok: bool, detail: String) -> void:
	if ok:
		_out.append("[OK]   %s" % label)
	else:
		_out.append("[FAIL] %s%s" % [label, "" if detail.is_empty() else " —— " + detail])
		_fails += 1


func _finish() -> void:
	_done = true
	_out.append("")
	_out.append("=== %s（失败 %d 项）===" % ["全部通过" if _fails == 0 else "存在问题", _fails])
	_flush()
	quit()


func _flush() -> void:
	var f: FileAccess = FileAccess.open("res://.workbuddy/pause.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_out))
		f.close()
