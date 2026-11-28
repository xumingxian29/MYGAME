extends SceneTree

## 高刷新率位移探针：把「渲染帧比物理帧多」导致的顿挫/重影变成数字。
##
## 病因不需要猜：逻辑全部跑在 _physics_process（60Hz），渲染却跑在屏幕刷新率上（120/144Hz）。
## 不开插值时同一个物理位置会被连续画 2~3 帧，然后突然跳到下一个位置——
## 眼睛看到的不是"物体在动"，而是"整张画面在抖"。
##
## 用法：
##   godot --headless --path . --fixed-fps 240 --script res://dev/interp_probe.gd
##   godot --headless --path . --fixed-fps 120 --script res://dev/interp_probe.gd
##
## --fixed-fps 240 让一次物理 tick 落在 4 个渲染帧上，等价于 240Hz 屏。
##
## GDScript 拿不到 2D 的"插值后变换"（那个 API 只有 3D 有），
## 所以这里只读渲染层真正使用的东西：**相机画布变换**。
## 它由 Camera2D 每帧算出来写进 Viewport，画面上的每个像素都乘过它——
##   逐帧增量恒定     → 画面匀速滑动，平滑
##   每 4 帧 3 个 0   → 阶梯，就是玩家说的重影/顿挫
## 另外把相机世界坐标反推出来，和玩家物理位置比：
##   滞后 0 个 tick    → 相机完全没插值（开插值后仍为 0 就是没生效）
##   滞后 0~1 个 tick  → 正常插值（滞后随帧在 1→0 之间扫）
##   滞后 >1 个 tick   → 相机被插值了两次
##
## 为保证只测"移动"，探针每帧清空敌人（接触伤害会触发震屏，污染相机采样）。

const WARMUP: float = 1.2
const SAMPLE: float = 2.0
const MAX_ITER: int = 4000

var _game: Node = null
var _player: Node2D = null
var _t: float = 0.0
var _iter: int = 0
var _sampling: bool = false
var _done: bool = false

var _last_ct: Vector2 = Vector2.ZERO
var _have_last: bool = false
var _ct_d: Array[float] = []
var _f: Array[float] = []
var _lag: Array[float] = []
var _zero_frames: int = 0
var _ticks: int = 0
var _last_pos: Vector2 = Vector2.ZERO
var _dir: Vector2 = Vector2.RIGHT


func _initialize() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	if packed == null:
		print("FAIL 主场景加载失败")
		quit()
		return
	root.add_child(packed.instantiate())


func _process(delta: float) -> bool:
	_iter += 1
	if _iter > MAX_ITER:
		print("FAIL 迭代用尽（t=%.2f）" % _t)
		quit()
		return true
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("probe", 0)
		_game.story_enabled = false
		if _game.story_panel != null and _game.story_panel.is_open():
			_game.story_panel.skip()
		_player = _game.player
		_last_pos = _player.global_position
		Input.action_press("move_right")
		return false

	if _done:
		return true

	_t += delta
	_clear_enemies()

	if not _sampling:
		if _t >= WARMUP:
			_sampling = true
			_have_last = false
		return false

	if _player.global_position != _last_pos:
		_ticks += 1
		_last_pos = _player.global_position

	var ct: Transform2D = root.get_canvas_transform()
	var ct_origin: Vector2 = ct.origin
	# 反推相机在看世界的哪个点：屏幕上中心那个像素对应哪个世界坐标
	var cam_world: Vector2 = ct.affine_inverse() * (root.get_visible_rect().size * 0.5)
	# 相机比玩家落后多少世界像素（玩家在往右跑，所以沿 +x 量）
	var lag: float = (_player.global_position - cam_world).dot(_dir)

	if _have_last:
		var d: float = (ct_origin - _last_ct).length()
		_ct_d.append(d)
		_f.append(Engine.get_physics_interpolation_fraction())
		_lag.append(lag)
		if d < 0.02:
			_zero_frames += 1
	else:
		_have_last = true
	_last_ct = ct_origin

	if _t >= WARMUP + SAMPLE:
		_done = true
		print("")
		print("== 高刷新率位移采样（渲染 %.0f Hz，玩家速度 %.0f）==" % [1.0 / delta, _player.move_speed])
		_report(delta)
		Input.action_release("move_right")
		quit()
		return true
	return false


func _clear_enemies() -> void:
	if _game._enemies.is_empty():
		return
	for e in _game._enemies:
		if is_instance_valid(e):
			e.queue_free()
	_game._enemies.clear()


func _report(delta: float) -> void:
	var n: int = _ct_d.size()
	if n < 4:
		print("FAIL 样本不足（%d 帧）" % n)
		return
	var sum: float = 0.0
	var sq: float = 0.0
	var mx: float = 0.0
	for v in _ct_d:
		sum += v
		sq += v * v
		mx = maxf(mx, v)
	var mean: float = sum / float(n)
	var sd: float = sqrt(maxf(sq / float(n) - mean * mean, 0.0))
	var cv: float = sd / mean if mean > 0.001 else 0.0

	# 一个物理 tick 玩家走多远（世界单位），换算成屏幕像素要乘相机缩放
	var tick_px: float = _player.move_speed / 60.0
	var theory: float = tick_px * Player.CAMERA_ZOOM * float(_ticks) / float(n)
	var lag_sum: float = 0.0
	var lag_max: float = 0.0
	var lag_min: float = 999.0
	for v in _lag:
		lag_sum += v
		lag_max = maxf(lag_max, v)
		lag_min = minf(lag_min, v)
	var lag_mean: float = lag_sum / float(_lag.size())

	var f_min: float = 1.0
	var f_max: float = 0.0
	for v in _f:
		f_min = minf(f_min, v)
		f_max = maxf(f_max, v)

	print("  采样帧数        %d（物理 tick %d 次 → %.1f 帧/tick）" % [n, _ticks, float(n) / maxf(float(_ticks), 1.0)])
	print("  画面逐帧位移    均值 %.3f 标准差 %.3f 峰值 %.3f 像素（理论匀速 %.3f）" % [mean, sd, mx, theory])
	print("  位移变异系数    %.2f   平滑≈0，阶梯≈1.0 以上" % cv)
	print("  静止帧占比      %.1f%%  画面这一帧完全没动" % (100.0 * float(_zero_frames) / float(n)))
	print("  相机滞后        均值 %.2f 像素（%.2f tick）/ 区间 %.2f~%.2f 像素   一 tick = %.1f 像素" % [lag_mean, lag_mean / tick_px, lag_min, lag_max, tick_px])
	print("  插值分数区间    %.2f ~ %.2f" % [f_min, f_max])
	# 物理推进的确定性锚点：同一个迭代数下这两个数必须逐位相同，
	# 用来证明"插值只动画面、不动逻辑"（开/关各跑一次对比即可）。
	print("  物理帧 / 迭代   %d / %d" % [Engine.get_physics_frames(), _iter])
	print("  终点世界坐标    %s" % str(_player.global_position))

	var verdict: String = "阶梯（顿挫/重影仍在）"
	if cv < 0.25:
		verdict = "平滑"
	print("  判定            %s" % verdict)
	print("")
