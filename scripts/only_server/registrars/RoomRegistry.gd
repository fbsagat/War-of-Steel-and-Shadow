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

# Estado de inicialização
var _initialized: bool = false

# ===== SINAIS =====

signal room_created(room_data: Dictionary)
signal room_removed(room_id: int)
signal player_joined_room(room_id: int, peer_id: int)
signal player_left_room(room_id: int, peer_id: int)
signal host_changed(room_id: int, new_host_id: int)
signal round_added_to_history(room_id: int, round_data: Dictionary)
signal room_state_changed(room_id: int, in_game: bool)

# ===== ESTRUTURAS DE DADOS =====

## RoomData:
## {
##   "id": int,
##   "name": String,
##   "password": String,
##   "has_password": bool,
##   "host_id": int,
##   "players": Array[PlayerInRoom],  # [{id, name, is_host}]
##   "min_players": int,
##   "max_players": int,
##   "in_game": bool,
##   "created_at": float,
##   "rounds_history": Array[RoundData],  # Histórico de rodadas finalizadas
##   "total_rounds_played": int,
##   "total_playtime": float,  # Tempo acumulado de todas as rodadas
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
	"""Gera próximo ID de rodada disponível"""
	var max_id = 0
	for room_id in rooms:
		if room_id > max_id:
			max_id = room_id
	return max_id + 1

