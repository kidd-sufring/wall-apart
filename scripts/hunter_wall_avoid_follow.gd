class_name HunterWallAvoidFollow
extends Node

# HWAF：Hunter Wall-Avoid Follow（追捕者绕墙跟随）
# 只负责 AI 托管追捕者的绕墙跟随；玩家操控时完全让出控制权。
# 穿墙技能/击退可通过 suspend_hwaf() / resume_hwaf() 挂起和恢复（计数式，支持多个来源同时挂起）。
#
# HPI（Hunter Predictive Intercept，预判拦截）是 HWAF 的可选子模块：
# 在 WALL_AVOID_FOLLOW 状态、目标更新计时器触发时，把导航目标从“逃生者当前位置”
# 换成“逃生者未来路径上的可拦截点”，从而在墙角处自然切出斜线抄近路。
# HPI 只改目标点，不参与移动、不新增穿墙逻辑、不改变卡死检测与挂起语义。

enum State {
	WALL_AVOID_FOLLOW,
	SHIELD_AVOID,
	RECOVER,
	DISABLED,
}

@export var ai_enabled := true                  # AI 托管总开关
@export var wall_avoid_follow_enabled := true   # HWAF 专用开关
@export var move_speed := 6.0                   # 追捕者奔跑速度，与角色配置一致
@export var acceleration := 14.0                # 水平加速度
@export var target_update_interval := 0.25      # 重设导航目标的最小间隔
@export var target_repath_distance := 0.5       # 目标移动超过该距离才重新设置
@export var stuck_check_interval := 1.0         # 卡死检测周期
@export var stuck_distance := 0.1               # 周期内位移低于该值视为卡住
@export var max_stuck_checks := 3               # 连续卡住次数达到后重置到最近导航点
@export var recovery_time := 0.5                # 重置后的恢复时间

@export_group("预判拦截 HPI")
@export var predictive_intercept_enabled := true   # HPI 总开关
@export var lookahead_time := 1.0                  # 预判时间（秒），沿逃生者未来路径看的时长
@export var interception_sample_count := 8         # 沿未来路径的采样点数
@export var max_intercept_distance := 12.0         # 拦截点与追捕者的最大水平距离，超过则丢弃
@export var corner_detection_enabled := true       # 是否检测“逃生者即将撞墙转弯”
@export var corner_path_blocked_threshold := 1.2   # 前方被墙阻挡的探测距离（米）
@export var intercept_time_tolerance := 0.15       # 严格可拦截：追捕者到达时间允许略晚于逃生者的容差（秒）
@export var max_intercept_lag := 0.6               # 无严格可拦截点时，允许“落后不超过该秒数”的预判追截点；0 = 只接受严格可拦截
@export var fallback_to_current_target := true     # 无可用拦截点时回退到追逃生者当前位置
@export var max_intercept_nav_offset := 1.5        # 采样点映射到导航网格的最大偏移，超过视为无效
@export var intercept_target_min_change := 1.0     # 新旧拦截点距离小于该值时保持旧目标（防抖）
@export var wall_collision_mask := 1               # 墙体物理层（墙角检测用）
@export var hpi_debug_log := false                 # 打印回退日志，便于调参

@export_group("护盾规避 HSA")
@export var shield_avoidance_enabled := true       # HSA 总开关：护盾期间保持安全距离，不主动撞盾
@export var keep_distance_buffer := 2.0            # 安全距离 = 护盾半径 + 该缓冲（米）
@export var shield_state_check_interval := 0.1     # 护盾状态采样间隔（不逐帧读）
@export var avoid_ring_sample_count := 12          # 环绕采样点数
@export var avoid_ring_extra_radius := 2.0         # 环绕半径在安全距离之外再增加的范围
@export var avoid_openness_radius := 2.0           # 环绕候选点开阔度探测半径
@export var include_braking_margin := true         # 安全距离额外计入刹车距离（用距离而非加速度规避惯性撞盾）
@export var avoid_update_interval := 0.35          # 护盾期环绕目标的评估间隔（独立于 HWAF 的 0.25s）
@export var avoid_target_min_change := 2.0         # 新旧环绕点距离小于该值时保持当前目标，避免来回跳点

