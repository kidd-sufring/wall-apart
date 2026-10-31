extends Node

# 局域网联机管理器（Autoload: NetworkManager）
# Host-Client 架构：主机 = peer 1，客户端通过 ENet 连接。
# 选角冲突、血量、胜负都由主机裁决。

const PORT := 7777
const MAX_CLIENTS := 1                  # 2 人房：1 主机 + 1 客户端
const ROLE_HUNTER := &"hunter_sid"
const ROLE_SURVIVOR := &"survivor_sonny"

enum Mode { OFFLINE, HOST, CLIENT }

# 投掷物同步事件：投掷物自身会换父节点（挂到手上 / 扔回场景），
# RPC 不能挂在它身上（节点路径会变），统一由本 Autoload 中继广播。
enum ItemEvent { PICKUP, THROW, REST, HIT, DESTROY }

var mode: int = Mode.OFFLINE
var local_nickname := ""
var players: Dictionary = {}            # peer_id -> {"nickname": String, "role": StringName}
var selections: Dictionary = {}         # role -> peer_id
var game_result := -1

var _signals_connected := false
var _hit_cooldown := 0.0                # 主机端的受击冷却，与逃生者无敌时间一致
var _shield_block_grace := 0.0          # 主机端：护盾挡下攻击后的免伤窗口

signal lobby_changed                    # 玩家名单变化
signal selection_changed                # 选角变化
signal select_rejected(role: StringName)  # 想选的角色已被别人选走
signal enter_select                     # 房间满员，双方进入角色选择
signal game_started                     # 主机确认开始，准备切场景
signal rematch_requested                # 任意一方点了重新开始
signal result_received(result: int)     # 主机下发的胜负
signal status_changed(text: String)     # 大厅状态提示
signal hp_received(current: int)        # 主机下发的逃生者血量
signal item_event(net_id: String, kind: int, data: Dictionary)  # 投掷物状态同步


func _process(delta: float) -> void:
	if _hit_cooldown > 0.0:
		_hit_cooldown = maxf(_hit_cooldown - delta, 0.0)
	if _shield_block_grace > 0.0:
		_shield_block_grace = maxf(_shield_block_grace - delta, 0.0)


# ---------- 查询 ----------

func is_online() -> bool:
	return mode != Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


func get_my_id() -> int:
	return multiplayer.get_unique_id()


func get_my_role() -> StringName:
	return players.get(get_my_id(), {}).get("role", &"")


func get_nickname_of(peer_id: int) -> String:
	return str(players.get(peer_id, {}).get("nickname", "玩家%d" % peer_id))


func get_role_owner(role: StringName) -> int:
	return int(selections.get(role, 0))


# 该角色是否已被其他玩家选走
func is_role_taken_by_other(role: StringName) -> bool:
	if not selections.has(role):
		return false
	return int(selections[role]) != get_my_id()


# 取本机局域网 IPv4（优先 192.168 / 10 / 172 网段）
static func get_lan_ip() -> String:
	var candidates: Array[String] = []
	for addr in IP.get_local_addresses():
		if addr.contains(":"):          # 跳过 IPv6
			continue
		if addr.begins_with("127."):    # 跳过回环
			continue
		candidates.append(addr)
	for addr in candidates:
		if addr.begins_with("192.168.") or addr.begins_with("10.") or addr.begins_with("172."):
			return addr
	return candidates[0] if not candidates.is_empty() else "127.0.0.1"


# ---------- 建房 / 加入 / 离开 ----------

func host_game(nickname: String) -> bool:
	var nick := nickname.strip_edges()
	if nick.is_empty():
		status_changed.emit("请输入昵称")
		return false

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		status_changed.emit("创建房间失败（端口 %d 可能被占用）" % PORT)
		return false

	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	local_nickname = nick
	players = {1: {"nickname": nick, "role": &""}}
	selections.clear()
	game_result = -1
	_connect_signals()

	status_changed.emit("房间已创建，等待玩家加入…")
	lobby_changed.emit()
	return true


func join_game(ip: String, nickname: String) -> bool:
	var nick := nickname.strip_edges()
	var address := ip.strip_edges()
	if nick.is_empty():
		status_changed.emit("请输入昵称")
		return false
	if address.is_empty() or not address.is_valid_ip_address():
		status_changed.emit("请输入有效的主机 IP")
		return false

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		status_changed.emit("连接失败（IP 或端口错误）")
		return false

	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	local_nickname = nick
	selections.clear()
	game_result = -1
	_connect_signals()

	status_changed.emit("正在连接 %s…" % address)
	return true


