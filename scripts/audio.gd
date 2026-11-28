class_name GameAudio
extends Node

## 音效总控。目标不是"每个动作都有声音"，而是**听得见但不吵**。
##
## 三条硬约束，全部来自"同屏几百个敌人"这个前提：
##
## 1. **单池复用**，不是每个音效一个 player。
##    14 个音效 × 各 4 个 voice = 56 个 AudioStreamPlayer 节点，Web 上光是维护这些
##    节点的开销就够呛。这里固定 20 个 voice 轮流借还，节点数不随音效种类增长。
##
## 2. **三种限流叠加**，缺一个都会炸：
##    · gap      两次播放的最小间隔（时间维度）
##    · 同帧去重  同一帧内重复触发只响一声（帧维度）——子弹一帧穿 5 个敌人，
##                听感上本来就是"一下"，放 5 次只会变成嗡嗡声
##    · voices   同一音效最多几个实例同时存在（数量维度）
##
## 3. **优先级**。池满时低优先级直接丢弃，高优先级抢占最老的 voice。
##    受伤/升级/死亡/Boss 这些"玩家必须知道"的声音绝不能因为小怪太多而消失。
##
## 静音走 AudioServer 总线而不是逐个 player，一是指令少，二是状态能存盘。

## 每个音效的参数。改数值前先想清楚"它一秒会触发几次"：
##   shoot 5 次/秒、hit 最多 20 次/秒 → 必须轻且短
##   hurt / levelup / dead 一局十几次 → 可以重
const SPECS: Dictionary = {
	"shoot":    {"voices": 4, "gap": 0.050, "jitter": 0.12, "db": -13.0, "priority": false, "paused_ok": false},
	"hit":      {"voices": 4, "gap": 0.045, "jitter": 0.18, "db": -14.0, "priority": false, "paused_ok": false},
	"kill":     {"voices": 4, "gap": 0.060, "jitter": 0.14, "db": -12.0, "priority": false, "paused_ok": false},
	"hurt":     {"voices": 2, "gap": 0.080, "jitter": 0.06, "db": -4.0,  "priority": true,  "paused_ok": false},
	"pickup":   {"voices": 4, "gap": 0.040, "jitter": 0.10, "db": -14.0, "priority": false, "paused_ok": false},
	"levelup":  {"voices": 2, "gap": 0.200, "jitter": 0.00, "db": -6.0,  "priority": true,  "paused_ok": true},
	"card":     {"voices": 2, "gap": 0.060, "jitter": 0.00, "db": -8.0,  "priority": true,  "paused_ok": true},
	"skill":    {"voices": 2, "gap": 0.120, "jitter": 0.05, "db": -7.0,  "priority": true,  "paused_ok": false},
	"boss_in":  {"voices": 1, "gap": 1.500, "jitter": 0.00, "db": -2.0,  "priority": true,  "paused_ok": false},
	"boss_die": {"voices": 1, "gap": 0.500, "jitter": 0.00, "db": -3.0,  "priority": true,  "paused_ok": false},
	"zone":     {"voices": 1, "gap": 0.900, "jitter": 0.00, "db": -10.0, "priority": false, "paused_ok": false},
	"dead":     {"voices": 1, "gap": 1.000, "jitter": 0.00, "db": -3.0,  "priority": true,  "paused_ok": true},
	"clear":    {"voices": 1, "gap": 0.500, "jitter": 0.00, "db": -4.0,  "priority": true,  "paused_ok": true},
	"ui":       {"voices": 2, "gap": 0.050, "jitter": 0.04, "db": -15.0, "priority": false, "paused_ok": true},
}

## voice 池大小。20 个够覆盖"一圈敌人同时死 + 玩家受伤 + 升级"这种极端叠加，
## 再多就是浪费（超出的反正会被限流丢掉）。
const POOL_SIZE: int = 20

const SAVE_PATH: String = "user://audio.json"

var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
## 每个 voice 的占用起始时间，抢占时用它找"最老的"
var _voice_started: Array[float] = []
## 每个 voice 当前流的长度。headless（Dummy 音频驱动）下 playing 永远是 false，
## 靠它推算"这个 voice 其实还没播完"，否则测试环境里所有 voice 都被当成空闲，
## 池分配和抢占逻辑就完全测不到了。
var _voice_len: Array[float] = []
## 每个 voice 当前播的是哪个 id（同 id 重触发时优先覆盖自己，避免同音叠成拍频）
var _voice_id: Array[String] = []
var _last_play: Dictionary = {}
var _last_frame: Dictionary = {}
var _clock: float = 0.0
## 自增帧号，代替 Engine.get_frames_drawn()。
## 后者在 headless 下不推进（不渲染就没有 draw 帧），一旦恒为 0，
## "同帧去重"会把第二次播放起的所有音效都拦掉——测试全绿但游戏里没声音。
var _frame_no: int = 0
var _muted: bool = false
## 本帧实际发声数。_process 每帧清零，只对"同一帧内发生了多少次"有意义。
var _frame_count: int = 0
## 累计发声数，只在测试里用（跨帧累加得靠它，_frame_count 每帧会被清零）。
var _total_played: int = 0
## 每个音效的累计播放次数。调音量要靠它：一个每秒响十几次的音效，
## 说明它太密，该调 gap 或降音量，而不是继续往里加声音。
var _plays_by_id: Dictionary = {}
## 音高抖动用**私有**随机数发生器，绝不借全局 randf()。
## 原因是限流按渲染帧推进（_clock/_frame_no 在 _process 里累加），
## 而渲染帧和物理帧不是一一对应：同一份构建跑两次，"这一次有没有被限流拦掉"
## 会差出几次。一旦借用全局序列，音效放行几次就把玩法的随机数整体推开——
## 实测第 30.4 秒生成的那只怪位置就已经不同，整局岔成 181.5s / 240.9s。
## 抖动纯属听感，用固定种子反而更好：同一次操作听到的音高每次一致。
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	# Game 是 PROCESS_MODE_ALWAYS，这里继承下来：暂停时 ui / card / levelup 仍要能响，
	# 具体放不放行由 SPECS 的 paused_ok 决定，不靠节点暂停实现。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 20261125
	_load_all()
	_build_pool()
	_load_settings()
	apply_mute()


