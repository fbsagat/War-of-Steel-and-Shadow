extends Node
## GameManager - Gerenciador principal do jogo multiplayer (CLIENTE)
## Responsável por conectar ao servidor dedicado e gerenciar o fluxo do jogo

# ===== CONFIGURAÇÕES (Editáveis no Inspector) =====

@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var connection_timeout: float = 10.0
@export var debug_mode: bool = false

# ===== VARIÁVEIS INTERNAS =====

var main_menu: Control = null
var is_connected_to_server: bool = false
var local_peer_id: int = 0
var player_name: String = ""
var current_room: Dictionary = {}
var connection_start_time: float = 0.0
var is_connecting: bool = false

## Referências da partida atual
var client_map_manager: Node = null
var local_player: Node = null

# ===== SINAIS =====

signal connected_to_server()
signal connection_failed(reason: String)
signal disconnected_from_server()
signal rooms_list_received(rooms: Array)
signal joined_room(room_data: Dictionary)
signal room_created(room_data: Dictionary)
signal error_occurred(error_message: String)
signal name_accepted()
signal name_rejected(reason: String)
signal room_updated(room_data: Dictionary)
signal match_started()
signal round_ended(end_data: Dictionary)
signal party_ended()

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_log_debug("GameManager detectou modo servidor - não inicializando cliente")
		return
	
	_log_debug("GameManager inicializado (Cliente)")
	
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(delta):
	if is_connecting:
		if Time.get_ticks_msec() / 1000.0 - connection_start_time > connection_timeout:
			_log_debug("Timeout de conexão excedido")
			is_connecting = false
			_handle_connection_error("Tempo de conexão esgotado")

# ===== CONEXÃO COM O SERVIDOR =====

func connect_to_server():
	if is_connected_to_server:
		_log_debug("Já conectado ao servidor")
		return
	
	if is_connecting:
		_log_debug("Já está tentando conectar")
		return
	
	_log_debug("Tentando conectar ao servidor: %s:%d" % [server_address, server_port])
	
	if main_menu:
		main_menu.show_loading_menu("Conectando ao servidor...")
	
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(server_address, server_port)
	
	if error != OK:
		_log_debug("Erro ao criar cliente: " + str(error))
		_handle_connection_error("Falha ao criar conexão com o servidor")
		return
	
	multiplayer.multiplayer_peer = peer
	is_connecting = true
	connection_start_time = Time.get_ticks_msec() / 1000.0
	_log_debug("Cliente criado, aguardando conexão...")

func disconnect_from_server():
	if multiplayer.multiplayer_peer:
		_log_debug("Desconectando do servidor...")
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	
	is_connected_to_server = false
	is_connecting = false
	local_peer_id = 0
	current_room = {}
	player_name = ""
	
	disconnected_from_server.emit()

# ===== CALLBACKS DE CONEXÃO =====

func _on_connected_to_server():
	is_connecting = false
	is_connected_to_server = true
	local_peer_id = multiplayer.get_unique_id()
	
	_log_debug("✓ Conectado ao servidor com sucesso! Peer ID: %d" % local_peer_id)
	
	if main_menu:
		main_menu.show_name_input_menu()
	
	connected_to_server.emit()

func _on_connection_failed():
	is_connecting = false
	_log_debug("✗ Falha ao conectar ao servidor")
	_handle_connection_error("Não foi possível conectar ao servidor")

func _on_server_disconnected():
	_log_debug("✗ Desconectado do servidor")
	is_connected_to_server = false
	local_peer_id = 0
	current_room = {}
	player_name = ""
	
	if main_menu:
		main_menu.show_connecting_menu()
		main_menu.show_error_connecting("Conexão perdida. Tentando reconectar...")
	
	disconnected_from_server.emit()
	
	await get_tree().create_timer(3.0).timeout
	if not is_connected_to_server:
		connect_to_server()

