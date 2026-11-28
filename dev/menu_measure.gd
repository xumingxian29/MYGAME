extends SceneTree

## 量主菜单面板高度 vs 视口高度，验证压缩后没有被裁。
## 用法：godot --path . --script res://dev/menu_measure.gd
## 只打印，不做断言；数字给人看。

var _game: Node = null
var _frames: int = 0


func _initialize() -> void:
	root.add_child(load("res://MY主场景.tscn").instantiate())


func _process(_d: float) -> bool:
	if _game == null:
		_game = root.get_child(root.get_child_count() - 1)
		if _game == null or not _game.has_method("_begin_run"):
			_game = null
			return false
		return false
	_frames += 1
	if _frames < 10:
		return false
	var menu = _game.start_menu
	var panel = menu._panel
	print("viewport=", root.get_visible_rect().size)
	print("panel.size=", panel.size)
	print("box.size=", menu._box.size)
	var mute = menu._mute_btn
	print("mute global_bottom=", mute.global_position.y + mute.size.y)
	quit()
	return true
