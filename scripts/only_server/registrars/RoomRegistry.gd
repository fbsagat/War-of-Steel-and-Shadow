extends Node
class_name RoomRegistry
## RoomRegistry - Gerenciador de salas de lobby (SERVIDOR APENAS)
## Salas são locais onde jogadores aguardam antes de iniciar partidas (rodadas)
##
## RESPONSABILIDADES:
## - Criar/remover salas
## - Adicionar/remover jogadores de salas
## - Armazenar histórico de rodadas completadas por sala
## - Validar requisitos para iniciar partidas
## - Calcular estatísticas acumuladas da sala
##
## IDENTIFICAÇÃO:
## - Jogadores são identificados por uuid_base (String) em todos os métodos
## - host_uuid e player["uuid_base"] armazenam uuid_base

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var server_manager: ServerManager = null
var client_registry: ClientRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null
var debug_overlay: DebugOverlay = null
var initializer: Initializer = null

# ===== VARIÁVEIS INTERNAS =====

## Dados de todas as salas: {room_id: RoomData}
var rooms: Dictionary = {}

var _initialized: bool = false
var max_id: int  = 0

# ===== SINAIS =====

signal room_created(room_data: Dictionary)
signal room_removed(room_id: int)
signal player_joined_room(room_id: int, uuid_base: String)
signal player_left_room(room_id: int, uuid_base: String)
signal host_changed(room_id: int, new_host_uuid: String)
signal round_added_to_history(room_id: int, round_data: Dictionary)
signal room_state_changed(room_id: int, in_game: bool)

# ===== ESTRUTURAS DE DADOS =====

## RoomData:
## {
##   "id": int,
##   "name": String,
##   "password": String,
##   "has_password": bool,
##   "host_uuid": String,           # uuid_base do host
##   "players": Array[PlayerInRoom],  # [{id: uuid_base, name, is_host, is_offline}]
##   "kicked_players": Array,     # [{uuid_base, time}]
##   "min_players": int,
##   "max_players": int,
##   "in_game": bool,
##   "created_at": float,
##   "rounds_history": Array[RoundData],
##   "total_rounds_played": int,
##   "total_playtime": float,
##   "settings": Dictionary
## }


# ===== INICIALIZAÇÃO =====

## Inicializa o RoomRegistry (chamado apenas no servidor).
func initialize():
	if _initialized:
		_log_debug("⚠ RoomRegistry já inicializado")
		return
	
	# Conecta sinais
	client_registry.peer_id_updated.connect(_on_peer_id_updated)
	
	_initialized = true
	_log_debug("▶️ RoomRegistry inicializado")

## Reseta completamente o registro (usado ao desligar servidor).
func reset():
	rooms.clear()
	_initialized = false
	_log_debug("🔄 RoomRegistry resetado")


# ===== GERENCIAMENTO DE SALAS =====

func _get_next_room_id() -> int:
	max_id += 1
	return max_id

## Cria nova sala. Retorna RoomData completo ou {} se falhar.
func create_room(room_name: String, password: String, host_uuid: String, min_players: int, max_players: int) -> Dictionary:
	var room_id = _get_next_room_id()

	if rooms.has(room_id):
		push_error("RoomRegistry: Sala com ID %d já existe!" % room_id)
		return {}

	if not client_registry or not client_registry.is_player_registered(host_uuid):
		push_error("RoomRegistry: Host uuid=%s não é um jogador válido" % host_uuid)
		return {}

	var room_data = {
		"id": room_id,
		"name": room_name,
		"password": password,
		"has_password": not password.is_empty(),
		"host_uuid": host_uuid,
		"players": [],
		"kicked_players": [],
		"min_players": min_players,
		"max_players": max_players,
		"in_game": false,
		"created_at": Time.get_unix_time_from_system(),
		"rounds_history": [],
		"total_rounds_played": 0,
		"total_playtime": 0.0,
		"available_colors": _get_color_pool(),
		"last_hue": 0.0,
		"settings": {"locked": false}
	}

	rooms[room_id] = room_data

	# Adiciona host automaticamente
	add_player_to_room(room_id, host_uuid)

	_log_debug("✓ Sala criada: '%s' (ID: %d, Host: %s)" % [room_name, room_id, host_uuid])
	room_created.emit(room_data.duplicate())

	return room_data.duplicate()

