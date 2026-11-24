extends SceneTree

## Boss 招式截图：三只 Boss 的招牌招式各摆一张，确认"读招"在画面上真的看得懂。
## 用法：godot --path . --script res://dev/boss_shot.gd   （不能 headless，headless 没有渲染设备）
## 输出 .workbuddy/boss_*.png
##
## 只负责摆画面 + 存图，不做断言——断言在 dev/boss_check.gd。

const OUT_DIR: String = "res://.workbuddy/"

var _game: Node = null
var _frames: int = 0
var _step: int = 0
var _shots: PackedStringArray = []
## 摆场景的三步进度。不能用 _frames 判断：跨帧完成时它每帧都在变。
var _prep: int = 0
## 受击闪白是 0.14 秒的白光，刚打完就拍会拍到一只白球。等它退掉再摆招式。
var _hold: int = 0


func _initialize() -> void:
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game._on_menu_started("boss_shot", HeroClass.WARRIOR)
		return false

	_frames += 1
	if _game._state == 2:
		_game._choose(0)
		return false
	if is_instance_valid(_game.player) and _game._state == 1:
		_game.player.health = _game.player.max_health

	match _step:
		0:
			if not _prepare(0, Enemy.MOVE_TIDE):
				return false
			_snap("boss_1_tide")
			_finish_boss()
		1:
			if not _prepare(1, Enemy.MOVE_BLINK):
				return false
			_snap("boss_2_blink")
			_finish_boss()
		2:
			if not _prepare(2, Enemy.MOVE_HOMING):
				return false
			_snap("boss_3_homing")
			_step = 3
			_frames = 0
		3:
			# 弹体出膛：确认"会拐弯的弹"在画面上的颜色与锁定环
			if _frames < 24:
				return false
			_snap("boss_4_homing_shots")
			_finish()
			return true
	return false


## 摆场景分三步，跨帧完成：
##   1. 放 Boss、把它打到 45%（下一帧 _tick_boss 会真的切二阶段，血条也跟着变）
##   2. 阶段切换会把 _boss_move 清掉，所以招式必须等这一帧之后才设
##   3. 前摇快走满时截图
func _prepare(kit: int, move: int) -> bool:
	match _prep:
		0:
			var stage: Dictionary = Stage.at(kit)
			_game._stage_index = kit
			_game._stage_time = float(stage["length"])
			_game._check_boss()
			var boss: Enemy = _game._boss
			if boss == null or not is_instance_valid(boss):
				return false
			# 摆在玩家下方：上方是出场横幅，摆上去字和它叠在一起谁也看不清
			boss.global_position = _game.player.global_position + Vector2(0.0, 120.0)
			boss.boss_intro_t = 0.0
			for i in range(8):
				var angle: float = TAU * float(i) / 8.0
				_game._create_enemy(Enemy.Kind.GRUNT, false,
					boss.global_position + Vector2(cos(angle), sin(angle)) * randf_range(120.0, 210.0))
			boss.take_damage(boss.max_health * 0.55)
			_hold = 12
			_prep = 1
			return false
		1:
			if _hold > 0:
				_hold -= 1
				return false
			var boss2: Enemy = _game._boss
			if boss2 == null or not is_instance_valid(boss2):
				return false
			# 显式推进一次 Boss 逻辑：二阶段切换要当场发生（HUD 也跟着变红）。
			# 不能等物理帧——窗口刷新率高于 60 时，两帧 _process 之间可能根本没有物理 tick，
			# 上一版截图就因此拍到了"招式在放、但血条还写着第一阶段"的画面。
			var dir: Vector2 = (_game.player.global_position - boss2.global_position).normalized()
			boss2._tick_boss(0.0, dir, boss2.global_position.distance_to(_game.player.global_position))
			boss2._boss_move = move
			match move:
				Enemy.MOVE_TIDE:
					boss2._boss_move_t = Enemy.BOSS_TIDE_TELEGRAPH - 0.08
				Enemy.MOVE_BLINK:
					boss2._boss_move_t = Enemy.BOSS_BLINK_WINDUP - 0.10
				Enemy.MOVE_HOMING:
					boss2._boss_move_t = Enemy.BOSS_HOMING_WINDUP - 0.05
			# 直接改状态不会触发重绘（正常流程靠 _tick_boss 每帧 queue_redraw）。
			# 不补这一行，画面会一直停在上一个状态上——这正是前几版截不到巨浪的原因。
			boss2.queue_redraw()
			_prep = 2
			return false
		2:
			# 关键：root.get_texture().get_image() 拿到的是"上一帧已经画好的画面"，
			# 所以设完招式必须再等一帧，否则拍到的是还没进这招的样子。
			_prep = 3
			return false
		_:
			return true


func _finish_boss() -> void:
	if _game._boss != null and is_instance_valid(_game._boss):
		_game._boss.take_damage(1e9)
	_prep = 0
	_step += 1
	_frames = 0


func _snap(name: String) -> void:
	# 摆拍时把 Boss 状态一起记下来：图上看不到某个环时，先分清"没画"还是"没进这招"
	var boss: Enemy = _game._boss
	if boss != null and is_instance_valid(boss):
		_shots.append("  状态 %s：move=%d t=%.3f phase=%d intro=%.2f" % [
			name, boss._boss_move, boss._boss_move_t, boss._boss_phase_index, boss.boss_intro_t])
	var img: Image = root.get_texture().get_image()
	if img == null:
		return
	var path: String = OUT_DIR + name + ".png"
	img.save_png(path)
	_shots.append("%s  %dx%d" % [path, img.get_width(), img.get_height()])


func _finish() -> void:
	var f: FileAccess = FileAccess.open(OUT_DIR + "boss_shots.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _shots:
		f.store_line(line)
	f.close()
	quit()
