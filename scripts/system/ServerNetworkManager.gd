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

var _blocked_until := {}

var _player_rpc_timestamps = {}

## Atenção! A informação em client_latency_map é uma informação não confiável q vem do cliente
var client_latency_map: Dictionary = {}
var last_ping_from_client : Dictionary = {} # peer_id -> timestamp
var timeout_limit := 4000 # ms

## Sincronização de objetos
const _PEER_READY_DELAY := 0.15  # segundos de carência pós-conexão

# ===== VARIÁVEIS DE SYNC (servidor) =====

## { round_id: int → { "timer": float, "rate": float } }
var _round_sync: Dictionary = {}

## { peer_id: int → countdown: float }
var _pending_peers: Dictionary = {}

## { peer_id: int → true }
var _excluded_peers: Dictionary = {}

## Último estado enviado por objeto — base da delta compression
## { object_id: int → { "pos": Vector3, "rot": Vector3 } }
var _last_sent_state: Dictionary = {}

## Threshold de posição para considerar mudança (metros)
@export var pos_change_threshold: float = 0.005

## Threshold de rotação para considerar mudança (radianos)
@export var rot_change_threshold: float = 0.005

# ===== INICIALIZAÇÃO =====

func initialize():
	_player_rpc_timestamps.clear()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_log_debug("▶️ NetworkManager inicializado com sucesso!")

func _process(delta: float):
	_drain_pending_peers(delta)  
	_server_update_batch(delta)
	_client_timout_detection(delta)


# ===== CLIENT TIMOUT DETECTOR =====

# isso remove da lista de timout quando o cliente se reconecta, mas e se ele sumir pra sempre? 
# fazer um sistema de lipeza periódica

func remove_client_from_timeout_detection(peer_uuid: String):
	if last_ping_from_client.has(peer_uuid):
		last_ping_from_client.erase(peer_uuid)

func _client_timout_detection(_delta):
	var now = Time.get_ticks_msec()
	
	for peer_uuid in last_ping_from_client.keys():
		var last_time = last_ping_from_client[peer_uuid]
		
		if now - last_time > timeout_limit:
			_on_client_timeout(peer_uuid)

func _on_client_timeout(peer_uuid: String):
	# Sistema para impedir execução múltipla
	# Só passa se não for DISCONNECTED
	var state = client_registry.get_player_state(peer_uuid)
	var state_list = [client_registry.ClientState.DISCONNECTED]
	if state in state_list:
		return
	
	# Não passa se for LOADING
	if state == client_registry.ClientState.LOADING:
		return
	
	_log_debug("Timout de cliente %s, definindo como desconectado" % peer_uuid)
	var peer_id = client_registry.get_peer_id_by_uuid(peer_uuid)
	
	_safe_disconnect(peer_id)
	# Define cliente como desconectado
	client_registry.set_disconnected_peer(peer_id)


# ===== HEARTBEAT =====

# No seu script do Servidor
func _client_send_ping(client_time: float):
	var sender = multiplayer.get_remote_sender_id()
	var player_uuid = client_registry.get_uuid_by_peer_id(sender)
	if player_uuid != "":
		# Opcional: Atualizar último visto para detecção de timeout no servidor
		var now = Time.get_ticks_msec() 
		last_ping_from_client[player_uuid] = now 
		
		# 1. Recebe o 'client_time' e o devolve imediatamente (ECHO)
		# NÃO faça 'now - client_time' aqui, pois os relógios são diferentes!
		
		# 2. Envia de volta o mesmo timestamp para o cliente específico
		# Ajuste a chamada RPC conforme sua estrutura (network_manager ou direto)
	rpc_id(sender, "_client_receive_pong", client_time)

# Recebe o ping calculado pelo cliente
func _server_report_ping(client_latency: int):
	var sender = multiplayer.get_remote_sender_id()
	var player_uuid = client_registry.get_uuid_by_peer_id(sender)
	
	if player_uuid != "":
		# Armazena o ping para usar em lag compensation ou matchmaking
		client_latency_map[player_uuid] = client_latency


