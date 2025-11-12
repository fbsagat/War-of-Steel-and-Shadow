extends Node

# ===== CONFIGURAÇÕES =====

@export_category("Round Duration")
@export var max_round_duration: float = 600.0
@export var results_display_time: float = 5.0

@export_category("Auto-End Settings")
@export var disconnect_check_interval: float = 2.0
@export var auto_end_on_disconnect: bool = true

@export_category("Debug")
@export var debug_mode: bool = true

# ===== VARIÁVEIS DE ESTADO =====

# Dicionário de todas as rodadas: {round_id: RoundData}
var rounds: Dictionary = {}

# Timers globais (só no servidor)
var global_timers: Dictionary = {}

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
	
	_setup_global_timers()
	_log_debug("RoundRegistry inicializado como SERVIDOR")

func initialize_as_client():
	if _initialized:
		return
	
	_is_server = false
	_initialized = true
	
	_log_debug("RoundRegistry inicializado como CLIENTE (operações bloqueadas)")

func reset():
	# Remove timers globais
	for timer_name in global_timers:
		var timer = global_timers[timer_name]
		if timer and timer.is_inside_tree():
			timer.stop()
			timer.disconnect("timeout", _check_all_disconnected)
			remove_child(timer)
	
	global_timers.clear()
	rounds.clear()
	_initialized = false
	_is_server = false
	_log_debug("RoundRegistry resetado")

# ===== TIMERS GLOBAIS (APENAS SERVIDOR) =====

func _setup_global_timers():
	if not _is_server:
		return
	
	# Timer de verificação de desconexões (global para todas as rodadas)
	var check_timer = Timer.new()
	check_timer.wait_time = disconnect_check_interval
	check_timer.autostart = false
	check_timer.one_shot = false
	add_child(check_timer)
	check_timer.timeout.connect(_check_all_disconnected)
	global_timers["disconnect_check"] = check_timer

# ===== GERENCIAMENTO DE RODADAS =====

func create_round(room_id: int, room_name: String, players: Array, settings: Dictionary) -> Dictionary:
	if not _is_server:
		return {}

	var round_id = _get_next_round_id()
	
	# Cria nova rodada
	var round_data = {
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
		"end_reason": "",
		"state": "loading",
		"map_manager": null,
		"spawned_players": {},
		"round_timer": null
	}

	# Inicializa scores
	for player in players:
		round_data["scores"][player["id"]] = 0

	# Configs de mapa e env da rodada
	var array_rel = [
		{"nome": "Etapa 1", "tipo_relevo": "Semi-Flat", "percentual_distancia": 30},
		{"nome": "Etapa 2", "tipo_relevo": "Gentle Hills", "percentual_distancia": 30},
		{"nome": "Etapa 3", "tipo_relevo": "Rolling Hills", "percentual_distancia": 20},
		{"nome": "Etapa 4", "tipo_relevo": "Valleys", "percentual_distancia": 20}
	]
	round_data["settings"]["map_seed"] = randi_range(100000, 999999)
	round_data["settings"]["map_preencher_etapas"] = array_rel
	round_data["settings"]["map_size"] = Vector2i(20, 20)
	round_data["settings"]["env_current_time"] = 12.0

	# Armazena rodada
	rounds[round_id] = round_data

	_log_debug("✓ Rodada criada: ID %d, Sala '%s', %d players" % [round_id, room_name, players.size()])
	round_created.emit(round_data.duplicate())
	
	return round_data.duplicate()

func start_round(round_id: int):
	if not _is_server:
		return

	if not rounds.has(round_id):
		push_error("Rodada %d não existe!" % round_id)
		return

	var round_data = rounds[round_id]
	round_data["state"] = "playing"

	# Cria timer de duração específica para esta rodada
	if max_round_duration > 0:
		var round_timer = Timer.new()
		round_timer.wait_time = max_round_duration
		round_timer.autostart = false
		round_timer.one_shot = true
		add_child(round_timer)
		round_timer.timeout.connect(_on_round_timeout.bind(round_id))
		round_data["round_timer"] = round_timer
		round_timer.start()

	_log_debug("Timer de duração iniciado: %.1f segundos" % max_round_duration)

	# Ativa verificação de desconexão global
	if global_timers.has("disconnect_check"):
		global_timers["disconnect_check"].start()

	# Marca jogadores como em jogo
	for player in round_data["players"]:
		var player_data = PlayerRegistry.get_player(player.get("id"))
		if player_data:
			player_data.in_game = true

	_log_debug("▶ Rodada %d INICIADA" % round_id)
	round_started.emit(round_id)

