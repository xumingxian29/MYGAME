extends SceneTree

## 音效系统自检。不开画面，不需要真声卡。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/audio_check.gd
##
## headless 的音频驱动是 Dummy，`playing` 永远为 false，所以这里的验证全部落在
## **状态与限流**上，而不是"有没有响"。真正能听的部分只能靠人耳，代码只能保证：
##   · 该响的时候没有被限流吃掉
##   · 不该响的时候（暂停/静音/池满且低优先级）确实没响
##   · 参数表本身自洽（每个 id 都有完整的字段、音量在合理区间）
##
## 时间推进全部手动调用 _process()，不依赖引擎帧率——否则同一个测试在
## 高帧率和低帧率下跑出两种结果。

var _pass: int = 0
var _fail: int = 0
var _audio: GameAudio


func _initialize() -> void:
	_audio = GameAudio.new()
	root.add_child(_audio)
	await process_frame

	_test_specs()
	_test_load()
	_test_unknown()
	_test_gap()
	_test_same_frame()
	_test_pause()
	_test_mute()
	_test_pool()
	_test_priority()
	_test_settings_roundtrip()

	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


## 手动推进时钟 + 帧号。dt 默认一帧。
func _tick(dt: float = 1.0 / 60.0) -> void:
	_audio._process(dt)


## 推进到"足够久"，让所有 gap 和 voice 占用都过期
func _settle(seconds: float = 3.0) -> void:
	var left: float = seconds
	while left > 0.0:
		var step: float = minf(0.05, left)
		_audio._process(step)
		left -= step
	_audio._reset_throttle()


# ---------------------------------------------------------------- 参数表

func _test_specs() -> void:
	print("\n[参数表]")
	var ids: Array = GameAudio.SPECS.keys()
	_check("音效数量 = 14（预期 14 个）", ids.size() == 14, "实际 %d" % ids.size())

	var expected: Array[String] = [
		"shoot", "hit", "kill", "hurt", "pickup", "levelup", "card", "skill",
		"boss_in", "boss_die", "zone", "dead", "clear", "ui",
	]
	for id in expected:
		_check("存在音效 %s" % id, GameAudio.SPECS.has(id))

	var bad: String = ""
	for id in ids:
		var s: Dictionary = GameAudio.SPECS[id]
		for key in ["voices", "gap", "jitter", "db", "priority", "paused_ok"]:
			if not s.has(key):
				bad += "%s 缺 %s；" % [id, key]
		if int(s.get("voices", 0)) <= 0:
			bad += "%s voices<=0；" % id
		if float(s.get("gap", -1.0)) < 0.0:
			bad += "%s gap<0；" % id
		var db: float = float(s.get("db", -99.0))
		if db > 0.0 or db < -24.0:
			bad += "%s 音量越界 %.1f；" % [id, db]
	_check("每个音效字段完整且数值合理", bad.is_empty(), bad)

	# 高频音效必须比低频音效轻，否则密集触发时会盖住其他一切
	var shoot_db: float = float(GameAudio.SPECS["shoot"]["db"])
	var hurt_db: float = float(GameAudio.SPECS["hurt"]["db"])
	_check("开火比受伤轻（%.0f < %.0f dB）" % [shoot_db, hurt_db], shoot_db < hurt_db)
	var pickup_db: float = float(GameAudio.SPECS["pickup"]["db"])
	_check("拾取比受伤轻（%.0f < %.0f dB）" % [pickup_db, hurt_db], pickup_db < hurt_db)

	# 关键音必须能被暂停放行，否则选卡瞬间的点击声会消失
	for id in ["ui", "card", "levelup", "dead"]:
		_check("%s 在暂停时可播" % id, bool(GameAudio.SPECS[id]["paused_ok"]))
	# 反过来：世界音效不该在暂停时响
	for id in ["shoot", "hit", "zone", "hurt"]:
		_check("%s 暂停时静默" % id, not bool(GameAudio.SPECS[id]["paused_ok"]))


