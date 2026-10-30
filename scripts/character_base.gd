class_name CharacterBase
extends CharacterBody3D

# 通用角色控制器：行走/奔跑、重力、跳跃、攀爬和动画切换。
# 玩家操控与 AI 托管共用同一套移动逻辑与坐标系。

## 手上道具发生变化（拾取 / 丢下）时发出
signal item_changed(item: Node3D)

# 从抱物模型提取出来的动画资源，运行时合并进角色自己的 AnimationPlayer
const CARRY_ANIM_PATHS := {
	&"carry_idle": "res://animations/carry_idle.tres",
	&"carry_walk": "res://animations/carry_walk.tres",
	&"carry_run": "res://animations/carry_run.tres",
}
const THROW_ANIM_PATH := "res://animations/throw_item.tres"
const STUN_GETUP_ANIM_PATH := "res://animations/stun_getup.tres"

@export var walk_speed := 3.0              # 行走速度（WASD）
@export var run_speed := 6.0               # 奔跑速度（Shift）
@export var jump_velocity := 4.2           # 起跳初速度
@export var acceleration := 14.0           # 水平加速度
@export var turn_speed := 12.0             # 模型转身平滑速度
@export var climb_speed := 1.0             # 攀爬上升速度
@export var climb_animation_start_time := 0.9  # 跳过攀爬动画开头的下蹲准备
@export var climb_reference_height := 1.5  # 攀爬动画对应的上升高度（与高台一致）
@export var max_climb_height := 1.5        # 单次可攀爬的最大高度
@export var max_climb_trigger_height := 1.6  # 脚部到墙顶超过该高度时不触发攀爬
@export var mantle_speed := 2.5            # 翻越高台边缘的推进速度
@export var mantle_duration := 0.2         # 翻越最长持续时间
@export var model_scale := 1.7             # 模型缩放（原始模型约 1 米高）
@export var model_yaw_offset_deg := 90.0   # 模型正面朝向修正（模型正面为 +X）
@export var animation_speed_min := 0.5     # 动画最低播放倍率
@export var animation_speed_max := 2.5     # 动画最高播放倍率
@export var throw_force := 18.0            # 投掷初速度大小（米/秒）
@export var throw_elevation_deg := 15.0    # 当前投掷仰角（度），默认值保持原来的射程
@export var throw_elevation_min := 0.0     # 滚轮可调到的最小仰角
@export var throw_elevation_max := 60.0    # 滚轮可调到的最大仰角
@export var throw_elevation_step := 3.0    # 每格滚轮改变的仰角
@export var trajectory_step := 0.05        # 轨迹采样时间步长（秒）
@export var trajectory_duration := 2.0     # 轨迹最长预测时长（秒）
@export_flags_3d_physics var trajectory_mask := 15  # 轨迹射线检测的层（Wall|Survivor|Hunter|Ground）
@export var defeat_animation_speed := 2.061  # 倒地+起身整体加速倍率：(5.583-1.4) + 2.0 ≈ 3.0s 播完
@export var defeat_animation_start_time := 1.4  # 倒地动画的播放起点（秒），跳过前面的倒地前摇
@export var hit_slow_duration := 5.0       # 南瓜命中的减速时长；同时是减速层数上限（每层 1 秒）
@export var hit_slow_multiplier := 0.55    # 南瓜命中后的移速倍率
@export var slime_stack_interval := 0.2    # 踩粘液时每叠一层所需的浸泡时间（5 层正好 1 秒）
@export var slime_stack_duration := 1.0    # 每叠一层增加的减速时长（5 层 = 5 秒）
@export var slow_tint_color := Color(1.0, 0.45, 0.0)  # 被南瓜/粘液减速时模型叠加的橙色
@export var web_tint_color := Color(1.0, 1.0, 1.0)    # 被蛛网减速时模型叠加的白色
@export var hit_flash_color := Color(1.0, 0.12, 0.12) # 受击时模型闪红的颜色
@export var hit_flash_duration := 0.5                 # 受击闪红持续时间
@export var slow_tint_max_alpha := 0.55    # 减速满层时叠加色的最大不透明度
@export var item_hand_offset := Vector3(0.0, -0.1, -0.1)  # 手上道具相对两手中点的额外偏移（角色本地空间，Z 为负表示向前）
@export var throw_windup_speed := 2.9167   # 投掷前摇（脱手前）播放倍率：0.583s 前摇 / 2.9167 ≈ 0.2s 脱手
@export var throw_recovery_speed := 2.083  # 投掷收招（脱手后）播放倍率：0.417s 收招 / 2.083 ≈ 0.2s，总时长 0.4s
@export var throw_spin_speed := 15.0       # 投出后空中向前翻滚的角速度（rad/s）
@export var sprint_tap_threshold := 0.25   # 短按 Shift 的判定阈值（秒）：短按=切换奔跑，按住=持续奔跑

@export_group("AI 道具行为")
@export var ai_pickup_radius := 1.5        # AI 跑到道具旁后的实际拾取距离
@export var ai_pickup_seek_radius := 6.0   # AI 发现道具并主动跑过去的距离
@export var ai_seek_timeout := 4.0         # 追击单件道具的超时（秒），防止卡墙
@export var ai_throw_range := 10.0         # AI 主动投掷的最大距离
@export var ai_item_check_interval := 0.25 # AI 道具行为的检测间隔（秒）
@export var ai_throw_angle_min := 0.0      # AI 投掷仰角下限（度）
@export var ai_throw_angle_max := 60.0     # AI 投掷仰角上限（度）

@export_group("脚步声")
@export var footstep_enabled := true       # 是否播放脚步声
@export var footstep_volume_db := -6.0     # 脚步声基础音量
@export var footstep_unit_size := 3.0      # 3D 衰减单位距离（越大传得越远）
@export var footstep_max_distance := 22.0  # 超过该距离不再发声
@export var footstep_pitch_spread := 0.1   # 随机音高幅度（±10%）
@export var footstep_volume_spread := 1.5  # 随机音量幅度（±1.5 dB）

# 只有移动方向接近正对墙面（左右各 45°）时才强制行走
const WALL_HEAD_ON_DOT := 0.7071067811865476

# 减速区域来源，仅用于区分染色（粘液橙色 / 蛛网白色）
enum SlowSource { SLIME, WEB }

