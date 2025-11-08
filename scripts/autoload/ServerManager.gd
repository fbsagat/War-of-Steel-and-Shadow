extends Node
## ServerManager - Gerenciador do servidor dedicado
## Este script só é executado quando o jogo está rodando como servidor
## Todos os RPCs estão em NetworkManager

# ===== CONFIGURAÇÕES (Editáveis no Inspector) =====

@export var server_port: int = 7777
@export var max_clients: int = 32
@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

var is_dedicated_server: bool = false
var next_room_id: int = 1

## Referência ao MapManager do servidor
var server_map_manager: Node = null

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	_detect_server_mode()
	
	if is_dedicated_server:
		_start_server()
	else:
		_log_debug("Modo cliente - ServerManager inativo")

func _detect_server_mode():
	var args = OS.get_cmdline_args()
	is_dedicated_server = "--server" in args or "--dedicated" in args
	
	if not is_dedicated_server:
		is_dedicated_server = OS.has_environment("DEDICATED_SERVER")
	
	_log_debug("Modo servidor dedicado: " + str(is_dedicated_server))

func _start_server():
	_log_debug("========================================")
	_log_debug("INICIANDO SERVIDOR DEDICADO")
	_log_debug("Porta: %d" % server_port)
	_log_debug("Máximo de clientes: %d" % max_clients)
	_log_debug("========================================")
	
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(server_port, max_clients)
	
	if error != OK:
		_log_debug("✗ ERRO ao criar servidor: " + str(error))
		return
	
	multiplayer.multiplayer_peer = peer
	
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	_log_debug("✓ Servidor iniciado com sucesso!")

# ===== CALLBACKS DE CONEXÃO =====

func _on_peer_connected(peer_id: int):
	_log_debug("✓ Cliente conectado: Peer ID %d" % peer_id)
	PlayerRegistry.add_peer(peer_id)

func _on_peer_disconnected(peer_id: int):
	_log_debug("✗ Cliente desconectado: Peer ID %d" % peer_id)
	
	var player_data = PlayerRegistry.get_player(peer_id)
	if player_data and player_data.has("name"):
		_log_debug("  Jogador: %s" % player_data["name"])
		
		var room = RoomRegistry.get_room_by_player(peer_id)
		if room:
			RoomRegistry.remove_player_from_room(room["id"], peer_id)
			_log_debug("  Removido da sala: %s" % room["name"])
			_notify_room_update(room["id"])
	
	PlayerRegistry.remove_peer(peer_id)

# ===== HANDLERS DE JOGADOR =====

func _handle_register_player(peer_id: int, player_name: String):
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
	
	var validation_result = _validate_player_name(player_name)
	if validation_result != "":
		_log_debug("✗ Nome rejeitado: " + validation_result)
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
	
	var success = PlayerRegistry.register_player(peer_id, player_name)
	
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		NetworkManager.rpc_id(peer_id, "_client_name_accepted", player_name)
	else:
		_log_debug("✗ Falha ao registrar jogador")
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")

func _validate_player_name(player_name: String) -> String:
	var trimmed_name = player_name.strip_edges()
	
	if trimmed_name.is_empty():
		return "O nome não pode estar vazio"
	
	if trimmed_name.length() < 3:
		return "O nome deve ter pelo menos 3 caracteres"
	
	if trimmed_name.length() > 20:
		return "O nome deve ter no máximo 20 caracteres"
	
	var regex = RegEx.new()
	regex.compile("^[a-zA-Z0-9_ ]+$")
	if not regex.search(trimmed_name):
		return "O nome só pode conter letras, números, espaços e underscores"
	
	if PlayerRegistry.is_name_taken(trimmed_name):
		return "Este nome já está sendo usado"
	
	return ""

# ===== HANDLERS DE SALAS =====

func _handle_request_rooms_list(peer_id: int):
	_log_debug("Cliente %d solicitou lista de salas" % peer_id)
	
	if not PlayerRegistry.is_player_registered(peer_id):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	var rooms = RoomRegistry.get_rooms_list()
	_log_debug("Enviando %d salas para o cliente" % rooms.size())
	
	NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list", rooms)