@export var agent_path: NodePath = ^"../NavigationAgent3D"

@onready var body: CharacterBase = get_parent() as CharacterBase
@onready var agent: NavigationAgent3D = get_node_or_null(agent_path) as NavigationAgent3D

var _state: int = State.DISABLED
var _suspended := false
var _suspend_count := 0     # 挂起来源计数：击退与穿墙技能可能同时挂起，各自恢复时不能互相放开

var _target: CharacterBase = null
var _target_timer := 0.0
var _last_target_position := Vector3.ZERO

var _last_stuck_position := Vector3.ZERO
var _stuck_timer := 0.0
var _stuck_count := 0
var _recover_timer := 0.0

# HPI 运行状态（不新增外部状态机，仅内部记录）
var _hpi_target := Vector3.ZERO
var _has_hpi_target := false
var _hpi_fallback_count := 0
var _hpi_log_cooldown := 0.0

# HSA 运行状态
var _shield_active := false
var _shield_safe_distance := 0.0
var _shield_check_timer := 0.0
var _shield_avoid_active := false
var _avoid_target := Vector3.ZERO
var _has_avoid_target := false
var _avoid_timer := 0.0

func _ready() -> void:
	# 由 Hunter 的 _physics_process 主动调用 physics_step，避免双重重力/移动
	set_physics_process(false)
	_last_stuck_position = body.global_position if body else Vector3.ZERO

	if agent:
		agent.path_desired_distance = 0.35
		agent.target_desired_distance = 0.7
		agent.radius = 0.6
		agent.height = 1.7
		agent.max_speed = move_speed
		agent.avoidance_enabled = false


func should_drive() -> bool:
	if body != null and body.is_seeking_item():
		# 跑去捡道具时让出移动权，由基类 AI 朝道具移动
		return false
	return (
		ai_enabled
		and wall_avoid_follow_enabled
		and not _suspended
		and _is_ai_hosted()
	)


# AI 被关闭/HWAF 被挂起时，禁止回落到底层 AI 移动，避免和穿墙技能抢控制权
func should_block_base_movement() -> bool:
	return _is_ai_hosted() and (
		not ai_enabled
		or not wall_avoid_follow_enabled
		or _suspended
	)


func _is_ai_hosted() -> bool:
	return body != null and body.active and not body.player_controlled and body.ai_target != null


func physics_step(delta: float) -> void:
	if not should_drive():
		_state = State.DISABLED
		return

	if _hpi_log_cooldown > 0.0:
		_hpi_log_cooldown = maxf(_hpi_log_cooldown - delta, 0.0)

	if _recover_timer > 0.0:
		_state = State.RECOVER
		_recover_timer -= delta
		return

	if agent == null:
		_state = State.DISABLED
		return

	_update_target(delta)
	if _target == null:
		_state = State.DISABLED
		return
	# 护盾规避/复位期间不要覆盖成 FOLLOW，避免状态显示与行为不一致
	if _recover_timer > 0.0:
		_state = State.RECOVER
		return

	_state = State.SHIELD_AVOID if _shield_avoid_active else State.WALL_AVOID_FOLLOW
	# 用水平距离判断路径点是否到达，避免跳跃腾空时路径点永远“未到达”导致急停/倒退
	var direction := body.get_nav_direction(agent)

	var desired := direction * move_speed * body.get_hit_slow_multiplier()
	body.velocity.x = move_toward(body.velocity.x, desired.x, acceleration * delta)
	body.velocity.z = move_toward(body.velocity.z, desired.z, acceleration * delta)

	# 复用角色原有重力与动画更新，不重写角色运动基础逻辑
	body.call("_apply_gravity", delta)
	body.is_run_mode = direction.length_squared() > 0.0001

	body.move_and_slide()

	if direction.length_squared() > 0.0001:
		body.call("_face_direction", direction, delta)

	body.call("_update_animation")
	body.call("_update_animation_speed", delta)

	_update_stuck(delta)


