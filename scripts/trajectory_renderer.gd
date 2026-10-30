class_name TrajectoryRenderer
extends Node3D

# 投掷轨迹预览：圆点虚线 + 落点指示器。
# 轨迹点由角色脚本每帧算好后传进来，这里只负责绘制。
# 命中角色时整体变红，落在地上时显示白绿色。

const MAX_DOTS := 64

@export var dot_radius := 0.06            # 圆点半径（米）
@export var dot_spacing := 0.45           # 相邻圆点的最小间距（米），避免点挤在一起
@export var normal_color := Color(0.45, 1.0, 0.55, 0.9)
@export var hit_color := Color(1.0, 0.25, 0.25, 0.95)
@export var landing_radius := 0.45        # 落点圆盘半径（米）

var _dots: MultiMeshInstance3D
var _dot_material: StandardMaterial3D
var _landing: MeshInstance3D
var _landing_material: StandardMaterial3D

func _ready() -> void:
	_build()
	hide_trajectory()

func _build() -> void:
	var dot_mesh := SphereMesh.new()
	dot_mesh.radius = dot_radius
	dot_mesh.height = dot_radius * 2.0
	dot_mesh.radial_segments = 6
	dot_mesh.rings = 3

	_dot_material = StandardMaterial3D.new()
	_dot_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dot_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dot_material.albedo_color = normal_color

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = dot_mesh
	multi.instance_count = MAX_DOTS
	multi.visible_instance_count = 0

	_dots = MultiMeshInstance3D.new()
	_dots.name = "Dots"
	_dots.multimesh = multi
	_dots.material_override = _dot_material
	_dots.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dots)

	var disc := CylinderMesh.new()
	disc.top_radius = landing_radius
	disc.bottom_radius = landing_radius
	disc.height = 0.02
	disc.radial_segments = 24

	_landing_material = StandardMaterial3D.new()
	_landing_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_landing_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_landing_material.albedo_color = normal_color

	_landing = MeshInstance3D.new()
	_landing.name = "Landing"
	_landing.mesh = disc
	_landing.material_override = _landing_material
	_landing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_landing)

## points 为世界坐标轨迹点，最后一点是落点；hit_actor 表示落点命中角色
func show_trajectory(points: Array[Vector3], hit_actor: bool, has_hit: bool) -> void:
	if points.size() < 2:
		hide_trajectory()
		return

	var color := hit_color if hit_actor else normal_color
	_dot_material.albedo_color = color
	_landing_material.albedo_color = color

	var multi := _dots.multimesh
	var count := 0
	var last := points[0]
	for i in range(points.size()):
		if count >= MAX_DOTS:
			break
		var p := points[i]
		if i > 0 and p.distance_to(last) < dot_spacing:
			continue
		multi.set_instance_transform(count, Transform3D(Basis(), to_local(p)))
		count += 1
		last = p
	multi.visible_instance_count = count

	# 只有真正命中东西才显示落点圆盘
	_landing.visible = has_hit
	if has_hit:
		_landing.global_position = points[points.size() - 1] + Vector3.UP * 0.02

	visible = true

func hide_trajectory() -> void:
	visible = false
	if _dots != null and _dots.multimesh != null:
		_dots.multimesh.visible_instance_count = 0
	if _landing != null:
		_landing.visible = false
