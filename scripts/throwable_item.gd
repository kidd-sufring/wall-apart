class_name ThrowableItem
extends RigidBody3D

# 可拾取投掷物基类（石头、南瓜等）。
# 未拾取时是普通刚体；玩家进入 PickupArea 后自动冻结并挂到手上。

## 拾取成功后发出，参数为被拾取的道具本身
signal picked_up(item: ThrowableItem)

enum ItemType { STONE, PUMPKIN }
# 道具状态机：IDLE = 待拾取，THROWN = 飞行中，DROPPED = 已落地可回收
enum ItemState { IDLE, THROWN, DROPPED }

# 南瓜爆炸后留在地上的橙色粘液滩
const SLIME_PUDDLE_SCENE := preload("res://assets/props/pumpkin/pumpkin_slime_puddle.tscn")

# 地面物理层（layer 4 = Ground），用来区分「落到地面」和「撞到墙体」
const GROUND_LAYER := 8
const HUNTER_GROUP := &"hunter"
# 南瓜刚脱手时忽略扔出者碰撞的保护时长，防止贴着身体扔出去就炸到自己
const THROWER_IGNORE_TIME := 0.2
# 联机兜底命中判定：投掷物中心与角色躯干中心的距离阈值
const NET_HIT_RADIUS := 0.8

@export var item_type: ItemType = ItemType.STONE
@export var display_name := ""                  # 留空时使用类型默认名称
@export var pickup_area_path := NodePath("PickupArea")
@export var dodge_detector_path := NodePath("DodgeDetector")
@export var dodge_nudge_up := 0.6               # 规避成功时投掷物轻微上飘，模拟擦身而过

var has_attempted_dodge := false                # 同一发投掷物只判定一次闪避
var pickup_enabled := true                      # 是否允许被拾取（教程等流程可临时锁定）

var current_state: ItemState = ItemState.IDLE   # 道具当前状态，拾取逻辑以它为准
var _thrower_ignore_time_left := 0.0            # 南瓜脱手后与扔出者碰撞保护的剩余时间

# ---------- 联机 ----------
var net_id := ""                                # 投掷物在双方场景里的固定标识（_ready 时记录，不受换父节点影响）
var _net_proxy := false                         # true = 本端只是对方投掷物的显示副本，不做命中结算
var _net_holder_role: StringName = &""          # 联机时当前持有它的角色 ID
var _net_proxy_hit_done := false                # 副本是否已在本端为“砸中本地玩家”补过结算
var _net_destroy_applied := false               # 本端是否已执行过销毁，避免双方同时上报导致重复爆炸

var _collected := false
var _pickup_cooldown := 0.0                     # 刚被扔出时的拾取冷却，避免立刻吸回手里
var _thrower: Node3D = null                     # 投出它的角色，命中检测时排除
var _collision_ignore: PhysicsBody3D = null     # 当前为飞行忽略碰撞的角色（脱手瞬间的扔出者）
var _hit_handled := false                       # 本次飞行是否已经处理过命中
var _flying := false                            # 是否处于飞行状态，落地后不再伤人
var _flight_time := 0.0
var _pickup_probe_time := 0.0                   # 拾取补检计时（见 _process）
var _last_speed := 0.0                          # 上一帧的线速度大小，用于撞击音量
var _impact_cooldown := 0.0                     # 撞击音冷却，避免弹跳时连续发声
var _net_prev_pos := Vector3.ZERO               # 上一帧位置，用于飞行中的扫掠命中判定
var _passthrough_targets: Array[CollisionObject3D] = []  # 当前被穿透的免疫目标
# 记录场景里配置好的碰撞层/掩码，投掷时恢复，保证道具落地后仍是正常刚体
var _original_collision_layer := 0
var _original_collision_mask := 9

@onready var pickup_area: Area3D = get_node_or_null(pickup_area_path) as Area3D
@onready var dodge_detector: Area3D = get_node_or_null(dodge_detector_path) as Area3D