func create_room(room_name: String, password: String, host_peer_id: int, min_players: int, max_players: int) -> Dictionary:
	"""
	Cria nova sala
	Retorna RoomData completo ou {} se falhar
	"""
	var room_id = _get_next_room_id()
	
	if rooms.has(room_id):
		push_error("RoomRegistry: Sala com ID %d já existe!" % room_id)
		return {}
	
	# Valida se host existe
	if not client_registry or not client_registry.is_player_registered(host_peer_id):
		push_error("RoomRegistry: Host %d não é um jogador válido" % host_peer_id)
		return {}
	
	var room_data = {
		"id": room_id,
		"name": room_name,
		"password": password,
		"has_password": not password.is_empty(),
		"host_id": host_peer_id,
		"players": [],
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
	add_player_to_room(room_id, host_peer_id)
	
	_log_debug("✓ Sala criada: '%s' (ID: %d, Host: %d)" % [room_name, room_id, host_peer_id])
	room_created.emit(room_data.duplicate())
	
	return room_data.duplicate()

func remove_room(room_id: int) -> bool:
	"""
	Remove sala completamente
	Remove todos os jogadores primeiro
	"""
	if not rooms.has(room_id):
		_log_debug("⚠ Tentou remover sala inexistente: %d" % room_id)
		return false
	
	var room = rooms[room_id]
	var room_name = room["name"]
	
	# Remove todos os jogadores da sala
	var players_copy = room["players"].duplicate()
	for player_data in players_copy:
		remove_player_from_room(room_id, player_data["id"])
	
	# Remove sala
	rooms.erase(room_id)
	
	_log_debug("✓ Sala removida: '%s' (ID: %d)" % [room_name, room_id])
	room_removed.emit(room_id)
	
	return true

func get_room(room_id: int) -> Dictionary:
	"""Retorna cópia completa dos dados da sala"""
	if not rooms.has(room_id):
		return {}
	return rooms[room_id].duplicate(true)

func get_room_by_name(room_name: String) -> Dictionary:
	"""Busca sala por nome"""
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return rooms[room_id].duplicate(true)
	return {}

func room_exists(room_id: int) -> bool:
	"""Verifica se sala existe"""
	return rooms.has(room_id)

func room_name_exists(room_name: String) -> bool:
	"""Verifica se já existe sala com esse nome"""
	for room_id in rooms:
		if rooms[room_id]["name"] == room_name:
			return true
	return false

func get_rooms_list(include_password: bool = false) -> Array:
	"""
	Retorna lista de todas as salas
	Por padrão, omite senhas por segurança
	"""
	var rooms_list = []
	for room_id in rooms:
		var room = rooms[room_id].duplicate(true)
		if not include_password:
			room.erase("password")  # Segurança
		rooms_list.append(room)
	return rooms_list

func get_rooms_in_lobby() -> Array:
	"""Retorna apenas salas que NÃO estão em partida"""
	var lobby_rooms = []
	for room_id in rooms:
		if not rooms[room_id]["in_game"]:
			var room = rooms[room_id].duplicate(true)
			room.erase("password") # Segurança
			lobby_rooms.append(room)
	return lobby_rooms

func get_rooms_in_lobby_clean_to_menu() -> Array:
	"""Retorna apenas salas que NÃO estão em partida, com dados normalizados para o lobby"""
	var lobby_rooms: Array = []

	for room_id in rooms:
		var room_data = rooms[room_id]
		
		# Ignora salas em jogo
		if room_data.get("in_game", false):
			continue
		
		var room = room_data.duplicate(true)
		
		# Players: Array → quantidade
		var players_array = room.get("players", [])
		var players_count: int = players_array.size() if players_array is Array else 0
		
		# Conversão direta de min_players
		var min_raw = room.get("min_players", 0)
		var min_players: int = (
			min_raw if min_raw is int
			else int(min_raw) if min_raw is float
			else min_raw.to_int() if min_raw is String and min_raw.is_valid_integer()
			else 0
		)
		
		# Conversão direta de max_players
		var max_raw = room.get("max_players", 0)
		var max_players: int = (
			max_raw if max_raw is int
			else int(max_raw) if max_raw is float
			else max_raw.to_int() if max_raw is String and max_raw.is_valid_integer()
			else 0
		)
		
		# Remove campos indesejados
		room.erase("host_id")
		room.erase("players")
		room.erase("in_game")
		room.erase("created_at")
		room.erase("rounds_history")
		room.erase("total_playtime")
		room.erase("settings")
		room.erase("password")
		
		# Reinsere dados normalizados
		room["players"] = players_count
		room["min_players"] = min_players
		room["max_players"] = max_players
		
		lobby_rooms.append(room)

	return lobby_rooms

func get_rooms_in_game() -> Array:
	"""Retorna apenas salas que ESTÃO em partida"""
	var game_rooms = []
	for room_id in rooms:
		if rooms[room_id]["in_game"]:
			var room = rooms[room_id].duplicate(true)
			room.erase("password")
			game_rooms.append(room)
	return game_rooms

# ===== GERENCIAMENTO DE PLAYERS =====

func add_player_to_room(room_id: int, peer_id: int) -> bool:
	"""
	Adiciona jogador à sala
	Atualiza ClientRegistry automaticamente
	"""
	if not rooms.has(room_id):
		_log_debug("❌ Sala %d não existe" % room_id)
		return false
	
	var room = rooms[room_id]
	
	# Verifica se já está na sala
	for player in room["players"]:
		if player["id"] == peer_id:
			_log_debug("⚠ Player %d já está na sala %d" % [peer_id, room_id])
			return true
	
	# Verifica se sala está cheia
	if room["players"].size() >= room["max_players"]:
		_log_debug("❌ Sala %d está cheia!" % room_id)
		return false
	
	# Verifica se sala está em jogo (não pode entrar durante partida)
	if room["in_game"]:
		_log_debug("❌ Sala %d está em partida" % room_id)
		return false
	
	# Valida jogador no ClientRegistry
	if not client_registry or not client_registry.is_player_registered(peer_id):
		push_error("RoomRegistry: Player %d não está registrado" % peer_id)
		return false
	
	var player_name = client_registry.get_player_name(peer_id)
	
	# Determina se é host (primeiro jogador OU host original)
	var is_host = room["players"].is_empty() or peer_id == room["host_id"]
	
	# Adiciona à sala
	room["players"].append({
		"id": peer_id,
		"name": player_name,
		"is_host": is_host
	})
	
	# Atualiza ClientRegistry
	if client_registry:
		client_registry.join_room(peer_id, room_id)
	
	_log_debug("✓ Player '%s' (%d) entrou na sala '%s'" % [player_name, peer_id, room["name"]])
	player_joined_room.emit(room_id, peer_id)
	
	return true

func remove_player_from_room(room_id: int, peer_id: int) -> bool:
	"""
	Remove jogador da sala
	Se era o host, transfere para próximo jogador
	Se sala ficar vazia, remove sala automaticamente
	"""
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	var player_index = -1
	
	# Encontra jogador
	for i in range(room["players"].size()):
		if room["players"][i]["id"] == peer_id:
			player_index = i
			break
	
	if player_index == -1:
		_log_debug("⚠ Player %d não está na sala %d" % [peer_id, room_id])
		return false
	
	var player_name = room["players"][player_index]["name"]
	var was_host = room["players"][player_index]["is_host"]
	
	# Remove da sala
	room["players"].remove_at(player_index)
	
	# Atualiza ClientRegistry
	if client_registry:
		client_registry.leave_room(peer_id)
	
	_log_debug("✓ Player '%s' (%d) saiu da sala '%s'" % [player_name, peer_id, room["name"]])
	player_left_room.emit(room_id, peer_id)
	
	# Se era host e ainda há jogadores, transfere host
	if was_host and not room["players"].is_empty():
		room["players"][0]["is_host"] = true
		room["host_id"] = room["players"][0]["id"]
		_log_debug("✓ Novo host da sala '%s': %d" % [room["name"], room["host_id"]])
		host_changed.emit(room_id, room["host_id"])
	
	# Se sala ficou vazia, remove
	if room["players"].is_empty():
		remove_room(room_id)
	
	return true

func get_player_room(peer_id: int) -> Dictionary:
	"""Retorna sala em que o jogador está (ou {} se não estiver em nenhuma)"""
	for room_id in rooms:
		for player in rooms[room_id]["players"]:
			if player["id"] == peer_id:
				return rooms[room_id].duplicate(true)
	return {}

func is_player_in_room(peer_id: int, room_id: int) -> bool:
	"""Verifica se jogador específico está em sala específica"""
	if not rooms.has(room_id):
		return false
	
	for player in rooms[room_id]["players"]:
		if player["peer_id"] == peer_id:
			return true
	return false

func is_player_host(peer_id: int, room_id: int) -> bool:
	"""Verifica se jogador é host da sala"""
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["host_id"] == peer_id

func get_player_count_in_room(room_id: int) -> int:
	"""Retorna quantidade de jogadores na sala"""
	if not rooms.has(room_id):
		return 0
	return rooms[room_id]["players"].size()

# ===== ESTADO DA SALA =====

func set_room_in_game(room_id: int, in_game: bool):
	"""
	Marca sala como "em jogo" ou "no lobby"
	Emite sinal de mudança de estado
	"""
	if not rooms.has(room_id):
		return
	
	rooms[room_id]["in_game"] = in_game
	_log_debug("✓ Sala %d in_game = %s" % [room_id, in_game])
	room_state_changed.emit(room_id, in_game)

func is_room_in_game(room_id: int) -> bool:
	"""Verifica se sala está em partida"""
	if not rooms.has(room_id):
		return false
	return rooms[room_id]["in_game"]

# ===== HISTÓRICO DE RODADAS =====

func add_round_to_history(room_id: int, round_data: Dictionary) -> bool:
	"""
	Adiciona rodada finalizada ao histórico da sala
	Atualiza estatísticas acumuladas (total de rodadas, tempo de jogo)
	Chamado pelo RoundRegistry quando rodada termina
	"""
	if not rooms.has(room_id):
		_log_debug("❌ Tentou adicionar rodada ao histórico de sala inexistente: %d" % room_id)
		return false
	
	var room = rooms[room_id]
	
	# Cria cópia limpa dos dados da rodada (remove referências de nodes)
	var clean_round = round_data.duplicate(true)
	clean_round.erase("map_manager")
	clean_round.erase("spawned_players")
	clean_round.erase("round_timer")
	
	# Adiciona ao histórico
	room["rounds_history"].append(clean_round)
	room["total_rounds_played"] += 1
	
	# Atualiza tempo total de jogo
	if clean_round.has("duration"):
		room["total_playtime"] += clean_round["duration"]
	
	_log_debug("✓ Rodada %d adicionada ao histórico da sala '%s' (Total: %d rodadas, %.1fs jogadas)" % [
		clean_round["round_id"],
		room["name"],
		room["total_rounds_played"],
		room["total_playtime"]
	])
	
	round_added_to_history.emit(room_id, clean_round)
	return true

func get_rounds_history(room_id: int) -> Array:
	"""Retorna histórico completo de rodadas da sala"""
	if not rooms.has(room_id):
		return []
	return rooms[room_id]["rounds_history"].duplicate(true)

func get_last_round(room_id: int) -> Dictionary:
	"""Retorna dados da última rodada jogada na sala"""
	if not rooms.has(room_id):
		return {}
	
	var history = rooms[room_id]["rounds_history"]
	if history.is_empty():
		return {}
	
	return history[-1].duplicate(true)

func clear_rounds_history(room_id: int):
	"""Limpa histórico de rodadas (útil para resetar sala)"""
	if not rooms.has(room_id):
		return
	
	rooms[room_id]["rounds_history"].clear()
	rooms[room_id]["total_rounds_played"] = 0
	rooms[room_id]["total_playtime"] = 0.0
	_log_debug("✓ Histórico da sala %d limpo" % room_id)

# ===== ESTATÍSTICAS ACUMULADAS =====

func get_room_statistics(room_id: int) -> Dictionary:
	"""
	Retorna estatísticas gerais da sala:
	- Total de rodadas jogadas
	- Tempo total de jogo
	- Duração média das rodadas
	- Jogadores únicos que participaram
	- Pontuações acumuladas por jogador (se aplicável)
	"""
	if not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	
	var stats = {
		"total_rounds": room["total_rounds_played"],
		"total_playtime": room["total_playtime"],
		"average_round_duration": 0.0,
		"players_participated": {},  # {peer_id: {name, rounds_played, total_score}}
		"most_active_player": {},
		"highest_scorer": {}
	}
	
	# Calcula duração média
	if room["total_rounds_played"] > 0:
		stats["average_round_duration"] = room["total_playtime"] / room["total_rounds_played"]
	
	# Analisa histórico de rodadas
	for round_data in room["rounds_history"]:
		for player in round_data.get("players", []):
			var p_id = player["peer_id"]
			
			# Inicializa jogador se não existe
			if not stats["players_participated"].has(p_id):
				stats["players_participated"][p_id] = {
					"name": player["name"],
					"rounds_played": 0,
					"total_score": 0
				}
			
			# Atualiza contadores
			stats["players_participated"][p_id]["rounds_played"] += 1
			
			# Soma pontuação se disponível
			var scores = round_data.get("scores", {})
			if scores.has(p_id):
				stats["players_participated"][p_id]["total_score"] += scores[p_id]
	
	# Encontra jogador mais ativo (mais rodadas)
	var max_rounds = 0
	for p_id in stats["players_participated"]:
		var rounds = stats["players_participated"][p_id]["rounds_played"]
		if rounds > max_rounds:
			max_rounds = rounds
			stats["most_active_player"] = {
				"id": p_id,
				"name": stats["players_participated"][p_id]["name"],
				"rounds_played": rounds
			}
	
	# Encontra maior pontuador
	var max_score = 0
	for p_id in stats["players_participated"]:
		var score = stats["players_participated"][p_id]["total_score"]
		if score > max_score:
			max_score = score
			stats["highest_scorer"] = {
				"id": p_id,
				"name": stats["players_participated"][p_id]["name"],
				"total_score": score
			}
	
	return stats

func get_player_stats_in_room(room_id: int, peer_id: int) -> Dictionary:
	"""
	Retorna estatísticas de um jogador específico na sala:
	- Rodadas jogadas
	- Pontuação total
	- Vitórias
	"""
	if not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	var stats = {
		"rounds_played": 0,
		"total_score": 0,
		"wins": 0
	}
	
	for round_data in room["rounds_history"]:
		# Verifica se jogador participou
		var participated = false
		for player in round_data.get("players", []):
			if player["peer_id"] == peer_id:
				participated = true
				break
		
		if not participated:
			continue
		
		stats["rounds_played"] += 1
		
		# Soma pontuação
		var scores = round_data.get("scores", {})
		if scores.has(peer_id):
			stats["total_score"] += scores[peer_id]
		
		# Verifica vitória
		var winner = round_data.get("winner", {})
		if winner.get("id") == peer_id:
			stats["wins"] += 1
	
	return stats

# ===== VALIDAÇÕES PARA INICIAR PARTIDA =====

func can_start_match(room_id: int) -> bool:
	"""
	Verifica se sala pode iniciar partida:
	- Não está em jogo
	- Tem jogadores suficientes
	"""
	if not rooms.has(room_id):
		return false
	
	var room = rooms[room_id]
	
	if room["in_game"]:
		return false
	
	if room["players"].size() < room["min_players"]:
		return false
	
	return true

func get_match_requirements(room_id: int) -> Dictionary:
	"""
	Retorna informações sobre requisitos para iniciar partida
	Útil para UI mostrar ao host
	"""
	if not rooms.has(room_id):
		return {}
	
	var room = rooms[room_id]
	
	return {
		"current_players": room["players"].size(),
		"min_players": room["min_players"],
		"max_players": room["max_players"],
		"can_start": can_start_match(room_id),
		"in_game": room["in_game"],
		"missing_players": max(0, room["min_players"] - room["players"].size())
	}

# ===== CONFIGURAÇÕES DA SALA =====

func set_room_settings(room_id: int, settings: Dictionary):
	"""
	Define configurações customizadas da sala
	Ex: dificuldade, modo de jogo, etc
	"""
	if not rooms.has(room_id):
		return
	
	rooms[room_id]["settings"] = settings.duplicate(true)
	_log_debug("✓ Configurações da sala %d atualizadas" % room_id)

func get_room_settings(room_id: int) -> Dictionary:
	"""Retorna configurações da sala"""
	if not rooms.has(room_id):
		return {}
	return rooms[room_id]["settings"].duplicate(true)

func update_room_setting(room_id: int, key: String, value):
	"""Atualiza uma configuração específica"""
	if not rooms.has(room_id):
		return
	
	rooms[room_id]["settings"][key] = value
	_log_debug("✓ Setting '%s' atualizado na sala %d" % [key, room_id])

# ===== UTILITÁRIOS =====

func get_room_count() -> int:
	"""Retorna total de salas ativas"""
	return rooms.size()

func get_total_players_count() -> int:
	"""Retorna total de jogadores em todas as salas"""
	var total = 0
	for room_id in rooms:
		total += rooms[room_id]["players"].size()
	return total

func get_next_room_id() -> int:
	"""Gera próximo ID de sala disponível"""
	var max_id = 0
	for room_id in rooms:
		if room_id > max_id:
			max_id = room_id
	return max_id + 1

func debug_print_all_rooms():
	"""Imprime estado completo de todas as salas"""
	print("\n========== ROOM REGISTRY ==========")
	print("Total de salas: %d" % rooms.size())
	print("Total de jogadores: %d" % get_total_players_count())
	print("-----------------------------------")
	
	for room_id in rooms:
		var r = rooms[room_id]
		print("\n[Sala %d: %s]" % [room_id, r["name"]])
		print("  Host: %d" % r["host_id"])
		print("  Jogadores: %d/%d (mín: %d)" % [r["players"].size(), r["max_players"], r["min_players"]])
		print("  Em jogo: %s" % r["in_game"])
		print("  Senha: %s" % ("SIM" if r["has_password"] else "NÃO"))
		print("  Rodadas jogadas: %d" % r["total_rounds_played"])
		print("  Tempo total: %.1fs" % r["total_playtime"])
		
		print("  Players:")
		for player in r["players"]:
			var host_marker = " (HOST)" if player["is_host"] else ""
			print("    - %s [%d]%s" % [player["name"], player["peer_id"], host_marker])
	
	print("\n===================================\n")

func _log_debug(message: String):
	"""Função padrão de debug"""
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "RoomRegistry" in initializer.selected:
		return
	
	print("[SERVER][RoomRegistry] %s" % message)