var active := false                        # 选择角色后才启用行为
var player_controlled := false             # true = 玩家操控，false = AI
var remote_driven := false                 # 联机：该角色由网络驱动，跳过本地物理
var ai_target: CharacterBase = null        # AI 持续追踪的目标角色
var camera_yaw := 0.0                      # 玩家当前相机水平朝向（AI 读取玩家的值）
var is_run_mode := false                   # 当前是否处于奔跑状态
var _run_toggled := false                  # 单击 Shift 锁定的奔跑状态（再点一次取消）
var _sprint_held := false                  # Shift 当前是否按住
var _sprint_hold_time := 0.0               # 本次按住的时长，用于区分短按与长按
var _sprint_press_cancels := false         # 本次按下是为了取消已锁定的奔跑
var current_item: Node3D = null            # 手上持有的道具（无则为 null）
var is_throwing := false                   # 正在播放投掷动作，期间锁定移动
var is_stunned := false                    # 击晕状态：禁止移动、输入与碰撞
var _carry_idle_hold := false               # 抱物站立时把行走动画定格成待机姿势
var _throw_time_left := 0.0                 # 投掷动作剩余锁定时间
var _hit_slow_time_left := 0.0              # 南瓜减速剩余时间（同时也是减速层数，每层 1 秒）
var _hit_slow_multiplier := 1.0             # 南瓜减速倍率
var _slime_contact_time := 0.0              # 踩在粘液上的浸泡时间，用于累计层数
var _slow_overlay: StandardMaterial3D = null  # 减速时叠加在模型上的橙色材质
var _throw_held := false                    # 投掷键是否按住（松开才真正出手）
var _throw_speed_scale := 1.0               # 投掷动画当前播放倍率（前摇 / 收招两段不同）
var _hold_hand_index := -1                  # 手部旋转参考骨骼（抱物动画生效后采样）
var _hold_hand_ref_basis := Basis.IDENTITY  # 该手骨在基准姿势下的世界旋转，用于计算跟随手的旋转增量
var _hold_ref_pending := false              # 等待采样手部旋转基准
var _hold_ref_delay := 0.0                  # 距离采样还有多久（等抱物动画混合完成）
var _hit_flash_time_left := 0.0             # 受击闪红剩余时间
var _slow_source := SlowSource.SLIME        # 当前减速来自粘液还是蛛网（决定染色）
var _slow_area_frame := -100                # 最近一次踩到减速区域的物理帧
var _ai_hopping := false                    # AI 是否处于自动跳跃的腾空阶段
var _ai_item_timer := 0.0                   # AI 道具行为的下次检测倒计时
var _ai_seek_item: Node3D = null            # AI 正在跑过去拾取的道具
var _ai_seek_scan_timer := 0.0              # 重新搜索道具的间隔计时
var _ai_seek_time_left := 0.0               # 当前追击道具的剩余时间
var _ai_seek_blocked_id := 0                # 追击超时被暂时跳过的道具实例 ID
var _ai_seek_blocked_time := 0.0            # 跳过该道具的剩余时间
var _trajectory: TrajectoryRenderer = null  # 投掷轨迹预览
var _footstep_time := 0.0                   # 距离下一次脚步声的时间累计
var _was_on_floor := true                   # 上一帧是否站在地面，用于检测落地瞬间
var _fall_speed := 0.0                      # 本次下落的最大速度，决定落地音量

var _gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
var _is_climbing := false
var _is_mantling := false                  # 攀爬后翻上平台的短状态
var _mantle_time_left := 0.0
var _mantle_dir := Vector3.ZERO
var _climb_normal := Vector3.ZERO
var _climb_hit_point := Vector3.ZERO       # 起爬时命中的墙面点
var _climb_start_y := 0.0                  # 本次攀爬开始时的脚部高度
var _climb_cooldown := 0.0                 # 攀爬失败后的短暂冷却
var _mantle_start_position := Vector3.ZERO # 翻越开始位置，用于限制位移
var _mantle_distance := 0.0                # 翻越需要移动的最小水平距离
var _current_anim: StringName = &""
var _wall_blocked := false                 # 正面贴墙时强制行走，避免高速穿模

# 停止奔跑时，让收尾动画的播放速度平滑回到正常值
var _stop_anim_scale_time := 0.0
var _stop_anim_scale_total := 0.0
var _stop_anim_scale_value := 1.0

@onready var model: Node3D = $Model
@onready var anim_player: AnimationPlayer = $Model.find_child("AnimationPlayer", true, false) as AnimationPlayer
@onready var climb_check: RayCast3D = $ClimbCheck

var _anims: Dictionary = {}

# 手上的道具每帧对齐到这两个手骨的中点，否则播放抱物/投掷动画时道具会浮在胸前不动
var _skeleton: Skeleton3D = null
var _hand_bones: Array[int] = []

func _ready() -> void:
	# 统一模型尺寸与朝向，使模型正面与角色 -Z 前方一致
	model.scale = Vector3.ONE * model_scale
	model.rotation.y = deg_to_rad(model_yaw_offset_deg)
	_skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	_cache_hand_bones()
	_setup_trajectory_renderer()
	_setup_slow_tint()
	_setup_animations()
	_setup_carry_animations()
	_update_animation()
	_update_animation_speed(0.0)

func _cache_hand_bones() -> void:
	_hand_bones.clear()
	if _skeleton == null:
		return
	for bone_name in ["L_Hand", "R_Hand"]:
		var idx := _skeleton.find_bone(bone_name)
		if idx >= 0:
			_hand_bones.append(idx)

# 动画在 idle 阶段更新骨骼姿态，这里在之后取当帧手骨位置
func _process(delta: float) -> void:
	# 奔跑切换要先于移动逻辑采样，保证同一帧就能按新的奔跑状态计算速度
	_tick_sprint_input(delta)
	# 减速计时与染色放在 _process：AI 由 HWAF/SWAE 接管移动时不会走基类的 _physics_process
	_tick_hit_slow(delta)
	# 投掷锁定计时同样放在 _process，保证 AI 由寻路脚本接管移动时也能正常收招
	if is_throwing:
		_tick_throw(delta)
	# 落地后结束自动跳跃状态（起跳时会重新置位）
	if is_on_floor():
		_ai_hopping = false
	_ai_jump_out_of_slow_zone()
	_ai_item_behavior(delta)
	_tick_landing_sound()
	_tick_footsteps(delta)
	_update_hold_hand_reference(delta)
	_sync_item_to_hands()
	_update_trajectory_preview()

# 落地音：按本次下落高度决定音量，3D 播放自带距离衰减
func _tick_landing_sound() -> void:
	var on_floor := is_on_floor()
	if not on_floor:
		_fall_speed = maxf(_fall_speed, -velocity.y)
	elif not _was_on_floor:
		if not remote_driven and _fall_speed > 1.5:
			var vol := clampf(remap(_fall_speed, 1.5, 12.0, -18.0, -2.0), -18.0, -2.0)
			AudioManager.play_3d_randomized(&"land", global_position, vol, 1.0, 0.06, 1.5, 4.0, 20.0)
		_fall_speed = 0.0
	_was_on_floor = on_floor

# 脚步声：按实际移动速度换算步频，每步随机音高与音量，3D 播放自带方位与距离衰减
func _tick_footsteps(delta: float) -> void:
	if not footstep_enabled or not active or remote_driven or is_stunned:
		return
	if _is_climbing or _is_mantling or is_throwing or not is_on_floor():
		_footstep_time = 0.0
		return

	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < 0.6:  # 站定或极慢移动时不发声
		_footstep_time = 0.0
		return

	# 步频随速度提升：走路约 1.9 步/秒，奔跑约 3.1 步/秒
	var t := clampf((speed - walk_speed) / maxf(run_speed - walk_speed, 0.1), 0.0, 1.0)
	var step_rate := lerpf(1.9, 3.1, t)
	_footstep_time += delta
	if _footstep_time < 1.0 / step_rate:
		return
	_footstep_time = 0.0

	AudioManager.play_3d_randomized(
		&"run",
		global_position + Vector3.UP * 0.12,
		footstep_volume_db,
		1.0,
		footstep_pitch_spread,
		footstep_volume_spread,
		footstep_unit_size,
		footstep_max_distance
	)

# AI：站在减速区域（蛛网 / 南瓜粘液）上时连续起跳，腾空期间不叠层，减少减速持续时间
func _ai_jump_out_of_slow_zone() -> void:
	if player_controlled or not active or ai_target == null:
		return
	if not is_on_floor() or not is_in_slow_area():
		return
	if is_stunned or is_throwing or _is_climbing or _is_mantling:
		return
	# 只增加竖直方向的速度，水平移动仍由原寻路逻辑决定，路线不变
	_ai_hopping = true
	velocity.y = jump_velocity

# AI 道具行为：手上有道具时在 10 米内且无墙体遮挡就投掷；
# 空手时 6 米内发现道具会主动跑过去，靠近到 1.5 米才真正拾取
func _ai_item_behavior(delta: float) -> void:
	if player_controlled or not active or is_stunned or remote_driven:
		_clear_ai_seek_item()
		return
	if is_throwing or _is_climbing or _is_mantling:
		return

	# 手上有道具：按间隔尝试投掷
	if current_item != null and is_instance_valid(current_item):
		_clear_ai_seek_item()
		_ai_item_timer -= delta
		if _ai_item_timer > 0.0:
			return
		_ai_item_timer = maxf(ai_item_check_interval, 0.05)
		_try_ai_throw()
		return

	# 空手：维护“跑向道具”的目标
	_update_ai_seek_item(delta)


