extends SceneTree

## 确定性自检：保证"同一份构建 + 同一颗种子 = 同一局"。
##
## 背景（2026-11-25）：射手同种子跑出过 101.3 / 124.5 / 144.9 三档。
## 结果不稳定 = 尺子是坏的，20% 以内的调参根本读不出意义。
##
## 定位过程（靠 dev/bot.gd 的 --trace 逐帧指纹）：
##   两次跑到第 1818 帧（t=30.35）仍然逐位相同，
##   第 1819 帧（t=30.37）帧号、时间、击杀数、敌人数全同，只有指纹不同——
##   那正是第 15 只怪出生的那一帧，也就是说**新怪的位置不同**，
##   随机数序列在被用到之前就已经被别的东西推开了。
## 根因：audio.gd 的限流按**渲染帧**推进（_clock/_frame_no 在 _process 里累加），
##   而渲染帧和物理帧不是一一对应；"这一次有没有被限流拦掉"每个进程差出几次。
##   每次放行又消耗一次全局 randf() 做音高抖动，于是非玩法代码把玩法随机序列推歪了。
## 修法：音效改用自己的 RandomNumberGenerator（固定种子），不再碰全局序列。
##
## 另外给 Enemy 加了 spawn_serial：不是防串号（实测 id 不复用，见
## dev/id_recycle_probe.gd），而是让"谁是谁"跨进程可比——
## instance_id 每进程不同，日志没法逐项对账。
##
## 用法：godot --headless --path . --script res://dev/determinism_check.gd

const STEP: float = 1.0 / 60.0

var _pass: int = 0
var _fail: int = 0
var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_check_source()
	_check_orbit_no_inherit()
	_check_boomerang_no_inherit()
	_check_bullet_hit_list()
	print("=== 确定性自检：%d 项通过，%d 项失败" % [_pass, _fail])
	quit()
	return true


# ---------------------------------------------------------------- 源码约束

## 这类"少一个字符就退回原样"的改动，靠人工 review 守不住，必须扫描。
func _check_source() -> void:
	var hits: PackedStringArray = []
	for path in _gd_files("res://scripts"):
		var text: String = _read(path)
		for line in text.split("\n"):
			# 注释里提到 get_instance_id() 是说明文字，不算违规
			if line.begins_with("#"):
				continue
			if line.contains("get_instance_id()"):
				hits.append("%s: %s" % [path.get_file(), line.strip_edges()])
	_ok("scripts/ 里不再有 get_instance_id() 做键（命中 %d 处）" % hits.size(), hits.is_empty())
	for h in hits:
		print("     ", h)

	var enemy_src: String = _read("res://scripts/enemy.gd")
	_ok("Enemy 有 spawn_serial 字段", enemy_src.contains("var spawn_serial: int = 0"))

	var game_src: String = _read("res://scripts/game.gd")
	_ok("Game 有 _next_serial 计数器", game_src.contains("var _next_serial: int = 0"))
	# 逐行判断，不要拼 "\n"：Windows 检出的是 CRLF，拼字符串会永远匹配不上，
	# 而失败信息看起来像"代码没写"，最容易被误判。
	var begin_at: int = -1
	var lines: PackedStringArray = game_src.split("\n")
	for i in range(lines.size()):
		if lines[i].begins_with("func _begin_run("):
			begin_at = i
	var resets: bool = false
	if begin_at >= 0:
		for i in range(begin_at, mini(begin_at + 16, lines.size())):
			if lines[i].strip_edges() == "_next_serial = 0":
				resets = true
	_ok("_begin_run 里把序号归零（每局从 0 开始）", resets)
	# 普通怪 + Boss 两条创建路径，漏一条就有角色永远拿 0 号，
	# 而 0 号会被所有武器当成"同一个人"
	var assigns: int = 0
	for line in game_src.split("\n"):
		if line.strip_edges() == "spawn_serial = _next_serial" or \
			line.strip_edges() == "enemy.spawn_serial = _next_serial" or \
			line.strip_edges() == "boss.spawn_serial = _next_serial":
			assigns += 1
	_ok("两条创建路径都分配序号（%d/2）" % assigns, assigns == 2)

	for w in ["orbit_weapon.gd", "boomerang_weapon.gd", "bullet_weapon.gd"]:
		var src: String = _read("res://scripts/weapons/" + w)
		_ok("%s 用 spawn_serial 当键" % w, src.contains("spawn_serial"))

	# 玩法随机序列必须只被"每物理帧必然发生"的代码消耗。
	# 音效限流按渲染帧推进，被拦掉几次每个进程不同，所以它一旦借全局 randf()
	# 就会把玩法随机数整体推开——这是实测到的真正分岔源，比 instance_id 更致命。
	var audio_src: String = _read("res://scripts/audio.gd")
	var all_rand: int = 0
	var own_rand: int = 0
	for line in audio_src.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		all_rand += line.count("randf_range(") + line.count("randf()")
		own_rand += line.count("_rng.randf_range(") + line.count("_rng.randf()")
	_ok("audio.gd 只用私有 RNG（%d/%d 个调用已隔离）" % [own_rand, all_rand],
		all_rand > 0 and own_rand == all_rand)

	# bot 的决策必须在物理帧：idle 帧会领先/落后物理帧 1~N 帧，且领先量
	# 取决于引擎初始化耗时，每个进程不同。挂在 _process 上，输入注入与
	# 游戏读输入就错开一帧，整条轨迹岔开（181.5s vs 240.9s）。
	var bot_src: String = _read("res://dev/bot.gd")
	var phys_at: int = bot_src.find("func _physics_process(")
	var proc_at: int = bot_src.find("func _process(")
	_ok("bot 的决策入口是 _physics_process", phys_at >= 0)
	_ok("bot 的 _drive / _sample 挂在物理帧路径上",
		phys_at >= 0 and bot_src.find("_drive(delta)") > phys_at and bot_src.find("_sample()") > phys_at)
	# 把 _process 的函数体单独切出来，确认它已经退化成"只判退出"
	var idle_body: String = ""
	if proc_at >= 0 and phys_at > proc_at:
		idle_body = bot_src.substr(proc_at, phys_at - proc_at)
	_ok("bot 的 _process 不再注入输入 / 采样（否则又回到 idle 帧）",
		idle_body != "" and not idle_body.contains("_drive(") and not idle_body.contains("_sample("))
	_ok("bot 的 _drive 全脚本只调用一次", bot_src.count("_drive(delta)") == 1)


