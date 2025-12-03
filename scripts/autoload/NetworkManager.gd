extends Node
## NetworkManager - Gerenciador de RPCs compartilhados entre cliente e servidor
## Funções que começam com _server_ só rodam no servidor
## Funções que começam com _client_ só rodam nos clientes

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS =====

var player_registry: PlayerRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null

## Referência ao ItemDatabase (autoload)
var item_database = null

# ===== VARIÁVEIS INTERNAS =====

var is_connected_: bool = false
var _is_server: bool = false
var server_is_headless: bool = false

# --- SINCRONIZAÇÃO DE OBJETOS ---
## { object_id: { node: Node, config: Dictionary } }
var syncable_objects: Dictionary = {}

## Timers de sync no servidor (contagem regressiva até próximo envio)
## { object_id: float }
var sync_timers: Dictionary = {}

## Buffer de interpolação no cliente
## { object_id: { last_update: float, target_pos: Vector3, target_rot: Vector3, has_first: bool } }
var client_sync_buffer: Dictionary = {}

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	# Detecta se é servidor dedicado
	var args = OS.get_cmdline_args()
	_is_server = "--server" in args or "--dedicated" in args
	
	if _is_server:
		server_is_headless = ServerManager.is_headless
	
	if _is_server:
		player_registry = ServerManager.player_registry
		room_registry = ServerManager.room_registry
		round_registry = ServerManager.round_registry
		object_manager = ServerManager.object_manager
		
		_log_debug("Inicializando NetworkManager como servidor")
		return
	
	item_database = ItemDatabase
	_log_debug("Inicializando NetworkManager como cliente")
	if not item_database:
		push_error("NetworkManager: ItemDatabase não encontrado!")
	
	# Conecta aos sinais de rede (apenas no cliente)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _on_connected_to_server():
	"""Callback quando conecta ao servidor"""
	is_connected_ = true
	_log_debug("Conexão de rede estabelecida")

func _on_server_disconnected():
	"""Callback quando desconecta do servidor"""
	is_connected_ = false
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
	if multiplayer.has_multiplayer_peer() and !multiplayer.is_server():
		_client_interpolate_all(delta)

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
func update_client_info(info):
	if multiplayer.is_server():
		return
		
	if GameManager and GameManager.has_method("update_client_info"):
		GameManager.update_client_info(info)
		
@rpc("authority", "call_remote", "reliable")
func _client_name_accepted(accepted_name: String):
	"""RPC: Cliente recebe confirmação de nome aceito"""
	if multiplayer.is_server():
		return
		
	_log_debug("Nome aceito: " + accepted_name)
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
	
	_log_debug("Sala criada: " + str(room_data.get("name", "?")))
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
	
	_log_debug("Entrou na sala: " + str(room_data.get("name", "?")))
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
	
	_log_debug("Rodada iniciada")
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

@rpc("authority", "call_remote", "reliable")
func _client_remove_player(peer_id: int):
	"""RPC: Cliente recebe comando para remover player"""
	if multiplayer.is_server():
		return
	_log_debug("👤 Removendo player: %d" % peer_id)
	GameManager._client_remove_player(peer_id)

# ===== SPAWN DE OBJETOS (ObjectSpawner) =====

@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_on_clients(active_players, object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, owner_id: int):
	"""
	✅ CORRIGIDO: Envia spawn para clientes ativos na rodada
	"""
	_log_debug("🔄 Spawning item for clients: ID=%d, Item=%s" % [object_id, item_name])
	
	# ✅ CORRIGIDO: Itera pelos players ativos e envia RPC individual
	for player_id in active_players:
		if player_id == 1:  # Ignora servidor
			continue
		
		if _is_peer_connected(player_id):
			_rpc_receive_spawn_on_clients.rpc_id(player_id, object_id, round_id, item_name, position, rotation, owner_id)
	
	_log_debug("✓ Spawn enviado para %d clientes" % (active_players.size() - 1))

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_spawn_on_clients(object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, owner_id: int):
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
	if GameManager.has_method("_spawn_on_client"):
		GameManager._spawn_on_client(object_id, round_id, item_name, position, rotation, owner_id)
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
	if GameManager.has_method("_despawn_on_client"):
		GameManager._despawn_on_client(object_id, round_id)

