extends NavigationRegion3D

# 小型竞技场导航烘焙器。
# 使用 nav_source 组收集 Ground 与 Map（墙体 StaticBody3D、NavigationObstacle3D）。
# 运行时烘焙一次 NavigationMesh；参数面向 40×40m 竞技场。

@export var source_group_name := &"nav_source"
@export var agent_radius := 0.75         # 追捕者胶囊半径 0.5；取 cell_size 的整数倍（0.75），留出贴墙余量
@export var agent_height := 1.75         # 同样对齐到 cell_height 的整数倍，避免烘焙量化警告
@export var agent_max_climb := 0.5       # 本项目无平台跳跃
@export var cell_size := 0.25            # 与 NavigationServer3D 默认 map cell size 一致
@export var cell_height := 0.25
@export var region_min_size := 1.0       # 小竞技场把最小区域调小，避免狭窄通道被丢弃
@export var region_merge_size := 2.0

func _ready() -> void:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = agent_radius
	nav_mesh.agent_height = agent_height
	nav_mesh.agent_max_climb = agent_max_climb
	nav_mesh.cell_size = cell_size
	nav_mesh.cell_height = cell_height
	nav_mesh.region_min_size = region_min_size
	nav_mesh.region_merge_size = region_merge_size

	# 只解析静态碰撞体；墙体自身保留 StaticBody3D + CollisionShape3D
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_mesh.geometry_source_group_name = source_group_name

	navigation_mesh = nav_mesh

	# 等一帧，确保场景内 StaticBody3D / NavigationObstacle3D 已进入场景树
	await get_tree().physics_frame
	bake_navigation_mesh(false)

	# Recast 烘焙出的导航面会整体高出地面若干体素（本竞技场实测约 0.5m）。
	# 若不对齐，NavigationAgent3D 用 3D 距离判断路径点是否到达时会卡在路径点下方。
	# 这里把最低导航面（地面）归零到区域原点，墙顶等高层导航面同步下移。
	_align_navigation_mesh_to_floor()


func _align_navigation_mesh_to_floor() -> void:
	if navigation_mesh == null:
		return
	var verts := navigation_mesh.get_vertices()
	if verts.is_empty():
		return

	var min_y := INF
	for v in verts:
		min_y = minf(min_y, v.y)

	if absf(min_y) < 0.0001:
		return

	for i in verts.size():
		verts[i].y -= min_y
	navigation_mesh.set_vertices(verts)