## 静态：预热南瓜爆炸特效。
## 粘液滩第一次被绘制时，渲染器要现编译它的自定义着色器管线（实测可达上百毫秒），
## 于是第一个南瓜落地会卡一下。这里在准备阶段用离屏 SubViewport 渲染一帧把它消化掉。
static func prewarm_slime_puddle(root: Node) -> void:
	if root == null or not root.is_inside_tree():
		return
	# 只取粘液滩的网格与材质，不把整滩加进场景（避免提前触发贴地与扩散动画）
	var source := SLIME_PUDDLE_SCENE.instantiate() as Node3D
	var source_mesh := source.get_node_or_null("Mesh") as MeshInstance3D
	if source_mesh == null:
		source.free()
		return
	var quad_mesh := source_mesh.mesh
	var material := source_mesh.get_surface_override_material(0)
	source.free()

	var viewport := SubViewport.new()
	viewport.size = Vector2i(16, 16)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = quad_mesh
	quad.set_surface_override_material(0, material)
	quad.position = Vector3(0.0, 0.0, -2.0)
	viewport.add_child(quad)

	await root.get_tree().process_frame
	await root.get_tree().process_frame
	viewport.queue_free()

static func get_type_display_name(type: ItemType) -> String:
	match type:
		ItemType.STONE:
			return "石头"
		ItemType.PUMPKIN:
			return "南瓜"
	return "道具"

func get_display_name() -> String:
	if not display_name.is_empty():
		return display_name
	return get_type_display_name(item_type)

## 道具原点在模型底部，握持时需要把原点下移半高，让几何中心落在两手中点
func get_hold_height_offset() -> float:
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		return -(col.shape as BoxShape3D).size.y * 0.5
	return 0.0

## AI 拾取判定用：只有躺在地上的道具（未被持有、不在飞行、过了拾取冷却）才能被捡起
## player 传入时顺带排除“自己扔出的道具”
func is_available_for_pickup(player: Node3D = null) -> bool:
	if current_state == ItemState.THROWN:
		return false
	if player != null and player == _thrower:
		return false
	return pickup_enabled and not _collected and not _flying and _pickup_cooldown <= 0.0

## 教程等流程用来限制“到某一步才能捡某件道具”
func set_pickup_enabled(enabled: bool) -> void:
	pickup_enabled = enabled

func _ready() -> void:
	add_to_group("throwable_items")
	# 投掷物会被挂到手上/扔回场景，节点路径会变，所以启动时记一份固定标识用于联机同步。
	# 刷怪器会预先写一个按出生序号生成的稳定 ID：节点重名时 Godot 会改名成
	# @RigidBody3D@N（进程内自增，两台机器不一样），直接用路径会导致两端 ID 对不上。
	var preset_id := str(get_meta(&"net_id", ""))
	net_id = preset_id if not preset_id.is_empty() else str(get_path())
	if NetworkManager.is_online():
		NetworkManager.item_event.connect(_on_net_item_event)
	# 在编辑器里配置的层/掩码会被拾取流程清零，这里先存一份原始值
	_original_collision_layer = collision_layer
	_original_collision_mask = collision_mask
	# 开启接触监听：飞行中撞到角色时触发 body_entered
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)
	if item_type == ItemType.STONE:
		# 石头靠物理休眠判定“真正停稳”，再切到可拾取状态
		sleeping_state_changed.connect(_on_sleeping_state_changed)
	if dodge_detector != null:
		# 只在飞行中开启监测，拿在手上或躺在地上时不参与闪避判定
		dodge_detector.monitoring = false
		dodge_detector.body_entered.connect(_on_dodge_detector_body_entered)
	else:
		push_warning("%s 缺少 DodgeDetector 子节点，追捕者无法闪避该投掷物" % name)
	if pickup_area == null:
		push_warning("%s 缺少 PickupArea 子节点，无法自动拾取" % name)
		return
	pickup_area.body_entered.connect(_on_pickup_area_body_entered)

func _on_pickup_area_body_entered(body: Node3D) -> void:
	# 飞行中的投掷物不能被接住；扔出者也不能回收自己扔出的道具
	if current_state == ItemState.THROWN:
		return
	if body == _thrower:
		return
	if _collected or _pickup_cooldown > 0.0 or not body.is_in_group("Player"):
		return
	# 物理回调期间不能直接改变节点结构，延迟到本帧物理处理结束后再挂载
	call_deferred("try_pickup", body)

# 石头停止滚动进入休眠：THROWN -> DROPPED，重新开放拾取
func _on_sleeping_state_changed() -> void:
	if item_type != ItemType.STONE or current_state != ItemState.THROWN or not sleeping:
		return
	_enter_dropped_state()

