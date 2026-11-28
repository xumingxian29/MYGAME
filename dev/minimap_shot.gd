extends SceneTree

## 小地图截图：常规战斗一张、四门已开一张（门是图上的亮点，要能看见）。
## 用法：godot --path . --script res://dev/minimap_shot.gd   （不能 headless）
## 手机尺寸：再跑一次 --resolution 844x390 -- --touch
## 输出 .workbuddy/minimap_*.png
##
## 小地图这种"右下角一块 120×90"的东西，断言只能验数值（谁在图里、坐标对不对），
## 验不了"它看起来是不是一块糊掉的灰方块"。所以这一份是给眼睛看的。

const OUT_DIR: String = "res://.workbuddy/"
const PLAY_SECONDS: float = 6.0

var _game: Node = null
var _frames: int = 0
var _steps: int = 0
var _shots: PackedStringArray = []


func _initialize() -> void:
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_delta: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null:
			return false
		_game.story_enabled = false
		_game._on_menu_started("minimap_shot", HeroClass.WARRIOR)
		return false
	# 升级卡会盖住画面，直接选第一张
	if _game._state == 2:
		_game._choose(0)
		return false

	_frames += 1
	match _steps:
		0:
			# 先跑几秒让怪刷出来：空图上看不出"敌人点在哪儿"
			if _game._elapsed < PLAY_SECONDS:
				return false
			# 把玩家挪到地图中心附近，保证四周都有走廊和房间可看
			_game.player.global_position = Vector2(0.0, 0.0)
			_game.player.reset_physics_interpolation()
			_frames = 0
			_steps = 1
		1:
			if _frames < 4:
				return false
			_snap("minimap_1_play")
			# 四门：门是地图上唯一的亮青色点，挑门的十几秒里就靠它找路
			_game._open_portals(_game.player.global_position)
			_frames = 0
			_steps = 2
		2:
			if _frames < 6:
				return false
			_snap("minimap_2_gates")
			_finish()
			return true
	return false


func _snap(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		return
	var path: String = OUT_DIR + name + ".png"
	img.save_png(path)
	_shots.append("%s  %dx%d" % [path, img.get_width(), img.get_height()])


func _finish() -> void:
	var f: FileAccess = FileAccess.open(OUT_DIR + "minimap_shots.txt", FileAccess.WRITE)
	if f == null:
		return
	for line in _shots:
		f.store_line(line)
	f.close()
	quit()
