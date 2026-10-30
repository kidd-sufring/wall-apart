class_name Survivor
extends CharacterBase

# 逃生者：在通用移动基础上增加生命值、受击无敌、逃跑动画和短暂加速。

signal health_changed(current: int, maximum: int)

@export var max_health := 2                # 生命值上限（与 GameManager.SURVIVOR_MAX_HP 一致）
@export var invincible_duration := 2.0     # 受击后的无敌时间
@export var speed_boost_duration := 2.0    # 加速持续时间
@export var speed_boost_multiplier := 1.4  # 加速倍率
@export var invincible_transparency := 0.65   # 无敌虚化透明度
@export var flee_angle_range_deg := 45.0   # AI 逃跑方向相对“正背向”的最大偏角
@export var ai_shield_distance := 2.5      # AI 托管时，与追捕者距离小于该值就释放泡泡护盾

@export_group("战术规避 Tactical Evasion")
@export var evasion_chance := 0.3          # 常规状态的响应触发几率（与 AI 追捕者一致）
@export var alerted_evasion_chance := 0.7  # 被投掷物命中过后的触发几率
@export var evasion_distance := 2.0        # 侧向规避位移距离（米）
@export var evasion_duration := 0.2        # 侧向规避位移时长（秒）
@export var evasion_wall_margin := 0.5     # 侧向射线检测的额外余量，避免规避撞进墙体

var health := 2
var is_evading := false                    # 正在战术规避：期间跳过 AI 与常规移动
var is_alerted := false                    # 高度警觉：被投掷物真实命中过
var is_exposed := false                    # 战术破绽：刚成功规避过，下次触发几率归零

@onready var bubble_shield: SurvivorBubbleShield = get_node_or_null("BubbleShield") as SurvivorBubbleShield
@onready var swae: SurvivorWallAvoidEvade = get_node_or_null("SWAE") as SurvivorWallAvoidEvade

var _invincible_time_left := 0.0
var _boost_time_left := 0.0
var _evasion_tween: Tween = null

var _flee_angle := 0.0                     # 当前逃跑方向的角度偏移
var _flee_angle_timer := 0.0               # 每隔一段时间重新随机一次
var _last_hunter_distance := -1.0          # AI 技能判断用的上一帧追捕者距离

var _ghost_meshes: Array[MeshInstance3D] = []
var _ghost_active := false
var _hit_reaction_pending := false         # 倒地期间被打，等起身再播放逃跑动画

func _ready() -> void:
	super._ready()
	health = max_health
	health_changed.emit(health, max_health)

	# 缓存模型网格，用于无敌期间的闪烁虚化
	for node in model.find_children("*", "MeshInstance3D", true, false):
		_ghost_meshes.append(node as MeshInstance3D)


func _physics_process(delta: float) -> void:
	# 联机下的远端逃生者由 NetworkSync 驱动
	if remote_driven:
		return

	# 战术规避是临时高优先级状态：位移完全由 Tween 驱动，跳过 AI 与常规移动
	if is_evading:
		return

	# 击晕倒地期间跳过 AI 技能与绕墙避让，交给基类只做重力与贴地
	if is_stunned:
		super._physics_process(delta)
		return

	# AI 托管：追捕者进入危险距离时自动释放泡泡护盾
	if not player_controlled:
		_process_ai_shield()

	# AI 托管时由 SWAE 接管绕墙逃离；玩家操控/禁用时走通用控制器
	if swae != null and swae.should_drive():
		swae.physics_step(delta)
		return
	super._physics_process(delta)


# AI 逃生者的技能释放逻辑：距离追捕者足够近且仍在被逼近时立刻开盾
func _process_ai_shield() -> void:
	if bubble_shield == null or ai_target == null:
		return
	if not (ai_target is Hunter):
		return
	if not bubble_shield.is_skill_ready():
		return
	var distance := global_position.distance_to(ai_target.global_position)
	var closing := _last_hunter_distance < 0.0 or distance <= _last_hunter_distance + 0.001
	_last_hunter_distance = distance
	if distance <= ai_shield_distance and closing:
		bubble_shield.trigger_if_ready()


