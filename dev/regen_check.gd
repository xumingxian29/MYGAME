extends SceneTree

## 脱战回血自检。全部手动步进：直接调 Player._tick_regen()，
## 不依赖引擎调度，所以结果与帧率、暂停、headless 都无关。
##
## 为什么值得单独一个脚本：回血是"计时门 → 累加 → 阈值结算 → 上限截断"四段逻辑，
## 任何一段写错都不会报错，只会表现成"血条偶尔跳一下"或者"其实从来没回过"。
## 上一轮音效就栽在 headless 下 Engine.get_frames_drawn() 不推进，
## 测试全绿但游戏无声——这类东西必须逐项断言。

const STEP: float = 1.0 / 60.0
const PLAYER_PATH: String = "res://scripts/player.gd"

var _pass: int = 0
var _fail: int = 0
var _ran: bool = false


## 不能在 _initialize() 里跑：那时 root 还没进树，add_child 不会触发 _ready，
## Player.max_health 会停在声明默认值 120（实测三个用例因此全错）。
## 推到第一帧，树已就绪，add_child 同步触发 _ready。
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_check_idle_at_full()
	_check_delay_gate()
	_check_starts_after_delay()
	_check_rate()
	_check_batching()
	_check_clamp()
	_check_zone_resets()
	_check_contact_lock()
	_check_dead_stops()
	_check_hero_scaling()
	_check_source_wiring()
	print("=== 脱战回血自检：%d 项通过，%d 项失败" % [_pass, _fail])
	quit()
	return true


func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  [ok] ", label, ("  " + detail) if detail != "" else "")
	else:
		_fail += 1
		print("  [FAIL] ", label, "  ", detail)


func _near(label: String, actual: float, expected: float, tol: float) -> void:
	var diff: float = absf(actual - expected)
	_ok(label, diff <= tol, "实际 %.4f  期望 %.4f ±%.4f" % [actual, expected, tol])


## 造一个玩家并接管调度。必须 add_child：max_health 与武器都在 _ready 里装配。
func _make(hero: int = HeroClass.WARRIOR) -> Player:
	var p: Player = (load(PLAYER_PATH) as GDScript).new()
	p.hero = hero
	root.add_child(p)
	p.set_physics_process(false)
	return p


func _drop(p: Player) -> void:
	root.remove_child(p)
	p.queue_free()


## 手动推进秒数，返回这段时间内的净回血量
func _step(p: Player, seconds: float) -> float:
	var before: float = p.health
	var frames: int = int(round(seconds / STEP))
	for i in range(frames):
		p._tick_regen(STEP)
	return p.health - before


func _check_idle_at_full() -> void:
	var p: Player = _make()
	p.health = p.max_health
	var gained: float = _step(p, 3.0)
	_near("满血时不产生回复", gained, 0.0, 0.0001)
	# 攒额度是最隐蔽的 bug：满血时不清累加器，掉血后第一帧就会吐出一大口
	_near("满血时累加器保持 0", p._regen_acc, 0.0, 0.0001)
	p.health = p.max_health - 40.0
	var burst: float = _step(p, 0.02)
	_near("刚掉血不会吐出攒下的额度", burst, 0.0, 0.0001)
	_drop(p)


func _check_delay_gate() -> void:
	var p: Player = _make()
	p.health = p.max_health - 50.0
	p._regen_wait = Player.REGEN_DELAY
	var gained: float = _step(p, 2.4)
	_near("受伤后 2.4 秒内不回血", gained, 0.0, 0.0001)
	_drop(p)


func _check_starts_after_delay() -> void:
	var p: Player = _make()
	p.health = p.max_health - 50.0
	p._regen_wait = Player.REGEN_DELAY
	var gained: float = _step(p, 3.0)
	_ok("2.5 秒后开始回血", gained > 0.1, "3 秒共回 %.3f" % gained)
	_drop(p)


func _check_rate() -> void:
	# 4 秒 = 240 帧，正好 15 个结算周期（每 16 帧一次），中途不留零头
	var p: Player = _make()
	p.health = p.max_health - 100.0
	p._regen_wait = 0.0
	var gained: float = _step(p, 4.0)
	var expected: float = p.max_health * 0.006 * 4.0
	_near("回血速率 = 最大生命 0.6%/秒", gained, expected, expected * 0.03)
	_drop(p)


