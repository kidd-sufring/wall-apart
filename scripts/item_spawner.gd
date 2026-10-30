class_name ItemSpawner
extends Node3D

# 道具随机刷新器：在地图地面范围内随机撒 3~5 个道具。
# 默认按地面范围铺满整张地图；关闭 use_map_bounds 时退回自身周围 spawn_radius 的圆形范围。

@export var item_scenes: Array[PackedScene] = []
@export var min_count := 3
@export var max_count := 5
@export var use_map_bounds := true              # 在整个地图地面范围内随机刷新
@export var map_margin := 1.5                   # 距地图边缘留出的余量
@export var spawn_radius := 8.0                 # 仅 use_map_bounds = false 时生效
@export var spawn_height := 0.35                # 生成点离地高度，让道具自然落下
@export_range(0.0, 10.0) var min_spacing := 1.5  # 两个道具之间的最小间距
@export_flags_3d_physics var ground_mask: int = 8  # 默认只检测 Ground 层
@export_flags_3d_physics var blocked_mask: int = 1  # 落在墙里/障碍物里的点直接丢弃
@export var character_clearance := 3.0          # 与角色初始位置的最小水平距离，避免开局直接被捡起
@export var spawn_on_ready := true

# 联机时双方必须刷出完全一致的道具（位置/数量/类型/朝向），
# 否则同步过来的投掷物在两边对应不上，所以固定用同一个随机种子。
const MULTIPLAYER_SPAWN_SEED := 20261030

var _rng := RandomNumberGenerator.new()

# 角色开局位置，用于排除贴着人出生的刷新点
var _character_positions: Array[Vector3] = []

# 地图水平范围（x/z），由地面网格包围盒计算
var _map_bounds := Rect2()
var _has_map_bounds := false

func _ready() -> void:
	if Engine.is_editor_hint() or not spawn_on_ready:
		return
	if NetworkManager.is_online():
		_rng.seed = MULTIPLAYER_SPAWN_SEED
	else:
		_rng.randomize()
	_collect_character_positions()
	_collect_map_bounds()
	spawn_items()

# 记录场景中所有角色（逃生者 / 追捕者）的初始位置
func _collect_character_positions() -> void:
	_character_positions.clear()
	var root := get_tree().current_scene
	if root == null:
		return
	for node in root.find_children("*", "", true, false):
		if node is CharacterBase:
			_character_positions.append((node as Node3D).global_position)

## 立即生成一批道具，可重复调用
func spawn_items() -> void:
	if item_scenes.is_empty():
		push_warning("ItemSpawner: item_scenes 为空，无法刷新道具")
		return
	# 外部先调用 spawn_items 时兜底采集角色位置（角色已入场，位置即开局位置）
	if _character_positions.is_empty():
		_collect_character_positions()
	if use_map_bounds and not _has_map_bounds:
		_collect_map_bounds()

	var count := _rng.randi_range(mini(min_count, max_count), maxi(min_count, max_count))
	var used: Array[Vector3] = []
	for i in range(count):
		var spawn_position := _find_spawn_position(used)
		var scene: PackedScene = item_scenes[_rng.randi() % item_scenes.size()]
		var item := scene.instantiate()
		# 联机标识必须两端一致：节点名在重名时会变成 @RigidBody3D@N（进程内自增，两端不同），
		# 不能用路径；这里按出生序号给一个稳定 ID（随机种子固定，两端顺序一致）
		item.set_meta(&"net_id", "item_%02d" % i)
		add_child(item)
		item.global_position = spawn_position
		item.rotation.y = _rng.randf() * TAU



# 用地面层静态体的网格包围盒算出整张地图的水平刷新范围
func _collect_map_bounds() -> void:
	_has_map_bounds = false
	_map_bounds = Rect2()
	if not use_map_bounds:
		return
	var root := get_tree().current_scene
	if root == null:
		return

	var bounds := AABB()
	var has_box := false
	for body in root.find_children("*", "StaticBody3D", true, false):
		var static_body := body as StaticBody3D
		if (static_body.collision_layer & ground_mask) == 0:
			continue
		for mesh_node in static_body.find_children("*", "MeshInstance3D", true, false):
			var mesh := mesh_node as MeshInstance3D
			if mesh.mesh == null:
				continue
			var box := mesh.global_transform * mesh.get_aabb()
			bounds = box if not has_box else bounds.merge(box)
			has_box = true
	if not has_box:
		return

	# 只取水平范围，并向内收缩 margins 距离
	var min_x := bounds.position.x + map_margin
	var max_x := bounds.position.x + bounds.size.x - map_margin
	var min_z := bounds.position.z + map_margin
	var max_z := bounds.position.z + bounds.size.z - map_margin
	if max_x <= min_x or max_z <= min_z:
		return
	_map_bounds = Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))
	_has_map_bounds = true


# 在地图（或刷新器周围）找一块水平地面；找不到时退回刷新器原点，保证生成数量
func _find_spawn_position(used: Array[Vector3]) -> Vector3:
	for attempt in range(20):
		var center := global_position
		if _has_map_bounds:
			center = Vector3(
				_rng.randf_range(_map_bounds.position.x, _map_bounds.end.x),
				0.0,
				_rng.randf_range(_map_bounds.position.y, _map_bounds.end.y)
			)
		else:
			var angle := _rng.randf() * TAU
			var distance := sqrt(_rng.randf()) * spawn_radius
			center = global_position + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		var from := center + Vector3.UP * 10.0
		var to := center + Vector3.DOWN * 30.0
		var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			continue
		# 只接受近似水平的面，避免道具挂在墙顶
		var normal: Vector3 = hit.normal
		if normal.y < 0.7:
			continue
		var candidate: Vector3 = hit.position + Vector3.UP * spawn_height
		if _has_nearby(candidate, used):
			continue
		# 避免生成在墙体内：候选点周围有障碍物就重新取点
		if _is_blocked(candidate):
			continue
		# 避免贴着角色初始位置，防止开局直接被捡走
		if _is_near_character(candidate):
			continue
		used.append(candidate)
		return candidate

	var fallback := global_position + Vector3.UP * spawn_height
	used.append(fallback)
	return fallback

func _has_nearby(point: Vector3, used: Array[Vector3]) -> bool:
	for other in used:
		if point.distance_to(other) < min_spacing:
			return true
	return false

# 候选点与任一角色初始位置的水平距离是否过近
func _is_near_character(point: Vector3) -> bool:
	if character_clearance <= 0.0:
		return false
	for pos in _character_positions:
		if Vector2(point.x - pos.x, point.z - pos.z).length() < character_clearance:
			return true
	return false

func _is_blocked(point: Vector3) -> bool:
	if blocked_mask == 0:
		return false
	var probe := SphereShape3D.new()
	probe.radius = 0.5
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = probe
	params.transform = Transform3D(Basis.IDENTITY, point)
	params.collision_mask = blocked_mask
	return not get_world_3d().direct_space_state.intersect_shape(params, 1).is_empty()
