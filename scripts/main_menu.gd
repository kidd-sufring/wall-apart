extends Control

# 主菜单：单人模式进入难度选择；局域网联机进入独立的大厅场景。
# 右下角的齿轮按钮打开设置面板，可调节音乐与音效音量。

@export var button_hover_scale := 1.06   # 悬停时的放大倍率
@export var button_hover_time := 0.12    # 放大/还原动画时长（秒）

@onready var single_button: Button = $Content/VBox/MenuButtons/SingleButton
@onready var lan_button: Button = $Content/VBox/MenuButtons/LanButton
@onready var settings_button: TextureButton = $SettingsButton
@onready var settings_popup: Control = $SettingsPopup
@onready var settings_close: Button = $SettingsPopup/Center/Window/VBox/CloseButton
@onready var settings_x: TextureButton = $SettingsPopup/Center/Window/Close
@onready var music_slider: HSlider = $SettingsPopup/Center/Window/VBox/MusicRow/MusicSlider
@onready var music_value: Label = $SettingsPopup/Center/Window/VBox/MusicRow/MusicValue
@onready var sfx_slider: HSlider = $SettingsPopup/Center/Window/VBox/SfxRow/SfxSlider
@onready var sfx_value: Label = $SettingsPopup/Center/Window/VBox/SfxRow/SfxValue

var _button_tweens: Dictionary = {}


func _ready() -> void:
	# 回到主菜单时清理残留的联机状态
	if NetworkManager.is_online():
		NetworkManager.leave_room()

	GameManager.enter_menu_state()
	Platform.set_capture(false)
	# Web 版只提供单机玩法，隐藏局域网联机入口
	lan_button.visible = Platform.supports_multiplayer()

	for button in [single_button, lan_button, settings_button, settings_x, settings_close] as Array[Control]:
		button.mouse_entered.connect(_on_button_hover.bind(true, button))
		button.mouse_exited.connect(_on_button_hover.bind(false, button))

	settings_popup.visible = false
	settings_button.pressed.connect(_open_settings)
	settings_close.pressed.connect(_close_settings)
	settings_x.pressed.connect(_close_settings)
	music_slider.value_changed.connect(_on_music_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	sfx_slider.drag_ended.connect(_on_sfx_drag_ended)
	_sync_volume_controls()

	UiSound.bind(self)
	# 主菜单背景音乐（与加载界面共用一段循环氛围音）
	AudioManager.play_bgm(&"loading", -6.0)


func _on_single_pressed() -> void:
	GameManager.goto_difficulty_select()


func _on_lan_pressed() -> void:
	SceneTransition.change_scene("res://scenes/lan_lobby.tscn")


# 新手教程：先进角色选择（只开放逃生者），确认后进入教程场景
func _on_tutorial_pressed() -> void:
	GameManager.goto_tutorial_select()


# ---------- 设置 ----------

func _open_settings() -> void:
	_sync_volume_controls()
	settings_popup.visible = true


func _close_settings() -> void:
	settings_popup.visible = false


# Esc 关闭设置面板（只在面板打开时拦截）
func _unhandled_input(event: InputEvent) -> void:
	if not settings_popup.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		_close_settings()
		get_viewport().set_input_as_handled()


# 把 AudioManager 里保存的音量同步到滑条与百分比文字
func _sync_volume_controls() -> void:
	music_slider.set_value_no_signal(AudioManager.get_music_volume_percent())
	sfx_slider.set_value_no_signal(AudioManager.get_sfx_volume_percent())
	music_value.text = "%d%%" % AudioManager.get_music_volume_percent()
	sfx_value.text = "%d%%" % AudioManager.get_sfx_volume_percent()


func _on_music_volume_changed(value: float) -> void:
	AudioManager.set_music_volume(value / 100.0)
	music_value.text = "%d%%" % int(value)


func _on_sfx_volume_changed(value: float) -> void:
	AudioManager.set_sfx_volume(value / 100.0)
	sfx_value.text = "%d%%" % int(value)


# 松开滑条时播放一次点击音，方便试听当前音效音量
func _on_sfx_drag_ended(value_changed: bool) -> void:
	if value_changed:
		AudioManager.play_2d(&"click", -6.0)


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