func _update_status(delta: float) -> void:
	# 倒地期间无敌时间暂停：起身后才开始计算受击无敌的倒计时
	if _invincible_time_left > 0.0:
		if not is_stunned:
			_invincible_time_left = maxf(_invincible_time_left - delta, 0.0)
		_set_ghost(true)
	else:
		_set_ghost(false)

	if _boost_time_left > 0.0:
		_boost_time_left = maxf(_boost_time_left - delta, 0.0)

	# AI 托管时，每隔一小段时间重新随机逃跑偏角，避免一直沿固定斜线跑
	if not player_controlled:
		_flee_angle_timer -= delta
		if _flee_angle_timer <= 0.0:
			_flee_angle_timer = randf_range(1.2, 2.4)
			_flee_angle = deg_to_rad(randf_range(-flee_angle_range_deg, flee_angle_range_deg))

func get_speed_multiplier() -> float:
	if _boost_time_left > 0.0:
		return speed_boost_multiplier
	return 1.0

# AI 逃生者始终往远离追捕者的方向跑
func should_flee() -> bool:
	return not player_controlled and ai_target != null

# 在“正背向”的基础上叠加一个随机角度，方向仍保持在远离追捕者的范围内
func get_flee_direction(direct_away: Vector3) -> Vector3:
	return direct_away.rotated(Vector3.UP, _flee_angle)


# 逃生者 AI 的投掷瞄准点：不做提前量预判，直接朝追捕者当前所在方向投出
func _ai_throw_aim_point(target: CharacterBase, _angle: float, _distance: float) -> Vector3:
	return target.global_position

func _update_animation() -> void:
	# 击晕倒地/起身期间由基类独占动画，避免受击加速的逃跑动画抢走
	if is_stunned:
		super._update_animation()
		return
	# 投掷动作播放期间不允许被加速/受击动画打断，否则方法轨会失效
	if is_throwing:
		super._update_animation()
		return
	# 加速期间优先播放逃跑动画
	if _boost_time_left > 0.0:
		_play_anim("flee")
		return
	super._update_animation()

# 无敌期间模型整体虚化（不再闪烁）
func _set_ghost(active: bool) -> void:
	if _ghost_active == active:
		return
	_ghost_active = active
	var transparency := invincible_transparency if active else 0.0
	for mesh in _ghost_meshes:
		mesh.transparency = transparency

# 倒地时清掉残留的受击无敌：倒地期间应该能被追捕者再次命中
func _on_stun_started() -> void:
	_invincible_time_left = 0.0
	_hit_reaction_pending = false
	_set_ghost(false)

# 被追捕者碰撞盒接触时调用
func take_hit(amount: int) -> void:
	# 无敌期间不会重复受击（倒地期间被打后同样进入无敌，避免连续掉血）
	if _invincible_time_left > 0.0:
		return

	health = maxi(health - amount, 0)
	flash_hit()
	_play_hit_sound()
	health_changed.emit(health, max_health)

	# 倒地期间被打：立刻虚化并保持无敌，但倒计时与逃跑动画等起身后再开始
	if is_stunned:
		_invincible_time_left = invincible_duration
		_hit_reaction_pending = true
		return

	_start_hit_reaction()

# 受击反馈：开始无敌倒计时 + 加速逃跑
func _start_hit_reaction() -> void:
	_invincible_time_left = invincible_duration
	_boost_time_left = speed_boost_duration
	_set_ghost(true)
	_play_anim("flee")

# 起身完成：如果倒地期间被打过，这时才播放逃跑动画并开始无敌倒计时
func _on_stun_ended() -> void:
	if not _hit_reaction_pending:
		return
	_hit_reaction_pending = false
	_start_hit_reaction()


