extends Control

# 局域网大厅：创建房间 / 加入房间。
# 独立场景，由主菜单进入；「返回上一步」先退出房间再回到创建/加入选择处。

@export var button_hover_scale := 1.06   # 悬停时的放大倍率
@export var button_hover_time := 0.12    # 放大/还原动画时长（秒）

@onready var back_button: Button = $BackButton
@onready var close_button: TextureButton = $Center/Card/Close
@onready var nick_input: LineEdit = $Center/Card/Content/VBox/NickRow/NickInput
@onready var ip_input: LineEdit = $Center/Card/Content/VBox/IpRow/IpInput
@onready var host_button: Button = $Center/Card/Content/VBox/Buttons/HostButton
@onready var join_button: Button = $Center/Card/Content/VBox/Buttons/JoinButton
@onready var status_label: Label = $Center/Card/Content/VBox/StatusLabel
@onready var ip_hint: Label = $Center/Card/Content/VBox/IpHint
@onready var copy_button: Button = $Center/Card/Content/VBox/CopyButton

var _button_tweens: Dictionary = {}
var _lobby_busy := false
var _host_ip := ""                       # 建房后本机可被连接的 IP，复制按钮使用


func _ready() -> void:
	GameManager.enter_menu_state()
	Platform.set_capture(false)

	NetworkManager.status_changed.connect(_on_net_status)
	NetworkManager.enter_select.connect(_on_net_enter_select)
	nick_input.text_changed.connect(_on_nick_changed)
	copy_button.visible = false
	copy_button.pressed.connect(_on_copy_pressed)

	for button in [back_button, close_button, host_button, join_button, copy_button] as Array[Control]:
		button.mouse_entered.connect(_on_button_hover.bind(true, button))
		button.mouse_exited.connect(_on_button_hover.bind(false, button))

	# 返回大厅时保留上次填写的昵称
	if not NetworkManager.local_nickname.is_empty():
		nick_input.text = NetworkManager.local_nickname

	_set_lobby_busy(false)
	UiSound.bind(self)
	status_label.text = "请输入昵称，然后创建房间或加入房间"


# ---------- 返回 ----------

# 返回上一步：已建房/连接中 → 离开房间，回到「创建房间 / 加入房间」选择处
func _on_back_pressed() -> void:
	if NetworkManager.is_online() or _lobby_busy:
		NetworkManager.leave_room()
		_set_lobby_busy(false)
		status_label.text = "请输入昵称，然后创建房间或加入房间"
		ip_hint.text = ""
		_host_ip = ""
		copy_button.visible = false
		return
	# 还没进房间：返回主菜单
	SceneTransition.change_scene("res://scenes/main_menu.tscn")


# 关闭窗口：离开房间并回到主菜单
func _on_close_pressed() -> void:
	NetworkManager.leave_room()
	SceneTransition.change_scene("res://scenes/main_menu.tscn")


# ---------- 大厅 ----------

func _on_nick_changed(_text: String) -> void:
	_update_lobby_buttons()


func _on_host_pressed() -> void:
	if not NetworkManager.host_game(nick_input.text):
		return
	_set_lobby_busy(true)
	_host_ip = NetworkManager.get_lan_ip()
	ip_hint.text = "本机 IP：%s（端口 %d），点击下方按钮可复制" % [_host_ip, NetworkManager.PORT]
	copy_button.visible = true


# 把主机 IP 写入系统剪贴板，方便直接粘贴给队友
func _on_copy_pressed() -> void:
	if _host_ip.is_empty():
		return
	DisplayServer.clipboard_set(_host_ip)
	# 部分平台会静默失败，写完后校验一次，避免给出错误的“已复制”反馈
	if DisplayServer.clipboard_get() == _host_ip:
		status_label.text = "已复制 IP：%s" % _host_ip
	else:
		status_label.text = "复制失败，请手动记录 IP：%s" % _host_ip


func _on_join_pressed() -> void:
	if not NetworkManager.join_game(ip_input.text, nick_input.text):
		_set_lobby_busy(false)
		return
	_set_lobby_busy(true)


func _set_lobby_busy(busy: bool) -> void:
	_lobby_busy = busy
	_update_lobby_buttons()


# 昵称为空或正在连接时禁用创建/加入
func _update_lobby_buttons() -> void:
	var valid := not nick_input.text.strip_edges().is_empty()
	host_button.disabled = _lobby_busy or not valid
	join_button.disabled = _lobby_busy or not valid


func _on_net_status(text: String) -> void:
	status_label.text = text
	# 连接失败/断开后允许重新操作
	if not NetworkManager.is_online():
		_set_lobby_busy(false)


func _on_net_enter_select() -> void:
	SceneTransition.change_scene("res://scenes/character_select.tscn")


# ---------- 通用 ----------

# 悬停放大/离开还原：以按钮中心为轴缩放，不影响容器布局
func _on_button_hover(entered: bool, button: Control) -> void:
	if not is_instance_valid(button):
		return
	if button is BaseButton and (button as BaseButton).disabled and entered:
		return

	button.pivot_offset = button.size * 0.5

	var tween: Tween = _button_tweens.get(button)
	if tween != null and tween.is_valid():
		tween.kill()

	tween = create_tween()
	_button_tweens[button] = tween
	var target := Vector2.ONE * (button_hover_scale if entered else 1.0)
	tween.tween_property(button, "scale", target, button_hover_time) \
		.set_trans(Tween.TRANS_QUAD) \
		.set_ease(Tween.EASE_OUT)