func _enter_dropped_state() -> void:
	current_state = ItemState.DROPPED
	_flying = false
	contact_monitor = false
	collision_mask = _original_collision_mask
	# 落地后不再排除扔出者：否则自己扔出的道具永远捡不回来（单人游戏里只有自己）
	# 与扔出者的碰撞例外保留，避免小石头压在身上把玩家卡住
	_thrower = null
	if pickup_area != null:
		pickup_area.set_deferred("monitoring", true)
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", false)
	# 联机：让对手那端的副本也变成可拾取的落地状态（对方捡走后会重新广播归属）
	if NetworkManager.is_online() and not _net_proxy:
		NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.REST,
			{"pos": global_position})

# DodgeDetector 进入角色：按目标当前的响应触发几率掷骰，成功则执行战术规避
func _on_dodge_detector_body_entered(body: Node3D) -> void:
	if has_attempted_dodge or _collected or not _flying:
		return
	if body == _thrower:
		return
	# AI 追捕者与 AI 逃生者都实现同一套战术规避接口
	if not body.has_method("get_evasion_trigger_chance"):
		return
	if not body.has_method("execute_tactical_evasion"):
		return

	# 每发投掷物只判定一次（无论成功与否）
	has_attempted_dodge = true
	var trigger_chance := float(body.call("get_evasion_trigger_chance"))
	var roll := randf()
	if trigger_chance > 0.0 and roll <= trigger_chance:
		if body.has_method("execute_tactical_evasion"):
			body.call("execute_tactical_evasion", _get_evasion_direction())
			# 规避成功：投掷物轻微上飘，模拟擦身而过
			linear_velocity += Vector3.UP * dodge_nudge_up
		return
	if body.has_method("on_evasion_judged_without_success"):
		body.call("on_evasion_judged_without_success")

# 传给追捕者的规避方向：飞行方向的水平法线，随机取左或右
func _get_evasion_direction() -> Vector3:
	var flat := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if flat.length_squared() < 0.01:
		return global_transform.basis.x.normalized()
	flat = flat.normalized()
	var side := Vector3(-flat.z, 0.0, flat.x)
	return side * (1.0 if randf() < 0.5 else -1.0)

func _process(delta: float) -> void:
	if _pickup_cooldown > 0.0:
		_pickup_cooldown = maxf(_pickup_cooldown - delta, 0.0)
	if _impact_cooldown > 0.0:
		_impact_cooldown = maxf(_impact_cooldown - delta, 0.0)
	# 南瓜防自爆窗口到期：恢复与扔出者的碰撞，炸到脚下时能正常结算
	if _thrower_ignore_time_left > 0.0:
		_thrower_ignore_time_left = maxf(_thrower_ignore_time_left - delta, 0.0)
		if _thrower_ignore_time_left <= 0.0 and item_type == ItemType.PUMPKIN:
			_clear_collision_ignore()
	_last_speed = linear_velocity.length()
	_sync_projectile_passthrough()
	# 联机：远端角色由网络插值驱动，物理接触不一定稳定触发，补一层扫掠命中判定
	if _flying and not _net_proxy and not _hit_handled and NetworkManager.is_online():
		_check_net_character_hit()
	_net_prev_pos = global_position
	# 速度降下来说明已经落地：关闭命中检测，避免躺在地上的道具再砸晕路过的玩家
	if _flying:
		_flight_time += delta
		if _flight_time > 5.0 or (_flight_time > 0.2 and linear_velocity.length() < 1.0):
			_flying = false
			if item_type == ItemType.STONE and current_state == ItemState.THROWN:
				# 石头落地就恢复可拾取，不必等物理休眠：在斜坡上滚动或压在其他物体上时
				# 刚体可能长时间（甚至永远）不进入 sleeping，石头会一直卡在 THROWN 捡不起来
				_enter_dropped_state()
			else:
				contact_monitor = false
				collision_mask = _original_collision_mask

	# 兜底补检：玩家一开始就站在范围内（或道具被扔到脚下）时 body_entered 不会重复触发
	if current_state != ItemState.THROWN and not _collected and _pickup_cooldown <= 0.0 \
			and pickup_area != null and pickup_area.monitoring:
		_pickup_probe_time += delta
		if _pickup_probe_time >= 0.25:
			_pickup_probe_time = 0.0
			for body in pickup_area.get_overlapping_bodies():
				if body.is_in_group("Player") and body != _thrower:
					call_deferred("try_pickup", body)
					break