func _handle_connection_error(message: String):
	if main_menu:
		main_menu.show_connecting_menu()
		main_menu.show_error_connecting(message)
	
	connection_failed.emit(message)

# ===== REGISTRO DE JOGADOR =====

func set_player_name(p_name: String):
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	_log_debug("Tentando registrar nome: " + p_name)
	
	if main_menu:
		main_menu.show_loading_menu("Registrando jogador...")
	
	NetworkManager.register_player(p_name)

func _client_name_accepted(accepted_name: String):
	player_name = accepted_name
	_log_debug("✓ Nome aceito pelo servidor: " + player_name)
	
	if main_menu:
		main_menu.show_main_menu()
		main_menu.update_name_e_connected(accepted_name)
	
	name_accepted.emit()

func _client_wrong_password():
	if main_menu:
		main_menu.show_match_list_menu()
		main_menu.match_password_container.visible = true
		_show_error("Senha incorreta")

func _client_room_not_found():
	if main_menu:
		main_menu.show_match_list_menu()
		main_menu.match_password_container.visible = true
		_show_error("Sala não encontrada")

func _client_name_rejected(reason: String):
	_log_debug("✗ Nome rejeitado: " + reason)
	
	if main_menu:
		main_menu.show_name_input_menu()
		main_menu.show_error_name_input(reason)
	
	name_rejected.emit(reason)

# ===== GERENCIAMENTO DE SALAS =====

func request_rooms_list():
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	if player_name.is_empty():
		_show_error("Nome do jogador não definido")
		return
	
	_log_debug("Solicitando lista de salas...")
	
	if main_menu:
		main_menu.show_loading_menu("Buscando salas disponíveis...")
	
	NetworkManager.request_rooms_list()

func _client_receive_rooms_list(rooms: Array):
	_log_debug("Lista de salas recebida: %d salas" % rooms.size())
	
	if main_menu:
		main_menu.hide_loading_menu(true)
		main_menu.populate_match_list(rooms)
	
	rooms_list_received.emit(rooms)

func _client_receive_rooms_list_update(rooms: Array):
	_log_debug("Lista de salas recebida: %d salas, só update" % rooms.size())
	rooms_list_received.emit(rooms)

func create_room(room_name: String, password: String = ""):
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	if player_name.is_empty():
		_show_error("Nome do jogador não definido")
		return
	
	_log_debug("Criando sala: '%s' (Senha: %s)" % [room_name, "Sim" if password else "Não"])
	
	if main_menu:
		main_menu.show_loading_menu("Criando sala...")
	
	NetworkManager.create_room(room_name, password)