# AI 是否正在跑向某件道具
func is_seeking_item() -> bool:
	return _ai_seek_item != null and is_instance_valid(_ai_seek_item)


func _clear_ai_seek_item() -> void:
	_ai_seek_item = null
	_ai_seek_time_left = 0.0


# 6 米内发现道具就跑过去，进入 1.5 米拾取距离后才真正捡起（不做隔空拾取）
func _update_ai_seek_item(delta: float) -> void:
	if not can_pickup_item():
		_clear_ai_seek_item()
		return

	_ai_seek_blocked_time = maxf(_ai_seek_blocked_time - delta, 0.0)

	# 目标被捡走 / 被销毁 / 不可再拾取时放弃
	if _ai_seek_item != null and (not is_instance_valid(_ai_seek_item) or not _is_seek_item_available(_ai_seek_item)):
		_clear_ai_seek_item()

	# 没有目标时按检测间隔重新搜索
	if _ai_seek_item == null:
		_ai_seek_scan_timer -= delta
		if _ai_seek_scan_timer > 0.0:
			return
		_ai_seek_scan_timer = maxf(ai_item_check_interval, 0.05)
		_ai_seek_item = _find_ai_pickup_target()
		if _ai_seek_item == null:
			return
		_ai_seek_time_left = maxf(ai_seek_timeout, 0.1)

	# 跑到拾取距离内才真正拾取
	if _ai_seek_item.global_position.distance_to(global_position) <= ai_pickup_radius:
		if bool(_ai_seek_item.call("try_pickup", self)):
			_clear_ai_seek_item()
		return

	# 长时间追不到（多半被墙挡住）：暂时跳过这件道具，避免反复卡在同一处
	_ai_seek_time_left -= delta
	if _ai_seek_time_left <= 0.0:
		_ai_seek_blocked_id = _ai_seek_item.get_instance_id()
		_ai_seek_blocked_time = maxf(ai_seek_timeout, 1.0)
		_clear_ai_seek_item()


func _is_seek_item_available(item: Node3D) -> bool:
	if not is_instance_valid(item) or not item.has_method("is_available_for_pickup"):
		return false
	if not bool(item.call("is_available_for_pickup", self)):
		return false
	return item.global_position.distance_to(global_position) <= ai_pickup_seek_radius


# 找最近的可拾取道具：需要视线可达，且不在临时跳过的名单里
func _find_ai_pickup_target() -> Node3D:
	var best: Node3D = null
	var best_dist := ai_pickup_seek_radius
	for node in get_tree().get_nodes_in_group("throwable_items"):
		var item := node as Node3D
		if item == null or not is_instance_valid(item):
			continue
		if _ai_seek_blocked_time > 0.0 and item.get_instance_id() == _ai_seek_blocked_id:
			continue
		if not _is_seek_item_available(item):
			continue
		var dist := item.global_position.distance_to(global_position)
		if dist >= best_dist:
			continue
		if not _has_clear_line_to(item.global_position + Vector3.UP * 0.4):
			continue
		best = item
		best_dist = dist
	return best


