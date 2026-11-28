class_name Story
extends RefCounted

## 剧情数据表：王子逃离黑暗城堡。
##
## 为什么剧情单独一个文件、而不是散在 Game 的各个横幅里：
## 这一版要求"剧情覆盖整个游戏"——菜单、每一幕的开场、Boss 出场、商人、
## 死亡结算、胜利结算都要说同一件事。文本一旦散在六处，
## 想改一句台词就得全项目搜，而且必然出现"结算里写三章、HUD 里写十幕"。
##
## 一个约束写在这里：**每一行都必须短**。手机横屏 844×390 CSS 像素，
## 一行 24 个汉字已经是极限，超过就要换行，换行之后整块文字的排版就散了。
## 所以台词一律"一句一行"，宁可用多行，不写长句。

## 一局要走十道门。这个数同时决定了剧情有多少幕——
## 剧情不是配菜，它就是"你在第几幕"这件事本身。
const ACT_COUNT: int = 10

const ORDINALS: Array[String] = [
	"第一幕", "第二幕", "第三幕", "第四幕", "第五幕",
	"第六幕", "第七幕", "第八幕", "第九幕", "第十幕",
]

## 每一幕：名字、开场台词、横幅上的一句话、配色。
## tint 跟着场景走（地牢冷蓝 → 宴会暖橙 → 镜厅紫 → 王座血红），
## 玩家不看字也能从颜色上感觉到"更深了"。
const ACTS: Array[Dictionary] = [
	{
		"name": "铁门之后",
		"lines": [
			"你不记得自己睡了多久。",
			"铁门自己开了，锁还挂在上面。",
			"走廊尽头有风——风里没有外面的味道。",
		],
		"beat": "地牢最深处 · 门是开着的",
		"tint": Color(0.42, 0.74, 0.92),
	},
	{
		"name": "无人的长廊",
		"lines": [
			"盔甲整整齐齐站着，里面是空的。",
			"你走过一具，身后就多一串脚步。",
			"别回头。回头它们就不动了。",
		],
		"beat": "长廊 · 没有守卫，只有脚步声",
		"tint": Color(0.52, 0.80, 0.86),
	},
	{
		"name": "熄灯的宴会厅",
		"lines": [
			"十年前的宴席还摆着，蜡烛烧到了底。",
			"主位上的椅子朝向你，像在等你入座。",
			"潮主从桌下站起来时，桌布还在滴水。",
		],
		"beat": "宴会厅 · 酒还温着，人已经不在了",
		"tint": Color(0.94, 0.72, 0.42),
	},
	{
		"name": "渗水的回廊",
		"lines": [
			"墙在渗水。水里有东西在数数。",
			"它数到七，就重来一次。",
			"第七次之后，它开始数你。",
		],
		"beat": "回廊 · 水里有声音在数数",
		"tint": Color(0.44, 0.72, 0.78),
	},
	{
		"name": "镜厅",
		"lines": [
			"每一面镜子里的你，都慢半步。",
			"你停下，它们还在走。",
			"蚀影从最深的那面镜子里侧身出来。",
		],
		"beat": "镜厅 · 镜子里的你慢半步",
		"tint": Color(0.72, 0.62, 0.98),
	},
	{
		"name": "塔基的螺旋",
		"lines": [
			"往上是唯一的出路。",
			"台阶一共九百级，你数到第三百就忘了。",
			"忘了也好——数到底的人，会知道塔有几层。",
		],
		"beat": "塔基 · 上去的只有这一条",
		"tint": Color(0.60, 0.68, 0.92),
	},
	{
		"name": "无光的礼拜堂",
		"lines": [
			"蜡烛点不着，可地上有影子在祈祷。",
			"它们念的不是神的名字。",
			"听起来像你的名字。",
		],
		"beat": "礼拜堂 · 祷告里念的是你",
		"tint": Color(0.68, 0.56, 0.86),
	},
	{
		"name": "灰色的雪",
		"lines": [
			"窗外的雪是灰的，落在手上会烧。",
			"你看见远处有你小时候的房间。",
			"那不是窗户，是画上去的。",
		],
		"beat": "顶层的窗 · 雪落下来会烧",
		"tint": Color(0.72, 0.80, 0.90),
	},
	{
		"name": "九级台阶",
		"lines": [
			"王座前的台阶有九级。",
			"你走到第五级就停了——上面有影子在等你。",
			"深潜者最后一个起身，它从没浮上来过。",
		],
		"beat": "王座前 · 五道影子站起来了",
		"tint": Color(0.86, 0.52, 0.52),
	},
	{
		"name": "王座之前",
		"lines": [
			"第十道门后面没有房间，只有一段向下的台阶。",
			"台阶尽头是王座厅——门开着，里面很亮。",
			"亮的东西不一定是光。",
		],
		"beat": "王座之前 · 门开着，里面很亮",
		"tint": Color(0.88, 0.40, 0.44),
	},
]

