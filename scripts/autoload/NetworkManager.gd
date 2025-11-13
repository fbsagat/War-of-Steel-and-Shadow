extends Node
## NetworkManager - Gerenciador de RPCs compartilhados entre cliente e servidor
## Funções que começam com _server_ só rodam no servidor
## Funções que começam com _client_ só rodam nos clientes

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

var is_connected: bool = false

# ===== PROPRIEDADE PARA COMPATIBILIDADE =====

# Permite que outros scripts usem NetworkManager.is_connected
var _is_connected: bool = false:
	get:
		return is_connected

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	# Detecta se é servidor dedicado
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_log_debug("========================================")
		_log_debug("NETWORKMANAGER INICIALIZADO (SERVIDOR)")
		_log_debug("========================================")
		return
	
	_log_debug("========================================")
	_log_debug("NETWORKMANAGER INICIALIZADO (CLIENTE)")
	_log_debug("========================================")
	
	# Conecta aos sinais de rede (apenas no cliente)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _on_connected_to_server():
	"""Callback quando conecta ao servidor"""
	is_connected = true
	_log_debug("✅ Conexão de rede estabelecida")

func _on_server_disconnected():
	"""Callback quando desconecta do servidor"""
	is_connected = false
	_log_debug("❌ Conexão de rede perdida")

func _on_connection_failed():
	"""Callback quando falha ao conectar"""
	is_connected = false
	_log_debug("❌ Falha ao conectar ao servidor")

# ===== REGISTRO DE JOGADOR =====

func register_player(player_name: String):
	"""Envia requisição de registro de jogador ao servidor"""
	if not is_connected:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Registrando jogador: " + player_name)
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
	
	_log_debug("✅ Nome aceito: " + accepted_name)
	GameManager._client_name_accepted(accepted_name)

@rpc("authority", "call_remote", "reliable")
func _client_name_rejected(reason: String):
	"""RPC: Cliente recebe rejeição de nome"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Nome rejeitado: " + reason)
	GameManager._client_name_rejected(reason)

# ===== GERENCIAMENTO DE SALAS =====

func request_rooms_list():
	"""Solicita lista de salas ao servidor"""
	if not is_connected:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Solicitando lista de salas")
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
	
	_log_debug("📥 Lista de salas recebida: %d salas" % rooms.size())
	GameManager._client_receive_rooms_list(rooms)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list_update(rooms: Array):
	"""RPC: Cliente recebe atualização de lista de salas"""
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Atualização de salas recebida: %d salas" % rooms.size())
	GameManager._client_receive_rooms_list_update(rooms)

func create_room(room_name: String, password: String = ""):
	"""Solicita criação de sala ao servidor"""
	if not is_connected:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Criando sala: " + room_name)
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
	
	_log_debug("✅ Sala criada: " + str(room_data.get("name", "?")))
	GameManager._client_room_created(room_data)

func join_room(room_id: int, password: String = ""):
	"""Solicita entrada em sala por ID"""
	if not is_connected:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Entrando na sala ID: %d" % room_id)
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
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Entrando na sala: " + room_name)
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
	
	_log_debug("✅ Entrou na sala: " + str(room_data.get("name", "?")))
	GameManager._client_joined_room(room_data)

@rpc("authority", "call_remote", "reliable")
func _client_wrong_password():
	"""RPC: Cliente recebe notificação de senha incorreta"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Senha incorreta")
	GameManager._client_wrong_password()

@rpc("authority", "call_remote", "reliable")
func _client_room_name_exists():
	"""RPC: Cliente recebe notificação de sala já tem este nome"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Nome de sala já existe")
	GameManager._client_room_name_exists()

@rpc("authority", "call_remote", "reliable")
func _client_room_name_error(error: String):
	"""RPC: Cliente recebe notificação de erro ao definir nome da sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Erro no nome da sala: " + error)
	GameManager._client_room_name_error(error)

@rpc("authority", "call_remote", "reliable")
func _client_room_not_found():
	"""RPC: Cliente recebe notificação de sala não encontrada"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Sala não encontrada")
	GameManager._client_room_not_found()

func leave_room():
	"""Solicita saída da sala atual"""
	if not is_connected:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Saindo da sala")
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
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Fechando sala")
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
	
	_log_debug("❌ Sala fechada: " + reason)
	GameManager._client_room_closed(reason)

@rpc("authority", "call_remote", "reliable")
func _client_room_updated(room_data: Dictionary):
	"""RPC: Cliente recebe atualização de dados da sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Sala atualizada: " + str(room_data.get("name", "?")))
	GameManager._client_room_updated(room_data)