# RoundRegistry.gd
func set_local_player_round(round_data: Dictionary):
	if not _initialized:
		return
	
	var local_player_id = multiplayer.get_unique_id()
	# Armazena a rodada do jogador local
	rounds[round_data["round_id"]] = round_data
	_log_debug("Rodada %d definida para jogador local %d" % [round_data["round_id"], local_player_id])

func end_round(round_id: int, reason: String = "completed", winner_data: Dictionary = {}) -> Dictionary:
	if not rounds.has(round_id):
		return {}

	var round_data = rounds[round_id]
	if round_data["state"] == "ending" or round_data["state"] == "results":
		return round_data.duplicate()

	round_data["state"] = "ending"

	# Para timer da rodada
	if round_data["round_timer"]:
		round_data["round_timer"].stop()
		remove_child(round_data["round_timer"])
		round_data["round_timer"] = null

	round_data["end_time"] = Time.get_unix_time_from_system()
	round_data["duration"] = round_data["end_time"] - round_data["start_time"]
	round_data["end_reason"] = reason

	_log_debug("⏹ Rodada %d FINALIZANDO | Razão: %s" % [round_id, reason])
	_add_event(round_id, "round_ended", {"reason": reason, "winner": winner_data})
	round_ending.emit(round_id, reason)
	round_data["state"] = "results"

	# Marca jogadores como fora do jogo
	for player in round_data["players"]:
		var player_data = PlayerRegistry.get_player(player.get("id"))
		if player_data:
			player_data.in_game = false

	return round_data.duplicate()

func complete_round_end(round_id: int) -> Dictionary:
	if not rounds.has(round_id):
		return {}

	var round_data = rounds[round_id].duplicate()
	_log_debug("✓ Rodada %d FINALIZADA" % round_data["round_id"])
	round_ended.emit(round_data)
	
	# Limpa rodada
	_cleanup_round(round_id)
	return round_data

func _cleanup_round(round_id: int):
	if not rounds.has(round_id):
		return
	
	var round_data = rounds[round_id]
	
	# Limpa referências
	round_data["map_manager"] = null
	round_data["spawned_players"].clear()
	
	# Remove timer se existir
	if round_data["round_timer"]:
		round_data["round_timer"].queue_free()
	
	# Remove da lista
	rounds.erase(round_id)

# ===== GERENCIAMENTO DE PLAYERS POR RODADA =====

func register_spawned_player(round_id: int, peer_id: int, player_node: Node):
	if not rounds.has(round_id):
		return
	
	print("rounds: ", rounds)
	rounds[round_id]["spawned_players"][peer_id] = player_node
	_log_debug("Player %d registrado na rodada %d" % [peer_id, round_id])

func unregister_spawned_player(round_id: int, peer_id: int):
	if not rounds.has(round_id):
		return
	
	if rounds[round_id]["spawned_players"].has(peer_id):
		rounds[round_id]["spawned_players"].erase(peer_id)
		_log_debug("Player %d removido da rodada %d" % [peer_id, round_id])

func mark_player_disconnected(round_id: int, peer_id: int):
	if not rounds.has(round_id):
		return
	
	var round_data = rounds[round_id]
	if peer_id not in round_data["disconnected_players"]:
		round_data["disconnected_players"].append(peer_id)
		_add_event(round_id, "player_disconnected", {"peer_id": peer_id})

func get_spawned_player(round_id: int, peer_id: int) -> Node:
	if not rounds.has(round_id):
		return null
	return rounds[round_id]["spawned_players"].get(peer_id, null)

func get_all_spawned_players(round_id: int) -> Array:
	if not rounds.has(round_id):
		return []
	return rounds[round_id]["spawned_players"].values()

