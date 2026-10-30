extends Node3D

# 新手教程状态机：依次引导玩家完成 拾取 → 投掷石头 → 投掷南瓜 → 躲避减速区 → 使用技能。
# 玩法侧只通过 EventBus 上报“发生了什么”，本脚本负责判断当前步骤并推进。

enum Step { INTRO, PICK_UP, THROW_STONE, THROW_PUMPKIN, AVOID_SLOW, USE_SKILL, PASS_WALL, FINISHED }

@export_group("场景引用")
@export var player_path: NodePath = ^"Player"
@export var instruction_label_path: NodePath = ^"UI/InstructionLabel"
@export var highlight_arrow_path: NodePath = ^"HighlightArrow"
@export var camera_rig_path: NodePath = ^"CameraRig"
@export var dummy_path: NodePath = ^"TutorialTriggers/DummyTarget"
@export var stone_path: NodePath = ^"Props/Stone"
@export var pumpkin_path: NodePath = ^"Props/Pumpkin"
@export var goal_area_path: NodePath = ^"TutorialTriggers/GoalArea"
@export var finish_popup_path: NodePath = ^"FinishPopup"
# 追捕者教程：技能测试用的墙体与墙后的逃生者（留空则不启用该环节）
@export var skill_wall_path: NodePath = ^"TutorialTriggers/SkillWall"
@export var wall_target_path: NodePath = ^"TutorialTriggers/WallTarget"

@export_group("提示文案")
@export var skill_prompt := "第五步：按 F 释放泡泡护盾"   # 第五步文案（追捕者教程覆盖为幽灵状态）
# 追捕者教程：幽灵状态最长 3 秒，只有贴着墙释放才来得及穿过去
@export var wall_use_max_gap := 8.0          # 与墙体的最大前后距离（米），超过则不算“在墙边释放”

@export_group("检测参数")
@export var intro_seconds := 2.5            # 开场提示停留时间
@export var throw_hit_window := 2.5         # 脱手后等待 dummy_hit 的时间窗口（秒）
@export var item_usable_min_y := -5.0       # 道具低于该高度即视为掉出边界、捡不回来

@export_group("弹窗按钮")
@export var close_hover_scale := 1.08       # 红叉悬停时的放大倍率
@export var close_hover_time := 0.12        # 放大/还原动画时长（秒）

var current_step: Step = Step.INTRO

var _player: CharacterBase
var _label: Label
var _arrow: Node3D
var _camera_rig: Node3D
var _dummy: Node3D
var _stone: Node3D
var _pumpkin: Node3D
var _goal_area: Area3D
var _finish_popup: CanvasLayer
var _wall: Node3D
var _wall_target: Node3D
var _hp_label: Label3D
var _skill_retry_timer := 0.0
var _close_button: Control
var _close_hover_bound := false
var _close_tween: Tween

var _last_thrown := ""                      # 本次投出的道具名
var _hit_window_left := 0.0                 # 命中判定的剩余时间
var _hit_registered := false                # 窗口内是否收到了 dummy_hit
var _arrow_base_y := 0.0
var _arrow_phase := 0.0


