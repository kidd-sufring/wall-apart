extends Control

# 角色选择：一张窗口内左右两栏展示追捕者与逃生者。
# 单人：点「选择」进入技能介绍页，在介绍页确认后开局。
# 联机：点「选择」上报主机；已被选择的角色置灰。双方选完后由主机点「开始游戏」，
#       客户端显示「等待主机玩家开始游戏」。已选角色处直接显示玩家昵称。

@export var button_hover_scale := 1.06   # 悬停时的放大倍率
@export var button_hover_time := 0.12    # 放大/还原动画时长（秒）

@onready var back_button: Button = $BackButton
@onready var subtitle: Label = $Subtitle
@onready var card_close: TextureButton = $Cards/Card/Close
@onready var hunter_select: Button = $Cards/Card/Content/VBox/Row/HunterCol/SelectButton
@onready var survivor_select: Button = $Cards/Card/Content/VBox/Row/SurvivorCol/SelectButton
@onready var hunter_col: VBoxContainer = $Cards/Card/Content/VBox/Row/HunterCol
@onready var survivor_col: VBoxContainer = $Cards/Card/Content/VBox/Row/SurvivorCol
@onready var action_row: HBoxContainer = $Cards/Card/Content/VBox/ActionRow
@onready var cancel_button: Button = $Cards/Card/Content/VBox/ActionRow/CancelButton
@onready var start_button: Button = $Cards/Card/Content/VBox/ActionRow/StartButton
@onready var skill_intro: CanvasLayer = $SkillIntro
@onready var net_status: Control = $NetStatus
@onready var net_self: Label = $NetStatus/VBox/SelfLabel
@onready var net_oppo: Label = $NetStatus/VBox/OppoLabel
@onready var net_pick: Label = $NetStatus/VBox/PickLabel
@onready var net_hint: Label = $NetStatus/VBox/HintLabel

var _button_tweens: Dictionary = {}
var _locked_buttons: Dictionary = {}
var _hint_serial := 0


func _ready() -> void:
	GameManager.enter_character_select_state()
	Platform.set_capture(false)

	for button in [back_button, card_close, hunter_select, survivor_select,
			cancel_button, start_button] as Array[Control]:
		button.mouse_entered.connect(_on_button_hover.bind(true, button))
		button.mouse_exited.connect(_on_button_hover.bind(false, button))

	skill_intro.pick_confirmed.connect(_on_skill_pick)

	if NetworkManager.is_online():
		net_status.visible = true
		action_row.visible = true
		subtitle.text = "双方各选择一名角色，选好后由主机点击「开始游戏」"
		NetworkManager.selection_changed.connect(_refresh_net_state)
		NetworkManager.lobby_changed.connect(_refresh_net_state)
		NetworkManager.game_started.connect(_on_net_game_started)
		NetworkManager.status_changed.connect(_on_net_status)
		NetworkManager.select_rejected.connect(_on_select_rejected)
		_refresh_net_state()
	else:
		net_status.visible = false
		action_row.visible = false
		# 单人：显示上一步选好的难度，方便确认
		subtitle.text = "难度：%s · 请选择你的角色" % GameManager.get_difficulty_name(GameManager.difficulty)

	# 新手教程：不同角色进入对应的教程场景
	if GameManager.tutorial_mode:
		_apply_tutorial_mode()

	UiSound.bind(self)


# 新手教程流程：两种角色都可选，各自进入对应教程
func _apply_tutorial_mode() -> void:
	subtitle.text = "新手教程：请选择要学习的角色"


# 两个角色都先进技能介绍页，在介绍页点「选择此角色」才算确认
func _on_hunter_pressed() -> void:
	skill_intro.open(GameManager.ROLE_HUNTER)


func _on_survivor_pressed() -> void:
	skill_intro.open(GameManager.ROLE_SURVIVOR)


# 技能介绍页点击「选择此角色」
func _on_skill_pick(role: StringName) -> void:
	# 新手教程：确认角色后进入对应的教程场景
	if GameManager.tutorial_mode:
		if role != GameManager.ROLE_HUNTER and role != GameManager.ROLE_SURVIVOR:
			return
		GameManager.current_role = role
		var tutorial_scene := "res://scenes/tutorial_hunter.tscn" \
			if role == GameManager.ROLE_HUNTER else "res://scenes/tutorial_survivor.tscn"
		SceneTransition.change_scene(tutorial_scene)
		return

	# 单人：直接开局，转场淡出会覆盖技能介绍页
	if not NetworkManager.is_online():
		GameManager.start_single_match(role)
		return

	skill_intro.close()

	# 已被对手选走：回到角色选择界面并提示
	if NetworkManager.is_role_taken_by_other(role):
		_show_taken_hint(role)
		return

	NetworkManager.request_select(role)