@rpc("authority", "call_remote", "reliable")
func _client_clear_all_objects():
	"""
	RPC para limpar todos os objetos (chamado ao sair de rodada)
	"""
	
	if multiplayer.is_server():
		return
	
	var count = 0
	
	# Percorre todas as rodadas registradas
	for round_id in GameManager.spawned_objects.keys():
		for object_id in GameManager.spawned_objects[round_id].keys():
			var obj_data = GameManager.spawned_objects[round_id][object_id]
			var item_node = obj_data.get("node")
			
			if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
				item_node.queue_free()
				count += 1
	
	# Limpa dicionário
	GameManager.spawned_objects.clear()
	
	_log_debug("✓ Todos os objetos limpos no cliente (%d objetos)" % count)

# ===== REQUISIÇÕES DE CLIENTES =====

func request_pick_up_item(player_id: int, object_id: int) -> void:
	"""Requisição do player: Chama RPC no servidor para pedir para equipar um item"""
	rpc_id(1, "_server_pick_up_player_item", player_id, object_id)

func request_equip_item(player_id: int, item_id: int, from_test: bool) -> void:
	"""Requisição do player: Chama RPC no servidor para pedir para equipar um item"""
	rpc_id(1, "_server_equip_player_item", player_id, item_id, from_test)

