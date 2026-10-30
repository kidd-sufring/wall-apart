extends CanvasLayer

# 全局界面切换：上一个界面渐渐变黑 → 切换界面 → 新界面渐渐浮现。
# 所有界面（场景切换、技能介绍、结算弹窗）都走这里的同一套时长与曲线，保证观感一致。

const FADE_OUT_TIME := 0.25   # 渐黑时长（秒）
const FADE_IN_TIME := 0.3     # 渐亮时长（秒）

var _rect: ColorRect
var _busy := false


func _ready() -> void:
	layer = 200
	process_mode = Node.PROCESS_MODE_ALWAYS

	_rect = ColorRect.new()
	_rect.color = Color(0, 0, 0, 1)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)
	# 必须同时设置锚点与偏移，否则 ColorRect 保持 0×0，遮罩不可见
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.modulate.a = 1.0

	# 首屏淡入
	fade_in(0.35)


# 渐黑：遮罩盖住旧界面，并在此期间吞掉鼠标输入
func fade_out(time: float = FADE_OUT_TIME) -> void:
	_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	var tween := create_tween()
	tween.tween_property(_rect, "modulate:a", 1.0, time)
	await tween.finished


# 渐亮：露出新界面并恢复输入
func fade_in(time: float = FADE_IN_TIME) -> void:
	var tween := create_tween()
	tween.tween_property(_rect, "modulate:a", 0.0, time)
	await tween.finished
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE


# 场景切换：渐黑 → 换场景 → 渐亮
func change_scene(path: String) -> void:
	if _busy:
		return
	_busy = true
	get_tree().paused = false

	await fade_out()

	get_tree().change_scene_to_file(path)
	# 等新场景进入场景树
	await get_tree().process_frame
	await get_tree().process_frame

	await fade_in()

	_busy = false
