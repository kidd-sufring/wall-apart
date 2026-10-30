class_name Hunter
extends CharacterBase

# 追捕者：移动逻辑复用通用控制器。
# 不做攻击动作/动画，只通过 HitBox(Area3D) 与逃生者重叠来触发伤害。
# AI 托管时由 HWAF 子节点接管绕墙跟随；玩家操控时完全让出控制权。
# 另外提供通用击退接口，供逃生者泡泡护盾等技能调用。

@onready var hit_box: Area3D = $HitBox
@onready var hwaf: HunterWallAvoidFollow = $HWAF
@onready var ghost_skill: HunterGhostSkill = $GhostSkill

@export_group("战术规避 Tactical Evasion")
@export var base_evasion_chance := 0.3     # 常规状态的响应触发几率
@export var alerted_evasion_chance := 0.7  # 高度警觉状态的响应触发几率
@export var evasion_distance := 2.0        # 侧向规避位移距离（米）
@export var evasion_duration := 0.2        # 侧向规避位移时长（秒）
@export var evasion_wall_margin := 0.5     # 侧向射线检测的额外余量，避免规避撞进墙体

var is_evading := false                # 正在执行战术规避：期间完全跳过常规移动
var is_alerted := false                # 高度警觉：被投掷物真实命中过
var is_exposed := false                # 战术破绽：刚成功规避过，下次触发几率归零

var _knockback_active := false
var _knockback_dir := Vector3.ZERO
var _knockback_speed := 0.0
var _knockback_remaining := 0.0
var _knockback_time_left := 0.0

var _evasion_tween: Tween = null       # 战术规避的位移 Tween

# 目标倒地后主动贴近的距离：HitBox(r0.6) + 逃生者胶囊(r0.5) 需要中心距 1.1 米内才判定命中
const STUN_PRESS_DISTANCE := 0.9

func _physics_process(delta: float) -> void:
	# 战术规避是临时高优先级状态：直接截断常规移动，位移完全由 Tween 驱动
	if is_evading:
		return

	# 联机下的远端追捕者由 NetworkSync 驱动
	if remote_driven:
		return

	# 击晕倒地期间跳过击退/寻路与抓人判定，交给基类只做重力与贴地
	if is_stunned:
		super._physics_process(delta)
		return

	_update_ghost_item_lock()

	if _knockback_active:
		# 击退优先：期间暂停 HWAF 寻路与基础 AI 移动
		_process_knockback(delta)
	elif _press_stunned_target(delta):
		# 目标倒地：主动贴到命中距离，保证这一次受击能打出来
		pass
	elif hwaf != null and hwaf.should_drive():
		# HWAF 接管 AI 移动；不再调用基础 AI 移动，避免双重驱动
		hwaf.physics_step(delta)
	elif hwaf != null and hwaf.should_block_base_movement():
		# HWAF 被禁用/挂起时停止底层 AI 移动，给穿墙技能留出控制权
		pass
	else:
		super._physics_process(delta)

	if not active:
		return

	## 只要碰撞盒与逃生者重叠就触发受伤逻辑，重复受击由逃生者无敌时间拦截
	for body in hit_box.get_overlapping_bodies():
		if body is Survivor:
			var survivor := body as Survivor
			if NetworkManager.is_online():
				# 联机：上报给主机，由主机统一扣血（远端的护盾状态不同步）
				NetworkManager.report_hit()
				continue
			if survivor.try_block_damage(self):
				continue
			survivor.take_hit(1)


# 幽灵技能期间始终不允许持有道具：开启瞬间就把手上的东西放到地上
func _update_ghost_item_lock() -> void:
	if ghost_skill != null and ghost_skill.is_ghost_active() and current_item != null:
		drop_item()


# 幽灵状态下禁止拾取投掷物
func can_pickup_item() -> bool:
	return ghost_skill == null or not ghost_skill.is_ghost_active()


# 被石头砸中时先强制结束幽灵技能，再走击倒动画
func _on_stun_started() -> void:
	if ghost_skill != null and ghost_skill.is_ghost_active():
		ghost_skill.force_end()


# 幽灵状态免疫投掷物：飞行中的投掷物会直接穿过身体（由 ThrowableItem 每帧同步碰撞例外）
func is_projectile_immune() -> bool:
	return ghost_skill != null and ghost_skill.is_ghost_active()


# AI 托管时目标倒地：主动贴到攻击距离内再把人打掉。
# HWAF 的寻路停止距离是 0.7 米，目标站着不动时追捕者常停在 1.2 米左右，
# HitBox 刚好够不到，表现成"站在旁边不攻击"。
# 返回 true 表示本帧移动已由这里接管。
func _press_stunned_target(delta: float) -> bool:
	if player_controlled or not active or ai_target == null or is_stunned:
		return false
	if not ai_target.is_stunned:
		return false

	var to_target := ai_target.global_position - global_position
	to_target.y = 0.0
	var distance := to_target.length()
	if distance <= STUN_PRESS_DISTANCE:
		# 已在命中范围内，把移动权交回 HWAF
		return false

	var direction := to_target / maxf(distance, 0.001)
	var speed := get_current_speed()
	velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * delta)
	_apply_gravity(delta)
	move_and_slide()
	_face_direction(direction, delta)
	_update_animation()
	_update_animation_speed(delta)
	return true


