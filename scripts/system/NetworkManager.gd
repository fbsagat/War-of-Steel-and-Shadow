extends Node
class_name NetworkManager

## NetworkManager - Gerenciador de RPCs compartilhados entre cliente e servidor
## Funções que começam com _server_ só rodam no servidor
## Funções que começam com _client_ só rodam nos clientes

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var server_manager: ServerManager = null
var player_registry: PlayerRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null

var game_manager: GameManager = null
var item_database: ItemDatabase = null

# ===== VARIÁVEIS INTERNAS =====

var is_connected_: bool = false
var _is_server: bool = false
var server_is_headless: bool
var cached_unique_id: int = 0

# --- SINCRONIZAÇÃO DE OBJETOS ---
## { object_id: { node: Node, config: Dictionary } }
var syncable_objects: Dictionary = {}

## Timers de sync no servidor (contagem regressiva até próximo envio)
## { object_id: float }
var sync_timers: Dictionary = {}

## Buffer de interpolação no cliente
## { object_id: { last_update: float, target_pos: Vector3, target_rot: Vector3, has_first: bool } }
var client_sync_buffer: Dictionary = {}

# Configurações de rate limit para pedidor RPCs de clientes
const RPC_RATE_LIMIT_SEC = 0.25  # 4 RPCs por segundo por jogador
const MAX_RPC_QUEUE = 10        # Número máximo de RPCs na fila

# Armazena o último timestamp de RPC por jogador
var _player_rpc_timestamps = {}  # { peer_id: float }
var _player_rpc_queues = {}      # { peer_id: [rpc_data] }

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func initialize():
	if _is_server:
		
		# Inicializar dicionários de proteção
		_player_rpc_timestamps.clear()
		_player_rpc_queues.clear()
		
		# Conectar-se ao evento de desconexão para limpar dados
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		
		_log_debug("Inicializando NetworkManager como servidor")
		
	else:
		_log_debug("Inicializando NetworkManager como cliente")
	
		# Conecta aos sinais de rede (apenas no cliente)
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.server_disconnected.connect(_on_server_disconnected)
		multiplayer.connection_failed.connect(_on_connection_failed)

func _on_connected_to_server():
	"""Callback quando conecta ao servidor"""
	is_connected_ = true
	var unique_id := cached_unique_id
	if unique_id == 0 and verificar_rede() and multiplayer.has_multiplayer_peer():
		unique_id = multiplayer.get_unique_id()
		cached_unique_id = unique_id
	_log_debug("Conexão de rede estabelecida")

func _on_server_disconnected():
	"""Callback quando desconecta do servidor"""
	is_connected_ = false
	
	# Futuramente: Resetar tudo e jogar pro menu de espera de conexão com o servidor
	
	_log_debug("❌ Conexão de rede perdida")

func _on_connection_failed():
	"""Callback quando falha ao conectar"""
	is_connected_ = false
	_log_debug("❌ Falha ao conectar ao servidor")
	
func _process(delta: float):
	if _is_server:
		_server_update_sync_timers(delta)
		return
		
	# cliente seguro
	if verificar_rede() and multiplayer.has_multiplayer_peer() and !multiplayer.is_server():
		_client_interpolate_all(delta)

func is_rpc_allowed(peer_id: int) -> bool:
	"""
	Verifica se o jogador pode enviar um RPC agora.
	:return: true se permitido, false se rate limited
	"""
	if not _is_server:
		return true  # Cliente não precisa de rate limit
	
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
	"""
	Limpa dados do jogador quando ele desconecta.
	"""
	if _player_rpc_timestamps.has(peer_id):
		_player_rpc_timestamps.erase(peer_id)
	if _player_rpc_queues.has(peer_id):
		_player_rpc_queues.erase(peer_id)

# ===== REGISTRO DE JOGADOR =====

