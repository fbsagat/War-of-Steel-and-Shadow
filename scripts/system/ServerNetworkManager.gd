extends NetworkManager
class_name ServerNetworkManager

## NetworkManager - Versão Servidor
## Gerencia todas as comunicações RPC do lado do servidor

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var server_manager: ServerManager = null
var client_registry: ClientRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null

# AVISO: game_manager e item_database podem ser necessários no servidor também
# Decida se eles devem ficar aqui ou só no cliente
var game_manager: GameManager = null
var item_database: ItemDatabase = null

# ===== VARIÁVEIS INTERNAS =====

var server_is_headless: bool

# --- SINCRONIZAÇÃO DE OBJETOS ---
## Timers de sync no servidor (contagem regressiva até próximo envio)
## { object_id: float }
var sync_timers: Dictionary = {}

# Configurações de rate limit para pedidos de RPCs de clientes
const RPC_RATE_LIMIT_SEC = 0.25  # 4 RPCs por segundo por jogador
const MAX_RPC_QUEUE = 10        # Número máximo de RPCs na fila

# Armazena o último timestamp de RPC por jogador
var _player_rpc_timestamps = {}  # { peer_id: float }
var _player_rpc_queues = {}      # { peer_id: [rpc_data] }

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func initialize():
	# Inicializar dicionários de proteção
	_player_rpc_timestamps.clear()
	_player_rpc_queues.clear()
	
	# Conectar-se ao evento de desconexão para limpar dados
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	_log_debug("Inicializando NetworkManager como servidor")

func _process(delta: float):
	_server_update_sync_timers(delta)

func _get_log_prefix() -> String:
	return "[SERVER][NetworkManager]"

func is_rpc_allowed(peer_id: int) -> bool:
	"""
	Verifica se o jogador pode enviar um RPC agora.
	:return: true se permitido, false se rate limited
	"""
	var current_time = Time.get_ticks_usec() / 1000000.0  # segundos
	
	# Inicializar dados do jogador se não existir
	if not _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps[peer_id] = current_time
		_player_rpc_queues[peer_id] = []
		return true
	
	# Verificar rate limit
	var last_rpc_time = _player_rpc_timestamps[peer_id]
	if current_time - last_rpc_time < RPC_RATE_LIMIT_SEC:
		# Rate limited - ignorar esta RPC
		_log_debug("RPC rate limited para peer %d: %.3fs desde última" % [peer_id, current_time - last_rpc_time])
		return false
	
	# Atualizar timestamp
	_player_rpc_timestamps[peer_id] = current_time
	return true

func _on_peer_disconnected(peer_id: int):
	"""Limpa dados do jogador quando ele desconecta."""
	if _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps.erase(peer_id)
	if _player_rpc_queues.has(peer_id):
		_player_rpc_queues.erase(peer_id)

# ===== REGISTRO DE JOGADOR =====
func _handle_receive_client_uuid(_client_uuid: String):
	"""RPC: Servidor recebe uuid do client que acabou de conectar"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._server_receive_client_uuid(peer_id, _client_uuid)

func _server_register_player_name(player_name: String):
	"""RPC: Servidor recebe pedido de registro"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_register_player_name(peer_id, player_name)

# ===== GERENCIAMENTO DE SALAS =====

func _server_request_rooms_list():
	"""RPC: Servidor recebe pedido de lista de salas"""
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_request_rooms_list(peer_id)

func _server_create_room(room_name: String, password: String):
	"""RPC: Servidor recebe pedido de criação de sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_create_room(peer_id, room_name, password)

func _server_join_room(room_id: int, password: String):
	"""RPC: Servidor recebe pedido de entrada em sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_join_room(peer_id, room_id, password)

func _server_join_room_by_name(room_name: String, password: String):
	"""RPC: Servidor recebe pedido de entrada em sala por nome"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_join_room_by_name(peer_id, room_name, password)

func _server_leave_room():
	"""RPC: Servidor recebe pedido de saída de sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_leave_room(peer_id)

func _server_close_room():
	"""RPC: Servidor recebe pedido de fechamento de sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_close_room(peer_id)

# ===== GERENCIAMENTO DE RODADAS =====

func _server_start_round(round_settings: Dictionary):
	"""RPC: Servidor recebe pedido de início de rodada"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_start_round(peer_id, round_settings)

