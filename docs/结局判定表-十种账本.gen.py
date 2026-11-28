# -*- coding: utf-8 -*-
"""生成《结局判定表 · 十种账本》——数据与 scripts/story.gd 逐字对齐。

三个 sheet：
  判定表   10 行 = story_check.gd 里那十种账本，公式现场重算结局
  结局一览 五个结局的门外名、由来与收尾三行
  规则说明 四条判定顺序 + 常量 + 代码位置
"""

try:
    import openpyxl
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "openpyxl>=3.1.0"])
    import openpyxl

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.formatting.rule import CellIsRule
from openpyxl.utils import get_column_letter


def xl_color(css_hex: str) -> str:
    value = css_hex.removeprefix("#").upper()
    if len(value) != 6:
        raise ValueError(f"Expected #RRGGBB, got: {css_hex}")
    return "FF" + value


# 商务蓝（游戏里是暗金配色，文档里保持正式，金色只用在标题那一处）
XL_PRIMARY = xl_color("#4472C4")
XL_DEEP = xl_color("#2F5597")
XL_LIGHT = xl_color("#D9E2F3")
XL_BORDER = xl_color("#BFBFBF")
XL_WHITE = xl_color("#FFFFFF")
XL_TEXT = xl_color("#1A1A1A")
XL_MUTED = xl_color("#6B7280")
XL_GOLD = xl_color("#B7791F")

thin_side = Side(style="thin", color=XL_BORDER)
BORDER = Border(left=thin_side, right=thin_side, top=thin_side, bottom=thin_side)

FONT = "微软雅黑"


def head_cell(ws, row: int, col: int, text: str, width: float = 12.0) -> None:
    c = ws.cell(row=row, column=col, value=text)
    c.font = Font(name=FONT, size=10, bold=True, color=XL_WHITE)
    c.fill = PatternFill("solid", fgColor=XL_PRIMARY)
    c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    c.border = BORDER
    ws.column_dimensions[get_column_letter(col)].width = width


def body_cell(ws, row: int, col: int, value, fmt=None, align="center", bold=False):
    c = ws.cell(row=row, column=col, value=value)
    c.font = Font(name=FONT, size=10, bold=bold, color=XL_TEXT)
    c.alignment = Alignment(horizontal=align, vertical="center",
                            wrap_text=(align == "left"))
    c.border = BORDER
    if fmt:
        c.number_format = fmt
    return c


wb = Workbook()

# ── Sheet 1 判定表 ────────────────────────────────────────────────────────
ws = wb.active
ws.title = "判定表"
ws.sheet_properties.tabColor = XL_PRIMARY

TITLE_ROW, HEAD_ROW, DATA_ROW = 1, 3, 4
LAST = DATA_ROW + 9          # 第 13 行：十种账本的最后一行
SUM_ROW = LAST + 1

ws.merge_cells(start_row=TITLE_ROW, start_column=1, end_row=TITLE_ROW, end_column=12)
t = ws.cell(row=TITLE_ROW, column=1, value="结局判定表 · 十种账本")
t.font = Font(name=FONT, size=15, bold=True, color=XL_GOLD)
t.alignment = Alignment(horizontal="left", vertical="center")
ws.row_dimensions[TITLE_ROW].height = 30

ws.merge_cells(start_row=TITLE_ROW + 1, start_column=1, end_row=TITLE_ROW + 1, end_column=12)
sub = ws.cell(row=TITLE_ROW + 1, column=1,
              value="十次选门就是十条路：改 B~E 的票数、I 的「最后一次选择」，J~K 会现场重算。"
                    "灰底是公式列，不用手填。")
sub.font = Font(name=FONT, size=9, color=XL_MUTED)
sub.alignment = Alignment(horizontal="left", vertical="center")
ws.row_dimensions[TITLE_ROW + 1].height = 18

HEADERS = [
    ("序号", 6), ("稳（单卡）", 11), ("贪（双卡）", 11), ("战（破甲弹）", 13),
    ("财（金币）", 11), ("合计", 7), ("最大票数", 10), ("并列数", 8),
    ("最后一次选择", 13), ("判定结局", 15), ("门外", 19), ("这条在测什么", 46),
]
for i, (name, width) in enumerate(HEADERS, start=1):
    head_cell(ws, HEAD_ROW, i, name, width)
