extends Area3D

# 教程终点触发区：玩家进入该区域时发出“到达”事件。
# 是否算“成功规避减速区”由 TutorialManager 结合减速状态判断；
# 如果被减速过，玩家需要离开后再进入一次。

@export var player_group: StringName = &"Player"

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group(player_group):
		return
	# 延迟到物理帧结束后再发事件：避免在物理回调里切步骤、改 UI
	EventBus.slow_zone_avoided.emit.call_deferred()
