extends Node
class_name ObjectManager
## ObjectManager - Gerenciador autoritativo de objetos no mundo (SERVIDOR APENAS)
##
## RESPONSABILIDADES:
## - Spawnar itens no mundo usando ItemDatabase como fonte
## - Replicar spawns para clientes via RPC
## - Despawnar itens quando coletados/destruídos
## - NOVO: Gerenciar objetos guardados (em inventários/baús)
## - Gerenciar objetos por rodada (isolamento entre rodadas)
## - Sincronizar estado com todos os clientes
##
## ESTADOS DOS OBJETOS:
## 1. SPAWNADO: No mundo (spawned_objects)
## 2. GUARDADO: Em inventário/baú (stored_objects)
## 3. DESPAWNADO: Destruído permanentemente
##
## IMPORTANTE: Lógica executa APENAS no servidor, clientes recebem via RPC

# ===== CONFIGURAÇÕES =====

@export_category("Spawn Settings")
@export var drop_distance: float = 1.2  # Distância na frente do player
@export var drop_height: float = 1.2    # Altura acima do chão
@export var drop_variance: float = 0.3  # Variação aleatória

@export_category("Physics Settings")
@export var drop_impulse_strength: float = 3.5
@export var drop_impulse_variance: float = 1.2
@export var drop_impulse_up_multiplier: float = 0.6

@export_category("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS =====

var player_registry: PlayerRegistry = null   # Injetado pelo ServerManager
var round_registry: RoundRegistry = null    # Injetado pelo ServerManager
var item_database: ItemDatabase = null     # Injetado pelo ServerManager

# ===== VARIÁVEIS INTERNAS =====

## Objetos spawnados organizados por rodada
## {round_id: {object_id: {node: Node, item_name: String, owner_id: int, spawn_time: float}}}
var spawned_objects: Dictionary = {}

## ✨ NOVO: Objetos guardados organizados por rodada
## {round_id: {object_id: {item_name: String, owner_id: int, stored_time: float, stored_by: int, transfer_history: Array, custom_data: Dictionary}}}
var stored_objects: Dictionary = {}

## Contador global de IDs únicos
var next_object_id: int = 1

## Estado de inicialização
var _initialized: bool = false

# ===== SINAIS =====

signal object_spawned(round_id: int, object_id: int, item_name: String)
signal object_despawned(round_id: int, object_id: int)
signal object_stored(round_id: int, object_id: int, owner_id: int)
signal object_retrieved(round_id: int, object_id: int)
signal object_transferred(round_id: int, object_id: int, old_owner: int, new_owner: int)
signal round_objects_cleared(round_id: int, count: int)

# ===== INICIALIZAÇÃO =====

func initialize():
	"""Inicializa o ObjectManager (chamado pelo ServerManager)"""
	if _initialized:
		_log_debug("⚠ ObjectManager já inicializado")
		return
	
	# Valida dependências
	if not item_database:
		push_error("ObjectManager: ItemDatabase não encontrado!")
		return
	
	if not item_database.is_loaded:
		push_error("ObjectManager: ItemDatabase não está carregado!")
		return
	
	_initialized = true
	_log_debug("✓ ObjectManager inicializado")

func reset():
	"""Reseta completamente o manager"""
	for round_id in spawned_objects.keys():
		clear_round_objects(round_id)
	
	spawned_objects.clear()
	stored_objects.clear()
	next_object_id = 1
	_initialized = false
	_log_debug("🔄 ObjectManager resetado")

# ===== SPAWN DE OBJETOS - API PRINCIPAL (SERVIDOR) =====

func spawn_item(objects_node, round_id: int, item_name: String, position: Vector3, rotation: Vector3 = Vector3.ZERO, owner_id: int = -1) -> int:
	"""
	Spawna item no servidor e replica para clientes
	
	@param round_id: ID da rodada
	@param item_name: Nome do item no ItemDatabase
	@param position: Posição no mundo
	@param rotation: Rotação (opcional)
	@param owner_id: ID do player que dropou (opcional)
	@return: object_id único ou -1 se falhar
	"""
	
	if not multiplayer.is_server():
		push_error("ObjectManager: spawn_item() só pode ser chamado no servidor!")
		return -1
	
	if not _initialized:
		push_error("ObjectManager: Não inicializado")
		return -1
	
	# Valida item no database
	if not item_database.item_exists(item_name):
		push_error("ObjectManager: Item '%s' não existe no ItemDatabase" % item_name)
		return -1
	
	# Valida rodada
	if not round_registry or not round_registry.is_round_active(round_id):
		push_error("ObjectManager: Rodada %d não está ativa" % round_id)
		return -1
	
	# Gera ID único
	var object_id = _get_next_object_id()
	
	_log_debug("🔨 Spawnando item no servidor, round %s: %s (ID: %d)" % [round_id, item_name, object_id])
	
	# Spawna no servidor
	var item_node = await _spawn_on_server(objects_node, object_id, round_id, item_name, position, rotation, owner_id)
	
	if not item_node:
		push_error("ObjectManager: Falha ao spawnar item '%s' no servidor" % item_name)
		return -1
	
	# Registra no dicionário
	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}
	
	spawned_objects[round_id][object_id] = {
		"node": item_node,
		"item_name": item_name,
		"owner_id": owner_id,
		"spawn_time": Time.get_unix_time_from_system()
	}
	var drop_velocity = item_node.initial_velocity
	# ✅ Envia RPC individual para cada cliente ativo
	_send_spawn_to_clients(round_id, object_id, item_name, position, rotation, drop_velocity, owner_id)
	
	_log_debug("✓ Item spawnado: %s (ID: %d, Round: %d)" % [item_name, object_id, round_id])
	
	object_spawned.emit(round_id, object_id, item_name)
	
	return object_id