ws.row_dimensions[HEAD_ROW].height = 32

# 十种账本 = dev/story_check.gd 的 cases 数组，顺序不动（自检与人看的顺序要一致）
CASES = [
    ({"card": 10}, "", "最大票数唯一：十次都拿单卡"),
    ({"card2": 10}, "", "最大票数唯一：十次都拿双卡"),
    ({"breach": 10}, "", "最大票数唯一：十次都拿破甲弹"),
    ({"gold": 10}, "", "最大票数唯一：十次都买金币"),
    ({"card": 3, "card2": 3, "breach": 2, "gold": 2}, "",
     "3/3/2/2：最大票数 3 ≤ 3 → 无主导"),
    ({"card": 4, "card2": 4, "breach": 1, "gold": 1}, "card2",
     "并列 4:4 → 破平看最后一次选的是双卡"),
    ({"card": 4, "card2": 4, "breach": 1, "gold": 1}, "card",
     "同一个账本，最后一次换成单卡就翻到黎明"),
    ({"card2": 5, "gold": 3, "card": 2}, "", "最大票数唯一（5）→ 不看最后一次"),
    ({"breach": 4, "gold": 3, "card": 3}, "gold",
     "最大票数唯一（4）压过最后一次的金币"),
    ({}, "", "空账本：一次都没选，不是杂色而是黎明"),
]

for idx, (trail, last_key, why) in enumerate(CASES):
    r = DATA_ROW + idx
    body_cell(ws, r, 1, idx + 1, "0")
    for col, key in ((2, "card"), (3, "card2"), (4, "breach"), (5, "gold")):
        body_cell(ws, r, col, int(trail.get(key, 0)), "0")
    # 计算列：合计 / 最大票数 / 并列数
    body_cell(ws, r, 6, f"=SUM(B{r}:E{r})", "0")
    body_cell(ws, r, 7, f"=MAX(B{r}:E{r})", "0")
    body_cell(ws, r, 8, f"=COUNTIF(B{r}:E{r},G{r})", "0")
    # 最后一次选择用中文标签，和结算面板上的「稳 2 · 贪 4」同一套字
    lab = {"card": "稳", "card2": "贪", "breach": "战", "gold": "财"}.get(last_key, "—")
    body_cell(ws, r, 9, lab)

    # 判定结局：四条规则的可执行版本，顺序与 Story.resolve_ending() 一致
    tie_pick = (
        f'IF(AND($I{r}="稳",$B{r}=$G{r}),"黎明",'
        f'IF(AND($I{r}="贪",$C{r}=$G{r}),"新的王",'
        f'IF(AND($I{r}="战",$D{r}=$G{r}),"烧掉的路",'
        f'IF(AND($I{r}="财",$E{r}=$G{r}),"买下的门",'
        f'IF($B{r}=$G{r},"黎明",IF($C{r}=$G{r},"新的王",'
        f'IF($D{r}=$G{r},"烧掉的路","买下的门")))))))'
    )
    win_pick = (
        f'IF($B{r}=$G{r},"黎明",IF($C{r}=$G{r},"新的王",'
        f'IF($D{r}=$G{r},"烧掉的路","买下的门")))'
    )
    formula = (
        f'=IF($F{r}=0,"黎明",IF($G{r}<=3,"杂色的清晨",'
        f'IF($H{r}=1,{win_pick},{tie_pick})))'
    )
    body_cell(ws, r, 10, formula, bold=True)
    body_cell(ws, r, 11, f'=IFERROR(VLOOKUP($J{r},结局一览!$B$3:$C$7,2,FALSE),"")', align="left")
    body_cell(ws, r, 12, why, align="left")

