extends Node3D

# 逃生者头顶血条：Billboard(Sprite3D) + SubViewport + ProgressBar。
# 血条 UI 全部放在 SubViewport 内部自己的 CanvasLayer 里，不与屏幕 HUD 混用。
# 血量由既有的主机权威 RPC 链路同步到所有客户端：
#   NetworkManager._rpc_apply_hp → Survivor.apply_network_hp → health_changed
# 这里只监听 health_changed 刷新进度条，因此每个客户端看到的血量一致。
# 挂在 Survivor 下，随角色一起移动；Sprite3D 开启深度测试，被墙体遮挡时会一起被挡住。

@onready var sprite: Sprite3D = $Sprite3D
@onready var viewport: SubViewport = $SubViewport
@onready var bar: ProgressBar = $SubViewport/BarLayer/Root/Bar

var _survivor: Survivor


func _ready() -> void:
	# 用 SubViewport 的渲染结果作为 3D 公告牌贴图
	sprite.texture = viewport.get_texture()

	_survivor = get_parent() as Survivor
	if _survivor == null:
		return
	_survivor.health_changed.connect(_on_health_changed)
	_on_health_changed(_survivor.health, _survivor.max_health)


func _on_health_changed(current: int, maximum: int) -> void:
	bar.max_value = maxi(maximum, 1)
	bar.value = clampi(current, 0, maximum)
