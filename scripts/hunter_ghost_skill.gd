class_name HunterGhostSkill
extends Node

# 幽灵状态（Ghost State）
# 只负责“追捕者技能”本身：状态机、模型替换、穿墙碰撞开关、穿墙检测与冷却。
# 移动分工：
#   - 玩家操控：完全交给角色原有控制器，本脚本不覆盖速度、不调用 move_and_slide。
#   - AI 托管：HWAF 被挂起后，由本脚本直线朝逃生者移动（可穿墙）。
# 与 HWAF 协作：ACTIVE 期间调用 suspend_hwaf()，结束时 resume_hwaf()。
# 挂起是计数式的：击退也挂起 HWAF 时，两边各自恢复不会把对方的状态放开。

enum State {
	READY,
	ACTIVE,
	COOLDOWN,
}

@export_group("开关")
@export var ai_enabled := true                       # AI 托管总开关（与 HWAF 的 ai_enabled 保持一致）
@export var hwaf_path: NodePath = ^"../HWAF"         # 追捕者身上的 HWAF 节点

@export_group("模型")
@export var ghost_model_scene: PackedScene           # 幽灵模型（hunter_skill.glb）
@export var original_visual_root: Node3D             # 原始外观根节点（Hunter/Model），只隐藏外观不动碰撞
@export var ghost_model_root: Node3D                 # 幽灵模型挂载点（Hunter/GhostModelRoot）
@export var ghost_model_yaw_offset_deg := 0.0        # 幽灵模型额外朝向修正（模型正面不一致时调整）
@export var fade_time := 0.22                        # 进入/退出幽灵状态的外观渐隐渐显时长（秒）
@export var forward_tilt_deg := 20.0                 # 幽灵模型围绕脚部向前倾斜的角度

@export_group("碰撞与检测")
# 墙体/木箱所在物理层（本项目 layer 1 = Wall，位值 1；地面单独在 layer 4 = Ground）。
# 只把该层从 collision_mask 中移除；地面、角色层保持碰撞。
@export var wall_collision_mask := 1
@export var exit_clearance := 0.8                    # 离开墙体后需要保持的最小距离
@export var ray_height := 0.9                        # 穿墙射线高度（角色胶囊中部），避免贴地漏检

@export_group("时长与冷却")
@export var max_duration := 3.0                      # 常规最大持续时间（未穿墙时兜底）
@export var hard_max_duration := 10.0                # 硬上限（仍卡在墙内时强制复位）
@export var cooldown_seconds := 10.0                 # 冷却时间
@export var cooldown_starts_on_end := true           # true=从技能结束开始冷却；false=从触发开始
@export var ghost_ai_speed := 6.0                    # AI 幽灵状态的直线移动速度
@export var shield_exit_hysteresis := 0.6            # 幽灵护盾规避的退出迟滞：距离超过 safe+该值才恢复直线追击
@export var shield_orbit_tangent_weight := 1.0       # 护盾规避时切向绕行权重（越大越接近环绕）

@onready var body: CharacterBase = get_parent() as CharacterBase
@onready var hwaf: HunterWallAvoidFollow = get_node_or_null(hwaf_path) as HunterWallAvoidFollow

var _state: int = State.READY
var _cooldown_left := 0.0
var _active_time := 0.0

var _saved_collision_mask := 0

var _previous_position := Vector3.ZERO
var _has_entered_wall := false
var _inside_wall := false

var _ghost_instance: Node3D = null
var _body_shape: CollisionShape3D = null
var _shape_offset_y := 0.85

var _avoid_shield := false                          # 幽灵状态是否正在做护盾规避
var _avoid_side := 1.0                              # 绕行方向：+1 / -1，进入规避时随机锁定

var _original_meshes: Array[MeshInstance3D] = []   # 原模型网格（做渐隐渐显）
var _ghost_meshes: Array[MeshInstance3D] = []      # 幽灵模型网格（做渐隐渐显）
var _fade_tween: Tween = null

var _shape_query: PhysicsShapeQueryParameters3D
var _clearance_query: PhysicsShapeQueryParameters3D
var _clearance_shape: SphereShape3D


