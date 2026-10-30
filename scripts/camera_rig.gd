class_name CameraRig
extends Node3D

# 第三人称相机：只跟随当前玩家操控的角色，鼠标控制水平/垂直环绕角度。
# AI 角色没有相机节点，这里也只会把朝向写入当前玩家角色。
# SpringArm3D 负责相机与场景（世界层）的碰撞避让。

@export var target: Node3D
@export var follow_height := 1.15
@export var mouse_sensitivity := 0.0025
@export var min_pitch_deg := -65.0
@export var max_pitch_deg := 20.0

var yaw := 0.0
var pitch := deg_to_rad(-12.0)

@onready var spring_arm: SpringArm3D = $SpringArm3D

func _ready() -> void:
	spring_arm.collision_mask = 1  # 只与 World 层发生相机碰撞

# 切换玩家角色时调用：解除旧角色的相机朝向绑定，再绑定新角色
func set_target(new_target: Node3D) -> void:
	if target == new_target:
		return
	if target is CharacterBase:
		target.camera_yaw = 0.0  # 旧角色转为 AI 后不再接收相机朝向
	target = new_target

func _process(_delta: float) -> void:
	if target:
		# 相机支点跟随角色头部附近
		global_position = target.global_position + Vector3.UP * follow_height
		if target is CharacterBase:
			# 把相机朝向交给角色，用于把 WASD 输入转换到世界方向
			target.camera_yaw = yaw

	rotation = Vector3(0.0, yaw, 0.0)
	spring_arm.rotation.x = pitch

func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * mouse_sensitivity
		pitch -= motion.relative.y * mouse_sensitivity
		pitch = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
