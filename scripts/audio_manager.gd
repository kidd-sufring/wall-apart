extends Node

# 全局音效管理（Autoload：AudioManager）
# 玩法脚本只描述"发生了什么"，这里负责选音源、是否 3D 定位、随机化与播放器回收。
# 3D 音效走 AudioStreamPlayer3D：自带距离衰减（近大远小）与基于听众的方位声像。

const AUDIO_DIR := "res://assets/audio/"

# 逻辑名 -> 文件名，脚本里只引用逻辑名，换素材时改这里即可
const SOUNDS := {
	&"click": "click1.ogg",
	&"click_heavy": "heavy_closeclick.ogg",
	&"hover": "mousehover1.ogg",
	&"page": "nextpage_rollover3.ogg",
	&"light_impact": "impactGeneric_light_002.ogg",
	&"bell": "impactBell_heavy_001.ogg",
	&"whistle": "whistle_start.wav",
	&"hit": "hit.ogg",
	&"jump": "jump.ogg",
	&"land": "jump_down.ogg",
	&"run": "run.ogg",
	&"shield": "shields_open.ogg",
	&"hunter_skill": "hunterskill.wav",
	&"stone_fly": "stonefly.wav",
	&"stone_hit": "stonehit.wav",
	&"pumpkin": "pumpkin.wav",
	&"win": "winning.wav",
	&"defeat": "defeated.wav",
	&"loading": "loading.wav",
}

@export var master_volume_db := 0.0     # 全局音量偏移
@export var max_2d_players := 8          # 2D 播放器池上限
@export var max_3d_players := 24         # 3D 播放器池上限

# 玩家设置（0.0 ~ 1.0 线性值，界面上用百分比滑条调节）
var music_volume := 1.0
var sfx_volume := 1.0

var _streams: Dictionary = {}
var _players_2d: Array[AudioStreamPlayer] = []
var _players_3d: Array[AudioStreamPlayer3D] = []
var _bgm_player: AudioStreamPlayer = null
var _bgm_key: StringName = &""
var _bgm_base_db := -6.0                # 当前 BGM 在 100% 音量时的目标音量
var _bgm_tween: Tween = null


func _ready() -> void:
	# 结算时会暂停场景树，音效与 BGM 仍需正常播完
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 长音频（加载界面 BGM）按需加载，其余短音效预先载入，避免首次播放卡顿
	for key in SOUNDS:
		if key == &"loading":
			continue
		_get_stream(key)


func has_sound(key: StringName) -> bool:
	return _get_stream(key) != null


# ---------- 音量设置 ----------

func set_music_volume(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)
	# 设置面板拖动时立刻生效，若正在淡入则打断补间，直接给到目标音量
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()
	_apply_bgm_volume()


func set_sfx_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)


func get_music_volume_percent() -> int:
	return int(round(music_volume * 100.0))


func get_sfx_volume_percent() -> int:
	return int(round(sfx_volume * 100.0))


# 线性音量转音量增益；0 时给 -80 dB（听不见但不报错）
func _gain_db(linear: float) -> float:
	return linear_to_db(maxf(linear, 0.0001))


func _apply_bgm_volume() -> void:
	if _bgm_player == null or not _bgm_player.playing:
		return
	_bgm_player.volume_db = _bgm_base_db + master_volume_db + _gain_db(music_volume)