func _handle_create_room(peer_id: int, room_name: String, password: String):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Criando sala '%s' para jogador %s (ID: %d)" % [room_name, player["name"], peer_id])
	
	var validation = _validate_room_name(room_name)
	if validation != "":
		_send_error(peer_id, validation)
		return
	
	if RoomRegistry.room_name_exists(room_name):
		_send_error(peer_id, "Já existe uma sala com este nome")
		return
	
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala")
		return
	
	var room_id = next_room_id
	next_room_id += 1
	
	var room_data = RoomRegistry.create_room(room_id, room_name, password, peer_id)
	
	_log_debug("✓ Sala criada: %s (ID: %d, Host: %s)" % [room_name, room_id, player["name"]])
	_send_rooms_list_to_all()
	
	NetworkManager.rpc_id(peer_id, "_client_room_created", room_data)

func _validate_room_name(room_name: String) -> String:
	var trimmed = room_name.strip_edges()
	
	if trimmed.is_empty():
		return "O nome da sala não pode estar vazio"
	
	if trimmed.length() < 3:
		return "O nome da sala deve ter pelo menos 3 caracteres"
	
	if trimmed.length() > 30:
		return "O nome da sala deve ter no máximo 30 caracteres"
	
	return ""

func _handle_join_room(peer_id: int, room_id: int, password: String):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala ID: %d" % [player["name"], peer_id, room_id])
	
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	var room = RoomRegistry.get_room(room_id)
	if room.is_empty():
		_send_error(peer_id, "Sala não encontrada")
		return
	
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	var success = RoomRegistry.add_player_to_room(room_id, peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	var room_data = RoomRegistry.get_room(room_id)
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	_notify_room_update(room_id)

func _handle_join_room_by_name(peer_id: int, room_name: String, password: String):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala: '%s'" % [player["name"], peer_id, room_name])
	
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	var room = RoomRegistry.get_room_by_name(room_name)
	if room.is_empty():
		NetworkManager.rpc_id(peer_id, "_client_room_not_found")
		return
	
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	var success = RoomRegistry.add_player_to_room(room["id"], peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	var room_data = RoomRegistry.get_room(room["id"])
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	_notify_room_update(room["id"])

func _handle_leave_room(peer_id: int):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		return
	
	_log_debug("Jogador %s saiu da sala: %s" % [player["name"], room["name"]])
	RoomRegistry.remove_player_from_room(room["id"], peer_id)
	
	_notify_room_update(room["id"])

func _handle_close_room(peer_id: int):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		return
	
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode fechar a sala")
		return
	
	_log_debug("Host %s fechou a sala: %s" % [player["name"], room["name"]])
	
	for room_player in room["players"]:
		if room_player["id"] != peer_id:
			NetworkManager.rpc_id(room_player["id"], "_client_room_closed", "O host fechou a sala")
	
	RoomRegistry.remove_room(room["id"])
	_send_rooms_list_to_all()

# ===== HANDLER DE INÍCIO DE PARTIDA =====

func _handle_start_match(peer_id: int, match_settings: Dictionary):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		_send_error(peer_id, "Você não está em nenhuma sala")
		return
	
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode iniciar a partida")
		return
	
	if not RoomRegistry.can_start_match(room["id"]):
		var reqs = RoomRegistry.get_match_requirements(room["id"])
		_send_error(peer_id, "Requisitos não atendidos: %d/%d jogadores (mínimo: %d)" % [
			reqs["current_players"],
			reqs["max_players"],
			reqs["min_players"]
		])
		return
	
	_log_debug("========================================")
	_log_debug("HOST INICIANDO PARTIDA")
	_log_debug("Sala: %s (ID: %d)" % [room["name"], room["id"]])
	_log_debug("Jogadores participantes:")
	
	for room_player in room["players"]:
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %d)%s" % [room_player["name"], room_player["id"], is_host_mark])
	
	_log_debug("========================================")
	
	# Define mapa (pode vir das configurações ou usar padrão)
	var map_scene = match_settings.get("map_scene", "res://scenes/system/WorldGenerator.tscn")
	
	# Cria partida no PartyRegistry do servidor
	var party_data = PartyRegistry.create_party(room["id"], map_scene, match_settings)
	PartyRegistry.set_players(room["players"])
	
	# Atualiza estado da sala
	RoomRegistry.set_room_in_game(room["id"], true)
	
	# Gera dados de spawn para cada jogador
	var spawn_data = {}
	for i in range(room["players"].size()):
		var p = room["players"][i]
		spawn_data[p["id"]] = {
			"spawn_index": i,
			"team": 0
		}
	
	# Prepara dados para enviar aos clientes
	var match_data = {
		"party_id": party_data["party_id"],
		"room_id": room["id"],
		"map_scene": map_scene,
		"settings": match_settings,
		"players": room["players"],
		"spawn_data": spawn_data
	}
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room["players"]:
		NetworkManager.rpc_id(room_player["id"], "_client_match_started", match_data)
	
	# Instancia mapa e players no servidor também
	_server_instantiate_match(match_data)

# ===== INSTANCIAÇÃO NO SERVIDOR =====

func _server_instantiate_match(match_data: Dictionary):
	_log_debug("Instanciando partida no servidor...")
	
	# Cria MapManager
	server_map_manager = preload("res://scripts/gameplay/MapManager.gd").new()
	get_tree().root.add_child(server_map_manager)
	
	# Carrega o mapa
	await server_map_manager.load_map(match_data["map_scene"], match_data["settings"])
	
	PartyRegistry.map_manager = server_map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
	
	# Inicia a rodada
	PartyRegistry.start_round()
	
	_log_debug("✓ Partida instanciada no servidor")

# ===== FIM DE RODADA E PARTIDA =====

func end_current_round(winner_data: Dictionary = {}):
	var party = PartyRegistry.current_party
	if party.is_empty():
		return
	
	_log_debug("Finalizando rodada %d" % party["round_number"])
	
	var end_data = PartyRegistry.end_round(winner_data)
	end_data["next_round_in"] = 5.0
	
	# Notifica todos os clientes
	for player in party["players"]:
		NetworkManager.rpc_id(player["id"], "_client_round_ended", end_data)
	
	# Limpa objetos da partida
	_cleanup_match_objects()
	
	# Aguarda e decide próxima ação
	await get_tree().create_timer(5.0).timeout
	
	if not PartyRegistry.is_last_round():
		_start_next_round(party["players"])
	else:
		_end_party(party["players"], party["room_id"])

func _start_next_round(players: Array):
	if not PartyRegistry.next_round():
		return
	
	_log_debug("Iniciando próxima rodada...")
	
	# Notifica clientes
	for player in players:
		NetworkManager.rpc_id(player["id"], "_client_next_round_starting", PartyRegistry.get_current_round())
	
	# Recarrega mapa e spawna players novamente
	var party = PartyRegistry.current_party
	var match_data = {
		"map_scene": party["map_scene"],
		"settings": party["settings"],
		"players": players,
		"spawn_data": {}
	}
	
	for i in range(players.size()):
		match_data["spawn_data"][players[i]["id"]] = {"spawn_index": i, "team": 0}
	
	_server_instantiate_match(match_data)

func _end_party(players: Array, room_id: int):
	_log_debug("Encerrando partida completamente")
	
	# Notifica clientes
	for player in players:
		NetworkManager.rpc_id(player["id"], "_client_party_ended")
	
	# Limpa tudo
	_cleanup_match_objects()
	PartyRegistry.end_party()
	
	# Volta sala ao estado normal
	RoomRegistry.set_room_in_game(room_id, false)

func _cleanup_match_objects():
	_log_debug("Limpando objetos da partida...")
	
	# Remove players
	for child in get_tree().root.get_children():
		if child.is_in_group("player"):
			child.queue_free()
	
	# Remove mapa
	if server_map_manager:
		server_map_manager.unload_map()
		server_map_manager.queue_free()
		server_map_manager = null
	
	# Limpa objetos spawnados
	ObjectSpawner.cleanup()
	
	_log_debug("✓ Limpeza completa")

# ===== UTILITÁRIOS =====

func _send_rooms_list_to_all():
	var all_rooms = RoomRegistry.get_rooms_list()
	for peer_id in multiplayer.get_peers():
		if peer_id != 1:
			NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list_update", all_rooms)

func _notify_room_update(room_id: int):
	var room = RoomRegistry.get_room(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		NetworkManager.rpc_id(player["id"], "_client_room_updated", room)

func _send_error(peer_id: int, message: String):
	_log_debug("Enviando erro para cliente %d: %s" % [peer_id, message])
	NetworkManager.rpc_id(peer_id, "_client_error", message)

func _log_debug(message: String):
	if debug_mode:
		print("[ServerManager] " + message)