func leave_room() -> void:
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	players.clear()
	selections.clear()
	game_result = -1
	_hit_cooldown = 0.0
	_shield_block_grace = 0.0


func _connect_signals() -> void:
	if _signals_connected:
		return
	_signals_connected = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _on_peer_connected(id: int) -> void:
	if not is_host():
		return
	players[id] = {"nickname": "玩家%d" % id, "role": &""}
	status_changed.emit("玩家已连接，等待同步昵称…")
	lobby_changed.emit()


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	for role in selections.keys():
		if int(selections[role]) == id:
			selections.erase(role)
	if is_host():
		rpc("_rpc_sync_players", players, selections)
	lobby_changed.emit()
	selection_changed.emit()
	status_changed.emit("有玩家断开连接")


func _on_connected_to_server() -> void:
	status_changed.emit("已连接，正在同步昵称…")
	rpc_id(1, "_rpc_register", local_nickname)


func _on_connection_failed() -> void:
	status_changed.emit("连接失败，请检查 IP 与防火墙")
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE


func _on_server_disconnected() -> void:
	status_changed.emit("主机已关闭房间")
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	lobby_changed.emit()


# ---------- 玩家名单 ----------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_register(nickname: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	players[id] = {"nickname": nickname, "role": &""}
	rpc("_rpc_sync_players", players, selections)
	lobby_changed.emit()
	status_changed.emit("%s 加入了房间" % nickname)

	# 两人到齐 → 双方进入角色选择
	if players.size() >= 2:
		await get_tree().create_timer(0.4).timeout
		if is_inside_tree() and is_host():
			rpc("_rpc_enter_select")


@rpc("authority", "call_local", "reliable")
func _rpc_enter_select() -> void:
	enter_select.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_players(data: Dictionary, picks: Dictionary) -> void:
	players = data.duplicate(true)
	selections = picks.duplicate(true)
	lobby_changed.emit()
	selection_changed.emit()


# ---------- 选角（主机裁决） ----------

func request_select(role: StringName) -> void:
	if not is_online():
		return
	if is_host():
		_handle_select(1, role)
	else:
		rpc_id(1, "_rpc_request_select", role)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_select(role: StringName) -> void:
	if not is_host():
		return
	_handle_select(multiplayer.get_remote_sender_id(), role)


func _handle_select(peer_id: int, role: StringName) -> void:
	# 已被别人选走 → 拒绝并通知请求方
	if selections.has(role) and int(selections[role]) != peer_id:
		_notify_select_rejected(peer_id, role)
		return
	# 一个玩家只能占一个角色
	for r in selections.keys():
		if int(selections[r]) == peer_id:
			selections.erase(r)
	selections[role] = peer_id
	if players.has(peer_id):
		players[peer_id]["role"] = role

	rpc("_rpc_apply_select", peer_id, role, selections, players)


# 拒绝选角：主机自己直接发信号，客户端由主机回发 RPC
func _notify_select_rejected(peer_id: int, role: StringName) -> void:
	if peer_id == get_my_id():
		select_rejected.emit(role)
	else:
		rpc_id(peer_id, "_rpc_select_rejected", role)


@rpc("authority", "call_remote", "reliable")
func _rpc_select_rejected(role: StringName) -> void:
	select_rejected.emit(role)


@rpc("authority", "call_local", "reliable")
func _rpc_apply_select(peer_id: int, role: StringName, picks: Dictionary, roster: Dictionary) -> void:
	selections = picks.duplicate(true)
	players = roster.duplicate(true)
	selection_changed.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_start_game() -> void:
	game_started.emit()


# ---------- 取消选择 ----------

func request_cancel() -> void:
	if not is_online():
		return
	if is_host():
		_handle_cancel(1)
	else:
		rpc_id(1, "_rpc_request_cancel")


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_cancel() -> void:
	if not is_host():
		return
	_handle_cancel(multiplayer.get_remote_sender_id())


func _handle_cancel(peer_id: int) -> void:
	for role in selections.keys():
		if int(selections[role]) == peer_id:
			selections.erase(role)
	if players.has(peer_id):
		players[peer_id]["role"] = &""
	rpc("_rpc_apply_cancel", selections, players)


