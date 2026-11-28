class_name StatCurve
extends RefCounted

## 属性加成的饱和曲线。所有"能一直往上叠"的属性都走这里。
##
## 为什么需要它：卡池里的加成全是乘算，一张传说卡就是 ×4.2，十几张之后
## 伤害能到几十倍——后期不是"打得动"，是"怪还没看清就没了"；
## 而改成线性封顶又会变成"前几张卡白拿"，因为玩家最需要立刻有感的是第一张。
##
## 这条曲线同时满足三件事：
##   1. 起点斜率 = 1：第一张 +22% 的卡，实际就给 22%（几乎不打折）。
##   2. 永远到不了 CAP：raw 无限大时只逼近 +200%，也就是 3 倍基础值。
##   3. 后段递减：raw 从 0 叠到 2 就拿到 2 倍，从 2 再叠到 6 只多 0.5 倍。
##
## 用有理函数而不是 exp：exp 在 raw=0 附近的值只能用浮点近似，
## 两张卡之后就开始和"写了 +22% 却只给 +19%"对不上，玩家会先怀疑 UI 出错。
const CAP: float = 3.0


static func mult(raw: float) -> float:
	if raw <= 0.0:
		return 1.0
	var room: float = CAP - 1.0
	return 1.0 + room * raw / (raw + room)


## 反解：想让最终倍数正好是 m，需要多少 raw。自检用它钉边界。
static func raw_for(m: float) -> float:
	var room: float = CAP - 1.0
	var gain: float = clampf(m, 1.0, CAP - 0.001) - 1.0
	if gain <= 0.0:
		return 0.0
	return room * gain / (room - gain)