func _send_spawn_to_clients(round_id: int, object_id: int, item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_id: int):
	"""
	✅ Envia spawn para clientes ativos na rodada
	Chama RPC individual para cada peer conectado
	"""
	
	if not multiplayer.is_server():
		return
	
	# Obtém players ativos da rodada
	var active_players = round_registry.get_all_spawned_players(round_id)
	
	if active_players.is_empty():
		_log_debug("⚠️  Nenhum player ativo na rodada %d" % round_id)
		return
	
	var clients_sent = 0
	
	# Envia para cada cliente individualmente
	for player_node in active_players:
		if not player_node or not is_instance_valid(player_node):
			continue
		
		var player_id = player_node.player_id
		
		_log_debug("📤 Enviando spawn para peer %d: ID=%d, Item=%s" % [player_id, object_id, item_name])
		
		# Ignora servidor (ID 1)
		if player_id == 1:
			continue
		
		# Verifica se peer está conectado
		if not _is_peer_connected(player_id):
			continue
		
		# ✅ Envia RPC individual via NetworkManager
		NetworkManager._rpc_receive_spawn_on_clients.rpc_id(
			player_id,
			object_id,
			round_id,
			item_name,
			position,
			rotation,
			drop_velocity,
			owner_id
		)
		
		clients_sent += 1
	
	_log_debug("📤 Spawn enviado para %d cliente(s)" % clients_sent)

func spawn_item_in_front_of_player(objects_node, round_id: int, player_id: int, item_name: String) -> int:
	"""
	Spawna item na frente de um player
	USA O ESTADO DO SERVIDOR (ServerManager.player_states)
	
	@return: object_id ou -1 se falhar
	"""
	
	if not multiplayer.is_server():
		return -1
	
	# Valida estado do player
	if not ServerManager.player_states.has(player_id):
		push_error("ObjectManager: Player %d não tem estado no servidor" % player_id)
		return -1
	
	var player_state = ServerManager.player_states[player_id]
	var player_pos = player_state["pos"]
	var player_rot = player_state["rot"]
	
	# Calcula posição na frente do player
	var spawn_pos = _calculate_front_position(player_pos, player_rot)
	var spawn_rot = Vector3.ZERO  # Rotação padrão

	_log_debug("Spawn na frente do player %d: pos=%s" % [player_id, spawn_pos])
	
	return await spawn_item(objects_node, round_id, item_name, spawn_pos, spawn_rot, player_id)

