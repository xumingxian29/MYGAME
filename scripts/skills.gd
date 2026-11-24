class_name HeroSkill
extends RefCounted

## 三个职业的主动技能。独立成文件而不是塞进 Player：
## 技能是"一次性爆发 + 视觉反馈"，与移动 / 受伤 / 武器装配没有共享状态，
## 放一起只会让 Player 越来越难读懂。

const WHIRL_RADIUS: float = 150.0
const WHIRL_DAMAGE: float = 58.0
const WHIRL_INVULN: float = 1.2
const WHIRL_KNOCKBACK: float = 54.0

const NOVA_RADIUS: float = 285.0
const NOVA_DAMAGE: float = 74.0
const NOVA_SLOW_TIME: float = 2.5
const NOVA_SLOW_FACTOR: float = 0.45

const ARROW_COUNT: int = 14
const ARROW_DAMAGE_SCALE: float = 2.2
const ARROW_PIERCE: int = 3


static func cast(hero: int, player: Player, enemies: Array[Enemy]) -> void:
	match hero:
		HeroClass.WARRIOR:
			_whirlwind(player, enemies)
		HeroClass.MAGE:
			_nova(player, enemies)
		HeroClass.RANGER:
			_arrow_rain(player)


## 战士：以自身为中心的瞬发斩击 + 击退 + 短暂无敌。
## 战士被围住时是唯一能"主动脱身"的手段，所以无敌时间是技能的一部分，不只是伤害。
static func _whirlwind(player: Player, enemies: Array[Enemy]) -> void:
	player.grant_invuln(WHIRL_INVULN)
	player.spawn_skill_fx(WHIRL_RADIUS, Color(1.0, 0.6, 0.35))
	player.add_trauma(0.5)

	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var offset: Vector2 = enemy.global_position - player.global_position
		var dist: float = offset.length()
		if dist > WHIRL_RADIUS + enemy.radius:
			continue
		enemy.take_damage(WHIRL_DAMAGE)
		enemy.apply_slow(0.5, 0.6)
		if dist > 0.01:
			enemy.global_position += offset / dist * WHIRL_KNOCKBACK


## 法师：大范围爆伤 + 减速。范围大到能清掉贴脸的一圈，但冷却最久（回蓝最慢）。
static func _nova(player: Player, enemies: Array[Enemy]) -> void:
	player.spawn_skill_fx(NOVA_RADIUS, Color(0.72, 0.5, 1.0))
	player.add_trauma(0.45)

	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		if enemy.global_position.distance_to(player.global_position) > NOVA_RADIUS + enemy.radius:
			continue
		enemy.take_damage(NOVA_DAMAGE)
		enemy.apply_slow(NOVA_SLOW_TIME, NOVA_SLOW_FACTOR)


## 射手：全向齐射。借用子弹武器的弹道系统，不另写一套飞行逻辑，
## 这样穿透、命中判定、火花反馈的规则与普攻完全一致。
static func _arrow_rain(player: Player) -> void:
	player.spawn_skill_fx(90.0, Color(0.45, 0.95, 0.7))
	player.add_trauma(0.35)
	if player.bullet_weapon != null:
		player.bullet_weapon.fire_ring(ARROW_COUNT, ARROW_DAMAGE_SCALE, ARROW_PIERCE)