# 合计行：只对票数列有意义，其余留空（A 列写标签，不合并——合并会盖住 B~E 的求和）
s = ws.cell(row=SUM_ROW, column=1, value="票数合计")
s.font = Font(name=FONT, size=10, bold=True, color=XL_WHITE)
s.fill = PatternFill("solid", fgColor=XL_DEEP)
s.alignment = Alignment(horizontal="center", vertical="center")
s.border = BORDER
for col in (2, 3, 4, 5):
    c = ws.cell(row=SUM_ROW, column=col, value=f"=SUM({get_column_letter(col)}{DATA_ROW}:{get_column_letter(col)}{LAST})")
    c.font = Font(name=FONT, size=10, bold=True, color=XL_WHITE)
    c.fill = PatternFill("solid", fgColor=XL_DEEP)
    c.alignment = Alignment(horizontal="center", vertical="center")
    c.border = BORDER
    c.number_format = "0"

# 公式列底色：和输入列分开，一眼看出哪里能改
for r in range(DATA_ROW, LAST + 1):
    for col in (6, 7, 8, 10, 11):
        ws.cell(row=r, column=col).fill = PatternFill("solid", fgColor=XL_LIGHT)

# 「杂色的清晨」是唯一的边界情形，标黄底；其余四色不再扩展（克制）
ws.conditional_formatting.add(
    f"J{DATA_ROW}:J{LAST}",
    CellIsRule(operator="equal", formula=['"杂色的清晨"'],
               fill=PatternFill("solid", fgColor=xl_color("#FFEB9C")),
               font=Font(name=FONT, size=10, bold=True, color=xl_color("#9C6500"))),
)

ws.freeze_panes = f"B{DATA_ROW}"
ws.auto_filter.ref = f"A{HEAD_ROW}:L{LAST}"

# ── Sheet 2 结局一览 ──────────────────────────────────────────────────────
es = wb.create_sheet("结局一览")
es.sheet_properties.tabColor = XL_GOLD
es.merge_cells("A1:G1")
et = es.cell(row=1, column=1, value="五个结局")
et.font = Font(name=FONT, size=15, bold=True, color=XL_GOLD)
et.alignment = Alignment(horizontal="left", vertical="center")
es.row_dimensions[1].height = 30

END_HEAD = [("序号", 6), ("结局", 14), ("门外", 18), ("一句由来", 26),
            ("主导门", 12), ("判定条件", 30), ("收尾三行", 76)]
for i, (name, width) in enumerate(END_HEAD, start=1):
    head_cell(es, 2, i, name, width)
es.row_dimensions[2].height = 30

# 与 Story.ENDINGS + ENDING_ORDER 逐字一致
ENDINGS = [
    ("黎明", "西门外 · 黎明", "十个门里，你挑了最稳的那种", "稳（单卡）",
     "最大票数是稳，且票数 > 3",
     "你推开了西门。天在亮，城堡在你背后合上。\n十年里第一次，你看见自己的影子落在地上。\n你逃出来了。这一次没有代价。"),
    ("新的王", "西门外 · 新的王", "每一道门你都拿了双份", "贪（双卡）",
     "最大票数是贪，且票数 > 3",
     "你走出去时走得很慢，身后的椅子认得你了。\n你带走的东西太多，多到它们替你回头看。\n你逃出来了。城堡换了囚徒——它在笑。"),
    ("烧掉的路", "西门外 · 灰烬", "你一路都在往弹上押", "战（破甲弹）",
     "最大票数是战，且票数 > 3",
     "你不是推开门，是把门打穿的。\n身后没有城堡了，也没有路，灰落在肩上像雪。\n你逃出来了。只是没有第二个地方可以逃。"),
    ("买下的门", "西门外 · 金子", "你一路都在买路", "财（金币）",
     "最大票数是财，且票数 > 3",
     "锁是金子敲开的，它自己松了。\n你带出来的箱子比你还重。\n你逃出来了。没有人记得走出来的那个人。"),
    ("杂色的清晨", "西门外 · 杂色", "四样你都试过，一样只拿一点", "无主导",
     "最大票数 ≤ 3（四类分散）",
     "每一扇门你都试过，每样只拿一点。\n你身上没有一样东西是纯粹的。\n你逃出来了。天亮了，颜色很杂，但没有一种是黑的。"),
]
for idx, (name, gate, lead, main_gate, cond, lines) in enumerate(ENDINGS):
    r = 3 + idx
    body_cell(es, r, 1, idx + 1, "0")
    body_cell(es, r, 2, name, bold=True)
    body_cell(es, r, 3, gate, align="left")
    body_cell(es, r, 4, lead, align="left")
    body_cell(es, r, 5, main_gate)
    body_cell(es, r, 6, cond, align="left")
    c = body_cell(es, r, 7, lines, align="left")
    c.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)
    es.row_dimensions[r].height = 46

