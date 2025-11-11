extends Node

# ===== CONFIGURAÇÕES =====

@export_category("Round Duration")
@export var max_round_duration: float = 600.0
@export var results_display_time: float = 5.0

@export_category("Auto-End Settings")
@export var disconnect_check_interval: float = 2.0
@export var auto_end_on_disconnect: bool = true

@export_category("Debug")
@export var debug_mode: bool = false

# ===== VARIÁVEIS DE ESTADO =====

var current_round: Dictionary = {}
var round_state: String = "none"
var next_round_id: int = 1
var map_manager: Node = null
var spawned_players: Dictionary = {}

# Timers (só criados no servidor, após inicialização)
var disconnect_check_timer: Timer = null
var round_duration_timer: Timer = null

# Estado de inicialização
var _is_server: bool = false
var _initialized: bool = false

# ===== SINAIS =====

signal round_created(round_data: Dictionary)
signal round_started(round_id: int)
signal round_ending(round_id: int, reason: String)
signal round_ended(round_data: Dictionary)
signal all_players_disconnected(round_id: int)
signal round_timeout(round_id: int)

# ===== INICIALIZAÇÃO CONTROLADA =====

func initialize_as_server():
	if _initialized:
		return
	
	_is_server = true
	_initialized = true
	
	_setup_timers()
	_log_debug("RoundRegistry inicializado como SERVIDOR")

func initialize_as_client():
	if _initialized:
		return
	
	_is_server = false
	_initialized = true
	
	# Clientes não precisam de timers
	_log_debug("RoundRegistry inicializado como CLIENTE")

func reset():
	# Para e remove timers
	if disconnect_check_timer:
		disconnect_check_timer.stop()
		disconnect_check_timer.disconnect("timeout", _check_all_disconnected)
		remove_child(disconnect_check_timer)
		disconnect_check_timer = null

	if round_duration_timer:
		round_duration_timer.stop()
		round_duration_timer.disconnect("timeout", _on_round_timeout)
		remove_child(round_duration_timer)
		round_duration_timer = null

	# Limpa estado
	current_round = {}
	round_state = "none"
	spawned_players.clear()
	map_manager = null
	_initialized = false
	_is_server = false
	_log_debug("RoundRegistry resetado")

# ===== CONFIGURAÇÃO DE TIMERS (APENAS SERVIDOR) =====

func _setup_timers():
	if not _is_server:
		return

	# Timer de desconexão
	if auto_end_on_disconnect:
		disconnect_check_timer = Timer.new()
		disconnect_check_timer.wait_time = disconnect_check_interval
		disconnect_check_timer.autostart = false
		disconnect_check_timer.one_shot = false
		add_child(disconnect_check_timer)
		disconnect_check_timer.timeout.connect(_check_all_disconnected)

	# Timer de duração da rodada
	if max_round_duration > 0:
		round_duration_timer = Timer.new()
		round_duration_timer.wait_time = max_round_duration
		round_duration_timer.autostart = false
		round_duration_timer.one_shot = true
		add_child(round_duration_timer)
		round_duration_timer.timeout.connect(_on_round_timeout)

# ===== GERENCIAMENTO DE RODADAS =====

func create_round(room_id: int, room_name: String, players: Array, settings: Dictionary) -> Dictionary:
	if not _is_server:
		push_warning("RoundRegistry: create_round() só pode ser chamado no servidor!")
		return {}

	if not current_round.is_empty():
		push_warning("Já existe uma rodada ativa!")
		return {}

	var round_id = next_round_id
	next_round_id += 1

	current_round = {
		"round_id": round_id,
		"room_id": room_id,
		"room_name": room_name,
		"players": players.duplicate(),
		"settings": settings.duplicate(),
		"start_time": Time.get_unix_time_from_system(),
		"end_time": 0,
		"duration": 0.0,
		"winner": {},
		"scores": {},
		"events": [],
		"disconnected_players": [],
		"end_reason": ""
	}

	for player in players:
		current_round["scores"][player["id"]] = 0

	round_state = "loading"
	_log_debug("✓ Rodada criada: ID %d, Sala '%s', %d players" % [round_id, room_name, players.size()])
	round_created.emit(current_round.duplicate())
	
	# Configs de mapa e env da rodada
	var array_rel = [
	{"nome": "Etapa 1", "tipo_relevo": "Semi-Flat", "percentual_distancia": 30},
	{"nome": "Etapa 2", "tipo_relevo": "Gentle Hills", "percentual_distancia": 30},
	{"nome": "Etapa 3", "tipo_relevo": "Rolling Hills", "percentual_distancia": 20},
	{"nome": "Etapa 4", "tipo_relevo": "Valleys", "percentual_distancia": 20}]
	current_round["settings"]["map_seed"] = randi_range(100000, 999999)
	current_round["settings"]["map_preencher_etapas"] = array_rel
	current_round["settings"]["map_size"] = Vector2i(20, 20)
	current_round["settings"]["env_current_time"] = 12.0
	
	return current_round.duplicate()