func _ready() -> void:
	_player = get_node_or_null(player_path) as CharacterBase
	_label = get_node_or_null(instruction_label_path) as Label
	_arrow = get_node_or_null(highlight_arrow_path) as Node3D
	_camera_rig = get_node_or_null(camera_rig_path) as Node3D
	_dummy = get_node_or_null(dummy_path) as Node3D
	_stone = get_node_or_null(stone_path) as Node3D
	_pumpkin = get_node_or_null(pumpkin_path) as Node3D
	_goal_area = get_node_or_null(goal_area_path) as Area3D
	_finish_popup = get_node_or_null(finish_popup_path) as CanvasLayer
	_wall = get_node_or_null(skill_wall_path) as Node3D
	_wall_target = get_node_or_null(wall_target_path) as Node3D
	if _wall_target != null:
		_hp_label = _wall_target.get_node_or_null("HpLabel") as Label3D
		if _wall_target.has_signal("health_changed"):
			_wall_target.connect("health_changed", _on_wall_target_health_changed)
			_update_hp_label(int(_wall_target.get("health")), int(_wall_target.get("max_health")))

	# 教程里逃生者由玩家操控
	if _player != null:
		_player.active = true
		_player.player_controlled = true
		_player.add_to_group("Player")
		# 教程的假人就在正前方 8 米，默认 15° 仰角会从假人头上飞过，先用平射
		_player.throw_elevation_deg = 0.0

	if _camera_rig != null and _camera_rig.has_method("set_target"):
		_camera_rig.call("set_target", _player)
		# 相机站在角色身后（+Z）看向 -Z，正好对着假人方向
		_camera_rig.set("yaw", 0.0)

	# 订阅全局玩法事件
	EventBus.item_picked_up.connect(_on_bus_item_picked_up)
	EventBus.item_thrown.connect(_on_bus_item_thrown)
	EventBus.dummy_hit.connect(_on_bus_dummy_hit)
	EventBus.slow_zone_avoided.connect(_on_bus_slow_zone_avoided)
	EventBus.skill_used.connect(_on_bus_skill_used)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# 进入教程停掉菜单背景音乐，并给教程界面的按钮挂上界面音效
	AudioManager.stop_bgm(0.3)
	UiSound.bind(self)

	# 预热南瓜粘液滩的着色器，避免第一个南瓜落地时卡一下
	ThrowableItem.prewarm_slime_puddle(self)

	current_step = Step.INTRO
	_apply_step()

	# 开场提示结束后自动进入第一步
	await get_tree().create_timer(maxf(intro_seconds, 0.1)).timeout
	if is_inside_tree() and current_step == Step.INTRO:
		advance_step()


func _process(delta: float) -> void:
	# 高亮箭头上下浮动，指向当前目标
	if _arrow == null or not _arrow.visible:
		return
	_arrow_phase += delta * 3.0
	_arrow.position.y = _arrow_base_y + sin(_arrow_phase) * 0.15


# Esc：先释放鼠标；鼠标已释放时再按一次返回主菜单（避免被抓取后无法退出）
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_set_instruction("已释放鼠标（再次按 Esc 返回主菜单）")
		return
	GameManager.return_to_menu()


func _physics_process(delta: float) -> void:
	# 投掷命中判定：窗口结束时按是否收到 dummy_hit 结算本次投掷
	if _hit_window_left > 0.0:
		_hit_window_left = maxf(_hit_window_left - delta, 0.0)
		if _hit_window_left <= 0.0:
			on_item_thrown(_last_thrown, _hit_registered)

	# 投掷物全部丢出边界、当前步骤已经无法完成时，不再卡关，直接进入躲避减速区的教学
	var needed := _needed_throw_item()
	if not needed.is_empty() and not _has_usable_item(needed):
		_skip_to_slow_step()

	# 追捕者教程：技能结束但还没穿过墙时自动恢复技能，允许反复尝试
	if current_step == Step.PASS_WALL and _player != null and _player.active:
		_skill_retry_timer -= delta
		if _skill_retry_timer <= 0.0:
			_skill_retry_timer = 1.0
			_reset_cooling_skill()
		# 幽灵状态已结束却仍停在墙前：提示重新贴墙释放，避免玩家被墙挡住后不知道怎么继续
		if not _has_passed_skill_wall() and not _is_player_ghost_active():
			_set_instruction("幽灵状态已结束：走到墙边再按 F 重新释放\n穿过墙体后，把墙后逃生者的生命值清空")


# ---------- 状态推进 ----------

# 切到下一个步骤并刷新 UI 提示
func advance_step() -> void:
	if current_step >= Step.FINISHED:
		return
	current_step = (current_step + 1) as Step
	_apply_step()


# ---------- 外部检测接口（也由 EventBus 转发调用） ----------

