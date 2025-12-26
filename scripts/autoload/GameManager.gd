extends Node
## GameManager - Gerenciador principal do jogo multiplayer (CLIENTE)
## Responsável por conectar ao servidor dedicado e gerenciar o fluxo do jogo

# ===== CONFIGURAÇÕES (Editáveis no Inspector) =====

@export_category("Connection Settings")
@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777
@export var connection_timeout: float = 10.0

const map_scene : String = "res://scenes/system/terrain_3d.tscn"
const player_scene : String = "res://scenes/system/player_warrior.tscn"
const camera_controller : String = "res://scenes/system/camera_controller.tscn"

@export_category("Physics Settings")
@export var drop_impulse_strength: float = 2.0
@export var drop_impulse_variance: float = 1.0

@export_category("Debug")
@export var debug_mode: bool = true

@export_category("Player")
@export var inventory : Control

# ===== REGISTROS =====

var item_database: ItemDatabase = null

# ===== VARIÁVEIS INTERNAS =====

var main_menu: Control = null
var is_connected_to_server: bool = false
var local_peer_id: int = 0
var player_name: String = ""
var configs: Dictionary = {}
var current_room: Dictionary = {}
var current_round: Dictionary = {}
var connection_start_time: float = 0.0
var is_connecting: bool = false
var _is_server: bool = false
var cached_unique_id: int = 0
## Objetos spawnados organizados por rodada
## {round_id: {object_id: {node: Node, item_name: String, owner_id: int}}}
var spawned_objects: Dictionary = {}
var local_inventory: Dictionary = {} # Inventário(de itens e equipamentos) local do player.

## Referências da rodada atual
var client_map_manager: Node = null
var local_player: Node = null
var is_in_round: bool = false
var round_node: Node = null
var players_node: Node = null
var objects_node: Node = null

# ===== VARIÁVEIS DE RECONEXÃO =====
var reconnect_attempts: int = 0
var max_reconnect_attempts: int = 5  # Tentativas máximas antes do reset
var reconnect_delay: float = 2.0    # Segundos entre tentativas
var reconnect_start_time: float = 0.0
var max_reconnect_duration: float = 15.0  # Tempo máximo total para reconexão
var is_reconnecting: bool = false
var reconnect_timer: Timer = null
var is_disconnecting_intentionally = false

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
signal round_started()
signal round_ended(end_data: Dictionary)
signal returned_to_room(room_data: Dictionary)
signal item_added(object_id: String, item_name: String, item_type: String, slot_id: String, icon_path: String)
signal item_removed(item_id: String)
signal item_equipped(item_id: String, slot_type: String)
signal item_unequipped(item_id: String, target_inventory_slot: int)
signal items_swapped(item_id_1: String, item_id_2: String)

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():	# Verifica se é servidor
	var args = OS.get_cmdline_args()
	_is_server = "--server" in args
	
	if _is_server:
		print("[SERVER][GameManager]Servidor - NÃO inicializando GameManager")
		return
	
	item_database = NetworkManager.item_database
	
	# Configuração do timer de reconexão (só para clientes)
	reconnect_timer = Timer.new()
	add_child(reconnect_timer)
	reconnect_timer.one_shot = true
	reconnect_timer.timeout.connect(_attempt_reconnection)
		
	_log_debug("Inicializando GameManager como cliente")
	
	# Conecta sinais de rede
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
func _process(_delta):
	"""Verifica timeout de conexão"""
	if is_connecting:
		if Time.get_ticks_msec() / 1000.0 - connection_start_time > connection_timeout:
			_log_debug("Timeout de conexão excedido")
			is_connecting = false
			_handle_connection_error("Tempo de conexão esgotado")
			
	# Interrompe reconexão se usuário cancelar
	if is_reconnecting and Input.is_action_just_pressed("ui_cancel"):
		_reset_client_state()
		is_reconnecting = false

# ===== CONEXÃO COM O SERVIDOR =====

func connect_to_server():
	"""Conecta ao servidor dedicado"""
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
	"""Desconecta do servidor"""
	# Marca desconexão intencional
	is_disconnecting_intentionally = true
	
	if multiplayer.multiplayer_peer:
		_log_debug("Desconectando do servidor...")
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	
	is_connected_to_server = false
	is_connecting = false
	local_peer_id = 0
	current_room = {}
	player_name = ""
	is_in_round = false
	
	disconnected_from_server.emit()

