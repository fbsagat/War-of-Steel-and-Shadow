extends Node
## NetworkManager - Gerenciador de RPCs compartilhados entre cliente e servidor
## Todos os RPCs devem estar aqui para funcionarem corretamente no Godot 4.5+
## Funções que começam com _server_ só rodam no servidor
## Funções que começam com _client_ só rodam nos clientes

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = false

# ===== VARIÁVEIS INTERNAS =====

var _is_connected: bool = false

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	# Detecta se é servidor dedicado
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_log_debug("Sou o servidor - Gerenciando RPCs")
		return
	
	_log_debug("Sou o cliente - Inicializado (Cliente)")
	
	# Conecta aos sinais de rede (apenas no cliente)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected_to_server():
	"""Callback quando conecta ao servidor"""
	_is_connected = true
	_log_debug("Conexão de rede estabelecida")

func _on_server_disconnected():
	"""Callback quando desconecta do servidor"""
	_is_connected = false
	_log_debug("Conexão de rede perdida")

# ===== REGISTRO DE JOGADOR =====

func register_player(player_name: String):
	"""Envia requisição de registro de jogador ao servidor"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Registrando jogador: " + player_name)
	rpc_id(1, "_server_register_player", player_name)

@rpc("any_peer", "call_remote", "reliable")
func _server_register_player(player_name: String):
	"""RPC: Servidor recebe pedido de registro"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_register_player(peer_id, player_name)

@rpc("authority", "call_remote", "reliable")
func _client_name_accepted(accepted_name: String):
	"""RPC: Cliente recebe confirmação de nome aceito"""
	if multiplayer.is_server():
		return
	
	GameManager._client_name_accepted(accepted_name)

@rpc("authority", "call_remote", "reliable")
func _client_name_rejected(reason: String):
	"""RPC: Cliente recebe rejeição de nome"""
	if multiplayer.is_server():
		return
	
	GameManager._client_name_rejected(reason)

# ===== GERENCIAMENTO DE SALAS =====

func request_rooms_list():
	"""Solicita lista de salas ao servidor"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Solicitando lista de salas")
	rpc_id(1, "_server_request_rooms_list")

@rpc("any_peer", "call_remote", "reliable")
func _server_request_rooms_list():
	"""RPC: Servidor recebe pedido de lista de salas"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_request_rooms_list(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list(rooms: Array):
	"""RPC: Cliente recebe lista de salas"""
	if multiplayer.is_server():
		return
	
	GameManager._client_receive_rooms_list(rooms)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list_update(rooms: Array):
	"""RPC: Cliente recebe atualização de lista de salas"""
	if multiplayer.is_server():
		return
	
	GameManager._client_receive_rooms_list_update(rooms)

func create_room(room_name: String, password: String = ""):
	"""Solicita criação de sala ao servidor"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Criando sala: " + room_name)
	rpc_id(1, "_server_create_room", room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_create_room(room_name: String, password: String):
	"""RPC: Servidor recebe pedido de criação de sala"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_create_room(peer_id, room_name, password)

@rpc("authority", "call_remote", "reliable")
func _client_room_created(room_data: Dictionary):
	"""RPC: Cliente recebe confirmação de sala criada"""
	if multiplayer.is_server():
		return
	
	GameManager._client_room_created(room_data)

func join_room(room_id: int, password: String = ""):
	"""Solicita entrada em sala por ID"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Entrando na sala ID: %d" % room_id)
	rpc_id(1, "_server_join_room", room_id, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room(room_id: int, password: String):
	"""RPC: Servidor recebe pedido de entrada em sala"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_join_room(peer_id, room_id, password)

func join_room_by_name(room_name: String, password: String = ""):
	"""Solicita entrada em sala por nome"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Entrando na sala: " + room_name)
	rpc_id(1, "_server_join_room_by_name", room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room_by_name(room_name: String, password: String):
	"""RPC: Servidor recebe pedido de entrada em sala por nome"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_join_room_by_name(peer_id, room_name, password)

@rpc("authority", "call_remote", "reliable")
func _client_joined_room(room_data: Dictionary):
	"""RPC: Cliente recebe confirmação de entrada em sala"""
	if multiplayer.is_server():
		return
	
	GameManager._client_joined_room(room_data)

@rpc("authority", "call_remote", "reliable")
func _client_wrong_password():
	"""RPC: Cliente recebe notificação de senha incorreta"""
	if multiplayer.is_server():
		return
	
	GameManager._client_wrong_password()

@rpc("authority", "call_remote", "reliable")
func _client_room_name_exists():
	"""RPC: Cliente recebe notificação de sala já tem este nome"""
	if multiplayer.is_server():
		return
	GameManager._client_room_name_exists()

@rpc("authority", "call_remote", "reliable")
func _client_room_name_error(error : String):
	"PRC: Cliente recebe notificação de erro ao definir nome da sala"
	if multiplayer.is_server():
		return
	GameManager._client_room_name_error(error)
	
@rpc("authority", "call_remote", "reliable")
func _client_room_not_found():
	"""RPC: Cliente recebe notificação de sala não encontrada"""
	if multiplayer.is_server():
		return
	
	GameManager._client_room_not_found()

func leave_room():
	"""Solicita saída da sala atual"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Saindo da sala")
	rpc_id(1, "_server_leave_room")

@rpc("any_peer", "call_remote", "reliable")
func _server_leave_room():
	"""RPC: Servidor recebe pedido de saída de sala"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_leave_room(peer_id)