func _server_start_match(match_settings: Dictionary):
	"""RPC: Alias para _server_start_round"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_start_round(peer_id, match_settings)

# ===== REQUISIÇÕES DE CLIENTES =====

func _server_pick_up_player_item(player_id, object_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_pick_up_item(player_id, object_id)

func _server_equip_player_item(player_id, item_id, slot_type):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_equip_item(player_id, item_id, slot_type)

func _server_unequip_player_item(player_id, item_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_unequip_item(player_id, item_id)

func _server_swap_items(item_id_1, item_id_2):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_swap_items(item_id_1, item_id_2)

func _server_trainer_spawn_item(player_id, item_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_spawn_item(player_id, item_id)

func _server_trainer_drop_item(player_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_drop_item(player_id)

func _server_trainer_repawn_player(player_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_repawn_player(player_id)

func _server_drop_player_item(player_id, obj_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_drop_item(player_id, obj_id)

# ===== ATUALIZAÇÕES DE ESTADOS DE CLIENTES =====

func _server_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Servidor recebe estado do jogador e redistribui"""
	
	# AVISO: round_registry é necessário aqui - verifique se está disponível
	var round_id = round_registry.get_round_by_player_id(p_id)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	# VALIDAÇÃO: O remetente é quem diz ser?
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		push_warning("⚠️ Jogador %d tentou enviar estado do jogador %d" % [sender_id, p_id])
		return
	
	# OPCIONAL: Validação anti-cheat
	if server_manager and server_manager.enable_anticheat:
		if not server_manager._validate_player_movement(p_id, pos, vel):
			push_warning("⚠️ Movimento suspeito detectado: Jogador %d" % p_id)
			if server_manager.has_method("_kick_player"):
				server_manager._kick_player(p_id, "Movimento suspeito detectado")
			return
	
	server_manager._apply_player_state_on_server(p_id, pos, rot, vel, running, jumping)
	
	# REDISTRIBUI PARA TODOS OS OUTROS CLIENTES
	for peer_id in players_round:
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_state", p_id, pos, rot, vel, running, jumping)

# ===== SINCRONIZAÇÃO DE ESTADOS DE ANIMAÇÕES =====

func _server_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""RPC: Servidor recebe estado de animação e redistribui"""
	
	# AVISO: round_registry é necessário aqui
	var round_id = round_registry.get_round_by_player_id(p_id)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	# Verificar se o sender é quem diz ser
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# Propaga para todos os outros clientes
	for peer_id in players_round:
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_animation_state", p_id, speed, attacking, 
				   defending, jumping, aiming, running, block_attacking, on_floor)

# ===== SINCRONIZAÇÃO DE OBJETOS =====

func _server_update_sync_timers(delta: float) -> void:
	"""Servidor: atualiza timers e envia snapshots periódicos."""
	var to_remove = []
	for object_id in sync_timers.keys():
		if !syncable_objects.has(object_id):
			to_remove.append(object_id)
			continue
		
		var entry = syncable_objects[object_id]
		var node = entry.node
		if !is_instance_valid(node) or !node.is_inside_tree():
			to_remove.append(object_id)
			continue
		
		var config = entry.config
		var rate = config.get("sync_rate", 0.03)
		sync_timers[object_id] += delta
		
		if sync_timers[object_id] >= rate:
			sync_timers[object_id] = 0.0
			_send_sync_for_object(object_id)
	
	# Limpa objetos inválidos
	for oid in to_remove:
		unregister_syncable_object(oid)

func _send_sync_for_object(object_id: int) -> void:
	"""Envia estado do objeto para todos os clientes."""
	var entry = syncable_objects.get(object_id)
	if !entry:
		return
	
	var node = entry.node
	if !is_instance_valid(node) or !node.is_inside_tree():
		return
	
	var config = entry.config
	var pos = node.global_position
	var rot = node.global_rotation if config.get("sync_rotation", true) else Vector3.ZERO
	
	# ✅ RPC centralizado para todos os clientes
	_on_client_sync_object.rpc(object_id, pos, rot)

func register_syncable_object(object_id: int, node: Node, config: Dictionary) -> void:
	"""Registra um objeto para sincronização contínua (lado servidor)."""
	if syncable_objects.has(object_id):
		push_warning("Tentativa de registrar objeto sincronizável duplicado: %d" % object_id)
		return
	
	if !node.is_inside_tree():
		push_error("Não é possível registrar nó fora da árvore: %d" % object_id)
		return
	
	syncable_objects[object_id] = {
		"node" = node,
		"config" = config
	}
	
	sync_timers[object_id] = 0.0
	
	_log_debug("✅ Objeto registrado para sync: %d" % object_id)

func unregister_syncable_object(object_id: int) -> void:
	"""Remove um objeto do sistema de sincronização."""
	if syncable_objects.has(object_id):
		syncable_objects.erase(object_id)
	if sync_timers.has(object_id):
		sync_timers.erase(object_id)
	
	_log_debug("🗑️ Objeto removido do sync: %d" % object_id)

# ===== SINCRONIZAÇÃO DE AÇÕES =====

func _server_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""RPC: Servidor recebe ação do jogador e redistribui"""
	
	_log_debug("_server_player_action")
	if server_manager.has_method("_server_player_action"):
		server_manager._server_player_action(p_id, action_type, item_equipado_nome, anim_name)