func register_player(player_name: String):
	"""Envia requisição de registro de jogador ao servidor"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Registrando jogador: " + player_name)
	rpc_id(1, "_server_register_player", player_name)
	
@rpc("any_peer", "call_remote", "reliable")
func _server_register_player(player_name: String):
	"""RPC: Servidor recebe pedido de registro"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_register_player(peer_id, player_name)
	
@rpc("authority", "call_remote", "reliable")
func update_client_info(info):
	if multiplayer.is_server():
		return
		
	if game_manager and game_manager.has_method("update_client_info"):
		game_manager.update_client_info(info)
		
@rpc("authority", "call_remote", "reliable")
func _client_name_accepted(accepted_name: String):
	"""RPC: Cliente recebe confirmação de nome aceito"""
	if multiplayer.is_server():
		return
		
	_log_debug("Nome aceito: " + accepted_name)
	game_manager._client_name_accepted(accepted_name)
	
@rpc("authority", "call_remote", "reliable")
func _client_name_rejected(reason: String):
	"""RPC: Cliente recebe rejeição de nome"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Nome rejeitado: " + reason)
	game_manager._client_name_rejected(reason)

# ===== GERENCIAMENTO DE SALAS =====

func request_rooms_list():
	"""Solicita lista de salas ao servidor"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Solicitando lista de salas")
	rpc_id(1, "_server_request_rooms_list")

@rpc("any_peer", "call_remote", "reliable")
func _server_request_rooms_list():
	"""RPC: Servidor recebe pedido de lista de salas"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_request_rooms_list(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list(rooms: Array):
	"""RPC: Cliente recebe lista de salas"""
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Lista de salas recebida: %d salas" % rooms.size())
	game_manager._client_receive_rooms_list(rooms)

@rpc("authority", "call_remote", "reliable")
func _client_receive_rooms_list_update(rooms: Array):
	"""RPC: Cliente recebe atualização de lista de salas"""
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Atualização de salas recebida: %d salas" % rooms.size())
	game_manager._client_receive_rooms_list_update(rooms)

func create_room(room_name: String, password: String = ""):
	"""Solicita criação de sala ao servidor"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Criando sala: " + room_name)
	rpc_id(1, "_server_create_room", room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_create_room(room_name: String, password: String):
	"""RPC: Servidor recebe pedido de criação de sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_create_room(peer_id, room_name, password)

@rpc("authority", "call_remote", "reliable")
func _client_room_created(room_data: Dictionary):
	"""RPC: Cliente recebe confirmação de sala criada"""
	if multiplayer.is_server():
		return
	
	_log_debug("Sala criada: " + str(room_data.get("name", "?")))
	game_manager._client_room_created(room_data)

func join_room(room_id: int, password: String = ""):
	"""Solicita entrada em sala por ID"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Entrando na sala ID: %d" % room_id)
	rpc_id(1, "_server_join_room", room_id, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room(room_id: int, password: String):
	"""RPC: Servidor recebe pedido de entrada em sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_join_room(peer_id, room_id, password)

func join_room_by_name(room_name: String, password: String = ""):
	"""Solicita entrada em sala por nome"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Entrando na sala: " + room_name)
	rpc_id(1, "_server_join_room_by_name", room_name, password)

@rpc("any_peer", "call_remote", "reliable")
func _server_join_room_by_name(room_name: String, password: String):
	"""RPC: Servidor recebe pedido de entrada em sala por nome"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_join_room_by_name(peer_id, room_name, password)

@rpc("authority", "call_remote", "reliable")
func _client_joined_room(room_data: Dictionary):
	"""RPC: Cliente recebe confirmação de entrada em sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("Entrou na sala: " + str(room_data.get("name", "?")))
	game_manager._client_joined_room(room_data)

@rpc("authority", "call_remote", "reliable")
func _client_wrong_password():
	"""RPC: Cliente recebe notificação de senha incorreta"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Senha incorreta")
	game_manager._client_wrong_password()

@rpc("authority", "call_remote", "reliable")
func _client_room_name_exists():
	"""RPC: Cliente recebe notificação de sala já tem este nome"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Nome de sala já existe")
	game_manager._client_room_name_exists()

