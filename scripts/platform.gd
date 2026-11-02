extends Node

# 平台适配层（Autoload：Platform）
# 区分桌面 / 浏览器 / 触屏环境，统一鼠标锁定行为与联机入口的可用性。

var is_web := false
var is_touch := false
var force_touch_demo := false          # 调试：浏览器加 ?touch=1 时用鼠标模拟触屏操作

# 触屏层积累的视角/仰角增量，由相机与角色在本帧消费
var _touch_look := Vector2.ZERO
var _touch_elevation := 0.0

func _ready() -> void:
	is_web = OS.has_feature("web")
	var web_touch := false
	if is_web:
		# 桌面浏览器调试触屏布局：用鼠标模拟触点，方便验收
		var demo = JavaScriptBridge.eval("location.search.indexOf('touch=1') >= 0")
		force_touch_demo = bool(demo)
		# 部分浏览器的 is_touchscreen_available 不可靠，直接查触点数与触摸事件支持
		web_touch = bool(JavaScriptBridge.eval(
			"(navigator.maxTouchPoints || 0) > 0 || 'ontouchstart' in window"))
	# 桌面端验收用：设置 WALLAPART_TOUCH=1 可强制走触屏布局
	if OS.has_environment("WALLAPART_TOUCH"):
		force_touch_demo = true
	# 原生移动端固定为触屏；Web 端按设备能力判断
	is_touch = OS.has_feature("mobile") or force_touch_demo or web_touch
	if is_touch:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

# 进入/退出“鼠标锁定”：触屏环境永不锁定，视角交给触屏层处理
func set_capture(captured: bool) -> void:
	if is_touch:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

# 当前是否处于可旋转视角的鼠标锁定状态
func is_captured() -> bool:
	if is_touch:
		return false
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

# 联机只保留桌面端：Web 构建加载不了 ENet 原生网络
func supports_multiplayer() -> bool:
	return not is_web


# ---------- 触屏输入中转 ----------

func push_touch_look(relative: Vector2) -> void:
	_touch_look += relative


func consume_touch_look() -> Vector2:
	var value := _touch_look
	_touch_look = Vector2.ZERO
	return value


func push_touch_elevation(delta_deg: float) -> void:
	_touch_elevation += delta_deg


func consume_touch_elevation() -> float:
	var value := _touch_elevation
	_touch_elevation = 0.0
	return value