@rpc("authority", "call_local", "reliable")
func _rpc_apply_cancel(picks: Dictionary, roster: Dictionary) -> void:
	selections = picks.duplicate(true)
	players = roster.duplicate(true)
	selection_changed.emit()


# ---------- 主机开始 / 重开 ----------

# 主机确认双方都已选择后开始
func request_start() -> void:
	if not is_host():
		return
	if selections.size() < 2:
		return
	rpc("_rpc_start_game")


# 重新开始：任意一方发起 → 主机清空选角 → 所有端回到角色选择
func request_rematch() -> void:
	if not is_online():
		return
	if is_host():
		_do_rematch()
	else:
		rpc_id(1, "_rpc_request_rematch")


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_rematch() -> void:
	if not is_host():
		return
	_do_rematch()


func _do_rematch() -> void:
	selections.clear()
	for id in players.keys():
		players[id]["role"] = &""
	rpc("_rpc_rematch", players)


@rpc("authority", "call_local", "reliable")
func _rpc_rematch(roster: Dictionary) -> void:
	players = roster.duplicate(true)
	selections.clear()
	rematch_requested.emit()


# ---------- 伤害与胜负（主机权威） ----------

func report_hit() -> void:
	if not is_online():
		return
	if is_host():
		_apply_hit(1)
	else:
		rpc_id(1, "_rpc_report_hit")


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_hit() -> void:
	if not is_host():
		return
	if multiplayer.get_remote_sender_id() != get_role_owner(ROLE_HUNTER):
		return
	_apply_hit(1)


func _apply_hit(amount: int) -> void:
	# 逃生者刚用护盾挡下这次攻击：直接忽略，既不扣血也不进入受击冷却
	if _shield_block_grace > 0.0:
		return
	if _hit_cooldown > 0.0:
		return
	if GameManager.state != GameManager.GameState.PLAYING:
		return
	_hit_cooldown = 2.0
	var hp := maxi(GameManager.survivor_hp - amount, 0)
	rpc("_rpc_apply_hp", hp)


@rpc("authority", "call_local", "reliable")
func _rpc_apply_hp(hp: int) -> void:
	hp_received.emit(hp)


# ---------- 护盾拦截同步（主机权威） ----------

# 逃生者端：护盾消耗时上报，由主机统一判定免伤并让追捕者真正被击退。
# 远端追捕者由 NetworkSync 插值驱动，本地直接调用 apply_knockback 不会生效。
func report_shield_block(direction: Vector3, distance: float, speed: float, max_duration: float) -> void:
	if not is_online():
		return
	if is_host():
		_apply_shield_block(direction, distance, speed, max_duration)
	else:
		rpc_id(1, "_rpc_report_shield_block", direction, distance, speed, max_duration)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_shield_block(direction: Vector3, distance: float, speed: float, max_duration: float) -> void:
	if not is_host():
		return
	if multiplayer.get_remote_sender_id() != get_role_owner(ROLE_SURVIVOR):
		return
	_apply_shield_block(direction, distance, speed, max_duration)


func _apply_shield_block(direction: Vector3, distance: float, speed: float, max_duration: float) -> void:
	# 挡下紧随其后的命中上报（网络延迟下护盾接触可能略早于伤害判定）
	_shield_block_grace = 0.35
	rpc("_rpc_shield_knockback", direction, distance, speed, max_duration)


@rpc("authority", "call_local", "reliable")
func _rpc_shield_knockback(direction: Vector3, distance: float, speed: float, max_duration: float) -> void:
	# 只有本机操控的追捕者需要本地物理击退，远端追捕者靠 NetworkSync 位置同步
	var hunter := get_tree().get_first_node_in_group("hunter") as CharacterBase
	if hunter == null or hunter.remote_driven or not hunter.has_method("apply_knockback"):
		return
	hunter.call("apply_knockback", direction, distance, speed, max_duration)


# ---------- 投掷物同步 ----------

# 本地投掷物状态变化时广播给对手（仅在联机模式生效）
func send_item_event(net_id: String, kind: int, data: Dictionary) -> void:
	if not is_online() or net_id.is_empty():
		return
	rpc("_rpc_item_event", net_id, kind, data)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_item_event(net_id: String, kind: int, data: Dictionary) -> void:
	item_event.emit(net_id, kind, data)


func broadcast_result(result: int) -> void:
	if not is_host():
		return
	rpc("_rpc_result", result)


@rpc("authority", "call_local", "reliable")
func _rpc_result(result: int) -> void:
	game_result = result
	result_received.emit(result)