# ===== CALLBACKS DE CONEXÃO =====

func _on_connected_to_server():
	"""Callback quando conecta com sucesso ao servidor"""
	# Só leia get_unique_id() quando o peer estiver ativo
	if verificar_rede():
		# garante que o peer foi realmente configurado
		if multiplayer.has_multiplayer_peer():
			cached_unique_id = multiplayer.get_unique_id()
	
	is_connecting = false
	is_connected_to_server = true
	local_peer_id = multiplayer.get_unique_id()
	
	_log_debug(" Cliente conectado ao servidor com sucesso! Peer ID: %d" % local_peer_id)
	
	if main_menu:
		main_menu.show_name_input_menu()
	
	connected_to_server.emit()

func _on_connection_failed():
	is_connecting = false
	_log_debug("Falha ao conectar ao servidor")
	
	# Não mostra erro durante reconexão automática
	if not is_reconnecting:
		_handle_connection_error("Não foi possível conectar ao servidor")

func _on_server_disconnected():
	_log_debug("Desconectado do servidor")
	
	is_connected_to_server = false
	is_in_round = false

	# Inicia processo de reconexão
	if main_menu:
		main_menu.show_connecting_menu()
		main_menu.show_error_connecting("Conexão perdida. Tentando reconectar...")
	
	disconnected_from_server.emit()
	_start_reconnection_process()
	
func _start_reconnection_process():
	# Reseta contadores de reconexão
	reconnect_attempts = 0
	reconnect_start_time = Time.get_ticks_msec() / 1000.0
	is_reconnecting = true
	
	_log_debug("Iniciando processo de reconexão")
	_attempt_reconnection()

func _attempt_reconnection():
	# Verifica limite de tempo total
	# Adicionar um botão "Cancelar" nesta tela de reconexão?
	
	var current_time = Time.get_ticks_msec() / 1000.0
	if (current_time - reconnect_start_time) > max_reconnect_duration:
		_log_debug("Limite de tempo de reconexão excedido. Resetando estado.")
		_reset_client_state()
		return

	# Verifica limite de tentativas
	if reconnect_attempts >= max_reconnect_attempts:
		_log_debug("Máximo de tentativas de reconexão excedido. Resetando estado.")
		_reset_client_state()
		return

	reconnect_attempts += 1
	_log_debug("Tentativa de reconexão #%d" % reconnect_attempts)
	
	if main_menu:
		main_menu.show_loading_menu("Tentando reconectar (%d/%d)..." % [reconnect_attempts, max_reconnect_attempts])
	
	connect_to_server()
	
	# Agenda próxima tentativa se falhar
	await get_tree().create_timer(connection_timeout + 0.5).timeout
	if not is_connected_to_server and is_reconnecting:
		reconnect_timer.start(reconnect_delay)

func _reset_client_state():
	# Interrompe processos de reconexão
	is_reconnecting = false
	if reconnect_timer:
		reconnect_timer.stop()
	
	# Limpa todos os objetos spawnados
	for round_id in spawned_objects.keys():
		for object_data in spawned_objects[round_id].values():
			if object_data.node and object_data.node.is_inside_tree():
				object_data.node.queue_free()
	spawned_objects.clear()
	
	# Limpa a partida(round) totalmente
	round_node.queue_free()
	
	# Reset completo do estado
	is_connected_to_server = false
	is_connecting = false
	local_peer_id = 0
	player_name = ""
	configs = {}
	current_room = {}
	current_round = {}
	client_map_manager = null
	local_player = null
	is_in_round = false
	reconnect_attempts = 0
	
	# Volta para tela inicial de conexão
	if main_menu:
		main_menu.show_loading_menu("Conectando ao servidor...")
	
	# Tenta nova conexão após pequeno delay
	await get_tree().create_timer(1.0).timeout
	reconnect_start_time = Time.get_ticks_msec() / 1000.0
	connect_to_server()
	
func _handle_connection_error(message: String):
	"""Trata erro de conexão"""
	if main_menu:
		main_menu.show_connecting_menu()
		main_menu.show_error_connecting(message)
	
	connection_failed.emit(message)
	