## 终章。它不在十幕里：十道门走完才进得来，所以单独一份数据。
## 如果说十幕是"往上爬"，终章就是"爬到了顶，发现顶上是空的"。
const FINALE: Dictionary = {
	"title": "终章 · 王座厅",
	"lines": [
		"王座是空的。",
		"空着的那块地方，正在看你。",
		"五位守门人从影子里站起来，一位接着一位。",
	],
	"beat": "空着的地方，正在看你",
	"tint": Color(0.94, 0.32, 0.36),
}

## 王座厅的五位守门人。顺序就是出场顺序，血量由 Game 逐位抬高。
## 前三位是前面三幕见过的老面孔（同一批影子又站了起来），
## 第四位是王子自己的影子，第五位是城堡本身——
## "越打越像自己"这件事，比换五个陌生名字更有压迫感。
const GAUNTLET: Array[Dictionary] = [
	{"name": "潮主", "line": "地下的潮水把它又推了上来"},
	{"name": "蚀影", "line": "镜子碎了，它还在"},
	{"name": "深潜者", "line": "它从来没浮上过水面"},
	{"name": "暗影王子", "line": "那是你——先一步走到了这里"},
	{"name": "无光之王", "line": "王座是空的，空着的地方站起来了"},
]

## 出场横幅上的一句提示，按 Boss 名字查。
## 和 Stage.BOSS_HINTS 的分工：那边写"它怎么打"（机制），这边写"它是谁"（剧情）。
const BOSS_LINES: Dictionary = {
	"潮主": "它从宴席底下爬出来，身上还挂着桌布",
	"蚀影": "你打的是它留在镜子里的那一半",
	"深潜者": "它上来的时候，整座塔都在渗水",
	"暗影王子": "它穿着和你一样的衣服，只是旧了很多年",
	"无光之王": "城堡醒了。它一直就是这座城堡",
}

## 从王座厅走向城门的这一刻，门外是什么，由**这一局怎么选门**决定。
## 五个结局不是"随机抽一个"：十次选门里哪一类占多数，就走向哪一种门外。
##
## 为什么把结局挂在"选门"上而不是"最后一个对话选项"：
## 门是这局唯一重复十次、且每次都真的有代价的决策（奖励越大，下一幕越难）。
## 玩家早就忘了自己在第 3 幕选过什么，但那个选择一直在累加——这才是"选择指向结局"。
##
## 每一段恰好三行，和原先把三行尾声塞进结算面板的排版一致：
## 不是凑数，是结算面板的高度是按三行留的（手机逻辑高只有 540）。
const ENDINGS: Dictionary = {
	"dawn": {
		"name": "黎明",
		"title": "你走出了城堡",
		"gate": "西门外 · 黎明",
		"lead": "十个门里，你挑了最稳的那种",
		"lines": [
			"你推开了西门。天在亮，城堡在你背后合上。",
			"十年里第一次，你看见自己的影子落在地上。",
			"你逃出来了。这一次没有代价。",
		],
		"tint": Color(1.0, 0.92, 0.68),
	},
	"throne": {
		"name": "新的王",
		"title": "你走出了城堡",
		"gate": "西门外 · 新的王",
		"lead": "每一道门你都拿了双份",
		"lines": [
			"你走出去时走得很慢，身后的椅子认得你了。",
			"你带走的东西太多，多到它们替你回头看。",
			"你逃出来了。城堡换了囚徒——它在笑。",
		],
		"tint": Color(0.90, 0.68, 1.0),
	},
	"ash": {
		"name": "烧掉的路",
		"title": "你走出了城堡",
		"gate": "西门外 · 灰烬",
		"lead": "你一路都在往弹上押",
		"lines": [
			"你不是推开门，是把门打穿的。",
			"身后没有城堡了，也没有路，灰落在肩上像雪。",
			"你逃出来了。只是没有第二个地方可以逃。",
		],
		"tint": Color(1.0, 0.66, 0.44),
	},
	"gold": {
		"name": "买下的门",
		"title": "你走出了城堡",
		"gate": "西门外 · 金子",
		"lead": "你一路都在买路",
		"lines": [
			"锁是金子敲开的，它自己松了。",
			"你带出来的箱子比你还重。",
			"你逃出来了。没有人记得走出来的那个人。",
		],
		"tint": Color(1.0, 0.84, 0.36),
	},
	"mixed": {
		"name": "杂色的清晨",
		"title": "你走出了城堡",
		"gate": "西门外 · 杂色",
		"lead": "四样你都试过，一样只拿一点",
		"lines": [
			"每一扇门你都试过，每样只拿一点。",
			"你身上没有一样东西是纯粹的。",
			"你逃出来了。天亮了，颜色很杂，但没有一种是黑的。",
		],
		"tint": Color(0.72, 0.86, 1.0),
	},
}

