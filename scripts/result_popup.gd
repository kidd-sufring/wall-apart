extends CanvasLayer

# 结算弹窗：按玩家所选角色把比赛结果翻译成「胜利 / 失败」。
# 同时展示剩余时间与逃生者剩余生命；节点为 PROCESS_MODE_ALWAYS，暂停时仍可交互。

@export var button_hover_scale := 1.06   # 悬停时的放大倍率
@export var button_hover_time := 0.12    # 放大/还原动画时长（秒）

var _hp_full: Texture2D = preload("res://ui/hp_100.png")
var _hp_half: Texture2D = preload("res://ui/hp_50.png")
var _hp_empty: Texture2D = preload("res://ui/hp_0.png")

@onready var root: Control = $Root
@onready var title_label: Label = $Root/Center/Window/Content/VBox/Title
@onready var subtitle_label: Label = $Root/Center/Window/Content/VBox/Subtitle
@onready var time_value: Label = $Root/Center/Window/Content/VBox/StatsRow/TimeStat/TimeIcon/TimeValue
@onready var hp_bar: TextureRect = $Root/Center/Window/Content/VBox/StatsRow/HpStat/HpBar
@onready var close_button: TextureButton = $Root/Center/Window/Close
@onready var restart_button: Button = $Root/Center/Window/Content/VBox/Buttons/RestartButton
@onready var menu_button: Button = $Root/Center/Window/Content/VBox/Buttons/MenuButton

var _button_tweens: Dictionary = {}


func _ready() -> void:
	root.visible = false
	GameManager.match_finished.connect(_on_match_finished)

	for button in [close_button, restart_button, menu_button] as Array[Control]:
		button.mouse_entered.connect(_on_button_hover.bind(true, button))
		button.mouse_exited.connect(_on_button_hover.bind(false, button))

	UiSound.bind(self)


func _on_match_finished(result: int) -> void:
	var player_is_hunter := GameManager.is_player_hunter()
	var hunter_win := result == GameManager.MatchResult.HUNTER_WIN
	var player_win := hunter_win == player_is_hunter

	title_label.text = "胜 利" if player_win else "失 败"
	title_label.add_theme_color_override(
		"font_color",
		Color(1.0, 0.85, 0.55) if player_win else Color(0.72, 0.18, 0.2)
	)
	subtitle_label.text = "追捕者胜利" if hunter_win else "逃生者胜利"

	# 剩余时间：只保留整数秒，倒计时归零时显示 0
	time_value.text = str(maxi(int(ceil(GameManager.match_time_left)), 0))

	# 剩余生命：按 2 / 1 / 0 切换血条贴图
	var max_hp := maxi(GameManager.survivor_max_hp, 1)
	var ratio := float(GameManager.survivor_hp) / float(max_hp)
	if ratio > 0.75:
		hp_bar.texture = _hp_full
	elif ratio > 0.25:
		hp_bar.texture = _hp_half
	else:
		hp_bar.texture = _hp_empty

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# 结算音效：按玩家视角的胜负播放
	AudioManager.play_2d(&"win" if player_win else &"defeat", -4.0)

	# 与其他界面统一的切换效果：先渐黑，再浮现结算窗口
	await SceneTransition.fade_out()
	root.visible = true
	root.modulate.a = 1.0
	await SceneTransition.fade_in()


func _on_restart_pressed() -> void:
	# 联机：由主机清空上一把的选角，所有玩家一起回到角色选择重新选人
	if NetworkManager.is_online():
		NetworkManager.request_rematch()
		return
	# 单人：重新开始 = 回到角色选择
	GameManager.goto_character_select()


func _on_menu_pressed() -> void:
	GameManager.return_to_menu()


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