## Remove sala completamente após remover todos os jogadores.
func remove_room(room_id: int) -> bool:
	if not rooms.has(room_id):
		_log_debug("⚠ Tentou remover sala inexistente: %d" % room_id)
		return false

	var room = rooms[room_id]
	var room_name = room["name"]

	var players_copy = room["players"].duplicate()
	for player_data in players_copy:
		remove_player_from_room(room_id, player_data["uuid_base"])

	rooms.erase(room_id)

	_log_debug("✓ Sala removida: '%s' (ID: %d)" % [room_name, room_id])
	room_removed.emit(room_id)

	return true

## Retorna cópia completa dos dados da sala.
func get_room(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	return rooms[room_id].duplicate(true)

## Retorna salas fora de jogo com dados normalizados para o menu.
func get_room_filtered(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
		
	var room = rooms[room_id].duplicate(true)

	var players_array = room.get("players", [])
	var players_count: int = players_array.size() if players_array is Array else 0
	var locked = room["settings"].get("locked", false)

	var min_raw = room.get("min_players", 0)
	var min_players: int = (
		min_raw if min_raw is int
		else int(min_raw) if min_raw is float
		else min_raw.to_int() if min_raw is String and min_raw.is_valid_integer()
		else 0
	)

	var max_raw = room.get("max_players", 0)
	var max_players: int = (
		max_raw if max_raw is int
		else int(max_raw) if max_raw is float
		else max_raw.to_int() if max_raw is String and max_raw.is_valid_integer()
		else 0
	)

	room.erase("settings")
	room.erase("password")
	room.erase("kicked_players")
	room.erase("rounds_history")
	room.erase("total_rounds_played")
	room.erase("total_playtime")
	room.erase("available_colors")
	room.erase("last_hue")
	
	room["players"] = players_array
	room["players_count"] = players_count
	room["min_players"] = min_players
	room["max_players"] = max_players
	room["locked"] = locked

	return room

func get_all_rooms() -> Array:
	return rooms.values().duplicate()

func get_all_rooms_ids() -> Array:
	var ids: Array = []
	for room in rooms.values():
		ids.append(room["id"])
	return ids

func get_all_room_players_uuids(room_id: int) -> Array:
	var p_ids: Array = []
	for room in rooms.values():
		if room.has("uuid_base"):
			for player in rooms[room_id]["players"]:
				p_ids.append(player["uuid_base"])
	return p_ids

## Posiçoes de entrada no servidor. Ordenamento.
func get_all_room_players_positions(room_id: int) -> Array:
	var p_entrys: Array = []
	for room in rooms.values():
		if room.has("uuid_base"):
			for player in rooms[room_id]["players"]:
				var entry = client_registry.get_player(player["uuid_base"])["entry_position"]
				p_entrys.append(entry)
	return p_entrys

func get_room_by_name(room_name: String) -> Dictionary:
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return rooms[room_id].duplicate(true)
	return {}

func room_exists(room_id: int) -> bool:
	return rooms.has(room_id)

func room_name_exists(room_name: String) -> bool:
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return true
	return false

func get_rooms_list(include_password: bool = false) -> Array:
	var rooms_list = []
	for room_id in rooms:
		var room = rooms[room_id].duplicate(true)
		if not include_password:
			room.erase("password")
		rooms_list.append(room)
	return rooms_list

## Retorna apenas salas que NÃO estão em partida.
func get_rooms_in_lobby() -> Array:
	var lobby_rooms = []
	for room_id in rooms:
		if not rooms[room_id]["in_game"]:
			var room = rooms[room_id].duplicate(true)
			room.erase("password")
			lobby_rooms.append(room)
	return lobby_rooms

## Retorna salas fora de jogo com dados normalizados para o menu.
func get_rooms_in_lobby_clean_to_menu() -> Array:
	var lobby_rooms: Array = []

	for room_id in rooms:
		var room_data = rooms[room_id]

		if room_data.get("in_game", false):
			continue

		var room = room_data.duplicate(true)

		var players_array = room.get("players", [])
		var players_count: int = players_array.size() if players_array is Array else 0
		var locked = room["settings"].get("locked", false)

		var min_raw = room.get("min_players", 0)
		var min_players: int = (
			min_raw if min_raw is int
			else int(min_raw) if min_raw is float
			else min_raw.to_int() if min_raw is String and min_raw.is_valid_integer()
			else 0
		)

		var max_raw = room.get("max_players", 0)
		var max_players: int = (
			max_raw if max_raw is int
			else int(max_raw) if max_raw is float
			else max_raw.to_int() if max_raw is String and max_raw.is_valid_integer()
			else 0
		)

		room.erase("host_uuid")
		room.erase("players")
		room.erase("in_game")
		room.erase("created_at")
		room.erase("rounds_history")
		room.erase("total_playtime")
		room.erase("settings")
		room.erase("password")

		room["players"] = players_count
		room["min_players"] = min_players
		room["max_players"] = max_players
		room["locked"] = locked

		lobby_rooms.append(room)
	return lobby_rooms

## Retorna apenas salas que ESTÃO em partida.
func get_rooms_in_game() -> Array:
	var game_rooms = []
	for room_id in rooms:
		if rooms[room_id]["in_game"]:
			var room = rooms[room_id].duplicate(true)
			room.erase("password")
			game_rooms.append(room)
	return game_rooms


# ===== GERENCIAMENTO DE PLAYERS =====

## Adiciona jogador à sala. Atualiza ClientRegistry automaticamente.
func add_player_to_room(room_id: int, uuid_base: String) -> bool:
	if not rooms.has(room_id):
		_log_debug("❌ Sala %d não existe" % room_id)
		return false

	var room = rooms[room_id]

	# Verifica se já está na sala
	for player in room["players"]:
		if player["uuid_base"] == uuid_base:
			_log_debug("⚠ uuid=%s já está na sala %d" % [uuid_base, room_id])
			return true

	if room["players"].size() >= room["max_players"]:
		_log_debug("❌ Sala %d está cheia!" % room_id)
		return false

	if room["in_game"]:
		_log_debug("❌ Sala %d está em partida" % room_id)
		return false

	if not client_registry or not client_registry.is_player_registered(uuid_base):
		push_error("RoomRegistry: uuid=%s não está registrado" % uuid_base)
		return false

	var player_name = client_registry.get_player_name(uuid_base)
	var player_id = client_registry.get_peer_id_by_uuid(uuid_base)

	var is_host = room["players"].is_empty() or uuid_base == room["host_uuid"]

	room["players"].append({
		"uuid_base": uuid_base,
		"session_id": player_id,
		"name": player_name,
		"is_host": is_host,
		"is_offline": false,
		"character": _create_default_character(room_id, uuid_base)
	})

	if client_registry:
		client_registry.join_room(uuid_base, room_id)

	_log_debug("✓ Player '%s' (uuid=%s) entrou na sala '%s'" % [player_name, uuid_base, room["name"]])
	player_joined_room.emit(room_id, uuid_base)

	return true

## Armazena configurações de personagens de cada cliente na sala.
func _create_default_character(room_id: int, uuid_base: String) -> Dictionary:
	_log_debug("Criando configurações de personagem para player %s na sala: %d" % [uuid_base, room_id])
	var character_data: Dictionary
	character_data["color"] = _assign_color_to_player(room_id)
	# Adicionar outros dados aqui

	return character_data

func _assign_color_to_player(room_id_: int) -> Color:
	
	var room = rooms[room_id_]

	# Se ainda tem cores fixas
	if not room["available_colors"].is_empty():
		var index = randi() % room["available_colors"].size()
		var color = room["available_colors"][index]
		room["available_colors"].remove_at(index)
		return color

	# Fallback infinito (golden ratio)
	room["last_hue"] = fmod(room["last_hue"] + 0.61803398875, 1.0)
	return Color.from_hsv(room["last_hue"], 0.7, 0.9)

func _return_color_to_pool(room_id_: int, color: Color) -> void:
	if not rooms.has(room_id_):
		return

	var room = rooms[room_id_]

	# Evita duplicar cor no pool
	if color in room["available_colors"]:
		return

	room["available_colors"].append(color)

## Adiciona jogador à lista de expulsos.
func add_player_to_kicked(room_id: int, uuid_base: String) -> bool:
	if not rooms.has(room_id):
		_log_debug("❌ Sala %d não existe" % room_id)
		return false

	var room = rooms[room_id]

	var player_ = client_registry.get_player_by_uuid(uuid_base)

	room["kicked_players"].append({
		"uuid_base": uuid_base,
		"time": Time.get_unix_time_from_system()
	})

	_log_debug("✓ Player '%s' (uuid=%s) adicionado como expulso da sala '%s'" % [player_["name"], uuid_base, room["name"]])
	return true

## Retorna uma lista de dados dos jogadores que foram expulsos/banidos da sala.
## [br]O parâmetro [param entry] define se deve retornar o UUID ou a posição de entrada.
## @return Array contendo os identificadores dos jogadores banidos.
func get_all_kicked_players(room_id: int, entry: bool = false) -> Array:
	var kicked: Array = []
	for player in rooms[room_id]["kicked_players"]:
		var uuid = player["uuid_base"]
		var client = client_registry.get_player(uuid)
		kicked.append(client["uuid_base" if not entry else "entry_position"])
	return kicked

## Verifica se um jogador ainda deve permanecer na lista de banidos.
## Se o tempo limite ([param time_limit]) tiver passado, o jogador é removido da lista.
## @return [bool] true se o jogador ainda estiver banido; false se o banimento expirou ou não existe.
func check_kicked_timeout(room_id: int, uuid_base: String, time_limit: float) -> bool:
	if not rooms.has(room_id):
		return false

	var room = rooms[room_id]
	var kicked_list: Array = room["kicked_players"]
	var now := Time.get_unix_time_from_system()

	for i in range(kicked_list.size() - 1, -1, -1):
		var entry = kicked_list[i]

		if entry["uuid_base"] == uuid_base:
			var elapsed: float = now - entry["time"]

			if elapsed >= time_limit:
				kicked_list.remove_at(i)
				_log_debug("✓ Banimento expirado para uuid=%s na sala %d" % [uuid_base, room_id])
				return false

			return true

	return false

## Remove um jogador da sala e gerencia a lógica de sucessão de host.
## Se o jogador removido for o host, o próximo jogador na lista será promovido. 
## Se a sala ficar vazia, a sala é deletada do registro.
## Já remove automaticamente do round. (Impossível estar em um round sem estar em uma sala)
## @return [String] O UUID do novo host (se houver mudança) ou uma string vazia se não houver mudança ou erro.
func remove_player_from_room(room_id: int, uuid_base: String) -> String:
	if not rooms.has(room_id):
		return ""

	var room = rooms[room_id]
	var player_index = -1

	for i in range(room["players"].size()):
		if room["players"][i]["uuid_base"] == uuid_base:
			player_index = i
			break

	if player_index == -1:
		_log_debug("⚠ uuid=%s não está na sala %d" % [uuid_base, room_id])
		return ""

	var player_name = room["players"][player_index]["name"]
	var was_host = room["players"][player_index]["is_host"]

	_return_color_to_pool(room_id, room["players"][player_index]["character"]["color"])
	
	# Se estiver em um round, remove dele antes de remover da sala
	var player = client_registry.get_player(uuid_base)
	if player and player["round_id"] > 0:
		round_registry.remove_player(player["round_id"], uuid_base)
	
	# Remove player da sala
	room["players"].remove_at(player_index)


	if client_registry:
		client_registry.leave_room(uuid_base)

	if was_host and not room["players"].is_empty():
		room["players"][0]["is_host"] = true
		room["host_uuid"] = room["players"][0]["uuid_base"]
		_log_debug("✓ Novo host da sala '%s': uuid=%s" % [room["name"], room["host_uuid"]])
		host_changed.emit(room_id, room["host_uuid"])
		return room["host_uuid"]
	
	if room["players"].is_empty():
		remove_room(room_id)
	
	_log_debug("✓ Player '%s' (uuid=%s) saiu da sala '%s'" % [player_name, uuid_base, room["name"]])
	player_left_room.emit(room_id, uuid_base)
	return ""

## Localiza a sala onde o jogador está presente.
## @return [Dictionary] Uma cópia dos dados da sala. Retorna um dicionário vazio {} se o jogador não estiver em nenhuma sala.
func get_player_room(uuid_base: String) -> Dictionary:
	for room_id in rooms:
		for player in rooms[room_id]["players"]:
			if player["uuid_base"] == uuid_base:
				return rooms[room_id].duplicate(true)
	return {}

## Verifica se jogador está em sala específica.
func is_player_in_room(uuid_base: String, room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	for player in rooms[room_id]["players"]:
		if player["uuid_base"] == uuid_base:
			return true
	return false

## Verifica se jogador é host da sala.
func is_player_host(uuid_base: String, room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["host_uuid"] == uuid_base

func get_player_count_in_room(room_id: int) -> int:
	if not rooms.has(room_id):
		return 0
	return rooms[room_id]["players"].size()

func _get_color_pool() -> Array:
	return [
		Color(1, 0.2, 0.2),
		Color(0.2, 1, 0.2),
		Color(0.2, 0.2, 1),
		Color(1, 1, 0.2),
		Color(1, 0.2, 1),
		Color(0.2, 1, 1),

		Color(1, 0.5, 0.2),
		Color(0.6, 0.2, 1),
		Color(0.2, 0.6, 1),
		Color(0.6, 1, 0.2),

		Color(1, 0.2, 0.6),
		Color(0.2, 1, 0.6),
		Color(0.6, 0.6, 0.6),
		Color(1, 0.8, 0.2),
		Color(0.8, 0.4, 0.1),

		Color(0.4, 0.2, 0.1),
		Color(0.2, 0.4, 0.8),
		Color(0.8, 0.2, 0.4),
		Color(0.4, 0.8, 0.2),
		Color(0.9, 0.9, 0.9)
	]


# ===== ESTADO DA SALA =====

## Marca sala como 'em jogo' ou 'no lobby'.
func set_room_in_game(room_id: int, in_game: bool):
	if not rooms.has(room_id):
		return

	rooms[room_id]["in_game"] = in_game
	_log_debug("✓ Sala %d in_game = %s" % [room_id, in_game])
	room_state_changed.emit(room_id, in_game)

func is_room_in_game(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["in_game"]

## Executada pelo client registry. Marca jogador como desconectado a partir do peer_id da sessão.
func _set_disconnected_peer(peer_id: int, room_id: int):
	var uuid_base = client_registry.get_uuid_by_peer_id(peer_id)
	
	if uuid_base.is_empty():
		_log_debug("⚠ Tentou desconectar peer inexistente: %d" % peer_id)
		return
		
	if not rooms.has(room_id):
		return
		
	for player in rooms[room_id].get("players", []):
		if player["uuid_base"] == uuid_base:
			player["is_offline"] = true
			_log_debug("⚠ uuid=%s marcado como desconectado na sala %s" % [uuid_base, rooms[room_id]["id"]])

## Executada pelo client registry. Marca jogador como conectado a partir do peer_id da sessão.
func _set_connected_peer(peer_id: int, room_id: int):
	var uuid_base = client_registry.get_uuid_by_peer_id(peer_id)
	
	if uuid_base.is_empty():
		_log_debug("⚠ Tentou desconectar peer inexistente: %d" % peer_id)
		return
		
	if not rooms.has(room_id):
		return
		
	for player in rooms[room_id].get("players", []):
		if player["uuid_base"] == uuid_base:
			player["is_offline"] = false
			_log_debug("⚠ uuid=%s marcado como conectado na sala %s" % [uuid_base, rooms[room_id]["id"]])


# ===== HISTÓRICO DE RODADAS =====

## Adiciona rodada finalizada ao histórico da sala e atualiza estatísticas.
func add_round_to_history(room_id: int, round_data: Dictionary) -> bool:
	if not rooms.has(room_id):
		_log_debug("❌ Tentou adicionar rodada ao histórico de sala inexistente: %d" % room_id)
		return false

	var room = rooms[room_id]

	var clean_round = round_data.duplicate(true)
	clean_round.erase("map_manager")
	clean_round.erase("spawned_players")
	clean_round.erase("round_timer")

	room["rounds_history"].append(clean_round)
	room["total_rounds_played"] += 1

	if clean_round.has("duration"):
		room["total_playtime"] += clean_round["duration"]

	_log_debug("✓ Rodada %d adicionada ao histórico da sala '%s' (Total: %d rodadas, %.1fs)" % [
		clean_round["id"],
		room["name"],
		room["total_rounds_played"],
		room["total_playtime"]
	])

	round_added_to_history.emit(room_id, clean_round)
	return true

func get_rounds_history(room_id: int) -> Array:
	if not rooms.has(room_id):
		return []
	return rooms[room_id]["rounds_history"].duplicate(true)

func get_last_round(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	var history = rooms[room_id]["rounds_history"]
	if history.is_empty():
		return {}
	return history[-1].duplicate(true)

func clear_rounds_history(room_id: int):
	if not rooms.has(room_id):
		return
	rooms[room_id]["rounds_history"].clear()
	rooms[room_id]["total_rounds_played"] = 0
	rooms[room_id]["total_playtime"] = 0.0
	_log_debug("✓ Histórico da sala %d limpo" % room_id)


# ===== ESTATÍSTICAS ACUMULADAS =====

## Calcula e retorna as estatísticas acumuladas de toda a história da sala.
## Inclui dados sobre tempo total de jogo, duração média e ranking de jogadores (mais ativos e maiores pontuadores).
## @return [Dictionary] Contém as chaves: 'total_rounds', 'total_playtime', 'average_round_duration', 'players_participated', etc.
func get_room_statistics(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}

	var room = rooms[room_id]

	var stats = {
		"total_rounds": room["total_rounds_played"],
		"total_playtime": room["total_playtime"],
		"average_round_duration": 0.0,
		"players_participated": {},  # {uuid_base: {name, rounds_played, total_score}}
		"most_active_player": {},
		"highest_scorer": {}
	}

	if room["total_rounds_played"] > 0:
		stats["average_round_duration"] = room["total_playtime"] / room["total_rounds_played"]

	for round_data in room["rounds_history"]:
		for player in round_data.get("players", []):
			var p_uuid = player["uuid_base"]  # uuid_base

			if not stats["players_participated"].has(p_uuid):
				stats["players_participated"][p_uuid] = {
					"name": player["name"],
					"rounds_played": 0,
					"total_score": 0
				}

			stats["players_participated"][p_uuid]["rounds_played"] += 1

			var scores = round_data.get("scores", {})
			if scores.has(p_uuid):
				stats["players_participated"][p_uuid]["total_score"] += scores[p_uuid]

	var max_rounds = 0
	for p_uuid in stats["players_participated"]:
		var rounds = stats["players_participated"][p_uuid]["rounds_played"]
		if rounds > max_rounds:
			max_rounds = rounds
			stats["most_active_player"] = {
				"uuid_base": p_uuid,
				"name": stats["players_participated"][p_uuid]["name"],
				"rounds_played": rounds
			}

	var max_score = 0
	for p_uuid in stats["players_participated"]:
		var score = stats["players_participated"][p_uuid]["total_score"]
		if score > max_score:
			max_score = score
			stats["highest_scorer"] = {
				"uuid_base": p_uuid,
				"name": stats["players_participated"][p_uuid]["name"],
				"total_score": score
			}

	return stats

## Retorna estatísticas de um jogador específico na sala.
func get_player_stats_in_room(room_id: int, uuid_base: String) -> Dictionary:
	if not rooms.has(room_id):
		return {}

	var room = rooms[room_id]
	var stats = {
		"rounds_played": 0,
		"total_score": 0,
		"wins": 0
	}

	for round_data in room["rounds_history"]:
		var participated = false
		for player in round_data.get("players", []):
			if player["uuid_base"] == uuid_base:
				participated = true
				break

		if not participated:
			continue

		stats["rounds_played"] += 1

		var scores = round_data.get("scores", {})
		if scores.has(uuid_base):
			stats["total_score"] += scores[uuid_base]

		var winner = round_data.get("winner", {})
		if winner.get("uuid_base") == uuid_base:
			stats["wins"] += 1

	return stats


# ===== VALIDAÇÕES PARA INICIAR PARTIDA =====

## Verifica se um jogador possui os requisitos mínimos para iniciar uma partida na sala.
## Valida: existência da sala, presença do jogador na sala, status da sala (não pode estar em jogo), 
## quantidade mínima/máxima de jogadores e permissão de host.
## @return [Array] Um array contendo [bool, String], onde o primeiro elemento é o sucesso e o segundo a mensagem de erro.
func can_start_match(room_id: int, uuid_base: String) -> Array:
	if not rooms.has(room_id):
		return [false, "A sala não existe"]

	var room = rooms[room_id]

	var players_uuids: Array = []
	for player: Dictionary in room["players"]:
		players_uuids.append(player["uuid_base"])

	if not uuid_base in players_uuids:
		return [false, "Você não está na sala"]

	if room["in_game"]:
		return [false, "A sala já está em jogo"]

	if room.is_empty():
		return [false, "A sala está vazia"]

	if room["players"].size() < room["min_players"]:
		return [false, "A sala não preenche o mínimo de players"]

	if room["players"].size() > room["max_players"]:
		return [false, "A sala não preenche o máximo de players"]

	if room["host_uuid"] != uuid_base:
		return [false, "Apenas o host pode iniciar a rodada"]

	if is_room_in_game(room["id"]):
		return [false, "A sala já está em uma rodada"]

	return [true, ""]

## Retorna informações sobre requisitos para iniciar partida.
func get_match_requirements(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}

	var room = rooms[room_id]

	return {
		"current_players": room["players"].size(),
		"min_players": room["min_players"],
		"max_players": room["max_players"],
	}


# ===== CONFIGURAÇÕES DA SALA =====

func set_room_settings(room_id: int, settings: Dictionary):
	if not rooms.has(room_id):
		return
	rooms[room_id]["settings"] = settings.duplicate(true)
	_log_debug("✓ Configurações da sala %d atualizadas" % room_id)

func get_room_settings(room_id: int) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	return rooms[room_id]["settings"].duplicate(true)

func update_room_setting(room_id: int, key: String, value):
	if not rooms.has(room_id):
		return
	rooms[room_id]["settings"][key] = value
	_log_debug("✓ Setting '%s' atualizado na sala %d" % [key, room_id])


# ===== UTILITÁRIOS =====

func _on_peer_id_updated(uuid_base: String, new_peer_id: int):
	for room_id in rooms:
		for player in rooms[room_id]["players"]:
			if player["uuid_base"] == uuid_base:
				player["session_id"] = new_peer_id
				_log_debug("✓ session_id atualizado para uuid=%s na sala %d" % [uuid_base, room_id])
				return

func get_room_count() -> int:
	return rooms.size()

func get_total_players_count() -> int:
	var total = 0
	for room_id in rooms:
		total += rooms[room_id]["players"].size()
	return total

func get_next_room_id() -> int:
	for room_id in rooms:
		if room_id > max_id:
			max_id = room_id
	return max_id + 1

## Valida nome da sala.
## Retorna string vazia se válido, mensagem de erro caso contrário.
func _validate_room_name(room_name: String) -> String:
	var trimmed = room_name.strip_edges()
	
	if trimmed.is_empty():
		return "O nome da sala não pode estar vazio"
	
	if trimmed.length() < 5:
		return "O nome da sala deve ter pelo menos 5 caracteres"
	
	if trimmed.length() > 30:
		return "O nome da sala deve ter no máximo 30 caracteres"
	
	if room_name_exists(trimmed):
		return "Já existe uma sala com o nome escolhido"
	
	return ""

func debug_print_all_rooms():
	print("\n========== ROOM REGISTRY ==========")
	print("Total de salas: %d" % rooms.size())
	print("Total de jogadores: %d" % get_total_players_count())
	print("-----------------------------------")

	for room_id in rooms:
		var r = rooms[room_id]
		print("\n[Sala %d: %s]" % [room_id, r["name"]])
		print("  Host: uuid=%s" % r["host_uuid"])
		print("  Jogadores: %d/%d (mín: %d)" % [r["players"].size(), r["max_players"], r["min_players"]])
		print("  Em jogo: %s" % r["in_game"])
		print("  Senha: %s" % ("SIM" if r["has_password"] else "NÃO"))
		print("  Rodadas jogadas: %d" % r["total_rounds_played"])
		print("  Tempo total: %.1fs" % r["total_playtime"])

		print("  Players:")
		for player in r["players"]:
			var host_marker = " (HOST)" if player["is_host"] else ""
			print("    - %s [uuid=%s]%s" % [player["name"], player["uuid_base"], host_marker])

	print("\n===================================\n")

func _log_debug(message: String):
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "RoomRegistry" in initializer.selected:
		return
	print("[SERVER][RoomRegistry] %s" % message)
