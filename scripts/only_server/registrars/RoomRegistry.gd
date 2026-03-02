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
## - host_id e player["id"] armazenam uuid_base

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var client_registry = null
var round_registry = null
var object_manager = null
var initializer = null

# ===== VARIÁVEIS INTERNAS =====

## Dados de todas as salas: {room_id: RoomData}
var rooms: Dictionary = {}

var _initialized: bool = false

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
##   "host_id": String,           # uuid_base do host
##   "players": Array[PlayerInRoom],  # [{id: uuid_base, name, is_host}]
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

func initialize():
	"""Inicializa o RoomRegistry (chamado apenas no servidor)"""
	if _initialized:
		_log_debug("⚠ RoomRegistry já inicializado")
		return

	_initialized = true
	_log_debug("✓ RoomRegistry inicializado")

func reset():
	"""Reseta completamente o registro (usado ao desligar servidor)"""
	rooms.clear()
	_initialized = false
	_log_debug("🔄 RoomRegistry resetado")

# ===== GERENCIAMENTO DE SALAS =====

func _get_next_room_id() -> int:
	var max_id = 0
	for room_id in rooms:
		if room_id > max_id:
			max_id = room_id
	return max_id + 1

func create_room(room_name: String, password: String, host_uuid: String, min_players: int, max_players: int) -> Dictionary:
	"""Cria nova sala. Retorna RoomData completo ou {} se falhar."""
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
		"host_id": host_uuid,
		"players": [],
		"kicked_players": [],
		"min_players": min_players,
		"max_players": max_players,
		"in_game": false,
		"created_at": Time.get_unix_time_from_system(),
		"rounds_history": [],
		"total_rounds_played": 0,
		"total_playtime": 0.0,
		"settings": {"locked": false}
	}

	rooms[room_id] = room_data

	# Adiciona host automaticamente
	add_player_to_room(room_id, host_uuid)

	_log_debug("✓ Sala criada: '%s' (ID: %d, Host: %s)" % [room_name, room_id, host_uuid])
	room_created.emit(room_data.duplicate())

	return room_data.duplicate()

func remove_room(room_id: int) -> bool:
	"""Remove sala completamente após remover todos os jogadores."""
	if not rooms.has(room_id):
		_log_debug("⚠ Tentou remover sala inexistente: %d" % room_id)
		return false

	var room = rooms[room_id]
	var room_name = room["name"]

	var players_copy = room["players"].duplicate()
	for player_data in players_copy:
		remove_player_from_room(room_id, player_data["id"])

	rooms.erase(room_id)

	_log_debug("✓ Sala removida: '%s' (ID: %d)" % [room_name, room_id])
	room_removed.emit(room_id)

	return true

func get_room(room_id: int) -> Dictionary:
	"""Retorna cópia completa dos dados da sala."""
	if not rooms.has(room_id):
		return {}
	return rooms[room_id].duplicate(true)

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

func get_rooms_in_lobby() -> Array:
	"""Retorna apenas salas que NÃO estão em partida."""
	var lobby_rooms = []
	for room_id in rooms:
		if not rooms[room_id]["in_game"]:
			var room = rooms[room_id].duplicate(true)
			room.erase("password")
			lobby_rooms.append(room)
	return lobby_rooms

func get_rooms_in_lobby_clean_to_menu() -> Array:
	"""Retorna salas fora de jogo com dados normalizados para o menu."""
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

		room.erase("host_id")
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

func get_rooms_in_game() -> Array:
	"""Retorna apenas salas que ESTÃO em partida."""
	var game_rooms = []
	for room_id in rooms:
		if rooms[room_id]["in_game"]:
			var room = rooms[room_id].duplicate(true)
			room.erase("password")
			game_rooms.append(room)
	return game_rooms

# ===== GERENCIAMENTO DE PLAYERS =====

func add_player_to_room(room_id: int, uuid_base: String) -> bool:
	"""Adiciona jogador à sala. Atualiza ClientRegistry automaticamente."""
	if not rooms.has(room_id):
		_log_debug("❌ Sala %d não existe" % room_id)
		return false

	var room = rooms[room_id]

	# Verifica se já está na sala
	for player in room["players"]:
		if player["id"] == uuid_base:
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

	var is_host = room["players"].is_empty() or uuid_base == room["host_id"]

	room["players"].append({
		"id": uuid_base,
		"session_id": player_id,
		"name": player_name,
		"is_host": is_host
	})

	if client_registry:
		client_registry.join_room(uuid_base, room_id)

	_log_debug("✓ Player '%s' (uuid=%s) entrou na sala '%s'" % [player_name, uuid_base, room["name"]])
	player_joined_room.emit(room_id, uuid_base)

	return true

func add_player_to_kicked(room_id: int, uuid_base: String) -> bool:
	"""Adiciona jogador à lista de expulsos."""
	if not rooms.has(room_id):
		_log_debug("❌ Sala %d não existe" % room_id)
		return false

	var room = rooms[room_id]

	if room["in_game"]:
		_log_debug("❌ Sala %d está em partida" % room_id)
		return false

	var player_ = client_registry.get_player_by_uuid(uuid_base)

	room["kicked_players"].append({
		"uuid_base": uuid_base,
		"time": Time.get_unix_time_from_system()
	})

	_log_debug("✓ Player '%s' (uuid=%s) adicionado como expulso da sala '%s'" % [player_["name"], uuid_base, room["name"]])
	return true

func check_kicked_timeout(room_id: int, uuid_base: String, time_limit: float) -> bool:
	"""Verifica se o jogador ainda está banido.
	Se o tempo ultrapassou time_limit, remove da lista.
	Retorna true se ainda estiver banido."""
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