func close_room():
	"""Solicita fechamento da sala (apenas host)"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Fechando sala")
	rpc_id(1, "_server_close_room")

@rpc("any_peer", "call_remote", "reliable")
func _server_close_room():
	"""RPC: Servidor recebe pedido de fechamento de sala"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_close_room(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_room_closed(reason: String):
	"""RPC: Cliente recebe notificação de sala fechada"""
	if multiplayer.is_server():
		return
	
	GameManager._client_room_closed(reason)

@rpc("authority", "call_remote", "reliable")
func _client_room_updated(room_data: Dictionary):
	"""RPC: Cliente recebe atualização de dados da sala"""
	if multiplayer.is_server():
		return
	
	GameManager._client_room_updated(room_data)

# ===== GERENCIAMENTO DE RODADAS =====

# Esta funçõa foi executada pelo game manager do cliente, ela serve para pedir
# para o servidor executar _server_start_round
func start_round(round_settings: Dictionary = {}):
	"""Solicita início de rodada (apenas host é respondido)"""
	if not is_connected:
		_log_debug("Erro: Não conectado ao servidor")
		return
	
	_log_debug("Iniciando rodada")
	rpc_id(1, "_server_start_round", round_settings)

# Esta função é executada pelo servidor, no ServerManager, e solicitada pelo cliente
@rpc("any_peer", "call_remote", "reliable")
func _server_start_round(round_settings: Dictionary):
	"""RPC: Servidor recebe pedido de início de rodada"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_start_round(peer_id, round_settings)

func start_match(match_settings: Dictionary = {}):
	"""Alias para start_round (compatibilidade)"""
	start_round(match_settings)

@rpc("any_peer", "call_remote", "reliable")
func _server_start_match(match_settings: Dictionary):
	"""RPC: Alias para _server_start_round (compatibilidade)"""
	if not multiplayer.is_server():
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	ServerManager._handle_start_match(peer_id, match_settings)

@rpc("authority", "call_remote", "reliable")
func _client_round_started(match_data: Dictionary):
	"""RPC: Cliente recebe notificação de rodada iniciada"""
	if multiplayer.is_server():
		return
	
	GameManager._client_round_started(match_data)

# Mantém compatibilidade
@rpc("authority", "call_remote", "reliable")
func _client_match_started(match_data: Dictionary):
	"""RPC: Alias para _client_round_started (compatibilidade)"""
	if multiplayer.is_server():
		return
	
	GameManager._client_round_started(match_data)

@rpc("authority", "call_remote", "reliable")
func _client_round_ended(end_data: Dictionary):
	"""RPC: Cliente recebe notificação de rodada finalizada"""
	if multiplayer.is_server():
		return
	
	GameManager._client_round_ended(end_data)

@rpc("authority", "call_remote", "reliable")
func _client_return_to_room(room_data: Dictionary):
	"""RPC: Cliente recebe comando para voltar à sala"""
	if multiplayer.is_server():
		return
	
	GameManager._client_return_to_room(room_data)

# ===== SPAWN DE OBJETOS (ObjectSpawner) =====

@rpc("authority", "call_remote", "reliable")
func _client_spawn_object(spawn_data: Dictionary):
	"""RPC: Cliente recebe comando para spawnar objeto"""
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
	"""RPC: Cliente recebe comando para despawnar objeto"""
	if multiplayer.is_server():
		return
	
	if ObjectSpawner.spawned_objects.has(object_id):
		var obj = ObjectSpawner.spawned_objects[object_id]
		if obj and is_instance_valid(obj):
			obj.queue_free()
		ObjectSpawner.spawned_objects.erase(object_id)

@rpc("authority", "call_remote", "reliable")
func _client_remove_player(peer_id: int):
	if multiplayer.is_server():
		return
	GameManager._client_remove_player(peer_id)

# ===== SINCRONIZAÇÃO DE JOGADORES =====

func send_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Envia estado do jogador para o servidor"""
	if not is_connected:
		return
	# RPC do NetworkManager → válido, pois NetworkManager é autoload
	rpc_id(1, "_server_player_state", p_id, pos, rot, vel, running, jumping)

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Servidor recebe estado do jogador"""
	# Verificação robusta de servidor
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		push_warning("[NetworkManager] Jogador %d tentou enviar estado do jogador %d" % [sender_id, p_id])
		return
	
	# Envia estado para TODOS os clientes (incluindo o remetente, mas ele ignora)
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_client_player_state", p_id, pos, rot, vel, running, jumping)

@rpc("any_peer", "call_remote", "unreliable")
func _client_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Cliente recebe estado de outro jogador"""
	# Só processa se NÃO for servidor
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	# Encontra o player na cena
	var player_path = str(p_id)
	var player = get_tree().root.get_node_or_null(player_path)
	
	if not player:
		print("[NetworkManager] Player não encontrado: %s" % player_path)
		return
	
	if player and player.has_method("_client_receive_state"):
		player._client_receive_state(pos, rot, vel, running, jumping)

# ===== TRATAMENTO DE ERROS =====

@rpc("authority", "call_remote", "reliable")
func _client_error(error_message: String):
	"""RPC: Cliente recebe mensagem de erro"""
	if multiplayer.is_server():
		return
	
	GameManager._client_error(error_message)

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		print("[NetworkManager] " + message)