## 把道具挂到玩家 HandAttachment 下；返回是否拾取成功
func try_pickup(player: Node3D) -> bool:
	if _collected or not is_instance_valid(player):
		return false
	# 飞行中不能被接住，扔出者也不能回收自己扔出的道具
	if current_state == ItemState.THROWN or player == _thrower:
		return false
	# 教程等流程可能还没轮到这件道具
	if not pickup_enabled:
		return false

	var hand := player.find_child("HandAttachment", true, false) as Node3D
	if hand == null:
		push_warning("%s 没有 HandAttachment 节点，无法拾取道具" % player.name)
		return false

	# 投掷动作播放期间不接受新道具（脱手后到收招结束的这段空档）
	if player.get("is_throwing") == true:
		return false
	# 倒地击晕期间也不能捡东西
	if player.get("is_stunned") == true:
		return false
	# 技能等状态自行决定是否禁止拾取
	if player.has_method("can_pickup_item") and not bool(player.call("can_pickup_item")):
		return false

	# 玩家已经持有道具时不重复拾取
	if hand.get_child_count() > 0:
		return false
	var held = player.get("current_item")
	if held != null and is_instance_valid(held) and held != self:
		return false

	_collected = true
	current_state = ItemState.IDLE
	if pickup_area != null:
		pickup_area.monitoring = false
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", false)
	# 被拿在手上时不再监听接触
	contact_monitor = false
	# 换人持有后要清掉上一手的飞行碰撞例外，否则新主人扔出去会穿过对方
	_clear_collision_ignore()

	# 冻结物理并关闭碰撞，避免挂载后被手部或场景推开
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0

	var old_parent := get_parent()
	if old_parent != null:
		old_parent.remove_child(self)
	hand.add_child(self)
	# 本地坐标与旋转清零，让道具贴合 HandAttachment 的位置
	transform = Transform3D.IDENTITY

	if player.has_method("equip_item"):
		player.equip_item(self)
	picked_up.emit(self)

	# 联机：接管所有权，并让对手看到“这个人手上拿着这件道具”
	_net_proxy = false
	if NetworkManager.is_online():
		var role := _net_role_of(player)
		_net_holder_role = role
		if role != &"":
			NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.PICKUP,
				{"role": String(role)})
	return true

## 由角色 release_item() 调用：脱离手部、挂回世界并施加一次冲量后自由飞行
## base_velocity：脱手瞬间继承的投掷者速度；spin_axis / spin_speed：飞行中的自转
func launch(world_parent: Node3D, throw_impulse: Vector3, thrower: Node3D = null,
		base_velocity: Vector3 = Vector3.ZERO, spin_axis: Vector3 = Vector3.ZERO,
		spin_speed := 0.0) -> void:
	# 先记录世界变换，换父节点后再还原，保证脱手位置不跳变
	var world_transform := global_transform
	var old_parent := get_parent()
	if old_parent != null:
		old_parent.remove_child(self)
	if world_parent != null and world_parent != self:
		world_parent.add_child(self)
	global_transform = world_transform

	_collected = false
	_hit_handled = false
	_flying = true
	current_state = ItemState.THROWN
	has_attempted_dodge = false
	_flight_time = 0.0
	_thrower = thrower
	_net_prev_pos = global_position
	_thrower_ignore_time_left = THROWER_IGNORE_TIME
	_pickup_cooldown = 0.35
	# 恢复物理与碰撞，并额外检测 Survivor / Hunter 层，飞行中才能撞到角色
	freeze = false
	collision_layer = _original_collision_layer
	collision_mask = _original_collision_mask | 2 | 4
	# 脱手瞬间忽略投出者：南瓜只保护 0.2 秒，石头则始终不会砸到扔出者自己。
	# 投掷物出手时就在扔出者身体里，不忽略会被物理引擎当场推歪（远端副本同样需要）
	_set_collision_ignore(thrower as PhysicsBody3D)
	contact_monitor = true
	# 恢复物理并唤醒刚体，否则交给物理引擎的冲量要等自动唤醒后才生效
	freeze = false
	sleeping = false
	# 直接算出脱手速度。apply_central_impulse 要到物理步才写进刚体，
	# 紧接着读 linear_velocity 拿到的仍是旧值，广播给对手的速度就会是 0（对方看到原地掉地）
	var launch_velocity := base_velocity + throw_impulse / maxf(mass, 0.001)
	linear_velocity = launch_velocity
	angular_velocity = spin_axis.normalized() * spin_speed
	# 飞行期间关闭拾取检测：只有石头停稳后（DROPPED）才重新开放
	if pickup_area != null:
		pickup_area.set_deferred("monitoring", false)
	# 飞行中才开启闪避检测
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", true)

	# 联机：广播出手瞬间的位置与速度，对手那端用同样参数复制一发飞行中的投掷物
	if NetworkManager.is_online():
		_net_proxy = false
		_net_holder_role = &""
		NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.THROW, {
			"pos": global_position,
			"vel": launch_velocity,
			"spin": angular_velocity,
			"thrower": String(_net_role_of(thrower)),
		})

