extends Node
class_name ObjectManager
## ObjectManager - Gerenciador autoritativo de objetos no mundo (SERVIDOR APENAS)
##
## RESPONSABILIDADES:
## - Spawnar itens no mundo usando ItemDatabase como fonte
## - Replicar spawns para clientes via RPC
## - Despawnar itens quando coletados/destruídos
## - Gerenciar objetos guardados (em inventários/baús)
## - Gerenciar objetos por rodada (isolamento entre rodadas)
## - Sincronizar estado com todos os clientes
##
## ESTADOS DOS OBJETOS:
## 1. SPAWNADO : No mundo      — spawned_objects[round_id][object_id] = Node
## 2. GUARDADO : Fora do mundo — stored_objects[round_id][object_id]  = Dictionary
## 3. DESPAWNADO: Destruído permanentemente
##
## IMPORTANTE: Toda lógica executa APENAS no servidor; clientes recebem via RPC.


# ===== CONFIGURAÇÕES =====

@export_category("Spawn Settings")
@export var drop_distance: float = 1.2  ## Distância na frente do player
@export var drop_height: float = 1.2    ## Altura acima do chão
@export var drop_variance: float = 0.3  ## Variação aleatória de posição

@export_category("Physics Settings")
@export var drop_impulse_strength: float = 3.5
@export var drop_impulse_variance: float = 1.2
@export var drop_impulse_up_multiplier: float = 0.6

@export_category("Debug")
@export var debug_mode: bool = true


# ===== DEPENDÊNCIAS (Injetadas pelo initializer.gd) =====

var server_manager: ServerManager = null
var network_manager: NetworkManager = null
var client_registry: ClientRegistry = null
var round_registry: RoundRegistry = null
var item_database: ItemDatabase = null
var initializer: Initializer = null


# ===== REGISTROS =====

## Objetos atualmente no mundo, organizados por rodada.
## Estrutura: { round_id: { object_id: Node } }
var spawned_objects: Dictionary = {}

## Referência flat para acesso rápido por object_id.
## Estrutura: { object_id: Node }
var all_spawned_objects: Dictionary = {}

## Objetos fora do mundo (inventários/baús), organizados por rodada.
## O nó é destruído ao guardar; os dados são preservados neste dicionário.
## Estrutura: { round_id: { object_id: { item_name, owner_uuid, stored_time,
##                                       stored_by, transfer_history, custom_data } } }
var stored_objects: Dictionary = {}

## Referência flat de objetos guardados.
## Estrutura: { object_id: Dictionary }
var all_stored_objects: Dictionary = {}

## Contador global de IDs únicos
var next_object_id: int = 1

var _initialized: bool = false


# ===== SINAIS =====

signal object_spawned(round_id: int, object_id: int, item_name: String)
signal object_despawned(round_id: int, object_id: int)
signal object_stored(round_id: int, object_id: int, owner_uuid: String)
signal object_retrieved(round_id: int, object_id: int)
signal object_transferred(round_id: int, object_id: int, old_owner: String, new_owner: String)
signal round_objects_cleared(round_id: int, count: int)


# ===== INICIALIZAÇÃO =====

## Inicializa o ObjectManager. Deve ser chamado pelo ServerManager após injetar as dependências.
func initialize():
	if _initialized:
		_log_debug("⚠ ObjectManager já inicializado")
		return

	if not item_database:
		push_error("ObjectManager: ItemDatabase não encontrado!")
		return

	if not item_database.is_loaded:
		push_error("ObjectManager: ItemDatabase não está carregado!")
		return

	_initialized = true
	_log_debug("✓ ObjectManager inicializado com sucesso!")

## Reseta completamente o manager, destruindo todos os objetos e limpando os registros.
func reset():
	for round_id in spawned_objects.keys():
		clear_round_objects(round_id)

	spawned_objects.clear()
	all_spawned_objects.clear()
	stored_objects.clear()
	all_stored_objects.clear()
	next_object_id = 1
	_initialized = false
	_log_debug("🔄 ObjectManager resetado")


# ===== SPAWN =====

