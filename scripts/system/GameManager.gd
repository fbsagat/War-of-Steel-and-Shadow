extends Node
class_name GameManager

## GameManager - Gerenciador principal do jogo multiplayer (CLIENTE)
## Responsável por conectar ao servidor dedicado e gerenciar o fluxo do jogo

# ===== CONFIGURAÇÕES =====

@export_category("Connection Settings")
const DEFAULT_SERVER_ADDRESS: String = "172.23.2.183"  # Localhost: "127.0.0.1" zeroTier: "172.23.2.183"
const DEFAULT_SERVER_PORT: int = 7777
@export var server_address: String = DEFAULT_SERVER_ADDRESS
@export var server_port: int = DEFAULT_SERVER_PORT
## (initializer sobrepõe) Conecta automaticamente no localhost na inicialização
@export var localhost_auto_connect: bool = false

@export_category("Default Node References")
const map_scene : String = "res://scenes/system/terrain_3d.tscn"
const player_scene : String = "res://scenes/gameplay/player_warrior.tscn"
const camera_controller : String = "res://scenes/gameplay/camera_controller.tscn"
var camera_scene: PackedScene
var camera_instance: Node3D

@export_category("Debug")
@export var debug_mode: bool = true
## Ativa menu de debug visual quando true (initializer sobrepõe)
@export var visual_debug: bool = false

@export_category("Reconection Settings")
@export var reconnect_attempts :int = 0
const MAX_RECONNECT_ATTEMPTS : int = 1000
const RECONNECT_DELAY := 2.0 # segundos
var reconnect_timer: Timer

# Heartbeat (detecção)
var last_pong_time := 0
var ping_interval := 1.0
var timeout_limit := 3500 # ms
var post_loading_tolerance := 4000
var ping_start_time := 0
var has_received_pong := false
var has_timed_out := false

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
var initializer: Initializer = null

# ===== VARIÁVEIS INTERNAS =====

var is_connected_to_server: bool = false
var is_in_round: bool = false
var is_loading: bool = false # True quando está durante carregamento de um round (initializer sobrepõe)
var is_connecting: bool = false
var inventory_menu: bool = false # True se o menu de inventário estiver visível
var gameplay_menu: bool = false # True se o menu de gameplay  estiver visível
var local_peer_id: int = 0
var player_name: String = ""
var configs: Dictionary = {} # Configurações do servidor
var current_room: Dictionary = {}
var current_round: Dictionary = {}
var player_nodes_by_uuid := {}   # uuid -> Node
var session_to_uuid := {}        # session_id -> uuid
var connection_start_time: float = 0.0
var cached_unique_id: int = 0
## Objetos spawnados organizados por rodada
## {round_id: {object_id: {node: Node, item_name: String, owner_uuid: int}}}
var spawned_objects: Dictionary = {}
var local_inventory: Dictionary = {} # Inventário(de itens e equipamentos) local do player.
var debug_menu_visible: bool = false # Mostra menu de debug visual quando true (initializer sobrepõe)
var peer: ENetMultiplayerPeer

# ===== REFERÊNCIAS INTERNAS =====

var main_menu_node: Control = null
var debug_overlay_node: CanvasLayer = null
var warning_overlay_node: CanvasLayer = null
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
signal item_added(object_id: int, item_name: String, item_type: String, slot_id: int, icon_path: String)
signal item_removed(object_id: int)
signal item_equipped(object_id: int, slot_type: String)
signal item_unequipped(object_id: int)
signal items_swapped(item_id_1: int, item_id_2: int)


# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	pass

func _process(_delta):
	_ping_pong(_delta)

func initialize():
	
	connect_inventory_signals()
	connect_muiltiplayer_signals()
	setup_reconection_timer()
	
	if main_menu_node:
		main_menu_node.show_main_menu()
	
	if localhost_auto_connect:
		_log_debug("Função de testes está ativada: Entrando no servidor localhost")
		await get_tree().create_timer(0.25).timeout
		join_server_by_ip(server_address, str(server_port))
	
	# Identificação de cliente
	uuid_base = _load_or_create_uuid()
	
	# Preenche uuid do debug overlay
	if debug_overlay_node:
		debug_overlay_node.client_uuid = uuid_base
		
	server_tokens = _load_tokens()
	
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


# ===== HEARTBEAT =====

func start_heartbeat():
	_log_debug("Inicializando heartbeat")
	last_pong_time = 0
	ping_start_time = 0
	while true:
		_client_send_ping()
		await get_tree().create_timer(ping_interval).timeout

func _client_send_ping():
	if not is_connected_to_server:
		return
	
	# 1. Marca o tempo EXATO do envio neste cliente
	ping_start_time = Time.get_ticks_msec()
	
	# 2. Envia esse timestamp para o servidor
	# Certifique-se de que o servidor receba este argumento 'client_time'
	network_manager._send_ping(ping_start_time) 

func _client_receive_pong(received_timestamp: int):
	# O servidor deve devolver o 'ping_start_time' que enviamos
	has_received_pong = true
	last_pong_time = Time.get_ticks_msec()
	
	# Cálculo Correto: Tempo Agora - Tempo que saiu daqui
	var latency = last_pong_time - received_timestamp
	
	# Proteção contra drift de relógio ou pacotes muito atrasados
	if latency < 0:
		latency = 0
	
	# Envia o resultado calculado para o servidor armazenar
	network_manager._server_report_ping(latency)
	
	# Atualiza overlay local
	if debug_overlay_node:
		debug_overlay_node.update_ping(latency)
		debug_overlay_node.update_pong_time(received_timestamp)

