class_name HeroClass
extends RefCounted

## 三个职业的唯一数据源：基础数值、配色、主动技能。
## Player 按这里配属性，HUD 按这里显示技能名，菜单按这里排版三张职业卡。
## 全部集中在一个文件，是为了避免"界面写血量 180、逻辑给 160"这种对不上的情况。

const WARRIOR: int = 0
const MAGE: int = 1
const RANGER: int = 2
const COUNT: int = 3

const NAMES: Array[String] = ["战士", "法师", "射手"]
const ROLES: Array[String] = ["近战 · 高血", "远程 · 高伤", "远程 · 高射速"]
const COLORS: Array[Color] = [
	Color(1.00, 0.56, 0.36),
	Color(0.68, 0.52, 1.00),
	Color(0.42, 0.95, 0.70),
]
const DESCS: Array[String] = [
	"血量 180，只能贴身近战：一次挥砍打中身前扇形内的所有敌人，站桩能力强。",
	"能量球单发伤害高、攻速慢，命中后小范围爆裂；血量只有 100，怕被围。",
	"箭矢射速极快但单发伤害低，靠走位拉扯；血最薄，容错最低。",
]

const HEALTH: Array[float] = [180.0, 100.0, 110.0]
const SPEED: Array[float] = [226.0, 232.0, 252.0]

const MANA_MAX: float = 100.0
## 击杀回蓝：战士靠贴脸换命，回蓝最快；射手击杀数最多，所以给最低值
const MANA_PER_KILL: Array[float] = [8.0, 7.0, 5.0]
## 自然回蓝（每秒）。法师技能最强，只给基础值，逼他用击杀换充能
const MANA_REGEN: Array[float] = [2.2, 1.6, 2.6]

const SKILL_NAMES: Array[String] = ["旋风斩", "奥术新星", "箭雨"]
const SKILL_DESCS: Array[String] = [
	"1.2 秒无敌，劈开并击退周围敌人",
	"大范围爆伤，命中者减速 2.5 秒",
	"向四周射出 14 支穿透箭矢",
]


## 界面上的小标签，例如"战士 · 近战 · 高血"
static func title(hero: int) -> String:
	var index: int = clampi(hero, 0, COUNT - 1)
	return "%s · %s" % [NAMES[index], ROLES[index]]


static func skill_name(hero: int) -> String:
	return SKILL_NAMES[clampi(hero, 0, COUNT - 1)]


static func color(hero: int) -> Color:
	return COLORS[clampi(hero, 0, COUNT - 1)]
