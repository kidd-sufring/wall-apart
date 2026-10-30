class_name UiSound
extends RefCounted

# 界面音效统一绑定：给一个界面根节点下的所有按钮挂上悬停与点击音效。
# 各界面在 _ready() 里调用 UiSound.bind(self) 即可，无需逐个按钮手写。
# 已绑定过的按钮会打 meta 标记，重复调用不会叠加播放。
#
# 点击音分两类：
#   正向（进入 / 打开 / 开始 / 确认）→ click1
#   反向（返回 / 关闭 / 取消 / 离开）→ heavy_closeclick

const HOVER_VOLUME_DB := -9.0    # 悬停音（很轻，避免频繁划过时吵）
const CLICK_VOLUME_DB := -6.0    # 正向操作
const BACK_VOLUME_DB := -3.0     # 反向操作，用更厚重的关闭音

# 按钮名包含这些关键字时视为「反向操作」
const BACK_KEYWORDS := [
	"back", "close", "cancel", "menu", "leave", "exit", "quit", "return",
]

const BOUND_META := &"ui_sound_bound"
const FORCED_KEY_META := &"ui_click_sound"


# overrides：{按钮节点: 音效逻辑名}，用于给个别按钮强制指定点击音，
# 例如技能介绍页的「选择此角色」必须走正向音 click。
static func bind(root: Node, overrides: Dictionary = {}) -> void:
	if root == null:
		return
	for node in root.find_children("*", "BaseButton", true, false):
		var button := node as BaseButton
		if button == null or button.has_meta(BOUND_META):
			continue
		button.set_meta(BOUND_META, true)
		if overrides.has(button):
			button.set_meta(FORCED_KEY_META, overrides[button])
		button.mouse_entered.connect(UiSound._on_hover.bind(button))
		button.pressed.connect(UiSound._on_pressed.bind(button))


static func _on_hover(button: BaseButton) -> void:
	if not is_instance_valid(button) or button.disabled:
		return
	AudioManager.play_2d(&"hover", HOVER_VOLUME_DB, randf_range(0.97, 1.03))


static func _on_pressed(button: BaseButton) -> void:
	if not is_instance_valid(button):
		return

	var forced: StringName = button.get_meta(FORCED_KEY_META, &"")
	if forced != &"":
		var is_back_key := forced == &"click_heavy"
		AudioManager.play_2d(forced, BACK_VOLUME_DB if is_back_key else CLICK_VOLUME_DB,
			randf_range(0.98, 1.02))
		return

	var is_back := _is_back_button(button)
	AudioManager.play_2d(
		&"click_heavy" if is_back else &"click",
		BACK_VOLUME_DB if is_back else CLICK_VOLUME_DB,
		randf_range(0.98, 1.02)
	)


static func _is_back_button(button: BaseButton) -> bool:
	var node_name := String(button.name).to_lower()
	for keyword in BACK_KEYWORDS:
		if node_name.contains(keyword):
			return true
	return false