func _ready() -> void:
	# 场景里未手动指定节点引用时，按 Hunter 的标准节点名自动查找，避免误隐藏碰撞体
	if original_visual_root == null and body != null:
		original_visual_root = body.get_node_or_null("Model") as Node3D
	if ghost_model_root == null and body != null:
		ghost_model_root = body.get_node_or_null("GhostModelRoot") as Node3D

	# 缓存原模型网格，用于进入/退出幽灵状态时的渐隐渐显
	if original_visual_root != null:
		for node in original_visual_root.find_children("*", "MeshInstance3D", true, false):
			_original_meshes.append(node as MeshInstance3D)

	_shape_query = PhysicsShapeQueryParameters3D.new()
	_shape_query.collide_with_bodies = true
	_shape_query.collide_with_areas = false
	_shape_query.exclude = [body.get_rid()]

	_clearance_shape = SphereShape3D.new()
	_clearance_shape.radius = exit_clearance
	_clearance_query = PhysicsShapeQueryParameters3D.new()
	_clearance_query.shape = _clearance_shape
	_clearance_query.collide_with_bodies = true
	_clearance_query.collide_with_areas = false
	_clearance_query.exclude = [body.get_rid()]

	# 取角色主碰撞体作为“是否在墙内”的查询形状；不要用 HitBox
	_body_shape = body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _body_shape == null:
		for child in body.get_children():
			if child is CollisionShape3D:
				_body_shape = child
				break
	if _body_shape != null:
		_shape_offset_y = _body_shape.position.y


func _physics_process(delta: float) -> void:
	if body == null:
		return

	match _state:
		State.READY:
			_try_start()
		State.ACTIVE:
			# 玩家再次按 F 主动关闭技能；在墙内关闭时先复位到安全点
			if body.player_controlled and Input.is_action_just_pressed("ghost_skill"):
				_end_ghost(_inside_wall)
				return
			_process_active(delta)
		State.COOLDOWN:
			_cooldown_left = maxf(_cooldown_left - delta, 0.0)
			if _cooldown_left <= 0.0:
				_state = State.READY


func _is_ai_hosted() -> bool:
	return (
		ai_enabled
		and body != null
		and body.active
		and not body.player_controlled
		and body.ai_target != null
	)


func _is_knocked_back() -> bool:
	# 追捕者被击退时由 Hunter 接管移动
	return body != null and body.has_method("is_knocked_back") and bool(body.call("is_knocked_back"))


# 追捕者正在执行战术规避时同样由 Hunter 接管位移（规避期间 Hunter 跳过常规移动）
func _is_body_evading() -> bool:
	return body != null and body.get("is_evading") == true


func _try_start() -> void:
	if not body.active:
		return
	# 击晕倒地/起身期间不开启技能，否则起身瞬间会带着技能速度直接弹射出去
	if body.is_stunned:
		return
	# AI 托管：冷却结束就自动使用，不读输入
	if _is_ai_hosted():
		_start_ghost()
		return
	# 玩家操控追捕者：F 触发
	if body.player_controlled and Input.is_action_just_pressed("ghost_skill"):
		_start_ghost()


func _start_ghost() -> void:
	if _state != State.READY:
		return

	# 1) 挂起 HWAF（计数式）：击退同时挂起时，两边的恢复不会互相放开
	if hwaf != null:
		hwaf.suspend_hwaf()

	# 2) 只移除墙体物理层，地面/边界/角色碰撞保留
	_saved_collision_mask = body.collision_mask
	body.collision_mask = _saved_collision_mask & ~wall_collision_mask

	# 3) 替换外观
	_show_ghost_model()

	# 4) 重置穿墙检测
	_has_entered_wall = false
	_inside_wall = false
	_active_time = 0.0
	_previous_position = body.global_position

	# 5) 技能释放音效：当作较远处的世界音源，远处的玩家也能听到方位
	AudioManager.play_3d(&"hunter_skill", body.global_position + Vector3.UP * 0.9, -3.0, 1.0, 8.0, 45.0)

	_state = State.ACTIVE

	# 全局事件：玩家释放了主动技能
	if body.player_controlled:
		EventBus.skill_used.emit()


