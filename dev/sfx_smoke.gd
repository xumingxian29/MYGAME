extends SceneTree

## 音效冒烟测试：真开一局，让它自己打 40 秒，统计每个音效实际响了多少次。
##
## 为什么需要它：audio_check 验的是"限流规则对不对"，验不出"这套配置吵不吵"。
## 而"吵"是这个系统唯一的失败方式——每个音效单听都没问题，合在 200 只怪里就糊成一片。
## 这里给出**每秒实际发声次数**，用它判断该调哪个参数。
##
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/sfx_smoke.gd
##
## 判读标准（经验值，超过就说明太密）：
##   hit    < 12 次/秒   它是最容易失控的，子弹穿透时一帧就能触发好几次
##   shoot  < 3 次/秒    只给近战/回旋镖用，不该高
##   kill   < 8 次/秒
##   其他   合计 < 2 次/秒
## 总发声数（含被丢弃的尝试）也要看：如果"尝试次数"远大于"实际发声"，
## 说明限流在替玩家挡噪音，配置本身还没失控。

const SECONDS: float = 40.0
const HERO: int = HeroClass.RANGER

var _game: Node
var _audio: GameAudio
var _frames: int = 0


func _initialize() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		print("FAIL 主场景加载失败")
		quit(1)
		return
	_game = packed.instantiate()
	root.add_child(_game)
	await process_frame
	_game._on_menu_started("冒烟", HERO)
	await process_frame

	_audio = _game.audio
	if _audio == null:
		print("FAIL Game 没有 audio 节点")
		quit(1)
		return
	print("音效冒烟：%s，跑 %.0f 秒\n" % [HeroClass.title(HERO), SECONDS])

	# 让游戏自己跑。--fixed-fps 60 下每帧 1/60 秒，SECONDS 秒 = 60*SECONDS 帧。
	var total_frames: int = int(SECONDS * 60.0)
	while _frames < total_frames and is_instance_valid(_game):
		await process_frame
		_frames += 1
		# 升级时自动选第一张卡：不选的话整棵树是暂停的，游戏根本不会往前走
		if _game._state == 2:
			_game._choose(0)
		elif _game._state == 3:
			break

	var elapsed: float = _game._elapsed
	_report(elapsed)
	await _verify_wiring()
	# 测试会顺手标记"引导已看过"，这些记录一旦写进 user://tutorial.json，
	# 玩家下次真机首局就再也看不到新手提示了。清掉，并且提前关掉 dirty 标记，
	# 否则退出时节点析构会自动 flush 一次，把刚删的文件又写回来。
	_game.tutorial._seen_dirty = false
	var tut_path: String = ProjectSettings.globalize_path(TutorialHint.SAVE_PATH)
	if FileAccess.file_exists(TutorialHint.SAVE_PATH):
		DirAccess.remove_absolute(tut_path)
	quit(0)


## 上面 40 秒只覆盖了"自然发生"的音效。受伤、技能、圈外这些要靠条件触发，
## 站着不动的射手可能一整局都碰不到，所以这里直接驱动对应的游戏入口，
## 确认"事件 → 音效"这根线是接上的，而不是只在代码里写了。
func _verify_wiring() -> void:
	print("\n=== 定向接线验证 ===")
	var player = _game.player
	if not is_instance_valid(player):
		print("  SKIP 玩家已失效，跳过")
		return

	var cases: Array = [
		["hurt", func(): player.take_damage(5.0)],
		["skill", func():
			player.mana = player.max_mana
			_game._on_skill_button()],
		["boss_in", func():
			# 章节时钟推过本章长度，_check_boss 就会把 Boss 叫出来
			_game._stage_time = 999.0
			_game._check_boss()],
		["boss_die", func():
			# 上一项已经把 Boss 叫出来了，这里直接走击杀路径
			_game._on_boss_killed()],
		["zone", func():
			# 两个前置条件缺一不可：① 时间轴要走到有毒伤的段（前 110 秒 dps=0，
			# _tick_zone 会直接 return）；② 玩家必须真的在圈外。
			_game.zone.tick(100.0)
			player.global_position = _game.zone.center + Vector2(_game.zone.radius + 300.0, 0.0)
			_game._zone_dmg_timer = 0.0
			_game._tick_zone(0.5)],
		["clear", func():
			# 从第三章往前推一格 = 三章走完，这是唯一会播 clear 的分支
			_game._stage_index = Stage.COUNT - 1
			_game._cleared = false
			_game._advance_stage()],
	]
	for case in cases:
		var id: String = str(case[0])
		var before: int = int(_audio._plays_by_id.get(id, 0))
		# 清掉冷却：这些音效可能刚刚在自然战斗里响过
		_audio._last_play.erase(id)
		_audio._last_frame.erase(id)
		(case[1] as Callable).call()
		await process_frame
		var after: int = int(_audio._plays_by_id.get(id, 0))
		var ok: bool = after > before
		print("  %s %-9s %d → %d" % ["ok  " if ok else "FAIL", id, before, after])


func _report(elapsed: float) -> void:
	print("\n=== 实际发声统计（真实经过 %.1f 秒） ===" % elapsed)
	var ids: Array = GameAudio.SPECS.keys()
	ids.sort()
	var total: int = 0
	for id in ids:
		var n: int = int(_audio._plays_by_id.get(id, 0))
		total += n
		var per_sec: float = float(n) / maxf(elapsed, 0.1)
		var mark: String = ""
		if id == "hit" and per_sec > 12.0:
			mark = "  ← 太密"
		elif id == "shoot" and per_sec > 3.0:
			mark = "  ← 太密"
		elif id == "kill" and per_sec > 8.0:
			mark = "  ← 太密"
		print("  %-9s %5d 次  %5.2f 次/秒%s" % [id, n, per_sec, mark])
	print("  %-9s %5d 次  %5.2f 次/秒" % ["合计", total, float(total) / maxf(elapsed, 0.1)])

	print("\n=== 限流拦下的量 ===")
	# 无法直接数"被拦下"，用"每帧平均发声"侧面看：60fps 下单帧最多 20 个 voice，
	# 实际远小于这个数就说明限流生效且配置有余量
	print("  voice 池 %d，单帧理论峰值 20，实测平均 %.2f 次/帧" % [
		_audio._voices.size(), float(total) / maxf(float(_frames), 1.0),
	])

	print("\n=== 事件覆盖 ===")
	var missing: Array[String] = []
	for id in ids:
		if int(_audio._plays_by_id.get(id, 0)) == 0:
			missing.append(str(id))
	if missing.is_empty():
		print("  全部音效都在 40 秒内被触发过")
	else:
		# 有些音效本来就低频（boss_die / clear / dead），40 秒内没出现是正常的
		print("  未触发：%s（低频音效在这段时间内不出现属正常）" % String(", ").join(PackedStringArray(missing)))
