class_name SurvivorWallAvoidEvade
extends Node

# SWAE：Survivor Wall-Avoid Evade（逃生者绕墙逃离）
# 复用 HWAF 的导航框架（NavigationAgent3D + 导航网格绕墙），
# 通过环形采样选择“离追捕者最远、可达且开阔”的目标点，避免直线逃跑撞墙/钻死角。
# 只在逃生者由 AI 托管时接管移动；玩家操控时完全让出控制权。

enum State {
	WALL_AVOID_EVADE,
	RECOVER,
	CORNER_ESCAPE,
	DISABLED,
}

@export_group("开关")
@export var ai_enabled := true                      # 逃生者是否由 AI 托管
@export var wall_avoid_evade_enabled := true        # SWAE 专用开关
@export var hunter_group: StringName = &"hunter"    # 追捕者分组（ai_target 为空时用于查找）
@export var agent_path: NodePath = ^"../NavigationAgent3D"
@export var shield_path: NodePath = ^"../BubbleShield"

@export_group("移动")
@export var move_speed := 6.0                       # 与逃生者奔跑速度一致
@export var acceleration := 14.0                    # 水平加速度

@export_group("目标采样")
@export var target_update_interval := 0.25          # 重新采样目标的间隔，避免逐帧抖动
@export var sample_directions := 16                 # 环形采样方向数
@export var sample_distance := 6.0                  # 采样半径（建议 4~8 米）
@export var corner_sample_multiplier := 1.6         # 角落脱困时放大的采样半径倍率
@export var max_sample_offset := 1.5                # 候选点映射到导航网格的最大偏移，超过视为贴墙/出界
@export var openness_radius := 2.0                  # 开阔度探测半径
@export var openness_weight := 2.0                  # 开阔度权重
@export var side_bonus_weight := 4.0                # 角落脱困时“侧向绕行”权重
@export var direction_hysteresis := 1.5             # 与上一次目标方向的一致性加成，抑制来回抖动

@export_group("卡死与脱困")
@export var stuck_check_interval := 1.0             # 卡死检测周期
@export var stuck_distance := 0.1                   # 周期内位移低于该值视为卡住
@export var corner_stuck_threshold := 2             # 连续卡住次数达到后进入 CORNER_ESCAPE
@export var shield_escape_stuck := 3                # 连续卡住次数达到后尝试用 SBS 脱困
@export var recover_time := 0.6                     # 无可用目标/复位后的恢复时间
@export var allow_shield_escape := false            # 允许 AI 在连续卡死且 SBS 就绪时用护盾脱困

@onready var body: CharacterBase = get_parent() as CharacterBase
@onready var agent: NavigationAgent3D = get_node_or_null(agent_path) as NavigationAgent3D
@onready var shield: SurvivorBubbleShield = get_node_or_null(shield_path) as SurvivorBubbleShield

var _state: int = State.DISABLED
var _target_timer := 0.0
var _stuck_timer := 0.0
var _stuck_count := 0
var _recover_timer := 0.0
var _last_stuck_position := Vector3.ZERO
var _last_direction := Vector3.ZERO
var _hunter: Node3D = null


func _ready() -> void:
	# 由 Survivor 的 _physics_process 主动调用 physics_step，避免双重驱动
	set_physics_process(false)
	_last_stuck_position = body.global_position if body else Vector3.ZERO

	if agent != null:
		# 与 HWAF 一致的导航参数：0.35 防止跳过墙角，0.7 允许贴近目标
		agent.path_desired_distance = 0.35
		agent.target_desired_distance = 0.7
		agent.radius = 0.6
		agent.height = 1.7
		agent.max_speed = move_speed
		agent.avoidance_enabled = false


func should_drive() -> bool:
	return (
		ai_enabled
		and wall_avoid_evade_enabled
		and body != null
		and body.active
		and not body.player_controlled
		and body.ai_target != null
		# 跑去捡道具时让出移动权，由基类 AI 朝道具移动
		and not body.is_seeking_item()
	)