# ---------------------------------------------------------------- 行为：飞刃

## 冷却必须按"这一只怪"记账：新出生的怪不能继承别人的剩余冷却。
func _check_orbit_no_inherit() -> void:
	var wep := OrbitWeapon.new()
	wep.blades = 1
	wep.damage = 10.0
	wep.orbit_radius = 0.0    # 刃心落在武器原点，方便把敌人摆在同一个点上
	wep.blade_length = 0.0

	var a: Enemy = _enemy(0)
	var b: Enemy = _enemy(1)
	wep.enemies = [a, b]

	wep._resolve_hits()
	_ok("第一刀两只都吃到伤害（序号不同 → 不互相挡）",
		is_equal_approx(a._health, 90.0) and is_equal_approx(b._health, 90.0))

	wep._resolve_hits()
	_ok("同一帧内再扫一次：冷却生效，两只都不再掉血",
		is_equal_approx(a._health, 90.0) and is_equal_approx(b._health, 90.0))

	# 0 号死掉、立刻补一只新怪：新怪的序号是新的，必须马上可以吃到伤害。
	# 这条守的是"冷却记在身份上、不记在位置上"——记错就会出现"刚出生的怪打不动"。
	a.free()
	var c: Enemy = _enemy(2)
	wep.enemies = [b, c]
	wep._resolve_hits()
	_ok("新怪立刻可被命中（没有继承死怪的剩余冷却）", is_equal_approx(c._health, 90.0))
	_ok("老怪仍在冷却中（冷却本身没被破坏）", is_equal_approx(b._health, 90.0))

	for e in [b, c]:
		if is_instance_valid(e):
			e.free()
	wep.free()


# ---------------------------------------------------------------- 行为：回旋镖

## 与飞刃同一套键，但代码是两份复制，所以两份都要验。
func _check_boomerang_no_inherit() -> void:
	var wep := BoomerangWeapon.new()
	wep.damage = 12.0
	var a: Enemy = _enemy(10)
	wep.enemies = [a]
	wep._resolve_hit(Vector2.ZERO)
	_ok("回旋镖第一刀命中", is_equal_approx(a._health, 88.0))

	a.free()
	var b: Enemy = _enemy(11)
	wep.enemies = [b]
	wep._resolve_hit(Vector2.ZERO)
	_ok("回旋镖：新怪不被 10 号的残留冷却拦住", is_equal_approx(b._health, 88.0))

	if is_instance_valid(b):
		b.free()
	wep.free()


# ---------------------------------------------------------------- 行为：子弹

## 子弹的命中名单活在一发弹的飞行期里（最长 1.4 秒），
## 这期间死掉的怪同样可能把 id 让给别人，导致"这一发明明扫过新怪却没打中"。
func _check_bullet_hit_list() -> void:
	var wep := BulletWeapon.new()
	wep.damage = 10.0
	wep.splash_radius = 0.0
	wep.slow_time = 0.0

	var seen: Enemy = _enemy(20)
	var fresh: Enemy = _enemy(21)
	wep.enemies = [seen, fresh]
	# 名单里已经有 20 号：只有 21 号应该挨打
	var shot: Dictionary = {"hits": [20], "damage": 10.0, "pierce": 1}
	wep._resolve_hit(shot, Vector2.ZERO, Vector2.ZERO)
	_ok("名单里的序号被跳过", is_equal_approx(seen._health, 100.0))
	_ok("不在名单里的序号照常吃伤害", is_equal_approx(fresh._health, 90.0))
	_ok("命中后把序号写进名单", (shot["hits"] as Array).has(21))

	for e in [seen, fresh]:
		if is_instance_valid(e):
			e.free()
	wep.free()


# ---------------------------------------------------------------- 工具

func _enemy(serial: int) -> Enemy:
	var e := Enemy.new()
	e.spawn_serial = serial
	# configure 会同步写好 _health = max_health；不依赖 _ready，
	# 所以敌人不必进树，就不会有 _physics_process 抢跑。
	e.configure(100.0, 60.0, false, Enemy.Kind.GRUNT)
	e.global_position = Vector2.ZERO
	return e


func _gd_files(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for name in dir.get_files():
		if name.ends_with(".gd"):
			out.append(dir_path.path_join(name))
	for sub in dir.get_directories():
		out.append_array(_gd_files(dir_path.path_join(sub)))
	return out


func _read(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


func _ok(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("[ok]   ", name)
	else:
		_fail += 1
		print("[FAIL] ", name)