func _ping_pong(_delta):
	# Se estiver carregando algo, não detecta perda de conexão (falsa detecção)
	if is_loading:
		return
	
	# Não começa a detectar enquanto não estiver recebido o primeiro pong
	if not has_received_pong:
		return
	
	# Se já estiver detectado a primeira vez, ignora as outras (_process está no loop)
	if has_timed_out:
		return
	
	if Time.get_ticks_msec() - last_pong_time > timeout_limit:
		has_timed_out = true
		_on_server_disconnected()

func finish_loading():
	is_loading = false
	last_pong_time = Time.get_ticks_msec() + post_loading_tolerance
	has_timed_out = false
	
	# Envia resultados de carregamento para o servidor checar integridade
	var check_this = {"current_round": current_round}
	network_manager._server_player_ready(check_this)


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

func _input(event: InputEvent) -> void:
	# Se visual_debug on, recebe debug_overlay_node
	# Esconde/mostra debug_overlay quando aperta F1
	if event.is_action_pressed("ui_debug") and debug_overlay_node:
		debug_menu_visible = not debug_menu_visible
		debug_overlay_node.visible = debug_menu_visible

# Validação
func _can_process_menu_input() -> bool:
	return is_in_round \
		and main_menu_node != null \
		and inventory_node != null

## ESC (ui_cancel)
## Prioridade: 1. Fecha inventário. 2. Fecha gameplay menu. 3. Abre gameplay menu.
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

## Inventory menu (ui_inventory)
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

## Gameplay menu
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

## Esse sinal é emitido quando o cliente consegue se conectar com sucesso ao servidor.
## Callback quando conecta com sucesso ao servidor.
func _on_connected_to_server():
	if not is_connecting:
		return

	if verificar_rede():
		# garante que o peer foi realmente configurado
		if multiplayer.has_multiplayer_peer():
			cached_unique_id = multiplayer.get_unique_id()
	
	is_connecting = false
	is_connected_to_server = true
	local_peer_id = multiplayer.get_unique_id()

	start_heartbeat()
	
	# Se visual_debug on, recebe debug_overlay_node
	# Mostra debug_overlay quando se conecta em um servidor
	if debug_overlay_node:
		debug_overlay_node.visible = true
		debug_menu_visible = true
		debug_overlay_node.peer_id = local_peer_id
	
	_log_debug(" Cliente conectado ao servidor com sucesso! Peer ID: %d" % local_peer_id)
	
	connected_to_server.emit()

## Dispara quando a tentativa de conexão falha.
func _on_connection_failed():
	_log_debug("Falha ao conectar ao servidor")

func _on_reconnect_timeout() -> void:
	if not is_connecting:
		return

	_log_debug("Tempo esgotado aguardando conexão.")

	# ❗ IMPORTANTE: limpar antes de tentar de novo
	multiplayer.multiplayer_peer = null
	peer = null
	_try_reconnect()

## Nova tentativa de conexão com o servidor
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

## Dispara quando o cliente já estava conectado, mas perde a conexão com o servidor.
## Aqui o jogo deve mostrar o menu de reconexão, se não conseguir no tempo e tentativas determinadas,
## desconecta totalmente e reseta, se conseguir, esconde a tela de reconexão e volta à partida normalmente.
func _on_server_disconnected():
	_log_debug("Conexão perdida com o servidor, tentando reconectar para voltar à partida")
	
	# Fecha conexão com o servidor
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	
	is_connected_to_server = false
	network_manager.is_connected_ = false
	has_received_pong = false
	
	# Inicia processo de reconexão
	# Mostra menu de reconexão
	if main_menu_node:
		main_menu_node.show_main_menu()
		main_menu_node.show_connecting_menu()
		main_menu_node.show_error_connecting("Conexão perdida. Tentando reconectar...")
	
	start_connection_attempts(server_address, server_port)

func start_connection_attempts(address: String, port: int) -> void:
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
	local_peer_id = peer.get_unique_id()
	_log_debug("Conseguiu reconectar, novo peer id: %s" % peer.get_unique_id())
	
	if is_in_round or round_node:
		# Envia resultados de carregamento para o servidor checar integridade
		var check_this = {"current_round": current_round}
		network_manager._server_player_ready(check_this)

	# Se o servidor estiver offline, o resultado real virá por signal
	# Este timer serve como fallback caso a rede demore demais
	reconnect_timer.start(RECONNECT_DELAY)

func _on_reconnect_gave_up() -> void:
	_disconnect_from_server()
	if main_menu_node:
		main_menu_node.show_main_menu()

	_log_debug("Conexão perdida permanentemente.")

## Dispara quando o cliente quer desconectar do servidor intencionalmente
## Aqui o jogo deve retornar para a tela inicial, desconectado do servidor, tudo resetado e sem 
## possibilidade de o cliente retornar ao round em que estava
## notify = avisa o servidor.
func _disconnect_from_server(notify_server: bool = false):
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
	has_received_pong = false
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
	
	# Se visual_debug on, recebe debug_overlay_node
	# Esconde debug_overlay quando desconexão é intencional
	if debug_overlay_node:
		debug_overlay_node.on_disconnected()
		debug_overlay_node.visible = false
		debug_menu_visible = false
	
	# Emite sinal
	disconnected_from_server.emit()

## Validar IP/hostname
func join_server_by_ip(received_ip: String, received_port: String) -> bool:
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
	
	if is_connected_to_server:
		_log_debug("Já conectado ao servidor")
		return false
	
	if is_connecting:
		_log_debug("Já está tentando conectar")
		return false
	
	_log_debug("Tentando conectar ao servidor: %s:%d" % [server_address, server_port])
	
	if main_menu_node:
		main_menu_node.show_loading_menu("Conectando ao servidor...")
		
	start_connection_attempts(server_address, server_port)
	return true

## Validar localhost
func _is_valid_address(address: String) -> bool:

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

## Gera identidade persistente do cliente.
## Nunca muda após criação.
func _load_or_create_uuid() -> String:
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

