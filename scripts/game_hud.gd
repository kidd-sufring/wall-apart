extends CanvasLayer

# 游戏内 HUD：只读取 GameManager 的状态与时间，不自行判定胜负。
# - 倒计时（与胜负判定同一数据源）
# - 逃生者生命值（仅玩家操控逃生者时显示，按剩余血量切换整张血条贴图）
# - 技能图标（冷却暗影 + 冷却完成边框闪亮）

const ROLE_HUNTER := &"hunter_sid"
const ROLE_SURVIVOR := &"survivor_sonny"

var _hp_full: Texture2D = preload("res://ui/hp_100.png")
var _hp_half: Texture2D = preload("res://ui/hp_50.png")
var _hp_empty: Texture2D = preload("res://ui/hp_0.png")

@onready var time_value: Label = $Root/Clock/TimeValue
@onready var ready_label: Label = $Root/ReadyLabel
@onready var hp_root: Control = $Root/HPRoot
@onready var hp_bar: TextureRect = $Root/HPRoot/HpBar
@onready var icon_ghost: TextureRect = $Root/SkillRoot/IconGhost
@onready var icon_shield: TextureRect = $Root/SkillRoot/IconShield
@onready var shade: ColorRect = $Root/SkillRoot/Shade
@onready var border: Panel = $Root/SkillRoot/Border
@onready var skill_name: Label = $Root/SkillRoot/SkillName

var _role: StringName = &""
var _skill_node: Node = null
var _last_hp := -1
var _last_ratio := 0.0
var _border_tween: Tween
var _hp_tween: Tween


func _ready() -> void:
	GameManager.survivor_hp_changed.connect(_on_hp_changed)
	GameManager.state_changed.connect(_on_state_changed)
	hp_root.visible = false
	shade.visible = false
	border.modulate.a = 0.0
	_on_hp_changed(GameManager.survivor_hp, GameManager.survivor_max_hp)


# 由游戏场景在分配好控制权后调用
func bind_role(role: StringName, skill_node: Node) -> void:
	_role = role
	_skill_node = skill_node

	var player_is_hunter := role == ROLE_HUNTER
	hp_root.visible = not player_is_hunter
	icon_ghost.visible = player_is_hunter
	icon_shield.visible = not player_is_hunter
	skill_name.text = "幽灵状态" if player_is_hunter else "泡泡护盾"
	skill_name.modulate = Color(0.62, 0.82, 1.0) if player_is_hunter else Color(1.0, 0.62, 0.82)

	_last_ratio = 0.0
	shade.visible = false
	_update_hp(GameManager.survivor_hp, GameManager.survivor_max_hp)


func _process(_delta: float) -> void:
	var state := GameManager.state
	if state == GameManager.GameState.COUNTDOWN:
		ready_label.visible = true
		ready_label.text = str(ceili(GameManager.time_left))
		time_value.text = str(int(GameManager.match_duration))
	elif state == GameManager.GameState.PLAYING:
		ready_label.visible = false
		time_value.text = str(ceili(GameManager.time_left))
	else:
		ready_label.visible = false
	_update_skill()


func _on_state_changed(new_state: int) -> void:
	if new_state == GameManager.GameState.RESULT:
		time_value.text = "0"


func _on_hp_changed(current: int, maximum: int) -> void:
	_update_hp(current, maximum)
	if _last_hp >= 0 and current < _last_hp:
		_flash_hp_bar()
	_last_hp = current


# 按剩余血量切换整张血条贴图：满血 / 半血 / 空血
func _update_hp(hp: int, maximum: int) -> void:
	var ratio := float(hp) / float(maxi(maximum, 1))
	if ratio > 0.75:
		hp_bar.texture = _hp_full
	elif ratio > 0.25:
		hp_bar.texture = _hp_half
	else:
		hp_bar.texture = _hp_empty


# 掉血时血条整体闪一下暗红，再恢复
func _flash_hp_bar() -> void:
	if _hp_tween != null and _hp_tween.is_valid():
		_hp_tween.kill()
	hp_bar.modulate = Color(1.0, 0.45, 0.45, 1.0)
	_hp_tween = create_tween()
	_hp_tween.tween_property(hp_bar, "modulate", Color(1, 1, 1, 1), 0.3)


func _update_skill() -> void:
	if _skill_node == null:
		return

	var ratio := 0.0
	if _skill_node.has_method("get_skill_cooldown_ratio"):
		ratio = float(_skill_node.call("get_skill_cooldown_ratio"))
	ratio = clampf(ratio, 0.0, 1.0)

	shade.visible = ratio > 0.001
	# 圆形阴影自上而下消退：把冷却比例传给着色器
	var shade_material := shade.material as ShaderMaterial
	if shade_material != null:
		shade_material.set_shader_parameter("ratio", ratio)

	# 冷却刚好结束：边框用技能主色闪亮一次
	if ratio <= 0.001 and _last_ratio > 0.001:
		_flash_skill_border()
	_last_ratio = ratio


func _flash_skill_border() -> void:
	# 冷却结束的轻提示音
	AudioManager.play_2d(&"light_impact", -10.0, randf_range(0.98, 1.02))
	var color := Color(0.62, 0.82, 1.0) if _role == ROLE_HUNTER else Color(1.0, 0.42, 0.72)
	if _border_tween != null and _border_tween.is_valid():
		_border_tween.kill()
	border.modulate = Color(color.r, color.g, color.b, 0.0)
	_border_tween = create_tween()
	_border_tween.tween_property(border, "modulate:a", 1.0, 0.12)
	_border_tween.tween_property(border, "modulate:a", 0.0, 0.18)
