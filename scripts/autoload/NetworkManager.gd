extends Node
## NetworkManager - Gerenciador de RPCs compartilhados entre cliente e servidor
## Todos os RPCs devem estar aqui para funcionarem corretamente no Godot 4.5+

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

var is_connected: bool = false

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	_log_debug("NetworkManager inicializado")
	
	# Conecta aos sinais de rede
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected_to_server():
	is_connected = true
	_log_debug("Conexão de rede estabelecida")

func _on_server_disconnected():
	is_connected = false
	_log_debug("Conexão de rede perdida")

# ===== REGISTRO DE JOGADOR =====

func register_player(player_name: String):
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Registrando jogador: " + player_name)
	rpc_id(1, "_server_register_player", player_name)

@rpc("any_peer", "call_remote", "reliable")
func _server_register_player(player_name: String):
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_register_player(peer_id, player_name)

@rpc("authority", "call_remote", "reliable")
func _client_name_accepted(accepted_name: String):
	if multiplayer.is_server():
		return
	
	GameManager._client_name_accepted(accepted_name)

## [CLIENT] Recebe senha incorreta
@rpc("authority", "call_remote", "reliable")
func _client_wrong_password():
	GameManager._client_wrong_password()

@rpc("authority", "call_remote", "reliable")
func _client_room_not_found():
	GameManager._client_room_not_found()
		
@rpc("authority", "call_remote", "reliable")
func _client_name_rejected(reason: String):
	if multiplayer.is_server():
		return
	
	GameManager._client_name_rejected(reason)
	
# ===== GERENCIAMENTO DE SALAS =====

func request_rooms_list():
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Solicitando lista de salas")
	rpc_id(1, "_server_request_rooms_list")

@rpc("any_peer", "call_remote", "reliable")
func _server_request_rooms_list():
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_request_rooms_list(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list(rooms: Array):
	if multiplayer.is_server():
		return
	
	GameManager._client_receive_rooms_list(rooms)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list_update(rooms: Array):
	if multiplayer.is_server():
		return
	
	GameManager._client_receive_rooms_list_update(rooms)

func create_room(room_name: String, password: String = ""):
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Criando sala: " + room_name)
	rpc_id(1, "_server_create_room", room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_create_room(room_name: String, password: String):
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_create_room(peer_id, room_name, password)

@rpc("authority", "call_remote", "reliable")
func _client_room_created(room_data: Dictionary):
	if multiplayer.is_server():
		return
	
	GameManager._client_room_created(room_data)

func join_room(room_id: int, password: String = ""):
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Entrando na sala ID: %d" % room_id)
	rpc_id(1, "_server_join_room", room_id, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room(room_id: int, password: String):
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_join_room(peer_id, room_id, password)

func join_room_by_name(room_name: String, password: String = ""):
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Entrando na sala: " + room_name)
	rpc_id(1, "_server_join_room_by_name", room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room_by_name(room_name: String, password: String):
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_join_room_by_name(peer_id, room_name, password)

@rpc("authority", "call_remote", "reliable")
func _client_joined_room(room_data: Dictionary):
	if multiplayer.is_server():
		return
	
	GameManager._client_joined_room(room_data)

func leave_room():
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Saindo da sala")
	rpc_id(1, "_server_leave_room")

@rpc("any_peer", "call_remote", "reliable")
func _server_leave_room():
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_leave_room(peer_id)

func close_room():
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Fechando sala")
	rpc_id(1, "_server_close_room")

@rpc("any_peer", "call_remote", "reliable")
func _server_close_room():
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_close_room(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_room_closed(reason: String):
	if multiplayer.is_server():
		return
	
	GameManager._client_room_closed(reason)

@rpc("authority", "call_remote", "reliable")
func _client_room_updated(room_data: Dictionary):
	if multiplayer.is_server():
		return
	
	GameManager._client_room_updated(room_data)

func start_match(match_settings: Dictionary = {}):
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Iniciando partida")
	rpc_id(1, "_server_start_match", match_settings)

@rpc("any_peer", "call_remote", "reliable")
func _server_start_match(match_settings: Dictionary):
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_start_match(peer_id, match_settings)

@rpc("authority", "call_remote", "reliable")
func _client_match_started(match_data: Dictionary):
	if multiplayer.is_server():
		return
	
	GameManager._client_match_started(match_data)

# ===== TRATAMENTO DE ERROS =====

@rpc("authority", "call_remote", "reliable")
func _client_error(error_message: String):
	if multiplayer.is_server():
		return
	
	GameManager._client_error(error_message)

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[NetworkManager] " + message)
