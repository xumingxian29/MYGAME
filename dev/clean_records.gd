extends SceneTree

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
		if str(key).begins_with("触屏") or str(key).begins_with("诊断"):
			players.erase(key)
			removed.append(str(key))
	data["players"] = players
	if str(data.get("last_player", "")).begins_with("触屏") or str(data.get("last_player", "")).begins_with("诊断"):
		data["last_player"] = ""
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(JSON.stringify(data, "\t"))
	out.close()
	print("removed: ", removed, " left: ", players.keys())
	quit()