## Spawna um item no servidor e replica para todos os clientes ativos na rodada.
## Retorna o object_id único gerado, ou -1 em caso de falha.
func spawn_item(objects_node, round_id: int, item_name: String, position: Vector3, rotation: Vector3 = Vector3.ZERO, velocity: Vector3 = Vector3.ZERO, owner_uuid: String = "") -> int:
	if not _initialized:
		push_error("ObjectManager: Não inicializado")
		return -1

	if not item_database.item_exists(item_name):
		push_error("ObjectManager: Item '%s' não existe no ItemDatabase" % item_name)
		return -1

	if not round_registry or not round_registry.is_round_active(round_id):
		push_error("ObjectManager: Rodada %d não está ativa" % round_id)
		return -1

	var object_id = _get_next_object_id()

	_log_debug("🔨 Spawnando '%s' (ID: %d, Round: %d)" % [item_name, object_id, round_id])

	var item_node = await _spawn_on_server(objects_node, object_id, round_id, item_name, position, rotation, velocity, owner_uuid)

	if not item_node:
		push_error("ObjectManager: Falha ao spawnar '%s'" % item_name)
		return -1

	# Armazena apenas o nó
	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}

	spawned_objects[round_id][object_id] = item_node
	all_spawned_objects[object_id] = item_node

	_send_spawn_to_clients(round_id, object_id, item_name, position, rotation, item_node.initial_velocity, owner_uuid)

	_log_debug("✓ Item spawnado: %s (ID: %d, Round: %d)" % [item_name, object_id, round_id])

	object_spawned.emit(round_id, object_id, item_name)

	return object_id

## Spawna um item na frente do player identificado por player_uuid.
## Usa o estado atual do servidor (ServerManager.player_states).
## Retorna o object_id gerado, ou -1 em caso de falha.
func spawn_item_in_front_of_player(objects_node, round_id: int, player_uuid: String, item_name: String) -> int:
	if not server_manager.player_states.has(player_uuid):
		push_error("ObjectManager: Player '%s' não tem estado no servidor" % player_uuid)
		return -1

	var player_state = server_manager.player_states[player_uuid]
	var spawn_pos = _calculate_front_position(player_state["pos"], player_state["rot"])

	_log_debug("Spawn na frente do player '%s': pos=%s" % [player_uuid, spawn_pos])

	return await spawn_item(objects_node, round_id, item_name, spawn_pos, Vector3.ZERO, Vector3.ZERO, player_uuid)

## Spawna um item acima do player identificado por player_uuid (+3 unidades no eixo Y).
## Usa o estado atual do servidor (ServerManager.player_states).
## Retorna o object_id gerado, ou -1 em caso de falha.
func spawn_item_over_of_player(objects_node, round_id: int, player_uuid: String, item_name: String) -> int:
	if not server_manager.player_states.has(player_uuid):
		push_error("ObjectManager: Player '%s' não tem estado no servidor" % player_uuid)
		return -1

	var player_pos = server_manager.player_states[player_uuid]["pos"]
	var spawn_pos = Vector3(player_pos.x, player_pos.y + 3.0, player_pos.z)

	_log_debug("Spawn acima do player '%s': pos=%s" % [player_uuid, spawn_pos])

	return await spawn_item(objects_node, round_id, item_name, spawn_pos, Vector3.ZERO, Vector3.ZERO, player_uuid)


## Spawna um item em posição aleatória dentro de um raio circular centrado em area_center.
## Retorna o object_id gerado, ou -1 em caso de falha.
func spawn_item_at_random_position(objects_node, round_id: int, item_name: String, area_center: Vector3, area_radius: float, owner_uuid: String = "") -> int:
	var angle = randf() * TAU
	var distance = randf() * area_radius
	var spawn_pos = area_center + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)

	return await spawn_item(objects_node, round_id, item_name, spawn_pos, Vector3.ZERO, Vector3.ZERO, owner_uuid)

## Envia RPC de spawn para cada cliente ativo na rodada (ignora servidor e peers desconectados).
func _send_spawn_to_clients(round_id: int, object_id: int, item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_uuid: String):
	var active_players = round_registry.get_all_spawned_players(round_id)

	if active_players.is_empty():
		_log_debug("⚠️  Nenhum player ativo na rodada %d" % round_id)
		return

	var clients_sent = 0

	for player_node in active_players:
		if not player_node or not is_instance_valid(player_node):
			continue

		var player_id = player_node.peer_id

		if player_id == 1 or not _is_peer_connected(player_id):
			continue

		network_manager._client_spawn_item.rpc_id(
			player_id, object_id, round_id, item_name, position, rotation, drop_velocity, owner_uuid
		)

		clients_sent += 1

	_log_debug("📤 Spawn enviado para %d cliente(s)" % clients_sent)


