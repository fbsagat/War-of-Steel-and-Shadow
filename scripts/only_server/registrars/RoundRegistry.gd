extends Node
class_name RoundRegistry
## RoundRegistry - Gerenciador de rodadas/partidas (SERVIDOR APENAS)
## Rodadas são partidas ativas jogadas dentro de salas
##
## RESPONSABILIDADES:
## - Criar/iniciar rodadas
## - Gerenciar estado da rodada (loading, playing, ending, results)
## - Controlar timer de duração máxima
## - Detectar desconexões e finalizar automaticamente se necessário
## - Rastrear jogadores spawnados na cena
## - Registrar eventos da rodada
## - Finalizar rodada e enviar dados para RoomRegistry
##
## IDENTIFICAÇÃO:
## - Jogadores são identificados por uuid_base (String) em todos os métodos
## - player["id"], spawned_players, disconnected_players e scores usam uuid_base
## - Para RPCs use client_registry.get_peer_id_by_uuid(uuid_base)

# ===== CONFIGURAÇÕES =====

@export_group("Auto-End Settings")
@export var disconnect_check_interval: float = 2.0
@export var auto_end_on_all_disconnected: bool = true

@export_group("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var client_registry = null
var room_registry = null
var object_manager = null
var initializer = null

# ===== VARIÁVEIS INTERNAS =====

## Dicionário de todas as rodadas ativas: {round_id: RoundData}
var rounds: Dictionary = {}

var disconnect_check_timer: Timer = null
var _initialized: bool = false

# ===== SINAIS =====

signal round_created(round_data: Dictionary)
signal round_started(round_id: int)
signal round_ending(round_id: int, reason: String)
signal round_ended(round_data: Dictionary)
signal all_players_disconnected(round_id: int)
signal player_spawned_in_round(round_id: int, uuid_base: String, player_node: Node)
signal player_despawned_from_round(round_id: int, uuid_base: String)

# ===== ESTRUTURAS DE DADOS =====

## RoundData:
## {
##   "round_id": int,
##   "room_id": int,
##   "room_name": String,
##   "players": Array[PlayerInRound],  # [{id: uuid_base, name}]
##   "settings": Dictionary,
##   "start_time": float,
##   "end_time": float,
##   "duration": float,
##   "winner": Dictionary,             # {uuid_base, name, score}
##   "scores": Dictionary,             # {uuid_base: score}
##   "events": Array[Event],
##   "disconnected_players": Array[String],  # uuid_bases desconectados
##   "end_reason": String,
##   "state": String,                  # "loading", "playing", "ending", "results"
##   "map_manager": Node,
##   "round_node": Node,
##   "spawned_players": Dictionary,    # {uuid_base: Node}
##   "round_timer": Timer
## }

# ===== INICIALIZAÇÃO =====

func initialize():
	"""Inicializa o RoundRegistry (chamado apenas no servidor)"""
	if _initialized:
		_log_debug("⚠ RoundRegistry já inicializado")
		return
	
	# Conecta sinais
	client_registry.peer_id_updated.connect(_on_peer_id_updated)
	
	_setup_global_timers()
	_initialized = true
	_log_debug("▶️ RoundRegistry inicializado")

func reset():
	"""Reseta completamente o registro (usado ao desligar servidor)"""
	if disconnect_check_timer:
		disconnect_check_timer.stop()
		if disconnect_check_timer.is_inside_tree():
			remove_child(disconnect_check_timer)
		disconnect_check_timer.queue_free()
		disconnect_check_timer = null

	for round_id in rounds.keys():
		_cleanup_round(round_id)

	rounds.clear()
	_initialized = false
	_log_debug("🔄 RoundRegistry resetado")

func _setup_global_timers():
	disconnect_check_timer = Timer.new()
	disconnect_check_timer.wait_time = disconnect_check_interval
	disconnect_check_timer.autostart = false
	disconnect_check_timer.one_shot = false
	disconnect_check_timer.timeout.connect(_check_all_disconnected)
	add_child(disconnect_check_timer)

# ===== GERENCIAMENTO DE RODADAS =====

func create_round(room_id: int, room_name: String, players: Array, settings: Dictionary) -> Dictionary:
	"""Cria nova rodada (não inicia ainda).
	players deve ser Array de {id: uuid_base, name: String}.
	Retorna RoundData completo ou {} se falhar."""
	var round_id = _get_next_round_id()

	if not room_registry or not room_registry.room_exists(room_id):
		push_error("RoundRegistry: Sala %d não existe" % room_id)
		return {}

	if players.is_empty():
		push_error("RoundRegistry: Tentou criar rodada sem jogadores")
		return {}

	var round_data = {
		"round_id": round_id,
		"room_id": room_id,
		"room_name": room_name,
		"players": players.duplicate(true),
		"settings": settings.duplicate(true),
		"start_time": Time.get_unix_time_from_system(),
		"end_time": 0,
		"duration": 0.0,
		"winner": {},
		"scores": {},
		"events": [],
		"disconnected_players": [],
		"end_reason": "",
		"state": "loading",
		"round_node": null,
		"map_manager": null,
		"spawned_players": {},
		"round_timer": null
	}

	# Inicializa scores zerados (chave = uuid_base)
	for player in players:
		round_data["scores"][player["id"]] = 0

	# Gerar configurações do Sky3D
	round_data["settings"]["sky_rand_configs"] = sky3d_config_generator()

	rounds[round_id] = round_data

	# Registra jogadores na rodada (ClientRegistry)
	if client_registry:
		for player in players:
			client_registry.join_round(player["id"], round_id)

	_log_debug("✓ Rodada criada: ID %d, Sala '%s', %d players" % [round_id, room_name, players.size()])
	_add_event(round_id, "round_created", {"room_id": room_id})
	round_created.emit(round_data.duplicate(true))

	return round_data.duplicate(true)

func set_round_node(round_id: int, node: Node):
	"""Define o nó da cena para uma rodada existente."""
	if not rounds.has(round_id):
		push_error("RoundRegistry: Rodada %d não existe" % round_id)
		return false
	rounds[round_id]["round_node"] = node
	_log_debug("Nó da rodada %d definido: %s" % [round_id, node.name])
	return true

func start_round(round_id: int):
	"""Inicia rodada (muda estado para 'playing').
	Chamado DEPOIS de spawnar todos os jogadores na cena."""
	if not rounds.has(round_id):
		push_error("RoundRegistry: Rodada %d não existe" % round_id)
		return

	var round_data = rounds[round_id]

	if round_data["state"] != "loading":
		_log_debug("⚠ Rodada %d já foi iniciada (estado: %s)" % [round_id, round_data["state"]])
		return

	round_data["state"] = "playing"
	round_data["start_time"] = Time.get_unix_time_from_system()

	_log_debug("▶ Rodada %d INICIADA" % round_id)
	_add_event(round_id, "round_started", {})
	round_started.emit(round_id)

func end_round(round_id: int, reason: String = "completed", winner_data: Dictionary = {}) -> Dictionary:
	"""Finaliza rodada (muda estado para 'ending').
	winner_data deve conter {uuid_base, name, score}.
	reason: 'completed', 'timeout', 'all_disconnected'."""
	if not rounds.has(round_id):
		_log_debug("⚠ Tentou finalizar rodada inexistente: %d" % round_id)
		return {}

	var round_data = rounds[round_id]

	if round_data["state"] == "ending" or round_data["state"] == "results":
		_log_debug("⚠ Rodada %d já está finalizando/finalizada" % round_id)
		return round_data.duplicate(true)

	round_data["state"] = "ending"

	if round_data["round_timer"]:
		round_data["round_timer"].stop()
		round_data["round_timer"].queue_free()
		round_data["round_timer"] = null

	round_data["end_time"] = Time.get_unix_time_from_system()
	round_data["duration"] = round_data["end_time"] - round_data["start_time"]
	round_data["end_reason"] = reason
	round_data["winner"] = winner_data.duplicate(true)

	_log_debug("⏹ Rodada %d FINALIZANDO | Razão: %s | Duração: %.1fs" % [
		round_id, reason, round_data["duration"]
	])

	_add_event(round_id, "round_ended", {
		"reason": reason,
		"winner": winner_data,
		"duration": round_data["duration"]
	})

	round_ending.emit(round_id, reason)
	return round_data.duplicate(true)

func complete_round_end(round_id: int) -> Dictionary:
	"""Completa finalização da rodada (muda estado para 'results').
	Adiciona ao histórico da sala e limpa recursos.
	Chamado DEPOIS de mostrar resultados na UI."""
	if not rounds.has(round_id):
		return {}

	var round_data = rounds[round_id]

	if round_data["state"] != "ending":
		_log_debug("⚠ Rodada %d não está no estado 'ending'" % round_id)
		return round_data.duplicate(true)

	round_data["state"] = "results"

	if room_registry:
		room_registry.add_round_to_history(round_data["room_id"], round_data)

	if client_registry:
		for player in round_data["players"]:
			var uuid_base = player["id"]
			client_registry.leave_round(uuid_base)
			client_registry.clear_player_inventory(round_id, uuid_base)

	_log_debug("✓ Rodada %d FINALIZADA" % round_id)
	round_ended.emit(round_data.duplicate(true))

	var final_data = round_data.duplicate(true)
	_cleanup_round(round_id)

	return final_data

func _cleanup_round(round_id: int):
	"""Limpa todos os recursos da rodada."""
	if not rounds.has(round_id):
		return

	var round_data = rounds[round_id]

	if round_data["round_timer"] and is_instance_valid(round_data["round_timer"]):
		round_data["round_timer"].stop()
		if round_data["round_timer"].is_inside_tree():
			remove_child(round_data["round_timer"])
		round_data["round_timer"].queue_free()

	round_data["map_manager"] = null
	round_data["spawned_players"].clear()
	round_data["round_timer"] = null

	rounds.erase(round_id)

	if rounds.is_empty() and disconnect_check_timer:
		disconnect_check_timer.stop()

func cleanup_inactive_rounds():
	var current_time = Time.get_ticks_msec() / 1000.0
	var inactive_threshold = 30.0

	for round_id in rounds.keys():
		var last_activity = rounds[round_id].last_activity
		if current_time - last_activity > inactive_threshold:
			_log_debug("Round %d inativo por >%.1fs. Limpando..." % [round_id, inactive_threshold])
			end_round(round_id)

# ===== GERENCIAMENTO DE PLAYERS SPAWNADOS =====

func register_spawned_player(round_id: int, uuid_base: String, player_node: Node):
	"""Registra player que foi spawnado na cena da rodada."""
	if not rounds.has(round_id):
		push_error("RoundRegistry: Tentou registrar player em rodada inexistente: %d" % round_id)
		return

	rounds[round_id]["spawned_players"][uuid_base] = player_node

	_log_debug("✓ uuid=%s spawnado na rodada %d" % [uuid_base, round_id])
	player_spawned_in_round.emit(round_id, uuid_base, player_node)

func unregister_spawned_player(round_id: int, uuid_base: String):
	"""Remove registro de player spawnado."""
	if not rounds.has(round_id):
		return

	if rounds[round_id]["spawned_players"].has(uuid_base):
		rounds[round_id]["spawned_players"].erase(uuid_base)
		_log_debug("✓ uuid=%s despawnado da rodada %d" % [uuid_base, round_id])
		player_despawned_from_round.emit(round_id, uuid_base)

func _mark_player_disconnected(round_id: int, uuid_base: String):
	"""Marca player como desconectado durante a rodada (não remove da rodada)."""
	if not rounds.has(round_id):
		return

	var round_data = rounds[round_id]

	if uuid_base in round_data["disconnected_players"]:
		return

	round_data["disconnected_players"].append(uuid_base)
	_add_event(round_id, "player_disconnected", {"uuid_base": uuid_base})
	_log_debug("⚠ uuid=%s marcado como desconectado na rodada %d" % [uuid_base, round_id])

func get_spawned_player(round_id: int, uuid_base: String) -> Node:
	"""Retorna node do player spawnado (ou null se não encontrado)."""
	if not rounds.has(round_id):
		return null
	return rounds[round_id]["spawned_players"].get(uuid_base, null)

func get_all_spawned_players(round_id: int) -> Array:
	"""Retorna array com todos os nodes de players spawnados."""
	if not rounds.has(round_id):
		return []
	return rounds[round_id]["spawned_players"].values()

func get_active_players(round_id: int) -> Array:
	"""Retorna lista de PlayerData dos jogadores ATIVOS (não desconectados)."""
	if not rounds.has(round_id):
		return []

	var round_data = rounds[round_id]
	var active = []

	for player_data in round_data["players"]:
		if player_data["id"] not in round_data["disconnected_players"]:
			active.append(player_data)

	return active

func get_active_players_ids(round_id: int) -> Array:
	"""Retorna lista de uuid_bases dos jogadores ATIVOS (não desconectados)."""
	if not rounds.has(round_id):
		return []

	var round_data = rounds[round_id]
	var active = []

	for player_data in round_data["players"]:
		if player_data["id"] not in round_data["disconnected_players"]:
			active.append(player_data["id"])

	return active

func get_active_player_count(round_id: int) -> int:
	return get_active_players(round_id).size()

# ===== EVENTOS DA RODADA =====

func add_event(round_id: int, event_type: String, event_data: Dictionary = {}):
	_add_event(round_id, event_type, event_data)

func _add_event(round_id: int, event_type: String, event_data: Dictionary = {}):
	if not rounds.has(round_id):
		return

	rounds[round_id]["events"].append({
		"type": event_type,
		"timestamp": Time.get_unix_time_from_system(),
		"data": event_data.duplicate(true)
	})

func get_events(round_id: int) -> Array:
	if not rounds.has(round_id):
		return []
	return rounds[round_id]["events"].duplicate(true)

func get_events_of_type(round_id: int, event_type: String) -> Array:
	var filtered = []
	for event in get_events(round_id):
		if event["type"] == event_type:
			filtered.append(event)
	return filtered

# ===== PONTUAÇÃO (keyed by uuid_base) =====

func set_player_score(round_id: int, uuid_base: String, score: int):
	"""Define pontuação de um jogador."""
	if not rounds.has(round_id):
		return
	rounds[round_id]["scores"][uuid_base] = score
	_add_event(round_id, "score_updated", {"uuid_base": uuid_base, "score": score})

func add_player_score(round_id: int, uuid_base: String, points: int):
	"""Adiciona pontos à pontuação atual do jogador."""
	if not rounds.has(round_id):
		return
	var current = rounds[round_id]["scores"].get(uuid_base, 0)
	rounds[round_id]["scores"][uuid_base] = current + points
	_add_event(round_id, "score_added", {"uuid_base": uuid_base, "points": points})

func get_player_score(round_id: int, uuid_base: String) -> int:
	if not rounds.has(round_id):
		return 0
	return rounds[round_id]["scores"].get(uuid_base, 0)

func get_all_scores(round_id: int) -> Dictionary:
	"""Retorna dicionário {uuid_base: score}."""
	if not rounds.has(round_id):
		return {}
	return rounds[round_id]["scores"].duplicate()

func get_leaderboard(round_id: int) -> Array:
	"""Retorna array ordenado por pontuação (maior primeiro).
	Formato: [{uuid_base, name, score}, ...]"""
	if not rounds.has(round_id):
		return []

	var round_data = rounds[round_id]
	var leaderboard = []

	for player in round_data["players"]:
		leaderboard.append({
			"uuid_base": player["id"],
			"name": player["name"],
			"score": round_data["scores"].get(player["id"], 0)
		})

	leaderboard.sort_custom(func(a, b): return a["score"] > b["score"])
	return leaderboard

# ===== VERIFICAÇÕES AUTOMÁTICAS =====

func _check_all_disconnected():
	for round_id in rounds:
		var round_data = rounds[round_id]

		if round_data["state"] != "playing":
			continue

		if get_active_player_count(round_id) == 0:
			_log_debug("⚠ Todos os jogadores desconectaram da rodada %d!" % round_id)
			all_players_disconnected.emit(round_id)

			if auto_end_on_all_disconnected:
				end_round(round_id, "all_disconnected")

# ===== QUERIES DE ESTADO =====

func is_round_active(round_id: int) -> bool:
	return rounds.has(round_id)

func get_round_state(round_id: int) -> String:
	if not rounds.has(round_id):
		return "none"
	return rounds[round_id]["state"]

func get_round(round_id: int) -> Dictionary:
	if not rounds.has(round_id):
		return {}
	return rounds[round_id].duplicate(true)

func get_round_by_player_uuid(uuid_base: String) -> Dictionary:
	"""Retorna rodada em que o jogador está participando.
	Substitui get_round_by_player_id() — agora usa uuid_base."""
	for round_id in rounds:
		var round_data = rounds[round_id]
		for player in round_data["players"]:
			if player["id"] == uuid_base:
				return round_data.duplicate(true)
	return {}

func get_round_duration(round_id: int) -> float:
	if not rounds.has(round_id):
		return 0.0
	var round_data = rounds[round_id]
	if round_data["state"] == "playing":
		return Time.get_unix_time_from_system() - round_data["start_time"]
	else:
		return round_data.get("duration", 0.0)

func get_settings(round_id: int) -> Dictionary:
	if not rounds.has(round_id):
		return {}
	return rounds[round_id]["settings"].duplicate(true)

func get_total_players(round_id: int) -> int:
	if not rounds.has(round_id):
		return 0
	return rounds[round_id]["players"].size()

func get_all_rounds() -> Dictionary:
	return rounds.duplicate(true)

func get_active_rounds_count() -> int:
	return rounds.size()

# ===== UTILITÁRIOS =====

func _get_next_round_id() -> int:
	var max_id = 0
	for round_id in rounds:
		if round_id > max_id:
			max_id = round_id
	return max_id + 1

## Gera um dicionário com configurações randômicas para o Sky3D
func sky3d_config_generator() -> Dictionary:
	var config = {}

	var paletas_cores = _gerar_paletas_cores()
	var paleta = paletas_cores[randi() % paletas_cores.size()]

	config["time"] = {
		"current_time": randf_range(6.0, 14.0),
		"day_duration": randf_range(840.0, 1200.0),
		"auto_advance": true,
		"time_scale": 1.0
	}

	config["sky"] = {
		"sky_contribution": randf_range(0.5, 1.5),
		"quality": "high",
		"rayleigh_coefficient": randf_range(0.5, 3.0),
		"mie_coefficient": randf_range(0.005, 0.05),
		"turbidity": randf_range(1.0, 8.0),
		"sky_color": paleta["sky"],
		"horizon_color": paleta["horizon"]
	}

	config["fog"] = {
		"enabled": randi() % 2 == 0,
		"density": randf_range(0.001, 0.05),
		"color": paleta["fog"],
		"height": randf_range(-10.0, 50.0),
		"height_density": randf_range(0.0, 2.0)
	}

	config["clouds"] = {
		"coverage": randf_range(0.2, 0.9),
		"size": randf_range(0.5, 2.0),
		"speed": randf_range(0.01, 0.5),
		"wind_direction": randf_range(0.0, 360.0),
		"opacity": randf_range(0.6, 1.0),
		"brightness": randf_range(0.8, 1.5),
		"color": paleta["clouds"]
	}

	config["exposure"] = {
		"exposure": randf_range(0.8, 1.5),
		"white_point": randf_range(6.0, 12.0)
	}

	config["ambient"] = {
		"sky_color": paleta["ambient_sky"],
		"ground_color": paleta["ambient_ground"]
	}

	_log_debug("✓ Configurações randômicas geradas: %s" % paleta["nome"])
	return config

func _gerar_paletas_cores() -> Array:
	return [
		{
			"nome": "Azul Clássico",
			"sky": Color(0.4, 0.6, 0.9), "horizon": Color(0.6, 0.7, 0.9),
			"fog": Color(0.7, 0.8, 0.95), "clouds": Color(0.95, 0.95, 1.0),
			"ambient_sky": Color(0.5, 0.6, 0.8), "ambient_ground": Color(0.3, 0.3, 0.3)
		},
		{
			"nome": "Pôr do Sol Dourado",
			"sky": Color(0.9, 0.5, 0.3), "horizon": Color(1.0, 0.7, 0.4),
			"fog": Color(0.95, 0.75, 0.6), "clouds": Color(1.0, 0.8, 0.6),
			"ambient_sky": Color(0.8, 0.5, 0.3), "ambient_ground": Color(0.4, 0.3, 0.2)
		},
		{
			"nome": "Aurora Roxa",
			"sky": Color(0.6, 0.3, 0.8), "horizon": Color(0.8, 0.4, 0.9),
			"fog": Color(0.75, 0.6, 0.85), "clouds": Color(0.9, 0.7, 0.95),
			"ambient_sky": Color(0.5, 0.3, 0.6), "ambient_ground": Color(0.3, 0.2, 0.4)
		},
		{
			"nome": "Amanhecer Rosa",
			"sky": Color(0.95, 0.6, 0.7), "horizon": Color(1.0, 0.75, 0.8),
			"fog": Color(0.95, 0.8, 0.85), "clouds": Color(1.0, 0.85, 0.9),
			"ambient_sky": Color(0.8, 0.5, 0.6), "ambient_ground": Color(0.4, 0.3, 0.3)
		},
		{
			"nome": "Tempestade Cinza",
			"sky": Color(0.4, 0.4, 0.5), "horizon": Color(0.5, 0.5, 0.55),
			"fog": Color(0.6, 0.6, 0.65), "clouds": Color(0.7, 0.7, 0.75),
			"ambient_sky": Color(0.3, 0.3, 0.35), "ambient_ground": Color(0.2, 0.2, 0.2)
		},
		{
			"nome": "Deserto Âmbar",
			"sky": Color(0.85, 0.7, 0.5), "horizon": Color(0.95, 0.8, 0.6),
			"fog": Color(0.9, 0.8, 0.7), "clouds": Color(0.95, 0.9, 0.8),
			"ambient_sky": Color(0.7, 0.6, 0.4), "ambient_ground": Color(0.5, 0.4, 0.3)
		},
		{
			"nome": "Noite Estrelada",
			"sky": Color(0.1, 0.1, 0.3), "horizon": Color(0.2, 0.2, 0.4),
			"fog": Color(0.15, 0.15, 0.35), "clouds": Color(0.3, 0.3, 0.5),
			"ambient_sky": Color(0.1, 0.1, 0.2), "ambient_ground": Color(0.05, 0.05, 0.1)
		},
		{
			"nome": "Floresta Esmeralda",
			"sky": Color(0.5, 0.8, 0.6), "horizon": Color(0.6, 0.85, 0.7),
			"fog": Color(0.7, 0.9, 0.75), "clouds": Color(0.85, 0.95, 0.9),
			"ambient_sky": Color(0.4, 0.6, 0.5), "ambient_ground": Color(0.2, 0.4, 0.2)
		},
		{
			"nome": "Inverno Gelado",
			"sky": Color(0.7, 0.8, 0.95), "horizon": Color(0.8, 0.85, 0.98),
			"fog": Color(0.85, 0.9, 1.0), "clouds": Color(0.95, 0.97, 1.0),
			"ambient_sky": Color(0.6, 0.7, 0.8), "ambient_ground": Color(0.4, 0.45, 0.5)
		},
		{
			"nome": "Vulcão Laranja",
			"sky": Color(0.8, 0.4, 0.2), "horizon": Color(0.9, 0.5, 0.3),
			"fog": Color(0.85, 0.5, 0.4), "clouds": Color(0.9, 0.6, 0.5),
			"ambient_sky": Color(0.6, 0.3, 0.2), "ambient_ground": Color(0.3, 0.2, 0.1)
		}
	]

func _on_peer_id_updated(uuid_base: String, new_peer_id: int):
	for round_id in rounds:
		for player in rounds[round_id]["players"]:
			if player["id"] == uuid_base:
				player["session_id"] = new_peer_id
				_log_debug("✓ session_id atualizado para uuid=%s na rodada %d" % [uuid_base, round_id])
				return

func _log_debug(message: String):
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "RoundRegistry" in initializer.selected:
		return
	print("[SERVER][RoundRegistry] %s" % message)
