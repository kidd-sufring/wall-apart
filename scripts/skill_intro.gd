extends CanvasLayer

# 技能介绍界面：全屏覆盖在角色选择之上，按角色切换插画与文案。
# 关闭 / 返回回到角色选择；「选择此角色」直接开局。

const HUNTER_EFFECT := "进入持续3s的幽灵状态，\n可以穿越墙体和躲避道具"
const SURVIVOR_EFFECT := "获得持续0.5s的护盾，\n可以击退近身的追捕者10m"

# 点击「选择此角色」：由宿主界面决定是开局还是向主机申请锁定角色
signal pick_confirmed(role: StringName)

@export var button_hover_scale := 1.06   # 悬停时的放大倍率
@export var button_hover_time := 0.12    # 放大/还原动画时长（秒）

var _hunter_art: Texture2D = preload("res://ui/skill_hunter.png")
var _survivor_art: Texture2D = preload("res://ui/skill_survivor.png")

@onready var root: Control = $Root
@onready var art: TextureRect = $Root/Center/Window/Content/Row/Left/Art
@onready var skill_name: Label = $Root/Center/Window/Content/Row/Left/SkillName
@onready var tag_label: Label = $Root/Center/Window/Content/Row/Right/Tag
@onready var cooldown_label: Label = $Root/Center/Window/Content/Row/Right/Cooldown
@onready var effect_label: Label = $Root/Center/Window/Content/Row/Right/Effects/Effect1
@onready var back_button: Button = $Root/BackButton
@onready var close_button: TextureButton = $Root/Center/Window/Close
@onready var pick_button: Button = $Root/Center/Window/Content/Row/Right/PickButton

var _role: StringName = &""
var _button_tweens: Dictionary = {}


func _ready() -> void:
	root.visible = false

	for button in [back_button, close_button, pick_button] as Array[Control]:
		button.mouse_entered.connect(_on_button_hover.bind(true, button))
		button.mouse_exited.connect(_on_button_hover.bind(false, button))

	# 「选择此角色」是正向确认按钮，显式指定用普通点击音
	UiSound.bind(self, {pick_button: &"click"})


# 打开并填入对应角色的技能内容
func open(role: StringName) -> void:
	_role = role
	var is_hunter := role == GameManager.ROLE_HUNTER

	art.texture = _hunter_art if is_hunter else _survivor_art
	skill_name.text = "幽灵状态" if is_hunter else "泡泡护盾"
	tag_label.text = "主动 · 位移" if is_hunter else "主动 · 防御"
	cooldown_label.text = "冷却 10 秒" if is_hunter else "冷却 8 秒"

	effect_label.text = HUNTER_EFFECT if is_hunter else SURVIVOR_EFFECT

	Platform.set_capture(false)
	# 面板翻开的声音
	AudioManager.play_2d(&"page", -6.0, randf_range(0.98, 1.02))

	# 与其他界面统一的切换效果：先渐黑，再浮现技能介绍
	await SceneTransition.fade_out()
	root.visible = true
	root.modulate.a = 1.0
	await SceneTransition.fade_in()


func close() -> void:
	if not root.visible:
		return
	AudioManager.play_2d(&"page", -8.0, randf_range(0.95, 0.99))
	await SceneTransition.fade_out()
	root.visible = false
	await SceneTransition.fade_in()


func is_open() -> bool:
	return root.visible


func _on_back_pressed() -> void:
	close()


func _on_pick_pressed() -> void:
	if _role == &"":
		return
	pick_confirmed.emit(_role)


# 悬停放大/离开还原：以按钮中心为轴缩放
func _on_button_hover(entered: bool, button: Control) -> void:
	if not is_instance_valid(button):
		return

	button.pivot_offset = button.size * 0.5

	var tween: Tween = _button_tweens.get(button)
	if tween != null and tween.is_valid():
		tween.kill()

	tween = create_tween()
	_button_tweens[button] = tween
	var target := Vector2.ONE * (button_hover_scale if entered else 1.0)
	tween.tween_property(button, "scale", target, button_hover_time) \
		.set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
