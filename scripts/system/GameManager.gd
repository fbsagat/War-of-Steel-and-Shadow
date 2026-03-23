extends Node
class_name GameManager

## GameManager - Gerenciador principal do jogo multiplayer (CLIENTE)
## Responsável por conectar ao servidor dedicado e gerenciar o fluxo do jogo

# ===== CONFIGURAÇÕES =====

@export_category("Connection Settings")
const DEFAULT_SERVER_ADDRESS: String = "172.23.2.183" #local host: "127.0.0.1"
const DEFAULT_SERVER_PORT: int = 7777
@export var server_address: String = DEFAULT_SERVER_ADDRESS
@export var server_port: int = DEFAULT_SERVER_PORT
@export var localhost_auto_connect: bool = false

@export_category("Default Node References")
const map_scene : String = "res://scenes/system/terrain_3d.tscn"
const player_scene : String = "res://scenes/gameplay/player_warrior.tscn"
const camera_controller : String = "res://scenes/gameplay/camera_controller.tscn"

@export_category("Debug")
@export var debug_mode: bool = true
@export var visual_debug: bool = false

@export_category("Reconection Settings")
@export var reconnect_attempts :int = 0
const MAX_RECONNECT_ATTEMPTS : int = 1000
const RECONNECT_DELAY := 2.0 # segundos
var reconnect_timer: Timer

@export_category("Player Identifier")
var UUID_FILE := "user://identity.json"
var TOKEN_FILE := "user://server_tokens.json"
var uuid_base : String
var server_tokens : Dictionary = {}
const MAX_SAVED_TOKENS: int = 50

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var item_database: ItemDatabase = null
var network_manager: NetworkManager = null
var map_manager: Node = null
var initializer = null

# ===== VARIÁVEIS INTERNAS =====

var is_connected_to_server: bool = false
var is_in_round: bool = false
var is_connecting: bool = false
var inventory_menu: bool = false # True se o menu de inventário estiver visível
var gameplay_menu: bool = false # True se o menu de gameplay  estiver visível
var local_peer_id: int = 0
var player_name: String = ""
var configs: Dictionary = {} # Configurações do servidor
var current_room: Dictionary = {}
var current_round: Dictionary = {}
var connection_start_time: float = 0.0
var cached_unique_id: int = 0
## Objetos spawnados organizados por rodada
## {round_id: {object_id: {node: Node, item_name: String, owner_uuid: int}}}
var spawned_objects: Dictionary = {}
var local_inventory: Dictionary = {} # Inventário(de itens e equipamentos) local do player.
var peer: ENetMultiplayerPeer

# ===== REFERÊNCIAS INTERNAS =====

var main_menu_node: Control = null
var inventory_node : Control = null
var local_player_node: Node = null
var round_node: Node = null
var players_node: Node = null
var objects_node: Node = null
var room_settings: Dictionary = {"locked": false}

# ===== SINAIS =====

signal connected_to_server()
signal connection_failed(reason: String)
signal disconnected_from_server()
signal rooms_list_received(success: bool, rooms: Array)
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
signal item_removed(object_id: String)
signal item_equipped(object_id: String, slot_type: String)
signal item_unequipped(object_id: String)
signal items_swapped(item_id_1: String, item_id_2: String)

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	pass

func initialize():
	if main_menu_node:
		main_menu_node.show_main_menu()
	
	if localhost_auto_connect:
		_log_debug("Função de testes está ativada: Entrando no servidor localhost")
		await get_tree().create_timer(0.25).timeout
		join_server_by_ip(server_address, str(server_port))
	
	# Identificação de cliente
	uuid_base = _load_or_create_uuid()
	server_tokens = _load_tokens()
	
	connect_inventory_signals()
	connect_muiltiplayer_signals()
	setup_reconection_timer()
	
	_log_debug("▶️ GameManager inicializado com sucesso!")

func setup_reconection_timer():
	reconnect_timer = Timer.new()
	reconnect_timer.one_shot = true
	add_child(reconnect_timer)
	reconnect_timer.timeout.connect(_on_reconnect_timeout)

func connect_inventory_signals():
	main_menu_node.gameplay_menu_back_pressed.connect(_on_gameplay_menu_back_pressed)
	main_menu_node.gameplay_menu_exit_game_pressed.connect(_on_gameplay_menu_exit_game_pressed)
	main_menu_node.gameplay_menu_give_up_game_pressed.connect(_on_gameplay_menu_give_up_game_pressed)

func connect_muiltiplayer_signals():
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# ===== FUNÇÕES DE MENU e INPUT =====

func _unhandled_input(event: InputEvent) -> void:
	if not _can_process_menu_input():
		return

	if event.is_action_pressed("ui_cancel"):
		_handle_escape()
		return

	if event.is_action_pressed("ui_inventory"):
		_handle_inventory()
		return

# Validação
func _can_process_menu_input() -> bool:
	return is_in_round \
		and main_menu_node != null \
		and inventory_node != null

# ESC (ui_cancel)
# Prioridade: 1. Fecha inventário. 2. Fecha gameplay menu. 3. Abre gameplay menu.
func _handle_escape() -> void:
	# Fecha inventário primeiro
	if inventory_menu:
		inventory_menu = false
		_toggle_inventory_menu(true)
		return

	# Fecha gameplay menu
	if gameplay_menu:
		gameplay_menu = false
		_toggle_gameplay_menu(true)
		return

	# Abre gameplay menu
	gameplay_menu = true
	_toggle_gameplay_menu(false)

# Inventory menu (ui_inventory)
func _handle_inventory() -> void:
	# Não abre inventário se gameplay menu estiver aberto
	if gameplay_menu:
		return

	inventory_menu = !inventory_menu
	_toggle_inventory_menu(not inventory_menu)

func _on_gameplay_menu_back_pressed():
	_handle_escape()

func _toggle_inventory_menu(hide: bool = false) -> void:
	if not is_in_round or inventory_node == null:
		return

	if hide:
		# Esconder inventário
		local_player_node.stop_movment = false
		inventory_node.hide_inventory()
		_log_debug("Escondendo menu de inventário e capturando ponteiro do mouse")
	else:
		# Mostrar inventário
		local_player_node.stop_movment = true
		inventory_node.show_inventory()
		_log_debug("Mostrando menu de inventário e exibindo ponteiro do mouse")