es.freeze_panes = "A3"

# ── Sheet 3 规则说明 ──────────────────────────────────────────────────────
rs = wb.create_sheet("规则说明")
rs.sheet_properties.tabColor = XL_MUTED
rs.merge_cells("A1:C1")
rt = rs.cell(row=1, column=1, value="判定规则：四条，按顺序判，前面的命中就不往下走")
rt.font = Font(name=FONT, size=15, bold=True, color=XL_GOLD)
rt.alignment = Alignment(horizontal="left", vertical="center")
rs.row_dimensions[1].height = 30

for i, (name, width) in enumerate([("顺序", 7), ("规则", 22), ("说明", 96)], start=1):
    head_cell(rs, 2, i, name, width)
rs.row_dimensions[2].height = 26

RULES = [
    ("0", "空账本 → 黎明", "一次门都没选（合计 = 0）。空账本不能落到「杂色」上：杂色是四样都试过，零样试过是另一回事。"),
    ("1", "最大票数 ≤ 3 → 杂色", "十次分四类，最大票数至少是 3；3/3/2/2 这种分布确实没有偏向，硬挑一个会让玩家觉得「我明明每样都拿了，凭什么算我贪」。"),
    ("2", "最大票数唯一 → 对应结局", "稳→黎明、贪→新的王、战→烧掉的路、财→买下的门。唯一最大时不看最后一次选择。"),
    ("3", "并列 → 最后一次选择破平", "只在并列的那几个里找。玩家认的是「我最后想要的是这个」，不是「表里它排第一」。最后一次也不在并列组里（旧存档或异常），退回固定顺序：稳 → 贪 → 战 → 财。"),
]
for idx, (order, name, why) in enumerate(RULES):
    r = 3 + idx
    body_cell(rs, r, 1, order, "0", bold=True)
    body_cell(rs, r, 2, name, align="left", bold=True)
    body_cell(rs, r, 3, why, align="left")
    rs.row_dimensions[r].height = 40

CONST_ROW = 8
rs.merge_cells(start_row=CONST_ROW, start_column=1, end_row=CONST_ROW, end_column=3)
ct = rs.cell(row=CONST_ROW, column=1, value="常量与代码位置")
ct.font = Font(name=FONT, size=12, bold=True, color=XL_DEEP)
ct.alignment = Alignment(horizontal="left", vertical="center")
rs.row_dimensions[CONST_ROW].height = 26

META = [
    ("MIXED_MAX", "3", "最大票数不超过它就判「无主导」。改这一个数，整张判定表的分界线跟着动。"),
    ("PORTAL_LIMIT", "10", "最多十道门；每次穿门记一笔账，所以账本合计恒为 10。"),
    ("记账", "_gate_trail", "game.gd：{\"card\", \"card2\", \"breach\", \"gold\"} 四个键各记次数；另有 _last_choice。"),
    ("判定", "Story.resolve_ending()", "story.gd。纯函数，输入账本 + 最后一次，输出结局 key。"),
    ("呈现", "Story.ending()", "story.gd：门外名、一句由来、收尾三行、配色都在 ENDINGS 里。"),
    ("自检", "dev/story_check.gd", "本表这十行就是自检里的 cases；改这里记得同步改那边，反之亦然。"),
]
for idx, (key, value, note) in enumerate(META):
    r = CONST_ROW + 1 + idx
    body_cell(rs, r, 1, key, align="left")
    body_cell(rs, r, 2, value, align="left")
    body_cell(rs, r, 3, note, align="left")
    rs.row_dimensions[r].height = 30

import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "结局判定表-十种账本.xlsx")
wb.properties.title = "结局判定表 · 十种账本"
wb.save(OUT)
print("saved:", OUT)
