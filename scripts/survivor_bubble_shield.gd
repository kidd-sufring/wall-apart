class_name SurvivorBubbleShield
extends Node

# SBS：Survivor Bubble Shield（逃生者泡泡护盾）
# 只在玩家操控逃生者时由 Q 手动释放；AI 托管时由 Survivor 在追捕者靠近时自动释放。
# 护盾存在期间拦截一次追捕者伤害，并沿水平方向击退追捕者。

enum State {
	READY,
	ACTIVE,
	COOLDOWN,
}

@export_group("时长与冷却")
@export var shield_duration := 0.5          # 护盾持续时间（秒）
@export var cooldown_seconds := 8.0         # 冷却时间，0 表示无冷却
@export var block_grace_time := 0.1         # 护盾消耗后仍拦截伤害的极短窗口，避免同一次接触在下一物理帧扣血

@export_group("击退")
@export var knockback_distance := 10.0      # 击退距离（米）
@export var knockback_speed := 20.0         # 击退速度（米/秒）
@export var knockback_max_duration := 1.0   # 击退最长持续时间（秒），到时间或撞墙会提前结束

@export_group("目标与节点")
@export var hunter_group: StringName = &"hunter"  # 追捕者分组（可留空，仅靠物理层判断）
@export var hunter_collision_layer := 4           # 追捕者所在物理层（layer 3 = Hunter，值 4）
@export var shield_visual: Node3D                 # 护盾球体视觉根节点
@export var shield_area: Area3D                   # 护盾检测 Area3D

@onready var body: CharacterBase = get_parent() as CharacterBase

var _state: int = State.READY
var _active_left := 0.0
var _cooldown_left := 0.0
var _grace_time_left := 0.0
var _consumed := false


func _ready() -> void:
	# 场景未手动指定时，按标准节点名自动查找
	if shield_visual == null and body != null:
		shield_visual = body.get_node_or_null("ShieldVisual") as Node3D
	if shield_area == null and body != null:
		shield_area = body.get_node_or_null("ShieldArea") as Area3D

	if shield_visual != null:
		shield_visual.visible = false
	if shield_area != null:
		shield_area.monitoring = false
		shield_area.body_entered.connect(_on_shield_area_body_entered)


func _physics_process(delta: float) -> void:
	if body == null:
		return

	_grace_time_left = maxf(_grace_time_left - delta, 0.0)

	match _state:
		State.READY:
			_try_activate()
		State.ACTIVE:
			_active_left -= delta
			if _active_left <= 0.0:
				# 0.5 秒内没有碰到追捕者：自然结束，不产生击退
				_end_shield()
				return
			# Area3D 兜底：释放瞬间已与追捕者重叠时，body_entered 可能不触发
			if shield_area != null:
				for other in shield_area.get_overlapping_bodies():
					if _is_hunter(other):
						_consume(other as Node3D)
						return
		State.COOLDOWN:
			_cooldown_left = maxf(_cooldown_left - delta, 0.0)
			if _cooldown_left <= 0.0:
				_state = State.READY


func _try_activate() -> void:
	# 只允许玩家操控的逃生者手动释放
	if not body.active or not body.player_controlled:
		return
	# 倒地/起身期间不允许释放技能
	if body.is_stunned:
		return
	if not Input.is_action_just_pressed("survivor_bubble_shield"):
		return
	_activate()


# 公开触发接口：供 SWAE 等 AI 脱困逻辑在 READY 时调用
func trigger_if_ready() -> bool:
	if body == null or not body.active:
		return false
	# 倒地/起身期间不允许释放技能
	if body.is_stunned:
		return false
	if _state != State.READY:
		return false
	_activate()
	return true


