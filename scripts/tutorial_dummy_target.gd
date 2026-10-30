extends StaticBody3D

# 教程假人：投掷物的 collision_layer 为 0，Area3D 检测不到它们，
# 所以这里按距离检测飞行中的投掷物，被砸中时发全局事件 dummy_hit。

@export var hit_radius := 1.2       # 视为命中的距离（以假人胸口为圆心）
@export var hit_cooldown := 0.5     # 两次命中事件的间隔，避免同一发道具连续触发

var _cooldown := 0.0


func _physics_process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown = maxf(_cooldown - delta, 0.0)
		return

	var center := global_position + Vector3.UP * 0.9
	for node in get_tree().get_nodes_in_group("throwable_items"):
		var item := node as Node3D
		if item == null or not is_instance_valid(item):
			continue
		if not bool(item.get("_flying")):
			continue
		if item.global_position.distance_to(center) > hit_radius:
			continue
		_cooldown = maxf(hit_cooldown, 0.01)
		EventBus.dummy_hit.emit()
		return