## 主动丢下（如追捕者开技能）：不给冲量、落地后也不再伤人
func drop(world_parent: Node3D) -> void:
	var world_transform := global_transform
	var old_parent := get_parent()
	if old_parent != null:
		old_parent.remove_child(self)
	if world_parent != null and world_parent != self:
		world_parent.add_child(self)
	global_transform = world_transform

	_collected = false
	_flying = false
	current_state = ItemState.DROPPED if item_type == ItemType.STONE else ItemState.IDLE
	_thrower = null                     # 主动丢下后不再限制回收者
	_clear_collision_ignore()
	_hit_handled = true                 # 本次不再触发命中效果
	_pickup_cooldown = 0.35
	freeze = false
	sleeping = false
	collision_layer = _original_collision_layer
	collision_mask = _original_collision_mask   # 只碰墙和地面，不碰角色
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	contact_monitor = false
	if pickup_area != null:
		pickup_area.set_deferred("monitoring", true)
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", false)
	# 联机：主动丢下同样要让对手看到道具落到自己脚下
	if NetworkManager.is_online() and not _net_proxy:
		NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.REST,
			{"pos": global_position})

## 飞行中撞到物体：石头击晕角色、南瓜减速角色，随后销毁自身
## 南瓜撞到墙体不处理，继续飞行，等落到地面才爆炸留滩并销毁
func _on_body_entered(body: Node3D) -> void:
	if _net_proxy:
		_on_proxy_body_entered(body)
		return
	if _hit_handled or _collected or not _flying:
		return
	# 命中判定：南瓜在 0.2 秒防自爆窗口内忽略扔出者；石头始终不会砸到扔出者自己
	if body == _thrower and (item_type != ItemType.PUMPKIN or _thrower_ignore_time_left > 0.0):
		return

	# 命中角色：石头击晕、南瓜减速
	if body is CharacterBase:
		_handle_character_hit(body)
		return

	# 撞到墙体等非地面物体：只出撞击声，不销毁，南瓜继续飞行等落地
	if not _is_ground_body(body):
		_play_impact_sound()
		return

	# 落到地面：南瓜爆炸留滩并销毁
	if item_type == ItemType.PUMPKIN:
		_hit_handled = true
		_play_explosion_sound()
		_spawn_slime_puddle()
		_net_destroy(true)
		return

	# 石头落地：出闷响，本体留在原地可以再次拾取
	_play_impact_sound()

# 命中角色结算（物理接触与联机距离兜底共用）
func _handle_character_hit(body: CharacterBase) -> void:
	if _hit_handled or _collected or not _flying:
		return
	# 幽灵状态免疫投掷物：接触信号或扫掠判定抢先到达时也不能算命中
	if body.has_method("is_projectile_immune") and bool(body.call("is_projectile_immune")):
		return
	# 倒地中的角色保留碰撞层（追捕者可以继续攻击），但投掷物不再重复结算
	if body.get("is_stunned") == true:
		return
	_hit_handled = true
	# 命中角色：南瓜爆炸音，石头用命中音
	if item_type == ItemType.PUMPKIN:
		_play_explosion_sound()
	else:
		AudioManager.play_3d_randomized(&"stone_hit", global_position, -2.0, 1.0, 0.06, 1.0, 5.0, 30.0)
	# 真实命中角色：让它进入高度警觉，下一次响应几率提升
	if body.has_method("on_projectile_hit"):
		body.call("on_projectile_hit")
	match item_type:
		ItemType.STONE:
			if body.has_method("apply_stun"):
				body.apply_stun()
		ItemType.PUMPKIN:
			if body.has_method("apply_slow"):
				body.apply_slow()
			_spawn_slime_puddle()
	# 联机：命中效果由投掷方广播，对手在自己那台机器上第二次结算（本地玩家才应用）
	if NetworkManager.is_online():
		var role := _net_role_of(body)
		if role != &"":
			NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.HIT,
				{"role": String(role), "kind": int(item_type)})
	_net_destroy(item_type == ItemType.PUMPKIN)