func spawn_item_at_random_position(objects_node, round_id: int, item_name: String, area_center: Vector3, area_radius: float, owner_id: int = -1) -> int:
	"""Spawna item em posição aleatória dentro de uma área circular"""
	
	if not multiplayer.is_server():
		return -1
	
	# Calcula posição aleatória
	var angle = randf() * TAU
	var distance = randf() * area_radius
	
	var spawn_pos = area_center + Vector3(
		cos(angle) * distance,
		0,
		sin(angle) * distance
	)
	
	return await spawn_item(objects_node, round_id, item_name, spawn_pos, Vector3.ZERO, owner_id)

# ===== DESPAWN DE OBJETOS (SERVIDOR) =====

func despawn_object(round_id: int, object_id: int) -> bool:
	"""
	Despawna objeto do servidor e replica para clientes
	
	@return: true se sucesso
	"""
	
	if not multiplayer.is_server():
		push_error("ObjectManager: despawn_object() só pode ser chamado no servidor!")
		return false
	
	# Valida existência
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		push_warning("ObjectManager: Objeto %d não existe na rodada %d" % [object_id, round_id])
		return false
	
	var obj_data = spawned_objects[round_id][object_id]
	var item_node = obj_data["node"]
	
	# Remove do servidor
	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()
	
	# ✅ Desregistra do NetworkManager
	if item_node and item_node.has_method("get_sync_config") and item_node.sync_enabled:
		NetworkManager.unregister_syncable_object(object_id)
	
	# Remove do registro
	spawned_objects[round_id].erase(object_id)
	
	# ✅ CORRIGIDO: Envia despawn para clientes ativos
	_send_despawn_to_clients(round_id, object_id)
	
	_log_debug("✓ Objeto despawnado: ID %d (Round: %d)" % [object_id, round_id])
	
	object_despawned.emit(round_id, object_id)
	
	return true

func _send_despawn_to_clients(round_id: int, object_id: int):
	"""
	✅ NOVA FUNÇÃO: Envia despawn para clientes ativos na rodada
	"""
	
	if not multiplayer.is_server():
		return
	
	var active_players = round_registry.get_all_spawned_players(round_id)
	
	for player_node in active_players:
		if not player_node or not is_instance_valid(player_node):
			continue
		
		var player_id = player_node.player_id
		
		if player_id == 1 or not _is_peer_connected(player_id):
			continue
		
		# ✅ Envia RPC individual
		NetworkManager._rpc_client_despawn_item.rpc_id(player_id, object_id, round_id)

func _is_peer_connected(peer_id: int) -> bool:
	"""Verifica se um peer está conectado"""
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

func despawn_object_by_node(round_id: int, node: Node) -> bool:
	"""Despawna objeto pela referência do node"""
	
	if not spawned_objects.has(round_id):
		return false
	
	# Encontra ID do objeto
	for object_id in spawned_objects[round_id]:
		if spawned_objects[round_id][object_id]["node"] == node:
			return despawn_object(round_id, object_id)
	
	push_warning("ObjectManager: Node não encontrado no registro")
	return false

func clear_round_objects(round_id: int):
	"""Remove todos os objetos de uma rodada (spawnados E guardados)"""
	
	if not multiplayer.is_server():
		return
	
	var total_count = 0
	
	# Limpa objetos spawnados
	if spawned_objects.has(round_id):
		var spawned_count = spawned_objects[round_id].size()
		var object_ids = spawned_objects[round_id].keys()
		for object_id in object_ids:
			despawn_object(round_id, object_id)
		total_count += spawned_count
		spawned_objects.erase(round_id)
	
	# Limpa objetos guardados
	if stored_objects.has(round_id):
		var stored_count = stored_objects[round_id].size()
		stored_objects.erase(round_id)
		total_count += stored_count
	
	_log_debug("✓ Objetos da rodada %d limpos (%d total)" % [round_id, total_count])
	
	round_objects_cleared.emit(round_id, total_count)