# ===== CONECÇÃO =====

func _on_peer_connected(peer_id: int) -> void:
	# Não adiciona direto ao ciclo de sync — coloca em quarentena primeiro
	_pending_peers[peer_id] = _PEER_READY_DELAY

func _on_peer_disconnected(peer_id: int):
	if _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps.erase(peer_id)
	if not _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps[peer_id] = []

func is_rpc_allowed(peer_id: int) -> bool:
	var now := Time.get_ticks_msec()
	
	if _blocked_until.has(peer_id) and now < _blocked_until[peer_id]:
		return false
	
	if not _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps[peer_id] = []
	
	var timestamps = _player_rpc_timestamps[peer_id]
	
	timestamps = timestamps.filter(func(t): return now - t < 1000)
	_player_rpc_timestamps[peer_id] = timestamps
	
	if timestamps.size() >= 5:
		_blocked_until[peer_id] = now + 2000 # bloqueia 2s
		return false
	
	timestamps.append(now)
	return true


# ===== AUTENTICAÇÃO =====

func _server_receive_hello(payload: Dictionary):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	var response = server_manager.process_client_hello(payload, peer_id)
	# Destino: game_manager.handle_server_response
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

func _server_request_return_or_exit(_chosen: bool):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
		
	var peer_id = multiplayer.get_remote_sender_id()
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)

	# Sistema para impedir execução múltipla
	# Só aceita se estava in game ou no lobby
	var state = client_registry.get_player_state(player_uuid)
	var state_list = [client_registry.ClientState.IN_GAME, client_registry.ClientState.LOBBY]
	if state not in state_list:
		_log_debug("Estado de jogador %s não está entre: %s. Estado atual:  %s" % [player_uuid, state_list, state])
		return
	
	# Se está voltando, define RETURNING, se false, quer abandonar: DISCONNECTED
	if _chosen:
		client_registry.set_player_state(player_uuid, client_registry.ClientState.RETURNING)
	else:
		client_registry.set_player_state(player_uuid, client_registry.ClientState.LOBBY)
	
	server_manager._handle_request_return_or_exit(peer_id, _chosen)

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

## Cliente avisa servidor que concluiu o carregamento de seu round e envia check_this_ para
## checagem de integridade.
func _server_player_ready(check_this_: Dictionary):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var peer_id = multiplayer.get_remote_sender_id()
	_log_debug("Cliente de peer_id %d informou que seu round está carregado" % [peer_id])
	
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Sistema para impedir execução múltipla
	# Só aceita se estava carregando
	var state = client_registry.get_player_state(player_uuid)
	var state_list = [client_registry.ClientState.LOADING]
	if state not in state_list:
		_log_debug("Estado (Atual: %s) de jogador %d não está entre: %s" % [state, peer_id, state_list])
		return
		
	await get_tree().process_frame
	
	resume_peer_sync(peer_id)
	
	client_registry.set_player_state(player_uuid, client_registry.ClientState.IN_GAME)
	
	# Checagens pós load:
	# Checa se 'players' no round recém carregado no cliente está atualizado, se não, atualizar.
	var r_players = check_this_["current_round"]["players"]
	var check_this_host_uuid = null
	for r_player in r_players:
		var r_uuid = r_player["uuid_base"]
		var r_name = r_player["name"]
		if r_player["is_host"]:
			check_this_host_uuid = r_player["uuid_base"]
		
		if r_uuid not in round_registry.get_active_players_uuids(check_this_["current_round"]["round_id"]):
			# Verificar se jogador ainda está na partida, se não, remover remoto dele no cliente
			if _is_peer_connected(peer_id):
				var text = "Jogador %s desistiu da partida" % r_name
				_client_receive_message.rpc_id(peer_id, text, 6, "info")
				rpc_id(peer_id, "_client_remove_player", r_uuid)

	# Checa se o host da sala deste round mudou para notificar isto
	var p_room_id = client_registry.get_player_room(player_uuid)
	var room = room_registry.get_room(p_room_id)
	# Só notifica se mudar e se for o próprio host
	if check_this_host_uuid != room["host_uuid"] and check_this_host_uuid == player_uuid:
		var text = "Agora você é o host dessa sala: %s" % room["name"]
		_client_receive_message.rpc_id(peer_id, text, 6, "info")