func update_client_info(info: Dictionary):
	_log_debug("Atualizando configurações do servidor:")
	
	for key in info.keys():
		var new_value = info[key]
		
		# Se não existe ou se mudou, atualiza
		if not configs.has(key) or configs[key] != new_value:
			configs[key] = new_value
			_log_debug("[UPDATED] %s: %s" % [str(key), str(new_value)])


# ===== REGISTRO DE JOGADOR =====

func set_player_name(p_name: String):
	"""Envia nome do jogador para registro no servidor"""
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	_log_debug("Tentando registrar nome: " + p_name)
	
	if main_menu:
		main_menu.show_loading_menu("Registrando jogador...")
	
	NetworkManager.register_player(p_name)

func _client_name_accepted(accepted_name: String):
	"""Callback quando o nome é aceito pelo servidor"""
	player_name = accepted_name
	_log_debug("Nome aceito pelo servidor: " + player_name)
	
	if main_menu:
		main_menu.show_main_menu()
		main_menu.update_name_e_connected(accepted_name)
	
	name_accepted.emit()

func _client_name_rejected(reason: String):
	"""Callback quando o nome é rejeitado"""
	_log_debug("Nome rejeitado: " + reason)
	
	if main_menu:
		main_menu.show_name_input_menu()
		main_menu.show_error_name_input(reason)
	
	name_rejected.emit(reason)

func _client_wrong_password():
	"""Callback quando a senha está incorreta"""
	if main_menu:
		main_menu.show_match_list_menu()
		main_menu.match_password_container.visible = true
		_show_error("Senha incorreta")

func _client_room_name_exists():
	"""Callback de quando já existe uma sala com o nome escolhido"""
	if main_menu:
		main_menu.show_create_match_menu()
		_show_error("Já existe uma sala com o nome escolhido")

func _client_room_name_error(error_msg : String):
	"""Callback de quando já existe uma sala com o nome escolhido"""
	if main_menu:
		main_menu.show_create_match_menu()
		_show_error(error_msg)

func _client_room_not_found():
	"""Callback quando a sala não é encontrada"""
	if main_menu:
		main_menu.show_match_list_menu()
		main_menu.match_password_container.visible = true
		_show_error("Sala não encontrada")

# ===== GERENCIAMENTO DE SALAS =====

func request_rooms_list():
	"""Solicita lista de salas disponíveis"""
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
	"""Callback quando recebe lista de salas"""
	_log_debug("Lista de salas recebida: %d salas" % rooms.size())
	
	if main_menu:
		main_menu.hide_loading_menu(true)
		main_menu.populate_match_list(rooms)
	
	rooms_list_received.emit(rooms)

func _client_receive_rooms_list_update(rooms: Array):
	"""Callback quando recebe atualização de lista de salas"""
	_log_debug("Lista de salas atualizada: %d salas" % rooms.size())
	rooms_list_received.emit(rooms)