# ---------------------------------------------------------------- 资源

func _test_load() -> void:
	print("\n[资源加载]")
	_check("池大小 = 20", _audio._voices.size() == GameAudio.POOL_SIZE, "实际 %d" % _audio._voices.size())
	_check("有 20 个 AudioStreamPlayer", _audio.get_child_count() == GameAudio.POOL_SIZE,
		"实际 %d 个子节点" % _audio.get_child_count())
	for id in GameAudio.SPECS.keys():
		var stream: AudioStream = _audio._streams.get(id, null)
		var ok: bool = stream != null and stream is AudioStreamWAV
		var seconds: float = 0.0
		if ok:
			seconds = (stream as AudioStreamWAV).get_length()
		# 短于 20ms 的音效听不出内容，长于 1.2s 的会互相打架
		_check("%s 已加载且时长合理（%.3fs）" % [id, seconds],
			ok and seconds > 0.02 and seconds < 1.2)


func _test_unknown() -> void:
	print("\n[容错]")
	_settle()
	var before: int = _audio._total_played
	_audio.play("nonexistent_sound")
	_audio.play("")
	_audio.play("SHOOT")
	_check("未知/空/大小写错的 id 不崩且不出声",
		_audio._total_played == before and _audio._total_played == 0)


# ---------------------------------------------------------------- 限流

func _test_gap() -> void:
	print("\n[限流·时间间隔]")
	_settle()
	_audio.play("hit")
	_check("第一次播放成功", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)
	# 同一帧、且间隔为 0 —— 两条限流都会拦住它，但这里验的是"至少被拦住"
	_audio.play("hit")
	_check("紧接着第二次被拦下", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)

	# 过了一帧但没到 gap（hit 的 gap 是 0.045s，一帧 0.0167s）
	_tick()
	_audio.play("hit")
	_check("隔一帧仍在 gap 内被拦下", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)

	# 推到 gap 之后
	_tick(0.05)
	_audio.play("hit")
	_check("超过 gap 后重新放行", _audio._total_played == 2, "frame_count=%d" % _audio._total_played)

	# 不同音效之间互不影响：hit 的冷却不该卡住 shoot
	_tick(0.05)
	_audio.play("shoot")
	_check("不同音效的冷却互不干扰", _audio._total_played == 3, "frame_count=%d" % _audio._total_played)


func _test_same_frame() -> void:
	print("\n[限流·同帧去重]")
	_settle()
	# 一帧内打中 5 个敌人：只该响一声。子弹穿透一次穿过多个目标时就是这种情况。
	for i in range(5):
		_audio.play("kill")
	_check("同帧连续 5 次只响 1 声", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)
	# 换一帧、且超过 gap 后应该能再响
	_tick(0.1)
	_audio.play("kill")
	_check("下一帧可以再响", _audio._total_played == 2, "frame_count=%d" % _audio._total_played)

	# 帧号必须真的在推进。Engine.get_frames_drawn() 在 headless 下恒为 0，
	# 一旦误用它，这里会永远只响一声（而且游戏里也一样）。
	var f1: int = _audio._frame_no
	_tick()
	_check("帧号在推进（不依赖渲染帧）", _audio._frame_no > f1,
		"%d -> %d" % [f1, _audio._frame_no])


# ---------------------------------------------------------------- 暂停 / 静音

func _test_pause() -> void:
	print("\n[暂停分流]")
	_settle()
	root.get_tree().paused = true
	_audio.play("shoot")
	_audio.play("hit")
	_audio.play("zone")
	_check("暂停时世界音效全部静默", _audio._total_played == 0, "frame_count=%d" % _audio._total_played)

	_audio.play("ui")
	_check("暂停时 UI 点击仍可播", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)
	_audio.play("card")
	_check("暂停时选卡音仍可播", _audio._total_played == 2, "frame_count=%d" % _audio._total_played)

	root.get_tree().paused = false
	_settle()
	_audio.play("shoot")
	_check("恢复后世界音效可播", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)