# 玩家拾取到道具（item_name 为"石头"/"南瓜"）
func on_item_picked_up(item_name: String) -> void:
	if current_step == Step.PICK_UP:
		advance_step()


# 玩家投出道具；hit_target 表示是否命中假人
func on_item_thrown(item_name: String, hit_target: bool) -> void:
	if current_step == Step.FINISHED:
		return
	var expected := ""
	match current_step:
		Step.THROW_STONE:
			expected = "石头"
		Step.THROW_PUMPKIN:
			expected = "南瓜"
		_:
			_set_instruction("请先完成当前步骤")
			return
	if item_name != expected:
		_set_instruction("请先完成当前步骤")
		return
	if not hit_target:
		_set_instruction("没有命中，再试一次：转动视角瞄准假人，滚轮调整仰角，点击鼠标左键投出")
		return
	advance_step()


# 走进减速区后的终点区
func on_slow_zone_avoided() -> void:
	if current_step == Step.FINISHED:
		return
	if current_step != Step.AVOID_SLOW:
		_set_instruction("请先完成当前步骤")
		return
	advance_step()


# 成功释放技能
func on_skill_used() -> void:
	if current_step == Step.USE_SKILL:
		# 追捕者教程：技能用来穿墙，穿过后还要清空墙后逃生者的生命值才算完成
		if _wall != null and _wall_target != null:
			# 幽灵状态只有 3 秒：离墙太远释放会在走到墙前就结束，玩家被墙挡住后
			# 自然也就无法清空墙后逃生者的生命值。这里要求贴着墙再按 F。
			if not _is_near_skill_wall():
				_reset_tutorial_skill()
				_set_instruction("离墙体太远了：先走到前方墙体旁，再按 F 释放幽灵状态")
				return
			current_step = Step.PASS_WALL
			_apply_step()
			# 玩家可能绕路提前把墙后逃生者打死了，直接结算，避免卡在穿墙步骤
			if int(_wall_target.get("health")) <= 0:
				call_deferred("_finish_step")
			return
		# 逃生者教程：释放技能即完成，跳过追捕者专用的穿墙环节
		current_step = Step.FINISHED
		_apply_step()
		return
	if current_step == Step.FINISHED or current_step == Step.PASS_WALL:
		return
	_set_instruction("请先完成当前步骤")


# ---------- EventBus 回调 ----------

func _on_bus_item_picked_up(item_name: String) -> void:
	on_item_picked_up(item_name)


func _on_bus_item_thrown(item_name: String) -> void:
	_last_thrown = item_name
	_hit_registered = false
	_hit_window_left = maxf(throw_hit_window, 0.1)


func _on_bus_dummy_hit() -> void:
	if _hit_window_left <= 0.0:
		return
	_hit_registered = true
	_hit_window_left = 0.0
	on_item_thrown(_last_thrown, true)


func _on_bus_slow_zone_avoided() -> void:
	on_slow_zone_avoided()


func _on_bus_skill_used() -> void:
	# 技能是在物理帧里触发的，延迟到帧末再切步骤/弹窗
	call_deferred("on_skill_used")


# ---------- 步骤表现 ----------

