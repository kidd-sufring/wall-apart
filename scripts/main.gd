extends Node3D

# 游戏场景：根据 GameManager.current_role / 联机角色分配玩家与 AI 控制权。
# - COUNTDOWN：双方冻结，等待 3 秒
# - PLAYING：解冻，40 秒比赛倒计时由 GameManager 统一管理
# - RESULT：冻结并由结算弹窗接管
# 联机模式下：本地玩家操控自己选择的角色，另一个角色由 NetworkSync 驱动。

@onready var survivor: Survivor = $Survivor
@onready var hunter: Hunter = $Hunter
@onready var camera_rig: CameraRig = $CameraRig
@onready var hud: CanvasLayer = $GameHUD

@export var debug_player_is_hunter := false  # 调试：直接运行本场景时用追捕者当玩家（不影响选人界面选择的角色）

func _ready() -> void:
	survivor.health_changed.connect(_on_survivor_health_changed)
	GameManager.state_changed.connect(_on_state_changed)

	if NetworkManager.is_online():
		_setup_multiplayer()
	else:
		# 只有没选过角色（直接运行游戏场景）时才走兜底，选人界面的选择优先
		if GameManager.current_role == &"":
			GameManager.current_role = GameManager.ROLE_HUNTER if debug_player_is_hunter else GameManager.ROLE_SURVIVOR
		_apply_roles()

	_set_characters_active(false)  # 准备倒计时期间冻结移动与技能
	GameManager.sync_survivor_hp(survivor.health, survivor.max_health)
	if NetworkManager.is_online():
		# 联机：等双方场景都加载完，由主机统一下发倒计时，避免各自计时不同步
		NetworkManager.report_scene_ready()
	else:
		GameManager.begin_countdown()
	# countdown 期间预热南瓜粘液滩特效，避免第一个南瓜落地时现编译着色器卡顿
	ThrowableItem.prewarm_slime_puddle(self)

	Platform.set_capture(true)

	# 进入对局停掉菜单背景音乐，并给 HUD 上的按钮挂上界面音效
	AudioManager.stop_bgm(0.3)
	UiSound.bind(self)


# ---------- 单人：玩家 + AI ----------

func _apply_roles() -> void:
	var player_is_hunter := GameManager.is_player_hunter()
	var player: CharacterBase = hunter if player_is_hunter else survivor
	var ai: CharacterBase = survivor if player_is_hunter else hunter

	player.player_controlled = true
	player.ai_target = null
	# 道具系统通过 "Player" 组判断是否可以拾取
	player.add_to_group("Player")

	ai.player_controlled = false
	ai.ai_target = player
	ai.camera_yaw = 0.0  # AI 角色没有相机，清空朝向绑定

	# 相机只跟随当前玩家角色
	camera_rig.set_target(player)
	camera_rig.yaw = PI / 2.0 if player_is_hunter else -PI / 2.0

	var skill_node: Node = hunter.get_node("GhostSkill") if player_is_hunter else survivor.get_node("BubbleShield")
	hud.bind_role(GameManager.current_role, skill_node)


# ---------- 联机：本地玩家 + 远端角色 ----------

func _setup_multiplayer() -> void:
	var my_role := NetworkManager.get_my_role()
	if my_role == &"":
		my_role = GameManager.ROLE_SURVIVOR
	GameManager.current_role = my_role

	var i_am_hunter := my_role == GameManager.ROLE_HUNTER
	var player: CharacterBase = hunter if i_am_hunter else survivor
	var remote: CharacterBase = survivor if i_am_hunter else hunter

	player.player_controlled = true
	player.ai_target = null
	player.remote_driven = false
	player.add_to_group("Player")

	remote.player_controlled = false
	remote.ai_target = null
	remote.remote_driven = true

	hunter.get_node("NetworkSync").is_local = i_am_hunter
	survivor.get_node("NetworkSync").is_local = not i_am_hunter

	camera_rig.set_target(player)
	camera_rig.yaw = PI / 2.0 if i_am_hunter else -PI / 2.0

	var skill_node: Node = hunter.get_node("GhostSkill") if i_am_hunter else survivor.get_node("BubbleShield")
	hud.bind_role(my_role, skill_node)

	NetworkManager.hp_received.connect(_on_net_hp)
	NetworkManager.result_received.connect(_on_net_result)
	NetworkManager.rematch_requested.connect(_on_rematch_requested)


# 任意一方点了重新开始：主机已清空选角，双方一起回角色选择重新选人
func _on_rematch_requested() -> void:
	GameManager.goto_character_select()


func _on_net_hp(hp: int) -> void:
	survivor.apply_network_hp(hp)


func _on_net_result(result: int) -> void:
	if GameManager.state == GameManager.GameState.PLAYING:
		GameManager.end_match(result)


# ---------- 状态切换 ----------

func _on_state_changed(new_state: int) -> void:
	if new_state == GameManager.GameState.PLAYING:
		_set_characters_active(true)
		Platform.set_capture(true)
	elif new_state == GameManager.GameState.RESULT:
		_set_characters_active(false)
		# 联机：主机把最终结果同步给客户端
		if NetworkManager.is_online() and NetworkManager.is_host():
			NetworkManager.broadcast_result(GameManager.match_result)


func _set_characters_active(is_active: bool) -> void:
	survivor.active = is_active
	hunter.active = is_active


func _on_survivor_health_changed(current: int, maximum: int) -> void:
	# 血量统一写入 GameManager，HUD 与胜负判定都从这里读
	GameManager.sync_survivor_hp(current, maximum)


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	# Esc 释放鼠标，点击窗口重新锁定
	if event.is_action_pressed("ui_cancel"):
		Platform.set_capture(false)
	elif event is InputEventMouseButton and event.pressed:
		Platform.set_capture(true)
