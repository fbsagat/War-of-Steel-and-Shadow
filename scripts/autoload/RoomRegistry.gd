extends Node
## RoomRegistry - Registro centralizado de salas
## Gerencia todas as salas de jogo disponíveis

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

## Número máximo de jogadores por sala
@export var max_players_per_room: int = 10

## Número mínimo de jogadores para iniciar partida
@export var min_players_to_start: int = 2

# ===== VARIÁVEIS INTERNAS =====

## Dicionário com todas as salas: {room_id: room_data}
var rooms: Dictionary = {}

# ===== GERENCIAMENTO DE SALAS =====

## Cria uma nova sala
func create_room(room_id: int, room_name: String, password: String, host_peer_id: int) -> Dictionary:
	var room_data = {
		"id": room_id,
		"name": room_name,
		"password": password,
		"has_password": not password.is_empty(),
		"host_id": host_peer_id,
		"players": [],
		"max_players": max_players_per_room,
		"created_at": Time.get_unix_time_from_system()
	}
	
	# Adiciona o host como primeiro jogador
	var host_player = PlayerRegistry.get_player(host_peer_id)
	if host_player:
		room_data["players"].append({
			"id": host_peer_id,
			"name": host_player["name"],
			"is_host": true
		})
	
	rooms[room_id] = room_data
	_log_debug("Sala criada: %s (ID: %d, Host: %d)" % [room_name, room_id, host_peer_id])
	
	return room_data.duplicate(true)

## Remove uma sala
func remove_room(room_id: int):
	if rooms.has(room_id):
		var room = rooms[room_id]
		_log_debug("Sala removida: %s (ID: %d)" % [room["name"], room_id])
		rooms.erase(room_id)

## Retorna dados de uma sala
func get_room(room_id: int) -> Dictionary:
	if rooms.has(room_id):
		return rooms[room_id].duplicate(true)
	return {}

## Retorna sala por nome
func get_room_by_name(room_name: String) -> Dictionary:
	for room in rooms.values():
		if room["name"] == room_name:
			return room.duplicate(true)
	return {}

## Verifica se existe sala com determinado nome
func room_name_exists(room_name: String) -> bool:
	for room in rooms.values():
		if room["name"] == room_name:
			return true
	return false

## Retorna sala onde o jogador está
func get_room_by_player(peer_id: int) -> Dictionary:
	for room in rooms.values():
		for player in room["players"]:
			if player["id"] == peer_id:
				return room.duplicate(true)
	return {}

## Adiciona um jogador à sala
func add_player_to_room(room_id: int, peer_id: int) -> bool:
	if not rooms.has(room_id):
		_log_debug("Sala não encontrada: %d" % room_id)
		return false
	
	var room = rooms[room_id]
	
	# Verifica se a sala está cheia
	if room["players"].size() >= room["max_players"]:
		_log_debug("Sala cheia: %s" % room["name"])
		return false
	
	# Verifica se o jogador já está na sala
	for player in room["players"]:
		if player["id"] == peer_id:
			_log_debug("Jogador já está na sala")
			return false
	
	# Adiciona o jogador
	var player_data = PlayerRegistry.get_player(peer_id)
	if not player_data:
		_log_debug("Jogador não encontrado: %d" % peer_id)
		return false
	
	room["players"].append({
		"id": peer_id,
		"name": player_data["name"],
		"is_host": false
	})
	
	_log_debug("Jogador %s adicionado à sala %s (%d/%d)" % [
		player_data["name"],
		room["name"],
		room["players"].size(),
		room["max_players"]
	])
	
	return true

## Remove um jogador da sala
func remove_player_from_room(room_id: int, peer_id: int):
	if not rooms.has(room_id):
		return
	
	var room = rooms[room_id]
	var was_host = false
	
	# Remove o jogador
	for i in range(room["players"].size()):
		if room["players"][i]["id"] == peer_id:
			if room["players"][i]["is_host"]:
				was_host = true
			room["players"].remove_at(i)
			break
	
	_log_debug("Jogador %d removido da sala %s" % [peer_id, room["name"]])
	
	# Se a sala ficou vazia, remove a sala
	if room["players"].is_empty():
		_log_debug("Sala vazia, removendo: %s" % room["name"])
		remove_room(room_id)
		return
	
	# Se o host saiu, transfere para o próximo jogador
	if was_host and not room["players"].is_empty():
		room["players"][0]["is_host"] = true
		room["host_id"] = room["players"][0]["id"]
		_log_debug("Novo host da sala %s: %s" % [room["name"], room["players"][0]["name"]])

## Retorna lista de salas (formato para enviar aos clientes)
func get_rooms_list() -> Array:
	var rooms_list = []
	
	for room in rooms.values():
		rooms_list.append({
			"id": room["id"],
			"name": room["name"],
			"has_password": room["has_password"],
			"players": room["players"].size(),
			"max_players": room["max_players"]
		})
	
	return rooms_list

## Retorna número de salas ativas
func get_room_count() -> int:
	return rooms.size()

## Limpa todas as salas
func clear_all():
	_log_debug("Limpando todas as salas")
	rooms.clear()

## Verifica se a sala pode iniciar partida
func can_start_match(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	var player_count = room["players"].size()
	
	return player_count >= min_players_to_start and player_count <= max_players_per_room

## Retorna informações sobre requisitos de partida
func get_match_requirements(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	var player_count = room["players"].size()
	
	return {
		"current_players": player_count,
		"min_players": min_players_to_start,
		"max_players": max_players_per_room,
		"can_start": can_start_match(room_id)
	}

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[RoomRegistry] " + message)
