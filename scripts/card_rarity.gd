class_name CardRarity
extends RefCounted

## 升级卡的稀有度档位：名字、颜色、数值倍率、出货权重，全部集中在这里。
## Game 用它决定倍数与概率，HUD 用它决定边框/徽章颜色，两边不会各写一套而对不上。

const COMMON: int = 0
const RARE: int = 1
const EPIC: int = 2
const LEGENDARY: int = 3
const COUNT: int = 4

const NAMES: Array[String] = ["普通", "稀有", "史诗", "传说"]
## 深色卡片上的可读性优先：普通为灰白，往上依次蓝 / 紫 / 金
const COLORS: Array[Color] = [
	Color(0.76, 0.82, 0.92),
	Color(0.36, 0.70, 1.00),
	Color(0.72, 0.48, 1.00),
	Color(1.00, 0.79, 0.28),
]
## 强度倍率。取 1.8 / 2.9 / 4.2 而不是整倍数，是为了让「数量类」卡按
## round(1×倍率) 自然落在 +2 / +3 / +4，形成清晰的台阶。
## 卡片总数变少（最多 8 张）后高档必须更值钱，否则同等强度只有改造前的一半。
const MULTIPLIERS: Array[float] = [1.0, 1.8, 2.9, 4.2]
const STRENGTH_TEXT: Array[String] = ["×1.0", "×1.8", "×2.9", "×4.2"]

## 出货权重：开局几乎全是普通，越往后高档卡越常见。
## 两个端点之间按等级线性插值，改曲线只需要动这两行。
const EARLY_WEIGHTS: Array[float] = [66.0, 27.0, 7.0, 0.0]
const LATE_WEIGHTS: Array[float] = [10.0, 27.0, 37.0, 26.0]
## 从第几张卡开始变"欧"，到多少级拉满
const LUCK_START_LEVEL: int = 2
const LUCK_FULL_LEVEL: int = 34


static func weights_at(level: int) -> Array[float]:
	var span: float = float(maxi(LUCK_FULL_LEVEL - LUCK_START_LEVEL, 1))
	var t: float = clampf(float(level - LUCK_START_LEVEL) / span, 0.0, 1.0)
	var weights: Array[float] = []
	for i in range(COUNT):
		weights.append(lerpf(EARLY_WEIGHTS[i], LATE_WEIGHTS[i], t))
	return weights


## 按等级权重抽一档。返回 COMMON ~ LEGENDARY。
static func roll(level: int) -> int:
	var weights: Array[float] = weights_at(level)
	var total: float = 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return COMMON

	var pick: float = randf() * total
	for i in range(COUNT):
		pick -= weights[i]
		if pick <= 0.0:
			return i
	return COUNT - 1


## 供界面直接显示的强度文字（解锁类卡的倍率无意义，单独处理）
static func strength_text(rarity: int) -> String:
	return STRENGTH_TEXT[clampi(rarity, 0, COUNT - 1)]