# ---------- 目标更新（HPI 接入点） ----------

func _update_target(delta: float) -> void:
	# ai_target 由 main.gd 在开局时写入；若托管目标变化则重新绑定
	if body.ai_target != null and body.ai_target != _target:
		_target = body.ai_target

	if _target == null:
		_target = get_tree().get_first_node_in_group("player") as CharacterBase

	if _target == null:
		return

	# HSA：每 0.1s 采样一次护盾状态，不逐帧读
	_update_shield_state(delta)
	_shield_avoid_active = _shield_active and shield_avoidance_enabled

	# 护盾激活：暂停 HPI，用独立节奏评估环绕目标（不被逃生者位移触发，避免高频跳点）
	if _shield_avoid_active:
		_avoid_timer -= delta
		if _avoid_timer <= 0.0 or not _has_avoid_target:
			_avoid_timer = maxf(avoid_update_interval, shield_state_check_interval)
			_refresh_avoid_target()
		_has_hpi_target = false
		return

	if _has_avoid_target:
		# 护盾结束：清空环绕目标缓存，下一帧立刻按 HWAF/HPI 重算
		_has_avoid_target = false
		_target_timer = 0.0

	_target_timer -= delta
	var target_now := _target.global_position
	var moved := target_now.distance_to(_last_target_position)

	# 只有计时器到点或目标明显移动时才重新计算，避免逐帧运算
	if _target_timer > 0.0 and moved < target_repath_distance:
		return

	_target_timer = target_update_interval
	_last_target_position = target_now

	var goal := target_now
	var intercept: Variant = null
	if predictive_intercept_enabled:
		intercept = choose_intercept_target()

	if intercept != null:
		goal = intercept
		# 防抖：新拦截点与当前拦截点距离太近时沿用旧目标
		if _has_hpi_target and goal.distance_to(_hpi_target) < maxf(intercept_target_min_change, 0.01):
			goal = _hpi_target
		_hpi_target = goal
		_has_hpi_target = true
		_hpi_fallback_count = 0
	elif fallback_to_current_target:
		_hpi_target = target_now
		_has_hpi_target = false
		_register_hpi_fallback()
	else:
		# 关闭回退时保持当前导航目标不变，等待下一次可拦截点
		return

	agent.target_position = goal


func _register_hpi_fallback() -> void:
	_hpi_fallback_count += 1
	if not hpi_debug_log:
		return
	if _hpi_fallback_count >= 3 and _hpi_log_cooldown <= 0.0:
		print("[HPI] 连续 %d 次没有可用拦截点，回退追当前点（可调小 lookahead_time 或调大 max_intercept_distance）" % _hpi_fallback_count)
		_hpi_log_cooldown = 5.0


# ---------- HPI：预判拦截 ----------

# 逃生者未来路径：优先读取 AI 逃生者的导航路径，否则用水平速度线性预测
func get_survivor_predicted_path() -> PackedVector3Array:
	var points := PackedVector3Array()
	if _target == null:
		return points

	var speed := _get_survivor_speed()
	var max_len := maxf(speed * maxf(lookahead_time, 0.05), 0.5)

	# 1) AI 托管逃生者且导航路径可用：取“最近点之后”的一段
	if not _target.player_controlled:
		var survivor_agent := _target.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
		if survivor_agent != null:
			points = _path_after_survivor(survivor_agent, max_len)
			if points.size() >= 2:
				return points

	# 2) 玩家操控或没有可用路径：按水平速度/朝向线性预测
	points.clear()
	var velocity := _target.velocity
	velocity.y = 0.0
	var dir := -_target.global_transform.basis.z
	if velocity.length_squared() > 0.04:
		dir = velocity.normalized()

	var origin := _target.global_position
	points.append(origin)
	points.append(origin + dir * max_len)
	return points