## 结局的固定顺序。序号（"结局 2/5"）和"已解锁 N/5"都读它，
## 顺序写死在字典遍历里的话，换一个引擎版本就可能变成另一套编号。
const ENDING_ORDER: Array[String] = ["dawn", "throne", "ash", "gold", "mixed"]

## 门的四种奖励 → 结局。键是 Game 记账用的短名，不是 Portal.Reward 的枚举值：
## 剧情表不该认识玩法层的枚举（Story 是纯数据，反过来 Portal 还要读 Story 的文案）。
const CHOICE_KEYS: Array[String] = ["card", "card2", "breach", "gold"]
const CHOICE_ENDING: Dictionary = {
	"card": "dawn",
	"card2": "throne",
	"breach": "ash",
	"gold": "gold",
}
## 结算面板与确认面板上的单字标签。四门四字，玩家一眼能对上是哪扇门。
const CHOICE_LABELS: Dictionary = {
	"card": "稳",
	"card2": "贪",
	"breach": "战",
	"gold": "财",
}
## 票数不超过这个值就算"没有主导"→ 走杂色结局。
## 十次选择分在四类里，最大票数至少是 3；3/3/2/2 这种分布确实没有偏向，
## 强行从中挑一个会让玩家觉得"我明明每样都拿了，凭什么算我贪"。
const MIXED_MAX: int = 3


static func act_count() -> int:
	return ACT_COUNT


## 终章的三件展示信息。和 act() 分开：终章没有幕号、没有下一幕，
## 混进 ACTS 之后所有"第 N/10 幕"的地方都要特判一次。
static func finale_lines() -> Array:
	return FINALE["lines"]


static func finale_title() -> String:
	return "%s" % FINALE["title"]


static func finale_beat() -> String:
	return str(FINALE["beat"])


static func finale_tint() -> Color:
	return FINALE["tint"]


## 取一幕。越界一律夹回范围内：剧情比地图少一幕就会直接崩在半路。
static func act(index: int) -> Dictionary:
	return ACTS[clampi(index, 0, ACT_COUNT - 1)]


static func title(index: int) -> String:
	var i: int = clampi(index, 0, ACT_COUNT - 1)
	return "%s · %s" % [ORDINALS[i], ACTS[i]["name"]]


## HUD 上那行要更短：幕名已经够长了，再加"第 X 幕"会挤掉难度百分比。
static func name_at(index: int) -> String:
	return str(ACTS[clampi(index, 0, ACT_COUNT - 1)]["name"])


static func progress_text(index: int) -> String:
	var i: int = clampi(index, 0, ACT_COUNT - 1)
	return "第 %d/%d 幕" % [i + 1, ACT_COUNT]


static func tint(index: int) -> Color:
	return ACTS[clampi(index, 0, ACT_COUNT - 1)]["tint"]


static func beat(index: int) -> String:
	return str(ACTS[clampi(index, 0, ACT_COUNT - 1)]["beat"])


## 菜单上的一句引子。开场剧情要能在主菜单就被"预告"到，
## 否则玩家点开始时才第一次知道这游戏有剧情。
static func prologue() -> String:
	return "城堡沉进黑暗的那一夜，王子被锁在了最深处。"


## 商人密室的一行台词。固定一句而不是随机的：
## 玩家在这局里会遇到八到十次商人，随机台词会变成噪音，
## 而一句"越往上越贵"正好把定价规则用剧情说了一遍。
static func merchant_line() -> String:
	return "「殿下，越往上越贵。这是城堡的规矩。」"


