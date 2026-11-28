class_name Stage
extends RefCounted

## 关卡（章）数据表 + 无尽循环生成。
##
## 一局 = 三章 + 无尽循环。每章有独立的敌人构成、配色和章节 Boss，
## 打完 Boss 才进下一章——所以"关卡"不是背景板，而是一次必须跨过的门槛。
## 全部数据集中在这一个文件，理由和 HeroClass 一样：界面、刷怪逻辑、配色
## 读同一份表，才不会出现"界面写第二章、刷怪还在用第一章"的对不上。
##
## 为什么不按固定秒数刷 Boss（原实现 90/180/270）：
## 时间驱动的 Boss 和"打到哪了"没有关系，玩家 90 秒时正在被围，Boss 照样插进来；
## 反过来玩家清得干净，也换不来任何节奏变化。改成"章节目标"后，
## 玩家的进度感来自"我推进到第几章"，而不是"我撑了多少秒"。

## 每章开头这么多秒只有普通小兵。新章的第一印象必须是"看得懂的局面"：
## 一进来就被吐息和自爆夹击，只会让人觉得难度是随机跳的。
const INTRO_TIME: float = 15.0

## 手写章节数。之后的章节由 _endless() 生成。
const COUNT: int = 3
const ORDINALS: Array[String] = ["第一章", "第二章", "第三章"]

## charger / spitter / bomber 是"每只怪成为该类型的概率"，三者之和必须 ≤ 1，
## 剩下的部分全是普通小兵。普通小兵是包围与分离的主体，任何一章都不能没有它。
##
## breach_shots / breach_every 是破甲弹的两个配平旋钮，一起决定 Boss 战的手感：
##   breach_shots —— 打穿这只 Boss 需要几发（Boss 生命 = 发数 × 单发固定伤害）
##   breach_every —— 多少秒掉一枚（Boss 战期间按 0.6 倍加速）
##
## 这两个数从"12/16/20 发、4.0/4.5/5.0 秒"改到"18/23/28 发、2.4/2.5/2.6 秒"，
## 是同一次改动：Boss 多了"出招无敌 / 破甲窗口"的循环，单场最短时长被钉在
## "窗口数 × 一轮时长"上，血量必须抬高，否则两个窗口就打完了。
## 但血量不能只抬不放——抬血量而不抬掉率，等于把 Boss 战拉成 60 秒的拉锯，
## 而这局的毒圈只给 5~8 分钟。**单场 Boss 的目标时长是 25~35 秒**：
## 18×1.44≈26s / 23×1.5≈35s / 28×1.56≈44s（Boss 战期间按 0.6 倍加速后的间隔）。
## 改任意一个数，都先算一遍"发数 × 间隔"是不是还在 25~45 秒区间里。
const LIST: Array[Dictionary] = [
	{
		"name": "残响浅滩",
		"subtitle": "潮水退了，岸上还站着东西",
		"length": 70.0,
		"boss": "潮主",
		"charger": 0.13,
		"spitter": 0.0,
		"bomber": 0.0,
		"hp_scale": 1.0,
		"breach_shots": 18,
		"breach_every": 2.4,
		"tint": Color(0.36, 0.82, 0.74),
		"bg": Color(0.043, 0.068, 0.075),
	},
	{
		"name": "锈蚀回廊",
		"subtitle": "墙在渗水，水里有东西在喘",
		"length": 80.0,
		"boss": "蚀影",
		"charger": 0.12,
		"spitter": 0.10,
		"bomber": 0.0,
		"hp_scale": 1.05,
		"breach_shots": 23,
		"breach_every": 2.5,
		"tint": Color(0.92, 0.66, 0.32),
		"bg": Color(0.070, 0.055, 0.038),
	},
	{
		"name": "深渊之喉",
		"subtitle": "再往下没有底，只有更多要上来的",
		"length": 90.0,
		"boss": "深潜者",
		"charger": 0.10,
		"spitter": 0.10,
		"bomber": 0.09,
		"hp_scale": 1.12,
		"breach_shots": 28,
		"breach_every": 2.6,
		"tint": Color(0.66, 0.50, 0.96),
		"bg": Color(0.055, 0.045, 0.085),
	},
]

## 无尽循环的 Boss 轮换表：三章的三只循环出场，不再造新名字。
## 玩家能一眼认出"又是潮主，但它更硬了"，比每轮换一个陌生名字更有压迫感。
const BOSS_CYCLE: Array[String] = ["潮主", "蚀影", "深潜者"]