# 主机拒绝选角（期间被别人抢选）
func _on_select_rejected(role: StringName) -> void:
	skill_intro.close()
	_show_taken_hint(role)


# 「该角色已被选择」提示，短暂显示后自动消失
func _show_taken_hint(role: StringName) -> void:
	_hint_serial += 1
	var serial := _hint_serial
	net_hint.text = "「%s」已被选择" % _role_name(role)
	net_hint.visible = true
	await get_tree().create_timer(2.5).timeout
	if serial == _hint_serial:
		net_hint.visible = false


func _on_cancel_pressed() -> void:
	if not NetworkManager.is_online():
		return
	NetworkManager.request_cancel()


func _on_start_pressed() -> void:
	if not NetworkManager.is_online():
		return
	NetworkManager.request_start()


func _on_back_pressed() -> void:
	# 新手教程：返回主菜单
	if GameManager.tutorial_mode:
		GameManager.enter_menu_state()
		SceneTransition.change_scene("res://scenes/main_menu.tscn")
		return
	if NetworkManager.is_online():
		NetworkManager.leave_room()
		SceneTransition.change_scene("res://scenes/lan_lobby.tscn")
		return
	# 单人：退回上一步的难度选择
	GameManager.goto_difficulty_select()


# ---------- 联机 ----------

func _on_net_status(text: String) -> void:
	net_pick.text = text


func _on_net_game_started() -> void:
	SceneTransition.change_scene("res://scenes/main.tscn")


# 根据主机同步下来的 selections 刷新锁定状态、昵称与开始按钮
func _refresh_net_state() -> void:
	_apply_role_lock(GameManager.ROLE_HUNTER, hunter_select, hunter_col)
	_apply_role_lock(GameManager.ROLE_SURVIVOR, survivor_select, survivor_col)

	var my_id := NetworkManager.get_my_id()
	var my_role := NetworkManager.get_my_role()
	net_self.text = "%s：%s" % [NetworkManager.get_nickname_of(my_id), _role_text(my_role)]

	var opp_id := 0
	for id in NetworkManager.players.keys():
		if int(id) != my_id:
			opp_id = int(id)
	if opp_id == 0:
		net_oppo.text = "对手：等待加入…"
	else:
		var opp_role: StringName = NetworkManager.players[opp_id].get("role", &"")
		net_oppo.text = "%s：%s" % [NetworkManager.get_nickname_of(opp_id), _role_text(opp_role)]

	var picks: Array[String] = []
	for role in NetworkManager.selections.keys():
		var owner_id := int(NetworkManager.selections[role])
		picks.append("%s 已选择 %s" % [NetworkManager.get_nickname_of(owner_id), _role_name(role)])
	net_pick.text = " · ".join(picks)

	# 取消选择：只有自己已选角色时可用
	cancel_button.disabled = my_role == &""
	# 开始游戏：主机在双方都选好后可点击；客户端只能等待
	if NetworkManager.is_host():
		start_button.text = "开始游戏"
		start_button.add_theme_font_size_override("font_size", 24)
		start_button.disabled = NetworkManager.selections.size() < 2
	else:
		start_button.text = "等待主机玩家开始游戏"
		start_button.add_theme_font_size_override("font_size", 16)
		start_button.disabled = true


func _apply_role_lock(role: StringName, button: Button, card: Control) -> void:
	var taken := NetworkManager.selections.has(role)
	if taken:
		# 变灰 + 禁用按钮
		card.modulate = Color(0.55, 0.55, 0.6, 1.0)
		button.disabled = true
		# 区分是“自己已选”还是“被对方选走”，避免两个灰置按钮含义不清
		if int(NetworkManager.selections[role]) == NetworkManager.get_my_id():
			button.text = "你已选择该角色"
		else:
			button.text = "已被对方选择"
		# 彻底关掉鼠标交互，避免 hover 放大
		button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tween: Tween = _button_tweens.get(button)
		if tween != null and tween.is_valid():
			tween.kill()
		button.scale = Vector2.ONE
		_locked_buttons[button] = true
	else:
		card.modulate = Color(1, 1, 1, 1)
		button.disabled = false
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		button.text = "选择"
		_locked_buttons.erase(button)


func _role_name(role: StringName) -> String:
	if role == GameManager.ROLE_HUNTER:
		return "追捕者"
	if role == GameManager.ROLE_SURVIVOR:
		return "逃生者"
	return "未选择"


func _role_text(role: StringName) -> String:
	return "未选择" if role == &"" else _role_name(role)


# ---------- 通用 ----------

# 悬停放大/离开还原：以按钮中心为轴缩放，不影响容器布局
func _on_button_hover(entered: bool, button: Control) -> void:
	if not is_instance_valid(button):
		return
	if _locked_buttons.has(button):
		return
	if button is BaseButton and (button as BaseButton).disabled and entered:
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