# Gameplay menu
func _toggle_gameplay_menu(hide: bool = false) -> void:
	
	if main_menu_node == null:
		return
	
	if not local_player_node:
		return
	
	if hide:
		# Esconder gameplay menu
		local_player_node.stop_movment = false
		main_menu_node.hide_gameplay_menu()
		_log_debug("Escondendo menu de gameplay e capturando ponteiro do mouse")
	else:
		# Mostrar gameplay menu
		local_player_node.stop_movment = true
		main_menu_node.show_gameplay_menu()
		_log_debug("Mostrando menu de gameplay e exibindo ponteiro do mouse")

# ===== FUNÇÕES DE CONEXÃO COM O SERVIDOR =====

func connect_to_server():
	"""Conecta ao servidor dedicado"""
	
	if is_connected_to_server:
		_log_debug("Já conectado ao servidor")
		return
	
	if is_connecting:
		_log_debug("Já está tentando conectar")
		return
	
	_log_debug("Tentando conectar ao servidor: %s:%d" % [server_address, server_port])
	
	if main_menu_node:
		main_menu_node.show_loading_menu("Conectando ao servidor...")
	
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(server_address, server_port)
	
	if error != OK:
		_log_debug("Erro ao criar cliente: " + str(error))
		_handle_connection_error("Falha ao criar conexão com o servidor")
		return
	
	multiplayer.multiplayer_peer = peer
	is_connecting = true
	connection_start_time = Time.get_ticks_msec() / 1000.0
	
	_log_debug("Cliente criado, aguardando conexão...")

func _on_connected_to_server():
	"""Esse sinal é emitido quando o cliente consegue se conectar com sucesso ao servidor."""
	"""Callback quando conecta com sucesso ao servidor"""

	if not is_connecting:
		return

	if verificar_rede():
		# garante que o peer foi realmente configurado
		if multiplayer.has_multiplayer_peer():
			cached_unique_id = multiplayer.get_unique_id()
	
	is_connecting = false
	is_connected_to_server = true
	local_peer_id = multiplayer.get_unique_id()
	
	_log_debug(" Cliente conectado ao servidor com sucesso! Peer ID: %d" % local_peer_id)
	
	connected_to_server.emit()

func _on_connection_failed():
	"""Dispara quando a tentativa de conexão falha."""
	_log_debug("Falha ao conectar ao servidor")

func _on_reconnect_timeout() -> void:
	if not is_connecting:
		return

	_log_debug("Tempo esgotado aguardando conexão.")

	# ❗ IMPORTANTE: limpar antes de tentar de novo
	multiplayer.multiplayer_peer = null
	peer = null
	_try_reconnect()

func _schedule_next_retry() -> void:
	if reconnect_attempts >= MAX_RECONNECT_ATTEMPTS:
		_log_debug("Não foi possível reconectar.")
		is_connecting = false
		_on_reconnect_gave_up()
		return

	# Limpa o peer atual antes de tentar de novo
	multiplayer.multiplayer_peer = null
	peer = null

	reconnect_timer.start(RECONNECT_DELAY)

func _on_server_disconnected():
	"""Dispara quando o cliente já estava conectado, mas perde a conexão com o servidor.
	Aqui o jogo deve mostrar o menu de reconexão, se não conseguir no tempo e tentativas determinadas,
	desconecta totalmente e reseta, se conseguir, esconde a tela de reconexão e volta à partida normalmente"""
	
	_log_debug("Conexão perdida com o servidor, tentando reconectar para voltar à partida")
	
	is_connected_to_server = false
	network_manager.is_connected_ = false
	
	# Inicia processo de reconexão
	# Mostra menu de reconexão
	if main_menu_node:
		main_menu_node.show_main_menu()
		main_menu_node.show_connecting_menu()
		main_menu_node.show_error_connecting("Conexão perdida. Tentando reconectar...")
	
	start_reconnect(server_address, server_port)

func start_reconnect(address: String, port: int) -> void:
	server_address = address
	server_port = port
	reconnect_attempts = 0
	is_connecting = true
	_try_reconnect()

func _try_reconnect() -> void:
	if reconnect_attempts >= MAX_RECONNECT_ATTEMPTS:
		_log_debug("Desistiu de reconectar após %d tentativas." % MAX_RECONNECT_ATTEMPTS)
		is_connecting = false
		_on_reconnect_gave_up()
		return

	reconnect_attempts += 1
	main_menu_node.show_error_connecting(
		"Conexão perdida. Tentando reconectar... \ntentativa %s/%s" % [reconnect_attempts, MAX_RECONNECT_ATTEMPTS])
	_log_debug("Tentando reconectar... tentativa %d/%d" % [reconnect_attempts, MAX_RECONNECT_ATTEMPTS])
	
	# Cria um peer novo para cada tentativa
	peer = ENetMultiplayerPeer.new()
	var result := peer.create_client(server_address, server_port)

	if result != OK:
		_log_debug("Erro ao criar cliente ENet. Código: %s" % str(result))
		_schedule_next_retry()
		return

	multiplayer.multiplayer_peer = peer

	# Se o servidor estiver offline, o resultado real virá por signal
	# Este timer serve como fallback caso a rede demore demais
	reconnect_timer.start(RECONNECT_DELAY)

func _on_reconnect_gave_up() -> void:
	
	_disconnect_from_server()
	if main_menu_node:
		main_menu_node.show_main_menu()

	_log_debug("Conexão perdida permanentemente.")

func _disconnect_from_server(notify_server: bool = false):
	"""Dispara quando o cliente quer desconectar do servidor intencionalmente
	Aqui o jogo deve retornar para a tela inicial, desconectado do servidor, tudo resetado e sem 
	possibilidade de o cliente retornar ao round em que estava
	notify = avisa o servidor.
	"""
	
	_log_debug("Cliente desconectado intencionalmente do servidor, resetando estado do cliente e voltando ao menu principal")
	
	if notify_server:
		_log_debug("Avisando servidor")
		# Fazer a função
	
	# Iniciando reset completo
	# Fecha conexão com o servidor
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
		
	# Reset completo do estado
	peer = null
	inventory_menu = false
	gameplay_menu = false
	is_connected_to_server = false
	is_in_round = false
	is_connecting = false
	local_peer_id = 0
	player_name = ""
	configs.clear()
	current_room.clear()
	current_round.clear()
	local_player_node = null
	spawned_objects.clear()
	local_inventory.clear()
	
	# Limpa o nó da partida(round) totalmente
	if round_node:
		round_node.queue_free()
		
	# Volta para tela inicial
	if main_menu_node:
		main_menu_node.show_main_menu()
	
	# Emite sinal
	disconnected_from_server.emit()