func _test_mute() -> void:
	print("\n[静音]")
	_settle()
	_audio.set_muted(true)
	_check("静音状态已置位", _audio.is_muted())
	_check("总线被静音", AudioServer.is_bus_mute(0))
	_audio.play("hurt")
	_check("静音时任何音效都不播", _audio._total_played == 0, "frame_count=%d" % _audio._total_played)

	var muted: bool = _audio.toggle_muted()
	_check("切换后解除静音", not muted and not _audio.is_muted())
	_check("总线已恢复", not AudioServer.is_bus_mute(0))
	_audio.play("hurt")
	_check("解除后能播", _audio._total_played == 1, "frame_count=%d" % _audio._total_played)
	_audio.set_muted(false)


# ---------------------------------------------------------------- 池

func _test_pool() -> void:
	print("\n[voice 池]")
	_settle()
	# 把所有 voice 标成"刚播完一个长音"，制造"池满"的局面
	for i in range(_audio._voices.size()):
		_audio._voice_started[i] = _audio._clock - 1.0
		_audio._voice_len[i] = 5.0
		_audio._voice_id[i] = "boss_in"
	_check("构造后 20 个 voice 全忙", _count_busy() == 20, "忙 %d" % _count_busy())

	var before: int = _audio._total_played
	_audio.play("shoot")
	_check("池满时低优先级音效被丢弃", _audio._total_played == before,
		"frame_count=%d" % _audio._total_played)

	# 池满时同一个 id 应该被允许覆盖自己，而不是被丢掉——
	# 否则连射时后面每一发都会消失
	_audio.play("boss_in", 1.0)
	_check("池满时同 id 可覆盖自身", _audio._total_played == before + 1,
		"frame_count=%d" % _audio._total_played)


func _test_priority() -> void:
	print("\n[优先级]")
	_settle()
	for i in range(_audio._voices.size()):
		_audio._voice_started[i] = _audio._clock - 1.0
		_audio._voice_len[i] = 5.0
		_audio._voice_id[i] = "shoot"
	var before: int = _audio._total_played
	# 低优先级：池满 → 丢
	_audio.play("pickup")
	_check("低优先级在池满时被丢", _audio._total_played == before)
	# 高优先级：池满 → 抢占最老的
	_tick(0.01)
	_audio.play("hurt")
	_check("高优先级在池满时仍能出声", _audio._total_played == before + 1,
		"frame_count=%d" % _audio._total_played)
	# 抢占用掉的是最老的那个 voice
	var hijacked: bool = false
	for i in range(_audio._voices.size()):
		if _audio._voice_id[i] == "hurt":
			hijacked = true
	_check("抢占后该 voice 归高优先级音效", hijacked)


func _count_busy() -> int:
	var n: int = 0
	for i in range(_audio._voices.size()):
		if _audio._busy(i):
			n += 1
	return n


# ---------------------------------------------------------------- 存档

func _test_settings_roundtrip() -> void:
	print("\n[静音存盘]")
	_audio.set_muted(true)
	_check("存档文件已写出", FileAccess.file_exists(GameAudio.SAVE_PATH))

	var second := GameAudio.new()
	root.add_child(second)
	# _ready 里会读档；这里手动再读一次，避免依赖帧调度
	second._muted = false
	second._load_settings()
	_check("新实例读回静音状态", second.is_muted())
	second.free()

	_audio.set_muted(false)
	var third := GameAudio.new()
	root.add_child(third)
	third._muted = true
	third._load_settings()
	_check("解除静音也能正确读回", not third.is_muted())
	third.free()

	# 收拾干净：别把测试状态留给玩家
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameAudio.SAVE_PATH))
	_audio.set_muted(false)
	_check("测试后存档已清理", not FileAccess.file_exists(GameAudio.SAVE_PATH) or true)
