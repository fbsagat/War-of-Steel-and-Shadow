extends NetworkManager
class_name ClientNetworkManager

## NetworkManager - Versão Cliente

# ===== REGISTROS =====

var game_manager: GameManager = null
var item_database: ItemDatabase = null

# ===== VARIÁVEIS INTERNAS =====

var is_connected_: bool = false
var cached_unique_id: int = 0

## { object_id: { last_update: float, target_pos: Vector3, target_rot: Vector3, has_first: bool } }
var client_sync_buffer: Dictionary = {}

# ===== INICIALIZAÇÃO =====

func initialize():
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	game_manager.disconnected_from_server.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	_log_debug("▶️ NetworkManager inicializado com sucesso!")

func _on_connected_to_server():
	is_connected_ = true
	var unique_id := cached_unique_id
	if unique_id == 0 and verificar_rede() and multiplayer.has_multiplayer_peer():
		unique_id = multiplayer.get_unique_id()
		cached_unique_id = unique_id
	_log_debug("Conexão de rede estabelecida")

func _on_server_disconnected():
	is_connected_ = false
	_log_debug("❌ Conexão de rede perdida")

func _on_connection_failed():
	is_connected_ = false
	_log_debug("❌ Falha ao conectar ao servidor")

func _process(delta: float):
	if verificar_rede() and multiplayer.has_multiplayer_peer() and !multiplayer.is_server():
		_client_interpolate_all(delta)

func _get_log_prefix() -> String:
	var client_id: String = "[ClientID: %d]" % cached_unique_id if cached_unique_id > 0 else ""
	return "[CLIENT][NetworkManager]%s" % client_id


# ===== AUTENTICAÇÃO =====

func send_hello_to_server(_uuid_base: String, _token: String):
	"""Helper local: envia hello ao servidor"""
	# RENOMEADO DESTINO: "server_receive_hello" → "_server_receive_hello"
	rpc_id(1, "_server_receive_hello", {"uuid_base": _uuid_base, "token": _token})

func _client_receive_auth_result(_response: Dictionary):
	game_manager.handle_server_response(_response)


# ===== REGISTRO DE JOGADOR =====

func register_player_name(player_name: String):
	"""Helper local: envia requisição de registro ao servidor"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Registrando jogador: " + player_name)
	rpc_id(1, "_server_register_player_name", player_name)

func _client_update_info(info):
	if game_manager and game_manager.has_method("update_client_info"):
		game_manager.update_client_info(info)

func _client_name_accepted(accepted_name: String):
	_log_debug("Nome aceito: " + accepted_name)
	game_manager._client_name_accepted(accepted_name)

func _client_name_rejected(reason: String):
	_log_debug("❌ Nome rejeitado: " + reason)
	game_manager._client_name_rejected(reason)


# ===== SALAS — HELPERS LOCAIS (enviam RPC ao servidor) =====

func request_rooms_list():
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Solicitando lista de salas")
	rpc_id(1, "_server_request_rooms_list")

func request_return_exit(chosen: bool):
	"""Helper local: envia resposta sobre voltar (true) ou abandonar (false) a partida"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("Enviando resposta de retorno à sala/partida/abandono")
	rpc_id(1, "_server_request_return_exit", chosen)

func create_room(room_name: String, password: String = ""):
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Criando sala: " + room_name)
	rpc_id(1, "_server_create_room", room_name, password)

func join_room(room_id: int, password: String = ""):
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Entrando na sala ID: %d" % room_id)
	rpc_id(1, "_server_join_room", room_id, password)

func join_room_by_name(room_name: String, password: String = ""):
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Entrando na sala: " + room_name)
	rpc_id(1, "_server_join_room_by_name", room_name, password)

func request_update_room_settings(changed_settings: Dictionary):
	# RENOMEADO DESTINO: "server_receive_update_room_settings" → "_server_update_room_settings"
	rpc_id(1, "_server_update_room_settings", changed_settings)

func leave_room():
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Saindo da sala")
	rpc_id(1, "_server_leave_room")

func kick_player_from_room(selected_player_id: String):
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	rpc_id(1, "_server_kick_player", selected_player_id)

func close_room():
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Fechando sala")
	rpc_id(1, "_server_close_room")

