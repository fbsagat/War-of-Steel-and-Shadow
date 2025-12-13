extends Node
class_name ObjectManager
## ObjectManager - Gerenciador autoritativo de objetos no mundo (SERVIDOR APENAS)
##
## RESPONSABILIDADES:
## - Spawnar itens no mundo usando ItemDatabase como fonte
## - Replicar spawns para clientes via RPC
## - Despawnar itens quando coletados/destruídos
## - Gerenciar objetos por rodada (isolamento entre rodadas)
## - Sincronizar estado com todos os clientes
##
## IMPORTANTE: Lógica executa APENAS no servidor, clientes recebem via RPC

# ===== CONFIGURAÇÕES =====

@export_category("Spawn Settings")
@export var drop_distance: float = 1.2  # Distância na frente do player
@export var drop_height: float = 1.2    # Altura acima do chão
@export var drop_variance: float = 0.3  # Variação aleatória

@export_category("Physics Settings")
@export var drop_impulse_strength: float = 3.5
@export var drop_impulse_variance: float = 1.0

@export_category("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS =====

var player_registry: PlayerRegistry = null   # Injetado pelo ServerManager
var round_registry: RoundRegistry = null    # Injetado pelo ServerManager
var item_database: ItemDatabase = null     # Injetado pelo ServerManager

# ===== VARIÁVEIS INTERNAS =====

## Objetos spawnados organizados por rodada
## {round_id: {object_id: {node: Node, item_name: String, owner_id: int}}}
var spawned_objects: Dictionary = {}

## Contador global de IDs únicos
var next_object_id: int = 1

## Estado de inicialização
var _initialized: bool = false

# ===== SINAIS =====

signal object_spawned(round_id: int, object_id: int, item_name: String)
signal object_despawned(round_id: int, object_id: int)
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
	
	# ✅ Envia RPC individual para cada cliente ativo
	_send_spawn_to_clients(round_id, object_id, item_name, position, rotation, owner_id)
	
	_log_debug("✓ Item spawnado: %s (ID: %d, Round: %d)" % [item_name, object_id, round_id])
	
	object_spawned.emit(round_id, object_id, item_name)
	
	return object_id

func _send_spawn_to_clients(round_id: int, object_id: int, item_name: String, position: Vector3, rotation: Vector3, owner_id: int):
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
	"""Remove todos os objetos de uma rodada"""
	
	if not multiplayer.is_server():
		return
	
	if not spawned_objects.has(round_id):
		return
	
	var object_count = spawned_objects[round_id].size()
	
	# Despawna cada objeto
	var object_ids = spawned_objects[round_id].keys()
	for object_id in object_ids:
		despawn_object(round_id, object_id)
	
	# Remove dicionário da rodada
	spawned_objects.erase(round_id)
	
	_log_debug("✓ Objetos da rodada %d limpos (%d objetos)" % [round_id, object_count])
	
	round_objects_cleared.emit(round_id, object_count)

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
		var drop_velocity = _calculate_drop_impulse(rotation)
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
	"""Calcula vetor de impulso para dropar item"""
	
	var basis = Basis.from_euler(player_rot)
	var forward = -basis.z
	
	var impulse = forward * drop_impulse_strength
	impulse.x += randf_range(-drop_impulse_variance, drop_impulse_variance)
	impulse.y += drop_impulse_strength * 0.5  # Para cima
	impulse.z += randf_range(-drop_impulse_variance, drop_impulse_variance)
	
	return impulse

# ===== QUERIES =====

func get_object_node(round_id: int, object_id: int) -> Node:
	"""Retorna node de um objeto"""
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		return null
	return spawned_objects[round_id][object_id]["node"]

func get_object_data(round_id: int, object_id: int) -> Dictionary:
	"""Retorna dados completos de um objeto"""
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		return {}
	return spawned_objects[round_id][object_id].duplicate()

func get_round_objects(round_id: int) -> Array:
	"""Retorna todos os nodes de objetos de uma rodada"""
	if not spawned_objects.has(round_id):
		return []
	
	var result = []
	for obj_data in spawned_objects[round_id].values():
		result.append(obj_data["node"])
	return result

func get_round_object_count(round_id: int) -> int:
	"""Retorna quantidade de objetos em uma rodada"""
	if not spawned_objects.has(round_id):
		return 0
	return spawned_objects[round_id].size()

func get_objects_near_position(round_id: int, position: Vector3, radius: float) -> Array:
	"""Retorna objetos dentro de um raio"""
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
	"""Verifica se objeto existe"""
	return spawned_objects.has(round_id) and spawned_objects[round_id].has(object_id)

func get_object_owner(round_id: int, object_id: int) -> int:
	"""Retorna ID do dono do objeto (-1 se não tiver)"""
	if not object_exists(round_id, object_id):
		return -1
	return spawned_objects[round_id][object_id].get("owner_id", -1)

func get_object_item_name(round_id: int, object_id: int) -> String:
	"""Retorna nome do item do objeto"""
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
	"""Total de objetos em todas as rodadas"""
	var total = 0
	for round_id in spawned_objects:
		total += spawned_objects[round_id].size()
	return total

func get_stats() -> Dictionary:
	"""Estatísticas gerais"""
	return {
		"total_objects": get_total_spawned_objects(),
		"active_rounds": spawned_objects.size(),
		"next_object_id": next_object_id,
		"is_server": multiplayer.is_server()
	}

func print_round_objects(round_id: int):
	"""Debug: Imprime objetos de uma rodada"""
	if not spawned_objects.has(round_id):
		print("❌ Rodada %d não tem objetos" % round_id)
		return
	
	var objects = spawned_objects[round_id]
	
	print("\n╔════════════════════════════════════════╗")
	print("║    OBJETOS DA RODADA %d (%s)" % [round_id, "SERVIDOR" if multiplayer.is_server() else "CLIENTE"])
	print("╚════════════════════════════════════════╝")
	print("  Total: %d objetos" % objects.size())
	print("─────────────────────────────────────────")
	
	for object_id in objects:
		var data = objects[object_id]
		var node = data["node"]
		var pos = node.global_position if node is Node3D else Vector3.ZERO
		print("  🎁 [%d] %s" % [object_id, data["item_name"]])
		print("     Node: %s" % node.name)
		print("     Pos: %s" % pos)
		print("     Owner: %d" % data["owner_id"])
	
	print("─────────────────────────────────────────\n")

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if multiplayer.is_server() else "[CLIENT]"
		print("%s[ObjectManager]%s" % [prefix, message])