func _client_room_created(room_data: Dictionary):
	current_room = room_data
	_log_debug("✓ Sala criada com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu:
		main_menu.show_room_menu(room_data)
	
	room_created.emit(room_data)

func join_room(room_id: int, password: String = ""):
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	if player_name.is_empty():
		_show_error("Nome do jogador não definido")
		return
	
	_log_debug("Tentando entrar na sala ID: %d" % room_id)
	
	if main_menu:
		main_menu.show_loading_menu("Entrando na sala...")
	
	NetworkManager.join_room(room_id, password)

func join_room_by_name(room_name: String, password: String = ""):
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	if player_name.is_empty():
		_show_error("Nome do jogador não definido")
		return
	
	_log_debug("Tentando entrar na sala: '%s'" % room_name)
	
	if main_menu:
		main_menu.show_loading_menu("Procurando sala...")
	
	NetworkManager.join_room_by_name(room_name, password)

func _client_joined_room(room_data: Dictionary):
	current_room = room_data
	_log_debug("✓ Entrou na sala com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu:
		main_menu.show_room_menu(room_data)
	
	joined_room.emit(room_data)

func _client_room_updated(room_data: Dictionary):
	current_room = room_data
	_log_debug("Sala atualizada: %s (%d jogadores)" % [room_data["name"], room_data["players"].size()])
	
	if main_menu:
		main_menu.update_room_info(room_data)
	
	room_updated.emit(room_data)

func leave_room():
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	_log_debug("Saindo da sala: %s" % current_room["name"])
	NetworkManager.leave_room()
	current_room = {}
	
	if main_menu:
		main_menu.show_main_menu()

func close_room():
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_id"] != local_peer_id:
		_show_error("Apenas o host pode fechar a sala")
		return
	
	_log_debug("Fechando sala: %s" % current_room["name"])
	NetworkManager.close_room()
	current_room = {}
	
	if main_menu:
		main_menu.show_main_menu()

func start_match(match_settings: Dictionary = {}):
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_id"] != local_peer_id:
		_show_error("Apenas o host pode iniciar a partida")
		return
	
	var min_p: int = RoomRegistry.min_players_to_start
	if current_room.players.size() < min_p:
		_show_error("Pelo menos %d jogadores são necessários para iniciar uma partida" % min_p)
		return
	
	_log_debug("Solicitando início da partida...")
	NetworkManager.start_match(match_settings)

func _client_room_closed(reason: String):
	_log_debug("Sala fechada: " + reason)
	current_room = {}
	
	if main_menu:
		main_menu.show_main_menu()
		_show_error(reason)

# ===== INÍCIO DA PARTIDA =====

func _client_match_started(match_data: Dictionary):
	_log_debug("✓ Partida iniciada pelo servidor!")
	_start_match(match_data)

func _start_match(match_data: Dictionary):
	_log_debug("========================================")
	_log_debug("INICIANDO PARTIDA")
	_log_debug("Sala: ID %d" % match_data["room_id"])
	_log_debug("Mapa: %s" % match_data["map_scene"])
	_log_debug("Jogadores participantes:")
	
	for player in match_data["players"]:
		var is_host = " [HOST]" if player["is_host"] else ""
		var is_me = " [VOCÊ]" if player["id"] == local_peer_id else ""
		_log_debug("  - %s (ID: %d)%s%s" % [player["name"], player["id"], is_host, is_me])
	
	_log_debug("========================================")
	
	# Cria partida no PartyRegistry local
	PartyRegistry.create_party(
		match_data["room_id"],
		match_data["map_scene"],
		match_data["settings"]
	)
	PartyRegistry.set_players(match_data["players"])
	
	# Esconde o menu
	if main_menu:
		main_menu.hide()
		main_menu.get_node("CanvasLayer").hide()
	
	# Instancia MapManager
	client_map_manager = preload("res://scripts/gameplay/MapManager.gd").new()
	get_tree().root.add_child(client_map_manager)
	
	# Carrega o mapa
	await client_map_manager.load_map(match_data["map_scene"], match_data["settings"])
	
	PartyRegistry.map_manager = client_map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		var is_local = player_data["id"] == local_peer_id
		_spawn_player(player_data, spawn_data, is_local)
	
	# Inicia rodada
	PartyRegistry.start_round()
	
	match_started.emit()
	
	_log_debug("✓ Partida carregada no cliente")

func _spawn_player(player_data: Dictionary, spawn_data: Dictionary, is_local: bool):
	var player_scene = preload("res://scenes/system/player.tscn")
	var player_instance = player_scene.instantiate()

	var camera_scene = preload("res://scenes/system/camera_controller.tscn")
	var camera_instance = camera_scene.instantiate()
	
	var sky_scene = preload("res://sky/sky_3d.tscn")
	var sky_instance = sky_scene.instantiate()

	player_instance.name = str(player_data["id"])
	player_instance.player_id = player_data["id"]
	player_instance.player_name = player_data["name"]

	# Atribui target **antes** de adicionar à árvore
	camera_instance.target = player_instance
	camera_instance.name = "CameraController"
	camera_instance.add_to_group("camera_controller")

	get_tree().root.add_child(player_instance)
	get_tree().root.add_child(camera_instance)
	get_tree().root.add_child(sky_instance)
	
	var spawn_pos = client_map_manager.get_spawn_position(spawn_data["spawn_index"])
	player_instance.initialize(player_data["id"], player_data["name"], spawn_pos)
	
	if is_local:
		player_instance.set_as_local_player()
		local_player = player_instance
		_log_debug("✓ Jogador local spawnado")
	
	_log_debug("Player spawnado: %s (ID: %d, Local: %s)" % [player_data["name"], player_data["id"], is_local])

# ===== FIM DE RODADA E PARTIDA =====

func _client_round_ended(end_data: Dictionary):
	_log_debug("========================================")
	_log_debug("RODADA FINALIZADA")
	_log_debug("Rodada: %d" % end_data["round_number"])
	
	if end_data.has("winner") and not end_data["winner"].is_empty():
		_log_debug("Vencedor: %s (Score: %d)" % [end_data["winner"]["name"], end_data["winner"]["score"]])
	
	_log_debug("Scores:")
	for peer_id in end_data["scores"]:
		_log_debug("  Peer %d: %d pontos" % [peer_id, end_data["scores"][peer_id]])
	
	_log_debug("========================================")
	
	# Atualiza PartyRegistry local
	PartyRegistry.end_round(end_data.get("winner", {}))
	
	# Mostrar UI de fim de rodada (se tiver)
	if main_menu:
		main_menu.show_round_end_screen(end_data)
	
	# Limpa objetos locais
	_cleanup_local_match()
	
	round_ended.emit(end_data)

func _client_next_round_starting(round_number: int):
	_log_debug("Próxima rodada iniciando: %d" % round_number)
	
	# A partida será recarregada automaticamente via _client_match_started
	# ou você pode implementar lógica específica aqui

func _client_party_ended():
	_log_debug("========================================")
	_log_debug("PARTIDA ENCERRADA")
	_log_debug("========================================")
	
	# Limpa tudo
	_cleanup_local_match()
	
	# Volta para o menu da sala
	if main_menu:
		main_menu.show()
		main_menu.get_node("CanvasLayer").show()
		main_menu.show_room_menu(current_room)
	
	party_ended.emit()

func _cleanup_local_match():
	_log_debug("Limpando objetos da partida...")
	
	# Remove players
	for child in get_tree().root.get_children():
		if child.is_in_group("player"):
			child.queue_free()
	
	local_player = null
	
	# Remove mapa
	if client_map_manager:
		client_map_manager.unload_map()
		client_map_manager.queue_free()
		client_map_manager = null
	
	# Limpa ObjectSpawner
	ObjectSpawner.cleanup()
	
	# Limpa PartyRegistry (se não for continuar jogando)
	if not PartyRegistry.is_party_active():
		PartyRegistry.end_party()
	
	_log_debug("✓ Limpeza completa")

# ===== TRATAMENTO DE ERROS =====

func _client_error(error_message: String):
	_log_debug("✗ Erro recebido do servidor: " + error_message)
	_show_error(error_message)
	error_occurred.emit(error_message)

func _show_error(message: String):
	_log_debug("ERRO: " + message)
	
	if main_menu:
		if main_menu.connecting_menu and main_menu.connecting_menu.visible:
			main_menu.show_error_connecting(message)
		elif main_menu.room_menu and main_menu.room_menu.visible:
			main_menu.show_error_room(message)
		elif main_menu.match_list_menu and main_menu.match_list_menu.visible:
			main_menu.show_error_match_list(message)
		elif main_menu.manual_join_menu and main_menu.manual_join_menu.visible:
			main_menu.show_error_manual_join(message)
		elif main_menu.create_match_menu and main_menu.create_match_menu.visible:
			main_menu.show_error_create_match(message)

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[GameManager] " + message)

func set_main_menu(menu: Control):
	main_menu = menu
	_log_debug("UI principal registrada")
