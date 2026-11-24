class_name Score
extends RefCounted

## 综合评分：击杀（按敌人等级分档）+ 存活时间 + 成长（等级/累计经验）三块加权。
## 想调平衡只改这里的常量，公式与展示都依赖它们。

## 普通小怪每只
const KILL_NORMAL: int = 10
## 精英大怪每只（血量 ×3.2、经验 ×3，给 4.5 倍分）
const KILL_ELITE: int = 45
## 每存活 1 秒
const PER_SECOND: int = 8
## 每升 1 级（从 2 级起算）
const PER_LEVEL: int = 120
## 每点累计经验
const PER_XP: int = 2
## 通关奖励。三章走完 + 三只章节 Boss，大约值 250 次击杀或 300 秒存活，
## 所以给一个"能看出来、但不至于让没通关的人白玩"的量级：
## 通关局的总分通常在 8000~15000，2500 是明显的加成而不是决定性差距。
const CLEAR_BONUS: int = 2500


## 单项拆解，供结算面板逐行展示。
static func compute(kills: int, elite_kills: int, elapsed: float, level: int, xp_total: int, cleared: bool = false) -> Dictionary:
	var elites: int = clampi(elite_kills, 0, kills)
	var normal: int = maxi(kills - elites, 0)
	var kill_points: int = normal * KILL_NORMAL + elites * KILL_ELITE
	var time_points: int = int(elapsed) * PER_SECOND
	var growth_points: int = maxi(level - 1, 0) * PER_LEVEL + maxi(xp_total, 0) * PER_XP
	var clear_points: int = CLEAR_BONUS if cleared else 0
	return {
		"total": kill_points + time_points + growth_points + clear_points,
		"kill_points": kill_points,
		"time_points": time_points,
		"growth_points": growth_points,
		"clear_points": clear_points,
		"normal_kills": normal,
		"elite_kills": elites,
	}


## 只要总分时用这个，避免每帧构造字典
static func total(kills: int, elite_kills: int, elapsed: float, level: int, xp_total: int, cleared: bool = false) -> int:
	var elites: int = clampi(elite_kills, 0, kills)
	return (maxi(kills - elites, 0) * KILL_NORMAL
		+ elites * KILL_ELITE
		+ int(elapsed) * PER_SECOND
		+ maxi(level - 1, 0) * PER_LEVEL
		+ maxi(xp_total, 0) * PER_XP
		+ (CLEAR_BONUS if cleared else 0))