# ===== 🆕 SISTEMA DE OBJETOS GUARDADOS =====

func store_object(round_id: int, object_id: int, owner_id: int, custom_data: Dictionary = {}) -> bool:
	"""
	Move objeto do estado SPAWNADO para GUARDADO
	Remove do mundo e adiciona ao inventário/baú
	
	@param round_id: ID da rodada
	@param object_id: ID do objeto
	@param owner_id: ID do dono (player ou baú)
	@param custom_data: Dados customizados do item (durabilidade, encantamentos, etc)
	@return: true se sucesso
	"""
	
	if not multiplayer.is_server():
		push_error("ObjectManager: store_object() só pode ser chamado no servidor!")
		return false
	
	# Valida que objeto está spawnado
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		push_error("ObjectManager: Objeto %d não está spawnado na rodada %d" % [object_id, round_id])
		return false
	
	var obj_data = spawned_objects[round_id][object_id]
	var item_name = obj_data["item_name"]
	var item_node = obj_data["node"]
	
	# Extrai dados customizados do item (se tiver método get_custom_data)
	var final_custom_data = custom_data.duplicate()
	if item_node and item_node.has_method("get_custom_data"):
		var node_data = item_node.get_custom_data()
		final_custom_data.merge(node_data, true)
	
	# Remove do mundo
	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()
	
	# Remove do registro de spawnados
	spawned_objects[round_id].erase(object_id)
	
	# Adiciona ao registro de guardados
	if not stored_objects.has(round_id):
		stored_objects[round_id] = {}
	
	stored_objects[round_id][object_id] = {
		"item_name": item_name,
		"owner_id": owner_id,
		"stored_time": Time.get_unix_time_from_system(),
		"stored_by": owner_id,
		"transfer_history": [{"from": obj_data.get("owner_id", -1), "to": owner_id, "time": Time.get_unix_time_from_system()}],
		"custom_data": final_custom_data
	}
	
	# Envia despawn para clientes (objeto sumiu do mundo)
	_send_despawn_to_clients(round_id, object_id)
	
	_log_debug("📦 Objeto guardado: ID %d → Owner %d (Round: %d)" % [object_id, owner_id, round_id])
	
	object_stored.emit(round_id, object_id, owner_id)
	
	return true

func retrieve_stored_object(objects_node, round_id: int, object_id: int, position: Vector3, rotation: Vector3 = Vector3.ZERO, new_owner_id: int = -1) -> bool:
	"""
	Move objeto do estado GUARDADO para SPAWNADO
	Spawna objeto guardado de volta ao mundo
	
	@param round_id: ID da rodada
	@param object_id: ID do objeto guardado
	@param position: Posição para spawnar
	@param rotation: Rotação
	@param new_owner_id: Novo dono (quem dropou)
	@return: true se sucesso
	"""
	
	if not multiplayer.is_server():
		push_error("ObjectManager: retrieve_stored_object() só pode ser chamado no servidor!")
		return false
	
	# Valida que objeto está guardado
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		push_error("ObjectManager: Objeto %d não está guardado na rodada %d" % [object_id, round_id])
		return false
	
	var stored_data = stored_objects[round_id][object_id]
	var item_name = stored_data["item_name"]
	var custom_data = stored_data["custom_data"]
	
	# Remove do registro de guardados
	stored_objects[round_id].erase(object_id)
	
	# Spawna no mundo
	var item_node = await _spawn_on_server(objects_node, object_id, round_id, item_name, position, rotation, new_owner_id)
	
	if not item_node:
		push_error("ObjectManager: Falha ao respawnar objeto guardado %d" % object_id)
		# Reverte para guardado
		stored_objects[round_id][object_id] = stored_data
		return false
	
	# Restaura dados customizados
	if item_node.has_method("set_custom_data"):
		item_node.set_custom_data(custom_data)
	
	# Registra como spawnado
	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}
	
	spawned_objects[round_id][object_id] = {
		"node": item_node,
		"item_name": item_name,
		"owner_id": new_owner_id,
		"spawn_time": Time.get_unix_time_from_system()
	}
	var drop_velocity = item_node.initial_velocity
	# Envia spawn para clientes
	_send_spawn_to_clients(round_id, object_id, item_name, position, rotation, drop_velocity, new_owner_id)
	
	_log_debug("📤 Objeto respawnado: ID %d (Round: %d)" % [object_id, round_id])
	
	object_retrieved.emit(round_id, object_id)
	
	return true

