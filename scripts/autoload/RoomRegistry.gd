extends Node
## RoomRegistry - Gerenciador de salas de lobby (SERVIDOR APENAS)
## Armazena informações de salas e histórico de rodadas

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

@export_category("Room Settings")
@export var max_players_per_room: int = 8
@export var min_players_to_start: int = 1
@export var allow_password_protected_rooms: bool = true

# ===== VARIÁVEIS INTERNAS =====

var rooms: Dictionary = {}

# Estado de inicialização
var _is_server: bool = false
var _initialized: bool = false

# ===== SINAIS =====

signal room_created(room_data: Dictionary)
signal room_removed(room_id: int)
signal player_joined_room(room_id: int, peer_id: int)
signal player_left_room(room_id: int, peer_id: int)
signal round_added_to_history(room_id: int, round_data: Dictionary)

# ===== INICIALIZAÇÃO CONTROLADA =====

func initialize_as_server():
	if _initialized:
		return
	
	_is_server = true
	_initialized = true
	_log_debug("RoomRegistry inicializado")

func initialize_as_client():
	if _initialized:
		return
	
	# RoomRegistry NÃO DEVE ser usado no cliente!
	# Mas mantemos para evitar erros se chamado por engano.
	_is_server = false
	_initialized = true
	_log_debug("RoomRegistry acessado como CLIENTE (operações bloqueadas)")

func reset():
	rooms.clear()
	_initialized = false
	_is_server = false
	_log_debug("RoomRegistry resetado")

# ===== GERENCIAMENTO DE SALAS =====

func create_room(room_id: int, room_name: String, password: String, host_peer_id: int) -> Dictionary:
	if not _is_server:
		push_warning("RoomRegistry: create_room() só pode ser chamado no servidor!")
		return {}
	
	if rooms.has(room_id):
		push_error("Sala com ID %d já existe!" % room_id)
		return {}
	
	var room_data = {
		"id": room_id,
		"name": room_name,
		"password": password,
		"has_password": not password.is_empty(),
		"host_id": host_peer_id,
		"players": [],
		"min_players": min_players_to_start,
		"max_players": max_players_per_room,
		"in_game": false,
		"created_at": Time.get_unix_time_from_system(),
		"rounds_history": [],
		"total_rounds_played": 0,
		"settings": {}
	}
	
	rooms[room_id] = room_data
	add_player_to_room(room_id, host_peer_id)
	
	_log_debug(" Sala criada: '%s' (ID: %d, Host: %d)" % [room_name, room_id, host_peer_id])
	room_created.emit(room_data.duplicate())
	return room_data.duplicate()

func remove_room(room_id: int) -> bool:
	if not _is_server:
		return false
	
	if not rooms.has(room_id):
		return false
	
	var room_name = rooms[room_id]["name"]
	rooms.erase(room_id)
	_log_debug("Sala removida: '%s' (ID: %d)" % [room_name, room_id])
	room_removed.emit(room_id)
	return true

func get_room(room_id: int) -> Dictionary:
	return rooms.get(room_id, {}).duplicate()

func get_room_by_name(room_name: String) -> Dictionary:
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return rooms[room_id].duplicate()
	return {}

func room_name_exists(room_name: String) -> bool:
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return true
	return false

func get_rooms_list() -> Array:
	if not _is_server:
		return []  # Cliente não deve acessar lista interna
	
	var rooms_list = []
	for room_id in rooms:
		var room = rooms[room_id].duplicate()
		room.erase("password")  # Segurança
		rooms_list.append(room)
	return rooms_list

func get_in_game_rooms_list(out_game: bool = false) -> Array:
	if not _is_server:
		return []  # Cliente não deve acessar lista interna
	
	var rooms_list_in = []
	var rooms_list_out = []
	for room_id in rooms:
		var room = rooms[room_id].duplicate()
		room.erase("password")  # Segurança
		if room["in_game"] == true:
			rooms_list_in.append(room)
		else:
			rooms_list_out.append(room)
	return rooms_list_out if out_game else rooms_list_in
	
# ===== GERENCIAMENTO DE PLAYERS =====

func add_player_to_room(room_id: int, peer_id: int) -> bool:
	if not _is_server:
		return false
	
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	
	for player in room["players"]:
		if player["id"] == peer_id:
			_log_debug("Player %d já está na sala %d" % [peer_id, room_id])
			return true
	
	if room["players"].size() >= room["max_players"]:
		_log_debug("Sala %d está cheia!" % room_id)
		return false
	
	var player_data = PlayerRegistry.get_player(peer_id)
	if player_data.is_empty():
		push_error("Player %d não está registrado!" % peer_id)
		return false
	
	var is_host = room["players"].is_empty() or peer_id == room["host_id"]
	room["players"].append({
		"id": peer_id,
		"name": player_data["name"],
		"is_host": is_host
	})
	
	_log_debug(" Player '%s' (%d) entrou na sala '%s'" % [
		player_data["name"], peer_id, room["name"]
	])
	player_joined_room.emit(room_id, peer_id)
	return true

