extends SceneTree

## 验证两件事：
##  1) extends SceneTree 的脚本里 _physics_process 会不会被引擎调用
##  2) --fixed-fps 下 idle 帧与物理帧是否严格 1:1
## 如果 physics 帧数明显多于 idle 帧，说明主循环会"补跑"物理 tick，
## 那么挂在 _process 上的 bot 输入注入就会与游戏逻辑脱节。

var _idle: int = 0
var _phys: int = 0

func _process(_delta: float) -> bool:
	_idle += 1
	if _idle >= 600:
		print("idle=%d phys=%d 比值=%.4f" % [_idle, _phys, float(_phys) / float(_idle)])
		quit()
		return true
	return false

func _physics_process(_delta: float) -> bool:
	_phys += 1
	return false
