extends NetworkManager
class_name ServerNetworkManager

## NetworkManager - Versão Servidor

# ===== REGISTROS =====

var server_manager: ServerManager = null
var client_registry: ClientRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null
var game_manager: GameManager = null
var item_database: ItemDatabase = null

# ===== VARIÁVEIS INTERNAS =====

var server_is_headless: bool

## { object_id: float }  — contagem regressiva até próximo envio
var sync_timers: Dictionary = {}

const RPC_RATE_LIMIT_SEC = 0.25

var _player_rpc_timestamps = {}
var _player_rpc_queues = {}

# ===== INICIALIZAÇÃO =====

func initialize():
	_player_rpc_timestamps.clear()
	_player_rpc_queues.clear()
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_log_debug("▶️ NetworkManager inicializado com sucesso!")

func _process(delta: float):
	_server_update_sync_timers(delta)

func _get_log_prefix() -> String:
	return "[SERVER][NetworkManager]"

func _on_peer_disconnected(peer_id: int):
	if _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps.erase(peer_id)
	if _player_rpc_queues.has(peer_id):
		_player_rpc_queues.erase(peer_id)

func is_rpc_allowed(peer_id: int) -> bool:
	var current_time = Time.get_ticks_usec() / 1000000.0
	if not _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps[peer_id] = current_time
		_player_rpc_queues[peer_id] = []
		return true
	var last_rpc_time = _player_rpc_timestamps[peer_id]
	if current_time - last_rpc_time < RPC_RATE_LIMIT_SEC:
		_log_debug("RPC rate limited para peer %d: %.3fs desde última" % [peer_id, current_time - last_rpc_time])
		return false
	_player_rpc_timestamps[peer_id] = current_time
	return true


# ===== AUTENTICAÇÃO =====

func _server_receive_hello(payload: Dictionary):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	var response = server_manager.process_client_hello(payload, peer_id)
	# RENOMEADO DESTINO: "client_receive_auth_result" → "_client_receive_auth_result"
	rpc_id(peer_id, "_client_receive_auth_result", response)


# ===== REGISTRO DE JOGADOR =====

func _server_register_player_name(player_name: String):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_register_player_name(peer_id, player_name)


# ===== SALAS =====

func _server_request_rooms_list():
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_request_rooms_list(peer_id)

func _server_request_return_exit(_chosen: bool):
	"""Servidor recebe resposta de cliente sobre voltar (true) ou abandonar (false)"""
	pass  # implementar lógica aqui

func _server_create_room(room_name: String, password: String):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_create_room(peer_id, room_name, password)

func _server_join_room(room_id: int, password: String):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_join_room(peer_id, room_id, password)

func _server_join_room_by_name(room_name: String, password: String):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_join_room_by_name(peer_id, room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_update_room_settings(changed_settings: Dictionary):
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_update_room_settings(peer_id, changed_settings)

func _server_leave_room():
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_leave_room(peer_id)

func _server_kick_player(selected_player_id: String):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_kick_player_from_room(peer_id, selected_player_id)

func _server_close_room():
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_close_room(peer_id)


# ===== RODADAS =====

func _server_start_round(round_settings: Dictionary):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_start_round(peer_id, round_settings)

func _server_start_match(match_settings: Dictionary):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_start_round(peer_id, match_settings)


# ===== ITENS — RECEBIMENTOS DO CLIENTE =====

func _server_pick_up_item(player_id, object_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_pick_up_item(player_id, object_id)

func _server_equip_item(player_id, item_id, slot_type):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_equip_item(player_id, item_id, slot_type)

func _server_unequip_item(player_id, item_id):
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

func _server_trainer_respawn_player(player_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_repawn_player(player_id)

func _server_drop_item(player_id, obj_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_drop_item(player_id, obj_id)


# ===== SINCRONIZAÇÃO DE ESTADO DE JOGADORES =====

func _server_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		push_warning("⚠️ Jogador %d tentou enviar estado do jogador %d" % [sender_id, p_id])
		return
	server_manager._apply_player_state_on_server(p_id, pos, rot, vel, running, jumping)
	var sender_uuid = client_registry.get_uuid_by_peer_id(p_id)
	var round_id = round_registry.get_round_by_player_uuid(sender_uuid)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	for peer_id in players_round:
		if peer_id != sender_uuid:
			var session_id = client_registry.get_peer_id_by_uuid(peer_id)
			rpc_id(session_id, "_client_player_state", p_id, pos, rot, vel, running, jumping)

func _server_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	var player_uuid = client_registry.get_uuid_by_peer_id(p_id)
	var round_id = round_registry.get_round_by_player_uuid(player_uuid)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	for peer_id in players_round:
		if peer_id != player_uuid:
			var session_id = client_registry.get_peer_id_by_uuid(peer_id)
			rpc_id(session_id, "_client_player_animation_state", int(p_id), speed, attacking,
				   defending, jumping, aiming, running, block_attacking, on_floor)


# ===== SINCRONIZAÇÃO DE OBJETOS =====

func _server_update_sync_timers(delta: float) -> void:
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
	for oid in to_remove:
		unregister_syncable_object(oid)

func _send_sync_for_object(object_id: int) -> void:
	var entry = syncable_objects.get(object_id)
	if !entry:
		return
	var node = entry.node
	if !is_instance_valid(node) or !node.is_inside_tree():
		return
	var config = entry.config
	var pos = node.global_position
	var rot = node.global_rotation if config.get("sync_rotation", true) else Vector3.ZERO
	# RENOMEADO DESTINO: "_on_client_sync_object" → "_client_sync_object"
	_client_sync_object.rpc(object_id, pos, rot)

func register_syncable_object(object_id: int, node: Node, config: Dictionary) -> void:
	if syncable_objects.has(object_id):
		push_warning("Tentativa de registrar objeto sincronizável duplicado: %d" % object_id)
		return
	if !node.is_inside_tree():
		push_error("Não é possível registrar nó fora da árvore: %d" % object_id)
		return
	syncable_objects[object_id] = { "node" = node, "config" = config }
	sync_timers[object_id] = 0.0
	_log_debug("✅ Objeto registrado para sync: %d" % object_id)

func unregister_syncable_object(object_id: int) -> void:
	if syncable_objects.has(object_id):
		syncable_objects.erase(object_id)
	if sync_timers.has(object_id):
		sync_timers.erase(object_id)
	_log_debug("🗑️ Objeto removido do sync: %d" % object_id)


# ===== AÇÕES (ATAQUES, DEFESA) =====

func _server_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	_log_debug("_server_player_action")
	if server_manager.has_method("_server_player_action"):
		server_manager._server_player_action(p_id, action_type, item_equipado_nome, anim_name)