# 联机：主机下发血量后由本地应用，并播放受击反馈
func apply_network_hp(value: int) -> void:
	if value >= health:
		return
	health = maxi(value, 0)
	flash_hit()
	_play_hit_sound()
	health_changed.emit(health, max_health)
	if is_stunned:
		_invincible_time_left = invincible_duration
		_hit_reaction_pending = true
		return
	_start_hit_reaction()


# 逃生者受击音效：3D 播放，靠近时更响；与护盾弹开的 &"hit" 用不同音高区分
func _play_hit_sound() -> void:
	AudioManager.play_3d_randomized(&"hit", global_position + Vector3.UP * 1.0,
		-4.0, 0.9, 0.05, 1.0, 6.0, 30.0)


# 伤害入口：追捕者造成伤害前先询问护盾是否拦截（SBS）
func try_block_damage(attacker: Node) -> bool:
	if bubble_shield != null:
		return bubble_shield.try_block_damage(attacker)
	return false


# 供其它系统查询护盾是否可用
func is_shield_active() -> bool:
	return bubble_shield != null and bubble_shield.is_shield_active()


# ---------- 战术规避（与 AI 追捕者同一套判定） ----------

# 当前响应触发几率：破绽（0）> 高度警觉（70%）> 常规（30%）
# 只有 AI 托管且已激活的逃生者会规避；玩家操控时不自动位移
func get_evasion_trigger_chance() -> float:
	if player_controlled or not active:
		return 0.0
	# 空中（跳跃/下落）不参与躲避判定
	if not is_on_floor():
		return 0.0
	# 单人难度覆盖：简单 0%（不躲）、困难 100%（必躲）
	var override := GameManager.get_evasion_chance_override()
	if override >= 0.0:
		return override
	if is_exposed:
		return 0.0
	if is_alerted:
		return alerted_evasion_chance
	return evasion_chance


# 被投掷物真实命中：进入高度警觉，同时清除破绽
func on_projectile_hit() -> void:
	is_alerted = true
	is_exposed = false


# 战术规避成功：产生破绽，下一次面临投掷物时触发几率归零
func on_evasion_success() -> void:
	is_exposed = true


# 掷骰未通过 / 几率为 0：破绽期结束，恢复正常判定
func on_evasion_judged_without_success() -> void:
	is_exposed = false


# 执行战术规避：只用 Tween 直接改变 global_position，不修改 velocity / speed 等常规移动参数
func execute_tactical_evasion(evade_direction: Vector3) -> void:
	if is_evading or is_stunned or is_throwing:
		return
	# 空中不触发躲避：跳跃/下落期间保持原有运动轨迹
	if not is_on_floor():
		return

	var dir := Vector3(evade_direction.x, 0.0, evade_direction.z)
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()

	# 防穿墙：侧向射线被墙挡住就不做规避
	if _is_evasion_blocked(dir):
		return

	is_evading = true

	if _evasion_tween != null and _evasion_tween.is_valid():
		_evasion_tween.kill()
	var target := global_position + dir * evasion_distance
	var duration := maxf(evasion_duration, 0.01)
	# 朝向与位移同步：规避时面朝移动方向（取最短转向角，避免绕远路）
	var target_yaw := atan2(-dir.x, -dir.z)
	var yaw_delta := wrapf(target_yaw - rotation.y, -PI, PI)
	var target_rotation := Vector3(rotation.x, rotation.y + yaw_delta, rotation.z)

	_evasion_tween = create_tween()
	_evasion_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_evasion_tween.set_parallel(true)
	_evasion_tween.tween_property(self, "global_position", target, duration)
	_evasion_tween.tween_property(self, "rotation", target_rotation, duration)
	_evasion_tween.finished.connect(_finish_tactical_evasion)


func _finish_tactical_evasion() -> void:
	is_evading = false
	on_evasion_success()


# 侧向规避是否会被墙体挡住：只对墙层做一次水平射线，忽略地面与角色
func _is_evasion_blocked(dir: Vector3) -> bool:
	var from := global_position + Vector3.UP * 0.9
	var to := from + dir * (evasion_distance + maxf(evasion_wall_margin, 0.0))
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()
