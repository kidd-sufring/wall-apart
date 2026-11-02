extends Node

# 联机角色同步：本地角色按固定间隔发送位置/朝向/奔跑状态/当前动画，
# 远端角色插值跟随位置并直接播放对应动画，保证双方能看到对方的动作。
# 同时同步护盾可视化与幽灵模型状态。
# 挂在 Hunter / Survivor 下，role_id 与选角 ID 对应。

@export var role_id: StringName = &""       # 该角色对应的选角 ID
@export var body_path: NodePath = ^".."
@export_range(0.02, 0.2, 0.01) var send_interval := 0.05

var is_local := true                        # true = 本机操控的角色

var _body: CharacterBase
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _acc := 0.0

var _remote_anim: StringName = &""
var _remote_anim_speed := 1.0
var _remote_flags := -1


func _ready() -> void:
	_body = get_node_or_null(body_path) as CharacterBase
	if _body != null:
		_target_pos = _body.global_position
		_target_yaw = _body.rotation.y


func _physics_process(delta: float) -> void:
	if not NetworkManager.is_online() or _body == null:
		return

	if is_local:
		if not _body.active:
			return
		_acc += delta
		if _acc >= send_interval:
			_acc = 0.0
			var anim_state := _body.get_anim_state()
			rpc("_rpc_state", _body.global_position, _body.rotation.y, _body.is_run_mode,
				anim_state[0], anim_state[1], _collect_flags())
	else:
		if not _body.remote_driven:
			return
		# 远端角色做位置插值，避免顿挫
		_body.global_position = _body.global_position.lerp(_target_pos, minf(1.0, delta * 14.0))
		_body.rotation.y = lerp_angle(_body.rotation.y, _target_yaw, minf(1.0, delta * 14.0))
		_body.apply_remote_anim(_remote_anim, _remote_anim_speed)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_state(pos: Vector3, yaw: float, run: bool, anim: StringName, anim_speed: float, flags: int) -> void:
	if is_local or _body == null:
		return
	# 只接受该角色归属玩家发来的状态
	if multiplayer.get_remote_sender_id() != NetworkManager.get_role_owner(role_id):
		return
	_target_pos = pos
	_target_yaw = yaw
	_body.is_run_mode = run
	_remote_anim = anim
	_remote_anim_speed = anim_speed
	if flags != _remote_flags:
		_apply_flags(flags)


# bit0 = 护盾可视化显示中；bit1 = 追捕者处于幽灵状态；bit2 = 逃生者受伤无敌虚化
func _collect_flags() -> int:
	var flags := 0
	var shield := _body.get_node_or_null("ShieldVisual") as Node3D
	if shield != null and shield.visible:
		flags |= 1
	var ghost := _body.get_node_or_null("GhostSkill")
	if ghost != null and ghost.has_method("is_ghost_active") and bool(ghost.call("is_ghost_active")):
		flags |= 2
	# 无敌虚化是逃生者自己的本地状态，远端必须按标志显示，否则会一直卡在虚化
	if _body.has_method("is_hit_invincible") and bool(_body.call("is_hit_invincible")):
		flags |= 4
	return flags


func _apply_flags(flags: int) -> void:
	_remote_flags = flags
	# 幽灵状态不只是外观：远端追捕者不运行本地技能状态机，
	# 必须把“当前是否免疫投掷物”同步过去，命中判定才认这套状态
	if _body.has_method("set_remote_ghost_active"):
		_body.call("set_remote_ghost_active", (flags & 2) != 0)

	var shield := _body.get_node_or_null("ShieldVisual") as Node3D
	if shield != null:
		shield.visible = (flags & 1) != 0

	# 逃生者受伤无敌虚化：远端不做本地计时，只跟随拥有者的标志
	if _body.has_method("set_remote_invincible"):
		_body.call("set_remote_invincible", (flags & 4) != 0)

	var ghost := _body.get_node_or_null("GhostSkill")
	if ghost == null:
		return
	if (flags & 2) != 0:
		if not bool(ghost.call("is_ghost_active")):
			ghost.call("_show_ghost_model")
	else:
		ghost.call("_hide_ghost_model")