@rpc("authority", "call_remote", "reliable")
func _client_room_name_error(error: String):
	"""RPC: Cliente recebe notificação de erro ao definir nome da sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Erro no nome da sala: " + error)
	game_manager._client_room_name_error(error)

@rpc("authority", "call_remote", "reliable")
func _client_room_not_found():
	"""RPC: Cliente recebe notificação de sala não encontrada"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Sala não encontrada")
	game_manager._client_room_not_found()

func leave_room():
	"""Solicita saída da sala atual"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Saindo da sala")
	rpc_id(1, "_server_leave_room")

@rpc("any_peer", "call_remote", "reliable")
func _server_leave_room():
	"""RPC: Servidor recebe pedido de saída de sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_leave_room(peer_id)

func close_room():
	"""Solicita fechamento da sala (apenas host)"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Fechando sala")
	rpc_id(1, "_server_close_room")

@rpc("any_peer", "call_remote", "reliable")
func _server_close_room():
	"""RPC: Servidor recebe pedido de fechamento de sala"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_close_room(peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_room_closed(reason: String):
	"""RPC: Cliente recebe notificação de sala fechada"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ Sala fechada: " + reason)
	game_manager._client_room_closed(reason)

@rpc("authority", "call_remote", "reliable")
func _client_room_updated(room_data: Dictionary):
	"""RPC: Cliente recebe atualização de dados da sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Sala atualizada: " + str(room_data.get("name", "?")))
	game_manager._client_room_updated(room_data)

# ===== GERENCIAMENTO DE RODADAS =====

func start_round(round_settings: Dictionary = {}):
	"""Solicita início de rodada (apenas host é respondido)"""
	if not is_connected_:
		_log_debug("❌ Erro: Não conectado ao servidor")
		return
	
	_log_debug("📤 Iniciando rodada")
	rpc_id(1, "_server_start_round", round_settings)

