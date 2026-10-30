class_name SlowZone
extends Area3D

# 圆形减速区域（蛛网等）：机制与南瓜粘液一致——
# 站在范围内每 0.2s 叠一层减速、每层 1 秒、最多 5 层（共 5 秒），
# 离开后按剩余时间自然衰减；只有落地才叠层，跳跃/空中可以规避。

var _slowed: Array[CharacterBase] = []

func _physics_process(delta: float) -> void:
	var inside: Array[CharacterBase] = []
	for body in get_overlapping_bodies():
		if body is CharacterBase:
			inside.append(body as CharacterBase)

	# 离开范围的清空浸泡进度（已叠的层数按剩余时间自然衰减）
	for body in _slowed:
		if not inside.has(body):
			body.reset_slow_contact()

	# 范围内落地才叠层；起跳离地后不叠加
	for body in inside:
		body.add_slow_contact(delta, CharacterBase.SlowSource.WEB)

	_slowed = inside