func _process_active(delta: float) -> void:
	_active_time += delta

	# AI 幽灵：不寻路，直接朝逃生者直线移动（可穿墙）
	# 被击退/战术规避期间让出移动权，避免与这些运动互相覆盖
	if _is_ai_hosted() and not _is_knocked_back() and not _is_body_evading():
		_drive_ai(delta)

	# 1) 本帧位移射线：防止高速移动跳过薄墙
	var from := _previous_position + Vector3.UP * ray_height
	var to := body.global_position + Vector3.UP * ray_height
	if from.distance_squared_to(to) > 0.000001:
		var ray := PhysicsRayQueryParameters3D.create(from, to, wall_collision_mask, [body.get_rid()])
		if not _space().intersect_ray(ray).is_empty():
			_has_entered_wall = true

	# 2) 当前是否与墙体重叠
	_inside_wall = _overlaps_wall()
	var clear := _is_clear_of_walls()

	# 3) 穿过墙并从另一侧离开 exit_clearance：正常结束
	if _has_entered_wall and not _inside_wall and clear:
		_previous_position = body.global_position
		_end_ghost(false)
		return

	# 4) 未穿墙的时长兜底：仅在墙外且满足安全距离时结束
	if _active_time >= max_duration and not _inside_wall and clear:
		_previous_position = body.global_position
		_end_ghost(false)
		return

	# 5) 硬上限：仍在墙内时复位到最近导航点后再结束
	if _active_time >= hard_max_duration:
		_end_ghost(true)
		return

	_previous_position = body.global_position


# AI 幽灵移动：直线追击 + 重力，不经过 NavigationAgent3D
# HSA：目标有生效中的护盾且已进入安全距离时，改为后撤 + 侧向绕行，不主动撞盾。
func _drive_ai(delta: float) -> void:
	var target := body.ai_target
	if target == null:
		target = get_tree().get_first_node_in_group("player") as CharacterBase

	var direction := Vector3.ZERO
	if target != null:
		var to_target := target.global_position - body.global_position
		to_target.y = 0.0
		var distance := to_target.length()
		if distance > 0.0001:
			direction = to_target / distance

		# HSA（方案 E）：带退出迟滞的护盾规避，进入时随机锁定左/右绕行方向
		if _is_target_shield_active(target):
			var safe := _shield_safe_distance(target)
			if not _avoid_shield and distance <= safe:
				_avoid_shield = true
				_avoid_side = 1.0 if randf() < 0.5 else -1.0
			elif _avoid_shield and distance >= safe + maxf(shield_exit_hysteresis, 0.0):
				_avoid_shield = false
		else:
			_avoid_shield = false

		if _avoid_shield and direction.length_squared() > 0.0001:
			# 后撤 + 固定方向的切向绕行，避免每帧在“冲/退”之间切换
			var away := -direction
			var side := Vector3(-away.z, 0.0, away.x) * _avoid_side
			direction = (away * 0.8 + side * maxf(shield_orbit_tangent_weight, 0.0)).normalized()

	# 命中减速（南瓜）与蛛网减速同样作用于幽灵状态的直线移动
	var speed := ghost_ai_speed * body.get_hit_slow_multiplier()
	body.velocity.x = direction.x * speed
	body.velocity.z = direction.z * speed
	body.call("_apply_gravity", delta)
	body.move_and_slide()

	if direction.length_squared() > 0.0001:
		body.call("_face_direction", direction, delta)


# 只读：目标身上是否有生效中的 SBS 护盾
func _is_target_shield_active(target: Node) -> bool:
	var shield := target.get_node_or_null("BubbleShield")
	if shield == null or not shield.has_method("is_shield_active"):
		return false
	return bool(shield.call("is_shield_active"))


# 安全距离 = 护盾半径 + HWAF 的保持距离缓冲（复用同一套参数，避免两处调参）
func _shield_safe_distance(target: Node) -> float:
	var shield := target.get_node_or_null("BubbleShield")
	var radius := 1.0
	if shield != null and shield.has_method("get_shield_radius"):
		radius = float(shield.call("get_shield_radius"))
	var buffer := 1.0
	if hwaf != null:
		buffer = hwaf.keep_distance_buffer
	return radius + maxf(buffer, 0.0)


func _overlaps_wall() -> bool:
	if _body_shape == null or _body_shape.shape == null:
		return false
	_shape_query.shape = _body_shape.shape
	_shape_query.transform = _body_shape.global_transform
	_shape_query.collision_mask = wall_collision_mask
	return not _space().intersect_shape(_shape_query, 1).is_empty()