# ===== GERENCIAMENTO DE RODADAS =====

func start_round(round_settings: Dictionary = {}):
	"""Solicita início de rodada (apenas host é respondido)"""
	if not is_connected:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Iniciando rodada")
	rpc_id(1, "_server_start_round", round_settings)

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
	ServerManager._handle_start_round(peer_id, match_settings)

@rpc("authority", "call_remote", "reliable")
func _client_round_started(match_data: Dictionary):
	"""RPC: Cliente recebe notificação de rodada iniciada"""
	if multiplayer.is_server():
		return
	
	_log_debug("✅ Rodada iniciada")
	GameManager._client_round_started(match_data)

@rpc("authority", "call_remote", "reliable")
func _client_round_ended(end_data: Dictionary):
	"""RPC: Cliente recebe notificação de rodada finalizada"""
	if multiplayer.is_server():
		return
	
	_log_debug("🏁 Rodada finalizada")
	GameManager._client_round_ended(end_data)

@rpc("authority", "call_remote", "reliable")
func _client_return_to_room(room_data: Dictionary):
	"""RPC: Cliente recebe comando para voltar à sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("↩️ Voltando para sala")
	GameManager._client_return_to_room(room_data)

# ===== SPAWN DE OBJETOS (ObjectSpawner) =====

@rpc("authority", "call_remote", "reliable")
func _client_spawn_object(spawn_data: Dictionary):
	"""RPC: Cliente recebe comando para spawnar objeto"""
	if multiplayer.is_server():
		return
	
	_log_debug("🎯 Spawnando objeto: " + str(spawn_data.get("object_id", "?")))
	
	# Instancia o objeto no cliente
	var scene = load(spawn_data["scene_path"])
	if scene == null:
		push_error("❌ Falha ao carregar cena: %s" % spawn_data["scene_path"])
		return
	
	var obj = scene.instantiate()
	obj.name = "Object_%d" % spawn_data["object_id"]
	
	# Define posição
	if obj is Node3D:
		obj.global_position = spawn_data["position"]
	elif obj is Node2D:
		obj.global_position = Vector2(spawn_data["position"].x, spawn_data["position"].y)
	
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
	if ObjectSpawner:
		ObjectSpawner.spawned_objects[spawn_data["object_id"]] = obj

@rpc("authority", "call_remote", "reliable")
func _client_despawn_object(object_id: int):
	"""RPC: Cliente recebe comando para despawnar objeto"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Despawnando objeto: %d" % object_id)
	
	if ObjectSpawner and ObjectSpawner.spawned_objects.has(object_id):
		var obj = ObjectSpawner.spawned_objects[object_id]
		if obj and is_instance_valid(obj):
			obj.queue_free()
		ObjectSpawner.spawned_objects.erase(object_id)

@rpc("authority", "call_remote", "reliable")
func _client_remove_player(peer_id: int):
	"""RPC: Cliente recebe comando para remover player"""
	if multiplayer.is_server():
		return
	
	_log_debug("👤 Removendo player: %d" % peer_id)
	GameManager._client_remove_player(peer_id)

# ===== SINCRONIZAÇÃO DE JOGADORES (POSIÇÃO/ROTAÇÃO) =====

func send_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Envia estado do jogador para o servidor (UNRELIABLE - rápido)"""
	if not is_connected:
		return
	
	# RPC do NetworkManager → válido, pois NetworkManager é autoload
	rpc_id(1, "_server_player_state", p_id, pos, rot, vel, running, jumping)

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Servidor recebe estado do jogador e redistribui"""
	# Verificação robusta de servidor
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	# ✅ VALIDAÇÃO: O remetente é quem diz ser?
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		push_warning("⚠️ Jogador %d tentou enviar estado do jogador %d" % [sender_id, p_id])
		return
	
	# ✅ OPCIONAL: Validação anti-cheat
	if ServerManager and ServerManager.enable_anticheat:
		if not ServerManager._validate_player_movement(p_id, pos, vel):
			push_warning("⚠️ Movimento suspeito detectado: Jogador %d" % p_id)
			if ServerManager.has_method("_kick_player"):
				ServerManager._kick_player(p_id, "Movimento suspeito detectado")
			return
	
	# ✅ ATUALIZA ESTADO NO SERVIDOR (opcional, para autoridade)
	if ServerManager and ServerManager.player_states:
		ServerManager.player_states[p_id] = {
			"pos": pos,
			"rot": rot,
			"vel": vel,
			"running": running,
			"jumping": jumping,
			"timestamp": Time.get_ticks_msec()
		}
	
	# ✅ REDISTRIBUI PARA TODOS OS OUTROS CLIENTES
	for peer_id in multiplayer.get_peers():
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_state", p_id, pos, rot, vel, running, jumping)