func join_server_by_ip(received_ip: String, received_port: String) -> bool:
	# Validar IP/hostname
	if received_ip and received_ip.strip_edges() != "":
		var trimmed_ip: String = received_ip.strip_edges()
		
		if not _is_valid_address(trimmed_ip):
			_log_debug("Endereço inválido: " + trimmed_ip)
			return false
		
		server_address = trimmed_ip
	
	# Validar porta
	if received_port and received_port.strip_edges() != "":
		var trimmed_port: String = received_port.strip_edges()
		
		if not trimmed_port.is_valid_int():
			_log_debug("Porta inválida: não é um número")
			return false
		
		var port_number: int = int(trimmed_port)
		
		if port_number < 1 or port_number > 65535:
			_log_debug("Porta inválida: deve estar entre 1 e 65535")
			return false
		
		server_port = port_number
	
	_log_debug("Conectando manualmente no servidor: " + server_address + ":" + str(server_port))
	connect_to_server()
	return true

func _is_valid_address(address: String) -> bool:
	# Validar localhost
	if address.to_lower() in ["localhost", "::1"]:
		return true
	
	# Validar IPv4
	if _is_valid_ipv4(address):
		return true
	
	# Validar hostname (formato básico)
	if _is_valid_hostname(address):
		return true
	
	return false

func _is_valid_ipv4(ip: String) -> bool:
	var parts: PackedStringArray = ip.split(".")
	
	if parts.size() != 4:
		return false
	
	for part in parts:
		if not part.is_valid_int():
			return false
		
		var num: int = int(part)
		if num < 0 or num > 255:
			return false
	
	return true
	
func _is_valid_hostname(hostname: String) -> bool:
	# Hostname não pode estar vazio ou ser muito longo
	if hostname.length() == 0 or hostname.length() > 253:
		return false
	
	# Não pode começar ou terminar com hífen ou ponto
	if hostname.begins_with("-") or hostname.ends_with("-") or hostname.begins_with(".") or hostname.ends_with("."):
		return false
	
	# Validar cada label (parte separada por ponto)
	var labels: PackedStringArray = hostname.split(".")
	
	for label in labels:
		if label.length() == 0 or label.length() > 63:
			return false
		
		# Verificar se contém apenas caracteres válidos (a-z, A-Z, 0-9, hífen)
		for i in range(label.length()):
			var c: String = label[i]
			var is_valid: bool = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-'
			
			if not is_valid:
				return false
		
		# Label não pode começar ou terminar com hífen
		if label.begins_with("-") or label.ends_with("-"):
			return false
	
	return true

# ===== SISTEMA DE IDENTIFIAÇÃO =====

func _load_or_create_uuid() -> String:
	"""
	Gera identidade persistente do cliente.
	Nunca muda após criação.
	"""
	if FileAccess.file_exists(UUID_FILE):
		var data = JSON.parse_string(FileAccess.get_file_as_string(UUID_FILE))
		return data["uuid_base"]

	var crypto = Crypto.new()
	var new_uuid = crypto.generate_random_bytes(16).hex_encode()

	var file = FileAccess.open(UUID_FILE, FileAccess.WRITE)
	file.store_string(JSON.stringify({"uuid_base": new_uuid}))
	file.close()

	return new_uuid

func _load_tokens() -> Dictionary:
	if FileAccess.file_exists(TOKEN_FILE):
		return JSON.parse_string(FileAccess.get_file_as_string(TOKEN_FILE))
	return {}

func _save_tokens() -> void:
	"""
	Salva apenas os tokens mais recentes.
	Mantém no máximo MAX_SAVED_TOKENS entradas.
	Funciona com Dictionary simples:
	{
		"server_id": "token"
	}
	"""
	
	# Se exceder limite, remove os mais antigos
	while server_tokens.size() > MAX_SAVED_TOKENS:
		# Pega a primeira chave inserida (mais antiga)
		var oldest_key = server_tokens.keys()[0]
		server_tokens.erase(oldest_key)
	
	var file = FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	file.store_string(JSON.stringify(server_tokens))
	file.close()

func handle_server_response(response: Dictionary) -> void:
	"""
	Processa resposta do servidor.
	Salva novo token se necessário.
	"""

	if response["status"] == "new_token":
		var sid = response["server_id"]
		server_tokens[sid] = response["token"]
		_save_tokens()
			
		if main_menu_node:
			main_menu_node.show_name_input_menu(true)

	elif response["status"] == "ok":
		_log_debug("Autenticado com sucesso")
		player_name = response["player_name"]
		
		if is_in_round:
			if main_menu_node:
				main_menu_node.hide_main_menu()
		else:
			if main_menu_node:
				if player_name == "":
					main_menu_node.show_name_input_menu(true)
				else:
					main_menu_node.update_name_e_connected(configs["server_name"], response["player_name"])
					main_menu_node.show_main_menu()

	elif response["status"] == "reject":
		_log_debug("Conexão rejeitada: %s" % response.get("reason",""))
		_disconnect_from_server()

# ===== EXECUÇÃO DE BOTÕES DE CONEXÃO =====

func _on_gameplay_menu_exit_game_pressed():
	_cleanup_local_round()
	
	# Sinalizar pra o servidor que está desconectado da rodada
	_mark_player_disconnected()

	
	# Volta para o menu da sala
	if main_menu_node:
		main_menu_node.show_main_menu()
		
	_log_debug("_on_gameplay_menu_exit_game_pressed")

func _on_gameplay_menu_disconnect_f_server_pressed():
	_log_debug("_on_gameplay_menu_disconnect_f_server_pressed")
	_disconnect_from_server(true)

func _on_gameplay_menu_give_up_game_pressed():
	_cleanup_local_round()
	network_manager._server_request_return_or_exit(false)
	
	# Volta para o menu da sala
	if main_menu_node:
		main_menu_node.show_main_menu()

# ===== ATUALIZAÇÃO DE CONFIGURAÇÕES =====

