extends Node3D

# 南瓜爆炸后留在地面的橙色粘液滩。
# 随机挑选一份 splat 贴图与随机朝向，从一点快速向外扩散展开，存在一段时间后淡出销毁。

const SPLAT_DIR := "res://assets/props/pumpkin/splat/"
const SPLAT_COUNT := 36

@export var lifetime := 6.0            # 存在时长（秒）
@export var fade_time := 1.5           # 结尾淡出时长（秒）
@export var grow_time := 0.2           # 从中心炸开的扩散时长（秒）
@export var start_scale_ratio := 0.1   # 扩散起始时的 X/Z 缩放比例
@export var ground_mask := 9           # 向下射线检测的层：Wall | Ground（含高台与箱顶）
@export var ray_up := 0.5              # 向上起射高度，避免起点埋进地面
@export var ray_down := 3.0            # 向下检测距离
@export var random_shape := true       # 每次随机挑一张 splat 贴图
@export var scale_min := 0.85          # 随机缩放下限
@export var scale_max := 1.35          # 随机缩放上限
@export var tint := Color(1.0, 0.5, 0.0, 1.0)  # 粘液颜色（湿润亮橙）
@export var glow := 0.4                # 自发光强度，暗处也能看清
@export var slow_radius := 1.8         # 踩踏减速范围半径
@export var slow_layer_mask := 6       # 会触发减速的物理层：Survivor | Hunter

@onready var _mesh: MeshInstance3D = $Mesh

var _mat: ShaderMaterial
var _age := 0.0
var _slow_area: Area3D = null
var _slow_bodies: Array[CharacterBase] = []

func _ready() -> void:
	_mat = _mesh.get_surface_override_material(0) as ShaderMaterial
	if _mat != null:
		if random_shape:
			var tex := load(SPLAT_DIR + "splat%02d.png" % (randi() % SPLAT_COUNT)) as Texture2D
			if tex != null:
				_mat.set_shader_parameter("splat_tex", tex)
		_mat.set_shader_parameter("glow", glow)
		_set_alpha(0.0)

	_build_slow_area()

	# 先隐藏，等贴地完成后再开始扩散，避免生成瞬间在原点闪一帧
	visible = false
	call_deferred("_place_on_ground")

# 减速检测区：站在粘液上的角色会持续叠减速层数
func _build_slow_area() -> void:
	_slow_area = Area3D.new()
	_slow_area.name = "SlowArea"
	_slow_area.collision_layer = 0
	_slow_area.collision_mask = slow_layer_mask
	_slow_area.monitoring = true
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = slow_radius
	cylinder.height = 2.0
	shape.shape = cylinder
	shape.position = Vector3(0.0, 1.0, 0.0)  # 以粘液为底向上覆盖角色
	_slow_area.add_child(shape)
	add_child(_slow_area)
	_slow_area.body_entered.connect(_on_slow_body_entered)
	_slow_area.body_exited.connect(_on_slow_body_exited)

func _on_slow_body_entered(body: Node3D) -> void:
	if body is CharacterBase and not _slow_bodies.has(body):
		_slow_bodies.append(body)

func _on_slow_body_exited(body: Node3D) -> void:
	if body is CharacterBase:
		_slow_bodies.erase(body)
		body.reset_slow_contact()

func _physics_process(delta: float) -> void:
	# 站在粘液里的角色持续叠加减速层数
	for body in _slow_bodies:
		if is_instance_valid(body):
			body.add_slow_contact(delta, CharacterBase.SlowSource.SLIME)

# 贴到生成点正下方的地面，然后从极小尺寸炸开
func _place_on_ground() -> void:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * ray_up
	var to := global_position - Vector3.UP * ray_down
	var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
	var hit := space.intersect_ray(query)

	var normal := Vector3.UP
	if not hit.is_empty():
		normal = hit.normal
		global_position = hit.position + normal * 0.01

	# 贴图平面在子节点里已经转为水平，这里只做「对齐地面法线 + 随机绕法线旋转」
	var align := Basis(Quaternion(Vector3.UP, normal))
	global_basis = align * Basis(Vector3.UP, randf() * TAU)

	var s := randf_range(scale_min, scale_max)
	var target_scale := Vector3(s, 1.0, s)
	scale = Vector3(target_scale.x * start_scale_ratio, 1.0, target_scale.z * start_scale_ratio)
	visible = true
	_start_grow(target_scale)

# 0.2 秒内从中心向外扩散到目标大小，同时整体渐显
func _start_grow(target_scale: Vector3) -> void:
	if _mat == null:
		scale = target_scale
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", target_scale, grow_time)
	tween.tween_method(_set_alpha, 0.0, 1.0, grow_time)

func _process(delta: float) -> void:
	_age += delta
	var left := lifetime - _age
	if left <= 0.0:
		queue_free()
		return
	if _mat == null or left >= fade_time:
		return

	# 淡出：透明度与自发光一起衰减，避免消失前还在发亮
	var t := left / fade_time
	_set_alpha(t)
	_mat.set_shader_parameter("glow", glow * t)

# 只改颜色里的 alpha，保留 rgb，供扩散渐显与结尾淡出共用
func _set_alpha(a: float) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("tint", Color(tint.r, tint.g, tint.b, a))