# 到目标点之间是否有墙体挡路（只检测墙体层）
func _has_clear_line_to(point: Vector3) -> bool:
	var from := global_position + Vector3.UP * 0.9
	var query := PhysicsRayQueryParameters3D.create(from, point, 1, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

# 面向目标（含提前量）投掷：距离 ≤ ai_throw_range 且中间没有墙体遮挡才出手
func _try_ai_throw() -> void:
	if not can_throw():
		return
	var target := _get_ai_item_target()
	if target == null:
		return

	var to_target := target.global_position - global_position
	to_target.y = 0.0
	var distance := to_target.length()
	if distance < 0.1 or distance > ai_throw_range:
		return
	if not _has_clear_throw_path(target):
		return

	# 仰角：按当前水平距离与高差解低抛弹道，再夹到 0~60 度，保证射程够到目标
	var angle := _ai_throw_elevation(distance, target)
	var aim := _ai_throw_aim_point(target, angle, distance)
	var aim_dir := aim - global_position
	aim_dir.y = 0.0
	# AI 的投掷前向就是角色正前方，先把朝向对准目标
	if aim_dir.length_squared() > 0.0001:
		rotation.y = atan2(-aim_dir.x, -aim_dir.z)

	throw_elevation_deg = angle
	_start_throw()

func _get_ai_item_target() -> CharacterBase:
	if ai_target != null and is_instance_valid(ai_target):
		return ai_target
	return get_tree().get_first_node_in_group("Player") as CharacterBase

# AI 投掷的瞄准点：默认按飞行时间对目标做提前量预测，子类可重写
func _ai_throw_aim_point(target: CharacterBase, angle: float, distance: float) -> Vector3:
	var lead_time := distance / maxf(throw_force * cos(deg_to_rad(angle)), 0.1)
	return target.global_position + Vector3(target.velocity.x, 0.0, target.velocity.z) * lead_time

# 投掷路径上是否有不可穿越的墙体（只检测墙体层）
func _has_clear_throw_path(target: CharacterBase) -> bool:
	var from := global_position + Vector3.UP * 1.0
	var to := target.global_position + Vector3.UP * 1.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

# 低抛弹道仰角：tanθ = (v² - sqrt(v⁴ - g(g d² + 2 h v²))) / (g d)
func _ai_throw_elevation(distance: float, target: CharacterBase) -> float:
	var g := maxf(_gravity, 0.1)
	var v2 := throw_force * throw_force
	var height := target.global_position.y - global_position.y
	var disc := v2 * v2 - g * (g * distance * distance + 2.0 * height * v2)
	var angle := 45.0
	if disc >= 0.0 and distance > 0.01:
		angle = rad_to_deg(atan((v2 - sqrt(disc)) / (g * distance)))
	return clampf(angle, ai_throw_angle_min, ai_throw_angle_max)

# 南瓜 / 粘液减速的倒计时、受击闪红计时与染色刷新
func _tick_hit_slow(delta: float) -> void:
	if _hit_slow_time_left > 0.0:
		_hit_slow_time_left = maxf(_hit_slow_time_left - delta, 0.0)
		if _hit_slow_time_left <= 0.0:
			_hit_slow_multiplier = 1.0
	if _hit_flash_time_left > 0.0:
		_hit_flash_time_left = maxf(_hit_flash_time_left - delta, 0.0)
	_update_slow_tint()

# 受击反馈：模型闪红一小段时间
func flash_hit() -> void:
	_hit_flash_time_left = hit_flash_duration

func _sync_item_to_hands() -> void:
	if current_item == null or not is_instance_valid(current_item):
		return
	if _skeleton == null or _hand_bones.is_empty():
		return
	var sum := Vector3.ZERO
	for idx in _hand_bones:
		sum += (_skeleton.global_transform * _skeleton.get_bone_global_pose(idx)).origin
	var hand_center := sum / float(_hand_bones.size())
	var base_basis := global_transform.basis.orthonormalized()

	# 手骨的绝对朝向是骨骼自身的 roll 基准，直接抄给道具会让石头/南瓜歪掉；
	# 这里只跟随「相对基准姿势的旋转增量」：抱物待机时保持正立，挥臂投掷时道具跟着手一起翻转。
	var basis := (_get_hold_hand_delta() * base_basis).orthonormalized()

	# 旋转支点取道具几何中心：原点在底部，需要先算出中心点再反推原点位置
	var half_height := _get_item_half_height()
	var pivot := hand_center + base_basis * item_hand_offset
	current_item.global_transform = Transform3D(basis, pivot - basis * Vector3(0.0, half_height, 0.0))

# 手骨相对拾取瞬间的旋转增量（世界空间）
func _get_hold_hand_delta() -> Basis:
	if _skeleton == null or _hold_hand_index < 0:
		return Basis.IDENTITY
	var now := (_skeleton.global_transform * _skeleton.get_bone_global_pose(_hold_hand_index)).basis.orthonormalized()
	return now * _hold_hand_ref_basis.inverse()

# 拾取瞬间记录手骨世界旋转，作为后续旋转跟随的基准
func _cache_hold_hand_reference() -> void:
	_hold_hand_index = -1
	_hold_hand_ref_basis = Basis.IDENTITY
	if _skeleton == null or _hand_bones.is_empty():
		return
	# 左右手对称，任取一只手作为旋转参考即可
	_hold_hand_index = _hand_bones[0]
	_hold_hand_ref_basis = (_skeleton.global_transform * _skeleton.get_bone_global_pose(_hold_hand_index)).basis.orthonormalized()

# 旋转基准要等抱物姿势稳定后再采样：拾取瞬间还在动画混合过程中，
# 直接采样会把过渡姿势当成基准，导致后续道具被固定转歪一个角度。
func _update_hold_hand_reference(delta: float) -> void:
	if not _hold_ref_pending:
		return
	_hold_ref_delay = maxf(_hold_ref_delay - delta, 0.0)
	if _hold_ref_delay > 0.0:
		return
	_cache_hold_hand_reference()
	_hold_ref_pending = false

# 手上道具的半高（原点在底部时，几何中心相对原点的偏移）
func _get_item_half_height() -> float:
	if current_item == null or not is_instance_valid(current_item):
		return 0.0
	if current_item.has_method("get_hold_height_offset"):
		return -float(current_item.call("get_hold_height_offset"))
	return 0.0

# ---------- 投掷瞄准与轨迹预览 ----------

func _setup_trajectory_renderer() -> void:
	_trajectory = get_node_or_null("Trajectory") as TrajectoryRenderer
	if _trajectory == null:
		_trajectory = TrajectoryRenderer.new()
		_trajectory.name = "Trajectory"
		add_child(_trajectory)

func _unhandled_input(event: InputEvent) -> void:
	if not player_controlled:
		return
	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed:
		return
	if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_adjust_throw_elevation(throw_elevation_step)
	elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_adjust_throw_elevation(-throw_elevation_step)

# 滚轮调整仰角，只有手上有道具时才响应
func _adjust_throw_elevation(delta_deg: float) -> void:
	if current_item == null or not is_instance_valid(current_item):
		return
	throw_elevation_deg = clampf(throw_elevation_deg + delta_deg, throw_elevation_min, throw_elevation_max)

func _get_throw_forward() -> Vector3:
	if player_controlled:
		return Basis(Vector3.UP, camera_yaw) * Vector3.FORWARD
	return -global_transform.basis.z

func _should_show_trajectory() -> bool:
	# 投掷动作播放期间（道具尚未脱手）继续显示轨迹，脱手后才收起
	return player_controlled and current_item != null and is_instance_valid(current_item) \
			and not is_stunned and not _is_climbing and not _is_mantling

# 按当前仰角模拟抛物线，逐段射线检测，命中就截断
func _update_trajectory_preview() -> void:
	if _trajectory == null:
		return
	if not _should_show_trajectory():
		_trajectory.hide_trajectory()
		return

	var item := current_item
	var start := item.global_position + Vector3.UP * _get_item_half_height()
	var dir := _get_throw_forward()
	var elevation := deg_to_rad(throw_elevation_deg)
	var v_horizontal := throw_force * cos(elevation)
	var v_vertical := throw_force * sin(elevation)

	var exclude: Array[RID] = [get_rid()]
	if item is CollisionObject3D:
		exclude.append((item as CollisionObject3D).get_rid())

	var space := get_world_3d().direct_space_state
	var points: Array[Vector3] = [start]
	var hit_actor := false
	var has_hit := false
	var previous := start
	var t := 0.0
	while t < trajectory_duration:
		t += trajectory_step
		var pos := start + dir * v_horizontal * t + Vector3.UP * (v_vertical * t - 0.5 * _gravity * t * t)
		var query := PhysicsRayQueryParameters3D.create(previous, pos, trajectory_mask, exclude)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			points.append(hit["position"])
			var collider = hit["collider"]
			hit_actor = collider is CharacterBase and collider != self
			has_hit = true
			break
		points.append(pos)
		previous = pos

	_trajectory.show_trajectory(points, hit_actor, has_hit)

func _physics_process(delta: float) -> void:
	# 联机下的远端角色由 NetworkSync 驱动，跳过本地物理与动画
	if remote_driven:
		return

	_update_status(delta)

	# 击晕期间完全锁定输入与动画切换，只保留重力让身体贴地
	if is_stunned:
		_apply_gravity(delta)
		move_and_slide()
		return

	_climb_cooldown = maxf(_climb_cooldown - delta, 0.0)

	# 游戏尚未开始：只保留重力，角色保持待机
	if not active:
		_apply_gravity(delta)
		move_and_slide()
		is_run_mode = false
		_update_animation()
		_update_animation_speed(delta)
		return

	# 按住投掷键瞄准（可移动、可滚轮调仰角），松开才真正出手
	if player_controlled and not is_throwing and InputMap.has_action("throw"):
		var throw_pressed := Input.is_action_pressed("throw")
		if throw_pressed:
			if can_throw():
				_throw_held = true
		elif _throw_held:
			_throw_held = false
			if can_throw():
				_start_throw()

	# 投掷不再锁定移动：动作只叠加在动画层，位移照常由移动逻辑处理
	if _is_mantling:
		# 翻越高台边缘时只做脚本位移，动画继续播放攀爬动作
		is_run_mode = false
		_process_mantle(delta)
	else:
		var move_dir := _get_move_direction()
		if _is_climbing:
			is_run_mode = false
			_process_climb(delta, move_dir)
		else:
			_process_move(delta, move_dir)

	_update_animation()
	_update_animation_speed(delta)

# 子类可重写，用于处理受伤、加速等自身状态
func _update_status(_delta: float) -> void:
	pass

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta

# 取“下一个尚未到达的导航路径点”的水平方向。
# 导航代理按 3D 距离判断路径点是否到达，角色跳跃腾空时离地，
# 脚下的路径点永远算“未到达”，直接拿它算方向会导致空中急停甚至倒退，
# 所以这里改成按水平距离跳过已到达的点。
func get_nav_direction(agent: NavigationAgent3D) -> Vector3:
	if agent == null or agent.is_navigation_finished():
		return Vector3.ZERO
	var path := agent.get_current_navigation_path()
	for i in range(agent.get_current_navigation_path_index(), path.size()):
		var to_point := path[i] - global_position
		to_point.y = 0.0
		if to_point.length() > 0.5:
			return to_point.normalized()
	return Vector3.ZERO

func _get_move_direction() -> Vector3:
	# 玩家与 AI 使用同一个移动坐标系：当前玩家相机的水平朝向。
	# AI 角色没有相机，直接读取被追踪玩家角色的相机朝向。
	var reference_yaw := camera_yaw
	if not player_controlled and ai_target != null:
		reference_yaw = ai_target.camera_yaw

	var input_vec := Vector2.ZERO
	if player_controlled:
		input_vec = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		# 没有按住 WASD 但处于奔跑状态（单击 Shift 锁定或按住 Shift）时，默认朝相机前方跑
		if input_vec.length_squared() < 0.01 and (_run_toggled or _sprint_held):
			input_vec = Vector2(0.0, -1.0)
	elif is_seeking_item():
		# AI 跑去捡道具：直接朝道具的世界方向跑，不套用追踪/逃跑方向
		var to_item := _ai_seek_item.global_position - global_position
		to_item.y = 0.0
		if to_item.length_squared() > 0.0025:
			return to_item.normalized()
		return Vector3.ZERO
	elif ai_target:
		var to_target := ai_target.global_position - global_position
		to_target.y = 0.0
		if to_target.length() <= 0.05:
			return Vector3.ZERO
		# AI 处于逃跑状态时远离目标（追捕者），具体方向可由子类加入角度偏移
		if should_flee():
			to_target = -to_target
			to_target = get_flee_direction(to_target)
		# 把 AI 的世界追踪方向转换成与玩家 WASD 一致的相机局部输入
		var local_dir := Basis(Vector3.UP, -reference_yaw) * to_target.normalized()
		input_vec = Vector2(local_dir.x, local_dir.z)

	return _input_to_world(input_vec, reference_yaw)

# 子类可重写：AI 逃生者在逃跑状态下远离追捕者
func should_flee() -> bool:
	return false

# 子类可重写：对“远离目标”的方向做角度偏移
func get_flee_direction(direct_away: Vector3) -> Vector3:
	return direct_away

# 玩家与 AI 共用的输入向量 -> 世界方向转换
func _input_to_world(input_vec: Vector2, reference_yaw: float) -> Vector3:
	if input_vec.length_squared() < 0.01:
		return Vector3.ZERO
	var cam_basis := Basis(Vector3.UP, reference_yaw)
	return (cam_basis * Vector3(input_vec.x, 0.0, input_vec.y)).normalized()

# Shift 奔跑：按住 → 持续奔跑；短按一下 → 锁定奔跑，再短按一次取消。
# 长按后松手即回到走路，不会误锁；已锁定时再按住只是临时取消，松手后不再锁定。
func _tick_sprint_input(delta: float) -> void:
	if not player_controlled or not active:
		_sprint_held = false
		_sprint_hold_time = 0.0
		_sprint_press_cancels = false
		return

	if Input.is_action_just_pressed("sprint"):
		_sprint_held = true
		_sprint_hold_time = 0.0
		# 已经处于锁定奔跑：这次按下用于关闭
		_sprint_press_cancels = _run_toggled
		if _sprint_press_cancels:
			_run_toggled = false
	elif Input.is_action_pressed("sprint"):
		_sprint_held = true
		_sprint_hold_time += delta
	elif _sprint_held:
		# 松手：短按 → 锁定奔跑；长按 → 结束奔跑
		if not _sprint_press_cancels and _sprint_hold_time < sprint_tap_threshold:
			_run_toggled = true
		_sprint_held = false
		_sprint_hold_time = 0.0
		_sprint_press_cancels = false


# 玩家按住 Shift 或已锁定奔跑才奔跑；AI 保持原有持续追踪，使用奔跑速度
func _wants_to_run(has_move_input: bool) -> bool:
	if not has_move_input:
		return false
	if player_controlled:
		return _sprint_held or _run_toggled
	return true

func _process_move(delta: float, move_dir: Vector3) -> void:
	var has_move_input := move_dir.length_squared() > 0.01
	var can_run := _wants_to_run(has_move_input) and not _wall_blocked
	is_run_mode = can_run

	var target_velocity := move_dir * get_current_speed()
	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)

	_apply_gravity(delta)

	# 地面检测通过 is_on_floor()，只有站在地面/高台时才能起跳
	if player_controlled and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
		AudioManager.play_3d_randomized(&"jump", global_position, -6.0, 1.0, 0.06, 1.0, 4.0, 20.0)

	# 贴着高台侧面并朝墙移动时自动进入攀爬
	if _can_start_climb(move_dir):
		_start_climb()
		return

	move_and_slide()
	_update_wall_block(move_dir)

	if move_dir.length_squared() > 0.01:
		_face_direction(move_dir, delta)