# ===== RODADAS =====

func _server_start_round(round_settings: Dictionary):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
		
	var peer_id = multiplayer.get_remote_sender_id()
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Sistema para impedir execução múltipla
	# Só aceita se estava no lobby
	var state = client_registry.get_player_state(player_uuid)
	var state_list = [client_registry.ClientState.LOBBY]
	if state not in state_list:
		_log_debug("Estado de jogador %s não está entre: %s" % [state, state_list])
		return
	
	server_manager._handle_start_round(peer_id, round_settings)
	
func _mark_player_disconnected(_chosen: bool):
	#if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		#return
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._mark_player_disconnected(peer_id, _chosen)
	
	
# ===== ITENS — RECEBIMENTOS DO CLIENTE =====

func _server_pick_up_item(peer_id, object_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_pick_up_item(peer_id, object_id)

func _server_equip_item(peer_id, item_id, slot_type):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_equip_item(peer_id, item_id, slot_type)

func _server_unequip_item(peer_id, item_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_unequip_item(peer_id, item_id)

func _server_swap_items(item_id_1: int, item_id_2: int):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_swap_items(item_id_1, item_id_2)

func _server_trainer_spawn_item(peer_id: int, item_id: int):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_spawn_item(peer_id, item_id)

func _server_trainer_drop_item(peer_id: int):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_drop_item(peer_id)

func _server_trainer_respawn_player(peer_id: int):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	var player_uuid: String = client_registry.get_uuid_by_peer_id(peer_id)
	server_manager._server_trainer_repawn_player(peer_id, player_uuid)

func _server_drop_item(peer_id: int, obj_id: int):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_drop_item(peer_id, obj_id)

func _server_player_action(peer_id: int, action_type: String, item_equipado_nome, anim_name: String):
	server_manager._server_player_action(peer_id, action_type, item_equipado_nome, anim_name)


# ===== SINCRONIZAÇÃO DE ESTADO DE JOGADORES =====

func _server_player_state(peer_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	if multiplayer.multiplayer_peer == null:
		return
	
	var peers = multiplayer.get_peers()
	
	if peer_id not in peers:
		return

	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != peer_id:
		push_warning("⚠️ Jogador %d tentou enviar estado do jogador %d" % [sender_id, peer_id])
		return
	
	# Aplica no nó do servidor
	server_manager._apply_player_state_on_server(peer_id, pos, rot, vel, running, jumping)
	
	var sender_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var round_ = round_registry.get_round_by_player_uuid(sender_uuid)
	
	if not round_:
		return
		
	var round_id = round_["id"]
	var players_round = round_registry.get_active_players_uuids(round_id)
	
	for r_peer_uuid in players_round:
		if r_peer_uuid != sender_uuid:
			var session_id = client_registry.get_peer_id_by_uuid(r_peer_uuid)
			if not _is_peer_connected(session_id):
				return
			rpc_id(session_id, "_client_player_state", peer_id, pos, rot, vel, running, jumping)

func _server_player_animation_state(peer_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):

	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != peer_id:
		return
	
	# Aplica no nó do servidor
	server_manager._apply_animation_state_on_server(peer_id, speed, attacking, defending, jumping, aiming, running, block_attacking, on_floor)

	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	if not round_:
		return
	var players_round = round_registry.get_active_players_uuids(round_["id"])
	for r_peer_id in players_round:
		if r_peer_id != player_uuid:
			var session_id = client_registry.get_peer_id_by_uuid(r_peer_id)
			if not _is_peer_connected(session_id):
				return
			rpc_id(session_id, "_client_player_animation_state", peer_id, speed, attacking,
				   defending, jumping, aiming, running, block_attacking, on_floor)
				
func _correct_player_position(peer_id: int, correct_position: Vector3):
	rpc_id(peer_id, "server_force_position", correct_position)


# ===== SYNC =====

# SYNC EM LOTE POR ROUND
## Inicia o loop de sincronização em lote para um round.
## Chame quando o round realmente começar.
func start_round_sync(round_id: int, sync_rate: float = 0.04) -> void:
	if _round_sync.has(round_id):
		push_warning("[ObjSync] Round %d já está em sync." % round_id)
		return
	_round_sync[round_id] = { "timer": 0.0, "rate": sync_rate }
	_log_debug("[ObjSync] ▶ Sync iniciado — round %d (rate: %.3fs)" % [round_id, sync_rate])

## Para o sync de um round inteiro (fim de round).
## Chame também quando o último jogador de um round desconectar.
func stop_round_sync(round_id: int) -> void:
	_round_sync.erase(round_id)
	_log_debug("[ObjSync] ⏹ Sync parado — round %d" % round_id)

## Exclui imediatamente um peer de todos os envios futuros.
## Chame ao detectar desconexão, antes que o registry seja limpo.
func stop_peer_sync(peer_id: int) -> void:
	_excluded_peers[peer_id] = true
	_log_debug("[ObjSync] 🚫 Peer %d excluído do sync" % peer_id)

## Remove a exclusão de um peer (reconexão ou troca de round).
func resume_peer_sync(peer_id: int) -> void:
	if not _is_peer_connected(peer_id):
		return
	_excluded_peers.erase(peer_id)
	_log_debug("[ObjSync] ✅ Peer %d retomou sync" % peer_id)

## Remove peer_ids obsoletos das listas internas.
func remove_old_peer_id(old_peer_id: int) -> void:
	if _excluded_peers.has(old_peer_id):
		_excluded_peers.erase(old_peer_id)
		_log_debug("[ObjSync] Removido %d de _excluded_peers" % old_peer_id)
	if _pending_peers.has(old_peer_id):
		_pending_peers.erase(old_peer_id)
		_log_debug("[ObjSync] Removido %d de _pending_peers" % old_peer_id)

# LOOP PRINCIPAL (servidor)

func _server_update_batch(delta: float) -> void:
	_drain_pending_peers(delta)
	for round_id: int in _round_sync.keys():
		var state: Dictionary = _round_sync[round_id]
		state["timer"] = (state["timer"] as float) + delta
		if (state["timer"] as float) >= (state["rate"] as float):
			state["timer"] = 0.0
			_send_batch_for_round(round_id)

func _drain_pending_peers(delta: float) -> void:
	var ready: Array[int] = []
	for peer_id: int in _pending_peers.keys():
		_pending_peers[peer_id] = (_pending_peers[peer_id] as float) - delta
		if (_pending_peers[peer_id] as float) <= 0.0:
			ready.append(peer_id)
	for peer_id: int in ready:
		_pending_peers.erase(peer_id)
		_log_debug("[ObjSync] ✅ Peer %d saiu da quarentena" % peer_id)

# ENVIO EM LOTE COM DELTA COMPRESSION
func _send_batch_for_round(round_id: int) -> void:
	# 1. Coleta apenas objetos que mudaram desde o último envio
	var ids:       PackedInt32Array   = PackedInt32Array()
	var positions: PackedVector3Array = PackedVector3Array()
	var rotations: PackedVector3Array = PackedVector3Array()

	for object_id: int in syncable_objects.keys():
		var entry: Dictionary = syncable_objects[object_id]

		if (entry["config"] as Dictionary).get("round_id", -1) != round_id:
			continue

		var node: Node = entry["node"]
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue

		var pos: Vector3 = (node as Node3D).global_position
		var rot: Vector3 = (node as Node3D).global_rotation \
		if (entry["config"] as Dictionary).get("sync_rotation", true) \
		else Vector3.ZERO

		if not _has_state_changed(object_id, pos, rot):
			continue

		ids.append(object_id)
		positions.append(pos)
		rotations.append(rot)
		_last_sent_state[object_id] = { "pos": pos, "rot": rot }

	if ids.is_empty():
		return

	# 2. Resolve peers válidos do round
	var target_peers: Array[int] = _get_round_peers(round_id)
	if target_peers.is_empty():
		return

	# 3. Envia um único RPC por peer válido
	var enet_mp: ENetMultiplayerPeer = multiplayer.multiplayer_peer as ENetMultiplayerPeer

	for peer_id: int in target_peers:
		if _pending_peers.has(peer_id) or _excluded_peers.has(peer_id):
			continue

		if enet_mp:
			var ep: ENetPacketPeer = enet_mp.get_peer(peer_id)
			if not ep or ep.get_state() != ENetPacketPeer.STATE_CONNECTED:
				if ep and ep.get_state() == ENetPacketPeer.STATE_CONNECTING:
					if not _pending_peers.has(peer_id):
						_pending_peers[peer_id] = 1.0
				continue

		if not _is_peer_connected(peer_id):
			continue

		_rpc_client_batch_sync.rpc_id(peer_id, round_id, ids, positions, rotations)

## Retorna true se pos ou rot diferirem do último estado enviado além do threshold.
func _has_state_changed(object_id: int, pos: Vector3, rot: Vector3) -> bool:
	if not _last_sent_state.has(object_id):
		return true  # Nunca enviado — força envio completo

	var last: Dictionary = _last_sent_state[object_id]
	var last_pos: Vector3 = last["pos"]
	var last_rot: Vector3 = last["rot"]

	# distance_squared evita raiz quadrada no hot path
	if last_pos.distance_squared_to(pos) > pos_change_threshold * pos_change_threshold:
		return true

	# Rotação componente a componente (distância euclidiana entre ângulos não tem sentido físico)
	if absf(last_rot.x - rot.x) > rot_change_threshold: return true
	if absf(last_rot.y - rot.y) > rot_change_threshold: return true
	if absf(last_rot.z - rot.z) > rot_change_threshold: return true

	return false

func _get_round_peers(round_id: int) -> Array[int]:
	var peers: Array[int] = []
	if not round_registry:
		return peers
	for uuid: String in round_registry.get_active_players_uuids(round_id):
		var pid: int = client_registry.get_peer_id_by_uuid(uuid)
		if pid > 0:
			peers.append(pid)
	return peers

## Registro de objeto.
func register_syncable_object(object_id: int, node: Node, config: Dictionary) -> void:
	if syncable_objects.has(object_id):
		push_warning("[ObjSync] Objeto duplicado: %d" % object_id)
		return
	if not node.is_inside_tree():
		push_error("[ObjSync] Nó fora da árvore: %d" % object_id)
		return
	syncable_objects[object_id] = { "node": node, "config": config }
	# Sem entrada em _last_sent_state → força envio completo na primeira vez
	_log_debug("[ObjSync] ✅ Objeto registrado: %d (round %d)" % [object_id, config.get("round_id", -1)])

func unregister_syncable_object(object_id: int) -> void:
	syncable_objects.erase(object_id)
	_last_sent_state.erase(object_id)
	_log_debug("[ObjSync] 🗑️ Objeto removido do sync: %d" % object_id)


# ===== UTILITÁRIOS =====

## Verifica se um peer ainda está conectado
func _is_peer_connected(peer_id: int) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers
	
func _safe_disconnect(peer_id: int):
	if not multiplayer.has_multiplayer_peer():
		return
	
	var peer = multiplayer.multiplayer_peer
	if peer == null:
		return
	
	# Checa se ainda está ativo
	if not peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return
	
	# Checa se o peer ainda existe
	if peer_id in multiplayer.get_peers():
		# Para o sync de objetos pra este peer:
		stop_peer_sync(peer_id)
		peer.disconnect_peer(peer_id)
	else:
		_log_debug("⚠️ Peer já desconectado: %d" % peer_id)
		
func _get_log_prefix() -> String:
	return "[SERVER][NetworkManager]"