# ===== DESPAWN =====

## Despawna um objeto do servidor e notifica todos os clientes ativos.
## Retorna true em caso de sucesso.
func despawn_object(round_id: int, object_id: int) -> bool:
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		push_warning("ObjectManager: Objeto %d não existe na rodada %d" % [object_id, round_id])
		return false

	var item_node: Node = spawned_objects[round_id][object_id]

	# Desregistra do sync antes do queue_free (nó ainda está na árvore)
	network_manager.unregister_syncable_object(object_id)

	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()

	spawned_objects[round_id].erase(object_id)
	all_spawned_objects.erase(object_id)

	_send_despawn_to_clients(round_id, object_id)

	_log_debug("✓ Objeto despawnado: ID %d (Round: %d)" % [object_id, round_id])

	object_despawned.emit(round_id, object_id)

	return true

## Despawna um objeto a partir da referência direta ao nó.
## Retorna true em caso de sucesso.
func despawn_object_by_node(round_id: int, node: Node) -> bool:
	if not spawned_objects.has(round_id):
		return false

	for object_id in spawned_objects[round_id]:
		if spawned_objects[round_id][object_id] == node:
			return despawn_object(round_id, object_id)

	push_warning("ObjectManager: Nó não encontrado no registro da rodada %d" % round_id)
	return false

## Remove todos os objetos (spawnados e guardados) de uma rodada.
func clear_round_objects(round_id: int):
	var total_count = 0

	if spawned_objects.has(round_id):
		total_count += spawned_objects[round_id].size()
		for object_id in spawned_objects[round_id].keys():
			despawn_object(round_id, object_id)
		spawned_objects.erase(round_id)

	if stored_objects.has(round_id):
		for obj in stored_objects[round_id]:
			if all_stored_objects.has(obj):
				all_stored_objects.erase(obj)
		total_count += stored_objects[round_id].size()
		stored_objects.erase(round_id)

	_log_debug("✓ Rodada %d limpa (%d objetos)" % [round_id, total_count])

	round_objects_cleared.emit(round_id, total_count)

## Envia RPC de despawn para cada cliente ativo na rodada.
func _send_despawn_to_clients(round_id: int, object_id: int):
	var active_players = round_registry.get_all_spawned_players(round_id)

	for player_node in active_players:
		if not player_node or not is_instance_valid(player_node):
			continue

		var player_id = player_node.peer_id

		if player_id == 1 or not _is_peer_connected(player_id):
			continue

		network_manager._client_despawn_item.rpc_id(player_id, object_id, round_id)

## Retorna true se o peer_id estiver conectado ao multiplayer.
func _is_peer_connected(peer_id: int) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	return peer_id in multiplayer.get_peers()


# ===== OBJETOS GUARDADOS =====

