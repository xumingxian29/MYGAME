class_name Difficulty
extends RefCounted

## 难度档位：一张乘数表，三档共用同一条曲线。
##
## 设计前提（11/28 拍板）：**标准档必须是恒等变换**。
## Stage.POWER / Game.ENEMY_HP_GROWTH / Portal.BIAS 已经构成一条标定好的曲线，
## "终幕 / 首幕 = 3.5 倍"是钉在 portal_check 里的断言。难度若混进那条曲线，
## 三档就会变成三套数值表，最后只有一套有人维护（见 docs/优化方案 §9）。
## 所以这里只放**乘在曲线之外**的四个旋钮，标准档全部为 1.0 / 0，
## 任何一档都不会改动 _power_scale()、波数公式或敌人血量公式。
##
## 玩家默认档由 DEFAULT 决定（轻松）；但代码里的实例默认值是 NORMAL：
## dev/ 下 484 项自检直接调 _on_menu_started(name, hero)，不带难度参数，
## 它们量的是"裸曲线"。玩家的默认档由主菜单显式注入，两条路径互不污染。
##
## 为什么轻松档不减怪：P0 实测过"怪少一半 → 经验少一半 → 升级慢 → DPS 更低"
## 的死亡螺旋（见 game.gd BUDGET_BASE 注释）。轻松档的四个旋钮全部**不碰经济**：
## 减伤、回血、补给、放宽同屏上限，击杀数与经验一个都不动。

enum { EASY, NORMAL, HARD }
const COUNT: int = 3
## 玩家侧的默认档。新玩家第一次进来先让他赢（11/28 拍板）。
const DEFAULT: int = EASY

const NAMES: Array[String] = ["轻松", "标准", "硬核"]
const DESCS: Array[String] = [
	"受击更轻、每幕开头回血、Boss 战补弹 —— 先走完十幕",
	"设计基准曲线：终幕敌人约为首幕的 3.5 倍",
	"受击更重、每波多 20% 敌人 —— 不给补给也不回血",
]
const COLORS: Array[Color] = [
	Color(0.55, 0.88, 0.68),   # 轻松 · 绿
	Color(0.72, 0.80, 0.94),   # 标准 · 蓝白
	Color(0.95, 0.58, 0.48),   # 硬核 · 红
]

## 玩家受到的所有伤害（含毒圈）乘这个数。
const DAMAGE_TAKEN: Array[float] = [0.75, 1.00, 1.10]
## 每次进入新幕回复最大生命的比例（0 = 不回）。第一幕开局满血，不需要。
const STAGE_HEAL: Array[float] = [0.15, 0.00, 0.00]
## 每场 Boss 战开场额外补几发破甲弹。王座厅五位守门人也算。
const BREACH_GIFT: Array[int] = [2, 0, 0]
## 每波刷怪数量乘数。**轻松档保持 1.0**：减怪会减经验，是负循环。
const WAVE_MULT: Array[float] = [1.00, 1.00, 1.20]


static func clamp_index(index: int) -> int:
	return clampi(index, 0, COUNT - 1)


static func name_of(index: int) -> String:
	return NAMES[clamp_index(index)]


static func desc_of(index: int) -> String:
	return DESCS[clamp_index(index)]


static func color_of(index: int) -> Color:
	return COLORS[clamp_index(index)]


static func damage_taken(index: int) -> float:
	return DAMAGE_TAKEN[clamp_index(index)]


static func stage_heal(index: int) -> float:
	return STAGE_HEAL[clamp_index(index)]


static func breach_gift(index: int) -> int:
	return BREACH_GIFT[clamp_index(index)]


static func wave_mult(index: int) -> float:
	return WAVE_MULT[clamp_index(index)]


## 一行式摘要，给结算面板用。例："轻松 · 受击 ×0.75 · 每幕回血 15%"
static func summary(index: int) -> String:
	var i: int = clamp_index(index)
	var parts: Array[String] = [NAMES[i]]
	if DAMAGE_TAKEN[i] != 1.0:
		parts.append("受击 ×%.2f" % DAMAGE_TAKEN[i])
	if STAGE_HEAL[i] > 0.0:
		parts.append("每幕回血 %d%%" % roundi(STAGE_HEAL[i] * 100.0))
	if BREACH_GIFT[i] > 0:
		parts.append("Boss 补 %d 发" % BREACH_GIFT[i])
	if WAVE_MULT[i] != 1.0:
		parts.append("每波 ×%.2f" % WAVE_MULT[i])
	if parts.size() == 1:
		parts.append("基准曲线")
	return " · ".join(parts)