func physics_step(delta: float) -> void:
	if not should_drive():
		_state = State.DISABLED
		return

	# 保留逃生者自身的无敌闪烁 / 加速计时
	body.call("_update_status", delta)

	if agent == null:
		_state = State.DISABLED
		return

	_hunter = _get_hunter()
	if _hunter == null:
		_state = State.DISABLED
		return

	if _recover_timer > 0.0:
		_state = State.RECOVER
		_recover_timer -= delta
		_brake(delta)
		return

	if _state == State.DISABLED:
		_state = State.WALL_AVOID_EVADE

	_update_target(delta)
	_move(delta)
	_update_stuck(delta)


func _get_hunter() -> Node3D:
	# main.gd 会把被追踪的玩家写入 ai_target；组查找作为回退
	if body.ai_target != null:
		return body.ai_target
	if _hunter != null and is_instance_valid(_hunter):
		return _hunter
	return get_tree().get_first_node_in_group(hunter_group) as Node3D


func _update_target(delta: float) -> void:
	_target_timer -= delta
	if _target_timer > 0.0:
		return
	_target_timer = target_update_interval
	_repath()


# 重新挑选逃离目标并写入 NavigationAgent3D
func _repath() -> void:
	var point: Variant = _pick_candidate()
	if point == null:
		# 所有候选点都不可达：退回最近有效导航点并短暂恢复
		_relocate_to_navmesh()
		_recover_timer = recover_time
		_state = State.RECOVER
		return
	agent.target_position = point


# 环形采样：到追捕者距离最大 + 路径可达 + 开阔度最高
func _pick_candidate() -> Variant:
	var map := body.get_world_3d().navigation_map
	if not map.is_valid():
		return null

	var origin := body.global_position
	var hunter_pos := _hunter.global_position
	var radius := sample_distance
	if _state == State.CORNER_ESCAPE:
		radius *= corner_sample_multiplier

	# 采样基准投影到脚下的导航网格：腾空（跳跃）时高度差不应该影响候选点判定，
	# 否则候选点会被全部判成“偏移过大/太近”，导致逃生方向临时翻转
	var ground_origin := NavigationServer3D.map_get_closest_point(map, origin)

	var candidates: Array[Dictionary] = []
	for i in sample_directions:
		var angle := TAU * float(i) / sample_directions
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var raw := ground_origin + dir * radius
		var closest := NavigationServer3D.map_get_closest_point(map, raw)

		# 映射偏移过大说明候选点落在墙体/边界外，丢弃（只比较水平距离）
		if Vector2(raw.x - closest.x, raw.z - closest.z).length() > max_sample_offset:
			continue
		if Vector2(closest.x - ground_origin.x, closest.z - ground_origin.z).length() < 1.0:
			continue
		if not _is_reachable(map, closest, ground_origin):
			continue

		var hunter_dist := Vector2(closest.x - hunter_pos.x, closest.z - hunter_pos.z).length()
		candidates.append({"point": closest, "dist": hunter_dist, "dir": dir})

	if candidates.is_empty():
		return null

	# 先按与追捕者的距离排序，只对最远的若干个候选做开阔度采样，控制查询开销
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["dist"] > b["dist"])

	var to_hunter := Vector3(hunter_pos.x - origin.x, 0.0, hunter_pos.z - origin.z)
	var best_score := -INF
	var best_point: Vector3 = origin
	var best_dir := Vector3.ZERO
	var count: int = mini(6, candidates.size())
	for i in count:
		var c: Dictionary = candidates[i]
		var point: Vector3 = c["point"]
		var dir: Vector3 = c["dir"]

		var score: float = c["dist"]
		score += float(_openness(map, point)) * openness_weight

		# 角落脱困时优先绕追捕者侧面，而不是继续背对追捕者直线逃跑
		if _state == State.CORNER_ESCAPE and to_hunter.length_squared() > 0.0001:
			var dot := to_hunter.normalized().dot(dir)
			score += (1.0 - absf(dot)) * side_bonus_weight

		# 与上一次方向一致时加成，避免目标在两侧来回切换
		if _last_direction.length_squared() > 0.0001:
			score += maxf(0.0, _last_direction.dot(dir)) * direction_hysteresis

		if score > best_score:
			best_score = score
			best_point = point
			best_dir = dir

	_last_direction = best_dir
	return best_point