# 通用击退接口：水平方向物理移动，不瞬移、不穿墙
func apply_knockback(direction: Vector3, distance: float, speed: float, max_duration: float) -> void:
	var dir := Vector3(direction.x, 0.0, direction.z)
	if dir.length_squared() < 0.0001:
		return
	if _knockback_active:
		return

	_knockback_dir = dir.normalized()
	_knockback_speed = maxf(speed, 0.01)
	_knockback_remaining = maxf(distance, 0.0)
	_knockback_time_left = maxf(max_duration, 0.01)
	_knockback_active = true
	is_run_mode = false

	# 挂起 HWAF（计数式）：幽灵技能同时挂起时，这里的恢复不会把它放开
	if hwaf != null:
		hwaf.suspend_hwaf()


func _process_knockback(delta: float) -> void:
	_knockback_time_left -= delta

	var before := global_position
	velocity.x = _knockback_dir.x * _knockback_speed
	velocity.z = _knockback_dir.z * _knockback_speed
	_apply_gravity(delta)
	move_and_slide()
	_update_animation()
	_update_animation_speed(delta)

	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_knockback_remaining -= moved

	# 到达距离、超时或撞墙都会提前结束
	if _knockback_remaining <= 0.05 or _knockback_time_left <= 0.0 or is_on_wall():
		_end_knockback()


func _end_knockback() -> void:
	_knockback_active = false
	velocity.x = 0.0
	velocity.z = 0.0

	# 计数式恢复：幽灵技能仍在挂起时 HWAF 保持挂起，避免双驱动导致速度翻倍
	if hwaf != null:
		hwaf.resume_hwaf()


func is_knocked_back() -> bool:
	return _knockback_active


# 当前响应触发几率：破绽（0）> 高度警觉（70%）> 常规（30%）
# 只有 AI 托管且已激活的追捕者会规避；玩家操控时不自动位移（与逃生者一致）
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
	return base_evasion_chance


# 被投掷物真实命中：进入高度警觉，同时清除破绽
func on_projectile_hit() -> void:
	is_alerted = true
	is_exposed = false
	_play_alert_sound()


# 战术规避成功：产生破绽，下一次面临投掷物时触发几率归零
func on_evasion_success() -> void:
	is_exposed = true


# 掷骰未通过 / 几率为 0：破绽期结束，恢复正常判定
func on_evasion_judged_without_success() -> void:
	is_exposed = false


# 执行战术规避：只用 Tween 直接改变 global_position，绝不修改 velocity / speed 等常规移动参数。
# 规避期间 _physics_process 会在最开头 return，常规移动被完全截断。
func execute_tactical_evasion(evade_direction: Vector3) -> void:
	if is_evading:
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
	_play_evasion_sound()

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


# 规避音效：项目里没有现成音频资源，这里用代码合成一段短促的风啸声
func _play_evasion_sound() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.current_scene
	if root == null:
		root = tree.root
	var player := AudioStreamPlayer3D.new()
	player.stream = _get_evasion_sound()
	player.volume_db = -6.0
	player.unit_size = 5.0
	player.max_distance = 20.0
	root.add_child(player)
	player.global_position = global_position
	player.finished.connect(player.queue_free)
	player.play()

static var _evasion_sound: AudioStreamWAV = null

static func _get_evasion_sound() -> AudioStreamWAV:
	if _evasion_sound != null:
		return _evasion_sound
	const RATE := 22050
	var count := int(RATE * 0.22)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261030
	for i in count:
		var t := float(i) / float(RATE)
		# 快速起音 + 指数衰减，音高从高扫到低，模拟风啸
		var env := minf(t / 0.02, 1.0) * exp(-t * 14.0)
		var freq := lerpf(1800.0, 500.0, t / 0.22)
		var sample := (rng.randf_range(-1.0, 1.0) * 0.5 + sin(TAU * freq * t) * 0.35) * env
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))

	_evasion_sound = AudioStreamWAV.new()
	_evasion_sound.format = AudioStreamWAV.FORMAT_16_BITS
	_evasion_sound.mix_rate = RATE
	_evasion_sound.stereo = false
	_evasion_sound.data = data
	return _evasion_sound


# 进入警觉状态的提示音：低沉短促的怒吼，提示逃生者“猎人已经认真了”
func _play_alert_sound() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.current_scene
	if root == null:
		root = tree.root
	var player := AudioStreamPlayer3D.new()
	player.stream = _get_alert_sound()
	player.volume_db = -4.0
	player.unit_size = 6.0
	player.max_distance = 25.0
	root.add_child(player)
	player.global_position = global_position + Vector3.UP * 1.2
	player.finished.connect(player.queue_free)
	player.play()

static var _alert_sound: AudioStreamWAV = null

static func _get_alert_sound() -> AudioStreamWAV:
	if _alert_sound != null:
		return _alert_sound
	const RATE := 22050
	var count := int(RATE * 0.34)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261031
	for i in count:
		var t := float(i) / float(RATE)
		var env := minf(t / 0.03, 1.0) * exp(-t * 7.0)
		# 音高从 190Hz 往下滑，叠加噪声，模拟低吼
		var freq := lerpf(190.0, 85.0, t / 0.34)
		var tone := signf(sin(TAU * freq * t)) * 0.3
		var sample := (tone + rng.randf_range(-1.0, 1.0) * 0.25) * env
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))

	_alert_sound = AudioStreamWAV.new()
	_alert_sound.format = AudioStreamWAV.FORMAT_16_BITS
	_alert_sound.mix_rate = RATE
	_alert_sound.stereo = false
	_alert_sound.data = data
	return _alert_sound