## Salva apenas os tokens mais recentes.
## Mantém no máximo MAX_SAVED_TOKENS entradas.
## Funciona com Dictionary simples:
## {
##     "server_id": "token"
## }
func _save_tokens() -> void:
	# Se exceder limite, remove os mais antigos
	while server_tokens.size() > MAX_SAVED_TOKENS:
		# Pega a primeira chave inserida (mais antiga)
		var oldest_key = server_tokens.keys()[0]
		server_tokens.erase(oldest_key)
	
	var file = FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	file.store_string(JSON.stringify(server_tokens))
	file.close()

## Processa resposta do servidor.
## Salva novo token se necessário.
func handle_server_response(response: Dictionary) -> void:
	var status = response["status"]

	match status:
		"new_token":
			var sid = response["server_id"]
			server_tokens[sid] = response["token"]
			_save_tokens()
			if main_menu_node:
				main_menu_node.show_name_input_menu(true)

		"ok", "ok_in_round":
			has_timed_out = false
			player_name = response["player_name"]

			var in_round = status == "ok_in_round"
			_log_debug(
				"Autenticado com sucesso e retornando ao round"
				if in_round
				else "Autenticado com sucesso, server reiniciou, retornando ao menu"
			)

			if in_round and is_in_round:
				_client_update_character_peer_id(uuid_base, local_peer_id)
				if main_menu_node:
					main_menu_node.hide_main_menu()
				return
			
			# Se a response for "ok"
			_cleanup_local_round()
			if main_menu_node:
				if player_name == "":
					main_menu_node.show_name_input_menu(true)
				else:
					main_menu_node.update_name_e_connected(configs["server_name"], player_name)
					main_menu_node.show_main_menu()

		"reject":
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

func _on_gameplay_menu_give_up_game_pressed():
	_cleanup_local_round()
	network_manager._server_request_return_or_exit(false)
	
	# Volta para o menu da sala
	if main_menu_node:
		main_menu_node.show_main_menu()


# ===== ATUALIZAÇÃO DE CONFIGURAÇÕES =====

## Atualiza configurações do servidor para o cliente
func update_client_info(info: Dictionary):
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

## Criar uma partida local
func create_local_match():
	_log_debug("Iniciando uma partida local")
	# Executar build do servidor.
	#var server_pid := -1
	#var server_path = ProjectSettings.globalize_path("res://server/server.exe")
	#server_pid = OS.create_process(server_path, ["--port", "7777"])

# ===== REGISTRO DE JOGADOR =====
	
## Envia nome do jogador para registro no servidor
func set_player_name(p_name: String):
	if not is_connected_to_server:
		main_menu_node._show_error_("Não conectado ao servidor", main_menu_node.name_input_error_label, "Red")
		return
	
	_log_debug("Tentando registrar nome: " + p_name)
	
	if main_menu_node:
		main_menu_node.show_loading_menu("Registrando jogador...")
	
	network_manager.register_player_name(p_name)

## Callback quando o nome é aceito pelo servidor
func _client_name_accepted(accepted_name: String):
	player_name = accepted_name
	_log_debug("Nome aceito pelo servidor: " + player_name)
	
	if main_menu_node:
		main_menu_node.update_name_e_connected(configs["server_name"], accepted_name)
		
	name_accepted.emit()

## Callback quando o nome é rejeitado
func _client_name_rejected(reason: String):
	_log_debug("Nome rejeitado: " + reason)
	
	if main_menu_node:
		# Se player_name for "", é tela de welcome, se já ter algum nome definido, tela de renomeação 
		var condition = true if player_name == "" else false
		main_menu_node.show_name_input_menu(condition)
		main_menu_node._show_error_(reason, main_menu_node.name_input_error_label, "Red")
	
	name_rejected.emit(reason)


# ===== GERENCIAMENTO DE SALAS =====

## Callback quando a senha está incorreta
func _client_wrong_password():
	var current_menu_visible_name = main_menu_node.current_menu_visible.name
	main_menu_node.room_list_menu.visible = true
	
	if main_menu_node and current_menu_visible_name == "RoomListMenu":
		main_menu_node._show_error_("Senha incorreta", main_menu_node.match_list_error_label, "Red")
		main_menu_node.show_room_list_menu(true, true)

	if main_menu_node and current_menu_visible_name == "ManualRoomJoinMenu":
		main_menu_node._show_error_("Senha incorreta", main_menu_node.manual_room_join_error_label, "Red")
		main_menu_node.show_manual_room_join_menu(true)

## Callback de quando existe um erro com o nome da sala
func _client_room_name_error(error_msg : String):
	if main_menu_node:
		main_menu_node.show_create_match_menu()
		main_menu_node._show_error_(error_msg, main_menu_node.create_room_error_label, "Red")

## Callback quando a sala não é encontrada
func _client_room_not_found():
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
	
## Callback quando recebe lista de salas, requisitado pelo cliente
func _client_receive_rooms_list(rooms: Array):
	rooms_list_received.emit(true, rooms)

## Cliente recebe requisição do servidor para retornar à partida onde estava ou abandonar
func _client_receive_round_return_request(_room_name: String):
	_log_debug("Recebendo requisição do servidor para retornar à prtid onde estava: %s" % _room_name)
	if main_menu_node:
			main_menu_node.show_round_return_menu(_room_name)

## Cliente envia resposta dizendo que quer voltar à partida em que estava
func _request_return_to_round():
	is_loading = true
	network_manager._server_request_return_or_exit(true)

## Cliente envia resposta dizendo que quer abandonar a partida em que estava
func _request_exit_from_round():
	network_manager._server_request_return_or_exit(false)