func request_drop_item(player_id, item_id=0):
	"""Requisição do player: Chama RPC no servidor para pedir para dropar um item"""
	rpc_id(1, "_server_drop_player_item", player_id, item_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_pick_up_player_item(player_id, object_id):
	ServerManager._server_validate_pick_up_item(player_id, object_id)

@rpc("any_peer", "call_remote", "unreliable")
func _server_equip_player_item(player_id, item_id, from_test):
	ServerManager._server_validate_equip_item(player_id, item_id, from_test)

@rpc("any_peer", "call_remote", "unreliable")
func _server_drop_player_item(player_id, item_id):
	ServerManager._server_validate_drop_item(player_id, item_id)

@rpc("authority", "call_remote", "reliable")
func server_apply_picked_up_item(player_id):
	# Encontra o player e executa a mudança de item pego
	var player_node = get_tree().root.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("action_pick_up_item"):
		player_node.action_pick_up_item()

@rpc("authority", "call_remote", "reliable")
func server_apply_equiped_item(player_id: int, change_data: int):
	"""Cliente recebe comando de equipamento"""
	
	if multiplayer.is_server():
		return
	
	# Encontra o player e executa a mudança de item equipado
	var player_node = get_tree().root.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(player_node, change_data)

@rpc("authority", "call_remote", "reliable")
func server_apply_drop_item(player_id: int, item: String):
	"""Cliente recebe comando de drop"""
	
	if multiplayer.is_server():
		return
	
	_log_debug("📥 Dropando equipamento: Player %d, Item %s" % [player_id, item])
	
	# ENCONTRA O PLAYER E EXECUTA
	var player_node = get_tree().root.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("execute_item_drop"):
		player_node.execute_item_drop(player_node, item)

# ===== ATUALIZAÇÕES DE ESTADOS DE CLIENTES =====

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
	
	# VALIDAÇÃO: O remetente é quem diz ser?
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		push_warning("⚠️ Jogador %d tentou enviar estado do jogador %d" % [sender_id, p_id])
		return
	
	# OPCIONAL: Validação anti-cheat
	if ServerManager and ServerManager.enable_anticheat:
		if not ServerManager._validate_player_movement(p_id, pos, vel):
			push_warning("⚠️ Movimento suspeito detectado: Jogador %d" % p_id)
			if ServerManager.has_method("_kick_player"):
				ServerManager._kick_player(p_id, "Movimento suspeito detectado")
			return
	
	# ATUALIZA ESTADO NO SERVIDOR (opcional, para autoridade)
	if ServerManager and ServerManager.player_states:
		ServerManager.player_states[p_id] = {
			"pos": pos,
			"rot": rot,
			"vel": vel,
			"running": running,
			"jumping": jumping,
			"timestamp": Time.get_ticks_msec()
		}
	
	ServerManager._apply_player_state_on_server(p_id, pos, rot, vel, running, jumping)
	
	# REDISTRIBUI PARA TODOS OS OUTROS CLIENTES
	for peer_id in multiplayer.get_peers():
		if peer_id != p_id:
			rpc_id(peer_id, "_client_player_state", p_id, pos, rot, vel, running, jumping)

@rpc("authority", "call_remote", "unreliable")
func _client_player_state(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""RPC: Cliente recebe estado de OUTRO jogador"""
	# Só processa se NÃO for servidor VERIFICAR
	#if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1:
		#return
	
	# ENCONTRA O PLAYER NA CENA (nome = player_id)
	var player = get_tree().root.get_node_or_null(str(p_id))
	
	if not player:
		return
	
	# CHAMA FUNÇÃO NO PLAYER PARA ATUALIZAR
	if player.has_method("_client_receive_state"):
		player._client_receive_state(pos, rot, vel, running, jumping)

# ===== SINCRONIZAÇÃO DE ESTADOS DE ANIMAÇÕES =====

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
	
	# PROPAGA PARA TODOS OS OUTROS CLIENTES
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

# ===== ATUALIZADORES DE INVENTÁRIO DE PLAYERS =====

@rpc("authority", "call_remote", "reliable")
func local_add_item_to_inventory(peer_id, item_name):
	_log_debug("local_add_item_to_inventory")
	if multiplayer.is_server():
		return
		
	var player = get_tree().root.get_node_or_null(str(peer_id))
	if not player:
		_log_debug("Não encontrado player para atualizar inventário")
	if player and player.has_method("add_item_to_inventory"):
		player.add_item_to_inventory(item_name)

@rpc("authority", "call_remote", "reliable")
func local_remove_item_from_inventory(peer_id, item_name):
	_log_debug("local_remove_item_from_inventory")
	if multiplayer.is_server():
		return
		
	var player = get_tree().root.get_node_or_null(str(peer_id))
	if not player:
		_log_debug("Não encontrado player para atualizar inventário")
	if player and player.has_method("remove_item_from_inventory"):
		player.remove_item_from_inventory(item_name)

@rpc("authority", "call_remote", "reliable")
func local_equip_item(peer_id, item_name, slot):
	_log_debug("local_equip_item")
	if multiplayer.is_server():
		return
		
	var player = get_tree().root.get_node_or_null(str(peer_id))
	if not player:
		_log_debug("Não encontrado player para atualizar inventário")
	if player and player.has_method("equip_item"):
		player.equip_item(item_name, slot)

@rpc("authority", "call_remote", "reliable")
func local_unequip_item(peer_id, slot):
	_log_debug("local_unequip_item")
	if multiplayer.is_server():
		return
		
	var player = get_tree().root.get_node_or_null(str(peer_id))
	if not player:
		_log_debug("Não encontrado player para atualizar inventário")
	if player and player.has_method("unequip_item"):
		player.unequip_item(slot)

@rpc("authority", "call_remote", "reliable")
func local_swap_equipped_item(player_id, new_item, slot):
	_log_debug("local_swap_equipped_item")
	if multiplayer.is_server():
		return
		
	var player = get_tree().root.get_node_or_null(str(player_id))
	if not player:
		_log_debug("Não encontrado player para atualizar inventário")
	if player and player.has_method("swap_equipped_item"):
		player.swap_equipped_item(new_item, slot)

@rpc("authority", "call_remote", "reliable")
func local_drop_item(player_id, item_name):
	_log_debug("local_drop_item")
	if multiplayer.is_server():
		return
		
	var player = get_tree().root.get_node_or_null(str(player_id))
	if not player:
		_log_debug("Não encontrado player para atualizar inventário")
	if player and player.has_method("drop_item"):
		player.drop_item(item_name)

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

func send_player_action(p_id: int, action_type: String, anim_name: String):
	"""Envia ação do jogador (ataque, defesa) - RELIABLE (garantido)"""
	if not is_connected:
		return
	
	_log_debug("⚔️ Enviando ação: %s (%s)" % [action_type, anim_name])
	rpc_id(1, "_server_player_action", p_id, action_type, anim_name)

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(p_id: int, action_type: String, anim_name: String):
	"""RPC: Servidor recebe ação do jogador e redistribui"""
	
	# Ignora pedidos do servidor (redundancia)
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	# Ignora o próprio player
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# PROPAGA PARA TODOS OS OUTROS CLIENTES (RELIABLE)
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

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		var prefix = "[SERVER]" if _is_server else "[CLIENT]"
		print("%s[NetworkManager]%s" % [prefix, message])