func remove_player_from_room(room_id: int, uuid_base: String) -> bool:
	"""Remove jogador da sala. Transfere host se necessário. Remove sala se ficar vazia."""
	if not rooms.has(room_id):
		return false

	var room = rooms[room_id]
	var player_index = -1

	for i in range(room["players"].size()):
		if room["players"][i]["id"] == uuid_base:
			player_index = i
			break

	if player_index == -1:
		_log_debug("⚠ uuid=%s não está na sala %d" % [uuid_base, room_id])
		return false

	var player_name = room["players"][player_index]["name"]
	var was_host = room["players"][player_index]["is_host"]

	room["players"].remove_at(player_index)

	if client_registry:
		client_registry.leave_room(uuid_base)

	_log_debug("✓ Player '%s' (uuid=%s) saiu da sala '%s'" % [player_name, uuid_base, room["name"]])
	player_left_room.emit(room_id, uuid_base)

	if was_host and not room["players"].is_empty():
		room["players"][0]["is_host"] = true
		room["host_id"] = room["players"][0]["id"]
		_log_debug("✓ Novo host da sala '%s': uuid=%s" % [room["name"], room["host_id"]])
		host_changed.emit(room_id, room["host_id"])

	if room["players"].is_empty():
		remove_room(room_id)

	return true

func get_player_room(uuid_base: String) -> Dictionary:
	"""Retorna sala em que o jogador está (ou {} se não estiver em nenhuma)."""
	for room_id in rooms:
		for player in rooms[room_id]["players"]:
			if player["id"] == uuid_base:
				return rooms[room_id].duplicate(true)
	return {}

func is_player_in_room(uuid_base: String, room_id: int) -> bool:
	"""Verifica se jogador está em sala específica."""
	if not rooms.has(room_id):
		return false
	for player in rooms[room_id]["players"]:
		if player["id"] == uuid_base:
			return true
	return false

func is_player_host(uuid_base: String, room_id: int) -> bool:
	"""Verifica se jogador é host da sala."""
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["host_id"] == uuid_base

func get_player_count_in_room(room_id: int) -> int:
	if not rooms.has(room_id):
		return 0
	return rooms[room_id]["players"].size()

# ===== ESTADO DA SALA =====

func set_room_in_game(room_id: int, in_game: bool):
	"""Marca sala como 'em jogo' ou 'no lobby'."""
	if not rooms.has(room_id):
		return

	rooms[room_id]["in_game"] = in_game
	_log_debug("✓ Sala %d in_game = %s" % [room_id, in_game])
	room_state_changed.emit(room_id, in_game)

func is_room_in_game(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["in_game"]

# ===== HISTÓRICO DE RODADAS =====

func add_round_to_history(room_id: int, round_data: Dictionary) -> bool:
	"""Adiciona rodada finalizada ao histórico da sala e atualiza estatísticas."""
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
		clean_round["round_id"],
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

func get_room_statistics(room_id: int) -> Dictionary:
	"""Retorna estatísticas gerais da sala (jogadores identificados por uuid_base)."""
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
			var p_uuid = player["id"]  # uuid_base

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

func get_player_stats_in_room(room_id: int, uuid_base: String) -> Dictionary:
	"""Retorna estatísticas de um jogador específico na sala."""
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
			if player["id"] == uuid_base:
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

func can_start_match(room_id: int, uuid_base: String) -> Array:
	"""Verifica se sala pode iniciar partida."""
	if not rooms.has(room_id):
		return [false, "A sala não existe"]

	var room = rooms[room_id]

	var players_uuids: Array = []
	for player: Dictionary in room["players"]:
		players_uuids.append(player["id"])

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

	if room["host_id"] != uuid_base:
		return [false, "Apenas o host pode iniciar a rodada"]

	if is_room_in_game(room["id"]):
		return [false, "A sala já está em uma rodada"]

	return [true, ""]

func get_match_requirements(room_id: int) -> Dictionary:
	"""Retorna informações sobre requisitos para iniciar partida."""
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

func get_room_count() -> int:
	return rooms.size()

func get_total_players_count() -> int:
	var total = 0
	for room_id in rooms:
		total += rooms[room_id]["players"].size()
	return total

func get_next_room_id() -> int:
	var max_id = 0
	for room_id in rooms:
		if room_id > max_id:
			max_id = room_id
	return max_id + 1

func debug_print_all_rooms():
	print("\n========== ROOM REGISTRY ==========")
	print("Total de salas: %d" % rooms.size())
	print("Total de jogadores: %d" % get_total_players_count())
	print("-----------------------------------")

	for room_id in rooms:
		var r = rooms[room_id]
		print("\n[Sala %d: %s]" % [room_id, r["name"]])
		print("  Host: uuid=%s" % r["host_id"])
		print("  Jogadores: %d/%d (mín: %d)" % [r["players"].size(), r["max_players"], r["min_players"]])
		print("  Em jogo: %s" % r["in_game"])
		print("  Senha: %s" % ("SIM" if r["has_password"] else "NÃO"))
		print("  Rodadas jogadas: %d" % r["total_rounds_played"])
		print("  Tempo total: %.1fs" % r["total_playtime"])

		print("  Players:")
		for player in r["players"]:
			var host_marker = " (HOST)" if player["is_host"] else ""
			print("    - %s [uuid=%s]%s" % [player["name"], player["id"], host_marker])

	print("\n===================================\n")

func _log_debug(message: String):
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "RoomRegistry" in initializer.selected:
		return
	print("[SERVER][RoomRegistry] %s" % message)