func transfer_stored_object(round_id: int, object_id: int, new_owner_id: int) -> bool:
	"""
	Transfere objeto guardado entre inventários
	Estado permanece GUARDADO, apenas muda o dono
	
	@param round_id: ID da rodada
	@param object_id: ID do objeto
	@param new_owner_id: Novo dono
	@return: true se sucesso
	"""
	
	if not multiplayer.is_server():
		push_error("ObjectManager: transfer_stored_object() só pode ser chamado no servidor!")
		return false
	
	# Valida que objeto está guardado
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		push_error("ObjectManager: Objeto %d não está guardado na rodada %d" % [object_id, round_id])
		return false
	
	var stored_data = stored_objects[round_id][object_id]
	var old_owner = stored_data["owner_id"]
	
	# Atualiza dono
	stored_data["owner_id"] = new_owner_id
	
	# Adiciona ao histórico de transferências
	stored_data["transfer_history"].append({
		"from": old_owner,
		"to": new_owner_id,
		"time": Time.get_unix_time_from_system()
	})
	
	_log_debug("🔄 Objeto transferido: ID %d, %d → %d" % [object_id, old_owner, new_owner_id])
	
	object_transferred.emit(round_id, object_id, old_owner, new_owner_id)
	
	return true

func destroy_stored_object(round_id: int, object_id: int) -> bool:
	"""
	Destrói objeto guardado permanentemente
	Move do estado GUARDADO para DESPAWNADO
	
	@return: true se sucesso
	"""
	
	if not multiplayer.is_server():
		push_error("ObjectManager: destroy_stored_object() só pode ser chamado no servidor!")
		return false
	
	# Valida existência
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		push_warning("ObjectManager: Objeto %d não está guardado na rodada %d" % [object_id, round_id])
		return false
	
	# Remove do registro
	stored_objects[round_id].erase(object_id)
	
	_log_debug("❌ Objeto guardado destruído: ID %d (Round: %d)" % [object_id, round_id])
	
	object_despawned.emit(round_id, object_id)
	
	return true

# ===== 🆕 QUERIES DE OBJETOS GUARDADOS =====

func get_stored_object_data(round_id: int, object_id: int) -> Dictionary:
	"""Retorna dados completos de um objeto guardado"""
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		return {}
	return stored_objects[round_id][object_id].duplicate()

func stored_object_exists(round_id: int, object_id: int) -> bool:
	"""Verifica se objeto está guardado"""
	return stored_objects.has(round_id) and stored_objects[round_id].has(object_id)

func get_stored_objects_by_owner(round_id: int, owner_id: int) -> Array:
	"""
	Retorna lista de IDs de objetos guardados de um dono
	@return: Array de object_ids
	"""
	if not stored_objects.has(round_id):
		return []
	
	var result = []
	for object_id in stored_objects[round_id]:
		if stored_objects[round_id][object_id]["owner_id"] == owner_id:
			result.append(object_id)
	
	return result

func get_stored_objects_full_data(round_id: int, owner_id: int) -> Array:
	"""
	Retorna dados completos de objetos guardados de um dono
	@return: Array de dicionários com {object_id, item_name, custom_data, ...}
	"""
	if not stored_objects.has(round_id):
		return []
	
	var result = []
	for object_id in stored_objects[round_id]:
		var data = stored_objects[round_id][object_id]
		if data["owner_id"] == owner_id:
			var full_data = data.duplicate()
			full_data["object_id"] = object_id
			result.append(full_data)
	
	return result