## Move um objeto do estado SPAWNADO para GUARDADO.
## Destrói o nó do mundo e preserva seus dados (lidos do próprio nó) no registro.
## custom_data opcional permite sobrescrever ou complementar os dados do nó.
## Retorna true em caso de sucesso.
func store_object(round_id: int, object_id: int, owner_uuid: String, custom_data: Dictionary = {}) -> bool:
	if not spawned_objects.has(round_id) or not spawned_objects[round_id].has(object_id):
		push_error("ObjectManager: Objeto %d não está spawnado na rodada %d" % [object_id, round_id])
		return false

	var item_node: Node = spawned_objects[round_id][object_id]

	# Lê dados diretamente do nó
	var item_name: String = item_node.item_name
	var previous_owner: String = item_node.owner_uuid

	# Extrai dados customizados do nó (se disponível), mesclando com o parâmetro recebido
	var final_custom_data = custom_data.duplicate()
	if item_node.has_method("get_custom_data"):
		final_custom_data.merge(item_node.get_custom_data(), true)

	# Desregistra do sync antes do queue_free (nó ainda está na árvore)
	network_manager.unregister_syncable_object(object_id)

	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()

	spawned_objects[round_id].erase(object_id)
	all_spawned_objects.erase(object_id)

	if not stored_objects.has(round_id):
		stored_objects[round_id] = {}

	stored_objects[round_id][object_id] = {
		"item_name": item_name,
		"owner_uuid": owner_uuid,
		"stored_time": Time.get_unix_time_from_system(),
		"stored_by": owner_uuid,
		"transfer_history": [{ "from": previous_owner, "to": owner_uuid, "time": Time.get_unix_time_from_system() }],
		"custom_data": final_custom_data
	}
	all_stored_objects[object_id] = stored_objects[round_id][object_id]

	_send_despawn_to_clients(round_id, object_id)

	_log_debug("📦 Objeto guardado: ID %d → Owner '%s' (Round: %d)" % [object_id, owner_uuid, round_id])

	object_stored.emit(round_id, object_id, owner_uuid)

	return true

## Move um objeto do estado GUARDADO de volta para SPAWNADO.
## Spawna o nó no mundo na posição indicada e restaura os dados customizados.
## Retorna true em caso de sucesso.
func retrieve_stored_object(objects_node, round_id: int, object_id: int, position: Vector3, rotation: Vector3 = Vector3.ZERO, new_owner_uuid: String = "") -> bool:
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		push_error("ObjectManager: Objeto %d não está guardado na rodada %d" % [object_id, round_id])
		return false

	var stored_data = stored_objects[round_id][object_id]
	var item_name: String = stored_data["item_name"]
	var custom_data: Dictionary = stored_data["custom_data"]

	stored_objects[round_id].erase(object_id)
	all_stored_objects.erase(object_id)

	var item_node = await _spawn_on_server(objects_node, object_id, round_id, item_name, position, rotation, Vector3.ZERO, new_owner_uuid)

	if not item_node:
		push_error("ObjectManager: Falha ao respawnar objeto guardado %d" % object_id)
		# Reverte para guardado
		stored_objects[round_id][object_id] = stored_data
		all_stored_objects[object_id] = stored_data
		return false

	if item_node.has_method("set_custom_data"):
		item_node.set_custom_data(custom_data)

	if not spawned_objects.has(round_id):
		spawned_objects[round_id] = {}

	spawned_objects[round_id][object_id] = item_node
	all_spawned_objects[object_id] = item_node

	_send_spawn_to_clients(round_id, object_id, item_name, position, rotation, item_node.initial_velocity, new_owner_uuid)

	_log_debug("📤 Objeto respawnado: ID %d (Round: %d)" % [object_id, round_id])

	object_retrieved.emit(round_id, object_id)

	return true

## Transfere a posse de um objeto guardado para new_owner_uuid.
## O estado permanece GUARDADO; apenas owner_uuid é atualizado.
## Retorna true em caso de sucesso.
func transfer_stored_object(round_id: int, object_id: int, new_owner_uuid: String) -> bool:
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		push_error("ObjectManager: Objeto %d não está guardado na rodada %d" % [object_id, round_id])
		return false

	var stored_data = stored_objects[round_id][object_id]
	var old_owner: String = stored_data["owner_uuid"]

	stored_data["owner_uuid"] = new_owner_uuid
	stored_data["transfer_history"].append({
		"from": old_owner,
		"to": new_owner_uuid,
		"time": Time.get_unix_time_from_system()
	})

	_log_debug("🔄 Transferência: ID %d, '%s' → '%s'" % [object_id, old_owner, new_owner_uuid])

	object_transferred.emit(round_id, object_id, old_owner, new_owner_uuid)

	return true

## Destrói permanentemente um objeto guardado sem respawná-lo.
## Retorna true em caso de sucesso.
func destroy_stored_object(round_id: int, object_id: int) -> bool:
	if not stored_objects.has(round_id) or not stored_objects[round_id].has(object_id):
		push_warning("ObjectManager: Objeto %d não está guardado na rodada %d" % [object_id, round_id])
		return false

	stored_objects[round_id].erase(object_id)
	all_stored_objects.erase(object_id)

	_log_debug("❌ Objeto guardado destruído: ID %d (Round: %d)" % [object_id, round_id])

	object_despawned.emit(round_id, object_id)

	return true


