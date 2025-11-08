extends Node
## GameManager - Gerenciador principal do jogo multiplayer (CLIENTE)
## Responsável por conectar ao servidor dedicado e gerenciar o fluxo do jogo

# ===== CONFIGURAÇÕES (Editáveis no Inspector) =====

## Endereço do servidor dedicado
@export var server_address: String = "127.0.0.1"

## Porta do servidor dedicado
@export var server_port: int = 7777

## Tempo máximo de espera para conexão (segundos)
@export var connection_timeout: float = 10.0

## Ativar logs de debug detalhados
@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

## Referência para a UI principal
var main_menu: Control = null

## Estado da conexão com o servidor
var is_connected_to_server: bool = false

## ID do peer local (cliente)
var local_peer_id: int = 0

## Nome do jogador local
var player_name: String = ""

## Sala atual em que o jogador está
var current_room: Dictionary = {}

## Tempo de tentativa de conexão
var connection_start_time: float = 0.0

## Flag para verificar se está tentando conectar
var is_connecting: bool = false

# ===== SINAIS =====

## Emitido quando conecta com sucesso ao servidor
signal connected_to_server()

## Emitido quando falha ao conectar ao servidor
signal connection_failed(reason: String)

## Emitido quando desconecta do servidor
signal disconnected_from_server()

## Emitido quando recebe a lista de salas
signal rooms_list_received(rooms: Array)

## Emitido quando entra em uma sala com sucesso
signal joined_room(room_data: Dictionary)

## Emitido quando a sala é criada com sucesso
signal room_created(room_data: Dictionary)

## Emitido quando ocorre um erro
signal error_occurred(error_message: String)

## Emitido quando o nome é aceito pelo servidor
signal name_accepted()

## Emitido quando o nome é rejeitado
signal name_rejected(reason: String)

## Emitido quando atualiza a sala (novo jogador entrou/saiu)
signal room_updated(room_data: Dictionary)

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	# Verifica se é servidor dedicado
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_log_debug("GameManager detectou modo servidor - não inicializando cliente")
		return
	
	_log_debug("GameManager inicializado (Cliente)")
	
	# Configura callbacks de rede
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(delta):
	# Verifica timeout de conexão
	if is_connecting:
		if Time.get_ticks_msec() / 1000.0 - connection_start_time > connection_timeout:
			_log_debug("Timeout de conexão excedido")
			is_connecting = false
			_handle_connection_error("Tempo de conexão esgotado")

# ===== CONEXÃO COM O SERVIDOR =====

## Conecta ao servidor dedicado
func connect_to_server():
	if is_connected_to_server:
		_log_debug("Já conectado ao servidor")
		return
	
	if is_connecting:
		_log_debug("Já está tentando conectar")
		return
	
	_log_debug("Tentando conectar ao servidor: %s:%d" % [server_address, server_port])
	
	# Mostra tela de carregamento
	if main_menu:
		main_menu.show_loading_menu("Conectando ao servidor...")
	
	# Cria peer para cliente
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

## Desconecta do servidor
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
	
	# Vai para tela de escolha de nome
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
	
	# Tenta reconectar após 3 segundos
	await get_tree().create_timer(3.0).timeout
	if not is_connected_to_server:
		connect_to_server()

func _handle_connection_error(message: String):
	if main_menu:
		main_menu.show_connecting_menu()
		main_menu.show_error_connecting(message)
	
	connection_failed.emit(message)

# ===== REGISTRO DE JOGADOR =====

## Define o nome do jogador e registra no servidor
func set_player_name(p_name: String):
	if not is_connected_to_server:
		_show_error("Não conectado ao servidor")
		return
	
	_log_debug("Tentando registrar nome: " + p_name)
	
	if main_menu:
		main_menu.show_loading_menu("Registrando jogador...")
	
	# Envia nome para o servidor validar via NetworkManager
	NetworkManager.register_player(p_name)

## [CLIENT] Recebe confirmação de nome aceito (chamado pelo NetworkManager)
func _client_name_accepted(accepted_name: String):
	player_name = accepted_name
	_log_debug("✓ Nome aceito pelo servidor: " + player_name)
	
	if main_menu:
		main_menu.show_main_menu()
		main_menu.update_name_e_connected(accepted_name)
	
	name_accepted.emit()

## [CLIENT] Recebe senha incorreta
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

## [CLIENT] Recebe rejeição de nome (chamado pelo NetworkManager)
func _client_name_rejected(reason: String):
	_log_debug("✗ Nome rejeitado: " + reason)
	
	if main_menu:
		main_menu.show_name_input_menu()
		main_menu.show_error_name_input(reason)
	
	name_rejected.emit(reason)

# ===== GERENCIAMENTO DE SALAS =====

