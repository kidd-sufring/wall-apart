extends Node

# 全局比赛管理器（Autoload：GameManager）
# 单一数据源：当前角色、比赛状态、准备/比赛倒计时、逃生者血量、胜负结果。
# HUD 与胜负判定都只读这里的数据，不各跑一套计时器。

enum GameState { MENU, CHARACTER_SELECT, COUNTDOWN, PLAYING, RESULT }
enum MatchResult { HUNTER_WIN, SURVIVOR_WIN }
# 单人模式 AI 难度：只影响 AI 的战术规避（躲避投掷物）机制
enum Difficulty { EASY, NORMAL, HARD }

const SURVIVOR_MAX_HP := 2                  # 逃生者生命值上限
const ROLE_HUNTER := &"hunter_sid"          # 追捕者希德
const ROLE_SURVIVOR := &"survivor_sonny"    # 逃生者桑尼

@export var countdown_seconds := 3.0        # 开局准备倒计时（秒）
@export var match_duration := 40.0          # 单局比赛时长（秒）

var current_role: StringName = &""          # 玩家所选角色
var tutorial_mode := false                  # 新手教程流程：角色选择确认后进入对应角色的教程场景
var difficulty: int = Difficulty.NORMAL     # 单人模式 AI 难度（联机不生效）
var state: int = GameState.MENU
var time_left := 0.0                        # 当前阶段剩余时间（准备或比赛）
var match_time_left := 0.0                  # 结算时保留的比赛剩余时间
var survivor_hp := SURVIVOR_MAX_HP
var survivor_max_hp := SURVIVOR_MAX_HP
var match_result: int = -1
# 联机客户端标记：本地只显示主机下发的时钟，不能自行推进阶段，避免开局不同步
var online_clock_client := false

# 倒计时已播放到的整秒数，用于 3 / 2 / 1 各响一次提示音
var _countdown_tick := -1
# 倒计时是否已真正开始：场景切换期间先保持 false，等游戏场景就绪再启动
var _countdown_started := false

signal state_changed(new_state: int)
signal match_finished(result: int)
signal survivor_hp_changed(current: int, maximum: int)


func _process(delta: float) -> void:
	# 联机时只有主机拥有计时权，客户端等待主机下发阶段切换，避免倒计时还没结束就能移动
	var authority := not NetworkManager.is_online() or NetworkManager.is_host()
	match state:
		GameState.COUNTDOWN:
			# 场景切换的淡出期间状态已是 COUNTDOWN，但倒计时要在游戏场景就绪后才真正开始，
			# 否则提示音会和确认按钮的点击音叠在一起
			if not _countdown_started:
				return
			time_left = maxf(time_left - delta, 0.0)
			_play_countdown_tick()
			if time_left <= 0.0:
				if authority:
					# 倒计时结束：吹哨，正式开赛
					_countdown_started = false
					AudioManager.play_2d(&"whistle", -2.0)
					_set_state(GameState.PLAYING)
					time_left = match_duration
				else:
					# 客户端计时到 0 后保持冻结，等主机同步 PLAYING
					time_left = 0.0
		GameState.PLAYING:
			time_left = maxf(time_left - delta, 0.0)
			if time_left <= 0.0 and authority:
				# 时间耗尽且逃生者仍存活 → 逃生者胜利
				end_match(MatchResult.SURVIVOR_WIN)


func _set_state(new_state: int) -> void:
	# 离开倒计时阶段时顺带关掉计时开关，避免残留状态影响下一次开局
	if new_state != GameState.COUNTDOWN:
		_countdown_started = false
	state = new_state
	state_changed.emit(new_state)


# 倒计时每跨过一个整秒响一次提示音（3 / 2 / 1）
func _play_countdown_tick() -> void:
	var remaining := int(ceil(time_left))
	if remaining <= 0 or remaining == _countdown_tick:
		return
	_countdown_tick = remaining
	AudioManager.play_2d(&"bell", -3.0)


func is_player_hunter() -> bool:
	return current_role == ROLE_HUNTER


# 进入角色选择（由主菜单调用）
func goto_character_select() -> void:
	get_tree().paused = false
	tutorial_mode = false
	current_role = &""
	match_result = -1
	time_left = 0.0
	survivor_hp = SURVIVOR_MAX_HP
	_set_state(GameState.CHARACTER_SELECT)
	SceneTransition.change_scene("res://scenes/character_select.tscn")