func get_round_stored_count(round_id: int) -> int:
	"""Retorna quantidade de objetos guardados em uma rodada"""
	if not stored_objects.has(round_id):
		return 0
	return stored_objects[round_id].size()

func get_owner_stored_count(round_id: int, owner_id: int) -> int:
	"""Retorna quantidade de objetos guardados de um dono"""
	return get_stored_objects_by_owner(round_id, owner_id).size()

func get_stored_object_owner(round_id: int, object_id: int) -> int:
	"""Retorna ID do dono do objeto guardado (-1 se não existir)"""
	if not stored_object_exists(round_id, object_id):
		return -1
	return stored_objects[round_id][object_id]["owner_id"]

func get_stored_object_item_name(round_id: int, object_id: int) -> String:
	"""Retorna nome do item do objeto guardado"""
	if not stored_object_exists(round_id, object_id):
		return ""
	return stored_objects[round_id][object_id]["item_name"]

func get_stored_object_custom_data(round_id: int, object_id: int) -> Dictionary:
	"""Retorna dados customizados do objeto guardado"""
	if not stored_object_exists(round_id, object_id):
		return {}
	return stored_objects[round_id][object_id].get("custom_data", {}).duplicate()

func get_stored_object_transfer_history(round_id: int, object_id: int) -> Array:
	"""Retorna histórico de transferências do objeto"""
	if not stored_object_exists(round_id, object_id):
		return []
	return stored_objects[round_id][object_id].get("transfer_history", []).duplicate()

# ===== 🆕 UTILITÁRIOS DE ESTADO =====

func get_object_state(round_id: int, object_id: int) -> String:
	"""
	Retorna estado atual do objeto
	@return: "spawned", "stored", "despawned" ou "unknown"
	"""
	if spawned_objects.has(round_id) and spawned_objects[round_id].has(object_id):
		return "spawned"
	elif stored_objects.has(round_id) and stored_objects[round_id].has(object_id):
		return "stored"
	else:
		return "unknown"  # Pode ter sido despawnado ou nunca existiu

func object_exists_anywhere(round_id: int, object_id: int) -> bool:
	"""Verifica se objeto existe em qualquer estado (spawnado ou guardado)"""
	return object_exists(round_id, object_id) or stored_object_exists(round_id, object_id)

# ===== SPAWN INTERNO (SERVIDOR) =====

func _spawn_on_server(objects_node, object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, owner_id: int) -> Node:
	"""
	Spawna objeto no servidor usando ItemDatabase
	
	@return: Node do item ou null se falhar
	"""

	# Obtém scene_path do ItemDatabase
	var scene_path = item_database.get_item(item_name)["scene_path"]
	
	if scene_path.is_empty():
		push_error("ObjectManager: Scene path vazio para item '%s'" % item_name)
		return null
	
	# Carrega cena
	var item_scene = load(scene_path)
	
	if not item_scene:
		push_error("ObjectManager: Falha ao carregar cena: %s" % scene_path)
		return null
	
	# Instancia
	var item_node = item_scene.instantiate()
	
	if not item_node:
		push_error("ObjectManager: Falha ao instanciar cena")
		return null
	
	# ✅ Nome único sem underscore duplicado
	item_node.name = "Object_%d_%s_%d" % [object_id, item_name, round_id]
	
	_log_debug("Criando node: %s" % item_node.name)
	
	# Adiciona à árvore (raiz de objeto do round no servidor)
	objects_node.add_child(item_node, true)
	
	# Aguarda processamento
	await get_tree().process_frame
	
	# Valida que está na árvore
	if not item_node.is_inside_tree():
		push_error("ObjectManager: Item não foi adicionado à árvore")
		item_node.queue_free()
		return null
	
	# Configura posição/rotação
	if item_node is Node3D:
		item_node.global_position = position
		item_node.global_rotation = rotation
	
	# Inicializa item (se tiver método initialize)
	if item_node.has_method("initialize"):
		var item_full_data = item_database.get_item_full_info(item_name)
		var drop_velocity = Vector3(0, 10, 0)
		
		# Se for drop de player, ajustar drop_velocity para a direção de sua fronte
		if owner_id > 0:
			var player_state = ServerManager.player_states[owner_id]
			var player_rot = player_state["rot"]
			drop_velocity = _calculate_drop_impulse(player_rot)
			
		_log_debug("drop_velocity %s" % drop_velocity)
		item_node.initialize(object_id, round_id, item_name, item_full_data, owner_id, drop_velocity)
	
	_log_debug("Node criado no servidor: %s" % item_node.name)
	
	return item_node

