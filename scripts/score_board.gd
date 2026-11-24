class_name ScoreBoard
extends RefCounted

## 分档最高分存档：user://records.json，按昵称分别记录各自的战绩。
## 同一台机器上多人轮流玩时，各看各的历史最高分，互不覆盖。
##
## 文件结构：
## {
##   "version": 2,
##   "last_player": "小明",              # 下次开局默认填入的昵称
##   "players": {
##     "小明": {
##       "best": {score, kills, elite_kills, level, xp_total, elapsed, date},
##       "runs": 3,
##       "total_kills": 128
##     }
##   }
## }
##
## 昵称直接作为 JSON key，所以不需要为文件名做转义。

const SAVE_PATH: String = "user://records.json"
## 旧版单档存档，首次启动时自动并入默认昵称
const LEGACY_PATH: String = "user://records.cfg"
const VERSION: int = 2
const DEFAULT_NAME: String = "玩家"
const MAX_NAME_LENGTH: int = 12

const BEST_KEYS: Array[String] = [
	"score", "kills", "elite_kills", "level", "xp_total", "elapsed", "date",
]


static func empty_best() -> Dictionary:
	return {
		"score": 0,
		"kills": 0,
		"elite_kills": 0,
		"level": 1,
		"xp_total": 0,
		"elapsed": 0.0,
		"date": "",
	}


## 清掉控制字符、首尾空格，并截断到长度上限；空名退回默认昵称。
static func sanitize(raw: String) -> String:
	var text: String = ""
	for i in range(raw.length()):
		var code: int = raw.unicode_at(i)
		if code < 32 or code == 127:
			continue
		text += raw[i]
	text = text.strip_edges()
	if text.length() > MAX_NAME_LENGTH:
		text = text.substr(0, MAX_NAME_LENGTH)
	if text.is_empty():
		return DEFAULT_NAME
	return text


## 昵称大小写归一：已有 "Alice" 时输入 "alice" 仍然读同一份记录。
static func resolve(raw: String) -> String:
	var key := sanitize(raw)
	var players: Dictionary = _read()["players"]
	if players.has(key):
		return key
	var lower: String = key.to_lower()
	for existing in players.keys():
		if str(existing).to_lower() == lower:
			return str(existing)
	return key


## 读取某个昵称的档案：{"name", "best", "runs", "total_kills"}
static func load_profile(raw: String) -> Dictionary:
	var key := resolve(raw)
	var players: Dictionary = _read()["players"]
	var entry: Dictionary = {}
	if players.has(key) and typeof(players[key]) == TYPE_DICTIONARY:
		entry = players[key]
	return {
		"name": key,
		"best": _normalize_best(entry.get("best", {})),
		"runs": int(entry.get("runs", 0)),
		"total_kills": int(entry.get("total_kills", 0)),
	}


## 一局结束后提交。返回 {"profile": 最新档案, "is_best": 是否破个人纪录}
static func submit(raw: String, run: Dictionary) -> Dictionary:
	var key := resolve(raw)
	var data := _read()
	var players: Dictionary = data["players"]

	var entry: Dictionary = {}
	if players.has(key) and typeof(players[key]) == TYPE_DICTIONARY:
		entry = players[key]

	var previous: Dictionary = _normalize_best(entry.get("best", {}))
	var is_best: bool = int(run.get("score", 0)) > int(previous["score"])
	var best: Dictionary = previous
	if is_best:
		best = _normalize_best(run)
		best["date"] = Time.get_datetime_string_from_system(false, true)

	players[key] = {
		"best": best,
		"runs": int(entry.get("runs", 0)) + 1,
		"total_kills": int(entry.get("total_kills", 0)) + int(run.get("kills", 0)),
	}
	data["players"] = players
	data["last_player"] = key
	_write(data)

	return {"profile": load_profile(key), "is_best": is_best}


## 本机所有玩家，按最高分降序。菜单里列出来供直接点选。
static func list_players() -> Array[Dictionary]:
	var players: Dictionary = _read()["players"]
	var out: Array[Dictionary] = []
	for key in players.keys():
		var entry: Variant = players[key]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var best: Dictionary = _normalize_best(entry.get("best", {}))
		out.append({
			"name": str(key),
			"score": int(best["score"]),
			"kills": int(best["kills"]),
			"runs": int(entry.get("runs", 0)),
			"total_kills": int(entry.get("total_kills", 0)),
			"date": str(best["date"]),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["score"]) == int(b["score"]):
			return str(a["name"]) < str(b["name"])
		return int(a["score"]) > int(b["score"]))
	return out


static func last_player() -> String:
	return sanitize(str(_read().get("last_player", DEFAULT_NAME)))


# ---------------------------------------------------------------- 读写

static func _read() -> Dictionary:
	var data: Dictionary = {}
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file != null:
			var text := file.get_as_text()
			file.close()
			var parsed: Variant = JSON.parse_string(text)
			if typeof(parsed) == TYPE_DICTIONARY:
				data = parsed

	if typeof(data.get("players")) != TYPE_DICTIONARY:
		data = _migrate_legacy()

	data["version"] = VERSION
	if typeof(data.get("players")) != TYPE_DICTIONARY:
		data["players"] = {}
	if typeof(data.get("last_player")) != TYPE_STRING:
		data["last_player"] = DEFAULT_NAME
	return data


## 旧版只有一个全局最高分。直接并在默认昵称名下，不丢历史成绩。
static func _migrate_legacy() -> Dictionary:
	var data := {"version": VERSION, "last_player": DEFAULT_NAME, "players": {}}
	var config := ConfigFile.new()
	if config.load(LEGACY_PATH) != OK:
		return data

	var score: int = int(config.get_value("best", "score", 0))
	var runs: int = int(config.get_value("stats", "runs", 0))
	if score <= 0 and runs <= 0:
		return data

	data["players"][DEFAULT_NAME] = {
		"best": {
			"score": score,
			"kills": int(config.get_value("best", "kills", 0)),
			"elite_kills": int(config.get_value("best", "elite_kills", 0)),
			"level": int(config.get_value("best", "level", 1)),
			"xp_total": int(config.get_value("best", "xp_total", 0)),
			"elapsed": float(config.get_value("best", "elapsed", 0.0)),
			"date": str(config.get_value("best", "date", "")),
		},
		"runs": runs,
		"total_kills": int(config.get_value("stats", "total_kills", 0)),
	}
	_write(data)
	return data


static func _write(data: Dictionary) -> void:
	data["version"] = VERSION
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("无法写入存档 %s（错误码 %d）" % [SAVE_PATH, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


## JSON 里的数字都会变成 float，统一转回目标类型，避免界面出现 4877.0
static func _normalize_best(raw: Variant) -> Dictionary:
	var src: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
	return {
		"score": int(src.get("score", 0)),
		"kills": int(src.get("kills", 0)),
		"elite_kills": int(src.get("elite_kills", 0)),
		"level": int(src.get("level", 1)),
		"xp_total": int(src.get("xp_total", 0)),
		"elapsed": float(src.get("elapsed", 0.0)),
		"date": str(src.get("date", "")),
	}
