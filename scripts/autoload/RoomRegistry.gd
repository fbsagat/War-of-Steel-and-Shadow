extends Node
## RoomRegistry - Gerenciador de salas de lobby (SERVIDOR APENAS)
## Armazena informações de salas e histórico de rodadas

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

@export_category("Room Settings")
## Número máximo de jogadores por sala
@export var max_players_per_room: int = 8
## Número mínimo de jogadores para iniciar rodada
@export var min_players_to_start: int = 2
## Permitir salas com senha
@export var allow_password_protected_rooms: bool = true

# ===== VARIÁVEIS INTERNAS =====

## Dicionário de salas {room_id: room_data}
var rooms: Dictionary = {}

# ===== SINAIS =====

signal room_created(room_data: Dictionary)
signal room_removed(room_id: int)
signal player_joined_room(room_id: int, peer_id: int)
signal player_left_room(room_id: int, peer_id: int)
signal round_added_to_history(room_id: int, round_data: Dictionary)

# ===== INICIALIZAÇÃO =====

func _ready():
	_log_debug("RoomRegistry inicializado")

# ===== GERENCIAMENTO DE SALAS =====

## Cria uma nova sala
func create_room(room_id: int, room_name: String, password: String, host_peer_id: int) -> Dictionary:
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
		"max_players": max_players_per_room,
		"in_game": false,  # Se está em rodada
		"created_at": Time.get_unix_time_from_system(),
		"rounds_history": [],  # Histórico de rodadas
		"total_rounds_played": 0,
		"settings": {}  # Configurações customizadas da sala
	}
	
	rooms[room_id] = room_data
	
	# Adiciona o host automaticamente
	add_player_to_room(room_id, host_peer_id)
	
	_log_debug("✓ Sala criada: '%s' (ID: %d, Host: %d)" % [room_name, room_id, host_peer_id])
	room_created.emit(room_data.duplicate())
	
	return room_data.duplicate()

