extends SceneTree

## 一次性取证脚本：确认"实例 id 会被回收"，这是 spawn_serial 存在的前提。
## 如果 id 从不回收，用 instance_id 当键本来是安全的，那套改动就白做了。
##
## 用法：godot --headless --path . --script res://dev/id_recycle_probe.gd
func _initialize() -> void:
	# 规模要够大：8 个看不出复用，几千个才接近一局里"生灭几万次"的实际情况
	const N: int = 4000
	var first: Array[int] = []
	for i in range(N):
		var n := Node.new()
		first.append(n.get_instance_id())
		n.free()   # 立即释放，让 id 回到池里
	var second: Array[int] = []
	for i in range(N):
		var n := Node.new()
		second.append(n.get_instance_id())
		n.free()
	print("第一批 id 区间：%d ~ %d" % [first.min(), first.max()])
	print("第二批 id 区间：%d ~ %d" % [second.min(), second.max()])

	var pool: Dictionary = {}
	for id in first:
		pool[id] = true
	var reused: int = 0
	for id in second:
		if pool.has(id):
			reused += 1
	print("复用个数：%d / %d" % [reused, second.size()])
	if reused > 0:
		print("结论：instance id 会被回收 → 用 id 当'这一只怪'的身份不安全")
	else:
		print("结论：本例未见复用（不足以证明安全，池可能在更大规模下才复用）")
	quit()