func create_room(room_name: String, password: String = ""):
	"""Cria uma nova sala"""
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
	"""Callback quando sala é criada com sucesso"""
	current_room = room_data
	_log_debug(" Sala criada com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu:
		main_menu.show_room_menu(room_data)
	
	room_created.emit(room_data)

func join_room(room_id: int, password: String = ""):
	"""Entra em uma sala por ID"""
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
	"""Entra em uma sala por nome"""
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
	"""Callback quando entra em uma sala com sucesso"""
	current_room = room_data
	_log_debug("Entrou na sala com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu:
		main_menu.show_room_menu(room_data)
	
	joined_room.emit(room_data)

func _client_room_updated(room_data: Dictionary):
	"""Callback quando a sala é atualizada"""
	current_room = room_data
	_log_debug("Sala atualizada: %s (%d jogadores)" % [room_data["name"], room_data["players"].size()])
	
	if main_menu:
		main_menu.update_room_info(room_data)
	
	room_updated.emit(room_data)

func leave_room():
	"""Sai da sala atual"""
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	_log_debug("Saindo da sala: %s" % current_room["name"])
	NetworkManager.leave_room()
	current_room = {}
	
	if main_menu:
		main_menu.show_main_menu()

func close_room():
	"""Fecha a sala atual (apenas host)"""
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

func _client_room_closed(reason: String):
	"""Callback quando a sala é fechada"""
	_log_debug("Sala fechada: " + reason)
	current_room = {}
	
	if main_menu:
		main_menu.show_match_list_menu()
		_show_error(reason)
		# Arrumar algum dia

# ===== GERENCIAMENTO DE RODADAS =====

func start_match(match_settings: Dictionary = {}):
	"""Alias para start_round (compatibilidade)"""
	start_round(match_settings)

func start_round(round_settings: Dictionary = {}):
	"""Inicia uma nova rodada (apenas host, que irá solicitar início da rodada)"""
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_id"] != local_peer_id:
		_show_error("Apenas o host pode iniciar a rodada")
		return
	
	if current_room.players.size() < configs.min_players_to_start:
		_show_error("Pelo menos %d jogadores são necessários para iniciar uma rodada" % 1)
		return
	
	_log_debug("Solicitando início da rodada...")
	NetworkManager.start_round(round_settings)
	
func _client_round_started(match_data: Dictionary):
	"""Callback quando a rodada inicia"""
	_log_debug("Rodada iniciada pelo servidor!")
	_start_round_locally(match_data)

func _client_round_ended(end_data: Dictionary):
	"""Callback quando a rodada termina"""
	_log_debug("========================================")
	_log_debug("RODADA FINALIZADA")
	_log_debug("Rodada: %d" % end_data["round_number"])
	_log_debug("Razão: %s" % end_data.get("end_reason", "desconhecida"))
	
	if end_data.has("winner") and not end_data["winner"].is_empty():
		_log_debug("Vencedor: %s (Score: %d)" % [end_data["winner"]["name"], end_data["winner"]["score"]])
	
	_log_debug("Scores:")
	for peer_id in end_data["scores"]:
		_log_debug("Peer %d: %d pontos" % [peer_id, end_data["scores"][peer_id]])
	
	_log_debug("========================================")
	
	# Mostrar UI de fim de rodada (se tiver)
	if main_menu:
		main_menu.show_round_end_screen(end_data)
	
	round_ended.emit(end_data)
	
	# Aguarda um pouco antes de limpar
	await get_tree().create_timer(1.0).timeout
	
	# Limpa objetos locais
	_cleanup_local_round()

func _start_round_locally(match_data: Dictionary):
	"""Inicia a rodada localmente no cliente"""
	_log_debug("========================================")
	_log_debug("INICIANDO RODADA")
	_log_debug("Sala: ID %d" % match_data["room_id"])
	_log_debug("Rodada: ID %d" % match_data["round_id"])
	_log_debug("Mapa: %s" % match_data["map_scene"])
	_log_debug("Jogadores participantes:")
	
	for player in match_data["players"]:
		var is_host = " [HOST]" if player["is_host"] else ""
		var is_me = " [GUEST]" if player["id"] == local_peer_id else ""
		_log_debug("- %s (ID: %d)%s%s" % [player["name"], player["id"], is_host, is_me])
	
	_log_debug("========================================")
	
	is_in_round = true
	
	# Esconde o menu
	if main_menu:
		main_menu.hide()
		main_menu.get_node("CanvasLayer").hide()
	
	# Criar cena de organização do round
	round_node = Node.new()
	round_node.name = "Round"
	
	# Adiciona à raiz
	get_tree().root.add_child(round_node)
	
	# Cria nós organizacionais
	players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	# Instancia MapManager
	client_map_manager = preload("res://scripts/gameplay/MapManager.gd").new()
	get_tree().root.add_child(client_map_manager)
	
	# Carrega o mapa
	await client_map_manager.load_map(match_data["map_scene"], round_node, match_data["settings"])

	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		var is_local = player_data["id"] == local_peer_id
		_spawn_player(player_data, spawn_data, is_local, match_data)
	
	round_started.emit()
	
	# Filtrar uns itens e deixar numa variável(current_round) para uso durante a partida
	# Modifique em filtrar_dict_invertido a lista de itens que devem retornar do dicionário match_data
	var filtered_round_data = filtrar_dict_invertido(match_data)
	current_round = filtered_round_data
	
	_log_debug("Rodada carregada no cliente")

func _spawn_player(player_data: Dictionary, spawn_data: Dictionary, is_local: bool, _match_data: Dictionary):
	"""Spawna players para cada cliente, cada cliente recebe X execuções,
	 a do seu jogador local e a do(s) jogador(es) remoto(s), sendo o seu = local"""
	# Verifica duplicação
	var player_name_ = str(player_data["id"])
	var camera_name = player_name_ + "_Camera"
	
	if players_node.has_node(player_name_):
		_log_debug("⚠ Player já existe: %s" % player_name_)
		return
		
	if players_node.has_node(camera_name):
		_log_debug("⚠ Câmera já existe: %s" % camera_name)
		return

	# Instancia player
	var player_scene_ = preload(player_scene)
	var player_instance = player_scene_.instantiate()
	
	player_instance.name = player_name_
	player_instance.player_id = player_data["id"]
	player_instance.player_name = player_data["name"]
	
	# Adiciona player à cena PRIMEIRO
	players_node.add_child(player_instance)
	
	# Inicializa jogador
	var spawn_info = client_map_manager.get_spawn_data(spawn_data["spawn_index"])
	player_instance.initialize(player_data["id"], player_data["name"], spawn_info["position"])
	player_instance.rotation = spawn_info["rotation"]
	player_instance.setup_name_label()
	
	# Configuração ESPECÍFICA por tipo de jogador
	if is_local:
		# Só instanciar e atribuir câmera para jogador LOCAL
		var camera_scene = preload(camera_controller)
		var camera_instance = camera_scene.instantiate()
		camera_instance.name = camera_name
		camera_instance.target = player_instance
		
		# Inicializa o inventário do player local (no game manager)
		init_player_inventory()
		
		# Carrega o menu de inventário
		var inventory_scene: PackedScene = load("res://scenes/ui/inventory_menu.tscn")
		var inventory_node: Node = inventory_scene.instantiate()
		get_tree().root.add_child(inventory_node)
		inventory = inventory_node
		
		# Atribui referência DIRETA (só para local) inventory_node
		player_instance.inventory = inventory_node
		player_instance.inventory.setup_inventory_signals()
		player_instance.connect_inventory_signals()
		
		# Atribui referência DIRETA (só para local) camera_instance
		player_instance.camera_controller = camera_instance
		
		# Adiciona câmera à cena
		players_node.add_child(camera_instance)
		
		# Ativa controle
		player_instance.set_as_local_player()
		camera_instance.set_as_active()
		local_player = player_instance
		_log_debug("Jogador local spawnado: %s" % player_name_)
	else:
		# Jogador remoto: NÃO tem câmera atribuída
		player_instance.camera_controller = null
		_log_debug("Jogador remoto spawnado: %s" % player_name_)

func _client_return_to_room(room_data: Dictionary):
	"""Callback quando deve retornar à sala"""
	_log_debug("========================================")
	_log_debug("RETORNANDO À SALA")
	_log_debug("Sala: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	_log_debug("========================================")
	
	current_room = room_data
	current_round = {}
	is_in_round = false
	
	# Garante que tudo foi limpo
	_cleanup_local_round()
	
	# Volta para o menu da sala
	if main_menu:
		main_menu.show()
		main_menu.show_room_menu(room_data)
	
	returned_to_room.emit(room_data)
	
	_log_debug(" De volta à sala")

func _client_remove_player(peer_id : int):
	"""Limpa o nó do cliente que se desconectou, esta função é para os outros 
	que estão conectados"""
	if peer_id and players_node and local_peer_id != peer_id:
		var player_node = players_node.get_node_or_null(str(peer_id))
		if player_node:
			player_node.queue_free()

func _cleanup_local_round():
	"""Limpa todos os objetos da rodada no cliente"""
	_log_debug("Limpando objetos da rodada...")
	
	# Remove players
	for child in players_node.get_children():
		if child.is_in_group("player") or child.is_in_group("camera_controller"):
			child.queue_free()
	
	local_player = null
	
	# Limpa objetos spawnados
	for round_id in spawned_objects.keys():
		for object_id in spawned_objects[round_id].keys():
			var obj_data = spawned_objects[round_id][object_id]
			var item_node = obj_data.get("node")
			
			if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
				item_node.queue_free()
	
	spawned_objects.clear()
	
	# Remove mapa
	if client_map_manager:
		client_map_manager.unload_map()
		client_map_manager.queue_free()
		client_map_manager = null
	
	_log_debug("✓ Limpeza completa")

# ===== TRATAMENTO DE ERROS =====

func _client_error(error_message: String):
	"""Callback quando recebe erro do servidor"""
	_log_debug("Erro recebido do servidor: " + error_message)
	_show_error(error_message)
	error_occurred.emit(error_message)

func _show_error(message: String):
	"""Mostra erro na UI apropriada"""
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

# ===== SISTEMA DE INVENTÁRIO POR RODADA =====
	
func init_player_inventory() -> bool:
	"""Inicializa inventário do jogador em uma rodada específica"""
	
	local_inventory = {
		"inventory": [],
		"equipped": {
			"hand-right": {},
			"hand-left": {},
			"head": {},
			"body": {},
			"back": {}
		}
	}
	
	_log_debug("✓ Inventário deste player inicializado")
	return true

func add_item_to_inventory(item_id: String, object_id: int) -> bool:
	"""Adiciona item ao inventário do jogador"""
	
	if local_inventory["inventory"].size() >= 9:
		_log_debug("⚠ Inventário deste player cheio")
		return false
	
	# Valida item no ItemDatabase se disponível
	if item_database and not item_database.item_exists_by_id(int(item_id)):
		push_error("PlayerRegistry: Item inválido: %s" % item_id)
		return false
	
	var item_name = item_database.get_item_by_id(int(item_id))["name"]
	var item_data = {
		"item_id": item_id,
		"object_id": object_id
	}
	
	local_inventory["inventory"].append(item_data)
	
	# Adiciona visualmente no nó do inventário
	var item_type = item_database.get_type(item_name)
	var icon_path = "res://material/collectibles_icons/%s.png" % item_name
	
	item_added.emit(str(object_id), item_name, item_type, icon_path)
	# signal item_added(object_id: String, item_name: String, item_type: String, slot_id: String, icon_path: String)
	
	_log_debug("✓ Item adicionado: %s (ID: %s, Object: %d)" % [item_name, item_id, object_id])

	return true

func remove_item_from_inventory(object_id: int) -> bool:
	"""Remove item do inventário pelo object_id"""
	if local_inventory["inventory"].is_empty():
		return false
	
	var idx = -1
	for i in range(local_inventory["inventory"].size()):
		if local_inventory["inventory"][i]["object_id"] == object_id:
			idx = i
			break
	
	if idx == -1:
		_log_debug("⚠ Item com object_id %d não encontrado no inventário" % object_id)
		return false
	
	var item_id = local_inventory["inventory"][idx]["item_id"]
	var item_name = item_database.get_item_by_id(int(item_id))["name"]
	local_inventory["inventory"].remove_at(idx)
	
	item_removed.emit(str(object_id))
	
	_log_debug("✓ Item removido por object_id: %d (%s)" % [object_id, item_name])
	
	return true

func equip_item(item_name: String, object_id, item_slot: String = "") -> bool:
	"""
	Equipa item em um slot (detecta automaticamente se não especificado)
	Slots válidos: hand-right, hand-left, head, body, back
	"""

	if local_inventory["inventory"].is_empty():
		return false
	
	# Procura o item no inventário
	var item_data: Dictionary = {}
	var item_idx = -1
	for i in range(local_inventory["inventory"].size()):
		if local_inventory["inventory"][i]["object_id"] == object_id:
			item_data = local_inventory["inventory"][i]
			item_idx = i
			break
	
	if item_data.is_empty():
		_log_debug("⚠ Item não está no inventário: %s" % item_name)
		return false
	
	# Detecta slot automaticamente se não especificado
	if item_slot.is_empty():
		if item_database:
			item_slot = item_database.get_slot(item_name)
		if item_slot.is_empty():
			push_error("PlayerRegistry: Não foi possível detectar slot para item: %s" % item_name)
			return false
	
	# Valida slot
	if not local_inventory["equipped"].has(item_slot):
		push_error("PlayerRegistry: Slot inválido: %s" % item_slot)
		return false
	
	# Valida se item pode ser equipado neste slot
	if item_database and not item_database.can_equip_in_slot(item_name, item_slot):
		push_error("PlayerRegistry: Item %s não pode ser equipado em %s" % [item_name, item_slot])
		return false
	
	# Desequipa item atual se houver
	if not local_inventory["equipped"][item_slot].is_empty():
		unequip_item(object_id, item_slot)
	
	# Equipa novo item
	local_inventory["equipped"][item_slot] = item_data
	
	# Remove do inventário
	local_inventory["inventory"].remove_at(item_idx)
	
	# Adiciona visualmente no nó do inventário
	item_equipped.emit(str(object_id), item_slot)
	
	_log_debug("✓ Item equipado: %s em %s" % [item_name, item_slot])
	
	return true

func unequip_item(_object_id: int, item_slot: String) -> bool:
	"""Desequipa item de um slot e retorna ao inventário"""

	if local_inventory.is_empty():
		return false
	
	if not local_inventory["equipped"].has(item_slot):
		push_error("PlayerRegistry: Slot inválido: %s" % item_slot)
		return false
	
	var item_data = local_inventory["equipped"][item_slot]
	if item_data.is_empty():
		return false
	
	# Verifica se há espaço no inventário
	if local_inventory["inventory"].size() >= 9:
		_log_debug("⚠ Inventário cheio, não pode desequipar item")
		return false
	
	var item_name = item_database.get_item_by_id(int(item_data["item_id"]))["name"]
	
	# Adiciona de volta ao inventário
	local_inventory["inventory"].append(item_data)
	
	# Limpa slot
	local_inventory["equipped"][item_slot] = {}
	
	# Remove visualmente no nó do inventário
	item_unequipped.emit(str(_object_id))
	
	_log_debug("✓ Item desequipado: %s de %s" % [item_name, item_slot])
	
	return true
	
func swap_equipped_item(new_item: String, slot: String = "") -> bool:
	"""
	Troca item equipado diretamente (desequipa antigo, equipa novo)
	Útil para trocas rápidas de armas/equipamentos
	"""
	
	if local_inventory.is_empty():
		return false
	
	# Detecta slot se não especificado
	if slot.is_empty():
		if ItemDatabase:
			slot = item_database.get_slot(new_item)
		if slot.is_empty():
			return false
	
	var old_item = local_inventory["equipped"][slot]
	
	# Desequipa item atual (se houver)
	if not old_item.is_empty():
		unequip_item(old_item["item_id"], slot)
	
	# Equipa novo item
	if equip_item(new_item, slot):
		return true
	
	items_swapped.emit(old_item["object_id"], new_item)
	
	return false

func clear_player_inventory():
	"""Limpa inventário do jogador em uma rodada"""
	
	local_inventory.clear()
	_log_debug("✓ Inventário limpo")

# ===== SPAWN DE OBJETOS =====

func _spawn_on_client(object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, owner_id: int):
	"""
	Spawna objeto no cliente (chamado via RPC)
	"""
	
	if multiplayer.is_server():
		return  # Servidor já spawnou na função principal
	
	# Valida ItemDatabase
	if not item_database or not item_database.is_loaded:
		push_error("GameManager[Cliente]: ItemDatabase não disponível")
		return
	
	# Obtém scene_path
	var scene_path = item_database.get_item(item_name)["scene_path"]
	
	if scene_path.is_empty():
		push_error("GameManager[Cliente]: Scene path vazio para '%s'" % item_name)
		return
	
	# Carrega cena
	var item_scene = load(scene_path)
	
	if not item_scene:
		push_error("GameManager[Cliente]: Falha ao carregar: %s" % scene_path)
		return
	
	# Instancia
	var item_node = item_scene.instantiate()
	
	if not item_node:
		push_error("GameManager[Cliente]: Falha ao instanciar")
		return
	
	# ✅ CORRIGIDO: Nome consistente com servidor
	item_node.name = "Object_%d_%s_%d" % [object_id, item_name, round_id]
	_log_debug("[ITEM]📦 Spawnando no cliente: %s - %s" % [owner_id, item_node.name])
	
	# Adiciona à árvore
	var round_scene = get_tree().root.get_node_or_null("Round")
	if round_scene:
		var obj_scene = round_scene.get_node_or_null("Objects")
		if obj_scene:
			obj_scene.add_child(item_node, true)
		else:
			push_error("Objects node not found in Round!")
	else:
		push_error("Round node not found!")
	
	await get_tree().process_frame
	
	# Configura transformação
	if item_node is Node3D:
		item_node.global_position = position
		item_node.global_rotation = rotation
	
	# Inicializa item
	if item_node.has_method("initialize"):
		var item_full_data = item_database.get_item_full_info(item_name)
		var drop_velocity = _calculate_drop_impulse(rotation)
		item_node.initialize(object_id, round_id, item_name, item_full_data, owner_id, drop_velocity)
	
	# ✅ CORRIGIDO: Registra com estrutura correta
	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}
	
	spawned_objects[round_id][object_id] = {
		"node": item_node,
		"item_name": item_name,
		"owner_id": owner_id,
		"spawn_time": Time.get_unix_time_from_system()
	}
	
	# ✅ REGISTRA NO NETWORKMANAGER (cliente-side)
	if item_node.has_method("get_sync_config") and item_node.sync_enabled:
		NetworkManager.register_syncable_object(
			object_id,
			item_node,
			item_node.get_sync_config()
		)
	
	# Armazena localmente (se necessário)
	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}
	spawned_objects[round_id][object_id] = {"node": item_node}
	
	_log_debug("✓ Objeto spawnado no cliente: Obj_ID=%d, Item=%s" % [object_id, item_name])

func _despawn_on_client(object_id: int, round_id: int):
	"""
	✅ NOVO MÉTODO: Despawna objeto no cliente
	Chamado via RPC pelo servidor
	"""
	
	if multiplayer.is_server():
		return
	
	_log_debug("🗑️  Despawnando objeto: ID=%d, Round=%d" % [object_id, round_id])
	
	# Valida existência
	if not spawned_objects.has(round_id):
		_log_debug("⚠️  Round %d não existe no registro" % round_id)
		return
	
	if not spawned_objects[round_id].has(object_id):
		_log_debug("⚠️  Objeto %d não existe no round %d" % [object_id, round_id])
		return
	
	var obj_data = spawned_objects[round_id][object_id]
	var item_node = obj_data.get("node")
	
	# Remove da cena
	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()
		_log_debug("Node removido da cena")
	
	# Remove do registro local
	spawned_objects[round_id].erase(object_id)
	
	# ✅ Desregistra primeiro
	NetworkManager.unregister_syncable_object(object_id)
	
	_log_debug("✓ Objeto despawnado no cliente: ID=%d" % object_id)

func _calculate_drop_impulse(player_rot: Vector3) -> Vector3:
	"""Calcula vetor de impulso para dropar item"""
	
	var basis = Basis.from_euler(player_rot)
	var forward = -basis.z
	
	var impulse = forward * drop_impulse_strength
	impulse.x += randf_range(-drop_impulse_variance, drop_impulse_variance)
	impulse.y += drop_impulse_strength * 0.5  # Para cima
	impulse.z += randf_range(-drop_impulse_variance, drop_impulse_variance)
	
	return impulse

# ===== UTILITÁRIOS =====

func filtrar_dict_invertido(original: Dictionary) -> Dictionary:
	var comando: Array = ["round_id", "room_id", "room_name", "players"]
	var copia := original.duplicate(true)  # cópia profunda
	for chave in copia.keys():
		if not comando.has(chave):
			copia.erase(chave)
	return copia

func set_main_menu(menu: Control):
	"""Registra referência do menu principal"""
	main_menu = menu
	_log_debug("UI principal registrada")
	
func verificar_rede() -> bool:
	var peer = multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer != null and multiplayer.has_multiplayer_peer()

func _log_debug(message: String):
	if not debug_mode:
		return

	var unique_id := cached_unique_id
	if unique_id == 0 and verificar_rede() and multiplayer.has_multiplayer_peer():
		unique_id = multiplayer.get_unique_id()
		cached_unique_id = unique_id

	print("[CLIENT][GameManager][ClientID: %s]: Message: %s" % [unique_id, message])
