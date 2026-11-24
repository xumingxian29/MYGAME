class_name EnemyGrid
extends RefCounted

## 均匀网格，只服务一件事：让敌人能在 O(1) 里找到身边的一小撮同类，用来做分离。
## 每物理帧由 Game 重建（Game 是 World 的父节点，重建总在所有敌人移动之前完成）。
##
## 为什么不用两两比较：125 只敌人两两比较是 1.5 万次距离计算，420 只是 17 万次，
## 全部挤在一个物理帧里会明显掉帧。查 3x3 格只碰得到真正可能重叠的那几只。
##
## 这里不做命中判定，职责单一：只管"谁在我附近"。

## 格子边长。取略大于两个普通怪的直径（10 x 2 x 2 = 40），保证 3x3 邻域一定覆盖
## 所有可能重叠的敌人；精英半径 17 时 3x3 也够（48 > 17 x 2）。
const CELL_SIZE: float = 48.0

## 查不到格子时返回的共享空数组。用 get(key, NONE) 而不是 get(key, [])，
## 否则每次落空都要新建一个数组，每帧光这里就是上千次分配。
const NONE: Array = []

var _cells: Dictionary = {}


func clear() -> void:
	_cells.clear()


func insert(enemy: Enemy) -> void:
	var key: Vector2i = cell_of(enemy.global_position)
	if _cells.has(key):
		_cells[key].append(enemy)
	else:
		_cells[key] = [enemy]


func cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CELL_SIZE), floori(pos.y / CELL_SIZE))


## 把 pos 周围 3x3 格里的敌人追加进 out。out 由调用方复用（先 clear 再传进来），
## 这样每帧零分配。
func query(pos: Vector2, out: Array) -> void:
	var base: Vector2i = cell_of(pos)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var bucket: Array = _cells.get(base + Vector2i(dx, dy), NONE)
			if not bucket.is_empty():
				out.append_array(bucket)