func _check_batching() -> void:
	# 结算间隔 0.25 秒：0.2 秒内不该有任何回复，否则 HUD 会被逐帧信号刷屏
	var p: Player = _make()
	p.health = p.max_health - 80.0
	p._regen_wait = 0.0
	var early: float = _step(p, 0.2)
	_near("0.2 秒内不结算（合并写）", early, 0.0, 0.0001)
	var later: float = _step(p, 0.2)
	_ok("越过 0.25 秒后结算一次", later > 0.1, "共回 %.3f" % later)
	_drop(p)


func _check_clamp() -> void:
	var p: Player = _make()
	p.health = p.max_health - 0.4
	p._regen_wait = 0.0
	var gained: float = _step(p, 4.0)
	_ok("不超过生命上限", is_equal_approx(p.health, p.max_health),
		"终值 %.2f / %.2f" % [p.health, p.max_health])
	_ok("上限处只补差额", gained <= 0.41, "共补 %.3f" % gained)
	_drop(p)


func _check_zone_resets() -> void:
	# 站在圈外还想回血，等于把圈外惩罚抹掉
	var p: Player = _make()
	p.health = p.max_health - 60.0
	p._regen_wait = 0.0
	p.take_zone_damage(2.0)
	_ok("毒伤会把回血窗口重置", is_equal_approx(p._regen_wait, Player.REGEN_DELAY),
		"wait=%.2f" % p._regen_wait)
	var gained: float = _step(p, 2.0)
	_near("毒伤后 2 秒仍不回血", gained, 0.0, 0.0001)
	_drop(p)


func _check_contact_lock() -> void:
	# 每 0.45 秒挨一下（等于无敌帧长度，最坏情况）：回血必须完全停摆
	var p: Player = _make()
	p.health = p.max_health
	var start: float = p.health
	var rose: bool = false
	var last: float = p.health
	for i in range(120):
		p._tick_regen(STEP)
		if i % 27 == 26:
			p._invuln = 0.0
			p.take_damage(1.0)
		if p.health > last + 0.0001:
			rose = true
		last = p.health
	_ok("持续受击时回血完全停摆", not rose and p.health < start,
		"血 %.2f → %.2f" % [start, p.health])
	_drop(p)


func _check_dead_stops() -> void:
	var p: Player = _make()
	p.health = 0.0
	p._regen_wait = 0.0
	var gained: float = _step(p, 3.0)
	_near("死亡后不回血（不复活）", gained, 0.0, 0.0001)
	_drop(p)


func _check_hero_scaling() -> void:
	var p: Player = _make(HeroClass.RANGER)
	p.health = p.max_health - 60.0
	p._regen_wait = 0.0
	var gained: float = _step(p, 4.0)
	var expected: float = 110.0 * 0.006 * 4.0
	_near("按职业最大生命缩放（射手 110 → 0.66/秒）", gained, expected, expected * 0.03)
	_drop(p)


func _check_source_wiring() -> void:
	var file: FileAccess = FileAccess.open(PLAYER_PATH, FileAccess.READ)
	if file == null:
		_ok("读不到 player.gd", false)
		return
	var text: String = file.get_as_text()
	file.close()
	var phys: int = text.find("func _physics_process")
	var call_at: int = text.find("_tick_regen(delta)")
	_ok("_tick_regen 挂在 _physics_process 里", phys >= 0 and call_at > phys)
	# 挂到 _process 就错了：暂停靠的是 physics 调度停摆，渲染帧不受 paused 影响。
	# 只看 _process 的函数体，因为文件里 _process 定义在 _physics_process 之前。
	var proc: int = text.find("func _process")
	var proc_body_end: int = text.find("\nfunc ", proc + 1)
	var proc_body: String = text.substr(proc, (proc_body_end - proc) if proc_body_end > proc else 200)
	_ok("_process 里没有回血（否则暂停与选卡时仍会回血）", proc < 0 or not proc_body.contains("_tick_regen"))
	var resets: int = text.count("_regen_wait = REGEN_DELAY")
	_ok("两个受伤入口都重置了窗口", resets >= 2, "命中 %d 处" % resets)