# 联机兜底：远端角色位置由网络插值驱动，接触信号可能漏，按本帧位移扫掠再判一次。
# 用「上一帧位置 -> 当前位置」这条线段做近似扫掠，避免高速飞行时只做点检测而漏过身体。
func _check_net_character_hit() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	var from := _net_prev_pos
	var to := global_position
	for node in root.find_children("*", "", true, false):
		var character := node as CharacterBase
		if character == null or character == _thrower or not character.active:
			continue
		# 远端追捕者可能正处于幽灵状态，扫掠判定同样要跳过免疫目标
		if character.has_method("is_projectile_immune") and bool(character.call("is_projectile_immune")):
			continue
		var base := character.global_position
		var center := base + Vector3.UP * 0.9
		var closest := Geometry3D.get_closest_point_to_segment(center, from, to)
		var flat := Vector2(closest.x - base.x, closest.z - base.z).length()
		var height := closest.y - base.y
		if flat <= NET_HIT_RADIUS and height >= -0.1 and height <= 1.9:
			_handle_character_hit(character)
			return

# 远端投掷物在本端只做显示，但如果它撞到的是本机玩家自己，就由本端补一次结算：
# 另一端只能拿插值出来的远端角色做判定，偶尔会漏；被砸的一方自己判最准。
func _on_proxy_body_entered(body: Node3D) -> void:
	if _net_proxy_hit_done or not _flying or not (body is CharacterBase):
		return
	var character := body as CharacterBase
	if not character.player_controlled:
		return
	if character.has_method("is_projectile_immune") and bool(character.call("is_projectile_immune")):
		return
	_net_proxy_hit_done = true
	_net_destroy_applied = true
	_hit_handled = true
	_flying = false
	if item_type == ItemType.PUMPKIN:
		character.apply_slow()
		_play_explosion_sound()
		_spawn_slime_puddle()
	else:
		character.apply_stun()
	# 命中端把「命中 + 销毁」一起补发给投掷方：投掷端可能因远端插值漏判，
	# 南瓜必须在碰到对方的这一瞬间就在两端同时爆炸消失
	var role := _net_role_of(character)
	if role != &"":
		NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.HIT,
			{"role": String(role), "kind": int(item_type)})
	NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.DESTROY,
		{"pos": global_position, "puddle": item_type == ItemType.PUMPKIN})
	queue_free()

# 销毁并通知对手（南瓜爆炸时顺带让对方也生成粘液滩）
func _net_destroy(explodes: bool) -> void:
	if _net_destroy_applied:
		return
	_net_destroy_applied = true
	if NetworkManager.is_online() and not _net_proxy:
		NetworkManager.send_item_event(net_id, NetworkManager.ItemEvent.DESTROY,
			{"pos": global_position, "puddle": explodes})
	queue_free()

# ---------- 联机：接收对手的投掷物状态 ----------

func _on_net_item_event(id: String, kind: int, data: Dictionary) -> void:
	if id != net_id or not is_inside_tree():
		return
	match kind:
		NetworkManager.ItemEvent.PICKUP:
			_net_apply_pickup(StringName(str(data.get("role", ""))))
		NetworkManager.ItemEvent.THROW:
			_net_apply_throw(data)
		NetworkManager.ItemEvent.REST:
			_net_apply_rest(data)
		NetworkManager.ItemEvent.HIT:
			_net_apply_hit(data)
		NetworkManager.ItemEvent.DESTROY:
			_net_apply_destroy(data)


# 对手捡起了道具：把本端的副本挂到对手手上（手部跟随位置同步，看起来就是对方拿着）
func _net_apply_pickup(role: StringName) -> void:
	_net_proxy = true
	_net_holder_role = role
	var player := _find_character(role)
	if player == null:
		return
	var hand := player.find_child("HandAttachment", true, false) as Node3D
	if hand == null:
		return

	_collected = true
	_flying = false
	_hit_handled = true
	current_state = ItemState.IDLE
	if pickup_area != null:
		pickup_area.set_deferred("monitoring", false)
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", false)
	contact_monitor = false
	_clear_collision_ignore()
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0

	var old_parent := get_parent()
	if old_parent != null:
		old_parent.remove_child(self)
	hand.add_child(self)
	transform = Transform3D.IDENTITY
	# 借用角色的手持逻辑，让远端道具也跟随手骨动画
	if player.has_method("equip_item"):
		player.equip_item(self)