func _activate() -> void:
	_state = State.ACTIVE
	_consumed = false
	_active_left = shield_duration
	_grace_time_left = 0.0

	if shield_visual != null:
		shield_visual.visible = true
	if shield_area != null:
		# 避免在物理信号回调内直接改 monitoring 被引擎拒绝
		shield_area.set_deferred("monitoring", true)

	# 护盾展开的声音
	if body != null:
		AudioManager.play_3d(&"shield", body.global_position + Vector3.UP * 0.9,
			-4.0, randf_range(0.97, 1.03), 6.0, 30.0)

	# 全局事件：玩家释放了主动技能
	if body != null and body.player_controlled:
		EventBus.skill_used.emit()


# 护盾是否真正可用（ACTIVE 且本次尚未消耗）
func is_shield_active() -> bool:
	return _state == State.ACTIVE and not _consumed


# 只读接口（供 AI 追捕者 HSA 计算安全距离）：护盾有效半径
func get_shield_radius() -> float:
	if shield_area != null:
		for child in shield_area.get_children():
			if child is CollisionShape3D:
				var shape := (child as CollisionShape3D).shape
				if shape is SphereShape3D:
					return (shape as SphereShape3D).radius
	if shield_visual != null:
		for child in shield_visual.find_children("*", "MeshInstance3D", true, false):
			var mesh := (child as MeshInstance3D).mesh
			if mesh is SphereMesh:
				return (mesh as SphereMesh).radius
	return 1.0


# 伤害入口调用：返回 true 表示本次伤害已被护盾挡下
func try_block_damage(attacker: Node) -> bool:
	if attacker == null:
		return false
	if not _is_hunter(attacker):
		return false

	# 刚消耗护盾的极短窗口内，重复的伤害请求也视为同一次碰撞
	if _grace_time_left > 0.0:
		return true

	if not is_shield_active():
		return false

	_consume(attacker as Node3D)
	return true


func _on_shield_area_body_entered(other: Node3D) -> void:
	if not is_shield_active():
		return
	if not _is_hunter(other):
		return
	_consume(other)


func _is_hunter(node: Node) -> bool:
	if node == null:
		return false
	if hunter_group != &"" and node.is_in_group(hunter_group):
		return true
	if node is CollisionObject3D:
		return ((node as CollisionObject3D).collision_layer & hunter_collision_layer) != 0
	return false


# 消耗护盾：结束视觉与检测、击退追捕者、进入冷却
func _consume(hunter_node: Node3D) -> void:
	if _consumed:
		return
	_consumed = true
	_grace_time_left = block_grace_time

	if hunter_node != null:
		var direction := hunter_node.global_position - body.global_position
		direction.y = 0.0
		if direction.length_squared() < 0.0001:
			direction = -hunter_node.global_transform.basis.z
		if direction.length_squared() < 0.0001:
			direction = Vector3.FORWARD
		direction = direction.normalized()

		if NetworkManager.is_online():
			# 联机：本机的追捕者往往是远端代理，直接调用不会生效，
			# 交由主机裁决免伤并让真正操控追捕者的一端执行击退
			NetworkManager.report_shield_block(direction, knockback_distance, knockback_speed, knockback_max_duration)
		elif hunter_node.has_method("apply_knockback"):
			hunter_node.call("apply_knockback", direction, knockback_distance, knockback_speed, knockback_max_duration)

		# 护盾弹开追捕者的音效
		AudioManager.play_3d(&"hit", body.global_position + Vector3.UP * 0.9, -2.0, 1.0, 8.0, 40.0)

	_end_shield()


func _end_shield() -> void:
	if shield_visual != null:
		shield_visual.visible = false
	if shield_area != null:
		# 可能由 body_entered 回调触发，必须延迟关闭 monitoring
		shield_area.set_deferred("monitoring", false)

	_cooldown_left = cooldown_seconds
	_active_left = 0.0
	_state = State.COOLDOWN if _cooldown_left > 0.0 else State.READY


func get_state() -> int:
	return _state


# 教程等场景用：立即清除冷却并收起护盾，让技能随时可用
func reset_skill() -> void:
	_state = State.READY
	_cooldown_left = 0.0
	_active_left = 0.0
	_consumed = false
	if shield_visual != null:
		shield_visual.visible = false
	if shield_area != null:
		shield_area.set_deferred("monitoring", false)


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