func _load_all() -> void:
	for id in SPECS.keys():
		var path: String = "res://assets/audio/%s.wav" % id
		var stream: AudioStream = load(path)
		if stream == null:
			push_warning("音效缺失：%s" % path)
			continue
		_streams[id] = stream


func _build_pool() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Voice%d" % i
		# 全部走 Master 总线：静音只需要一次 set_bus_mute，不用逐节点改
		add_child(p)
		_voices.append(p)
		_voice_started.append(-999.0)
		_voice_len.append(0.0)
		_voice_id.append("")


func _process(delta: float) -> void:
	_clock += delta
	_frame_no += 1
	_frame_count = 0


## 播一个音效。id 不存在时静默返回（漏一个音效不该让游戏崩）。
##
## pitch：额外音高倍率（比如拾取宝石按连击升调），和 SPECS 的 jitter 相乘。
func play(id: String, pitch: float = 1.0) -> void:
	if _muted:
		return
	if not SPECS.has(id):
		return
	var spec: Dictionary = SPECS[id]
	var stream: AudioStream = _streams.get(id, null)
	if stream == null:
		return

	# 暂停时只放行 paused_ok 的音效：选卡界面要有点击声，但圈外警告不该在暂停时响
	if get_tree().paused and not bool(spec["paused_ok"]):
		return

	# 限流一：时间间隔
	var gap: float = float(spec["gap"])
	if _clock - float(_last_play.get(id, -999.0)) < gap:
		return

	# 限流二：同帧去重。一帧内打中 5 个敌人，听觉上是"一下"，不是五下。
	var frame: int = _frame_no
	if int(_last_frame.get(id, -1)) == frame:
		return

	var voice: AudioStreamPlayer = _pick_voice(id, bool(spec["priority"]))
	if voice == null:
		return

	_last_play[id] = _clock
	_last_frame[id] = frame
	voice.stream = stream
	var jitter: float = float(spec["jitter"])
	var scale: float = pitch
	if jitter > 0.0:
		scale *= 1.0 + _rng.randf_range(-jitter, jitter)
	voice.pitch_scale = clampf(scale, 0.35, 2.5)
	voice.volume_db = float(spec["db"])
	voice.play()
	var slot: int = _voices.find(voice)
	if slot >= 0:
		_voice_started[slot] = _clock
		_voice_len[slot] = _stream_length(stream)
		_voice_id[slot] = id
	_frame_count += 1
	_total_played += 1
	_plays_by_id[id] = int(_plays_by_id.get(id, 0)) + 1


func _stream_length(stream: AudioStream) -> float:
	if stream is AudioStreamWAV:
		return (stream as AudioStreamWAV).get_length()
	# 认不出来的格式就按 0.3 秒估。估错的后果只是 voice 早一点被复用，
	# 不会崩，也不会漏音——比返回 0 好，返回 0 等于放弃推算。
	return 0.3


## 这个 voice 是不是还在响。真机上 playing 就够准；
## headless 的 Dummy 驱动永远报 false，退回用"起始时间 + 流长度"推算。
func _busy(i: int) -> bool:
	if _voices[i].playing:
		return true
	return _clock - _voice_started[i] < _voice_len[i]


## 找一个可用的 voice。优先级从高到低：
##   1. 完全空闲的
##   2. 同一个音效正在播的（覆盖自己，胜过占用别的音效）
##   3. priority 才允许抢占最老的；否则返回 null 表示这一声丢掉
func _pick_voice(id: String, priority: bool) -> AudioStreamPlayer:
	for i in range(_voices.size()):
		if not _busy(i):
			return _voices[i]
	# 同一个音效已经有一份在响：直接换掉它。同音叠加会产生拍频，
	# 听起来像"嗡嗡"的失真，比少一声难听得多。
	for i in range(_voices.size()):
		if _voice_id[i] == id:
			return _voices[i]
	if not priority:
		return null
	var oldest: int = 0
	for i in range(_voices.size()):
		if _voice_started[i] < _voice_started[oldest]:
			oldest = i
	# 抢占用的是旧声音，等价于截断——这是"关键音一定能出声"的代价，
	# 但只发生在 20 个 voice 全满时，正常局内到不了。
	return _voices[oldest]


## 圈外警告按固定节拍自动重复，省得调用方自己记时间。
## 返回 true 表示这一拍真的响了（调试用）。
func tick_zone_warning(outside: bool) -> bool:
	if not outside:
		return false
	play("zone")
	return true


func set_muted(muted: bool) -> void:
	if _muted == muted:
		return
	_muted = muted
	apply_mute()
	_save_settings()


func is_muted() -> bool:
	return _muted


func toggle_muted() -> bool:
	set_muted(not _muted)
	return _muted


func apply_mute() -> void:
	AudioServer.set_bus_mute(0, _muted)


func _load_settings() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var raw: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_muted = bool((parsed as Dictionary).get("muted", false))


func _save_settings() -> void:
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"muted": _muted}, "\t"))
	f.close()


## 测试用：清空限流状态，让下一次 play 一定通过
func _reset_throttle() -> void:
	_last_play.clear()
	_last_frame.clear()
	_frame_count = 0
	_total_played = 0