# 对手把道具扔了出来：用对方的初始速度在本端复制一发飞行中的副本
func _net_apply_throw(data: Dictionary) -> void:
	_net_release_from_character()
	_net_proxy = true
	_net_holder_role = &""
	_collected = false
	_hit_handled = true          # 副本只做显示，命中结算由投掷方负责
	_net_proxy_hit_done = false  # 但砸到本机玩家时要由本端补一次结算
	_net_destroy_applied = false
	_flying = true
	has_attempted_dodge = true
	_flight_time = 0.0
	current_state = ItemState.THROWN

	global_position = data.get("pos", global_position)
	_net_prev_pos = global_position
	# 出手位置就在对方角色身体里：本端副本也必须忽略对方角色，否则会被物理引擎当场推歪
	_thrower = _find_character(StringName(str(data.get("thrower", ""))))
	_thrower_ignore_time_left = THROWER_IGNORE_TIME
	_set_collision_ignore(_thrower as PhysicsBody3D)
	freeze = false
	sleeping = false
	collision_layer = _original_collision_layer
	collision_mask = _original_collision_mask | 2 | 4
	linear_velocity = data.get("vel", Vector3.ZERO)
	angular_velocity = data.get("spin", Vector3.ZERO)
	contact_monitor = true
	if pickup_area != null:
		pickup_area.set_deferred("monitoring", false)
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", false)


# 对手的道具落地：本端副本变成可拾取状态，捡到后即接管所有权
func _net_apply_rest(data: Dictionary) -> void:
	_net_release_from_character()
	_net_proxy = true
	_net_holder_role = &""
	_collected = false
	_flying = false
	_hit_handled = true
	_net_proxy_hit_done = false
	_net_destroy_applied = false
	current_state = ItemState.DROPPED
	_thrower = null
	_clear_collision_ignore()
	global_position = data.get("pos", global_position)
	freeze = false
	sleeping = false
	collision_mask = _original_collision_mask
	contact_monitor = false
	if pickup_area != null:
		pickup_area.set_deferred("monitoring", true)
	if dodge_detector != null:
		dodge_detector.set_deferred("monitoring", false)


# 把道具从对手手上摘下来（清掉手持引用并挂回场景），避免继续被手骨带着走
func _net_release_from_character() -> void:
	var holder := _find_character(_net_holder_role)
	if holder == null:
		return
	if holder.get("current_item") == self:
		holder.set("current_item", null)
	var hand := holder.find_child("HandAttachment", true, false) as Node3D
	if hand == null or get_parent() != hand:
		return
	var world_parent := get_tree().current_scene
	if world_parent == null:
		world_parent = get_tree().root
	hand.remove_child(self)
	world_parent.add_child(self)


# 对手命中了本端玩家：在本机重新播放一次击晕 / 减速，减速染色才会显示出来
func _net_apply_hit(data: Dictionary) -> void:
	var target := _find_character(StringName(str(data.get("role", ""))))
	if target == null:
		return
	# 本机玩家与远端角色都补一次表现：命中可能由任意一端先判定出来，
	# 另一端需要同步减速染色/击倒；重复施加是幂等的（已倒地会忽略、减速只刷新时长）
	var kind := int(data.get("kind", 0))
	if kind == ItemType.STONE:
		if target.has_method("apply_stun"):
			target.call("apply_stun")
	else:
		if target.has_method("apply_slow"):
			target.call("apply_slow")


# 对手的道具已销毁（南瓜爆炸会在本端补一滩粘液与爆炸音）
func _net_apply_destroy(data: Dictionary) -> void:
	# 命中端与投掷端可能同时判定到这次命中并各自上报销毁，只处理第一次
	if _net_destroy_applied:
		return
	_net_destroy_applied = true
	if bool(data.get("puddle", false)):
		global_position = data.get("pos", global_position)
		_play_explosion_sound()
		_spawn_slime_puddle()
	queue_free()


# 取角色身上的联机角色 ID（NetworkSync.role_id）
func _net_role_of(node: Node) -> StringName:
	if node == null:
		return &""
	var sync := node.get_node_or_null("NetworkSync")
	if sync == null:
		return &""
	return StringName(str(sync.get("role_id")))