# 只有正面（左右各 45° 内）撞墙才强制行走；斜着擦墙仍可奔跑
func _update_wall_block(move_dir: Vector3) -> void:
	var blocked := false
	if move_dir.length_squared() > 0.001:
		var dir := move_dir.normalized()
		for i in range(get_slide_collision_count()):
			var collision := get_slide_collision(i)
			if collision.get_collider() is CharacterBase:
				continue
			var normal := collision.get_normal()
			if absf(normal.y) >= 0.5:
				continue
			if dir.dot(-normal.normalized()) >= WALL_HEAD_ON_DOT:
				blocked = true
				break
	_wall_blocked = blocked

func _can_start_climb(move_dir: Vector3) -> bool:
	if move_dir.length_squared() < 0.01:
		return false
	# 投掷动作尚未收招时不触发攀爬
	if is_throwing:
		return false
	# 只有站在地面/高台上才能起爬：跳跃上升、滞空下落期间一律不触发
	# （velocity.y 判断用于拦住按下跳跃的同一帧，此时 is_on_floor() 仍为 true）
	if not is_on_floor() or velocity.y > 0.1:
		return false
	# 攀爬失败后的冷却期间不再重复起爬
	if _climb_cooldown > 0.0:
		return false
	# 奔跑撞墙时先切回行走，不允许直接以奔跑状态起爬
	if is_run_mode:
		return false
	climb_check.force_raycast_update()
	if not climb_check.is_colliding():
		return false
	var normal := climb_check.get_collision_normal()
	# 只把近似竖直的面当作可攀爬墙面
	if absf(normal.y) > 0.4:
		return false
	# 只有脚部与墙顶的垂直距离小于 1.6m 才允许起爬，
	# 避免在 3m 高墙或 12m 地图边界前反复触发攀爬。
	var hit_point := climb_check.get_collision_point()
	var wall_top_y := _get_wall_top_height(hit_point, normal)
	var top_distance := wall_top_y - global_position.y
	if top_distance <= 0.0 or top_distance >= max_climb_trigger_height:
		return false
	return move_dir.dot(-normal) > 0.3

# 从墙面上方垂直向下探测墙顶高度
func _get_wall_top_height(hit_point: Vector3, normal: Vector3) -> float:
	var from := hit_point - normal * 0.25 + Vector3.UP * 20.0
	var to := from + Vector3.DOWN * 30.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return -INF
	return result.position.y

func _start_climb() -> void:
	_is_climbing = true
	_wall_blocked = false
	_climb_start_y = global_position.y
	_climb_normal = climb_check.get_collision_normal()
	_climb_hit_point = climb_check.get_collision_point()
	velocity = Vector3.ZERO

func _process_climb(delta: float, move_dir: Vector3) -> void:
	# 玩家松开移动键时中断攀爬，自然落下
	if player_controlled and move_dir.length_squared() < 0.01:
		_is_climbing = false
		velocity = Vector3.ZERO
		return

	# 脚部射线不再碰到墙面，说明脚已经高于高台边缘，开始翻越
	if not climb_check.is_colliding():
		_is_climbing = false
		_is_mantling = true
		_mantle_time_left = mantle_duration
		_mantle_dir = -_climb_normal
		_mantle_start_position = global_position
		# 只移动到“胶囊中心刚进入平台边缘”所需的最小距离，避免多余滑行
		var out_dist := (global_position - _climb_hit_point).dot(_climb_normal)
		_mantle_distance = maxf(out_dist + 0.1, 0.2)
		return

	# 超过最大攀爬高度仍未到墙顶，说明墙体过高，无法翻越
	if global_position.y - _climb_start_y >= max_climb_height:
		_fail_climb()
		return

	# 贴着墙面持续向上爬
	velocity = -_climb_normal * 0.8
	velocity.y = climb_speed
	move_and_slide()
	_face_direction(-_climb_normal, delta)

