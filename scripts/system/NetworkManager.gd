extends Node
class_name NetworkManager

## NetworkManager - Classe Base
## Contém funcionalidades compartilhadas entre cliente e servidor

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var initializer = null

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

# ===== VARIÁVEIS COMUNS =====

# --- SINCRONIZAÇÃO DE OBJETOS ---
## { object_id: { node: Node, config: Dictionary } }
var syncable_objects: Dictionary = {}

# ===== FUNÇÕES COMUNS =====

func verificar_rede() -> bool:
	"""Verifica se a conexão de rede está ativa"""
	var peer = multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	return false

func _log_debug(message: String) -> void:
	"""Imprime mensagem de debug se habilitado"""
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "NetworkManager" in initializer.selected:
		return
		
	print("%s %s" % [_get_log_prefix(), message])

func _get_log_prefix() -> String:
	"""Retorna o prefixo de log (deve ser implementado nas classes filhas)"""
	assert(false, "_get_log_prefix() deve ser implementado nas classes filhas")
	return ""

# ===== FUNÇÕES RPC COMPARTILHADAS (declarações vazias) =====

@rpc("any_peer", "call_remote", "unreliable")
func server_receive_hello(_payload: Dictionary):
	pass

@rpc("authority", "call_remote", "unreliable")
func client_receive_auth_result(_response: Dictionary):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_register_player_name(_player_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func update_client_info(_info):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_name_accepted(_accepted_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_name_rejected(_reason: String):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_request_rooms_list():
	pass

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list(_rooms: Array):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list_update(_rooms: Array):
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

@rpc("authority", "call_remote", "reliable")
func _client_joined_room(_room_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_wrong_password():
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_name_exists():
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

@rpc("authority", "call_remote", "reliable")
func _client_room_closed(_reason: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_room_updated(_room_data: Dictionary):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_start_round(_round_settings: Dictionary):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_start_match(_match_settings: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_round_started(_match_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_round_ended(_end_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_return_to_room(_room_data: Dictionary):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_remove_player(_peer_id: int):
	pass

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_spawn_on_clients(_object_id: int, _round_id: int, _item_name: String, _position: Vector3, _rotation: Vector3, _drop_velocity: Vector3, _owner_id: int):
	pass

@rpc("authority", "call_remote", "reliable")
func _rpc_client_despawn_item(_object_id: int, _round_id: int):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_clear_all_objects():
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_pick_up_player_item(_player_id, _object_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_equip_player_item(_player_id, _item_id, _slot_type):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_unequip_player_item(_player_id, _item_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_swap_items(_item_id_1, _item_id_2):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_spawn_item(_player_id, _item_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_drop_item(_player_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_repawn_player(_player_id):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_drop_player_item(_player_id, _obj_id):
	pass

@rpc("authority", "call_remote", "reliable")
func server_apply_picked_up_item(_player_id):
	pass

@rpc("authority", "call_remote", "reliable")
func server_apply_repawn_player(_player_id, _position: Vector3):
	pass

@rpc("authority", "call_remote", "reliable")
func server_apply_equiped_item(_player_id: int, _item_id: int, _unnequip: bool = false, _from_inv_men = false, _is_swap = false):
	pass

@rpc("authority", "call_remote", "reliable")
func server_apply_drop_item(_player_id: int, _item_name: String):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_state(_p_id: int, _pos: Vector3, _rot: Vector3, _vel: Vector3, _running: bool, _jumping: bool):
	pass

@rpc("authority", "call_remote", "unreliable")
func _client_player_state(_p_id: int, _pos: Vector3, _rot: Vector3, _vel: Vector3, _running: bool, _jumping: bool):
	pass

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_animation_state(_p_id: int, _speed: float, _attacking: bool, _defending: bool, _jumping: bool, _aiming: bool, _running: bool, _block_attacking: bool, _on_floor: bool):
	pass

@rpc("authority", "call_remote", "unreliable")
func _client_player_animation_state(_p_id: int, _speed: float, _attacking: bool, _defending: bool, _jumping: bool, _aiming: bool, _running: bool, _block_attacking: bool, _on_floor: bool):
	pass

@rpc("authority", "call_remote", "reliable")
func local_add_item_to_inventory(_item_id, _object_id):
	pass

@rpc("authority", "call_remote", "reliable")
func local_remove_item_from_inventory(_object_id):
	pass

@rpc("authority", "call_remote", "reliable")
func local_equip_item(_item_name, _object_id, _slot):
	pass

@rpc("authority", "call_remote", "reliable")
func local_unequip_item(_item_id, _slot, _verify):
	pass

@rpc("authority", "call_remote", "reliable")
func local_swap_equipped_item(_new_item_name: String, _dragged_item: Dictionary, _existing_item_id: int, _target_slot: String):
	pass

@rpc("authority", "call_remote", "unreliable")
func _on_client_sync_object(_object_id: int, _pos: Vector3, _rot: Vector3):
	pass

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(_p_id: int, _action_type: String, _item_equipado_nome, _anim_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_player_action(_p_id: int, _action_type: String, _item_equipado_nome, _anim_name: String):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_player_receive_attack(_body_name):
	pass

@rpc("authority", "call_remote", "reliable")
func _client_error(_error_message: String):
	pass