# 按角色 ID 找到场景里的角色节点（双方场景结构一致）
func _find_character(role: StringName) -> CharacterBase:
	var root := get_tree().current_scene
	if root == null or role == &"":
		return null
	for node in root.find_children("*", "", true, false):
		var character := node as CharacterBase
		if character != null and _net_role_of(character) == role:
			return character
	return null

# 幽灵状态的追捕者免疫投掷物：飞行中动态维护碰撞例外，让道具直接穿过身体。
# 技能可能在飞行途中开启或结束，所以每帧同步一次。
func _sync_projectile_passthrough() -> void:
	if not _flying:
		return
	for node in get_tree().get_nodes_in_group(HUNTER_GROUP):
		var other := node as CollisionObject3D
		if other == null or other == _thrower:
			continue
		var immune := other.has_method("is_projectile_immune") \
			and bool(other.call("is_projectile_immune"))
		var has_exception := _passthrough_targets.has(other)
		if immune and not has_exception:
			add_collision_exception_with(other)
			_passthrough_targets.append(other)
		elif not immune and has_exception:
			remove_collision_exception_with(other)
			_passthrough_targets.erase(other)

	# 目标已被回收时清掉残留引用
	for i in range(_passthrough_targets.size() - 1, -1, -1):
		if not is_instance_valid(_passthrough_targets[i]):
			_passthrough_targets.remove_at(i)

# 脱手瞬间忽略扔出者（含远端副本）：出手点在角色体内，不忽略会被碰撞解算当场推歪
func _set_collision_ignore(body: PhysicsBody3D) -> void:
	_clear_collision_ignore()
	if body == null:
		return
	_collision_ignore = body
	add_collision_exception_with(body)

func _clear_collision_ignore() -> void:
	if _collision_ignore != null and is_instance_valid(_collision_ignore):
		remove_collision_exception_with(_collision_ignore)
	_collision_ignore = null

# 该碰撞体是否属于地面层
func _is_ground_body(body: Node3D) -> bool:
	if body is CollisionObject3D:
		return ((body as CollisionObject3D).collision_layer & GROUND_LAYER) != 0
	return false

# 在命中点正下方的地面上留下一滩橙色粘液（粘液滩自行贴地、淡出并销毁）
func _spawn_slime_puddle() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var parent := tree.current_scene
	if parent == null:
		parent = tree.root
	var puddle := SLIME_PUDDLE_SCENE.instantiate() as Node3D
	parent.add_child(puddle)
	puddle.global_position = global_position

# 南瓜爆炸音：命中角色或落到地面爆炸时都会播放
func _play_explosion_sound() -> void:
	AudioManager.play_3d_randomized(&"pumpkin", global_position, -2.0, 1.0, 0.06, 1.0, 6.0, 30.0)

# 撞击闷响：用于投掷物撞墙与石头落地。
# 音量由撞击速度决定，3D 播放负责距离衰减（近大远小）与方位声像。
func _play_impact_sound() -> void:
	if _impact_cooldown > 0.0:
		return
	_impact_cooldown = 0.12

	var tree := get_tree()
	if tree == null:
		return
	var root := tree.current_scene
	if root == null:
		root = tree.root
	if _hit_sound == null:
		_hit_sound = _build_hit_sound()

	var player := AudioStreamPlayer3D.new()
	player.stream = _hit_sound
	# 1 m/s 时最轻，14 m/s 以上达到最大音量
	player.volume_db = clampf(remap(_last_speed, 1.0, 14.0, -16.0, 0.0), -16.0, 0.0)
	player.pitch_scale = randf_range(0.92, 1.08)
	player.unit_size = 4.0
	player.max_distance = 28.0
	root.add_child(player)
	player.global_position = global_position
	player.finished.connect(player.queue_free)
	player.play()

static var _hit_sound: AudioStreamWAV = null

static func _build_hit_sound() -> AudioStreamWAV:
	const RATE := 22050
	var count := int(RATE * 0.18)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261029
	for i in range(count):
		var t := float(i) / float(RATE)
		var env := exp(-t * 26.0)  # 快速衰减，模拟闷响
		var sample := (rng.randf_range(-1.0, 1.0) * 0.35 + sin(TAU * 120.0 * t) * 0.5) * env
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	return stream