## 死亡结算的标题与旁白。用幕号而不是时间：
## "你倒在第 7 幕"比"你存活了 236 秒"更能让人记住这局走到哪。
static func defeat_title(act_index: int) -> String:
	var i: int = clampi(act_index, 0, ACT_COUNT - 1)
	return "你倒在了%s" % ORDINALS[i]


static func defeat_line(act_index: int, by_zone: bool) -> String:
	var i: int = clampi(act_index, 0, ACT_COUNT - 1)
	if by_zone:
		return "城堡把你留在了%s的阴影里。" % ORDINALS[i]
	return "城堡把你收回去，像收回一件借出去的东西。"


## 单只 Boss 的剧情台词。认不出来的名字退回空串，横幅会自动少一行。
static func boss_line(boss_name: String) -> String:
	return str(BOSS_LINES.get(boss_name, ""))


static func gauntlet_count() -> int:
	return GAUNTLET.size()


static func gauntlet(index: int) -> Dictionary:
	return GAUNTLET[clampi(index, 0, GAUNTLET.size() - 1)]


# ---------------------------------------------------------------- 结局

## 十次选门记完账之后，这一局走向哪个结局。
##
## 规则按顺序判：
##   0. 一次都没选 → 黎明（不能落到"杂色"上，那是"四样都试过"）；
##   1. 最大票数 ≤ MIXED_MAX（3）→ 杂色。四类分散就是"没有偏向"，不硬挑一个；
##   2. 最大票数唯一 → 直接对应；
##   3. 并列 → 看**最后一次**选的是哪一个（last_key 在并列组里才生效）。
##      并列不按固定优先级破，是因为"我最后选了贪"比"表里贪排在前面"更像玩家的意愿。
static func resolve_ending(choices: Dictionary, last_key: String = "") -> String:
	var best_key: String = ""
	var best_n: int = 0
	var tied: int = 0
	for key in CHOICE_KEYS:
		var n: int = int(choices.get(key, 0))
		if n > best_n:
			best_n = n
			best_key = key
			tied = 1
		elif n == best_n and n > 0:
			tied += 1
	# 一次都没选（自检直接调结算、或者账本被清）→ 按最朴素的那个结局收，
	# 而不是"杂色"：杂色是"四样都试过"，空账本恰恰是"一样都没选过"。
	if best_n == 0:
		return "dawn"
	if best_n <= MIXED_MAX:
		return "mixed"
	if tied > 1 and last_key != "" and int(choices.get(last_key, 0)) == best_n:
		best_key = last_key
	return str(CHOICE_ENDING.get(best_key, "dawn"))


static func ending(key: String) -> Dictionary:
	return ENDINGS.get(key, ENDINGS["dawn"])


static func ending_order() -> Array[String]:
	var out: Array[String] = []
	for key in ENDING_ORDER:
		out.append(key)
	return out


## 一到五。界面上的"结局 2/5"用这个，不直接拿字典下标——
## 字典顺序不是稳定的接口。
static func ending_index(key: String) -> int:
	var i: int = ENDING_ORDER.find(key)
	return i + 1 if i >= 0 else 1


static func ending_title(key: String) -> String:
	return str(ending(key)["title"])


static func ending_name(key: String) -> String:
	return str(ending(key)["name"])


static func ending_gate(key: String) -> String:
	return str(ending(key)["gate"])


static func ending_lead(key: String) -> String:
	return str(ending(key)["lead"])


static func ending_tint(key: String) -> Color:
	return ending(key)["tint"]


static func ending_lines(key: String) -> Array[String]:
	var out: Array[String] = []
	for line in ending(key)["lines"]:
		out.append(str(line))
	return out


## 确认面板底下那行"走到这里"。空表时返回空串，面板会自动少一行。
## 带上 pending 就把"正在选的这一扇"也算进去——玩家要判断的是"选完之后的形状"。
static func trail_text(choices: Dictionary, pending_key: String = "") -> String:
	var parts: PackedStringArray = []
	for key in CHOICE_KEYS:
		var n: int = int(choices.get(key, 0)) + (1 if key == pending_key else 0)
		if n > 0:
			parts.append("%s %d" % [str(CHOICE_LABELS.get(key, key)), n])
	if parts.is_empty():
		return ""
	return "走过的路：%s" % " · ".join(parts)
