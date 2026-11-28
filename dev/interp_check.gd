extends SceneTree

## 物理插值自检：把"重影修复"里**容易漏掉又不报错**的那几件事钉住。
##
## 插值本身是引擎行为，开关一开画面就顺了——真正会出事的是两个"沉默"的坑：
##   1. 生成/瞬移的节点忘了 reset_physics_interpolation()：
##      不报错，只是每只怪、每颗宝石都从世界原点滑到出生点（实测滑 197 像素）。
##   2. 自绘的东西（子弹/镖/飞刃/刀光）没手写补帧：
##      也不报错，只是它们继续以 60Hz 阶梯移动，和已经平滑的世界对不上。
## 这两类都是"看起来能跑"的 bug，所以要靠扫描源码把它们变成会红的断言。
##
## 用法：godot --headless --path . --fixed-fps 240 --script res://dev/interp_check.gd

var _pass: int = 0
var _fail: int = 0
var _game: Node = null
var _frames: int = 0

## 每个"设完位置就不会再连续移动"的赋值点都必须紧跟一次重置。
## 这里写的是"文件 + 期望至少有几处"，行号不写死——改代码时行号天天变。
const SPAWN_SITES: Array[Dictionary] = [
	{"file": "res://scripts/game.gd", "min": 6, "why": "刷怪 / Boss 出场 / 三种弹丸 / 宝石"},
	{"file": "res://scripts/enemy.gd", "min": 1, "why": "蚀影瞬移"},
]


func _initialize() -> void:
	print("=== 物理插值自检 ===")
	_check_setting()
	_check_spawn_sites()
	_check_self_drawn()
	var packed: PackedScene = load("res://MY主场景.tscn")
	root.add_child(packed.instantiate())


func _process(_delta: float) -> bool:
	_frames += 1
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		# 不点开局的话 _state 永远是 MENU，后面的运行时断言全部走不到
		_game._on_menu_started("check", 0)
		_game.story_enabled = false
		if _game.story_panel != null and _game.story_panel.is_open():
			_game.story_panel.skip()
		return false

	if _game._state == 2:
		_game._choose(0)
		return false
	if _game._state != 1 or not is_instance_valid(_game.player):
		return false

	# 跑两帧让刷怪、玩家、相机都进入稳态，再做运行时断言
	if _frames < 30:
		return false

	_check_runtime()
	print("")
	print("=== %s（%d 通过 / %d 失败）===" % ["全部通过" if _fail == 0 else "有失败项", _pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true


func _ok(cond: bool, label: String, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[OK]   %s%s" % [label, "" if detail.is_empty() else "  " + detail])
	else:
		_fail += 1
		print("[FAIL] %s%s" % [label, "" if detail.is_empty() else "  " + detail])


func _check_setting() -> void:
	var on: bool = bool(ProjectSettings.get_setting("physics/common/physics_interpolation"))
	_ok(on, "project.godot 打开了 physics/common/physics_interpolation")


## 扫源码：每个 `global_position = xxx`（生成 / 瞬移）后面 3 行内必须有重置。
## 用 `= ` 而不是 `+=`：连续移动的写法（+=）每 tick 都在推，不需要重置。
func _check_spawn_sites() -> void:
	for site in SPAWN_SITES:
		var path: String = str(site["file"])
		var text: String = FileAccess.get_file_as_string(path)
		if text.is_empty():
			_ok(false, "读取 " + path, "文件为空")
			continue
		var lines: PackedStringArray = text.split("\n")
		var sites: int = 0
		var missing: Array[int] = []
		for i in range(lines.size()):
			var l: String = lines[i]
			var code: String = l.strip_edges()
			if code.begins_with("#"):
				continue
			if not l.contains("global_position = "):
				continue
			sites += 1
			var has_reset: bool = false
			for j in range(i, mini(i + 4, lines.size())):
				if lines[j].contains("reset_physics_interpolation()"):
					has_reset = true
					break
			if not has_reset:
				missing.append(i + 1)
		_ok(sites >= int(site["min"]), "%s 的生成/瞬移点数量" % path.get_file(),
			"找到 %d 处（%s）" % [sites, str(site["why"])])
		_ok(missing.is_empty(), "%s 每处生成/瞬移都重置了插值" % path.get_file(),
			"缺失行号 %s" % str(missing) if not missing.is_empty() else "共 %d 处" % sites)


## 自绘的武器不经过节点变换，引擎插值对它们无效，必须自己按插值分数补帧。
func _check_self_drawn() -> void:
	var targets: Array[String] = [
		"res://scripts/weapons/bullet_weapon.gd",
		"res://scripts/weapons/boomerang_weapon.gd",
		"res://scripts/weapons/orbit_weapon.gd",
		"res://scripts/weapons/melee_weapon.gd",
	]
	for path in targets:
		var text: String = FileAccess.get_file_as_string(path)
		var name: String = path.get_file()
		_ok(text.contains("Engine.get_physics_interpolation_fraction()"),
			"%s 在 _draw 里用了插值分数" % name)
		_ok(text.contains("func _process("),
			"%s 每渲染帧重绘（否则补帧只发生在物理帧）" % name)


func _check_runtime() -> void:
	var f: float = Engine.get_physics_interpolation_fraction()
	_ok(f >= 0.0 and f <= 1.0, "插值分数在 0~1 之间", "f=%.2f" % f)

	var player: Node2D = _game.player
	_ok(player.is_physics_interpolated_and_enabled(), "玩家参与插值")

	var cam: Camera2D = player.camera
	_ok(cam.physics_interpolation_mode != Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"相机没有被人为排除出插值", "mode=%d" % cam.physics_interpolation_mode)

	# 真实刷怪路径：确认 _create_enemy 建出来的敌人是"已重置"状态，
	# 重置过的节点在出生那一帧的插值位移必须是 0（否则它会从原点滑过来）
	var before: int = _game._enemies.size()
	_game._create_enemy(Enemy.Kind.GRUNT, false, player.global_position + Vector2(420.0, 0.0))
	var fresh: Enemy = _game._enemies[before] if _game._enemies.size() > before else null
	_ok(fresh != null, "可以通过真实的 _create_enemy 造出一只敌人")
	if fresh != null:
		_ok(fresh.is_physics_interpolated_and_enabled(), "新刷的敌人参与插值")
		_ok(fresh.global_position.distance_to(player.global_position) > 300.0,
			"新刷的敌人站在出生点而不是原点", "距玩家 %.0f" % fresh.global_position.distance_to(player.global_position))

	# 宝石同理（Boss 死后会一次炸 8 颗，最容易被看出来）
	var gem_before: int = _game._gems.size()
	_game._spawn_gem(player.global_position + Vector2(-300.0, 0.0), 3)
	var gem: XpGem = _game._gems[gem_before] if _game._gems.size() > gem_before else null
	_ok(gem != null and gem.global_position.distance_to(player.global_position) > 200.0,
		"新掉的宝石站在掉落点", "" if gem == null else "距玩家 %.0f" % gem.global_position.distance_to(player.global_position))