# 攀爬失败：脱离墙面并进入短暂冷却，避免贴墙反复起爬
func _fail_climb() -> void:
	_is_climbing = false
	_climb_cooldown = 0.5
	velocity = _climb_normal * 1.5

# 翻越边缘：只用 move_and_slide 位移，避免瞬移穿进高台
func _process_mantle(delta: float) -> void:
	_mantle_time_left -= delta
	# 只向前推进并让重力自然落地，不再额外向上跳
	velocity = _mantle_dir * mantle_speed
	_apply_gravity(delta)
	move_and_slide()

	var moved := (global_position - _mantle_start_position).dot(_mantle_dir)
	if moved >= _mantle_distance or _mantle_time_left <= 0.0:
		_is_mantling = false
		# 清除翻越残留的水平速度，避免爬完后继续滑行
		velocity.x = 0.0
		velocity.z = 0.0

func _face_direction(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.001:
		return
	# 投掷动作期间锁定出手朝向：AI 由寻路脚本驱动时不会把瞄准方向转走
	if is_throwing:
		return
	# 自动跳跃期间锁定为实际移动方向：空中不按路径方向扭头，避免转弯时横着跳
	if _ai_hopping:
		var moved := Vector3(velocity.x, 0.0, velocity.z)
		if moved.length_squared() < 0.01:
			return
		dir = moved.normalized()
	var target_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, turn_speed * delta)

func get_current_speed() -> float:
	var speed := run_speed if is_run_mode else walk_speed
	return speed * get_speed_multiplier() * get_hit_slow_multiplier()

# 子类可重写，用于受伤后的移动加速
func get_speed_multiplier() -> float:
	return 1.0

func _setup_animations() -> void:
	if anim_player == null:
		return
	# 按名称关键字自动匹配模型自带的动画
	for anim_name in anim_player.get_animation_list():
		var n := String(anim_name).to_lower()
		if n.contains("defeat"):
			_anims["defeat"] = anim_name
		elif n.contains("stun"):
			_anims["stun_getup"] = anim_name
		elif n.contains("climb"):
			_anims["climb"] = anim_name
		elif n.contains("jump"):
			_anims["jump"] = anim_name
		elif n.contains("flee"):
			_anims["flee"] = anim_name
		elif n.contains("walk"):
			_anims["walk"] = anim_name
		elif n.contains("standing") or n.contains("idle"):
			_anims["idle"] = anim_name
		elif n.contains("run"):
			_anims["run"] = anim_name

	# 待机、行走、奔跑、逃跑动画循环播放
	for key in ["idle", "walk", "run", "flee"]:
		if _anims.has(key):
			var anim := anim_player.get_animation(_anims[key])
			if anim:
				anim.loop_mode = Animation.LOOP_LINEAR

	# 倒地动画只播放一次
	if _anims.has("defeat"):
		var defeat_anim := anim_player.get_animation(_anims["defeat"])
		if defeat_anim:
			defeat_anim.loop_mode = Animation.LOOP_NONE

	# 攀爬动画只播放一次；移除 Hip 位移轨道，避免动画抬升与脚本攀爬叠加
	if _anims.has("climb"):
		var climb_anim := anim_player.get_animation(_anims["climb"])
		if climb_anim:
			climb_anim.loop_mode = Animation.LOOP_NONE
			for i in range(climb_anim.get_track_count() - 1, -1, -1):
				if climb_anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
					continue
				var track_path := String(climb_anim.track_get_path(i))
				if track_path.get_slice(":", 1) == "Hip":
					climb_anim.remove_track(i)

# 把抱物 / 投掷动画资源合并进角色自己的 AnimationPlayer
func _setup_carry_animations() -> void:
	if anim_player == null:
		return
	var library := anim_player.get_animation_library(&"")
	if library == null:
		library = AnimationLibrary.new()
		anim_player.add_animation_library(&"", library)
	for key in CARRY_ANIM_PATHS:
		if anim_player.has_animation(key):
			_anims[key] = key
			continue
		var source := load(CARRY_ANIM_PATHS[key]) as Animation
		if source == null:
			continue
		var anim := source.duplicate(true) as Animation
		anim.loop_mode = Animation.LOOP_LINEAR
		library.add_animation(key, anim)
		_anims[key] = key

	# 投掷动画只播放一次，内部带有第 15 帧的 release_item 方法轨
	if not anim_player.has_animation(&"throw_item"):
		var throw_source := load(THROW_ANIM_PATH) as Animation
		if throw_source != null:
			var throw_anim := throw_source.duplicate(true) as Animation
			throw_anim.loop_mode = Animation.LOOP_NONE
			library.add_animation(&"throw_item", throw_anim)
	if anim_player.has_animation(&"throw_item"):
		_anims["throw_item"] = &"throw_item"

	# 起身动画只播放一次
	if not anim_player.has_animation(&"stun_getup"):
		var getup_source := load(STUN_GETUP_ANIM_PATH) as Animation
		if getup_source != null:
			var getup_anim := getup_source.duplicate(true) as Animation
			getup_anim.loop_mode = Animation.LOOP_NONE
			library.add_animation(&"stun_getup", getup_anim)
	if anim_player.has_animation(&"stun_getup"):
		_anims["stun_getup"] = &"stun_getup"

# 供 ThrowableItem 挂载完成后调用：记录手上道具并切换抱物动画
func equip_item(item: Node3D) -> void:
	if current_item != null and is_instance_valid(current_item) and current_item != item:
		return
	current_item = item
	_carry_idle_hold = false
	# 旋转基准等抱物动画混合完成后再采样，避免拾取瞬间道具被转歪
	_hold_ref_pending = true
	_hold_ref_delay = 0.35
	_hold_hand_index = -1
	_hold_hand_ref_basis = Basis.IDENTITY
	# 拾取当帧就贴到手部，避免先出现在 HandAttachment 原位再跳过去
	_sync_item_to_hands()
	item_changed.emit(item)
	# 全局事件：拾取道具（教程等引导逻辑订阅）
	EventBus.item_picked_up.emit(get_item_display_name(item))
	_update_animation()

# 道具显示名（石头 / 南瓜），供事件与 UI 使用
func get_item_display_name(item: Node3D) -> String:
	if item == null:
		return ""
	if item.has_method("get_display_name"):
		return str(item.call("get_display_name"))
	return item.name

# 当前是否满足投掷条件
func can_throw() -> bool:
	return current_item != null and is_instance_valid(current_item) \
			and anim_player != null and anim_player.has_animation(&"throw_item") \
			and not is_stunned and not _is_climbing and not _is_mantling

func _start_throw() -> void:
	is_throwing = true
	_carry_idle_hold = false
	# 出手瞬间面朝相机前方，让出手方向与视线一致
	if player_controlled:
		rotation.y = camera_yaw
	var anim := anim_player.get_animation(_anims["throw_item"]) if anim_player != null else null
	var total := anim.length if anim != null else 1.0
	var release_time := _get_throw_release_time(anim) if anim != null else total * 0.5
	# 前摇慢、收招快：按两段不同倍率换算总锁定时间
	_throw_speed_scale = throw_windup_speed
	_throw_time_left = release_time / maxf(throw_windup_speed, 0.01) \
			+ (total - release_time) / maxf(throw_recovery_speed, 0.01)
	_play_throw_anim()

# 从动画方法轨读取脱手时刻（release_item 的时间点）
func _get_throw_release_time(anim: Animation) -> float:
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) != Animation.TYPE_METHOD:
			continue
		if anim.track_get_key_count(i) > 0:
			return anim.track_get_key_time(i, 0)
	return anim.length * 0.5