# 从当前位置到目标是否可达（不可达时 map_get_path 的终点会偏离目标）
func _is_reachable(map: RID, target: Vector3, from: Vector3) -> bool:
	var path := NavigationServer3D.map_get_path(map, from, target, true)
	if path.is_empty():
		return false
	return path[path.size() - 1].distance_to(target) <= 1.0


# 开阔度：目标点四周探测导航网格是否依然存在
func _openness(map: RID, point: Vector3) -> int:
	var open := 0
	for i in 4:
		var angle := TAU * float(i) / 4.0
		var probe := point + Vector3(cos(angle), 0.0, sin(angle)) * openness_radius
		var closest := NavigationServer3D.map_get_closest_point(map, probe)
		if probe.distance_to(closest) <= 0.5:
			open += 1
	return open


func _move(delta: float) -> void:
	# 用水平距离判断路径点是否到达，避免跳跃腾空时路径点永远“未到达”导致急停/倒退
	var direction := body.get_nav_direction(agent)

	# 受击加速期间沿用逃生者自身的速度倍率，减速区域与南瓜命中再各叠加一层
	var speed := move_speed * body.get_speed_multiplier() * body.get_hit_slow_multiplier()
	var desired := direction * speed
	body.velocity.x = move_toward(body.velocity.x, desired.x, acceleration * delta)
	body.velocity.z = move_toward(body.velocity.z, desired.z, acceleration * delta)

	body.call("_apply_gravity", delta)
	body.is_run_mode = direction.length_squared() > 0.0001
	body.move_and_slide()

	if direction.length_squared() > 0.0001:
		body.call("_face_direction", direction, delta)

	body.call("_update_animation")
	body.call("_update_animation_speed", delta)


func _brake(delta: float) -> void:
	body.velocity.x = move_toward(body.velocity.x, 0.0, acceleration * delta)
	body.velocity.z = move_toward(body.velocity.z, 0.0, acceleration * delta)
	body.call("_apply_gravity", delta)
	body.is_run_mode = false
	body.move_and_slide()
	body.call("_update_animation")
	body.call("_update_animation_speed", delta)


func _update_stuck(delta: float) -> void:
	_stuck_timer += delta
	if _stuck_timer < stuck_check_interval:
		return

	var moved := body.global_position.distance_to(_last_stuck_position)
	_last_stuck_position = body.global_position
	_stuck_timer = 0.0

	if moved >= stuck_distance:
		# 恢复移动：退出角落脱困，回到常规逃离
		_stuck_count = 0
		if _state == State.CORNER_ESCAPE:
			_state = State.WALL_AVOID_EVADE
			_repath()
		return

	_stuck_count += 1
	_repath()

	if _stuck_count >= shield_escape_stuck and allow_shield_escape:
		if _try_shield_escape():
			_stuck_count = 0
			return

	if _stuck_count >= corner_stuck_threshold:
		# 连续卡死：进入角落脱困，放大采样半径 + 侧向绕行 + 安全复位
		_state = State.CORNER_ESCAPE
		_relocate_to_navmesh()
		_repath()


func _try_shield_escape() -> bool:
	if shield == null:
		return false
	if not shield.has_method("trigger_if_ready"):
		return false
	return bool(shield.call("trigger_if_ready"))


func _relocate_to_navmesh() -> void:
	var map := body.get_world_3d().navigation_map
	if not map.is_valid():
		return
	# 只纠正水平位置、保留当前高度：腾空（跳跃）时不应被硬拉回地面
	var pos := body.global_position
	var closest := NavigationServer3D.map_get_closest_point(map, pos)
	if Vector2(closest.x - pos.x, closest.z - pos.z).length() > 0.05:
		body.global_position = Vector3(closest.x, pos.y, closest.z)
		body.velocity = Vector3.ZERO


func get_state() -> int:
	return _state


func get_state_name() -> String:
	match _state:
		State.WALL_AVOID_EVADE:
			return "WALL_AVOID_EVADE"
		State.RECOVER:
			return "RECOVER"
		State.CORNER_ESCAPE:
			return "CORNER_ESCAPE"
		_:
			return "DISABLED"