func start_round():
	if not _is_server:
		return

	if current_round.is_empty():
		push_error("Não há rodada para iniciar!")
		return

	round_state = "playing"

	if round_duration_timer:
		round_duration_timer.start()
		_log_debug("Timer de duração iniciado: %.1f segundos" % max_round_duration)

	if disconnect_check_timer:
		disconnect_check_timer.start()
		_log_debug("Verificação de desconexão ativada")

	_log_debug("▶ Rodada %d INICIADA" % current_round["round_id"])
	round_started.emit(current_round["round_id"])

func end_round(reason: String = "completed", winner_data: Dictionary = {}) -> Dictionary:
	if current_round.is_empty():
		return {}

	if round_state == "ending" or round_state == "results":
		return current_round.duplicate()

	round_state = "ending"

	if _is_server:
		if disconnect_check_timer:
			disconnect_check_timer.stop()
		if round_duration_timer:
			round_duration_timer.stop()

	current_round["end_time"] = Time.get_unix_time_from_system()
	current_round["duration"] = current_round["end_time"] - current_round["start_time"]
	current_round["end_reason"] = reason

	_log_debug("⏹ Rodada %d FINALIZANDO | Razão: %s" % [current_round["round_id"], reason])
	_add_event("round_ended", {"reason": reason, "winner": winner_data})
	round_ending.emit(current_round["round_id"], reason)
	round_state = "results"
	return current_round.duplicate()

func complete_round_end() -> Dictionary:
	if current_round.is_empty():
		return {}

	var final_data = current_round.duplicate()
	_log_debug("✓ Rodada %d FINALIZADA" % final_data["round_id"])
	round_ended.emit(final_data)
	_cleanup_round()
	return final_data

func _cleanup_round():
	map_manager = null
	spawned_players.clear()
	current_round = {}
	round_state = "none"

# ===== GERENCIAMENTO DE PLAYERS =====

func register_spawned_player(peer_id: int, player_node: Node):
	spawned_players[peer_id] = player_node
	_log_debug("Player %d registrado na rodada" % peer_id)

func unregister_spawned_player(peer_id: int):
	if spawned_players.has(peer_id):
		spawned_players.erase(peer_id)
		_log_debug("Player %d removido da rodada" % peer_id)

func mark_player_disconnected(peer_id: int):
	if current_round.is_empty():
		return
	if peer_id not in current_round["disconnected_players"]:
		current_round["disconnected_players"].append(peer_id)
		_add_event("player_disconnected", {"peer_id": peer_id})

func get_spawned_player(peer_id: int) -> Node:
	return spawned_players.get(peer_id, null)

func get_all_spawned_players() -> Array:
	return spawned_players.values()

func get_active_players() -> Array:
	var active = []
	for player_data in current_round.get("players", []):
		if player_data["id"] not in current_round.get("disconnected_players", []):
			active.append(player_data)
	return active

# ===== EVENTOS =====

func _add_event(event_type: String, event_data: Dictionary = {}):
	if current_round.is_empty():
		return
	var event = {
		"type": event_type,
		"timestamp": Time.get_unix_time_from_system(),
		"data": event_data
	}
	current_round["events"].append(event)

func get_events() -> Array:
	return [] if current_round.is_empty() else current_round["events"].duplicate()

# ===== VERIFICAÇÕES (APENAS SERVIDOR) =====

func _check_all_disconnected():
	if not _is_server or current_round.is_empty() or round_state != "playing":
		return

	if get_active_players().is_empty():
		_log_debug("⚠ Todos os players desconectaram!")
		all_players_disconnected.emit(current_round["round_id"])
		end_round("all_disconnected")

func _on_round_timeout():
	if not _is_server:
		return
	_log_debug("⏱ Tempo máximo da rodada atingido!")
	round_timeout.emit(current_round["round_id"])
	end_round("timeout")

# ===== QUERIES DE ESTADO =====

func is_round_active() -> bool:
	return not current_round.is_empty()

func get_round_state() -> String:
	return round_state

func get_current_round() -> Dictionary:
	return current_round.duplicate()

func get_round_id() -> int:
	return current_round.get("round_id", 0)

func get_round_duration() -> float:
	if current_round.is_empty():
		return 0.0
	if round_state == "playing":
		return Time.get_unix_time_from_system() - current_round["start_time"]
	return current_round.get("duration", 0.0)

func get_time_remaining() -> float:
	if not _is_server or not round_duration_timer:
		return -1.0
	return round_duration_timer.time_left

func get_settings() -> Dictionary:
	return current_round.get("settings", {})

func get_total_players() -> int:
	return current_round.get("players", []).size()

func get_active_player_count() -> int:
	return get_active_players().size()

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if not debug_mode:
		return

	var prefix = "[SERVER]" if _is_server else "[CLIENT]"
	print("[RoundRegistry] %s %s" % [prefix, message])
