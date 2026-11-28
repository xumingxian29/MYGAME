extends SceneTree

## 金币 + 商人自检。
## 用法：godot --headless --path . --fixed-fps 60 --script res://dev/shop_check.gd
##
## 覆盖五件事：
##   1. 击杀给金币：普通 6 / 精英 24 / Boss 120，且随层数上涨
##   2. 走近商人 → SHOP 态 + 面板打开 + 整棵树暂停
##   3. 金币不足：直接调购买会被拒绝，一分钱不扣、货还在
##   4. 金币充足：扣钱、发货、售罄；同一件不能买第二次
##   5. 关店 / 换图：状态复位、商店库存重置、商人进入"先走开"
##
## 回血商品放开买：它是这一版里"回血只能靠脱战和商人"这两个出口之一，
## 删掉升级回血之后，这条路径必须有一条断言钉住。

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	await _run()
	print("\n==== %d 通过 / %d 失败 ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   ", label)
	else:
		_fail += 1
		print("  FAIL ", label, "  ", detail)


func _run() -> void:
	var packed: PackedScene = load("res://MY主场景.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await process_frame
	game._on_menu_started("探针", HeroClass.WARRIOR)
	game.story_enabled = false
	if game.story_panel != null and game.story_panel.is_open():
		game.story_panel.skip()
	await process_frame

	print("\n[击杀给金币]")
	game._gold = 0
	game._create_enemy(Enemy.Kind.GRUNT, false, game.player.global_position + Vector2(500.0, 0.0))
	var grunt: Enemy = game._enemies[game._enemies.size() - 1]
	_check("普通怪值 6 金", game._coin_reward(grunt) == 6, "%d" % game._coin_reward(grunt))
	game._create_enemy(Enemy.Kind.GRUNT, true, game.player.global_position + Vector2(520.0, 0.0))
	var elite: Enemy = game._enemies[game._enemies.size() - 1]
	_check("精英值 24 金", game._coin_reward(elite) == 24, "%d" % game._coin_reward(elite))
	game._create_enemy(Enemy.Kind.CHARGER, false, game.player.global_position + Vector2(540.0, 0.0))
	var charger: Enemy = game._enemies[game._enemies.size() - 1]
	_check("冲锋者也值 9 金", game._coin_reward(charger) == 9, "%d" % game._coin_reward(charger))
	# 走真实死亡路径，验金币真的进账
	var gold_before: int = game._gold
	game._on_enemy_died(grunt, 4)
	_check("击杀真的加钱", game._gold == gold_before + 6, "%d → %d" % [gold_before, game._gold])
	for e in game._enemies:
		if is_instance_valid(e):
			e.queue_free()
	game._enemies.clear()
	await process_frame

	print("\n[商人存在与可达]")
	_check("开局就有商人", is_instance_valid(game._merchant))
	_check("商人站在可走格", game.maze.has_floor_at(game._merchant.global_position))
	_check("商人不在起点房间（要专门跑一趟）",
		game._merchant.global_position.distance_to(game.maze.start_pos()) > 96.0,
		"%.1f" % game._merchant.global_position.distance_to(game.maze.start_pos()))

	print("\n[金币不足：买不了]")
	game._gold = 10
	game._state = game.State.PLAYING
	game._on_merchant_request(game._merchant)
	_check("进入 SHOP 态", game._state == game.State.SHOP, "state=%d" % game._state)
	_check("商店面板已开", game.hud._panel.visible == true)
	_check("整棵树已暂停", paused == true)
	var item_count: int = game._shop_stock.size()
	_check("货架 3 件", item_count == 3, "%d" % item_count)
	game._on_shop_buy(0)
	_check("钱不够时买不动", game._gold == 10, "%d" % game._gold)
	_check("钱不够时货没被标记售罄", bool(game._shop_stock[0]["bought"]) == false)

	print("\n[回血：扣钱 + 发货 + 售罄]")
	# 价格 ×10 之后，一次购买要 1600 金；测试直接给够。
	game._gold = 5000
	game.player.health = game.player.max_health * 0.3
	var hp_at: float = game.player.health
	game._on_shop_buy(0)
	_check("第 1 图扣 1600 金", game._gold == 3400, "%d" % game._gold)
	# 前三关固定 5% 最大生命（买之前血池 180 → 回 9 点）
	var want_heal: float = game.player.max_health * 0.05
	_check("前三关只回 5%%（%.1f 点）" % want_heal,
		is_equal_approx(game.player.health, hp_at + want_heal),
		"%.1f → %.1f" % [hp_at, game.player.health])
	_check("回血已售罄", bool(game._shop_stock[0]["bought"]) == true)
	var gold_after: int = game._gold
	game._on_shop_buy(0)
	_check("同一件买不了第二次", game._gold == gold_after, "%d" % game._gold)

	print("\n[破甲弹与卡牌]")
	var breach_at: int = game._breach
	game._on_shop_buy(1)
	_check("破甲弹 +3", game._breach == breach_at + 3, "%d → %d" % [breach_at, game._breach])
	_check("破甲弹扣 600 金", game._gold == 2800, "%d" % game._gold)

	print("\n[关店]")
	game._close_shop()
	await process_frame
	_check("关店后回到 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)
	_check("关店后已解冻", paused == false)
	_check("面板已收", game.hud._panel.visible == false)
	_check("商人进入『先走开』", game._merchant.is_pending() == false)

	print("\n[买卡：关店后直接进选卡]")
	game._on_merchant_request(game._merchant)
	_check("再次开店", game._state == game.State.SHOP, "state=%d" % game._state)
	var cards_at: int = game._pending_cards
	game._on_shop_buy(2)
	_check("卡牌 +1", game._pending_cards == cards_at + 1,
		"%d → %d" % [cards_at, game._pending_cards])
	game._close_shop()
	await process_frame
	_check("关店后直接弹出选卡", game._state == game.State.LEVEL_UP, "state=%d" % game._state)
	# 清掉选卡，回到主循环
	game._choose(0)
	await process_frame
	game._pending_cards = 0
	game._card_delay = 0.0
	_check("选完卡回到 PLAYING", game._state == game.State.PLAYING, "state=%d" % game._state)

	print("\n[换图后商店重置]")
	game._gold = 777
	var old_merchant_id: int = game._merchant.get_instance_id()
	game._awaiting_portal = true
	game._rebuild_map()
	await process_frame
	_check("新图有新商人", is_instance_valid(game._merchant)
		and game._merchant.get_instance_id() != old_merchant_id)
	_check("旧商人已释放", not is_instance_valid(instance_from_id(old_merchant_id)))
	_check("金币跨图保留", game._gold == 777, "%d" % game._gold)
	var fresh_all: bool = true
	for item in game._shop_stock:
		if bool(item["bought"]):
			fresh_all = false
	_check("新图货架全部重置", fresh_all)

	print("\n[价格随层数上涨 + 后期固定回血]")
	# 第 1 图：基准价 1600
	game._floor = 0
	game._floor_power = 0.0
	game._shop_stock_reset()
	_check("第 1 图药价 1600", int(game._shop_stock[0]["price"]) == 1600,
		"%d" % int(game._shop_stock[0]["price"]))
	# 第 4 图（_floor = 3）：1600 × (1 + 0.45×3) = 3760
	game._floor = 3
	game._shop_stock_reset()
	var want_price: int = int(round(1600.0 * (1.0 + 0.45 * 3.0)))
	_check("第 4 图药价涨到 %d" % want_price,
		int(game._shop_stock[0]["price"]) == want_price,
		"%d" % int(game._shop_stock[0]["price"]))
	_check("药价严格高于第 1 图", int(game._shop_stock[0]["price"]) > 1600)

	# 回血量：前三关 5%，第 4 关起固定 100
	game._floor = 2
	_check("第 3 图仍是 5%%（%.1f 点）" % (game.player.max_health * 0.05),
		is_equal_approx(game._shop_heal_amount(), game.player.max_health * 0.05),
		"%.1f" % game._shop_heal_amount())
	game._floor = 3
	_check("第 4 图起固定 100 点",
		is_equal_approx(game._shop_heal_amount(), 100.0),
		"%.1f" % game._shop_heal_amount())
	_check("第 4 图的面板文案写 100", game._shop_heal_text().contains("100"),
		"「%s」" % game._shop_heal_text())
	game._floor = 0
	game._shop_stock_reset()