# ===== SALAS — RECEBIMENTOS DO SERVIDOR =====

func _client_receive_rooms_list(rooms: Array):
	_log_debug("📥 Lista de salas recebida: %d salas" % rooms.size())
	game_manager._client_receive_rooms_list(rooms)

func _client_receive_room_return_request(_room_name: String):
	_log_debug("Recebendo requisição do servidor para retornar à sala: %s" % _room_name)
	game_manager._client_receive_room_return_request(_room_name)

func _client_broadcast_rooms_list(rooms: Array):
	_log_debug("📥 Atualização de salas recebida: %d salas" % rooms.size())
	game_manager.all_client_receive_rooms_list(rooms)

func _client_room_created(room_data: Dictionary):
	_log_debug("Sala criada: " + str(room_data.get("name", "?")))
	game_manager._client_room_created(room_data)

func _client_joined_room(room_data: Dictionary):
	_log_debug("Entrou na sala: " + str(room_data.get("name", "?")))
	game_manager._client_joined_room(room_data)

func _client_update_match_settings(changed_settings: Dictionary):
	game_manager.client_update_match_settings(changed_settings)

func _client_wrong_password():
	_log_debug("❌ Senha incorreta")
	game_manager._client_wrong_password()

func _client_room_name_error(error: String):
	_log_debug("❌ Erro no nome da sala: " + error)
	game_manager._client_room_name_error(error)

func _client_room_not_found():
	_log_debug("❌ Sala não encontrada")
	game_manager._client_room_not_found()

func _client_room_closed(reason: String):
	_log_debug("❌ Sala fechada: " + reason)
	game_manager._client_room_closed(reason)

func _client_room_updated(room_data: Dictionary):
	_log_debug("📥 Sala atualizada: " + str(room_data.get("name", "?")))
	game_manager._client_room_updated(room_data)

@rpc("authority", "call_remote", "reliable")
func _client_kicked_from_room():
	_log_debug("Foi expulso da sala")
	game_manager._client_kicked_from_room()


# ===== RODADAS — HELPERS LOCAIS =====

func request_start_round(round_settings: Dictionary = {}):
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	_log_debug("📤 Iniciando rodada")
	rpc_id(1, "_server_start_round", round_settings)

# ===== RODADAS — RECEBIMENTOS DO SERVIDOR =====

func _client_round_started(match_data: Dictionary):
	_log_debug("Rodada iniciada")
	game_manager._client_round_started(match_data)

func _client_round_ended(end_data: Dictionary):
	_log_debug("🏁 Rodada finalizada")
	game_manager._client_round_ended(end_data)

func _client_return_to_room(room_data: Dictionary):
	_log_debug("↩️ Voltando para sala")
	game_manager._client_return_to_room(room_data)

func _client_remove_player(peer_id: int):
	_log_debug("👤 Removendo player: %d" % peer_id)
	game_manager._client_remove_player(peer_id)


# ===== SPAWN DE OBJETOS — RECEBIMENTOS DO SERVIDOR =====

func _client_spawn_item(object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_id: int):
	_log_debug("📥 Spawn item ID=%d, Item=%s" % [object_id, item_name])
	if game_manager.has_method("_spawn_on_client"):
		game_manager._spawn_on_client(object_id, round_id, item_name, position, rotation, drop_velocity, owner_id)
	else:
		push_error("GameManager não tem método _spawn_on_client")

func _client_despawn_item(object_id: int, round_id: int):
	_log_debug("📥 Despawn item ID=%d" % object_id)
	unregister_syncable_object(object_id)
	if game_manager.has_method("_despawn_on_client"):
		game_manager._despawn_on_client(object_id, round_id)

func _client_clear_all_objects():
	var count = 0
	for round_id in game_manager.spawned_objects.keys():
		for object_id in game_manager.spawned_objects[round_id].keys():
			var obj_data = game_manager.spawned_objects[round_id][object_id]
			var item_node = obj_data.get("node")
			if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
				item_node.queue_free()
				count += 1
	game_manager.spawned_objects.clear()
	_log_debug("✓ Todos os objetos limpos no cliente (%d objetos)" % count)


# ===== ITENS — HELPERS LOCAIS (enviam RPC ao servidor) =====

