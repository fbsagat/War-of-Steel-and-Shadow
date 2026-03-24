extends CanvasLayer

@onready var label: Label = $Panel/Label

const PING_HISTORY_SIZE := 10
const PING_TIMEOUT_MS := 3000
const LAG_THRESHOLD_MS := 150

var ping: int = 0
var ping_avg: int = 0
var last_pong_time: int = 0
var _is_connected: bool = false
var peer_id = 0
var client_uuid: String = ""

var ping_history: Array[int] = []

func _ready() -> void:
	visible = false

func _zip_uuid() -> String:
	var uuid_minor: String = ""
	if client_uuid != "": 
		var dif1 = client_uuid.substr(0, 4)
		var dif2 = client_uuid.substr(client_uuid.length() - 4, 4)
		uuid_minor = "%s[...]%s" % [dif1, dif2]
	return uuid_minor

func _process(_delta: float) -> void:
	if not visible:
		return
	
	if not is_connected:
		label.text = "Status: ⚪ DESCONECTADO\nPing: -- ms\nPing médio: -- ms\nSem resposta: -- s\n UUID: %s\n Peer id: %d" % [_zip_uuid(), peer_id]
		return

	var now := Time.get_ticks_msec()
	var time_since_last := now - last_pong_time

	var status := "🟢 OK"
	if time_since_last > PING_TIMEOUT_MS:
		status = "🔴 TIMEOUT"
	elif ping > LAG_THRESHOLD_MS:
		status = "🟡 LAG"

	label.text = "Status: %s\nPing: %d ms\nPing médio: %d ms\nSem resposta: %.2f s\n UUID: %s\n Peer id: %d" % [
		status,
		ping,
		ping_avg,
		time_since_last / 1000.0,
		_zip_uuid(),
		peer_id,
	]

func update_ping(value: int) -> void:
	ping = value
	_is_connected = true

	ping_history.append(value)
	if ping_history.size() > PING_HISTORY_SIZE:
		ping_history.pop_front()

	var _sum := 0
	for p in ping_history:
		_sum += p

	#ping_avg = sum / ping_history.size()

func update_pong_time(time: int) -> void:
	last_pong_time = time
	_is_connected = true

func on_disconnected() -> void:
	_is_connected = false
	ping = 0
	ping_avg = 0
	last_pong_time = 0
	ping_history.clear()