func _apply_step() -> void:
	_update_item_locks()
	match current_step:
		Step.INTRO:
			_set_instruction("欢迎来到新手教程！\nWASD 移动 · 鼠标转视角 · Shift 奔跑 · Space 跳跃\n（按 Esc 释放鼠标，再按一次返回主菜单）")
			_set_highlight(null)
		Step.PICK_UP:
			_set_instruction("第一步：走到石头旁，靠近后会自动拾取")
			_set_highlight(_stone)
		Step.THROW_STONE:
			_set_instruction("第二步：转动视角瞄准，滚轮调整仰角，点击鼠标左键投出石头")
			_set_highlight(_dummy)
		Step.THROW_PUMPKIN:
			_set_instruction("第三步：捡起南瓜并投向假人\n南瓜命中会留下减速粘液")
			_set_highlight(_pumpkin)
		Step.AVOID_SLOW:
			_set_instruction("第四步：绕开或跳过白色蛛网减速区，走进发光终点区")
			_set_highlight(_goal_area)
		Step.USE_SKILL:
			# 教程里保证技能随时可用；延迟执行，避免在物理回调里改技能状态
			call_deferred("_reset_tutorial_skill")
			_set_instruction(skill_prompt)
			_set_highlight(null)
		Step.PASS_WALL:
			_set_instruction("技能已开启：穿过前方墙体\n墙后有一名逃生者，把它的生命值清空")
			_set_highlight(_wall)
		Step.FINISHED:
			_set_instruction("教程完成！\n你已经掌握了拾取、投掷、规避减速区和使用技能。")
			_set_highlight(null)
			_show_finish_popup()


func _set_instruction(text: String) -> void:
	if _label != null:
		_label.text = text


# 只允许捡起当前步骤对应的道具：第一步/第二步用石头，第三步用南瓜，其余步骤都不能捡
func _update_item_locks() -> void:
	var allow_stone := current_step == Step.PICK_UP or current_step == Step.THROW_STONE
	var allow_pumpkin := current_step == Step.THROW_PUMPKIN
	_set_item_pickup(_stone, allow_stone)
	_set_item_pickup(_pumpkin, allow_pumpkin)


# 道具可能已经被投掷销毁（南瓜落地会 queue_free），所以用 Variant 接收并做有效性检查
func _set_item_pickup(item: Variant, enabled: bool) -> void:
	if item == null or not is_instance_valid(item):
		return
	if item.has_method("set_pickup_enabled"):
		item.call("set_pickup_enabled", enabled)


# ---------- 投掷物掉出边界的兜底 ----------

# 当前投掷步骤需要的道具名（空字符串表示该步骤不需要道具）
func _needed_throw_item() -> String:
	match current_step:
		Step.THROW_STONE:
			return "石头"
		Step.THROW_PUMPKIN:
			return "南瓜"
	return ""


# 场上是否还有能捡起来的这种道具（掉到 item_usable_min_y 以下的算丢出边界）
func _has_usable_item(item_name: String) -> bool:
	for node in get_tree().get_nodes_in_group("throwable_items"):
		var item := node as Node3D
		if item == null or not is_instance_valid(item):
			continue
		if item.global_position.y < item_usable_min_y:
			continue
		if _get_item_name(item) != item_name:
			continue
		return true
	return false


func _get_item_name(item: Node3D) -> String:
	if item.has_method("get_display_name"):
		return str(item.call("get_display_name"))
	return item.name


# 道具已经没得用了：跳过剩下的投掷步骤，直接教躲避减速区，避免卡关
func _skip_to_slow_step() -> void:
	_hit_window_left = 0.0
	_last_thrown = ""
	current_step = Step.AVOID_SLOW
	_apply_step()
	_set_instruction("投掷物已经丢出场地了，先来学习躲避：\n绕开或跳过蛛网减速区，走进发光终点区")


# 教程完成弹窗：显示提示并放开鼠标，让玩家可以点「返回主菜单」
func _show_finish_popup() -> void:
	# 延迟到帧末再显示，避免在物理/动画回调里改鼠标模式
	call_deferred("_present_finish_popup")


func _present_finish_popup() -> void:
	if _finish_popup == null or not is_instance_valid(_finish_popup):
		return
	_finish_popup.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var button := _finish_popup.get_node_or_null("Center/Window/VBox/MenuButton") as Button
	if button != null and not button.pressed.is_connected(_on_finish_menu_pressed):
		button.pressed.connect(_on_finish_menu_pressed)
	# 右上角红叉：与「返回主菜单」等效
	var close_button := _finish_popup.find_child("Close", true, false) as BaseButton
	if close_button != null and not close_button.pressed.is_connected(_on_finish_menu_pressed):
		close_button.pressed.connect(_on_finish_menu_pressed)
	# 红叉的悬停放大效果（弹窗每次展示前都确保只连一次）
	if close_button != null and not _close_hover_bound:
		_close_hover_bound = true
		_close_button = close_button
		close_button.mouse_entered.connect(_on_close_hover.bind(true))
		close_button.mouse_exited.connect(_on_close_hover.bind(false))