func get_active_players(round_id: int) -> Array:
	if not rounds.has(round_id):
		return []
	
	var round_data = rounds[round_id]
	var active = []
	for player_data in round_data["players"]:
		if player_data["id"] not in round_data["disconnected_players"]:
			active.append(player_data)
	return active

# ===== EVENTOS POR RODADA =====

func _add_event(round_id: int, event_type: String, event_data: Dictionary = {}):
	if not rounds.has(round_id):
		return
	
	var round_data = rounds[round_id]
	var event = {
		"type": event_type,
		"timestamp": Time.get_unix_time_from_system(),
		"data": event_data
	}
	round_data["events"].append(event)

func get_events(round_id: int) -> Array:
	if not rounds.has(round_id):
		return []
	return rounds[round_id]["events"].duplicate()

# ===== VERIFICAÇÕES (APENAS SERVIDOR) =====

func _check_all_disconnected():
	if not _is_server:
		return

	# Verifica todas as rodadas ativas
	for round_id in rounds:
		var round_data = rounds[round_id]
		if round_data["state"] == "playing":
			if get_active_players(round_id).is_empty():
				_log_debug("⚠ Todos os players desconectaram da rodada %d!" % round_id)
				all_players_disconnected.emit(round_id)
				end_round(round_id, "all_disconnected")

func _on_round_timeout(round_id: int):
	if not _is_server:
		return
	
	if not rounds.has(round_id):
		return
	
	_log_debug("⏱ Tempo máximo da rodada %d atingido!" % round_id)
	round_timeout.emit(round_id)
	end_round(round_id, "timeout")

func get_round_by_player_id(player_id: int) -> Dictionary:
	"""
	Retorna os dados da rodada em que o jogador está participando.
	Se o jogador não estiver em nenhuma rodada, retorna um dicionário vazio.
	
	@param player_id: ID do jogador (peer_id)
	@return: Dicionário com dados da rodada ou {} se não encontrado
	"""
	if not _is_server:
		return {}
	
	for round_id in rounds:
		var round_data = rounds[round_id]
		# Verifica se o jogador está na lista de players da rodada
		for player in round_data["players"]:
			if player.has("id") and player["id"] == player_id:
				return round_data.duplicate()
	
	return {}

# ===== QUERIES DE ESTADO =====

func is_initialized() -> bool:
	return _initialized

func is_round_active(round_id: int) -> bool:
	return rounds.has(round_id)

func get_round_state(round_id: int) -> String:
	if not rounds.has(round_id):
		return "none"
	return rounds[round_id]["state"]

func get_round(round_id: int) -> Dictionary:
	if not rounds.has(round_id):
		return {}
	return rounds[round_id].duplicate()

func get_round_duration(round_id: int) -> float:
	if not rounds.has(round_id):
		return 0.0
	
	var round_data = rounds[round_id]
	if round_data["state"] == "playing":
		return Time.get_unix_time_from_system() - round_data["start_time"]
	return round_data.get("duration", 0.0)

func get_time_remaining(round_id: int) -> float:
	if not _is_server or not rounds.has(round_id):
		return -1.0
	
	var round_timer = rounds[round_id]["round_timer"]
	if not round_timer:
		return -1.0
	return round_timer.time_left

func get_settings(round_id: int) -> Dictionary:
	if not rounds.has(round_id):
		return {}
	return rounds[round_id]["settings"].duplicate()

func get_total_players(round_id: int) -> int:
	if not rounds.has(round_id):
		return 0
	return rounds[round_id]["players"].size()

func get_active_player_count(round_id: int) -> int:
	return get_active_players(round_id).size()
	
func get_all_rounds() -> Dictionary:
	return rounds.duplicate()

# ===== UTILITÁRIOS =====

func _get_next_round_id() -> int:
	var max_id = 0
	for round_id in rounds:
		if round_id > max_id:
			max_id = round_id
	return max_id + 1

func _log_debug(message: String):
	if not debug_mode:
		return

	var prefix = "[SERVER]" if _is_server else "[CLIENT]"
	print("[RoundRegistry] %s %s" % [prefix, message])
