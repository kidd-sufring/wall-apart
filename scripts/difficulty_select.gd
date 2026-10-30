extends Control

# 单人难度选择：简单（AI 不躲避）/ 普通（沿用现有几率）/ 困难（100% 躲避）。
# 选定后进入角色选择；在角色选择界面点返回会回到这里重新选难度。

@export var button_hover_scale := 1.06   # 悬停时的放大倍率
@export var button_hover_time := 0.12    # 放大/还原动画时长（秒）

@onready var easy_button: Button = $Content/VBox/MenuButtons/EasyButton
@onready var normal_button: Button = $Content/VBox/MenuButtons/NormalButton
@onready var hard_button: Button = $Content/VBox/MenuButtons/HardButton
@onready var back_button: Button = $BackButton
@onready var desc_label: Label = $Content/VBox/Desc

var _button_tweens: Dictionary = {}
var _buttons: Array[Button] = []


func _ready() -> void:
	GameManager.enter_menu_state()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	_buttons = [easy_button, normal_button, hard_button]
	for button in [easy_button, normal_button, hard_button, back_button] as Array[Button]:
		button.mouse_entered.connect(_on_button_hover.bind(true, button))
		button.mouse_exited.connect(_on_button_hover.bind(false, button))
	for i in range(_buttons.size()):
		_buttons[i].mouse_entered.connect(_on_difficulty_hover.bind(i))
		_buttons[i].mouse_exited.connect(_on_difficulty_hover.bind(-1))
		_buttons[i].pressed.connect(_on_difficulty_pressed.bind(i))
	back_button.pressed.connect(_on_back_pressed)

	_refresh_desc()
	UiSound.bind(self)
	AudioManager.play_bgm(&"loading", -6.0)


func _on_difficulty_pressed(value: int) -> void:
	GameManager.difficulty = value
	GameManager.goto_character_select()


func _on_back_pressed() -> void:
	GameManager.enter_menu_state()
	SceneTransition.change_scene("res://scenes/main_menu.tscn")


# 悬停某个难度时在下方显示它的效果说明，移开后回到当前已选难度
func _on_difficulty_hover(index: int) -> void:
	_refresh_desc(GameManager.difficulty if index < 0 else index)


func _refresh_desc(value: int = -1) -> void:
	var target := GameManager.difficulty if value < 0 else value
	desc_label.text = "%s：%s" % [
		GameManager.get_difficulty_name(target),
		GameManager.get_difficulty_description(target),
	]


# ---------- 通用 ----------

# 悬停放大/离开还原：以按钮中心为轴缩放，不影响容器布局
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