func _is_clear_of_walls() -> bool:
	_clearance_query.transform = Transform3D(Basis(), body.global_position + Vector3.UP * _shape_offset_y)
	_clearance_query.collision_mask = wall_collision_mask
	return _space().intersect_shape(_clearance_query, 1).is_empty()


func _space() -> PhysicsDirectSpaceState3D:
	return body.get_world_3d().direct_space_state


func _end_ghost(force_safe_reset: bool) -> void:
	if force_safe_reset:
		_relocate_to_safe_point()

	_hide_ghost_model()
	body.collision_mask = _saved_collision_mask

	_has_entered_wall = false
	_inside_wall = false

	# 计数式恢复：若击退仍在挂起 HWAF，这里不会把它放开
	if hwaf != null:
		hwaf.resume_hwaf()

	if cooldown_starts_on_end:
		_cooldown_left = cooldown_seconds
	else:
		_cooldown_left = maxf(cooldown_seconds - _active_time, 0.0)

	_active_time = 0.0
	_state = State.COOLDOWN if _cooldown_left > 0.0 else State.READY


func _relocate_to_safe_point() -> void:
	var map_rid := body.get_world_3d().navigation_map
	if map_rid.is_valid():
		var closest := NavigationServer3D.map_get_closest_point(map_rid, body.global_position)
		body.global_position = closest + Vector3.UP * 0.05
		body.velocity = Vector3.ZERO


func _show_ghost_model() -> void:
	if ghost_model_scene == null or ghost_model_root == null:
		return

	# 切换过程中又被重新触发：把已有幽灵模型直接渐显回去
	if _ghost_instance != null and is_instance_valid(_ghost_instance):
		if original_visual_root != null:
			original_visual_root.visible = true
		_fade_visual(true)
		return

	_ghost_instance = ghost_model_scene.instantiate() as Node3D
	if _ghost_instance == null:
		return
	ghost_model_root.add_child(_ghost_instance)
	# 幽灵模型也要能显示减速/受击的染色效果
	body.apply_slow_tint_to(_ghost_instance)

	# 复用原模型的缩放与朝向，可再叠加一个朝向修正
	var base := original_visual_root.global_transform if original_visual_root != null else ghost_model_root.global_transform
	base.basis = base.basis * Basis(Vector3.UP, deg_to_rad(ghost_model_yaw_offset_deg))
	_ghost_instance.global_transform = base

	# 幽灵模型高度与本体对齐：头部同高，脚允许悬空
	_align_head_height()
	# 围绕脚部前倾，形成前扑姿态
	_tilt_forward()
	# 循环播放幽灵模型自带的漂浮动画，避免替换后停在绑定姿态
	_play_ghost_animation()

	# 幽灵模型从全透明开始渐显
	_ghost_meshes.clear()
	for node in _ghost_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		mesh.transparency = 1.0
		_ghost_meshes.append(mesh)

	# 原模型保持显示，渐隐结束（_apply_visual_state）后才隐藏
	if original_visual_root != null:
		original_visual_root.visible = true
	_fade_visual(true)


func _hide_ghost_model() -> void:
	# 没有幽灵模型且原模型已完全显示时无需处理
	if _ghost_instance == null and (original_visual_root == null or original_visual_root.visible):
		return

	if original_visual_root != null:
		original_visual_root.visible = true
	_fade_visual(false)


# show_ghost = true：原模型渐隐、幽灵模型渐显；false：反向
func _fade_visual(show_ghost: bool) -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()

	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	for mesh in _original_meshes:
		tween.tween_property(mesh, "transparency", 1.0 if show_ghost else 0.0, fade_time)
	for mesh in _ghost_meshes:
		tween.tween_property(mesh, "transparency", 0.0 if show_ghost else 1.0, fade_time)
	tween.set_parallel(false)
	tween.tween_callback(_apply_visual_state.bind(show_ghost))
	_fade_tween = tween


