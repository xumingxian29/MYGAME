extends SceneTree

## 震动模型自检。
##
## 这个文件的存在理由：震动是**纯观感**的东西，改完之后"看着舒服了吗"
## 没法用断言回答，但"每帧相位推进了多少度"可以。
## 上一版真正的病根就是相位推进 75°~127°/帧（12~27Hz @60fps），
## 采样出来是白噪声，所以下面的断言几乎都围绕"运动是否连贯"。
##
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/shake_check.gd

const DT: float = 1.0 / 60.0

var _pass: int = 0
var _fail: int = 0
var _out: PackedStringArray = []


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		_out.append("[OK]   %s%s" % [name, ("  " + detail) if detail != "" else ""])
	else:
		_fail += 1
		_out.append("[FAIL] %s%s" % [name, ("  " + detail) if detail != "" else ""])


func _initialize() -> void:
	var p := Player.new()
	root.add_child(p)
	await process_frame

	_check("Player 建出了相机", p.camera != null)
	_check("不是 smoothing 模式（震动要直接改 offset）", p.camera != null and not p.camera.position_smoothing_enabled)

	# ---------- 1. 死区：幅度不到 1 像素的震动必须一点都不发 ----------
	# amp = 26 * t² < 0.9  →  t < 0.186。取 0.15 应完全静止，取 0.30 应开始动。
	p._trauma = 0.15
	for i in range(30):
		p._tick_shake(DT)
	_check("trauma=0.15（amp≈0.59，不到 1px）时完全静止",
		p.camera.offset == Vector2.ZERO, "offset=%s" % p.camera.offset)

	# 必须每帧把 trauma 钉住：0.30 只够衰减 0.16 秒，跑 30 帧（0.5 秒）
	# 早就归零了，测出来永远静止——这条断言一开始就是这么误报的。
	p._trauma = 0.30
	var moved: bool = false
	for i in range(30):
		p._trauma = 0.30
		p._tick_shake(DT)
		if p.camera.offset.length() > 0.5:
			moved = true
	_check("trauma=0.30（amp≈2.3）时确实在动", moved, "offset=%s" % p.camera.offset)

	# ---------- 2. 频率：60fps 下每秒过零次数要对得上 SHAKE_HZ ----------
	# 主分量 sin(2π·hz·t) 每秒过零 2×hz 次。用 2 秒的样本，分辨率才够。
	p._trauma = 1.0
	p._shake_t = 0.0
	var samples: Array[float] = []
	for i in range(120):
		p._trauma = 1.0          # 钉住幅度，只观察相位推进
		p._tick_shake(DT)
		samples.append(p.camera.offset.x)
	var flips: int = 0
	for i in range(1, samples.size()):
		var a: float = signf(samples[i - 1])
		var b: float = signf(samples[i])
		if a != 0.0 and b != 0.0 and a != b:
			flips += 1
	var hz: float = float(flips) / 2.0 / (120.0 * DT)
	_check("主频接近 %.1fHz（实测 %.1fHz）" % [Player.SHAKE_HZ, hz],
		absf(hz - Player.SHAKE_HZ) <= 1.2, "过零 %d 次 / 2s" % flips)

	# ---------- 3. 连贯性：这是上一版失败的真正指标 ----------
	# 相邻帧位移 / 峰值位移。平滑正弦的理论值 = 2π·hz/60 ≈ 0.57；
	# 完全随机的白噪声接近 1.4。上一版实测 1.07（每帧跳得比振幅还远）。
	var peak: float = 0.0
	for v in samples:
		peak = maxf(peak, absf(v))
	var jumps: float = 0.0
	for i in range(1, samples.size()):
		jumps += absf(samples[i] - samples[i - 1])
	jumps /= float(samples.size() - 1)
	var ratio: float = jumps / maxf(peak, 0.001)
	_check("帧间位移/峰值 = %.2f，属于连续运动（<0.70）" % ratio, ratio < 0.70,
		"旧版实测 1.07；正弦平均值理论 ≈%.2f，峰值斜率 %.2f" % [
			(2.0 / PI) * TAU * Player.SHAKE_HZ / 60.0, TAU * Player.SHAKE_HZ / 60.0])
	_check("没有退化成静止（ratio 不能接近 0）", ratio > 0.25, "ratio=%.2f" % ratio)

	# ---------- 4. 幅度上限：trauma=1 时的峰值不能超过旧版力度 ----------
	var peak_abs: float = 0.0
	p._trauma = 1.0
	p._shake_t = 0.0
	for i in range(240):
		p._trauma = 1.0
		p._tick_shake(DT)
		peak_abs = maxf(peak_abs, p.camera.offset.length())
	# 旧版峰值 = 26 × 0.8 × √2 ≈ 29.4 世界单位；给 5% 余量
	_check("trauma=1 峰值 %.1f 不超过旧版 29.4（世界单位）" % peak_abs,
		peak_abs <= 29.4 * 1.05, "≈%.0f 屏幕像素" % (peak_abs * 1.35))
	_check("trauma=1 峰值也不能太小（>15，否则打起来没手感）", peak_abs > 15.0, "%.1f" % peak_abs)

	# ---------- 5. 衰减：从满强度归零的时间 ----------
	p._trauma = 1.0
	var t: float = 0.0
	while p._trauma > 0.0 and t < 3.0:
		p._tick_shake(DT)
		t += DT
	_check("满创伤在 %.2fs 内归零（≈1/%s）" % [t, Player.TRAUMA_DECAY],
		t > 0.3 and t < 1.0, "实测 %.2fs" % t)

	# ---------- 6. 归零后必须回正，不能留残余偏移 ----------
	p._trauma = 0.0
	p._tick_shake(DT)
	_check("trauma 归零后 offset 回到 (0,0)", p.camera.offset == Vector2.ZERO,
		"offset=%s" % p.camera.offset)

	# ---------- 7. 更新时机：必须在渲染帧，不在物理帧 ----------
	# 物理固定 60 次/秒，渲染可能是 30 或 120；不对齐时同一个 offset 会被
	# 连续两帧共用（阶梯位移），比抖动更难看。
	_check("震动在 _process（渲染帧）推进", p.has_method("_process"))
	var src: String = FileAccess.get_file_as_string("res://scripts/player.gd")
	var phys: String = src.split("func _physics_process")[1].split("\n\n")[0] if src.contains("func _physics_process") else ""
	_check("_physics_process 里不再调用 _tick_shake", not phys.contains("_tick_shake"),
		"物理帧里推进视觉量会造成阶梯位移")

	# ---------- 7b. 暂停时必须回正 ----------
	# 暂停后 _process 停止推进，偏移会冻在最后一帧；卡片面板背后的世界就歪了。
	p._trauma = 1.0
	p._tick_shake(DT)
	var before_pause: Vector2 = p.camera.offset
	p.notification(Node.NOTIFICATION_PAUSED)
	_check("暂停时相机偏移回正（暂停前 %s）" % before_pause,
		p.camera.offset == Vector2.ZERO and p._trauma == 0.0, "offset=%s" % p.camera.offset)

	# ---------- 8. 普通击杀不再注入 trauma ----------
	# 后期 13~25 击杀/秒，每个 0.04 就是 0.5~1.0/s 的持续注入，
	# trauma 稳态被顶到 0.4，屏幕一直抖——这是"后期很震荡"的直接原因。
	var gsrc: String = FileAccess.get_file_as_string("res://scripts/game.gd")
	_check("普通击杀的 trauma 注入为 0",
		gsrc.contains("add_trauma(0.15 if enemy.tier > 0 else 0.0)"),
		"精英保留 0.15，普通小兵为 0")

	# ---------- 9. 后期稳态模拟 ----------
	# 用实测击杀率反推：若能注入量只剩技能与受击，稳态必须落进死区。
	# 技能 0.40 每 3 秒一次，只够衰减 0.21 秒；两次之间有 2.79 秒是静止的。
	# 关键是"注入间隔 > 衰减时间"，这样稳态是 0，而不是一个被顶住的非零值。
	var sim: float = 0.0
	var acc: float = 0.0
	for i in range(60 * 10):
		acc += DT
		if acc >= 3.0:            # 每 3 秒一次技能
			acc -= 3.0
			sim = minf(sim + 0.40, 1.0)
		sim = maxf(sim - Player.TRAUMA_DECAY * DT, 0.0)
	_check("只靠技能注入时，后期 trauma 稳态 %.3f 落在死区内" % sim,
		Player.SHAKE_MAX_OFFSET * sim * sim < Player.SHAKE_DEADZONE,
		"amp=%.2f < 死区 %.2f" % [Player.SHAKE_MAX_OFFSET * sim * sim, Player.SHAKE_DEADZONE])

	p.queue_free()
	_out.append("")
	_out.append("=== %s（%d 通过 / %d 失败）===" % ["全部通过" if _fail == 0 else "存在问题", _pass, _fail])
	var text: String = "\n".join(_out)
	print(text)
	var f: FileAccess = FileAccess.open("res://.workbuddy/shake_check.txt", FileAccess.WRITE)
	f.store_string(text)
	f.close()
	quit(0 if _fail == 0 else 1)