## Remove uma sala
func remove_room(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	
	var room_name = rooms[room_id]["name"]
	rooms.erase(room_id)
	
	_log_debug("✗ Sala removida: '%s' (ID: %d)" % [room_name, room_id])
	room_removed.emit(room_id)
	
	return true

## Retorna uma sala pelo ID
func get_room(room_id: int) -> Dictionary:
	return rooms.get(room_id, {}).duplicate()

## Retorna uma sala pelo nome
func get_room_by_name(room_name: String) -> Dictionary:
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return rooms[room_id].duplicate()
	return {}

## Verifica se um nome de sala já existe
func room_name_exists(room_name: String) -> bool:
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return true
	return false

## Retorna lista de todas as salas (para lobby)
func get_rooms_list() -> Array:
	var rooms_list = []
	for room_id in rooms:
		var room = rooms[room_id].duplicate()
		# Remove senha da lista pública por segurança
		room.erase("password")
		rooms_list.append(room)
	return rooms_list

# ===== GERENCIAMENTO DE PLAYERS =====

## Adiciona um player à sala
func add_player_to_room(room_id: int, peer_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	
	# Verifica se já está na sala
	for player in room["players"]:
		if player["id"] == peer_id:
			_log_debug("Player %d já está na sala %d" % [peer_id, room_id])
			return true
	
	# Verifica limite de players
	if room["players"].size() >= room["max_players"]:
		_log_debug("Sala %d está cheia!" % room_id)
		return false
	
	# Busca dados do player no PlayerRegistry
	var player_data = PlayerRegistry.get_player(peer_id)
	if player_data.is_empty():
		push_error("Player %d não está registrado!" % peer_id)
		return false
	
	# Adiciona à sala
	var is_host = room["players"].is_empty() or peer_id == room["host_id"]
	room["players"].append({
		"id": peer_id,
		"name": player_data["name"],
		"is_host": is_host
	})
	
	_log_debug("✓ Player '%s' (%d) entrou na sala '%s'" % [
		player_data["name"], peer_id, room["name"]
	])
	
	player_joined_room.emit(room_id, peer_id)
	
	return true

## Remove um player da sala
func remove_player_from_room(room_id: int, peer_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	var player_index = -1
	
	# Encontra o player
	for i in range(room["players"].size()):
		if room["players"][i]["id"] == peer_id:
			player_index = i
			break
	
	if player_index == -1:
		return false
	
	var player_name = room["players"][player_index]["name"]
	var was_host = room["players"][player_index]["is_host"]
	
	# Remove o player
	room["players"].remove_at(player_index)
	
	_log_debug("✗ Player '%s' (%d) saiu da sala '%s'" % [
		player_name, peer_id, room["name"]
	])
	
	player_left_room.emit(room_id, peer_id)
	
	# Se era o host e ainda há players, promove o próximo
	if was_host and not room["players"].is_empty():
		room["players"][0]["is_host"] = true
		room["host_id"] = room["players"][0]["id"]
		_log_debug("Novo host da sala '%s': %d" % [room["name"], room["host_id"]])
	
	# Se a sala ficou vazia, remove
	if room["players"].is_empty():
		remove_room(room_id)
	
	return true

## Retorna a sala em que um player está
func get_room_by_player(peer_id: int) -> Dictionary:
	for room_id in rooms:
		for player in rooms[room_id]["players"]:
			if player["id"] == peer_id:
				return rooms[room_id].duplicate()
	return {}

# ===== ESTADO DA SALA =====

## Define se a sala está em jogo (rodada ativa)
func set_room_in_game(room_id: int, in_game: bool):
	if not rooms.has(room_id):
		return
	
	rooms[room_id]["in_game"] = in_game
	_log_debug("Sala %d in_game = %s" % [room_id, in_game])

## Verifica se a sala está em jogo
func is_room_in_game(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["in_game"]

# ===== HISTÓRICO DE RODADAS =====

## Adiciona uma rodada finalizada ao histórico da sala
func add_round_to_history(room_id: int, round_data: Dictionary) -> bool:
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	
	# Cria cópia limpa dos dados da rodada (sem referências)
	var clean_round = round_data.duplicate(true)
	
	# Adiciona ao histórico
	room["rounds_history"].append(clean_round)
	room["total_rounds_played"] += 1
	
	_log_debug("✓ Rodada %d adicionada ao histórico da sala '%s' (Total: %d rodadas)" % [
		clean_round["round_id"],
		room["name"],
		room["total_rounds_played"]
	])
	
	round_added_to_history.emit(room_id, clean_round)
	
	return true

## Retorna histórico de rodadas da sala
func get_rounds_history(room_id: int) -> Array:
	if not rooms.has(room_id):
		return []
	return rooms[room_id]["rounds_history"].duplicate()

## Retorna a última rodada jogada na sala
func get_last_round(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	
	var history = rooms[room_id]["rounds_history"]
	if history.is_empty():
		return {}
	
	return history[history.size() - 1].duplicate()

## Retorna estatísticas da sala
func get_room_statistics(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	var stats = {
		"total_rounds": room["total_rounds_played"],
		"total_playtime": 0.0,
		"average_round_duration": 0.0,
		"players_participated": []
	}
	
	# Calcula estatísticas do histórico
	var total_duration = 0.0
	var players_set = {}
	
	for round_data in room["rounds_history"]:
		total_duration += round_data.get("duration", 0.0)
		for player in round_data.get("players", []):
			players_set[player["id"]] = player["name"]
	
	stats["total_playtime"] = total_duration
	
	if room["total_rounds_played"] > 0:
		stats["average_round_duration"] = total_duration / room["total_rounds_played"]
	
	# Lista única de players que já jogaram na sala
	for peer_id in players_set:
		stats["players_participated"].append({
			"id": peer_id,
			"name": players_set[peer_id]
		})
	
	return stats

# ===== VALIDAÇÕES =====

## Verifica se pode iniciar uma rodada
func can_start_match(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	
	# Não pode estar em jogo
	if room["in_game"]:
		return false
	
	# Precisa ter players suficientes
	if room["players"].size() < min_players_to_start:
		return false
	
	return true

## Retorna requisitos para iniciar rodada
func get_match_requirements(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
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

## Define configurações customizadas da sala
func set_room_settings(room_id: int, settings: Dictionary):
	if not rooms.has(room_id):
		return
	
	rooms[room_id]["settings"] = settings.duplicate()
	_log_debug("Configurações da sala %d atualizadas" % room_id)

## Retorna configurações da sala
func get_room_settings(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	return rooms[room_id]["settings"].duplicate()

# ===== UTILITÁRIOS =====

## Retorna número total de salas
func get_room_count() -> int:
	return rooms.size()

## Retorna número total de players em todas as salas
func get_total_players_count() -> int:
	var total = 0
	for room_id in rooms:
		total += rooms[room_id]["players"].size()
	return total

func _log_debug(message: String):
	if debug_mode:
		print("[RoomRegistry] %s" % message)