# ===== QUERIES — OBJETOS GUARDADOS =====

## Retorna os dados completos de um objeto guardado, ou {} se não existir.
func get_stored_object_data(round_id: int, object_id: int) -> Dictionary:
	if not stored_object_exists(round_id, object_id):
		return {}
	return stored_objects[round_id][object_id].duplicate()


## Retorna true se o objeto estiver no estado guardado.
func stored_object_exists(round_id: int, object_id: int) -> bool:
	return stored_objects.has(round_id) and stored_objects[round_id].has(object_id)


## Retorna a lista de object_ids de objetos guardados pertencentes a owner_uuid.
func get_stored_objects_by_owner(round_id: int, owner_uuid: String) -> Array:
	if not stored_objects.has(round_id):
		return []

	var result: Array = []
	for object_id in stored_objects[round_id]:
		if stored_objects[round_id][object_id]["owner_uuid"] == owner_uuid:
			result.append(object_id)
	return result


## Retorna dados completos (incluindo object_id) de todos os objetos guardados de owner_uuid.
func get_stored_objects_full_data(round_id: int, owner_uuid: String) -> Array:
	if not stored_objects.has(round_id):
		return []

	var result: Array = []
	for object_id in stored_objects[round_id]:
		var data = stored_objects[round_id][object_id]
		if data["owner_uuid"] == owner_uuid:
			var full_data = data.duplicate()
			full_data["object_id"] = object_id
			result.append(full_data)
	return result


func get_all_stored_objects_full_data() -> Array:
	var result: Array = []
	for round_id in stored_objects:
		var round_data = stored_objects[round_id]
		for object_id in round_data:
			var data = round_data[object_id]
			var full_data = data.duplicate()
			full_data["object_id"] = object_id
			full_data["round_id"] = round_id
			result.append(full_data)
	return result

## Retorna a quantidade de objetos guardados em uma rodada.
func get_round_stored_count(round_id: int) -> int:
	if not stored_objects.has(round_id):
		return 0
	return stored_objects[round_id].size()

## Retorna a quantidade de objetos guardados pertencentes a owner_uuid.
func get_owner_stored_count(round_id: int, owner_uuid: String) -> int:
	return get_stored_objects_by_owner(round_id, owner_uuid).size()

## Retorna o UUID do dono de um objeto guardado, ou "" se não existir.
func get_stored_object_owner(round_id: int, object_id: int) -> String:
	if not stored_object_exists(round_id, object_id):
		return ""
	return stored_objects[round_id][object_id]["owner_uuid"]

## Retorna o nome do item de um objeto guardado, ou "" se não existir.
func get_stored_object_item_name(round_id: int, object_id: int) -> String:
	if not stored_object_exists(round_id, object_id):
		return ""
	return stored_objects[round_id][object_id]["item_name"]

## Retorna os dados customizados de um objeto guardado, ou {} se não existir.
func get_stored_object_custom_data(round_id: int, object_id: int) -> Dictionary:
	if not stored_object_exists(round_id, object_id):
		return {}
	return stored_objects[round_id][object_id].get("custom_data", {}).duplicate()

## Retorna o histórico de transferências de um objeto guardado.
func get_stored_object_transfer_history(round_id: int, object_id: int) -> Array:
	if not stored_object_exists(round_id, object_id):
		return []
	return stored_objects[round_id][object_id].get("transfer_history", []).duplicate()


# ===== SPAWN INTERNO =====