# 悬停放大/离开还原：以按钮中心为轴缩放
func _on_close_hover(entered: bool) -> void:
	if _close_button == null or not is_instance_valid(_close_button):
		return

	_close_button.pivot_offset = _close_button.size * 0.5

	if _close_tween != null and _close_tween.is_valid():
		_close_tween.kill()
	_close_tween = create_tween()
	var target := Vector2.ONE * (close_hover_scale if entered else 1.0)
	_close_tween.tween_property(_close_button, "scale", target, close_hover_time) \
		.set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)


# 教程里保证技能随时可用：逃生者（泡泡护盾）与追捕者（幽灵状态）都有 reset_skill
func _reset_tutorial_skill() -> void:
	if _player == null:
		return
	for node in _player.get_children():
		if node.has_method("reset_skill"):
			node.call("reset_skill")
			return


# 只重置处于冷却中的技能，不会打断正在生效的技能
func _reset_cooling_skill() -> void:
	if _player == null:
		return
	for node in _player.get_children():
		if not node.has_method("get_state") or not node.has_method("reset_skill"):
			continue
		# COOLDOWN = 2（泡泡护盾与幽灵技能的状态枚举一致）
		if int(node.call("get_state")) == 2:
			node.call("reset_skill")
			return


# 追捕者教程：玩家是否已经贴着墙（只比较前后距离，沿墙左右移动也算靠近）
func _is_near_skill_wall() -> bool:
	if _wall == null or _player == null:
		return false
	# 已经在墙后侧：允许直接释放（玩家可能绕路提前清空血量，进步骤后会立即结算）
	if _player.global_position.z < _wall.global_position.z:
		return true
	return absf(_player.global_position.z - _wall.global_position.z) <= wall_use_max_gap


# 追捕者教程：是否已经穿到墙的另一侧
func _has_passed_skill_wall() -> bool:
	if _wall == null or _player == null:
		return false
	return _player.global_position.z < _wall.global_position.z


# 追捕者的幽灵状态是否仍在生效
func _is_player_ghost_active() -> bool:
	if _player == null:
		return false
	for node in _player.get_children():
		if node.has_method("is_ghost_active"):
			return bool(node.call("is_ghost_active"))
	return false


# 墙后逃生者的血量变化：同步数字显示，清空后结束教程
func _on_wall_target_health_changed(current: int, maximum: int) -> void:
	_update_hp_label(current, maximum)
	if current > 0 or current_step != Step.PASS_WALL:
		return
	# 受击发生在物理/信号回调里，延迟到帧末再切步骤与弹窗
	call_deferred("_finish_step")


func _finish_step() -> void:
	if current_step == Step.FINISHED:
		return
	current_step = Step.FINISHED
	_apply_step()


func _update_hp_label(current: int, maximum: int) -> void:
	if _hp_label == null:
		return
	_hp_label.text = "生命值 %d/%d" % [maxi(current, 0), maxi(maximum, 1)]


func _on_finish_menu_pressed() -> void:
	GameManager.return_to_menu()


# 箭头指向某个目标（传 null 或已销毁的节点则隐藏）
func _set_highlight(target: Variant) -> void:
	if _arrow == null:
		return
	if target == null or not is_instance_valid(target) or not (target is Node3D):
		_arrow.visible = false
		return
	var node := target as Node3D
	_arrow.visible = true
	_arrow_base_y = node.global_position.y + 2.6
	_arrow.global_position = Vector3(node.global_position.x, _arrow_base_y, node.global_position.z)
