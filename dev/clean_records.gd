extends SceneTree

func _is_test_name(name: String) -> bool:
	for prefix in ["触屏", "诊断", "探针", "bot"]:
		if name.begins_with(prefix):
			return true
	return false


func _init() -> void:
	var path := "user://records.json"
	if not FileAccess.file_exists(path):
		print("no records file")
		quit()
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		print("bad json")
		quit()
		return
	var players: Dictionary = data.get("players", {})
	var removed: Array[String] = []
	for key in players.keys():
		# 自检用过的名字：触屏探针、诊断、毒圈探针、平衡 bot。
		# 它们会出现在开始菜单的战绩榜里，不清理的话玩家会看到"bot 668153 分"。
		if _is_test_name(str(key)):
			players.erase(key)
			removed.append(str(key))
	data["players"] = players
	if _is_test_name(str(data.get("last_player", ""))):
		data["last_player"] = ""
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(JSON.stringify(data, "\t"))
	out.close()
	print("removed: ", removed, " left: ", players.keys())
	quit()
