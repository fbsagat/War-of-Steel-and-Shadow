extends Node
class_name NetworkManager

## NetworkManager - Classe Base
## Contém funcionalidades e declarações RPC compartilhadas entre cliente e servidor
##
## CONVENÇÃO DE NOMES:
##   _server_*  → função EXECUTA NO SERVIDOR  (cliente envia via rpc_id(1, "_server_*"))
##   _client_*  → função EXECUTA NO CLIENTE   (servidor envia via rpc_id(peer_id, "_client_*"))
##   sem prefixo → método local, não é RPC

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var initializer: GameInitializer = null

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

# ===== VARIÁVEIS COMUNS =====

## { object_id: { node: Node, config: Dictionary } }
var syncable_objects: Dictionary = {}

# ===== FUNÇÕES COMUNS =====

func verificar_rede() -> bool:
	var peer = multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	return false

func _log_debug(message: String, rpc_debug: bool = false) -> void:
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "NetworkManager" in initializer.selected:
		return
	if rpc_debug and not initializer.rpc_debug:
		return
	print("%s%s%s" % [_get_log_prefix(), "[RPC]" if rpc_debug else "", message])

func _get_log_prefix() -> String:
	assert(false, "_get_log_prefix() deve ser implementado nas classes filhas")
	return ""


# ==============================================================================
# ===== DECLARAÇÕES RPC (implementações nas classes filhas) ====================
# ==============================================================================

# ===== HEARTBEAT =====

@rpc("any_peer", "call_remote", "unreliable")
func _server_send_ping(_client_time):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_report_ping(_latency):
	pass

@rpc("authority", "call_remote", "unreliable")
func _client_receive_pong(_client_time):
	pass

# ===== AUTENTICAÇÃO =====

@rpc("any_peer", "call_remote", "unreliable")
func _server_give_me_configs():
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_receive_hello(_payload: Dictionary):
	pass

@rpc("authority", "call_remote", "unreliable")
func _client_receive_auth_result(_response: Dictionary):
	pass

# ===== REGISTRO DE JOGADOR =====

@rpc("any_peer", "call_remote", "reliable")
func _server_register_player_name(_player_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_update_info(_info):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_name_accepted(_accepted_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_name_rejected(_reason: String):
	pass

# ===== SALAS =====

@rpc("any_peer", "call_remote", "reliable")
func _server_request_rooms_list():
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_request_return_or_exit(_chosen: bool):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list(_rooms: Array):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_receive_round_return_request(_room_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_broadcast_rooms_list(_rooms: Array):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_create_room(_room_name: String, _password: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_created(_room_data: Dictionary):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room(_room_id: int, _password: String):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room_by_name(_room_name: String, _password: String):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_update_room_settings(_changed_settings: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_update_match_settings(_changed_settings: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_joined_room(_room_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_wrong_password():
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_name_error(_error: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_not_found():
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_leave_room():
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_close_room():
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_kick_player(_selected_player_uuid: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_closed(_reason: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_updated(_room_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_kicked_from_room():
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_player_ready(check_this_: Dictionary):
	pass

# ===== RODADAS =====

@rpc("any_peer", "call_remote", "reliable")
func _server_start_round(_round_settings: Dictionary):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _mark_player_disconnected(_chosen: bool):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_round_started(_server_id: String, _match_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_round_return(_server_id: String, _match_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_round_ended(_end_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_return_to_room(_room_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_remove_player(_peer_uuid: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_update_character_peer_id(_uuid_base: String, _new_peer_id: int):
	pass

# ===== SPAWN DE OBJETOS =====

@rpc("authority", "call_remote", "reliable")
func _client_spawn_item(_object_id: int, _round_id: int, _item_name: String, _position: Vector3, _rotation: Vector3, _drop_velocity: Vector3, _owner_uuid: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_despawn_item(_object_id: int, _round_id: int):
	pass

# ===== ITENS — REQUISIÇÕES DO CLIENTE AO SERVIDOR =====

@rpc("any_peer", "call_remote", "unreliable")
func _server_pick_up_item(_object_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_equip_item(_item_id, _slot_type):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_unequip_item(_item_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_swap_items(_item_id_1: int, _item_id_2: int):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_spawn_item(_item_id: int):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_drop_item():
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_respawn_player():
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_drop_item(_obj_id):
	pass

# ===== ITENS — APLICAÇÃO VISUAL NO CLIENTE (chamados pelo servidor) =====

@rpc("authority", "call_remote", "reliable")
func _client_apply_pick_up(_peer_id):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_apply_respawn(_peer_id, _position: Vector3):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_apply_equip(_peer_id: int, _item_id: int, _unequip: bool = false, _from_inv_men = false, _is_swap = false):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_apply_drop(_peer_id: int, _item_name: String):
	pass

# ===== ITENS — ATUALIZAÇÃO DE INVENTÁRIO NO CLIENTE =====

@rpc("authority", "call_remote", "reliable")
func _client_add_item_to_inventory(_item_id, _object_id):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_remove_item_from_inventory(_object_id):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_equip_item(_item_name, _object_id, _slot):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_unequip_item(_item_id, _slot, _verify):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_swap_equipped_item(_new_item_name: String, _dragged_item: Dictionary, _existing_item_id: int, _target_slot: String):
	pass

# ===== SINCRONIZAÇÃO DE ESTADO DE JOGADORES =====

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_state(_pos: Vector3, _rot: Vector3, _vel: Vector3, _running: bool, _jumping: bool):
	pass

@rpc("authority", "call_remote", "unreliable")
func _client_player_state(_p_id: int, _pos: Vector3, _rot: Vector3, _vel: Vector3, _running: bool, _jumping: bool):
	pass

@rpc("authority", "call_remote", "unreliable")
func server_force_position(_pos: Vector3):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_animation_state(_speed: float, _attacking: bool, _defending: bool, _jumping: bool, _aiming: bool, _running: bool, _block_attacking: bool, _on_floor: bool):
	pass

@rpc("authority", "call_remote", "unreliable")
func _client_player_animation_state(_p_id: int, _speed: float, _attacking: bool, _defending: bool, _jumping: bool, _aiming: bool, _running: bool, _block_attacking: bool, _on_floor: bool):
	pass

# ===== SINCRONIZAÇÃO DE OBJETOS =====
	
@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_client_batch_sync(_round_id: int, _ids: PackedInt32Array, _positions: PackedVector3Array, _rotations: PackedVector3Array):
	pass

# ===== AÇÕES (ATAQUES, DEFESA) =====

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(_action_type: String, _item_equipado_nome, _anim_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_player_action(_p_id: int, _action_type: String, _item_equipado_nome, _anim_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_receive_attack(_body_name):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_receive_message(_text: String, _duration: float, _type: String):
	pass

# ===== ERROS =====

@rpc("authority", "call_remote", "reliable")
func _client_receive_error(_error_message: String):
	pass