func update_client_info(info: Dictionary):
	"""Atualiza configurações do servidor para o cliente"""
	_log_debug("Atualizando configurações do servidor: %s" % info)
	
	for key in info.keys():
		var new_value = info[key]
		
		# Se não existe ou se mudou, atualiza
		if not configs.has(key) or configs[key] != new_value:
			configs[key] = new_value
			_log_debug("[UPDATED] %s: %s" % [str(key), str(new_value)])
			
		if key == "server_id":
			var token : String = ""
			if server_tokens.has(new_value):
				token = server_tokens[new_value]

			# Agora enviamos o hello com uuid + token
			network_manager.send_hello_to_server(uuid_base, token)
	
	# Ao atualizar, se estiver em uma partida e for o mesmo servidor, esconde o menu e continua
	# Se não for o mesmo servidor, sem registro de cliente e partida nele, então: conexão nova.
	if is_in_round:
		var loaded_round = get_tree().root.get_node_or_null("Round")
		
		if not loaded_round:
			_log_debug("❌ Nó do round não encontrado")
			return
			
		if loaded_round.server_id == configs["server_id"]:
			main_menu_node.hide_main_menu()
		else:
			_cleanup_local_round()
			_log_debug("Não é o mesmo servidor / id incompatível")

# ===== CRIAÇÃO DE REDE LOCAL =====

func create_local_match():
	"""Criar uma partida local"""
	_log_debug("Iniciando uma partida local")
	
	# Executar build do servidor.
	#var server_pid := -1
	#var server_path = ProjectSettings.globalize_path("res://server/server.exe")
	#server_pid = OS.create_process(server_path, ["--port", "7777"])

# ===== REGISTRO DE JOGADOR =====
	
func set_player_name(p_name: String):
	"""Envia nome do jogador para registro no servidor"""
	if not is_connected_to_server:
		main_menu_node._show_error_("Não conectado ao servidor", main_menu_node.name_input_error_label, "Red")
		return
	
	_log_debug("Tentando registrar nome: " + p_name)
	
	if main_menu_node:
		main_menu_node.show_loading_menu("Registrando jogador...")
	
	network_manager.register_player_name(p_name)
	
func _client_name_accepted(accepted_name: String):
	"""Callback quando o nome é aceito pelo servidor"""
	player_name = accepted_name
	_log_debug("Nome aceito pelo servidor: " + player_name)
	
	if main_menu_node:
		main_menu_node.update_name_e_connected(configs["server_name"], accepted_name)
		
	name_accepted.emit()
	
func _client_name_rejected(reason: String):
	"""Callback quando o nome é rejeitado"""
	_log_debug("Nome rejeitado: " + reason)
	
	if main_menu_node:
		# Se player_name for "", é tela de welcome, se já ter algum nome definido, tela de renomeação 
		var condition = true if player_name == "" else false
		main_menu_node.show_name_input_menu(condition)
		main_menu_node._show_error_(reason, main_menu_node.name_input_error_label, "Red")
	
	name_rejected.emit(reason)

# ===== GERENCIAMENTO DE SALAS =====

func _client_wrong_password():
	"""Callback quando a senha está incorreta"""
	
	var current_menu_visible_name = main_menu_node.current_menu_visible.name
	main_menu_node.room_list_menu.visible = true
	
	if main_menu_node and current_menu_visible_name == "RoomListMenu":
		main_menu_node._show_error_("Senha incorreta", main_menu_node.match_list_error_label, "Red")
		main_menu_node.show_room_list_menu(true, true)

	if main_menu_node and current_menu_visible_name == "ManualRoomJoinMenu":
		main_menu_node._show_error_("Senha incorreta", main_menu_node.manual_room_join_error_label, "Red")
		main_menu_node.show_manual_room_join_menu(true)
		
func _client_room_name_error(error_msg : String):
	"""Callback de quando existe um erro com o nome da sala"""
	if main_menu_node:
		main_menu_node.show_create_match_menu()
		main_menu_node._show_error_(error_msg, main_menu_node.create_room_error_label, "Red")

func _client_room_not_found():
	"""Callback quando a sala não é encontrada"""
	if main_menu_node:
		main_menu_node.show_room_list_menu(true, false)
		main_menu_node.match_password_container.visible = true
		main_menu_node._show_error_("Sala não encontrada", main_menu_node.match_list_error_label, "Red")

func _request_rooms_list():
	_log_debug("📤 Solicitando lista de salas")
	
	# Cancelar pedido se não ter nome do player
	if player_name.is_empty():
		if main_menu_node:
			main_menu_node.show_name_input_menu(true)
		main_menu_node._show_error_("Nome do jogador não definido", main_menu_node.name_input_error_label, "Red")
		return
		
	network_manager.request_rooms_list()

func _client_receive_rooms_list(rooms: Array):
	"""Callback quando recebe lista de salas, requisitado pelo cliente"""
	rooms_list_received.emit(true, rooms)

func _client_receive_round_return_request(_room_name: String):
	"""Cliente recebe requisição do servidor para retornar à partida onde estava ou abandonar"""
	_log_debug("Recebendo requisição do servidor para retornar à prtid onde estava: %s" % _room_name)
	if main_menu_node:
			main_menu_node.show_round_return_menu(_room_name)

func _request_return_to_round():
	"""Cliente envia resposta dizendo que quer voltar à partida em que estava"""
	network_manager._server_request_return_or_exit(true)
	
func _request_exit_from_round():
	"""Cliente envia resposta dizendo que quer abandonar a partida em que estava"""
	network_manager._server_request_return_or_exit(false)

func all_client_receive_rooms_list(rooms: Array):
	"""Callback quando recebe atualização de lista de salas por prte do servidor(não requisitado)"""
	_log_debug("Lista de salas atualizada: %d salas" % rooms.size())
	
	# Ignora se não estiver na lista de salas
	if not main_menu_node.current_menu_visible.name == "RoomListMenu":
		return
	rooms_list_received.emit(true, rooms)

func create_room(room_name: String, password: String = ""):
	"""Cria uma nova sala"""
	
	if is_in_round:
		return
	
	if not is_connected_to_server:
		main_menu_node._show_error_("Não conectado ao servidor", main_menu_node.match_list_error_label, "Red")
		return
	
	if player_name.is_empty():
		if main_menu_node:
			main_menu_node.show_name_input_menu(true)
		main_menu_node._show_error_("Nome do jogador não definido", main_menu_node.name_input_error_label, "Red")
		return
	
	_log_debug("Criando sala: '%s' (Senha: %s)" % [room_name, "Sim" if password else "Não"])
	
	if main_menu_node:
		main_menu_node.show_loading_menu("Criando sala...")
	
	network_manager.create_room(room_name, password)