func _play_throw_anim() -> void:
	if anim_player == null or not _anims.has("throw_item"):
		return
	var anim_name: StringName = _anims["throw_item"]
	if _current_anim == anim_name and anim_player.is_playing():
		return
	_current_anim = anim_name
	_stop_anim_scale_time = 0.0
	anim_player.speed_scale = _throw_speed_scale
	anim_player.play(anim_name, 0.1)

# 投掷只推进计时，位移与输入由正常的移动逻辑处理，支持边跑边扔
func _tick_throw(delta: float) -> void:
	# 投掷动作播放期间角色朝向持续跟随视角（玩家始终看到背面）
	if player_controlled:
		rotation.y = camera_yaw
	_throw_time_left = maxf(_throw_time_left - delta, 0.0)
	if _throw_time_left <= 0.0:
		is_throwing = false
		# 动画被受击等动作打断、方法轨没触发时兜底，避免道具卡在手上
		if current_item != null and is_instance_valid(current_item):
			release_item()

# 由 Throw_Item 动画的 Call Method Track 在第 15 帧调用
func release_item() -> void:
	var item := current_item
	if item == null or not is_instance_valid(item):
		return
	var item_name := get_item_display_name(item)
	current_item = null
	_carry_idle_hold = false
	item_changed.emit(null)
	# 全局事件：道具脱手（教程等引导逻辑订阅）
	EventBus.item_thrown.emit(item_name)

	var world_parent := get_tree().current_scene
	if world_parent == null:
		world_parent = get_tree().root
	var impulse := _get_throw_impulse(item)
	# 绕角色右轴反向旋转即为向前翻滚；脱手瞬间把角色当前速度也交给投掷物
	var spin_axis := -global_transform.basis.x.normalized()
	if item.has_method("launch"):
		item.launch(world_parent, impulse, self, velocity, spin_axis, throw_spin_speed)

	# 投掷物脱手的挥掷声：石头与南瓜共用
	if item is ThrowableItem:
		AudioManager.play_3d(&"stone_fly", global_position + Vector3.UP * 1.0,
			-4.0, randf_range(0.96, 1.04), 6.0, 26.0)

	# 脱手后切到收招倍率：剩余动画加快播放，锁定时间同步重算
	_throw_speed_scale = throw_recovery_speed
	if anim_player != null and _anims.has("throw_item"):
		anim_player.speed_scale = _throw_speed_scale
		var anim := anim_player.get_animation(_anims["throw_item"])
		if anim != null:
			var release_time := _get_throw_release_time(anim)
			_throw_time_left = maxf((anim.length - release_time) / maxf(throw_recovery_speed, 0.01), 0.05)

func _get_throw_impulse(item: Node3D) -> Vector3:
	var forward := _get_throw_forward()
	var elevation := deg_to_rad(throw_elevation_deg)
	var velocity := forward * (throw_force * cos(elevation)) + Vector3.UP * (throw_force * sin(elevation))
	var mass := 1.0
	if item is RigidBody3D:
		mass = (item as RigidBody3D).mass
	# 乘质量是为了让石头、南瓜的出手速度一致（冲量 / 质量 = 速度）
	return velocity * mass

# 被石头砸中：进入击晕状态，返回是否真正触发（已在击晕中的命中直接忽略）
func apply_stun() -> bool:
	if is_stunned:
		return false
	is_stunned = true

	# 先让子类清理自身状态（如追捕者的幽灵技能），再进入倒地流程
	_on_stun_started()

	# 中断投掷，手上的道具继续留在手节点上，起身后仍可继续抱/扔
	is_throwing = false
	_throw_held = false
	_throw_time_left = 0.0
	_is_climbing = false
	_is_mantling = false
	_carry_idle_hold = false
	is_run_mode = false
	velocity = Vector3.ZERO

	# 倒地期间保留碰撞层：追捕者的 HitBox 仍能命中，可以继续掉血
	_run_stun_sequence()
	return true

# 击晕动画序列：倒地 -> 起身 -> 恢复控制
func _run_stun_sequence() -> void:
	if anim_player != null and _play_stun_anim("defeat", defeat_animation_speed, defeat_animation_start_time):
		await anim_player.animation_finished

	if is_inside_tree() and anim_player != null and _play_stun_anim("stun_getup", defeat_animation_speed):
		await anim_player.animation_finished

	# 恢复输入，切回普通待机/奔跑动画
	is_stunned = false
	velocity = Vector3.ZERO
	_on_stun_ended()
	_update_animation()

# 子类可重写：击晕结束（起身完成）时的额外处理
func _on_stun_ended() -> void:
	pass

func _play_stun_anim(key: String, speed := 1.0, start_time := 0.0) -> bool:
	if anim_player == null or not _anims.has(key):
		return false
	var anim_name: StringName = _anims[key]
	_carry_idle_hold = false
	_current_anim = anim_name
	_stop_anim_scale_time = 0.0
	# 击晕期间不会走 _update_animation_speed，这里的倍率会一直生效到本次动画结束
	anim_player.speed_scale = maxf(speed, 0.01)
	anim_player.play(anim_name, 0.15)
	# 只跳播放起点不改速度：从 start_time 处开始播放剩余部分
	if start_time > 0.0:
		var length := anim_player.get_animation(anim_name).length
		anim_player.seek(clampf(start_time, 0.0, maxf(length, 0.0)), true)
	return true

# 南瓜命中：直接减速（落地/腾空都立即生效）
func apply_slow() -> void:
	_hit_slow_multiplier = hit_slow_multiplier
	_hit_slow_time_left = maxf(_hit_slow_time_left, hit_slow_duration)
	_slow_source = SlowSource.SLIME

# 踩在减速区域（南瓜粘液 / 蛛网）上：每浸泡 slime_stack_interval 秒叠一层减速，
# 剩余秒数即层数（最多 hit_slow_duration 层 ≈ 5 秒）
func add_slow_contact(delta: float, source := SlowSource.SLIME) -> void:
	_slow_area_frame = Engine.get_physics_frames()
	# 空中不叠层：起跳只能避免继续叠加，已经叠上的减速会一直保留
	if not is_on_floor():
		_slime_contact_time = 0.0
		return
	_slime_contact_time += delta
	var interval := maxf(slime_stack_interval, 0.01)
	while _slime_contact_time >= interval:
		_slime_contact_time -= interval
		_slow_source = source
		_hit_slow_multiplier = hit_slow_multiplier
		_hit_slow_time_left = minf(_hit_slow_time_left + slime_stack_duration, hit_slow_duration)

# 离开减速区域：清空浸泡进度，已叠的层数按剩余时间自然衰减
func reset_slow_contact() -> void:
	_slime_contact_time = 0.0

# 当前是否处在减速区域里（最近两帧内有接触），AI 据此判断要不要跳起来躲避
func is_in_slow_area() -> bool:
	return Engine.get_physics_frames() - _slow_area_frame <= 2

# 供技能等外部移动逻辑读取命中减速倍率（例如幽灵状态的直线移动）
# 已叠加的减速在起跳后依然生效，不能靠跳跃直接解除
func get_hit_slow_multiplier() -> float:
	return _hit_slow_multiplier

# ---------- 减速染色 ----------

# 给模型所有网格加一层橙色叠加材质，减速时把它调亮，减速程度越高颜色越深
func _setup_slow_tint() -> void:
	_slow_overlay = StandardMaterial3D.new()
	_slow_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_slow_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_slow_overlay.cull_mode = BaseMaterial3D.CULL_DISABLED
	_slow_overlay.albedo_color = Color(slow_tint_color, 0.0)
	_slow_overlay.emission_enabled = true
	_slow_overlay.emission = slow_tint_color
	_slow_overlay.emission_energy_multiplier = 0.0
	apply_slow_tint_to(model)