# ===== RPC PARA CLIENTES =====

@rpc("authority", "call_remote", "reliable")
func _rpc_despawn_on_clients(object_id: int, round_id: int):
	"""RPC para despawnar objeto nos clientes"""
	
	_log_debug("🔄 RPC recebido: despawn_on_client (ID: %d)" % object_id)
	
	_despawn_on_client(object_id, round_id)

func _despawn_on_client(object_id: int, round_id: int):
	"""Despawna objeto no cliente"""
	
	if multiplayer.is_server():
		return  # Servidor já despawnou na função principal
	
	# Valida existência
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		return
	
	var obj_data = spawned_objects[round_id][object_id]
	var item_node = obj_data["node"]
	
	# Remove da cena
	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()
	
	# Remove do registro local
	spawned_objects[round_id].erase(object_id)
	
	_log_debug("✓ [Cliente] Objeto despawnado: ID %d" % object_id)

# ===== CÁLCULOS DE POSIÇÃO =====

func _calculate_front_position(player_pos: Vector3, player_rot: Vector3) -> Vector3:
	"""
	Calcula posição na frente do player
	@param player_rot: Rotação em Euler angles
	"""
	
	var basis = Basis.from_euler(player_rot)
	var forward = basis.z  # -Z é frente no Godot
	
	# Posição base + variação aleatória
	var base_pos = player_pos + forward * drop_distance + Vector3.UP * drop_height
	
	var variance_x = randf_range(-drop_variance, drop_variance)
	var variance_z = randf_range(-drop_variance, drop_variance)
	
	return base_pos + Vector3(variance_x, 0, variance_z)

func _calculate_drop_impulse(player_rot: Vector3) -> Vector3:
	# Ignora position — não é usada no cálculo do impulso (só da posição de spawn)
	var yaw = player_rot.y
	
	# Frente: Z local → calculado via trigonometria
	var forward = Vector3(sin(yaw), 0.0, cos(yaw))
	
	# Vetor lateral (direita local)
	var right = Vector3(cos(yaw), 0.0, -sin(yaw))
	
	# Impulso principal
	var impulse = forward * drop_impulse_strength
	
	# Variação aleatória (relativa à orientação do jogador)
	impulse += right * randf_range(-drop_impulse_variance, drop_impulse_variance)
	impulse += forward * randf_range(-drop_impulse_variance * 0.3, drop_impulse_variance * 0.3)
	
	# Impulso vertical para cima
	impulse.y += drop_impulse_strength * drop_impulse_up_multiplier
	
	return impulse

# ===== QUERIES DE OBJETOS SPAWNADOS =====

func get_object_node(round_id: int, object_id: int) -> Node:
	"""Retorna node de um objeto spawnado"""
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		return null
	return spawned_objects[round_id][object_id]["node"]

func get_object_data(round_id: int, object_id: int) -> Dictionary:
	"""Retorna dados completos de um objeto spawnado"""
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		return {}
	return spawned_objects[round_id][object_id].duplicate()

func get_round_objects(round_id: int) -> Array:
	"""Retorna todos os nodes de objetos spawnados de uma rodada"""
	if not spawned_objects.has(round_id):
		return []
	
	var result = []
	for obj_data in spawned_objects[round_id].values():
		result.append(obj_data["node"])
	return result

func get_round_object_count(round_id: int) -> int:
	"""Retorna quantidade de objetos spawnados em uma rodada"""
	if not spawned_objects.has(round_id):
		return 0
	return spawned_objects[round_id].size()