@rpc("authority", "call_remote", "unreliable")
func _client_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Cliente recebe estado de OUTRO jogador"""
	# Só processa se NÃO for servidor
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	# ✅ ENCONTRA O PLAYER NA CENA (nome = player_id)
	var player = get_tree().root.get_node_or_null(str(p_id))
	
	if not player:
		return
	
	# ✅ CHAMA FUNÇÃO NO PLAYER PARA ATUALIZAR
	if player.has_method("_client_receive_state"):
		player._client_receive_state(pos, rot, vel, running, jumping)

# ===== SINCRONIZAÇÃO DE ANIMAÇÕES =====

func send_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool, 
								 jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""Envia estado de animação do jogador para o servidor (UNRELIABLE - menos frequente)"""
	if not is_connected:
		return
	
	rpc_id(1, "_server_player_animation_state", p_id, speed, attacking, defending, 
		   jumping, aiming, running, block_attacking, on_floor)

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""RPC: Servidor recebe estado de animação e redistribui"""
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# ✅ PROPAGA PARA TODOS OS OUTROS CLIENTES
	for peer_id in multiplayer.get_peers():
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_animation_state", p_id, speed, attacking, 
				   defending, jumping, aiming, running, block_attacking, on_floor)

@rpc("authority", "call_remote", "unreliable")
func _client_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""RPC: Cliente recebe estado de animação de outro jogador"""
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	var player = get_tree().root.get_node_or_null(str(p_id))
	if player and player.has_method("_client_receive_animation_state"):
		player._client_receive_animation_state(speed, attacking, defending, jumping, 
											   aiming, running, block_attacking, on_floor)

# ===== SINCRONIZAÇÃO DE AÇÕES (ATAQUES, DEFESA) =====

func send_player_action(p_id: int, action_type: String, anim_name: String):
	"""Envia ação do jogador (ataque, defesa) - RELIABLE (garantido)"""
	if not is_connected:
		return
	
	_log_debug("⚔️ Enviando ação: %s (%s)" % [action_type, anim_name])
	rpc_id(1, "_server_player_action", p_id, action_type, anim_name)

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(p_id: int, action_type: String, anim_name: String):
	"""RPC: Servidor recebe ação do jogador e redistribui"""
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# ✅ PROPAGA PARA TODOS OS OUTROS CLIENTES (RELIABLE)
	for peer_id in multiplayer.get_peers():
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_action", p_id, action_type, anim_name)

@rpc("authority", "call_remote", "reliable")
func _client_player_action(p_id: int, action_type: String, anim_name: String):
	"""RPC: Cliente recebe ação de outro jogador"""
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	_log_debug("⚔️ Recebendo ação: Player %d - %s" % [p_id, action_type])
	
	var player = get_tree().root.get_node_or_null(str(p_id))
	if player and player.has_method("_client_receive_action"):
		player._client_receive_action(action_type, anim_name)

# ===== TRATAMENTO DE ERROS =====

@rpc("authority", "call_remote", "reliable")
func _client_error(error_message: String):
	"""RPC: Cliente recebe mensagem de erro"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ ERRO DO SERVIDOR: " + error_message)
	
	if GameManager and GameManager.has_method("_client_error"):
		GameManager._client_error(error_message)

# ===== UTILITÁRIOS =====

func _is_peer_connected(peer_id: int) -> bool:
	"""Verifica se um peer ainda está conectado"""
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		var timestamp = Time.get_datetime_string_from_system()
		print("[%s][NetworkManager] %s" % [timestamp, message])