## Instancia o nó do item no servidor, configura posição/rotação e chama initialize().
## Retorna o nó instanciado, ou null em caso de falha.
func _spawn_on_server(objects_node, object_id: int, round_id: int, item_name: String, position: Vector3, rotation: Vector3, velocity: Vector3, owner_uuid: String) -> Node:
	var scene_path: String = item_database.get_item(item_name)["scene_path"]

	if scene_path.is_empty():
		push_error("ObjectManager: scene_path vazio para '%s'" % item_name)
		return null

	var item_scene = load(scene_path)
	if not item_scene:
		push_error("ObjectManager: Falha ao carregar cena: %s" % scene_path)
		return null

	var item_node = item_scene.instantiate()
	if not item_node:
		push_error("ObjectManager: Falha ao instanciar cena")
		return null

	item_node.name = "Object_%d_%s_%d" % [object_id, item_name, round_id]
	item_node.is_server = true

	# Injeta dependências no nó antes de adicioná-lo à árvore
	item_node.network_manager = network_manager
	item_node.server_manager = server_manager
	item_node.initializer = initializer

	objects_node.add_child(item_node, true)
	await get_tree().process_frame

	if not item_node.is_inside_tree():
		push_error("ObjectManager: Nó não foi adicionado à árvore")
		item_node.queue_free()
		return null

	if item_node is Node3D:
		item_node.global_position = position
		item_node.global_rotation = rotation

	if item_node.has_method("initialize"):
		var item_full_data = item_database.get_item_full_info(item_name)
		var drop_velocity: Vector3

		if owner_uuid != "":
			var player_state = server_manager.player_states[owner_uuid]
			drop_velocity = _calculate_drop_impulse(player_state["rot"])
		else:
			drop_velocity = velocity

		_log_debug("Impulso de drop: %s" % drop_velocity)
		item_node.initialize(object_id, round_id, item_name, item_full_data, owner_uuid, drop_velocity)

	_log_debug("Nó criado no servidor: %s" % item_node.name)

	return item_node


# ===== CÁLCULOS DE POSIÇÃO / IMPULSO =====

## Calcula a posição de spawn na frente do player com variação aleatória.
func _calculate_front_position(player_pos: Vector3, player_rot: Vector3) -> Vector3:
	var forward = Basis.from_euler(player_rot).z
	var base_pos = player_pos + forward * drop_distance + Vector3.UP * drop_height
	return base_pos + Vector3(
		randf_range(-drop_variance, drop_variance),
		0.0,
		randf_range(-drop_variance, drop_variance)
	)

## Calcula o vetor de impulso de drop com base na rotação (yaw) do player.
func _calculate_drop_impulse(player_rot: Vector3) -> Vector3:
	var yaw = player_rot.y
	var forward = Vector3(sin(yaw), 0.0, cos(yaw))
	var right   = Vector3(cos(yaw), 0.0, -sin(yaw))

	var impulse = forward * drop_impulse_strength
	impulse += right   * randf_range(-drop_impulse_variance, drop_impulse_variance)
	impulse += forward * randf_range(-drop_impulse_variance * 0.3, drop_impulse_variance * 0.3)
	impulse.y += drop_impulse_strength * drop_impulse_up_multiplier

	return impulse


# ===== QUERIES — OBJETOS SPAWNADOS =====

## Retorna o nó de um objeto spawnado, ou null se não existir.
func get_object_node(round_id: int, object_id: int) -> Node:
	if not object_exists(round_id, object_id):
		return null
	return spawned_objects[round_id][object_id]

## Retorna um dicionário com os dados do objeto spawnado, lidos diretamente do nó.
func get_object_data(round_id: int, object_id: int) -> Dictionary:
	if not object_exists(round_id, object_id):
		return {}
	var node = spawned_objects[round_id][object_id]
	return {
		"object_id": node.object_id,
		"round_id":  node.round_id,
		"item_name": node.item_name,
		"owner_uuid": node.owner_uuid,
		"spawn_time": node.spawn_time,
	}

## Retorna todos os nós de objetos spawnados em uma rodada.
func get_round_objects(round_id: int) -> Array:
	if not spawned_objects.has(round_id):
		return []
	return spawned_objects[round_id].values()

## Retorna a quantidade de objetos spawnados em uma rodada.
func get_round_object_count(round_id: int) -> int:
	if not spawned_objects.has(round_id):
		return 0
	return spawned_objects[round_id].size()

## Retorna os nós de objetos spawnados dentro de um raio a partir de uma posição.
func get_objects_near_position(round_id: int, position: Vector3, radius: float) -> Array:
	if not spawned_objects.has(round_id):
		return []

	var result: Array = []
	for node in spawned_objects[round_id].values():
		if node is Node3D and node.global_position.distance_to(position) <= radius:
			result.append(node)
	return result