# 给指定根节点下的所有网格挂上减速/受击染色（幽灵模型等运行时生成的模型也用它）
func apply_slow_tint_to(root: Node) -> void:
	if _slow_overlay == null or root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_overlay = _slow_overlay

# 受击闪红 > 减速染色（粘液橙色 / 蛛网白色），取优先级最高的一个叠加
func _update_slow_tint() -> void:
	if _slow_overlay == null:
		return
	# 受击：整只角色闪红
	if _hit_flash_time_left > 0.0:
		_apply_slow_tint(hit_flash_color, 1.0)
		return
	# 减速：层数越高颜色越深（起跳腾空也保持染色）
	if _hit_slow_time_left > 0.0 and hit_slow_duration > 0.0:
		var t := clampf(_hit_slow_time_left / hit_slow_duration, 0.0, 1.0)
		var color := web_tint_color if _slow_source == SlowSource.WEB else slow_tint_color
		_apply_slow_tint(color, t)
		return
	_apply_slow_tint(slow_tint_color, 0.0)

func _apply_slow_tint(color: Color, intensity: float) -> void:
	_slow_overlay.albedo_color = Color(color, slow_tint_max_alpha * intensity)
	_slow_overlay.emission = color
	_slow_overlay.emission_energy_multiplier = intensity * 0.6

# 子类可重写：进入击晕时的额外清理（如强制结束技能）
func _on_stun_started() -> void:
	pass

# 子类可重写：当前是否允许拾取道具（如追捕者技能期间禁止拾取）
func can_pickup_item() -> bool:
	return true

# 把手上的道具直接放到地上，不施加冲量（技能开启时自动掉落）
func drop_item() -> void:
	var item := current_item
	if item == null or not is_instance_valid(item):
		return
	current_item = null
	_carry_idle_hold = false
	_throw_held = false
	item_changed.emit(null)

	var world_parent := get_tree().current_scene
	if world_parent == null:
		world_parent = get_tree().root
	if item.has_method("drop"):
		item.drop(world_parent)

func _update_animation() -> void:
	if is_stunned:
		return
	if is_throwing:
		_play_throw_anim()
		return
	if _is_climbing or _is_mantling:
		# 攀爬动画从“开始上攀”的位置播放，跳过开头的下蹲准备
		if _current_anim != _anims.get("climb", &""):
			_play_climb_anim()
		return
	if not is_on_floor():
		_play_anim("jump")
		return

	var planar_speed := Vector2(velocity.x, velocity.z).length()
	# 手上有道具时使用抱物动画
	if current_item != null and is_instance_valid(current_item):
		if planar_speed > walk_speed * 1.25:
			_play_carry("carry_run")
		elif planar_speed > 0.1:
			_play_carry("carry_walk")
		else:
			_play_carry_idle()
		return

	if planar_speed > walk_speed * 1.25:
		_play_anim("run")
	elif planar_speed > 0.1:
		_play_anim("walk")
	else:
		# 从奔跑/行走停下时使用更长的过渡，让人物自然站定
		_play_anim("idle", 0.35)

# 抱物移动动画（走 / 跑）
func _play_carry(key: String) -> void:
	if anim_player == null or not _anims.has(key):
		return
	var anim_name: StringName = _anims[key]
	_carry_idle_hold = false
	if _current_anim == anim_name:
		return
	_current_anim = anim_name
	_stop_anim_scale_time = 0.0
	anim_player.play(anim_name, 0.18)

# 抱物站立：播放抱物行走动画并定格，避免站着时双腿还在迈步
func _play_carry_idle() -> void:
	if anim_player == null or not _anims.has("carry_walk"):
		return
	var anim_name: StringName = _anims["carry_walk"]
	if _current_anim != anim_name:
		_current_anim = anim_name
		_stop_anim_scale_time = 0.0
		anim_player.play(anim_name, 0.25)
	_carry_idle_hold = true

func _play_climb_anim() -> void:
	if anim_player == null or not _anims.has("climb"):
		return
	var anim_name: StringName = _anims["climb"]
	var climb_anim := anim_player.get_animation(anim_name)
	var start_time := clampf(climb_animation_start_time, 0.0, maxf(climb_anim.length - 0.01, 0.0))
	_current_anim = anim_name
	_stop_anim_scale_time = 0.0
	anim_player.play(anim_name, 0.12)
	anim_player.seek(start_time, true)

# 根据实际移动速度调整动画播放倍率，让脚步快慢与位移匹配
func _update_animation_speed(delta: float) -> void:
	if anim_player == null:
		return

	# 投掷动作有自己的前摇 / 收招倍率，不要被移动速度推导覆盖
	if is_throwing:
		anim_player.speed_scale = _throw_speed_scale
		return

	# 抱物站立：动画定格在第一帧，避免原地迈步
	if _carry_idle_hold:
		anim_player.speed_scale = 0.0
		return

	# 停止奔跑的过渡阶段：让正在淡出的动画平滑减速到正常倍率
	if _stop_anim_scale_time > 0.0:
		_stop_anim_scale_time = maxf(_stop_anim_scale_time - delta, 0.0)
		var t := 1.0 - _stop_anim_scale_time / maxf(_stop_anim_scale_total, 0.001)
		anim_player.speed_scale = lerpf(_stop_anim_scale_value, 1.0, clampf(t, 0.0, 1.0))
		return

	var target_scale := 1.0
	if _current_anim == _anims.get("walk", &"") or _current_anim == _anims.get("carry_walk", &""):
		target_scale = Vector2(velocity.x, velocity.z).length() / maxf(walk_speed, 0.1)
	elif _current_anim == _anims.get("run", &"") or _current_anim == _anims.get("flee", &"") or _current_anim == _anims.get("carry_run", &""):
		target_scale = Vector2(velocity.x, velocity.z).length() / maxf(run_speed, 0.1)
	elif _current_anim == _anims.get("climb", &""):
		if not _is_mantling:
			# 攀爬部分动画对应 climb_reference_height 的上升量
			var climb_anim := anim_player.get_animation(_anims["climb"])
			var climb_part_length := maxf(climb_anim.length - climb_animation_start_time, 0.1)
			var design_climb_speed := climb_reference_height / climb_part_length
			target_scale = absf(velocity.y) / maxf(design_climb_speed, 0.05)
	anim_player.speed_scale = clampf(target_scale, animation_speed_min, animation_speed_max)


# 联机：读取当前动画状态（动画资源名 + 播放倍率）供 NetworkSync 下发
func get_anim_state() -> Array:
	if anim_player == null:
		return [&"", 1.0]
	return [_current_anim, anim_player.speed_scale]


# 联机：远端角色直接播放对端发来的动画，不做本地状态推导
func apply_remote_anim(anim: StringName, speed: float) -> void:
	if anim_player == null or anim == &"":
		return
	if _current_anim != anim:
		_current_anim = anim
		_stop_anim_scale_time = 0.0
		anim_player.play(anim, 0.18)
	anim_player.speed_scale = clampf(speed, animation_speed_min, animation_speed_max)


func _play_anim(key: String, blend_time := 0.2) -> void:
	if anim_player == null or not _anims.has(key):
		return
	var anim_name: StringName = _anims[key]
	if _current_anim == anim_name:
		return

	var previous := _current_anim
	_current_anim = anim_name
	# 从奔跑/行走/逃跑切换到待机时，记录当前动画倍率，随过渡平滑恢复
	if anim_name == _anims.get("idle", &"") and (previous == _anims.get("run", &"") or previous == _anims.get("walk", &"") or previous == _anims.get("flee", &"")):
		_stop_anim_scale_total = blend_time
		_stop_anim_scale_time = blend_time
		_stop_anim_scale_value = anim_player.speed_scale
	else:
		_stop_anim_scale_time = 0.0

	anim_player.play(anim_name, blend_time)