## Callback quando recebe atualização de lista de salas por prte do servidor(não requisitado)
func all_client_receive_rooms_list(rooms: Array):
	_log_debug("Lista de salas atualizada: %d salas" % rooms.size())
	
	# Ignora se não estiver na lista de salas
	if not main_menu_node.current_menu_visible.name == "RoomListMenu":
		return
	rooms_list_received.emit(true, rooms)

## Cria uma nova sala
func create_room(room_name: String, password: String = ""):
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

## Callback quando sala é criada com sucesso
func _client_room_created(room_data: Dictionary):
	current_room = room_data
	_log_debug(" Sala criada com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu_node:
		main_menu_node.show_room_menu(room_data)
	
	room_created.emit(room_data)

## Entra em uma sala por ID
func join_room(room_id: int, password: String = ""):
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

## Entra em uma sala por nome
func join_room_by_name(room_name: String, password: String = ""):
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

## Callback quando entra em uma sala com sucesso
func _client_joined_room(room_data: Dictionary):
	current_room = room_data
	_log_debug("Entrou na sala com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu_node:
		main_menu_node.show_room_menu(room_data)
	
	joined_room.emit(room_data)

## Callback quando a sala é atualizada
func _client_room_updated(room_data: Dictionary):
	current_room = room_data
	_log_debug("Sala atualizada: %s (%d jogadores)" % [room_data["name"], room_data["players"].size()])
	
	#if main_menu:
		#main_menu._update_room_display(room_data)
	
	room_updated.emit(room_data)

## Envia pedido para expulsar um player da sala (somente para o host)
func kick_player_from_room(_selected_player_id: String):
	if is_in_round:
		return
	
	# Verificação local se é o host (add redundancia)
	var host_uuid = -1
	var _player_name: String
	
	for player in current_room["players"]:
		if player.get("uuid_base") == _selected_player_id:
			_player_name = player["name"]
	
	for player in current_room["players"]:
		if player.get("is_host", false):
			host_uuid = player["uuid_base"]
	if host_uuid == uuid_base:
		network_manager.kick_player_from_room(_selected_player_id)
		_log_debug("Pedido para expulsar player, id: %s feito ao servidor" % _selected_player_id)

## Recebe notificação do servidor de que foi expulso da sala em que está
func _client_kicked_from_room():
	var name_room = current_room["name"]
	current_room = {}
	
	if main_menu_node:
		main_menu_node.show_main_menu()
		main_menu_node.show_room_list_menu(true, false)
		main_menu_node._show_error_("Você foi expulso da sala %s" % name_room, main_menu_node.match_list_error_label, "Red")
	
	# Se estiver em uma partida, sair e limpar tudo
	_cleanup_local_round()

## Sai da sala atual
func leave_room():
	if is_in_round:
		return
		
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	_log_debug("Saindo da sala: %s" % current_room["name"])
	network_manager.leave_room()
	current_room = {}

## Fecha a sala atual (apenas host)
func close_room():
	if is_in_round:
		return
	
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_uuid"] != uuid_base:
		return
	
	_log_debug("Fechando sala: %s" % current_room["name"])
	network_manager.close_room()
	current_room = {}
	if main_menu_node:
		main_menu_node.show_room_list_menu(true, false)

## Callback quando a sala é fechada
func _client_room_closed(reason: String):
	_log_debug("Sala fechada: " + reason)
	current_room = {}
	
	if main_menu_node:
		main_menu_node._show_error_(reason, main_menu_node.match_list_error_label, "Red")
		main_menu_node.show_room_list_menu(true)

## Envia ao servidor as configurações modificadas (apenas elas).
## Compara com match_settings atual e envia somente o diff.
func request_update_settings(new_values: Dictionary) -> void:
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

## Callback que atualiza apenas as configurações modificadas.
func client_update_match_settings(changed_settings: Dictionary) -> void:
	for key in changed_settings.keys():
		room_settings[key] = changed_settings[key]
	
	# Verificar se é host; se sim, atualizar o botão de 
	var host_uuid = current_room.get("host_uuid", -1)
	if host_uuid == uuid_base:
		if room_settings["locked"] == true:
			main_menu_node.room_lock_button.text = "Liberar Sala"
			main_menu_node._show_error_("Sala trancada, ninguém entra!", main_menu_node.room_error_label, "Yellow")
		else:
			main_menu_node.room_lock_button.text = "Trancar Sala"
			main_menu_node._show_error_("Sala liberada, chama a glr!", main_menu_node.room_error_label, "Yellow")


# ===== GERENCIAMENTO DE RODADAS =====

## Inicia uma nova rodada (apenas host, que irá solicitar início da rodada)
func start_round(round_settings: Dictionary = {}):
	if is_in_round:
		return
	
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_uuid"] != uuid_base:
		return
	
	if current_room.players.size() < configs.min_players_to_start:
		main_menu_node._show_error_("Pelo menos %d jogadores são necessários para iniciar uma rodada" % 1, main_menu_node.room_error_label, "Yellow")
		return
	
	_log_debug("Solicitando início da rodada...")
	is_loading = true
	network_manager._server_request_start_round(round_settings)

## Callback quando a rodada termina.
func _client_round_ended(end_data: Dictionary):
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

## Callback quando a rodada inicia pela primeira vez.
func _client_round_started(server_id: String, match_data: Dictionary) -> void:
	_log_debug("Rodada iniciada pelo servidor!")
	#print("[pp]  -------------------- _client_round_started --------------------")
	#initializer.pretty_print_dict(match_data)
	#print("[pp]  -------------------- pp End --------------------")
	await _load_round(server_id, match_data, false)

## Callback quando o jogador retorna a uma rodada em andamento.
func _client_round_return(server_id: String, match_data: Dictionary) -> void:
	_log_debug("Retornando à rodada.")
	#print("[pp]  -------------------- _client_round_return --------------------")
	#initializer.pretty_print_dict(match_data)
	#print("[pp]  -------------------- pp End --------------------")
	await _load_round(server_id, match_data, true)

## Carrega a rodada localmente no cliente.
## [param server_id] ID do servidor que originou a rodada.
## [param match_data] Dados da partida recebidos do servidor, mantidos intactos.
## [param is_return] Se [code]true[/code], restaura estado de uma rodada em andamento.
func _load_round(server_id: String, match_data: Dictionary, is_return: bool) -> void:
	_log_debug("========================================")
	_log_debug("RETORNANDO À RODADA" if is_return else "INICIANDO RODADA")
	_log_debug("Sala: ID %d" % match_data["room_id"])
	_log_debug("Rodada: ID %d" % match_data["round_id"])
	_log_debug("Mapa: %s" % match_data["map_scene"])
	_log_debug("Jogadores participantes:")

	for player: Dictionary in match_data["players"]:
		var is_host: String  = " [HOST]"  if player["is_host"]      else ""
		var is_me: String    = " [ME]"    if player["uuid_base"] == uuid_base else ""
		_log_debug("- %s (ID: %s)%s%s" % [player["name"], player["uuid_base"], is_host, is_me])

	_log_debug("========================================")

	await get_tree().process_frame

	# Cria o nó organizador da rodada
	round_node = preload("res://scripts/utils/round_node.gd").new()
	round_node.name      = "Round"
	round_node.round_id  = match_data["round_id"]
	round_node.room_id   = match_data["room_id"]
	round_node.server_id = server_id

	get_tree().root.add_child(round_node)

	await get_tree().process_frame

	# Cria nós organizacionais filhos do round
	players_node        = Node.new()
	players_node.name   = "Players"
	round_node.add_child(players_node)

	objects_node        = Node.new()
	objects_node.name   = "Objects"
	round_node.add_child(objects_node)

	await get_tree().process_frame
	
	# Inicializa inventário do player local
	init_player_inventory()
	
	# ===== CARREGAMENTO ASSÍNCRONO DO INVENTÁRIO =====
	_log_debug("📦 [LOCAL] Carregando cena do inventário...")
	
	var inventory_scene: PackedScene = load("res://scenes/ui/inventory_menu.tscn")
	if not inventory_scene:
		push_error("[LOCAL] Falha ao carregar inventory_menu.tscn")
		return
	
	var inventory_node_: Node = inventory_scene.instantiate()
	if not inventory_node_:
		push_error("[LOCAL] Falha ao instanciar inventory_menu.tscn")
		return
	
	# Adiciona à cena
	round_node.add_child(inventory_node_)
	
	# Aguarda estar na árvore
	var tree_timeout = 60
	var tree_waited = 0
	while not inventory_node_.is_inside_tree() and tree_waited < tree_timeout:
		await get_tree().process_frame
		tree_waited += 1
	
	if not inventory_node_.is_inside_tree():
		push_error("[LOCAL] Inventory node não foi adicionado à árvore!")
		inventory_node_.queue_free()
		return
	
	inventory_node = inventory_node_
	inventory_node.game_manager = self
	inventory_node.initializer = initializer
	
	# Aguarda ready do inventário
	if inventory_node.has_method("_ready"):
		var ready_timeout = 60
		var ready_waited = 0
		while not inventory_node.is_node_ready() and ready_waited < ready_timeout:
			await get_tree().process_frame
			ready_waited += 1
		
		if ready_waited >= ready_timeout:
			push_warning("[LOCAL] Timeout aguardando _ready() do inventário")
	
	# Configura sinais
	inventory_node.setup_inventory_signals()
	
	# Instancia e adiciona a câmera à cena
	camera_scene    = preload(camera_controller)
	camera_instance = camera_scene.instantiate()
	players_node.add_child(camera_instance)

	await get_tree().process_frame

	# Carrega o mapa e aplica suas configurações
	await map_manager.load_map(match_data["map_scene"], round_node, camera_instance.camera)
	await map_manager.apply_map_configs(match_data["settings"])
	
	# Filtra e armazena os dados relevantes da rodada atual
	var filtered_match_data: Dictionary = filter_match_data(match_data)
	current_round = filtered_match_data
	
	# Spawna todos os jogadores da partida
	for player_data: Dictionary in match_data["players"]:
		var is_local: bool = player_data["uuid_base"] == uuid_base
		await _spawn_player(player_data, is_local, match_data)

	await get_tree().process_frame

	# Etapas exclusivas do retorno: restaura estado da rodada em andamento
	if is_return:
		await _restore_round_state(match_data)

	# Esconde o menu principal
	if main_menu_node:
		main_menu_node.hide_main_menu()

	# Sinaliza ao servidor que o jogador reconectou (apenas no retorno)
	if is_return:
		_unmark_player_disconnected()

	finish_loading()
	await get_tree().process_frame
	
	round_started.emit()
	is_in_round = true
	_log_debug("Rodada %s no cliente." % ("recarregada" if is_return else "carregada"))

## Restaura o estado da rodada ao reconectar: equipamentos, inventário e objetos no mapa.
## [param match_data] Dados completos da partida recebidos do servidor.
func _restore_round_state(match_data: Dictionary) -> void:
	# Restaura visuais de equipamentos para cada jogador
	for uuid in player_nodes_by_uuid.keys():
		var player_node = player_nodes_by_uuid.get(uuid)
		
		for player_uuid in match_data["equipped_items"]:
			var slots: Dictionary = match_data["equipped_items"][uuid]
			
			for slot_name in slots:
				var item: Dictionary = slots[slot_name]
				
				if item.is_empty():
					continue
				
				var item_id = item.get("item_id")
				var object_id = item.get("object_id")

				# Jogador local: registra no inventário e equipa o item
				if uuid == uuid_base:
					var item_name: String = item_database.get_item_by_id(int(item_id))["name"]
					add_item_to_inventory(item_id, object_id)
					equip_item(object_id, "", item_name)

				# Todos aplicam o visual no nó do personagem (local e remoto)
				if player_node.has_method("apply_visual_equip_on_player_node"):
					player_node.apply_visual_equip_on_player_node(item_id)

	# Restaura itens no inventário do jogador local que não estão equipados
	for item: Dictionary in match_data["player_items"]:
		add_item_to_inventory(item["item_id"], item["object_id"])

	await get_tree().process_frame

	# Spawna os objetos presentes na rodada com suas posições e atributos atuais
	for object_id: Variant in match_data["round_objects"]:
		var item: Dictionary = match_data["round_objects"][object_id]
		_spawn_on_client(
			object_id,
			item["round_id"],
			item["item_name"],
			item["position"],
			item["rotation"],
			item["drop_velocity"],
			item["owner_uuid"]
		)

	await get_tree().process_frame

## Spawna players para cada cliente.
## Cada cliente recebe X execuções: a do seu jogador local e a do(s) jogador(es) remoto(s).
## is_local = true → jogador local | is_local = false → jogador remoto
func _spawn_player(player_data: Dictionary, is_local: bool, _match_data: Dictionary):
	
	# VALIDAÇÕES INICIAIS
	if not player_data.has("uuid_base") or not player_data.has("name") or not player_data.has("peer_id"):
		push_error("GameManager: player_data inválido: faltam campos obrigatórios")
		return
	
	if not _match_data.has("settings") or not _match_data["settings"].has("spawn_points"):
		push_error("GameManager: _match_data sem spawn_points válidos")
		return
	
	var player_name_ = player_data["uuid_base"]
	var camera_name = player_name_ + "_Camera"
	var peer_id = player_data["peer_id"]
	var player_uuid = player_data["uuid_base"]
	var player_display_name = player_data["name"]
	
	_log_debug("🔄 [Spawn] Iniciando spawn: %s (Session: %s, Local: %s)" % [
		player_display_name, peer_id, "SIM" if is_local else "NÃO"
	])
	
	# VERIFICA DUPLICAÇÃO
	if players_node.has_node(player_name_):
		_log_debug("⚠️ [Spawn] Player já existe: %s" % player_name_)
		return
	
	if players_node.has_node(camera_name):
		_log_debug("⚠️ [Spawn] Câmera já existe: %s" % camera_name)
		return
	
	# VALIDA NÓS NECESSÁRIOS
	if not players_node:
		push_error("GameManager: players_node é null!")
		return
	
	if is_local and not camera_instance:
		push_error("GameManager: camera_instance é null para jogador local!")
		return
	
	# CARREGAMENTO DA CENA
	_log_debug("📦 [Spawn] Carregando cena do player: %s" % player_scene)
	
	var player_scene_ = preload(player_scene)
	if not player_scene_:
		push_error("GameManager: Falha ao carregar player_scene: %s" % player_scene)
		return
	
	# INSTANCIAÇÃO
	var player_instance = player_scene_.instantiate()
	if not player_instance:
		push_error("GameManager: Falha ao instanciar player_scene")
		return
	
	_log_debug("✓ [Spawn] Cena instanciada com sucesso")
	
	# INJEÇÃO DE DEPENDÊNCIAS (PRÉ-ÁRVORE)
	_log_debug("💉 [Spawn] Injetando dependências...")
	
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.initializer = initializer
	player_instance.game_manager = self
	
	# ADIÇÃO À ÁRVORE DE CENA
	_log_debug("🌳 [Spawn] Adicionando player à cena...")
	
	players_node.add_child(player_instance)
	# Aguarda o player estar na árvore com timeout
	var tree_timeout = 60  # ~1 segundo
	var tree_waited = 0
	
	# Adiciona nó no cachê de personagens para fácil acesso
	player_nodes_by_uuid[player_name_] = player_instance
	session_to_uuid[peer_id] = player_name_
	
	while not player_instance.is_inside_tree() and tree_waited < tree_timeout:
		await get_tree().process_frame
		tree_waited += 1
	
	if not player_instance.is_inside_tree():
		push_error("GameManager CRÍTICO: Player %s não foi adicionado à árvore após %d frames!" % [player_uuid, tree_timeout])
		player_instance.queue_free()
		return
	
	_log_debug("✓ [Spawn] Player adicionado à árvore de cena")
	
	# AGUARDA READY COM TIMEOUT
	if player_instance.has_method("_ready"):
		_log_debug("⏳ [Spawn] Aguardando _ready() do player...")
		
		var ready_timeout = 120  # ~2 segundos
		var ready_waited = 0
		
		while not player_instance.is_node_ready() and ready_waited < ready_timeout:
			await get_tree().process_frame
			ready_waited += 1
		
		if ready_waited >= ready_timeout:
			push_warning("⚠️ [Spawn] Timeout aguardando _ready() do player %s, continuando..." % player_uuid)
		else:
			_log_debug("✓ [Spawn] Player está ready!")
	else:
		_log_debug("ℹ️ [Spawn] Player não tem _ready(), pulando espera")
		await get_tree().process_frame
		await get_tree().process_frame
	
	# INICIALIZAÇÃO DO JOGADOR
	_log_debug("🔧 [Spawn] Inicializando dados do player...")
	
	var color: Color = Color(0.0, 0.0, 0.0, 1.0)
	var final_color = player_data["character"]["color"] if player_data["character"]["color"] else color

	player_instance.initialize(
		false, # is_server
		is_local,
		player_data["name"], 
		final_color, 
		peer_id, 
		player_uuid,
	)
	
	# Posiciona
	var player_pos = _match_data["settings"]["spawn_points"][player_data["uuid_base"]]
	if not player_pos:
		push_error("GameManager: Spawn point não encontrado para player: %s" % uuid_base)
		player_pos = {"position": Vector3.ZERO, "rotation": Vector3.ZERO}
	player_instance.positionate(player_pos["position"], player_pos["rotation"])
	
	# Aguarda processamento da inicialização
	await get_tree().process_frame
	
	# CONFIGURAÇÃO ESPECÍFICA POR TIPO DE JOGADOR
	if is_local:
		_setup_local_player(player_instance, camera_name, player_pos)
	else:
		_setup_remote_player(player_instance, player_name_, player_pos)
	
	_log_debug("✅ [Spawn] Player spawnado com sucesso: %s (Local: %s)" % [
		player_display_name, "SIM" if is_local else "NÃO"
	])


# ===== FUNÇÕES AUXILIARES DE SETUP =====

## Configurações específicas para jogador LOCAL
func _setup_local_player(player_instance: Node, camera_name: String, player_pos: Dictionary) -> void:
	_log_debug("🎮 [LOCAL] Configurando jogador local...")
	
	# Configura câmera
	if camera_instance:
		camera_instance.name = camera_name
		camera_instance.target = player_instance
		_log_debug("  - Câmera configurada: %s" % camera_name)
	else:
		push_error("[LOCAL] camera_instance é null!")

	_log_debug("  - Inventário inicializado")
	
	# Configura sinais e referências do inventário
	inventory_node.player_node = player_instance
	player_instance.inventory_node = inventory_node
	player_instance.connect_inventory_signals()
	
	_log_debug("  - Inventário configurado e sinais conectados")
	
	# Atribui câmera ao player
	if camera_instance:
		player_instance.camera_controller = camera_instance
		camera_instance.set_as_active()
		_log_debug("  - Câmera ativa")
	else:
		push_error("[LOCAL] camera_instance é null após setup!")
	
	# Ativa controle local
	player_instance.set_as_local_player()
	local_player_node = player_instance
	
	# Adiciona aos grupos
	player_instance.add_to_group("player")
	player_instance.add_to_group("myself_player")
	
	_log_debug("✓ [LOCAL] Jogador local configurado: %s em %s" % [
		player_instance.player_name,player_pos["position"]
	])

## Configurações específicas para jogador REMOTO.
func _setup_remote_player(player_instance: Node, player_name_: String, player_pos: Dictionary) -> void:
	_log_debug("🌐 [REMOTO] Configurando jogador remoto...")
	
	# Jogador remoto: NÃO tem câmera atribuída
	player_instance.camera_controller = null
	
	# Adiciona aos grupos
	player_instance.add_to_group("player")
	player_instance.add_to_group("remote_player")
	
	_log_debug("✓ [REMOTO] Jogador remoto configurado: %s em %s" % [
		player_name_,
		player_pos["position"]
	])

## Teleporta o jogador local para uma posição específica definida pelo servidor.
## @param pos: Vector3 contendo a nova coordenada global de destino.
func server_force_position(pos: Vector3):
	if local_player_node and is_in_round:
		local_player_node._respawn_player(pos)
		_log_debug("Jogador local teleportado pelo servidor para a posição: %s" % pos)

## Callback quando deve retornar à sala.
func _client_return_to_room(room_data: Dictionary):
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

## Limpa o nó do cliente que se desconectou, esta função é para os outros 
## que estão conectados
func _client_remove_player(peer_uuid : String):
	if peer_uuid and players_node and uuid_base != peer_uuid:
		var player_node = player_nodes_by_uuid.get(peer_uuid)
		if player_node:
			player_node.queue_free()
			player_nodes_by_uuid.erase(peer_uuid)

## Atualiza o id de sessão do cliente remoto reconectado no round para manutenção de sincronia, 
## isso acontece nos clientes que ainda estão no round e é executado apenas para remotos de outros players
func _client_update_character_peer_id(remote_uuid_base: String, remote_new_peer_id: int):
	_log_debug("👤 Atualizando session id de remoto: %s para %d" % [remote_uuid_base, remote_new_peer_id])
	
	# Se não ter um round carregado ignora, vai receber atualizado quando carregar com _client_round_return
	if not players_node:
		return
	
	# limpa session antiga (se existir)
	for s_id in session_to_uuid.keys():
		if session_to_uuid[s_id] == remote_uuid_base:
			session_to_uuid.erase(s_id)
			break
	
	# registra nova sessão
	session_to_uuid[remote_new_peer_id] = remote_uuid_base
	
	# recupera node existente
	var node = player_nodes_by_uuid.get(remote_uuid_base)
	
	# Muda session id do nó
	node.peer_id = remote_new_peer_id
	
	# Atualiza novo session id no debug overlay
	#if debug_overlay_node:
		#debug_overlay_node.peer_id = _new_peer_id
	
	# Atualiza o nome de debug (que exibe o id de sessão atual)
	if visual_debug:
		var ziped_uuid: String = initializer._zip_uuid(remote_uuid_base)
		node.name_label.text = "%s\n%s\n%s" % [node.player_name, ziped_uuid, remote_new_peer_id]
	
	# Pega o node e muda a autoridade multiplayer
	node.set_multiplayer_authority(remote_new_peer_id)
	_log_debug("👤 Session id de remoto atualizado com sucesso para %s" % remote_new_peer_id)

## Limpa todos os objetos da rodada no cliente.
func _cleanup_local_round():
	_log_debug("Limpando objetos da rodada...")
	is_loading = true
	local_player_node = null
	is_in_round = false
	inventory_menu = false
	gameplay_menu = false
	
	# Limpa cachê de nodes de personagens da partida
	player_nodes_by_uuid.clear()
	session_to_uuid.clear()
	
	# Limpa objetos spawnados
	for obj in spawned_objects.keys():
		for object_id in spawned_objects[obj].keys():
			var obj_data = spawned_objects[obj][object_id]
			var item_node = obj_data.get("node")
			
			if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
				item_node.queue_free()
		await get_tree().process_frame
	
	spawned_objects.clear()
	
	if round_node:
		round_node.queue_free()
		
	finish_loading()
	_log_debug("✓ Limpeza completa")

## Sinaliza para o servidor como desconectado durante a rodada.
func _mark_player_disconnected():
	network_manager._mark_player_disconnected(true)

## Sinaliza para o servidor como reconectado durante a rodada.
func _unmark_player_disconnected():
	network_manager._mark_player_disconnected(false)


# ===== SISTEMA DE INVENTÁRIO POR RODADA =====
	
## Inicializa inventário do jogador em uma rodada específica
func init_player_inventory() -> bool:
	
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

## Adiciona item ao inventário do jogador
func add_item_to_inventory(item_id: int, object_id: int) -> bool:
	if local_inventory["inventory"].size() >= 9:
		_log_debug("⚠ Inventário deste player cheio")
		return false
	
	# Valida item no ItemDatabase se disponível
	if item_database and not item_database.item_exists_by_id(item_id):
		push_error("ClientRegistry: Item inválido: %s" % item_id)
		return false
	
	var item_name = item_database.get_item_by_id(item_id)["name"]
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

## Remove item do inventário pelo object_id
func remove_item_from_inventory(object_id: int) -> bool:
	if local_inventory["inventory"].is_empty():
		return false
	
	var idx = local_inventory["inventory"].find_custom(func(item): return item["object_id"] == object_id)
	
	if idx == -1:
		_log_debug("⚠ Item com object_id %d não encontrado no inventário" % object_id)
		return false
	
	var item_id = local_inventory["inventory"][idx]["item_id"]
	var item_name = item_database.get_item_by_id(int(item_id))["name"]
	local_inventory["inventory"].remove_at(idx)
	
	item_removed.emit(str(object_id))
	
	_log_debug("✓ Item removido por object_id: %d (%s)" % [object_id, item_name])
	
	return true

## Equipa item em um slot (detecta automaticamente se não especificado)
## Slots válidos: hand-right, hand-left, head, body, back
func equip_item(object_id: int, item_slot: String = "", item_name: String = "") -> bool:
	if local_inventory["inventory"].is_empty():
		return false
	
	# Procura o item no inventário
	var item_data: Dictionary = {}
	var item_idx = local_inventory["inventory"].find_custom(func(item): return item["object_id"] == object_id)
	item_data = local_inventory["inventory"][item_idx]
	
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

## Desequipa item de um slot e retorna ao inventário.
func unequip_item(_object_id: int, item_slot: String, verify: bool = true) -> bool:
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

## Troca item equipado diretamente (desequipa antigo, equipa novo).
##   - Não emite sinais intermediários de equip/unequip.
##   - Mantém ambos os itens no inventário/equipamento.
##   - Emite apenas items_swapped no final.
func swap_equipped_item(new_item_name: String, dragged_item: Dictionary, existing_item_id: int, target_slot: String) -> bool:
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
	var new_item_idx = local_inventory["inventory"].find_custom(func(item): return item["object_id"] == dragged_item["object_id"])
	
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
	
	items_swapped.emit(str(dragged_item["object_id"]), str(existing_item_id))
	
	return true

## Limpa inventário do jogador em uma rodada.
func clear_player_inventory():
	local_inventory.clear()
	_log_debug("✓ Inventário limpo")


# ===== SPAWN DE OBJETOS =====

## Spawna objeto no cliente (chamado via RPC).
func _spawn_on_client(object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_uuid: String):
	if not round_node:
		return
	
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
	item_node.is_server = false
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

## Remove um objeto do cliente. Este método é invocado via RPC quando o servidor solicita o despawn.
func _despawn_on_client(object_id: int, round_id: int):
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

## Trata erros de conexão, exibindo menus de erro e notificando falha na conexão.
func _handle_connection_error(message: String):
	if main_menu_node:
		main_menu_node.show_connecting_menu()
		main_menu_node.show_error_connecting(message)
	
	connection_failed.emit(message)

## Recebe e processa mensagens de erro enviadas pelo servidor para o cliente.
func _server_to_client_error(error_message: String):
	_show_error(error_message)

## Callback executado ao receber mensagens de informação do servidor.
## Suporta os tipos: 'info', 'success', 'warning' e 'error'.
func _server_to_client_message(text: String, duration: float = 3.0, type: String = "info"):
	_log_debug("Mensagem recebida do servidor: " + text)
	if warning_overlay_node:
		warning_overlay_node.show_message(text, duration, type)
	else:
		push_error("Warning_overlay_node não existe no game manager")

## Localiza o menu atual e exibe uma mensagem de erro visualmente destacada para o jogador.
func _show_error(message: String, color= "Red"):
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
	error_occurred.emit(message)


# ===== UTILITÁRIOS =====

## Retorna uma cópia do dicionário contendo apenas as chaves permitidas (round_id, room_id, etc).
func filter_match_data(original: Dictionary) -> Dictionary:
	var comando: Array = ["round_id", "room_id", "room_name", "players"]
	var copia := original.duplicate(true)  # cópia profunda
	for chave in copia.keys():
		if not comando.has(chave):
			copia.erase(chave)
	return copia

## Verifica se o peer multiplayer está ativo e com status de conexão estabelecida.
func verificar_rede() -> bool:
	var peer_ = multiplayer.multiplayer_peer
	return peer_ != null and peer_.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer != null and multiplayer.has_multiplayer_peer()

## Registra mensagens no console de debug, incluindo o ID único do cliente para facilitar o rastreamento.
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