# 让幽灵模型的头部与追捕者本体头部同高：先按头高比例缩放，再做一次精确下移/上移。
# 参照静止姿态（rest pose），避免本体播放跑动动画时每帧改变缩放比例。
func _align_head_height() -> void:
	if _ghost_instance == null or original_visual_root == null:
		return

	var target_head := _head_rest_height(original_visual_root)
	var ghost_head := _head_rest_height(_ghost_instance)
	if is_nan(target_head) or is_nan(ghost_head):
		return

	var origin_y := _ghost_instance.global_position.y
	var head_offset := ghost_head - origin_y
	var target_offset := target_head - origin_y
	if head_offset <= 0.001 or target_offset <= 0.001:
		return

	# 按头高比例缩放模型高度
	_ghost_instance.scale *= target_offset / head_offset

	# 缩放后精确对齐头顶（模型原点不在脚底时会留下少量偏差）
	var new_head := _head_rest_height(_ghost_instance)
	if not is_nan(new_head):
		_ghost_instance.global_position.y += target_head - new_head


# 围绕脚部（模型原点）向前倾斜：以角色右方向为轴旋转，头顶朝角色前方（-Z）倒
func _tilt_forward() -> void:
	if _ghost_instance == null or body == null or is_zero_approx(forward_tilt_deg):
		return
	var right := body.global_transform.basis.x.normalized()
	var lean := Basis(right, deg_to_rad(-forward_tilt_deg))
	var current := _ghost_instance.global_transform
	_ghost_instance.global_transform = Transform3D(lean * current.basis, current.origin)


# 静止姿态下 Head 骨骼的世界高度；找不到骨骼时退回包围盒顶部
func _head_rest_height(root_node: Node3D) -> float:
	var skeleton := _find_skeleton(root_node)
	if skeleton != null:
		var index := skeleton.find_bone("Head")
		if index >= 0:
			return (skeleton.global_transform * skeleton.get_bone_global_rest(index).origin).y

	var top := -INF
	for node in root_node.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		top = maxf(top, box.position.y + box.size.y)
	return top


func _find_skeleton(root_node: Node3D) -> Skeleton3D:
	if root_node == null:
		return null
	if root_node is Skeleton3D:
		return root_node as Skeleton3D
	for node in root_node.find_children("*", "Skeleton3D", true, false):
		return node as Skeleton3D
	return null


# 播放幽灵模型自带的动画（优先 Ghost 关键字），并设为循环
func _play_ghost_animation() -> void:
	if _ghost_instance == null:
		return
	var anim_player := _ghost_instance.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim_player == null:
		return
	var list := anim_player.get_animation_list()
	if list.is_empty():
		return
	var pick: StringName = list[0]
	for candidate in list:
		if String(candidate).to_lower().contains("ghost"):
			pick = candidate
			break
	var anim := anim_player.get_animation(pick)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	anim_player.play(pick)


# 渐隐渐显结束后才真正切换节点显隐并释放幽灵模型
func _apply_visual_state(show_ghost: bool) -> void:
	if original_visual_root != null:
		original_visual_root.visible = not show_ghost

	if not show_ghost and _ghost_instance != null:
		if is_instance_valid(_ghost_instance):
			_ghost_instance.queue_free()
		_ghost_instance = null
		_ghost_meshes.clear()


func is_ghost_active() -> bool:
	return _state == State.ACTIVE


# 外部强制结束（如被石头击中），走正常收尾流程：恢复碰撞/外观并进入冷却
func force_end() -> void:
	if _state == State.ACTIVE:
		_end_ghost(false)


# 教程等场景用：立即结束幽灵状态、清除冷却，让技能随时可用
func reset_skill() -> void:
	if _state == State.ACTIVE:
		_hide_ghost_model()
		body.collision_mask = _saved_collision_mask
		if hwaf != null:
			hwaf.resume_hwaf()
	_state = State.READY
	_cooldown_left = 0.0
	_active_time = 0.0
	_has_entered_wall = false
	_inside_wall = false


func get_state() -> int:
	return _state


func get_state_name() -> String:
	match _state:
		State.ACTIVE:
			return "ACTIVE"
		State.COOLDOWN:
			return "COOLDOWN"
		_:
			return "READY"


func get_cooldown_left() -> float:
	return _cooldown_left


# 只读接口（供 HUD 显示技能状态）
func is_skill_ready() -> bool:
	return _state == State.READY


# 0 = 就绪，1 = 刚进入冷却/技能生效中
func get_skill_cooldown_ratio() -> float:
	if cooldown_seconds <= 0.0:
		return 0.0
	if _state == State.READY:
		return 0.0
	if _state == State.ACTIVE:
		return 1.0
	return clampf(_cooldown_left / cooldown_seconds, 0.0, 1.0)