func remove_player_from_room(room_id: int, peer_id: int) -> bool:
	if not _is_server:
		return false
	
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	var player_index = -1
	
	for i in range(room["players"].size()):
		if room["players"][i]["id"] == peer_id:
			player_index = i
			break
	
	if player_index == -1:
		return false
	
	var player_name = room["players"][player_index]["name"]
	var was_host = room["players"][player_index]["is_host"]
	room["players"].remove_at(player_index)
	
	_log_debug("Player '%s' (%d) saiu da sala '%s'" % [
		player_name, peer_id, room["name"]
	])
	player_left_room.emit(room_id, peer_id)
	
	if was_host and not room["players"].is_empty():
		room["players"][0]["is_host"] = true
		room["host_id"] = room["players"][0]["id"]
		_log_debug("Novo host da sala '%s': %d" % [room["name"], room["host_id"]])
	
	if room["players"].is_empty():
		remove_room(room_id)
	
	return true

func get_room_by_player(peer_id: int) -> Dictionary:
	if not _is_server:
		return {}
	
	for room_id in rooms:
		for player in rooms[room_id]["players"]:
			if player["id"] == peer_id:
				return rooms[room_id].duplicate()
	return {}

# ===== ESTADO DA SALA =====

func set_room_in_game(room_id: int, in_game: bool):
	if not _is_server:
		return
	
	if rooms.has(room_id):
		rooms[room_id]["in_game"] = in_game
		_log_debug("Sala %d in_game = %s" % [room_id, in_game])

func is_room_in_game(room_id: int) -> bool:
	if not _is_server or not rooms.has(room_id):
		return false
	return rooms[room_id]["in_game"]

# ===== HISTÓRICO DE RODADAS =====

func add_round_to_history(room_id: int, round_data: Dictionary) -> bool:
	if not _is_server:
		return false
	
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	var clean_round = round_data.duplicate(true)
	room["rounds_history"].append(clean_round)
	room["total_rounds_played"] += 1
	
	_log_debug(" Rodada %d adicionada ao histórico da sala '%s' (Total: %d rodadas)" % [
		clean_round["round_id"],
		room["name"],
		room["total_rounds_played"]
	])
	round_added_to_history.emit(room_id, clean_round)
	return true

func get_rounds_history(room_id: int) -> Array:
	if not _is_server or not rooms.has(room_id):
		return []
	return rooms[room_id]["rounds_history"].duplicate()

func get_last_round(room_id: int) -> Dictionary:
	if not _is_server or not rooms.has(room_id):
		return {}
	
	var history = rooms[room_id]["rounds_history"]
	return {} if history.is_empty() else history[-1].duplicate()

func get_room_statistics(room_id: int) -> Dictionary:
	if not _is_server or not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	var stats = {
		"total_rounds": room["total_rounds_played"],
		"total_playtime": 0.0,
		"average_round_duration": 0.0,
		"players_participated": []
	}
	
	var total_duration = 0.0
	var players_set = {}
	
	for round_data in room["rounds_history"]:
		total_duration += round_data.get("duration", 0.0)
		for player in round_data.get("players", []):
			players_set[player["id"]] = player["name"]
	
	stats["total_playtime"] = total_duration
	
	if room["total_rounds_played"] > 0:
		stats["average_round_duration"] = total_duration / room["total_rounds_played"]
	
	for peer_id in players_set:
		stats["players_participated"].append({
			"id": peer_id,
			"name": players_set[peer_id]
		})
	
	return stats

# ===== VALIDAÇÕES =====

func can_start_match(room_id: int) -> bool:
	if not _is_server or not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	if room["in_game"]:
		return false
	if room["players"].size() < min_players_to_start:
		return false
	return true

func get_match_requirements(room_id: int) -> Dictionary:
	if not _is_server or not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	return {
		"current_players": room["players"].size(),
		"min_players": min_players_to_start,
		"max_players": room["max_players"],
		"can_start": can_start_match(room_id),
		"in_game": room["in_game"]
	}

# ===== CONFIGURAÇÕES DA SALA =====

func set_room_settings(room_id: int, settings: Dictionary):
	if not _is_server:
		return
	
	if rooms.has(room_id):
		rooms[room_id]["settings"] = settings.duplicate()
		_log_debug("Configurações da sala %d atualizadas" % room_id)

func get_room_settings(room_id: int) -> Dictionary:
	if not _is_server or not rooms.has(room_id):
		return {}
	return rooms[room_id]["settings"].duplicate()

# ===== UTILITÁRIOS =====

func get_room_count() -> int:
	return rooms.size() if _is_server else 0

func get_total_players_count() -> int:
	if not _is_server:
		return 0
	
	var total = 0
	for room_id in rooms:
		total += rooms[room_id]["players"].size()
	return total

func get_total_players_in_room_count(room_id_ : int) -> int:
	if not _is_server:
		return 0
	
	var total = 0
	for player in get_room(room_id_)["players"]:
		total += 1
	return total

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if _is_server else "[CLIENT]"
		print("%s[RoomRegistry] %s" % [prefix, message])
