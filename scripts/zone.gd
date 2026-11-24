class_name Zone
extends Node2D

## 吃鸡式缩圈：时间轴 + 圈心 + 半径 + 毒伤速率。
##
## 职责只有一个——把一局的时间上限钉死。难度曲线负责"大多数人死在哪"，
## 毒圈负责"没有人能超过 11:30"。所以毒伤不能一开始就压满，
## 否则玩家不是被怪打死，而是被圈追着跑到死，手感会变成另一种难受。
##
## 半径单位是「视野半径 V」的倍数，不是像素：
##   桌面 1280x720，zoom 1.35 → 世界可见半宽 474、半高 267，外接半径 V≈545
##   手机 960x540 → V≈408
## 写死像素的话，手机会看到比桌面大 33% 的圈，同一套时间轴手感完全不同。

## 时间轴。from/to 是本段的起止秒数，r0/r1 是段首/段尾半径（V 的倍数），
## dps 是圈外每秒伤害占最大生命的比例（dps_to >= 0 时在段内线性过渡）。
## 收缩段的 r1 < r0 就是"缩圈"，r0 == r1 就是"等待"——两类共用一个结构，
## 少一套状态机，时间轴改起来只看这张表。
const SEGMENTS: Array = [
	{"from": 0.0,   "to": 120.0, "r0": 2.20, "r1": 2.20, "dps": 0.000, "label": "安全区稳定"},
	{"from": 120.0, "to": 165.0, "r0": 2.20, "r1": 1.50, "dps": 0.010, "label": "安全区收缩"},
	{"from": 165.0, "to": 240.0, "r0": 1.50, "r1": 1.50, "dps": 0.010, "label": "安全区稳定"},
	{"from": 240.0, "to": 285.0, "r0": 1.50, "r1": 1.10, "dps": 0.016, "label": "安全区收缩"},
	{"from": 285.0, "to": 360.0, "r0": 1.10, "r1": 1.10, "dps": 0.016, "label": "安全区稳定"},
	{"from": 360.0, "to": 405.0, "r0": 1.10, "r1": 0.85, "dps": 0.025, "label": "安全区收缩"},
	{"from": 405.0, "to": 480.0, "r0": 0.85, "r1": 0.85, "dps": 0.025, "label": "安全区稳定"},
	{"from": 480.0, "to": 525.0, "r0": 0.85, "r1": 0.62, "dps": 0.040, "label": "安全区收缩"},
	{"from": 525.0, "to": 585.0, "r0": 0.62, "r1": 0.45, "dps": 0.060, "label": "决战"},
	{"from": 585.0, "to": 690.0, "r0": 0.45, "r1": 0.00, "dps": 0.100, "dps_to": 0.180, "label": "终局"},
]

## 新圈心相对旧圈心的最大偏移，等于 (旧半径 - 新半径) 的这个比例。
## 必须 < 1：等于 1 时新圈刚好内切，随机方向一旦抽偏就会出现"新圈跑到旧圈外"，
## 那是必死且无解的局面。0.55 保留明显位移（逼玩家挪位）又不至于横穿整张地图。
const CENTER_SHIFT_RATIO: float = 0.55

## 桌面 1280x720 / zoom 1.35 的外接视野半径。
const DEFAULT_VIEW_RADIUS: float = 545.0

const RING_COLOR: Color = Color(0.72, 0.42, 1.0, 0.85)
const RING_WIDTH: float = 3.0

## 当前圈（世界坐标）。bot 与 HUD 都按这两个名字读，别改名。
var center: Vector2 = Vector2.ZERO
var radius: float = 0.0

var _view_radius: float = DEFAULT_VIEW_RADIUS
var _t: float = 0.0
var _seg_index: int = -1
## 段内的圈心起止点，收缩时从 _c_from 平滑移到 _c_to
var _c_from: Vector2 = Vector2.ZERO
var _c_to: Vector2 = Vector2.ZERO
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	# 圆圈画在所有游戏物体之下，但仍在背景网格之上（父节点先画，子节点后画）
	z_index = -1
	reset(DEFAULT_VIEW_RADIUS, 0)


## 开新一局：半径回到最大，圈心归零，随机种子固定（同一 seed 的 bot 局可复现）。
func reset(view_radius: float, seed_value: int) -> void:
	_view_radius = maxf(view_radius, 1.0)
	_rng.seed = seed_value
	_t = 0.0
	_seg_index = -1
	center = Vector2.ZERO
	radius = float(SEGMENTS[0]["r0"]) * _view_radius
	_c_from = center
	_c_to = center
	_enter_segment(0)
	queue_redraw()


## 推进时间轴。只有 PLAYING 状态才该调用，暂停时不走。
func tick(delta: float) -> void:
	_t += delta
	while _seg_index + 1 < SEGMENTS.size() and _t >= float(SEGMENTS[_seg_index + 1]["from"]):
		_enter_segment(_seg_index + 1)
	var seg: Dictionary = SEGMENTS[_seg_index]
	var span: float = maxf(float(seg["to"]) - float(seg["from"]), 0.001)
	var p: float = clampf((_t - float(seg["from"])) / span, 0.0, 1.0)
	var r: float = lerpf(float(seg["r0"]), float(seg["r1"]), p) * _view_radius
	center = _c_from.lerp(_c_to, p)
	if absf(r - radius) > 0.25:
		radius = r
		queue_redraw()


## 进入第 index 段。收缩段在这里抽一次方向，决定圈心要往哪边挪。
func _enter_segment(index: int) -> void:
	_seg_index = clampi(index, 0, SEGMENTS.size() - 1)
	var seg: Dictionary = SEGMENTS[_seg_index]
	var r0: float = float(seg["r0"]) * _view_radius
	var r1: float = float(seg["r1"]) * _view_radius
	_c_from = center
	if r1 < r0 - 0.5:
		var dir: Vector2 = Vector2.RIGHT.rotated(_rng.randf() * TAU)
		_c_to = center + dir * (r0 - r1) * CENTER_SHIFT_RATIO
	else:
		_c_to = center


## 圈外每秒伤害，占最大生命的比例。段内可线性过渡（终局的 10%→18%）。
func dps() -> float:
	var seg: Dictionary = SEGMENTS[_seg_index]
	var base: float = float(seg["dps"])
	var target: float = float(seg.get("dps_to", -1.0))
	if target < 0.0:
		return base
	var span: float = maxf(float(seg["to"]) - float(seg["from"]), 0.001)
	return lerpf(base, target, clampf((_t - float(seg["from"])) / span, 0.0, 1.0))


func is_outside(pos: Vector2) -> bool:
	return pos.distance_to(center) > radius


## 当前段剩余秒数。HUD 用它报"还有几秒开始缩圈"。
func segment_time_left() -> float:
	var seg: Dictionary = SEGMENTS[_seg_index]
	return maxf(float(seg["to"]) - _t, 0.0)


func segment_label() -> String:
	return str(SEGMENTS[_seg_index]["label"])


func is_shrinking() -> bool:
	var seg: Dictionary = SEGMENTS[_seg_index]
	return float(seg["r1"]) < float(seg["r0"]) - 0.001


func elapsed() -> float:
	return _t


func _draw() -> void:
	if radius <= 1.0:
		return
	draw_arc(center, radius, 0.0, TAU, 128, RING_COLOR, RING_WIDTH, true)
	# 内侧描一道更暗的线，收缩时看起来像有两层壁，比单线更容易判断距离
	if radius > 60.0:
		draw_arc(center, radius - 8.0, 0.0, TAU, 128, Color(RING_COLOR, 0.28), 1.5, true)