func get_objects_near_position(round_id: int, position: Vector3, radius: float) -> Array:
	"""Retorna objetos spawnados dentro de um raio"""
	if not spawned_objects.has(round_id):
		return []
	
	var result = []
	for obj_data in spawned_objects[round_id].values():
		var node = obj_data["node"]
		if node is Node3D:
			var distance = node.global_position.distance_to(position)
			if distance <= radius:
				result.append(node)
	
	return result

func object_exists(round_id: int, object_id: int) -> bool:
	"""Verifica se objeto está spawnado"""
	return spawned_objects.has(round_id) and spawned_objects[round_id].has(object_id)

func get_object_owner(round_id: int, object_id: int) -> int:
	"""Retorna ID do dono do objeto spawnado (-1 se não tiver)"""
	if not object_exists(round_id, object_id):
		return -1
	return spawned_objects[round_id][object_id].get("owner_id", -1)

func get_object_item_name(round_id: int, object_id: int) -> String:
	"""Retorna nome do item do objeto spawnado"""
	if not object_exists(round_id, object_id):
		return ""
	return spawned_objects[round_id][object_id].get("item_name", "")

# ===== UTILITÁRIOS =====

func _get_next_object_id() -> int:
	"""Gera próximo ID único"""
	var id = next_object_id
	next_object_id += 1
	return id

# ===== ESTATÍSTICAS E DEBUG =====

func get_total_spawned_objects() -> int:
	"""Total de objetos spawnados em todas as rodadas"""
	var total = 0
	for round_id in spawned_objects:
		total += spawned_objects[round_id].size()
	return total

func get_total_stored_objects() -> int:
	"""Total de objetos guardados em todas as rodadas"""
	var total = 0
	for round_id in stored_objects:
		total += stored_objects[round_id].size()
	return total

func get_stats() -> Dictionary:
	"""Estatísticas gerais"""
	return {
		"total_spawned": get_total_spawned_objects(),
		"total_stored": get_total_stored_objects(),
		"total_objects": get_total_spawned_objects() + get_total_stored_objects(),
		"active_rounds": spawned_objects.size(),
		"rounds_with_stored": stored_objects.size(),
		"next_object_id": next_object_id,
		"is_server": multiplayer.is_server()
	}

func print_round_objects(round_id: int):
	"""Debug: Imprime objetos de uma rodada (spawnados + guardados)"""
	var spawned_count = get_round_object_count(round_id)
	var stored_count = get_round_stored_count(round_id)
	
	print("\n╔════════════════════════════════════════╗")
	print("║    OBJETOS DA RODADA %d (%s)" % [round_id, "SERVIDOR" if multiplayer.is_server() else "CLIENTE"])
	print("╚════════════════════════════════════════╝")
	print("  Spawnados: %d | Guardados: %d | Total: %d" % [spawned_count, stored_count, spawned_count + stored_count])
	print("─────────────────────────────────────────")
	
	# Objetos spawnados
	if spawned_objects.has(round_id):
		print("\n  🌍 OBJETOS SPAWNADOS:")
		for object_id in spawned_objects[round_id]:
			var data = spawned_objects[round_id][object_id]
			var node = data["node"]
			var pos = node.global_position if node is Node3D else Vector3.ZERO
			print("    🎁 [%d] %s" % [object_id, data["item_name"]])
			print("       Node: %s" % node.name)
			print("       Pos: %s" % pos)
			print("       Owner: %d" % data["owner_id"])
	
	# Objetos guardados
	if stored_objects.has(round_id):
		print("\n  📦 OBJETOS GUARDADOS:")
		for object_id in stored_objects[round_id]:
			var data = stored_objects[round_id][object_id]
			print("    📦 [%d] %s" % [object_id, data["item_name"]])
			print("       Owner: %d" % data["owner_id"])
			print("       Stored By: %d" % data["stored_by"])
			print("       Transfers: %d" % data["transfer_history"].size())
	
	print("─────────────────────────────────────────\n")

func _log_debug(message: String):
	if debug_mode:
		print("[SERVER][ObjectManager] %s" % message)