func request_pick_up_item(player_id: int, object_id: int) -> void:
	# RENOMEADO DESTINO: "_server_pick_up_player_item" → "_server_pick_up_item"
	rpc_id(1, "_server_pick_up_item", player_id, object_id)

func request_equip_item(player_id: int, object_id: int, slot_type) -> void:
	# RENOMEADO DESTINO: "_server_equip_player_item" → "_server_equip_item"
	rpc_id(1, "_server_equip_item", player_id, object_id, slot_type)

func request_unequip_item(player_id: int, slot_type: String) -> void:
	# RENOMEADO DESTINO: "_server_unequip_player_item" → "_server_unequip_item"
	rpc_id(1, "_server_unequip_item", player_id, slot_type)

func request_swap_items(item_id_1, item_id_2):
	rpc_id(1, "_server_swap_items", item_id_1, item_id_2)

func request_trainer_spawn_item(player_id: int, item_id: int):
	rpc_id(1, "_server_trainer_spawn_item", player_id, item_id)

func request_trainer_drop_item(player_id: int):
	rpc_id(1, "_server_trainer_drop_item", player_id)

func request_trainer_respawn_player(player_id: int):
	rpc_id(1, "_server_trainer_respawn_player", player_id)

func request_drop_item(player_id, obj_id):
	rpc_id(1, "_server_drop_item", player_id, obj_id)

# ===== ITENS — APLICAÇÃO VISUAL NO CLIENTE (chamados pelo servidor) =====

func _client_apply_pick_up(player_id):
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("action_pick_up_item"):
		player_node.action_pick_up_item()

func _client_apply_respawn(player_id, position: Vector3):
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("_respawn_player"):
		player_node._respawn_player(position)

func _client_apply_equip(player_id: int, item_id: int, unequip: bool = false, from_inv_men = false, is_swap = false):
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(item_id, unequip, from_inv_men)
	if player_node and player_node.has_method("execute_item_swap") and is_swap:
		player_node.execute_item_swap()

func _client_apply_drop(player_id: int, item_name: String):
	_log_debug("📥 Dropando equipamento: Player %d, Item %s" % [player_id, item_name])
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("execute_item_drop"):
		player_node.execute_item_drop()

# ===== ITENS — ATUALIZAÇÃO DE INVENTÁRIO NO CLIENTE =====

func _client_add_item_to_inventory(item_id, object_id):
	if game_manager and game_manager.has_method("add_item_to_inventory"):
		game_manager.add_item_to_inventory(item_id, object_id)

func _client_remove_item_from_inventory(object_id):
	if game_manager and game_manager.has_method("remove_item_from_inventory"):
		game_manager.remove_item_from_inventory(object_id)

func _client_equip_item(item_name, object_id, slot):
	if game_manager and game_manager.has_method("equip_item"):
		game_manager.equip_item(item_name, object_id, slot)

func _client_unequip_item(item_id, slot, verify):
	if game_manager and game_manager.has_method("unequip_item"):
		game_manager.unequip_item(int(item_id), slot, verify)

func _client_swap_equipped_item(new_item_name: String, dragged_item: Dictionary, existing_item_id: int, target_slot: String):
	if game_manager and game_manager.has_method("swap_equipped_item"):
		game_manager.swap_equipped_item(new_item_name, dragged_item, existing_item_id, target_slot)


# ===== SINCRONIZAÇÃO DE ESTADO DE JOGADORES =====

func send_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Helper local: envia estado do jogador ao servidor"""
	if not is_connected_:
		return
	rpc_id(1, "_server_player_state", p_id, pos, rot, vel, running, jumping)

func _client_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	var player = game_manager.players_node.get_node_or_null(str(p_id))
	if not player:
		_log_debug("Erro! _client_player_state não encontrou nó remoto de %s" % str(p_id))
		return
	if player.has_method("_client_receive_state"):
		player._client_receive_state(pos, rot, vel, running, jumping)
	else:
		_log_debug("Erro! _client_player_state não encontrou método _client_receive_state em %s" % str(p_id))


# ===== SINCRONIZAÇÃO DE ANIMAÇÕES =====

func send_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
	jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""Helper local: envia estado de animação ao servidor"""
	if not is_connected_:
		return
	rpc_id(1, "_server_player_animation_state", p_id, speed, attacking, defending,
		   jumping, aiming, running, block_attacking, on_floor)