# 截取逃生者导航路径中位于其当前位置之后、长度不超过 max_len 的一段
func _path_after_survivor(survivor_agent: NavigationAgent3D, max_len: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	var nav_path := survivor_agent.get_current_navigation_path()
	if nav_path.size() < 2:
		return points

	var nearest := 0
	var best := INF
	for i in nav_path.size():
		var d := nav_path[i].distance_to(_target.global_position)
		if d < best:
			best = d
			nearest = i

	# 路径已全部走过（最近点是终点）：交给线性预测
	if nearest >= nav_path.size() - 1:
		return points

	points.append(_target.global_position)
	var last := _target.global_position
	var total := 0.0
	for i in range(nearest + 1, nav_path.size()):
		var point := nav_path[i]
		total += last.distance_to(point)
		last = point
		points.append(point)
		if total >= max_len:
			break
	return points


# 沿未来路径均匀采样，映射到导航网格并评估“是否来得及拦截”
func sample_intercept_candidates() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var map := body.get_world_3d().navigation_map
	if not map.is_valid():
		return result

	var polyline := get_survivor_predicted_path()
	if polyline.size() < 2:
		return result

	var segments: Array[float] = []
	var total_len := 0.0
	for i in range(1, polyline.size()):
		var seg := polyline[i - 1].distance_to(polyline[i])
		segments.append(seg)
		total_len += seg
	if total_len < 0.05:
		return result

	var speed := _get_survivor_speed()
	var count: int = maxi(interception_sample_count, 2)

	for i in count:
		var eta := lookahead_time * float(i) / float(count - 1)
		var raw := _point_along_polyline(polyline, segments, minf(eta * speed, total_len))
		var mapped := NavigationServer3D.map_get_closest_point(map, raw)

		# 必须落在有效导航网格上（空洞/边界外直接丢弃）
		if raw.distance_to(mapped) > max_intercept_nav_offset:
			continue
		# 超出追捕者最大预判距离
		if body.global_position.distance_to(mapped) > max_intercept_distance:
			continue
		# 去重，避免末端采样点堆在一起
		var duplicate := false
		for c in result:
			var existing: Vector3 = c["point"]
			if existing.distance_to(mapped) < 0.3:
				duplicate = true
				break
		if duplicate:
			continue

		var candidate := evaluate_candidate(mapped, eta)
		if not candidate.is_empty():
			result.append(candidate)

	return result


# 评估单个候选点：逃生者到达时间、追捕者沿导航路径的到达时间、是否来得及拦截
func evaluate_candidate(point: Vector3, survivor_eta: float) -> Dictionary:
	var map := body.get_world_3d().navigation_map
	if not map.is_valid():
		return {}

	var path := NavigationServer3D.map_get_path(map, body.global_position, point, true)
	if path.is_empty():
		return {}
	if path[path.size() - 1].distance_to(point) > 1.0:
		return {}

	var length := 0.0
	var prev := body.global_position
	for p in path:
		length += prev.distance_to(p)
		prev = p

	var hunter_eta := length / maxf(move_speed, 0.1)
	return {
		"point": point,
		"survivor_eta": survivor_eta,
		"hunter_eta": hunter_eta,
		"interceptable": hunter_eta <= survivor_eta + intercept_time_tolerance,
	}


# 逃生者是否即将撞墙转弯：沿其水平速度方向做一次短射线
func is_survivor_near_corner() -> bool:
	if not corner_detection_enabled or _target == null:
		return false

	var velocity := _target.velocity
	velocity.y = 0.0
	var dir := -_target.global_transform.basis.z
	if velocity.length_squared() > 0.04:
		dir = velocity.normalized()

	var from := _target.global_position + Vector3.UP * 0.9
	var to := from + dir * maxf(corner_path_blocked_threshold, 0.2)
	var query := PhysicsRayQueryParameters3D.create(from, to, wall_collision_mask, [_target.get_rid()])
	var hit := _target.get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()


# 选出 HPI 目标：
# 一级优先“严格可拦截点”（追捕者能在逃生者到达前/同时到达）；
# 若一个都没有，退到二级“可预判追截点”（落后不超过 max_intercept_lag 秒）；
# 仍然没有则返回 null，由调用方回退追当前位置。
# 逃生者即将转弯时，优先取预测路径后半段（转角之后的点）。
func choose_intercept_target() -> Variant:
	var candidates := sample_intercept_candidates()
	if candidates.is_empty():
		return null

	var usable: Array[Dictionary] = []
	for c in candidates:
		if bool(c["interceptable"]):
			usable.append(c)

	if usable.is_empty():
		if max_intercept_lag <= 0.0:
			return null
		for c in candidates:
			var gap := float(c["hunter_eta"]) - float(c["survivor_eta"])
			if gap <= max_intercept_lag:
				usable.append(c)
	if usable.is_empty():
		return null

	# 转角：优先取预测路径后半段（转角之后的点），让导航网格自然切斜线
	if is_survivor_near_corner():
		var after_corner: Array[Dictionary] = []
		for c in usable:
			if float(c["survivor_eta"]) >= lookahead_time * 0.5:
				after_corner.append(c)
		if not after_corner.is_empty():
			usable = after_corner

	# 依次比较：到达时间差最小者优先；差距接近时取更靠前的点（预判量更大）
	var best := usable[0]
	for c in usable:
		var gap := float(c["hunter_eta"]) - float(c["survivor_eta"])
		var best_gap := float(best["hunter_eta"]) - float(best["survivor_eta"])
		if gap < best_gap - 0.05:
			best = c
		elif absf(gap - best_gap) <= 0.05 and float(c["survivor_eta"]) > float(best["survivor_eta"]):
			best = c
	return best["point"]


# 逃生者当前移动速度（用于把预判时间换算成路径长度）
func _get_survivor_speed() -> float:
	if _target != null and _target.has_method("get_current_speed"):
		return maxf(float(_target.call("get_current_speed")), 0.1)
	return maxf(move_speed, 0.1)


# 按折线弧长取点
func _point_along_polyline(points: PackedVector3Array, segments: Array[float], distance: float) -> Vector3:
	var remain := distance
	for i in segments.size():
		var seg := segments[i]
		if remain <= seg:
			return points[i].lerp(points[i + 1], remain / maxf(seg, 0.001))
		remain -= seg
	return points[points.size() - 1]


# ---------- HSA：追捕者护盾规避 ----------

# 每 shield_state_check_interval 秒读一次逃生者 SBS 状态，不逐帧读
func _update_shield_state(delta: float) -> void:
	if not shield_avoidance_enabled or _target == null:
		_shield_active = false
		_shield_safe_distance = 0.0
		return

	_shield_check_timer -= delta
	if _shield_check_timer > 0.0:
		return
	_shield_check_timer = maxf(shield_state_check_interval, 0.01)

	var shield := _get_target_shield()
	if shield == null:
		_shield_active = false
		_shield_safe_distance = 0.0
		return

	var active := false
	if shield.has_method("is_shield_active"):
		active = bool(shield.call("is_shield_active"))
	_shield_active = active

	if active:
		var radius := 1.0
		if shield.has_method("get_shield_radius"):
			radius = float(shield.call("get_shield_radius"))
		var safe := radius + maxf(keep_distance_buffer, 0.0)
		if include_braking_margin:
			# 刹车距离 = v² / (2a)：只读取现有速度与加速度来放大安全距离，不修改加速度
			safe += (move_speed * move_speed) / (2.0 * maxf(acceleration, 0.1))
		_shield_safe_distance = safe
	else:
		_shield_safe_distance = 0.0


# 只读：逃生者身上的 SBS 节点（缺失则视为没有护盾）
func _get_target_shield() -> Node:
	if _target == null:
		return null
	return _target.get_node_or_null("BubbleShield")


# 环绕采样：在 [safe, safe+extra] 环带上找“离追捕者近、开阔、且在安全距离外”的点
func _choose_shield_avoid_target() -> Variant:
	if _target == null:
		return null
	var map := body.get_world_3d().navigation_map
	if not map.is_valid():
		return null

	var survivor_pos := _target.global_position
	var safe := maxf(_shield_safe_distance, 0.5)
	var ring := safe + maxf(avoid_ring_extra_radius, 0.1) * 0.5
	var inside_safe := body.global_position.distance_to(survivor_pos) < safe

	var count: int = maxi(avoid_ring_sample_count, 4)
	var best := Vector3.ZERO
	var best_score := -INF
	var found := false

	for i in count:
		var angle := TAU * float(i) / float(count)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var raw := survivor_pos + dir * ring
		var mapped := NavigationServer3D.map_get_closest_point(map, raw)

		# 必须落在有效导航网格上，且映射后仍在安全距离外
		if raw.distance_to(mapped) > max_intercept_nav_offset:
			continue
		var dist := mapped.distance_to(survivor_pos)
		if dist < safe:
			continue
		if not _is_nav_reachable(map, mapped):
			continue

		# 评分：离追捕者近（少跑路）+ 开阔 +（已在安全距离内时）离逃生者越远越好
		var score := -body.global_position.distance_to(mapped)
		score += float(_nav_openness(map, mapped)) * 0.5
		score += dist * (2.0 if inside_safe else 0.2)
		if score > best_score:
			best_score = score
			best = mapped
			found = true

	if found:
		return best

	# 退化：朝远离逃生者的方向找一个最近可达点；仍不可达则交给 RECOVER
	var away := body.global_position - survivor_pos
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = -_target.global_transform.basis.z
	away = away.normalized()
	var fallback_raw := body.global_position + away * 2.0
	var fallback := NavigationServer3D.map_get_closest_point(map, fallback_raw)
	if fallback_raw.distance_to(fallback) <= max_intercept_nav_offset and _is_nav_reachable(map, fallback):
		return fallback
	return null


# 刷新环绕目标：方案 A —— 独立节奏评估 + 目标保持，避免环点来回跳
func _refresh_avoid_target(force: bool = false) -> void:
	var point: Variant = _choose_shield_avoid_target()
	if point == null:
		# 环绕点全不可达：复位到最近导航点并进入 RECOVER（沿用既有兜底语义）
		_has_avoid_target = false
		_reset_to_closest_nav_point()
		return

	var new_point: Vector3 = point

	# 当前环绕点仍然有效、且新点几乎同向/同位置时保持不动
	if not force and _has_avoid_target and _is_avoid_target_valid():
		var step := TAU / float(maxi(avoid_ring_sample_count, 4))
		var same_slot := new_point.distance_to(_avoid_target) < maxf(avoid_target_min_change, 0.01)
		var same_dir := _angle_from_survivor(new_point, _avoid_target) < step * 1.05
		if same_slot or same_dir:
			return

	_avoid_target = new_point
	_has_avoid_target = true
	agent.target_position = new_point


# 当前环绕目标是否仍可用：仍在安全距离外且沿导航网格可达
func _is_avoid_target_valid() -> bool:
	if not _has_avoid_target or _target == null:
		return false
	if _avoid_target.distance_to(_target.global_position) < _shield_safe_distance:
		return false
	var map := body.get_world_3d().navigation_map
	if not map.is_valid():
		return false
	return _is_nav_reachable(map, _avoid_target)


# 两个点相对逃生者的方向夹角（水平面）
func _angle_from_survivor(a: Vector3, b: Vector3) -> float:
	if _target == null:
		return PI
	var da := a - _target.global_position
	var db := b - _target.global_position
	da.y = 0.0
	db.y = 0.0
	if da.length_squared() < 0.0001 or db.length_squared() < 0.0001:
		return PI
	return absf(da.normalized().angle_to(db.normalized()))


func _is_nav_reachable(map: RID, point: Vector3) -> bool:
	var path := NavigationServer3D.map_get_path(map, body.global_position, point, true)
	if path.is_empty():
		return false
	return path[path.size() - 1].distance_to(point) <= 1.0


# 开阔度：候选点四周探测导航网格是否依然存在（0~4）
func _nav_openness(map: RID, point: Vector3) -> int:
	var open := 0
	var radius := maxf(avoid_openness_radius, 0.5)
	for i in 4:
		var angle := TAU * float(i) / 4.0
		var probe := point + Vector3(cos(angle), 0.0, sin(angle)) * radius
		if probe.distance_to(NavigationServer3D.map_get_closest_point(map, probe)) <= 0.5:
			open += 1
	return open


# ---------- 卡死与恢复（逻辑保持不变） ----------

func _update_stuck(delta: float) -> void:
	if _target == null or agent == null:
		return

	# 已经贴近目标时静止是正常行为（两个胶囊半径合计约 1m，无法再靠近），不判卡死
	if body.global_position.distance_to(_target.global_position) <= agent.target_desired_distance + 0.5:
		_stuck_timer = 0.0
		_stuck_count = 0
		return

	_stuck_timer += delta
	if _stuck_timer < stuck_check_interval:
		return

	var moved := body.global_position.distance_to(_last_stuck_position)
	_last_stuck_position = body.global_position
	_stuck_timer = 0.0

	if moved >= stuck_distance:
		_stuck_count = 0
		return

	_stuck_count += 1
	_target_timer = 0.0
	if _shield_avoid_active:
		# 护盾期间不要把目标设回逃生者身上，否则会直接撞盾；卡死时强制换一个环绕点
		_avoid_timer = 0.0
		_refresh_avoid_target(true)
	else:
		agent.target_position = _target.global_position

	if _stuck_count >= max_stuck_checks:
		_reset_to_closest_nav_point()


func _reset_to_closest_nav_point() -> void:
	var map_rid := body.get_world_3d().navigation_map
	if map_rid.is_valid():
		var closest := NavigationServer3D.map_get_closest_point(map_rid, body.global_position)
		body.global_position = closest + Vector3(0.0, 0.05, 0.0)
		body.velocity = Vector3.ZERO

	_stuck_count = 0
	_stuck_timer = 0.0
	_recover_timer = recovery_time
	_target_timer = 0.0
	_avoid_timer = 0.0
	_has_hpi_target = false
	_has_avoid_target = false
	_state = State.RECOVER


func suspend_hwaf() -> void:
	# 穿墙技能/击退期间调用：停止读取目标、停止寻路、停止移动驱动（HPI 一并停止）
	# 计数式挂起：两个来源都恢复后才真正放开，否则会出现 HWAF 与技能同时驱动、速度翻倍
	_suspend_count += 1
	_suspended = true
	_state = State.DISABLED


func resume_hwaf() -> void:
	_suspend_count = maxi(_suspend_count - 1, 0)
	if _suspend_count > 0:
		return
	_suspended = false
	_stuck_count = 0
	_stuck_timer = 0.0
	_recover_timer = 0.0
	_target_timer = 0.0
	_shield_check_timer = 0.0        # 恢复后立刻重新采样护盾状态
	_avoid_timer = 0.0
	_shield_avoid_active = false
	_has_hpi_target = false
	_has_avoid_target = false
	_state = State.DISABLED


# 供穿墙等技能使用：判断 HWAF 当前是否处于挂起状态
func is_suspended() -> bool:
	return _suspended


func get_state() -> int:
	return _state


func get_state_name() -> String:
	match _state:
		State.WALL_AVOID_FOLLOW:
			return "WALL_AVOID_FOLLOW"
		State.SHIELD_AVOID:
			return "SHIELD_AVOID"
		State.RECOVER:
			return "RECOVER"
		_:
			return "DISABLED"