## 关底 Boss 的招式风格，取值对应 Enemy.BOSS_KIT_TABLES 的下标。
## 按名字查而不是按章号：无尽轮次会循环复用这三只，
## 玩家认的是"潮主会拍浪、蚀影会跳、深潜者会放追踪弹"，不是"第三章的 Boss 会什么"。
const BOSS_KITS: Dictionary = {
	"潮主": 0,
	"蚀影": 1,
	"深潜者": 2,
}
## 出场横幅上的一句提示。Boss 的威胁来自招式，不来自血量——
## 玩家第一次遇到它时该知道"要防的是什么"，而不是自己挨两轮才摸出来。
const BOSS_HINTS: Dictionary = {
	"潮主": "它抬手的时候，浪就已经到了",
	"蚀影": "你看到的那只，是它留在原地的影子",
	"深潜者": "水压先到，它后到",
}
## 无尽每轮的额外血量倍率**已停用**（保留常量是为了不打断旧引用）。
## 难度增长现在由 Game 的 _floor（每穿过一道传送门 ×1.10）独占：
## 旧的 ENDLESS_HP_STEP 是 1.3，两项叠起来每关 1.43 倍，
## 第 5 张图的怪血量会是第 1 张的 3 倍——那不是"更深一层"，是必死。
## 一个乘数只能有一个来源，否则调任何一边都会把另一边顶穿。
const ENDLESS_HP_STEP: float = 1.0
## 无尽每轮的长度增量：越往后单章越长，节奏不至于刚开打就结束
const ENDLESS_LENGTH_STEP: float = 10.0

## 章节切换的无敌/回血窗口由 Game 决定，这里只给数据。
static func at(index: int) -> Dictionary:
	if index < 0:
		index = 0
	if index < COUNT:
		return LIST[index]
	return _endless(index - COUNT + 1)


static func _endless(cycle: int) -> Dictionary:
	# 以第三章为模板：特殊怪全开，血量和长度按轮次往上加
	var data: Dictionary = LIST[COUNT - 1].duplicate()
	data["name"] = "回响 %d" % cycle
	data["subtitle"] = "同一层，第 %d 次涨潮" % cycle
	data["boss"] = BOSS_CYCLE[(cycle - 1) % BOSS_CYCLE.size()]
	data["charger"] = 0.12
	data["spitter"] = 0.12
	data["bomber"] = 0.12
	data["length"] = float(LIST[COUNT - 1]["length"]) + ENDLESS_LENGTH_STEP * float(cycle - 1)
	data["hp_scale"] = float(LIST[COUNT - 1]["hp_scale"]) * pow(ENDLESS_HP_STEP, float(cycle))
	# 无尽轮次的破甲需求跟着涨：每轮多 4 发、掉率每轮慢 0.6 秒。
	# 它和 hp_scale 是两条独立的压力——hp_scale 只影响小怪，
	# Boss 打不打得动只看破甲弹，所以这条必须单独抬。
	data["breach_shots"] = int(LIST[COUNT - 1]["breach_shots"]) + 4 * cycle
	data["breach_every"] = float(LIST[COUNT - 1]["breach_every"]) + 0.6 * float(cycle)
	return data


## 界面上的一行标题，例如"第二章 · 锈蚀回廊"
static func title(index: int) -> String:
	if index < 0:
		index = 0
	if index < COUNT:
		return "%s · %s" % [ORDINALS[index], LIST[index]["name"]]
	return "无尽 · %s" % _endless(index - COUNT + 1)["name"]


## 只要名字（结算面板用，避免"第三章 · 深渊之喉"和"通关"重复说两遍）
static func name_at(index: int) -> String:
	if index < 0:
		index = 0
	if index < COUNT:
		return str(LIST[index]["name"])
	return "无尽 %s" % _endless(index - COUNT + 1)["name"]


## 走完三章 = 通关。之后的轮次仍然算通关状态。
static func is_cleared(index: int) -> bool:
	return index >= COUNT


static func tint(index: int) -> Color:
	return LIST[clampi(index, 0, COUNT - 1)]["tint"]


## Boss 名字 → 招式风格下标。认不出来的名字退回 0（潮主那套），不会崩。
static func boss_kit(boss_name: String) -> int:
	return int(BOSS_KITS.get(boss_name, 0))


static func boss_hint(boss_name: String) -> String:
	return str(BOSS_HINTS.get(boss_name, ""))


static func background(index: int) -> Color:
	return LIST[clampi(index, 0, COUNT - 1)]["bg"]
