extends Node
## NetworkManager - Gerenciador de RPCs compartilhados entre cliente e servidor
## Todos os RPCs devem estar aqui para funcionarem corretamente no Godot 4.5+

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = false

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

# ===== INÍCIO E GERENCIAMENTO DE PARTIDAS =====

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

@rpc("authority", "call_remote", "reliable")
func _client_round_ended(end_data: Dictionary):
	if multiplayer.is_server():
		return
	
	GameManager._client_round_ended(end_data)

@rpc("authority", "call_remote", "reliable")
func _client_party_ended():
	if multiplayer.is_server():
		return
	
	GameManager._client_party_ended()

@rpc("authority", "call_remote", "reliable")
func _client_next_round_starting(round_number: int):
	if multiplayer.is_server():
		return
	
	GameManager._client_next_round_starting(round_number)

# ===== SPAWN DE OBJETOS (ObjectSpawner) =====

@rpc("authority", "call_remote", "reliable")
func _client_spawn_object(spawn_data: Dictionary):
	if multiplayer.is_server():
		return
	
	# Instancia o objeto no cliente
	var scene = load(spawn_data["scene_path"])
	if scene == null:
		push_error("Falha ao carregar cena: %s" % spawn_data["scene_path"])
		return
	
	var obj = scene.instantiate()
	obj.name = "Object_%d" % spawn_data["object_id"]
	
	# Define posição
	if obj is Node3D or obj is Node2D:
		obj.global_position = spawn_data["position"]
	
	# Aplica configurações
	if obj.has_method("configure"):
		obj.configure(spawn_data["data"])
	elif not spawn_data["data"].is_empty():
		for key in spawn_data["data"]:
			if key in obj:
				obj.set(key, spawn_data["data"][key])
	
	# Adiciona à cena
	get_tree().root.add_child(obj)
	
	# Registra no ObjectSpawner
	ObjectSpawner.spawned_objects[spawn_data["object_id"]] = obj

@rpc("authority", "call_remote", "reliable")
func _client_despawn_object(object_id: int):
	if multiplayer.is_server():
		return
	
	if ObjectSpawner.spawned_objects.has(object_id):
		var obj = ObjectSpawner.spawned_objects[object_id]
		if obj and is_instance_valid(obj):
			obj.queue_free()
		ObjectSpawner.spawned_objects.erase(object_id)

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