# 进入单人的难度选择（主菜单「单人模式」调用）
func goto_difficulty_select() -> void:
	get_tree().paused = false
	tutorial_mode = false
	match_result = -1
	time_left = 0.0
	survivor_hp = SURVIVOR_MAX_HP
	_set_state(GameState.MENU)
	SceneTransition.change_scene("res://scenes/difficulty_select.tscn")


# AI 躲避机制的触发几率覆盖：返回负数表示沿用角色自身配置（普通难度）
func get_evasion_chance_override() -> float:
	# 联机对局双方都是真人，难度不参与
	if NetworkManager.is_online():
		return -1.0
	match difficulty:
		Difficulty.EASY:
			return 0.0
		Difficulty.HARD:
			return 1.0
	return -1.0


func get_difficulty_name(value: int) -> String:
	match value:
		Difficulty.EASY:
			return "简单"
		Difficulty.HARD:
			return "困难"
	return "普通"


func get_difficulty_description(value: int) -> String:
	match value:
		Difficulty.EASY:
			return "AI 不会躲避投掷物"
		Difficulty.HARD:
			return "AI 高概率躲避投掷物"
	return "AI 有一定几率躲避投掷物"


# 进入新手教程的角色选择（确认后进对应角色的教程场景而不是对局）
func goto_tutorial_select() -> void:
	get_tree().paused = false
	tutorial_mode = true
	current_role = &""
	match_result = -1
	time_left = 0.0
	survivor_hp = SURVIVOR_MAX_HP
	_set_state(GameState.CHARACTER_SELECT)
	SceneTransition.change_scene("res://scenes/character_select.tscn")


# 选定角色并加载游戏场景（由角色选择界面调用）
func start_single_match(role: StringName) -> void:
	get_tree().paused = false
	current_role = role
	match_result = -1
	time_left = countdown_seconds
	_countdown_tick = -1
	_countdown_started = false
	survivor_hp = SURVIVOR_MAX_HP
	_set_state(GameState.COUNTDOWN)
	SceneTransition.change_scene("res://scenes/main.tscn")


# 游戏场景就绪后调用：重置并开始 3 秒准备倒计时
func begin_countdown() -> void:
	time_left = countdown_seconds
	_countdown_tick = -1
	_countdown_started = true
	_set_state(GameState.COUNTDOWN)


# 联机客户端应用主机下发的阶段与剩余时间
func apply_online_clock(synced_state: int, synced_time_left: float) -> void:
	if not online_clock_client:
		return
	time_left = maxf(synced_time_left, 0.0)
	if synced_state != state:
		if synced_state == GameState.COUNTDOWN:
			_countdown_started = true
		_set_state(synced_state)


# 逃生者血量同步（生命值唯一数据源）
func sync_survivor_hp(current: int, maximum: int) -> void:
	survivor_max_hp = maximum
	survivor_hp = current
	survivor_hp_changed.emit(current, maximum)
	if state == GameState.PLAYING and current <= 0:
		end_match(MatchResult.HUNTER_WIN)


func end_match(result: int) -> void:
	if state != GameState.PLAYING:
		return
	match_result = result
	match_time_left = time_left
	time_left = 0.0
	_set_state(GameState.RESULT)
	match_finished.emit(result)
	# 冻结玩家、AI 与物理；结算弹窗使用 PROCESS_MODE_ALWAYS 仍可交互
	get_tree().paused = true


# 返回主菜单
func return_to_menu() -> void:
	get_tree().paused = false
	tutorial_mode = false
	current_role = &""
	match_result = -1
	time_left = 0.0
	survivor_hp = SURVIVOR_MAX_HP
	_set_state(GameState.MENU)
	SceneTransition.change_scene("res://scenes/main_menu.tscn")


# 主菜单 / 角色选择场景就绪时调用，确保状态正确且不处于暂停
func enter_menu_state() -> void:
	get_tree().paused = false
	tutorial_mode = false
	match_result = -1
	time_left = 0.0
	_set_state(GameState.MENU)


func enter_character_select_state() -> void:
	get_tree().paused = false
	match_result = -1
	time_left = 0.0
	_set_state(GameState.CHARACTER_SELECT)