## Retorna true se o objeto estiver no estado spawnado.
func object_exists(round_id: int, object_id: int) -> bool:
	return spawned_objects.has(round_id) and spawned_objects[round_id].has(object_id)

## Retorna o UUID do dono do objeto spawnado, ou "" se não existir.
func get_object_owner(round_id: int, object_id: int) -> String:
	if not object_exists(round_id, object_id):
		return ""
	return spawned_objects[round_id][object_id].owner_uuid

## Retorna o nome do item de um objeto spawnado, ou "" se não existir.
func get_object_item_name(round_id: int, object_id: int) -> String:
	if not object_exists(round_id, object_id):
		return ""
	return spawned_objects[round_id][object_id].item_name


# ===== UTILITÁRIOS DE ESTADO =====

## Retorna o estado atual do objeto: "spawned", "stored" ou "unknown".
func get_object_state(round_id: int, object_id: int) -> String:
	if spawned_objects.has(round_id) and spawned_objects[round_id].has(object_id):
		return "spawned"
	elif stored_objects.has(round_id) and stored_objects[round_id].has(object_id):
		return "stored"
	return "unknown"

## Retorna true se o objeto existir em qualquer estado (spawnado ou guardado).
func object_exists_anywhere(round_id: int, object_id: int) -> bool:
	return object_exists(round_id, object_id) or stored_object_exists(round_id, object_id)

## Gera e retorna o próximo object_id único.
func _get_next_object_id() -> int:
	var id = next_object_id
	next_object_id += 1
	return id


# ===== ESTATÍSTICAS E DEBUG =====

## Retorna o total de objetos spawnados em todas as rodadas.
func get_total_spawned_objects() -> int:
	var total = 0
	for round_id in spawned_objects:
		total += spawned_objects[round_id].size()
	return total

## Retorna o total de objetos guardados em todas as rodadas.
func get_total_stored_objects() -> int:
	var total = 0
	for round_id in stored_objects:
		total += stored_objects[round_id].size()
	return total

## Retorna um dicionário com estatísticas gerais do manager.
func get_stats() -> Dictionary:
	return {
		"total_spawned":      get_total_spawned_objects(),
		"total_stored":       get_total_stored_objects(),
		"total_objects":      get_total_spawned_objects() + get_total_stored_objects(),
		"active_rounds":      spawned_objects.size(),
		"rounds_with_stored": stored_objects.size(),
		"next_object_id":     next_object_id,
	}

## Imprime no console os objetos de uma rodada (spawnados e guardados). Útil para debug.
func print_round_objects(round_id: int):
	var spawned_count = get_round_object_count(round_id)
	var stored_count  = get_round_stored_count(round_id)

	print("\n╔════════════════════════════════════════╗")
	print("║    OBJETOS DA RODADA %d [%s]" % [round_id, "SERVIDOR" if multiplayer.is_server() else "CLIENTE"])
	print("╚════════════════════════════════════════╝")
	print("  Spawnados: %d | Guardados: %d | Total: %d" % [spawned_count, stored_count, spawned_count + stored_count])
	print("─────────────────────────────────────────")

	if spawned_objects.has(round_id):
		print("\n  🌍 OBJETOS SPAWNADOS:")
		for object_id in spawned_objects[round_id]:
			var node = spawned_objects[round_id][object_id]
			var pos = node.global_position if node is Node3D else Vector3.ZERO
			print("    🎁 [%d] %s" % [object_id, node.item_name])
			print("       Node : %s" % node.name)
			print("       Pos  : %s" % pos)
			print("       Owner: %s" % node.owner_uuid)

	if stored_objects.has(round_id):
		print("\n  📦 OBJETOS GUARDADOS:")
		for object_id in stored_objects[round_id]:
			var data = stored_objects[round_id][object_id]
			print("    📦 [%d] %s" % [object_id, data["item_name"]])
			print("       Owner    : %s" % data["owner_uuid"])
			print("       Stored By: %s" % data["stored_by"])
			print("       Transfers: %d" % data["transfer_history"].size())

	print("─────────────────────────────────────────\n")

func _log_debug(message: String):
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "ObjectManager" in initializer.selected:
		return
	print("[SERVER][ObjectManager] %s" % message)
	