@rpc("any_peer", "call_remote", "reliable")
func _server_start_round(round_settings: Dictionary):
	"""RPC: Servidor recebe pedido de início de rodada"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_start_round(peer_id, round_settings)

#func start_match(match_settings: Dictionary = {}):
	#"""Alias para start_round (compatibilidade)"""
	#start_round(match_settings)

@rpc("any_peer", "call_remote", "reliable")
func _server_start_match(match_settings: Dictionary):
	"""RPC: Alias para _server_start_round (compatibilidade)"""
	if not multiplayer.is_server():
		return
	
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	
	var peer_id = multiplayer.get_remote_sender_id()
	server_manager._handle_start_round(peer_id, match_settings)

@rpc("authority", "call_remote", "reliable")
func _client_round_started(match_data: Dictionary):
	"""RPC: Cliente recebe notificação de rodada iniciada"""
	if multiplayer.is_server():
		return
	
	_log_debug("Rodada iniciada")
	game_manager._client_round_started(match_data)

@rpc("authority", "call_remote", "reliable")
func _client_round_ended(end_data: Dictionary):
	"""RPC: Cliente recebe notificação de rodada finalizada"""
	if multiplayer.is_server():
		return
	
	_log_debug("🏁 Rodada finalizada")
	game_manager._client_round_ended(end_data)

@rpc("authority", "call_remote", "reliable")
func _client_return_to_room(room_data: Dictionary):
	"""RPC: Cliente recebe comando para voltar à sala"""
	if multiplayer.is_server():
		return
	
	_log_debug("↩️ Voltando para sala")
	game_manager._client_return_to_room(room_data)

@rpc("authority", "call_remote", "reliable")
func _client_remove_player(peer_id: int):
	"""RPC: Cliente recebe comando para remover player"""
	if multiplayer.is_server():
		return
	_log_debug("👤 Removendo player: %d" % peer_id)
	game_manager._client_remove_player(peer_id)

# ===== SPAWN DE OBJETOS (ObjectSpawner) =====

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_spawn_on_clients(object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_id: int):
	"""
	RPC chamado APENAS pelo servidor para spawnar objeto em clientes
	
	FLUXO CORRETO:
	1. Servidor chama ObjectManager.spawn_item()
	2. ObjectManager spawna no servidor
	3. ObjectManager chama este RPC para cada cliente via rpc_id()
	4. Cada cliente recebe e spawna localmente
	"""
	
	# ✅ Clientes processam, servidor ignora
	if multiplayer.is_server():
		return
	
	_log_debug("📥 RPC recebido: spawn item ID=%d, Item=%s" % [object_id, item_name])
	
	# Chama GameManager para spawnar localmente
	if game_manager.has_method("_spawn_on_client"):
		game_manager._spawn_on_client(object_id, round_id, item_name, position, rotation, drop_velocity, owner_id)
	else:
		push_error("GameManager não tem método _spawn_on_client")
		
@rpc("authority", "call_remote", "reliable")
func _rpc_client_despawn_item(object_id: int, round_id: int):
	if multiplayer.is_server():
		return
	
	_log_debug("📥 RPC recebido: despawn item ID=%d" % object_id)
	
	# Primeiro: remove do sistema de sync
	unregister_syncable_object(object_id)
	
	# Depois: chama despawn no GameManager
	if game_manager.has_method("_despawn_on_client"):
		game_manager._despawn_on_client(object_id, round_id)

@rpc("authority", "call_remote", "reliable")
func _client_clear_all_objects():
	"""
	RPC para limpar todos os objetos (chamado ao sair de rodada)
	"""
	
	if multiplayer.is_server():
		return
	
	var count = 0
	
	# Percorre todas as rodadas registradas
	for round_id in game_manager.spawned_objects.keys():
		for object_id in game_manager.spawned_objects[round_id].keys():
			var obj_data = game_manager.spawned_objects[round_id][object_id]
			var item_node = obj_data.get("node")
			
			if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
				item_node.queue_free()
				count += 1
	
	# Limpa dicionário
	game_manager.spawned_objects.clear()
	
	_log_debug("✓ Todos os objetos limpos no cliente (%d objetos)" % count)

# ===== REQUISIÇÕES DE CLIENTES =====

func request_pick_up_item(player_id: int, object_id: int) -> void:
	"""Requisição do player: Chama RPC no servidor para pedir para equipar um item"""
	rpc_id(1, "_server_pick_up_player_item", player_id, object_id)

func request_equip_item(player_id: int, object_id: int, slot_type) -> void:
	"""Requisição do player: Chama RPC no servidor para pedir para equipar um item"""
	rpc_id(1, "_server_equip_player_item", player_id, object_id, slot_type)

func request_unequip_item(player_id: int, slot_type: String) -> void:
	"""Requisição do player: Chama RPC no servidor para pedir para desequipar um item"""
	rpc_id(1, "_server_unequip_player_item", player_id, slot_type)

func request_swap_items(item_id_1, item_id_2):
	"""Requisição do player: Chama RPC no servidor para pedir para trocar dois itens"""
	rpc_id(1, "_server_swap_items", item_id_1, item_id_2)

func request_trainer_spawn_item(player_id: int, item_id: int):
	"""Requisição do player: Chama RPC no servidor para pedir para spawnar um item na frente dele
	 (trainer de testes, apenas se estiver no modo de testes)"""
	rpc_id(1, "_server_trainer_spawn_item", player_id, item_id)

func handle_test_drop_item_call(player_id: int):
	"""Requisição do player: Chama RPC no servidor para pedir para dropar um item de seu inventário
	 na frente dele (trainer de testes, apenas se estiver no modo de testes)"""
	rpc_id(1, "_server_trainer_drop_item", player_id)

func handle_test_repawn_player_call(player_id: int):
	"""Requisição do player: Chama RPC no servidor para pedir para respawnar novamente
	(trainer de testes, apenas se estiver no modo de testes)"""
	rpc_id(1, "_server_trainer_repawn_player", player_id)

func request_drop_item(player_id, obj_id):
	"""Requisição do player: Chama RPC no servidor para pedir para dropar um item"""
	rpc_id(1, "_server_drop_player_item", player_id, obj_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_pick_up_player_item(player_id, object_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_pick_up_item(player_id, object_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_equip_player_item(player_id, item_id, slot_type):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_equip_item(player_id, item_id, slot_type)

@rpc("any_peer", "call_remote", "unreliable")
func _server_unequip_player_item(player_id, item_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_unequip_item(player_id, item_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_swap_items(item_id_1, item_id_2):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_swap_items(item_id_1, item_id_2)

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_spawn_item(player_id, item_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_spawn_item(player_id, item_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_drop_item(player_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_drop_item(player_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_trainer_repawn_player(player_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_trainer_repawn_player(player_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_drop_player_item(player_id, obj_id):
	if not is_rpc_allowed(multiplayer.get_remote_sender_id()):
		return
	server_manager._server_validate_drop_item(player_id, obj_id)

@rpc("authority", "call_remote", "reliable")
func server_apply_picked_up_item(player_id):
	# Encontra o player e executa a mudança de item pego
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("action_pick_up_item"):
		player_node.action_pick_up_item()
	
@rpc("authority", "call_remote", "reliable")
func server_apply_repawn_player(player_id, position: Vector3):
	# Encontra o player e executa a mudança de respawn
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("_respawn_player"):
		player_node._respawn_player(position)

@rpc("authority", "call_remote", "reliable")
func server_apply_equiped_item(player_id: int, item_id: int, unnequip: bool = false, from_inv_men = false, is_swap = false):
	"""Cliente recebe comando de equipamento equipar ou desequipar"""
	
	if multiplayer.is_server():
		return

	# Encontra o player e executa a mudança de item equipado
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(item_id, unnequip, from_inv_men)
	if player_node and player_node.has_method("execute_item_swap") and is_swap:
		player_node.execute_item_swap()

@rpc("authority", "call_remote", "reliable")
func server_apply_drop_item(player_id: int, item_name: String):
	"""Cliente recebe comando de drop"""
	
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Dropando equipamento: Player %d, Item %s" % [player_id, item_name])
	
	# ENCONTRA O PLAYER E EXECUTA
	var player_node = game_manager.players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("execute_item_drop"):
		player_node.execute_item_drop()

# ===== ATUALIZAÇÕES DE ESTADOS DE CLIENTES =====

func send_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Envia estado do jogador para o servidor (UNRELIABLE - rápido)"""
	
	if not is_connected_:
		return
	
	rpc_id(1, "_server_player_state", p_id, pos, rot, vel, running, jumping)

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Servidor recebe estado do jogador e redistribui para os do mesmo round"""
	# Verificação robusta de servidor
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

@rpc("authority", "call_remote", "unreliable")
func _client_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Cliente recebe estado de OUTRO jogador"""

	# Só processa se NÃO for servidor (o servidor já processa em _apply_player_state_on_server em ServerManager)
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	# ENCONTRA O PLAYER NA CENA (nome = player_id)
	var player = game_manager.players_node.get_node_or_null(str(p_id))
	
	if not player:
		return
	
	# CHAMA FUNÇÃO NO PLAYER PARA ATUALIZAR
	if player.has_method("_client_receive_state"):
		player._client_receive_state(pos, rot, vel, running, jumping)