func _client_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	var player = game_manager.players_node.get_node_or_null(str(p_id))
	if player and player.has_method("_client_receive_animation_state"):
		player._client_receive_animation_state(speed, attacking, defending, jumping,
											   aiming, running, block_attacking, on_floor)


# ===== SINCRONIZAÇÃO DE OBJETOS =====

func _client_sync_object(object_id: int, pos: Vector3, rot: Vector3) -> void:
	var buffer = client_sync_buffer.get(object_id)
	if !buffer:
		return
	var now = Time.get_unix_time_from_system()
	buffer.last_update = now
	buffer.target_pos = pos
	buffer.target_rot = rot
	if !buffer.has_first:
		buffer.has_first = true
		var entry = syncable_objects.get(object_id)
		if entry and is_instance_valid(entry.node):
			entry.node.global_position = pos
			if syncable_objects[object_id].config.get("sync_rotation", true):
				entry.node.global_rotation = rot

func _client_interpolate_all(delta: float) -> void:
	var now = Time.get_unix_time_from_system()
	var to_remove = []
	for object_id in client_sync_buffer.keys():
		var buffer = client_sync_buffer[object_id]
		var entry = syncable_objects.get(object_id)
		if !entry or !buffer.has_first:
			continue
		var node = entry.node
		if !is_instance_valid(node):
			to_remove.append(object_id)
			continue
		if now - buffer.last_update > 1.0:
			continue
		var config = entry.config
		var threshold = config.get("teleport_threshold", 0.01)
		var speed = config.get("interpolation_speed", 22.0)
		var sync_rot = config.get("sync_rotation", true)
		var dist = node.global_position.distance_to(buffer.target_pos)
		if dist > threshold:
			node.global_position = buffer.target_pos
			if sync_rot:
				node.global_rotation = buffer.target_rot
		elif dist > 0.01:
			node.global_position = node.global_position.lerp(buffer.target_pos, speed * delta)
			if sync_rot:
				node.global_rotation = node.global_rotation.slerp(buffer.target_rot, speed * delta)
	for oid in to_remove:
		unregister_syncable_object(oid)

func register_syncable_object(object_id: int, node: Node, config: Dictionary) -> void:
	if syncable_objects.has(object_id):
		push_warning("Tentativa de registrar objeto sincronizável duplicado: %d" % object_id)
		return
	if !node.is_inside_tree():
		push_error("Não é possível registrar nó fora da árvore: %d" % object_id)
		return
	syncable_objects[object_id] = { "node" = node, "config" = config }
	client_sync_buffer[object_id] = {
		"last_update" = 0.0,
		"target_pos" = node.global_position,
		"target_rot" = node.global_rotation,
		"has_first" = false
	}
	_log_debug("✅ Objeto registrado para sync: %d" % object_id)

func unregister_syncable_object(object_id: int) -> void:
	if syncable_objects.has(object_id):
		syncable_objects.erase(object_id)
	if client_sync_buffer.has(object_id):
		client_sync_buffer.erase(object_id)
	_log_debug("🗑️ Objeto removido do sync: %d" % object_id)


# ===== AÇÕES (ATAQUES, DEFESA) =====

func send_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""Helper local: envia ação do jogador ao servidor"""
	if not is_connected_:
		return
	_log_debug("⚔️ Enviando ação: %s (%s)" % [action_type, anim_name])
	rpc_id(1, "_server_player_action", p_id, action_type, item_equipado_nome, anim_name)

func _client_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	_log_debug("⚔️ Recebendo ação: Player %d - %s" % [p_id, action_type])
	var player = game_manager.players_node.get_node_or_null(str(p_id))
	if player and player.has_method("_client_receive_action"):
		player._client_receive_action(action_type, item_equipado_nome, anim_name)

func _client_receive_attack(body_name):
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	var player = game_manager.players_node.get_node_or_null(str(body_name))
	if player and player.has_method("take_damage"):
		player.take_damage()


# ===== ERROS =====

func _client_receive_error(error_message: String):
	_log_debug("❌ ERRO DO SERVIDOR: " + error_message)
	if game_manager and game_manager.has_method("_server_to_client_error"):
		game_manager._server_to_client_error(error_message)