# 让长音频循环播放：不同格式的循环开关位置不一样，这里逐个处理
func _set_stream_looping(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		var total_samples := int(round(wav.get_length() * float(wav.mix_rate)))
		if wav.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_begin = 0
		# loop_end 为 0 时部分格式/编码下会被当成空循环区，直接写满整段
		if wav.loop_end <= 0 and total_samples > 0:
			wav.loop_end = total_samples
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true


# BGM 播完（循环点未被支持时会走到这里）：自动从头再播一遍
func _on_bgm_finished() -> void:
	if _bgm_key == &"" or _bgm_player == null:
		return
	var stream := _bgm_player.stream
	if stream == null or stream.get_length() <= 0.0:
		return
	_bgm_player.volume_db = _bgm_base_db + master_volume_db + _gain_db(music_volume)
	_bgm_player.play()


func _get_stream(key: StringName) -> AudioStream:
	if _streams.has(key):
		return _streams[key]
	if not SOUNDS.has(key):
		push_warning("未登记的音效：%s" % key)
		return null
	var stream := load(AUDIO_DIR + SOUNDS[key]) as AudioStream
	if stream == null:
		push_warning("音效加载失败：%s" % (AUDIO_DIR + SOUNDS[key]))
		return null
	_streams[key] = stream
	return stream


# 界面 / 全局音效：不随摄像机距离变化
func play_2d(key: StringName, volume_db := 0.0, pitch := 1.0) -> void:
	var stream := _get_stream(key)
	if stream == null:
		return
	var player := _take_2d_player()
	player.stream = stream
	player.volume_db = volume_db + master_volume_db + _gain_db(sfx_volume)
	player.pitch_scale = maxf(pitch, 0.05)
	player.play()


# 世界音效：带方位与距离衰减
func play_3d(key: StringName, position: Vector3, volume_db := 0.0, pitch := 1.0,
		unit_size := 5.0, max_distance := 30.0) -> void:
	var stream := _get_stream(key)
	if stream == null:
		return
	var player := _take_3d_player()
	player.stream = stream
	player.global_position = position
	player.volume_db = volume_db + master_volume_db + _gain_db(sfx_volume)
	player.pitch_scale = maxf(pitch, 0.05)
	player.unit_size = maxf(unit_size, 0.1)
	player.max_distance = maxf(max_distance, 1.0)
	player.play()


# 带轻微随机化的世界音效：同一声源反复播放时不会听出"复读"
func play_3d_randomized(key: StringName, position: Vector3, volume_db := 0.0,
		pitch_center := 1.0, pitch_spread := 0.08, volume_spread_db := 1.5,
		unit_size := 5.0, max_distance := 30.0) -> void:
	play_3d(
		key,
		position,
		volume_db + randf_range(-volume_spread_db, volume_spread_db),
		pitch_center * randf_range(1.0 - pitch_spread, 1.0 + pitch_spread),
		unit_size,
		max_distance
	)


# ---------- 背景音乐 ----------

# 循环播放一段长音频（主菜单 / 加载界面）。重复调用同一首不会重新起播。
func play_bgm(key: StringName, volume_db := -6.0, fade_time := 0.4) -> void:
	if _bgm_key == key and _bgm_player != null and _bgm_player.playing:
		return
	var stream := _get_stream(key)
	if stream == null:
		return
	if _bgm_player == null:
		_bgm_player = AudioStreamPlayer.new()
		_bgm_player.bus = &"Master"
		# 有些压缩导入格式不支持循环点，播完手动续播，保证听感上是无缝循环
		_bgm_player.finished.connect(_on_bgm_finished)
		add_child(_bgm_player)

	_bgm_key = key
	_bgm_player.stream = stream
	# 导入时未必勾了循环，这里统一按循环播放（否则 BGM 放一遍就停）
	_set_stream_looping(stream)
	_bgm_base_db = volume_db
	var target_db := volume_db + master_volume_db + _gain_db(music_volume)
	if fade_time <= 0.0:
		_bgm_player.volume_db = target_db
		_bgm_player.play()
		return

	_bgm_player.volume_db = target_db - 40.0
	_bgm_player.play()
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(_bgm_player, "volume_db", target_db, fade_time)


func stop_bgm(fade_time := 0.4) -> void:
	if _bgm_player == null or not _bgm_player.playing:
		return
	_bgm_key = &""
	if fade_time <= 0.0:
		_bgm_player.stop()
		return
	var tween := create_tween()
	tween.tween_property(_bgm_player, "volume_db", _bgm_player.volume_db - 40.0, fade_time)
	tween.tween_callback(_bgm_player.stop)


func _take_2d_player() -> AudioStreamPlayer:
	for player in _players_2d:
		if not player.playing:
			return player
	if _players_2d.size() < max_2d_players:
		var player := AudioStreamPlayer.new()
		player.bus = &"Master"
		add_child(player)
		_players_2d.append(player)
		return player
	var oldest := _players_2d[0]
	oldest.stop()
	return oldest


func _take_3d_player() -> AudioStreamPlayer3D:
	for player in _players_3d:
		if not player.playing:
			return player
	if _players_3d.size() < max_3d_players:
		var player := AudioStreamPlayer3D.new()
		player.bus = &"Master"
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.max_polyphony = 1
		add_child(player)
		_players_3d.append(player)
		return player
	var oldest := _players_3d[0]
	oldest.stop()
	return oldest