## Solicita a lista de salas disponíveis ao servidor
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

## [CLIENT] Recebe a lista de salas do servidor (chamado pelo NetworkManager)
func _client_receive_rooms_list(rooms: Array):
	_log_debug("Lista de salas recebida: %d salas" % rooms.size())
	
	if main_menu:
		main_menu.hide_loading_menu(true)
		main_menu.populate_match_list(rooms)
	
	rooms_list_received.emit(rooms)

## [CLIENT] Recebe a lista de salas do servidor (chamado pelo NetworkManager)
func _client_receive_rooms_list_update(rooms: Array):
	_log_debug("Lista de salas recebida: %d salas, só update" % rooms.size())
	rooms_list_received.emit(rooms)

## Cria uma nova sala
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

## [CLIENT] Callback quando a sala é criada com sucesso (chamado pelo NetworkManager)
func _client_room_created(room_data: Dictionary):
	current_room = room_data
	_log_debug("✓ Sala criada com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu:
		main_menu.show_room_menu(room_data)
	
	room_created.emit(room_data)

## Entra em uma sala existente
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

## Entra em uma sala pelo nome (entrada manual)
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

## [CLIENT] Callback quando entra em uma sala com sucesso (chamado pelo NetworkManager)
func _client_joined_room(room_data: Dictionary):
	current_room = room_data
	_log_debug("✓ Entrou na sala com sucesso: %s (ID: %d)" % [room_data["name"], room_data["id"]])
	
	if main_menu:
		main_menu.show_room_menu(room_data)
	
	joined_room.emit(room_data)

## [CLIENT] Recebe atualização da sala (jogador entrou/saiu) (chamado pelo NetworkManager)
func _client_room_updated(room_data: Dictionary):
	current_room = room_data
	_log_debug("Sala atualizada: %s (%d jogadores)" % [room_data["name"], room_data["players"].size()])
	
	if main_menu:
		main_menu.update_room_info(room_data)
	
	room_updated.emit(room_data)

## Sai da sala atual
func leave_room():
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	_log_debug("Saindo da sala: %s" % current_room["name"])
	NetworkManager.leave_room()
	current_room = {}
	
	if main_menu:
		main_menu.show_main_menu()
	
## Fecha a sala (apenas o host pode fazer isso)
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

## Inicia a partida (apenas o host)
func start_match(match_settings: Dictionary = {}):
	if current_room.is_empty():
		_log_debug("Não está em nenhuma sala")
		return
	
	if current_room["host_id"] != local_peer_id:
		_show_error("Apenas o host pode iniciar a partida")
		return
	
	_log_debug("Solicitando início da partida...")
	NetworkManager.start_match(match_settings)

## [CLIENT] Servidor confirmou início da partida (chamado pelo NetworkManager)
func _client_match_started(match_data: Dictionary):
	_log_debug("✓ Partida iniciada pelo servidor!")
	_start_match()

## [CLIENT] Notifica que a sala foi fechada (chamado pelo NetworkManager)
func _client_room_closed(reason: String):
	_log_debug("Sala fechada: " + reason)
	current_room = {}
	
	if main_menu:
		main_menu.show_main_menu()
		_show_error(reason)

# ===== TRATAMENTO DE ERROS =====

## [CLIENT] Recebe mensagem de erro do servidor (chamado pelo NetworkManager)
func _client_error(error_message: String):
	_log_debug("✗ Erro recebido do servidor: " + error_message)
	
	_show_error(error_message)
	error_occurred.emit(error_message)

func _show_error(message: String):
	_log_debug("ERRO: " + message)
	
	# Mostra erro na UI apropriada
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

# ===== INÍCIO DA PARTIDA =====

## Inicia a partida (ainda será implementada)
func _start_match():
	_log_debug("========================================")
	_log_debug("INICIANDO PARTIDA")
	_log_debug("Sala: %s (ID: %d)" % [current_room["name"], current_room["id"]])
	_log_debug("Jogadores participantes:")
	
	if current_room.has("players"):
		for player in current_room["players"]:
			var is_host = " [HOST]" if player["is_host"] else ""
			_log_debug("  - %s (ID: %d)%s" % [player["name"], player["id"], is_host])
	
	_log_debug("========================================")
	
	# TODO: Implementar lógica de início da partida
	# Aqui você irá trocar de cena, instanciar jogadores, etc.

# ===== UTILITÁRIOS =====

## Registra mensagens de debug (apenas se debug_mode estiver ativo)
func _log_debug(message: String):
	if debug_mode:
		print("[GameManager] " + message)

## Define a referência da UI principal
func set_main_menu(menu: Control):
	main_menu = menu
	_log_debug("UI principal registrada")
