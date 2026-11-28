extends SceneTree

## 一次性 API 侦查：确认 4.7.2 里 2D 物理插值到底有哪些入口，
## 以及引擎默认的 physics_interpolation 设置值。不做任何断言，只打印。

func _initialize() -> void:
	print("== physics/common/physics_interpolation = %s" % str(ProjectSettings.get_setting("physics/common/physics_interpolation")))
	print("== 相关 ProjectSettings 键 ==")
	for p in ProjectSettings.get_property_list():
		var n: String = str(p["name"])
		if "interpolat" in n:
			print("  %s = %s" % [n, str(ProjectSettings.get_setting(n))])

	for cls in ["Node2D", "Camera2D", "Node", "CanvasItem", "Control"]:
		var methods: Array = []
		var obj: Object = ClassDB.instantiate(cls)
		for m in obj.get_method_list():
			if "interpolat" in str(m["name"]):
				methods.append(str(m["name"]))
		var props: Array = []
		for p in obj.get_property_list():
			if "interpolat" in str(p["name"]):
				props.append(str(p["name"]))
		print("== %s ==" % cls)
		print("  methods: %s" % str(methods))
		print("  props:   %s" % str(props))
		obj.free()
	quit()