func _client_room_created(room_data: Dictionary):
	"""Callback quando sala é criada com sucesso"""
	current_room = room_data
	_log_debug(" Sala criada com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu_node:
		main_menu_node.show_room_menu(room_data)
	
	room_created.emit(room_data)

func join_room(room_id: int, password: String = ""):
	"""Entra em uma sala por ID"""
	
	if is_in_round:
		return
	
	if not is_connected_to_server:
		main_menu_node._show_error_("Não conectado ao servidor", main_menu_node.match_list_error_label, "Red")
		return
	
	if player_name.is_empty():
		if main_menu_node:
			main_menu_node.show_name_input_menu(true)
		main_menu_node._show_error_("Nome do jogador não definido", main_menu_node.name_input_error_label, "Red")
		return
	
	_log_debug("Tentando entrar na sala ID: %d" % room_id)
	
	network_manager.join_room(room_id, password)

func join_room_by_name(room_name: String, password: String = ""):
	"""Entra em uma sala por nome"""
	
	if is_in_round:
		return
	
	if not is_connected_to_server:
		main_menu_node._show_error_("Não conectado ao servidor", main_menu_node.match_list_error_label, "Red")
		return
	
	if player_name.is_empty():
		if main_menu_node:
			main_menu_node.show_name_input_menu(true)
		main_menu_node._show_error_("Nome do jogador não definido", main_menu_node.name_input_error_label, "Red")
		return
	
	_log_debug("Tentando entrar na sala: '%s'" % room_name)
	
	if main_menu_node:
		main_menu_node.show_loading_menu("Procurando sala...")
	
	network_manager.join_room_by_name(room_name, password)

func _client_joined_room(room_data: Dictionary):
	"""Callback quando entra em uma sala com sucesso"""
	current_room = room_data
	_log_debug("Entrou na sala com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu_node:
		main_menu_node.show_room_menu(room_data)
	
	joined_room.emit(room_data)

func _client_room_updated(room_data: Dictionary):
	"""Callback quando a sala é atualizada"""
	current_room = room_data
	_log_debug("Sala atualizada: %s (%d jogadores)" % [room_data["name"], room_data["players"].size()])
	
	#if main_menu:
		#main_menu._update_room_display(room_data)
	
	room_updated.emit(room_data)

func kick_player_from_room(_selected_player_id: String):
	"""Envia pedido para expulsar um player da sala (somente para o host)"""
	
	if is_in_round:
		return
	
	# Verificação local se é o host (add redundancia)
	var host_id = -1
	var _player_name: String
	
	for player in current_room["players"]:
		if player.get("uuid_base") == _selected_player_id:
			_player_name = player["name"]
	
	for player in current_room["players"]:
		if player.get("is_host", false):
			host_id = player["id"]
	if host_id == uuid_base:
		network_manager.kick_player_from_room(_selected_player_id)
		_log_debug("Pedido para expulsar player, id: %s feito ao servidor" % _selected_player_id)

func _client_kicked_from_room():
	"""Recebe notificação do servidor de que foi expulso da sala em que está"""
	var name_room = current_room["name"]
	current_room = {}
	
	if main_menu_node:
		main_menu_node.show_room_list_menu(true, false)
		main_menu_node._show_error_("Você foi expulso da sala %s" % name_room, main_menu_node.match_list_error_label, "Red")

func leave_room():
	"""Sai da sala atual"""
	
	if is_in_round:
		return
		
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	_log_debug("Saindo da sala: %s" % current_room["name"])
	network_manager.leave_room()
	current_room = {}

func close_room():
	"""Fecha a sala atual (apenas host)"""
	
	if is_in_round:
		return
	
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_id"] != uuid_base:
		return
	
	_log_debug("Fechando sala: %s" % current_room["name"])
	network_manager.close_room()
	current_room = {}
	if main_menu_node:
		main_menu_node.show_room_list_menu(true, false)

func _client_room_closed(reason: String):
	"""Callback quando a sala é fechada"""
	_log_debug("Sala fechada: " + reason)
	current_room = {}
	
	if main_menu_node:
		main_menu_node._show_error_(reason, main_menu_node.match_list_error_label, "Red")
		main_menu_node.show_room_list_menu(true)

func request_update_settings(new_values: Dictionary) -> void:
	"""
	Envia ao servidor as configurações modificadas (apenas elas).
	Compara com match_settings atual e envia somente o diff.
	"""
	
	if is_in_round:
		return
	
	var changed_settings := {}
	
	for key in new_values.keys():
		if not room_settings.has(key):
			continue
		
		if room_settings[key] != new_values[key]:
			changed_settings[key] = new_values[key]
	
	# Se nada mudou, não envia RPC
	if changed_settings.is_empty():
		return
	
	# Envia pedido ao servidor (ID 1 = servidor dedicado)
	network_manager.request_update_room_settings(changed_settings)

func client_update_match_settings(changed_settings: Dictionary) -> void:
	"""Callback que atualiza apenas as configurações modificadas."""
	
	for key in changed_settings.keys():
		room_settings[key] = changed_settings[key]
	
	# Verificar se é host; se sim, atualizar o botão de 
	var host_id = current_room.get("host_id", -1)
	if host_id == uuid_base:
		if room_settings["locked"] == true:
			main_menu_node.room_lock_button.text = "Liberar Sala"
			main_menu_node._show_error_("Sala trancada, ninguém entra!", main_menu_node.room_error_label, "Yellow")
		else:
			main_menu_node.room_lock_button.text = "Trancar Sala"
			main_menu_node._show_error_("Sala liberada, chama a glr!", main_menu_node.room_error_label, "Yellow")

# ===== GERENCIAMENTO DE RODADAS =====

func start_round(round_settings: Dictionary = {}):
	"""Inicia uma nova rodada (apenas host, que irá solicitar início da rodada)"""
	
	if is_in_round:
		return
	
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_id"] != uuid_base:
		return
	
	if current_room.players.size() < configs.min_players_to_start:
		main_menu_node._show_error_("Pelo menos %d jogadores são necessários para iniciar uma rodada" % 1, main_menu_node.room_error_label, "Yellow")
		return
	
	_log_debug("Solicitando início da rodada...")
	network_manager._server_request_start_round(round_settings)
	
func _client_round_started(server_id: String, match_data: Dictionary):
	"""Callback quando a rodada inicia"""
	_log_debug("Rodada iniciada pelo servidor!")
	_start_round_locally(server_id, match_data)

func _client_round_return(server_id: String, match_data: Dictionary):
	"""Callback quando o jogador retorna à rodada"""
	_log_debug("retornando à rodada")
	_return_round_locally(server_id, match_data)

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
	if main_menu_node:
		main_menu_node.show_round_end_screen(end_data)
	
	round_ended.emit(end_data)
	
	# Aguarda um pouco antes de limpar
	await get_tree().create_timer(1.0).timeout
	
	# Limpa objetos locais
	_cleanup_local_round()

func _start_round_locally(server_id: String, match_data: Dictionary):
	"""Inicia a rodada localmente no cliente"""
	_log_debug("========================================")
	_log_debug("INICIANDO RODADA")
	_log_debug("Sala: ID %d" % match_data["room_id"])
	_log_debug("Rodada: ID %d" % match_data["round_id"])
	_log_debug("Mapa: %s" % match_data["map_scene"])
	_log_debug("Jogadores participantes:")
	
	for player in match_data["players"]:
		var is_host = " [HOST]" if player["is_host"] else ""
		var is_me = " [GUEST]" if player["id"] == uuid_base else ""
		_log_debug("- %s (ID: %s)%s%s" % [player["name"], player["id"], is_host, is_me])
	
	_log_debug("========================================")
	
	is_in_round = true
	
	# Criar cena de organização do round
	round_node = preload("res://scripts/utils/round_node.gd").new()
	round_node.name = "Round"
	round_node.round_id = match_data["round_id"]
	round_node.room_id = match_data["room_id"]
	round_node.server_id = server_id
	
	# Adiciona à raiz
	get_tree().root.add_child(round_node)
	
	# Cria nós organizacionais
	players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	# Carrega o mapa
	await map_manager.load_map(match_data["map_scene"], round_node)
	await map_manager.apply_map_configs(match_data["settings"])

	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var is_local = player_data["id"] == uuid_base
		_spawn_player(player_data, is_local, match_data)
	
	# Esconde o menu
	if main_menu_node:
		main_menu_node.hide_main_menu()
		
	round_started.emit()
	
	# Filtrar uns itens e deixar numa variável(current_round) para uso durante a partida
	# Modifique em filtrar_dict_invertido a lista de itens que devem retornar do dicionário match_data
	var filtered_round_data = filtrar_dict_invertido(match_data)
	current_round = filtered_round_data
	
	_log_debug("Rodada carregada no cliente")

func _return_round_locally(server_id: String, match_data: Dictionary):
	"""Retorna à rodada localmente no cliente"""
	_log_debug("========================================")
	_log_debug("RETORNANDO À RODADA")
	_log_debug("Sala: ID %d" % match_data["room_id"])
	_log_debug("Rodada: ID %d" % match_data["round_id"])
	_log_debug("Mapa: %s" % match_data["map_scene"])
	_log_debug("Jogadores participantes:")
	
	for player in match_data["players"]:
		var is_host = " [HOST]" if player["is_host"] else ""
		var is_me = " [GUEST]" if player["id"] == uuid_base else ""
		_log_debug("- %s (ID: %s)%s%s" % [player["name"], player["id"], is_host, is_me])
	
	_log_debug("========================================")
	
	is_in_round = true
	
	# Criar cena de organização do round
	round_node = preload("res://scripts/utils/round_node.gd").new()
	round_node.name = "Round"
	round_node.round_id = match_data["round_id"]
	round_node.room_id = match_data["room_id"]
	round_node.server_id = server_id
	
	# Adiciona à raiz
	get_tree().root.add_child(round_node)
	
	# Cria nós organizacionais
	players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	# Carrega o mapa
	await map_manager.load_map(match_data["map_scene"], round_node)
	await map_manager.apply_map_configs(match_data["settings"])

	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		# \/ Se for igual, retorna true
		var is_local = player_data["id"] == uuid_base
		_spawn_player(player_data, is_local, match_data)
	
	# Atualiza visual de equipamentos para cada personagem, incluindo local
	# (local deve usar funções do game manager add_item_to_inventory e equip_item antes de 
	# apply_visual_equip_on_player_node no nó do personagem)
	
	for player_uuid in match_data["equipped_items"]:
		var slots = match_data["equipped_items"][player_uuid]
		for slot_name in slots:
			var item = slots[slot_name]
			if item.is_empty():
				continue
			var item_id = item.get("item_id")
			var object_id = item.get("object_id")
			var node = players_node.get_node_or_null(str(player_uuid))
			if player_uuid == multiplayer.get_unique_id():
				var item_name = item_database.get_item_by_id(int(item_id))["name"]
				add_item_to_inventory(item_id, object_id)
				equip_item(object_id, "", item_name)
				node.apply_visual_equip_on_player_node(item_id)
			else:
				node.apply_visual_equip_on_player_node(item_id)
	
	# Atualiza visual de itens no inventário do player local
	for item in match_data["player_items"]:
		add_item_to_inventory(item["item_id"], item["object_id"])
	
	# Spawna objetos com localização(e outros atributos) atual na partida
	for object_id in match_data["round_objects"]:
		var item = match_data["round_objects"][object_id]
		var round_id = item["round_id"]
		var name_ = item["item_name"]
		var position = item["position"]
		var rotation = item["rotation"]
		var velocity = item["drop_velocity"]
		var owner_ = item["owner_uuid"]
		_spawn_on_client(object_id, round_id, name_, position, rotation, velocity, owner_)
	
	# Esconde o menu
	if main_menu_node:
		main_menu_node.hide_main_menu()
	
	round_started.emit()
	
	# Filtrar uns itens e deixar numa variável(current_round) para uso durante a partida
	# Modifique em filtrar_dict_invertido a lista de itens que devem retornar do dicionário match_data
	var filtered_round_data = filtrar_dict_invertido(match_data)
	current_round = filtered_round_data
	
	# Sinalizar pra o servidor que está reconectado na rodada
	_unmark_player_disconnected()
	
	_log_debug("Rodada recarregada no cliente")

func _spawn_player(player_data: Dictionary, is_local: bool, _match_data: Dictionary):
	"""Spawna players para cada cliente, cada cliente recebe X execuções,
	 a do seu jogador local e a do(s) jogador(es) remoto(s), sendo o seu = local
	player_data: { "id": "c3fabada6625ae19d44ed7df0eced246", "session_id": 504040370, 
	"name": "TestPlayer1 - 504040370", "is_host": false, "is_offline": false }"""
	
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
	
	# Injeta dependências
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.initializer = initializer
	player_instance.game_manager = self
	
	# Adiciona player à cena PRIMEIRO
	players_node.add_child(player_instance)
	
	# Inicializa jogador (configura identificação básica)
	var player_pos = _match_data["settings"]["spawn_points"][player_data["session_id"]]
	var color: Color = Color(0.0, 0.0, 0.0, 1.0)
	var final_color = player_data["character"]["color"] if player_data["character"]["color"] else color
	player_instance.initialize(player_data["name"], final_color, player_data["session_id"], player_data["id"], player_pos["position"])
	player_instance.rotation = player_pos["rotation"]

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
		var inventory_node_: Node = inventory_scene.instantiate()
		round_node.add_child(inventory_node_)
		inventory_node = inventory_node_
		inventory_node.game_manager = self
		inventory_node.initializer = initializer
		
		# Atribui referência DIRETA (só para local) inventory_node
		player_instance.inventory_node = inventory_node
		inventory_node.setup_inventory_signals()
		player_instance.connect_inventory_signals()
		inventory_node.player_node = player_instance
		
		# Atribui referência DIRETA (só para local) camera_instance
		player_instance.camera_controller = camera_instance
		
		# Adiciona câmera à cena
		players_node.add_child(camera_instance)
		
		# Ativa controle
		player_instance.set_as_local_player()
		camera_instance.set_as_active()
		local_player_node = player_instance
		
		player_instance.add_to_group("player")
		player_instance.add_to_group("myself_player")
		
		# Preenche terreno e central_spawn do player local (comentado pois não está sendo usado)
		#player_instance.terrain_ = map_manager.current_map
		#player_instance.central_spawn = player_instance.terrain_.get_node_or_null("central_spawn")
		
		_log_debug("🧍🏼Jogador local spawnado: %s na posição: %s" % [player_name_, player_pos["position"]])
	else:
		# Jogador remoto: NÃO tem câmera atribuída
		player_instance.camera_controller = null
		
		player_instance.add_to_group("player")
		player_instance.add_to_group("remote_player")
		
		_log_debug("🧍🏼Jogador remoto spawnado: %s na posição: %s" % [player_name_, player_pos["position"]])

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
	if main_menu_node:
		main_menu_node.show()
		main_menu_node.show_room_menu(room_data)
	
	returned_to_room.emit(room_data)
	
	_log_debug(" De volta à sala")

func _client_remove_player(peer_id : int):
	"""Limpa o nó do cliente que se desconectou, esta função é para os outros 
	que estão conectados"""
	if peer_id and players_node and local_peer_id != peer_id:
		var player_node = players_node.get_node_or_null(str(peer_id))
		if player_node:
			player_node.queue_free()

func _client_update_character_peer_id(_uuid_base: String, _new_peer_id: int):
	"""Atualiza o id de sessão do cliente reconectado no round para manutenção de sincronia, 
	isso acontece nos clientes que inda estão no round"""
	_log_debug("👤 Atualizando session id de remoto: %s para %d" % [_uuid_base, _new_peer_id])
	
	if not players_node:
		return
		
	for child in players_node.get_children():
		if child is CharacterBody3D and child.player_uuid == _uuid_base:
			child.name = str(_new_peer_id)
			child.player_id = _new_peer_id
			
			if visual_debug:
				var start = _uuid_base.substr(0, 4)
				var end = _uuid_base.substr(_uuid_base.length() - 4, 4)
				child.name_label.text = "%s\n%s[...]%s\n%s" % [player_name, start, end, _new_peer_id]
			
			child.set_multiplayer_authority(_new_peer_id)
# Execut
func _cleanup_local_round():
	"""Limpa todos os objetos da rodada no cliente"""
	_log_debug("Limpando objetos da rodada...")
	
	local_player_node = null
	is_in_round = false
	inventory_menu = false
	gameplay_menu = false
	
	# Limpa objetos spawnados
	for round_id in spawned_objects.keys():
		for object_id in spawned_objects[round_id].keys():
			var obj_data = spawned_objects[round_id][object_id]
			var item_node = obj_data.get("node")
			
			if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
				item_node.queue_free()
	
	spawned_objects.clear()
	
	if round_node:
		round_node.queue_free()

	_log_debug("✓ Limpeza completa")

func _mark_player_disconnected():
	"""Sinaliza para o servidor como desconectado durante a rodada."""
	network_manager._mark_player_disconnected(true)

func _unmark_player_disconnected():
	"""Sinaliza para o servidor como reconectado durante a rodada."""
	network_manager._mark_player_disconnected(false)

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
		push_error("ClientRegistry: Item inválido: %s" % item_id)
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
	
	# Emite o sinal
	item_added.emit(str(object_id), item_name, item_type, icon_path)
	
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

func equip_item(object_id, item_slot: String = "", item_name: String = "") -> bool:
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
		if local_inventory["inventory"][i]["object_id"] == int(object_id):
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
			push_error("ClientRegistry: Não foi possível detectar slot para item: %s" % item_name)
			return false
	
	# Valida slot
	if not local_inventory["equipped"].has(item_slot):
		push_error("ClientRegistry: Slot inválido: %s" % item_slot)
		return false
	
	# Valida se item pode ser equipado neste slot
	if item_database and not item_database.can_equip_in_slot(item_name, item_slot):
		push_error("ClientRegistry: Item %s não pode ser equipado em %s" % [item_name, item_slot])
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

func unequip_item(_object_id: int, item_slot: String, verify: bool = true) -> bool:
	"""Desequipa item de um slot e retorna ao inventário"""

	if local_inventory.is_empty():
		return false
	
	if not local_inventory["equipped"].has(item_slot):
		push_error("ClientRegistry: Slot inválido: %s" % item_slot)
		return false
	
	var item_data = local_inventory["equipped"][item_slot]
	if item_data.is_empty():
		return false
	
	# Verifica se há espaço no inventário
	if verify and local_inventory["inventory"].size() >= 9:
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

func swap_equipped_item(new_item_name: String, dragged_item: Dictionary, existing_item_id: int, target_slot: String) -> bool:
	"""
	Troca item equipado diretamente (desequipa antigo, equipa novo)
	- Não emite sinais intermediários de equip/unequip
	- Mantém ambos os itens no inventário/equipamento
	- Emite apenas items_swapped no final
	"""

	if local_inventory.is_empty():
		return false
	
	if not local_inventory["equipped"].has(target_slot):
		push_error("ClientRegistry: Slot inválido para swap: %s" % target_slot)
		return false
	
	var old_item_data = local_inventory["equipped"][target_slot]
	if old_item_data.is_empty():
		push_error("ClientRegistry: Nenhum item equipado no slot %s para trocar" % target_slot)
		return false
	
	# Verifica se o dragged_item realmente está no inventário
	var new_item_idx = -1
	for i in range(local_inventory["inventory"].size()):
		if local_inventory["inventory"][i]["object_id"] == int(dragged_item["object_id"]):
			new_item_idx = i
			break
	
	if new_item_idx == -1:
		push_error("ClientRegistry: Item arrastado não encontrado no inventário")
		return false
	
	var new_item_data = local_inventory["inventory"][new_item_idx]
	
	# 1. Remove o NOVO item do inventário
	local_inventory["inventory"].remove_at(new_item_idx)
	
	# 2. Coloca o ITEM ANTIGO no inventário (no lugar do novo)
	local_inventory["inventory"].append(old_item_data)
	
	# 3. Equipa o NOVO item no slot
	local_inventory["equipped"][target_slot] = new_item_data
	
	var old_item_name = item_database.get_item_by_id(int(old_item_data["item_id"]))["name"]
	
	_log_debug("🔄 Item trocado diretamente: %s <-> %s em %s" % [
		old_item_name, new_item_name, target_slot])
	
	items_swapped.emit(dragged_item["object_id"], str(existing_item_id))
	
	return true

func clear_player_inventory():
	"""Limpa inventário do jogador em uma rodada"""
	
	local_inventory.clear()
	_log_debug("✓ Inventário limpo")

# ===== SPAWN DE OBJETOS =====

func _spawn_on_client(object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_uuid: String):
	"""
	Spawna objeto no cliente (chamado via RPC)
	"""
	
	if not is_in_round:
		return
	
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
	
	# Nome consistente com servidor
	item_node.name = "Object_%d_%s_%d" % [object_id, item_name, round_id]
	_log_debug("[ITEM]📦 Spawnando no cliente: %s - %s" % [owner_uuid, item_node.name])
	
	# Injeta dependências
	item_node.network_manager = network_manager
	item_node.initializer = initializer
	
	# Adiciona à árvore
	var round_scene = get_tree().root.get_node_or_null("Round")
	if round_scene:
		var obj_scene = round_scene.get_node_or_null("Objects")
		if obj_scene:
			obj_scene.add_child(item_node, true)
		else:
			_log_debug("Objects node not found in Round!")
	else:
		_log_debug("Round node not found!")
	
	await get_tree().process_frame
	
	# Configura transformação
	if item_node is Node3D:
		item_node.global_position = position
		item_node.global_rotation = rotation
	
	# Inicializa item
	if item_node.has_method("initialize"):
		var item_full_data = item_database.get_item_full_info(item_name)
		item_node.initialize(object_id, round_id, item_name, item_full_data, owner_uuid, drop_velocity)
	# ✅ CORRIGIDO: Registra com estrutura correta
	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}
	
	spawned_objects[round_id][object_id] = {
		"node": item_node,
		"item_name": item_name,
		"owner_uuid": owner_uuid,
		"spawn_time": Time.get_unix_time_from_system()
	}
	
	# ✅ REGISTRA NO NETWORKMANAGER (cliente-side)
	if item_node.has_method("get_sync_config") and item_node.sync_enabled:
		network_manager.register_syncable_object(
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
	network_manager.unregister_syncable_object(object_id)
	
	_log_debug("✓ Objeto despawnado no cliente: ID=%d" % object_id)

# ===== TRATAMENTO DE ERROS =====

func _handle_connection_error(message: String):
	"""Trata erro de conexão"""
	if main_menu_node:
		main_menu_node.show_connecting_menu()
		main_menu_node.show_error_connecting(message)
	
	connection_failed.emit(message)

func _server_to_client_error(error_message: String):
	"""Callback quando recebe erro do servidor"""
	_log_debug("Erro recebido do servidor: " + error_message)
	_show_error(error_message)
	error_occurred.emit(error_message)

func _show_error(message: String, color= "Red"):
	"""Mostra erro na UI apropriada"""
	var current = main_menu_node.current_menu_visible
	_log_debug("ERRO (Em: %s): %s" % [current.name, message])
	if main_menu_node:
		if main_menu_node.connecting_menu and main_menu_node.connecting_menu.visible:
			main_menu_node._show_error_(message, main_menu_node.connecting_error_label, color)
		elif main_menu_node.room_menu and main_menu_node.room_menu.visible:
			main_menu_node._show_error_(message, main_menu_node.room_error_label, color)
		elif main_menu_node.room_list_menu and main_menu_node.room_list_menu.visible:
			main_menu_node.show_room_list_menu(true, false)
			main_menu_node._show_error_(message, main_menu_node.match_list_error_label, color)
		elif main_menu_node.manual_room_join_menu and main_menu_node.manual_room_join_menu.visible:
			main_menu_node._show_error_(message, main_menu_node.manual_room_join_error_label, color)
		elif main_menu_node.create_room_menu and main_menu_node.create_room_menu.visible:
			main_menu_node._show_error_(message, main_menu_node.create_room_error_label, color)

# ===== UTILITÁRIOS =====

func filtrar_dict_invertido(original: Dictionary) -> Dictionary:
	var comando: Array = ["round_id", "room_id", "room_name", "players"]
	var copia := original.duplicate(true)  # cópia profunda
	for chave in copia.keys():
		if not comando.has(chave):
			copia.erase(chave)
	return copia
	
func verificar_rede() -> bool:
	var peer_ = multiplayer.multiplayer_peer
	return peer_ != null and peer_.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer != null and multiplayer.has_multiplayer_peer()

func _log_debug(message: String):
	if not debug_mode:
		return
	
	var unique_id := cached_unique_id
	if unique_id == 0 and verificar_rede() and multiplayer.has_multiplayer_peer():
		unique_id = multiplayer.get_unique_id()
		cached_unique_id = unique_id
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "GameManager" in initializer.selected:
		return
	
	# Enquanto o cliente não receber id único de peer multiplayer, não exibe no log debug
	if unique_id == 1:
		print("[CLIENT][GameManager]:%s" % message)
	else:
		print("[GameManager][ClientID:%s]:%s" % [unique_id, message])