# ===== SINCRONIZAÇÃO DE ESTADOS DE ANIMAÇÕES =====

func send_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
	jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""Envia estado de animação do jogador para o servidor (UNRELIABLE - menos frequente)"""
	
	# Verifica se está conectado
	if not is_connected_:
		return
	
	rpc_id(1, "_server_player_animation_state", p_id, speed, attacking, defending, 
		   jumping, aiming, running, block_attacking, on_floor)

@rpc("any_peer", "call_remote", "unreliable")
func _server_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""RPC: Servidor recebe estado de animação e redistribui para os do mesmo round"""
	
	var round_id = round_registry.get_round_by_player_id(p_id)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	
	# Se não for o servidor, não recebe
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	# Verificar se o sender é quem diz ser (outro player não pode enviar estado de outro/apenas o seu próprio)
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# Propaga para todos os outros cliente
	for peer_id in players_round:
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_animation_state", p_id, speed, attacking, 
				   defending, jumping, aiming, running, block_attacking, on_floor)

@rpc("authority", "call_remote", "unreliable")
func _client_player_animation_state(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""RPC: Cliente recebe estado de animação de outro jogador"""
	
	# Servidor não recebe estado aqui
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	var player = game_manager.players_node.get_node_or_null(str(p_id))
	if player and player.has_method("_client_receive_animation_state"):
		player._client_receive_animation_state(speed, attacking, defending, jumping, 
											   aiming, running, block_attacking, on_floor)

# ===== ATUALIZADORES DE INVENTÁRIO DE PLAYERS =====

# Adiciona item no inventário do player
@rpc("authority", "call_remote", "reliable")
func local_add_item_to_inventory(item_id, object_id):
	
	# Ignorar se for servidor
	if multiplayer.is_server():
		return

	if game_manager and game_manager.has_method("add_item_to_inventory"):
		game_manager.add_item_to_inventory(item_id, object_id)

# Remove item do inventário do player
@rpc("authority", "call_remote", "reliable")
func local_remove_item_from_inventory(object_id):
	if multiplayer.is_server():
		return
		
	if game_manager and game_manager.has_method("remove_item_from_inventory"):
		game_manager.remove_item_from_inventory(object_id)
		
# Equipa item no inventário do player
@rpc("authority", "call_remote", "reliable")
func local_equip_item(item_name, object_id, slot):
	if multiplayer.is_server():
		return
		
	if game_manager and game_manager.has_method("equip_item"):
		game_manager.equip_item(item_name, object_id, slot)

# Desequipa item no inventário do player
@rpc("authority", "call_remote", "reliable")
func local_unequip_item(item_id, slot, verify):

	if multiplayer.is_server():
		return
		
	if game_manager and game_manager.has_method("unequip_item"):
		game_manager.unequip_item(int(item_id), slot, verify)

# Troca item no inventário do player
@rpc("authority", "call_remote", "reliable")
func local_swap_equipped_item(new_item_name: String, dragged_item: Dictionary, existing_item_id: int, target_slot: String):

	if multiplayer.is_server():
		return
		
	if game_manager and game_manager.has_method("swap_equipped_item"):
		game_manager.swap_equipped_item(new_item_name, dragged_item, existing_item_id, target_slot)

# ===== REGISTRO DE OBJETOS SINCRONIZÁVEIS =====

func _server_update_sync_timers(delta: float) -> void:
	"""
	Servidor: atualiza timers e envia snapshots periódicos.
	"""
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
	"""
	Envia estado do objeto para todos os clientes.
	"""
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

@rpc("authority", "call_remote", "unreliable")
func _on_client_sync_object(object_id: int, pos: Vector3, rot: Vector3) -> void:
	"""
	Cliente: recebe atualização de estado de objeto.
	"""
	if _is_server:
		return
	
	var buffer = client_sync_buffer.get(object_id)
	if !buffer:
		return  # objeto não registrado ou já removido
	
	var now = Time.get_unix_time_from_system()
	buffer.last_update = now
	buffer.target_pos = pos
	buffer.target_rot = rot
	
	if !buffer.has_first:
		buffer.has_first = true
		# Aplica imediatamente no primeiro sync
		var entry = syncable_objects.get(object_id)
		if entry and is_instance_valid(entry.node):
			entry.node.global_position = pos
			if syncable_objects[object_id].config.get("sync_rotation", true):
				entry.node.global_rotation = rot

func _client_interpolate_all(delta: float) -> void:
	"""
	Cliente: interpola todos os objetos registrados.
	"""
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
		
		var time_since = now - buffer.last_update
		if time_since > 1.0:
			continue  # stale update
		
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
	
	# Limpa objetos inválidos
	for oid in to_remove:
		unregister_syncable_object(oid)

func register_syncable_object(object_id: int, node: Node, config: Dictionary) -> void:
	"""
	Registra um objeto para sincronização contínua.
	Deve ser chamado após o objeto estar na árvore e ter object_id válido.
	"""
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
	
	if _is_server:
		sync_timers[object_id] = 0.0
	else:
		client_sync_buffer[object_id] = {
			"last_update" = 0.0,
			"target_pos" = node.global_position,
			"target_rot" = node.global_rotation,
			"has_first" = false
		}
	
	_log_debug("✅ Objeto registrado para sync: %d" % object_id)

func unregister_syncable_object(object_id: int) -> void:
	"""
	Remove um objeto do sistema de sincronização.
	"""
	if syncable_objects.has(object_id):
		syncable_objects.erase(object_id)
	if sync_timers.has(object_id):
		sync_timers.erase(object_id)
	if client_sync_buffer.has(object_id):
		client_sync_buffer.erase(object_id)
	
	_log_debug("🗑️ Objeto removido do sync: %d" % object_id)

# ===== SINCRONIZAÇÃO DE AÇÕES (ATAQUES, DEFESA) =====

func send_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""Envia ação do jogador (ataque, defesa) - RELIABLE (garantido)"""
	if not is_connected_:
		return
	
	_log_debug("⚔️ Enviando ação: %s (%s)" % [action_type, anim_name])
	rpc_id(1, "_server_player_action", p_id, action_type, item_equipado_nome, anim_name)

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""RPC: Servidor recebe ação do jogador e redistribui"""
	
	_log_debug("_server_player_action")
	if server_manager.has_method("_server_player_action"):
		server_manager._server_player_action(p_id, action_type, item_equipado_nome, anim_name)

@rpc("authority", "call_remote", "reliable")
func _client_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""RPC: Cliente recebe ação de outro jogador"""
	
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	_log_debug("⚔️ Recebendo ação: Player %d - %s" % [p_id, action_type])
	
	var player = game_manager.players_node.get_node_or_null(str(p_id))
	if player and player.has_method("_client_receive_action"):
		player._client_receive_action(action_type, item_equipado_nome, anim_name)

@rpc("authority", "call_remote", "reliable")
func _client_player_receive_attack(body_name):
	
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		return
	
	var player = game_manager.players_node.get_node_or_null(str(body_name))
	if player and player.has_method("take_damage"):
		player.take_damage()

# ===== TRATAMENTO DE ERROS =====

@rpc("authority", "call_remote", "reliable")
func _client_error(error_message: String):
	"""RPC: Cliente recebe mensagem de erro"""
	if multiplayer.is_server():
		return
	
	_log_debug("❌ ERRO DO SERVIDOR: " + error_message)
	
	if game_manager and game_manager.has_method("_client_error"):
		game_manager._client_error(error_message)

# ===== VALIDAÇÕES =====

func _validate_spawn_info(spawn_info: Dictionary) -> bool:
	"""Valida estrutura de dados de spawn"""
	
	if not spawn_info.has("object_id"):
		push_error("Cliente: spawn_info sem 'object_id'")
		return false
	
	if not spawn_info.has("item_name"):
		push_error("Cliente: spawn_info sem 'item_name'")
		return false
	
	if not spawn_info.has("position"):
		push_error("Cliente: spawn_info sem 'position'")
		return false
	
	return true

func _is_peer_connected(peer_id: int) -> bool:
	"""Verifica se um peer ainda está conectado"""
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

# ===== UTILITÁRIOS =====

func verificar_rede():
	var peer = multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	is_connected_ = false
	return false

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if not debug_mode:
		return
	
	if _is_server:
		print("[SERVER][NetworkManager]%s" % [message])
	else:
		print("[CLIENT][NetworkManager][ClientID: %d]%s" % [cached_unique_id, message])
