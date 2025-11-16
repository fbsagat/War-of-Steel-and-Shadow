extends Node
## ObjectSpawner - Sistema integrado de spawn de objetos sincronizados

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

var next_object_id: int = 1

## Objetos organizados por rodada: {round_id: {object_id: Node}}
var spawned_objects_by_round: Dictionary = {}

## Índice global para acesso rápido: {object_id: {round_id, node}}
var object_index: Dictionary = {}

# ===== REGISTROS =====

var player_registry = null
var room_registry = null
var round_registry = null
var object_spawner = null

# ===== SINAIS =====

signal object_spawned(round_id: int, object_id: int, object_node: Node)
signal object_despawned(round_id: int, object_id: int)
signal round_objects_cleared(round_id: int, count: int)

# ===== INICIALIZAÇÃO =====

func _ready():
	player_registry = ServerManager.player_registry
	room_registry = ServerManager.room_registry
	round_registry = ServerManager.round_registry
	object_spawner = ServerManager.object_spawner
	
	# Conecta ao RoundRegistry para limpar objetos quando rodada termina
	if round_registry.is_initialized():
		if not round_registry.round_ended.is_connected(_on_round_ended):
			round_registry.round_ended.connect(_on_round_ended)
		_log_debug(" Conectado ao RoundRegistry")

# ===== SPAWN DE OBJETOS (SERVIDOR) =====

## Spawna um objeto genérico usando path completo
func spawn_object(round_id: int, scene_path: String, spawn_position: Variant, data: Dictionary = {}) -> int:
	if not multiplayer.is_server():
		push_error("Apenas o servidor pode spawnar objetos!")
		return -1
	
	if not round_registry.is_round_active(round_id):
		push_error("Rodada %d não está ativa!" % round_id)
		return -1
	
	var object_id = _generate_object_id()
	
	_log_debug("Spawnando objeto: %s (ID: %d) na rodada %d" % [scene_path.get_file(), object_id, round_id])
	
	# Instancia no servidor primeiro (agora é async)
	var obj = await _instantiate_object(scene_path, spawn_position, data, object_id, round_id)
	
	if obj == null:
		push_error("Falha ao instanciar objeto: %s" % scene_path)
		return -1
	
	# Registra objeto na rodada
	_register_object(round_id, object_id, obj)
	
	# Notifica clientes DESSA RODADA para spawnarem também
	var spawn_data = {
		"round_id": round_id,
		"object_id": object_id,
		"scene_path": scene_path,
		"position": spawn_position,
		"data": data
	}
	
	# Envia apenas para jogadores desta rodada
	_rpc_to_round_players(round_id, "_client_spawn_object", spawn_data)
	
	object_spawned.emit(round_id, object_id, obj)
	
	return object_id

## Spawna um item usando nome (consulta ItemDatabase)
func spawn_item(round_id: int, item_name: String, spawn_position: Variant, data: Dictionary = {}) -> int:
	if not multiplayer.is_server():
		push_error("Apenas o servidor pode spawnar objetos!")
		return -1
	
	# Obtém dados do item do database
	var item_data = ItemDatabase.get_item(item_name)
	
	if item_data == null:
		push_error("Item não encontrado no ItemDatabase: %s" % item_name)
		return -1
	
	# Adiciona metadados do item aos dados customizados
	var enhanced_data = data.duplicate()
	enhanced_data["item_id"] = item_data.id
	enhanced_data["item_name"] = item_data.item_name
	enhanced_data["item_type"] = item_data.item_type
	enhanced_data["item_level"] = item_data.item_level
	
	return await spawn_object(round_id, item_data.scene_path, spawn_position, enhanced_data)

## Spawna um item por ID
func spawn_item_by_id(round_id: int, item_id: int, spawn_position: Variant, data: Dictionary = {}) -> int:
	var item_data = ItemDatabase.get_item_by_id(item_id)
	
	if item_data == null:
		push_error("Item não encontrado com ID: %d" % item_id)
		return -1
	
	return await spawn_item(round_id, item_data.item_name, spawn_position, data)

## Spawna múltiplos objetos de uma vez
func spawn_multiple(round_id: int, scene_path: String, positions: Array, data: Dictionary = {}) -> Array:
	var spawned_ids = []
	
	for pos in positions:
		var id = await spawn_object(round_id, scene_path, pos, data)
		if id != -1:
			spawned_ids.append(id)
	
	return spawned_ids

## Spawna múltiplos itens por nome
func spawn_multiple_items(round_id: int, item_name: String, positions: Array, data: Dictionary = {}) -> Array:
	var spawned_ids = []
	
	for pos in positions:
		var id = await spawn_item(round_id, item_name, pos, data)
		if id != -1:
			spawned_ids.append(id)
	
	return spawned_ids

## Spawna itens aleatórios de um tipo em uma área
func spawn_random_items_by_type(round_id: int, type: String, count: int, spawn_area: Rect2, data: Dictionary = {}) -> Array:
	var type_items = ItemDatabase.get_items_by_type(type)
	
	if type_items.is_empty():
		push_warning("Nenhum item do tipo '%s' encontrado" % type)
		return []
	
	var spawned_ids = []
	
	for i in range(count):
		# Item aleatório do tipo
		var random_item = type_items.pick_random()
		
		# Posição aleatória na área
		var random_pos = Vector2(
			randf_range(spawn_area.position.x, spawn_area.end.x),
			randf_range(spawn_area.position.y, spawn_area.end.y)
		)
		
		var id = await spawn_item(round_id, random_item.item_name, random_pos, data)
		if id != -1:
			spawned_ids.append(id)
	
	return spawned_ids

## NOVO: Spawna conjunto de itens em uma rodada (útil para setup inicial)
func spawn_item_set(round_id: int, items_config: Array) -> Dictionary:
	"""
	Spawna múltiplos itens diferentes em uma rodada.
	
	items_config formato:
	[
		{"item": "sword_1", "position": Vector3(10, 0, 5)},
		{"item": "shield_2", "position": Vector3(15, 0, 8), "data": {"custom": true}}
	]
	"""
	var results = {
		"spawned": [],
		"failed": []
	}
	
	for item_config in items_config:
		if not item_config.has("item") or not item_config.has("position"):
			results["failed"].append({"error": "Missing item or position", "config": item_config})
			continue
		
		var item_name = item_config["item"]
		var position = item_config["position"]
		var custom_data = item_config.get("data", {})
		
		var obj_id = await spawn_item(round_id, item_name, position, custom_data)
		
		if obj_id != -1:
			results["spawned"].append({"item": item_name, "id": obj_id})
		else:
			results["failed"].append({"item": item_name, "position": position})
	
	_log_debug("Item set spawned na rodada %d: %d sucesso, %d falhas" % [
		round_id, 
		results["spawned"].size(), 
		results["failed"].size()
	])
	
	return results

# ===== DESPAWN DE OBJETOS (SERVIDOR) =====

func despawn_object(object_id: int):
	if not multiplayer.is_server():
		push_error("Apenas o servidor pode despawnar objetos!")
		return
	
	if not object_index.has(object_id):
		push_warning("Tentativa de despawnar objeto inexistente: %d" % object_id)
		return
	
	var obj_data = object_index[object_id]
	var round_id = obj_data["round_id"]
	var obj = obj_data["node"]
	
	_log_debug("Despawnando objeto ID: %d da rodada %d" % [object_id, round_id])
	
	# Remove do servidor
	if obj and is_instance_valid(obj):
		obj.queue_free()
	
	# Remove dos registros
	_unregister_object(round_id, object_id)
	
	# Notifica clientes da rodada
	_rpc_to_round_players(round_id, "_client_despawn_object", object_id)
	
	object_despawned.emit(round_id, object_id)

## Remove todos os objetos de uma rodada específica
func despawn_round_objects(round_id: int):
	if not multiplayer.is_server():
		return
	
	if not spawned_objects_by_round.has(round_id):
		return
	
	var round_objects = spawned_objects_by_round[round_id]
	var count = round_objects.size()
	
	_log_debug("Despawnando todos os objetos da rodada %d (%d objetos)" % [round_id, count])
	
	# Copia as chaves para evitar modificação durante iteração
	var object_ids = round_objects.keys()
	for object_id in object_ids:
		despawn_object(object_id)
	
	round_objects_cleared.emit(round_id, count)

## Remove todos os objetos de todas as rodadas
func despawn_all():
	if not multiplayer.is_server():
		return
	
	_log_debug("Despawnando objetos de todas as rodadas...")
	
	var round_ids = spawned_objects_by_round.keys()
	for round_id in round_ids:
		despawn_round_objects(round_id)

# ===== INSTANCIAÇÃO (USADO INTERNAMENTE) =====

## Instancia um objeto localmente (usa ItemDatabase automaticamente)
func _instantiate_object(scene_path: String, spawn_position: Variant, data: Dictionary, object_id: int, round_id: int) -> Node:
	var scene: PackedScene = null
	
	# Tenta usar ItemDatabase (otimizado para clientes)
	if not multiplayer.is_server():
		var item_name = _extract_item_name_from_path(scene_path)
		scene = ItemDatabase.get_item_scene(item_name)
		
		if scene:
			_log_debug(" Cena obtida do cache: %s" % item_name)
	
	# Fallback: carrega normalmente (servidor ou item não encontrado)
	if scene == null:
		if not ResourceLoader.exists(scene_path):
			push_error("Caminho de cena não existe: %s" % scene_path)
			return null
		
		scene = load(scene_path)
		if scene == null:
			push_error("Falha ao carregar cena: %s" % scene_path)
			return null
	
	# Instancia
	var obj = scene.instantiate()
	if obj == null:
		push_error("Falha ao instanciar cena: %s" % scene_path)
		return null
	
	# Configura nome com identificação de rodada
	obj.name = "R%d_Object_%d" % [round_id, object_id]
	
	# Adiciona metadata da rodada
	obj.set_meta("round_id", round_id)
	obj.set_meta("object_id", object_id)
	
	# ADICIONA À ÁRVORE PRIMEIRO
	get_tree().root.add_child(obj)
	
	# AGUARDA ESTAR PRONTO
	if not obj.is_node_ready():
		await obj.ready
	await get_tree().process_frame
	
	# VALIDA QUE ESTÁ NA ÁRVORE
	if not obj.is_inside_tree():
		push_error("Objeto não foi adicionado à árvore: %s" % scene_path)
		obj.queue_free()
		return null
	
	# AGORA define posição (está na árvore, é seguro)
	if obj is Node3D:
		if spawn_position is Vector3:
			obj.global_position = spawn_position
		elif spawn_position is Vector2:
			obj.global_position = Vector3(spawn_position.x, 0, spawn_position.y)
		else:
			push_warning("Tipo de posição não suportado para Node3D: %s" % type_string(typeof(spawn_position)))
	elif obj is Node2D:
		if spawn_position is Vector2:
			obj.global_position = spawn_position
		elif spawn_position is Vector3:
			obj.global_position = Vector2(spawn_position.x, spawn_position.z)
		else:
			push_warning("Tipo de posição não suportado para Node2D: %s" % type_string(typeof(spawn_position)))
	
	# Aplica dados customizados
	if obj.has_method("configure"):
		obj.configure(data)
	elif not data.is_empty():
		# Tenta aplicar propriedades diretamente
		for key in data:
			if key in obj:
				obj.set(key, data[key])
	
	_log_debug(" Objeto instanciado: %s em %s (rodada %d)" % [obj.name, spawn_position, round_id])
	
	return obj

## Extrai nome do item do path completo
func _extract_item_name_from_path(scene_path: String) -> String:
	# "res://scenes/collectibles/sword_1.tscn" -> "sword_1"
	var file_name = scene_path.get_file()  # "sword_1.tscn"
	return file_name.get_basename()  # "sword_1"

# ===== GERENCIAMENTO DE REGISTROS =====

func _register_object(round_id: int, object_id: int, node: Node):
	# Cria dicionário da rodada se não existir
	if not spawned_objects_by_round.has(round_id):
		spawned_objects_by_round[round_id] = {}
	
	# Registra na rodada
	spawned_objects_by_round[round_id][object_id] = node
	
	# Registra no índice global
	object_index[object_id] = {
		"round_id": round_id,
		"node": node
	}

func _unregister_object(round_id: int, object_id: int):
	# Remove da rodada
	if spawned_objects_by_round.has(round_id):
		spawned_objects_by_round[round_id].erase(object_id)
		
		# Remove dicionário da rodada se vazio
		if spawned_objects_by_round[round_id].is_empty():
			spawned_objects_by_round.erase(round_id)
	
	# Remove do índice global
	object_index.erase(object_id)

# ===== RPC INTELIGENTE (APENAS JOGADORES DA RODADA) =====

func _rpc_to_round_players(round_id: int, method: String, data):
	"""
	Envia RPC apenas para jogadores da rodada específica.
	Muito mais eficiente que broadcast global.
	"""
	var round_data = round_registry.get_round(round_id)
	if round_data.is_empty():
		return
	
	# Pega lista de peer_ids dos jogadores da rodada
	var target_peers = []
	for player in round_data["players"]:
		target_peers.append(player["id"])
	
	# Envia RPC apenas para esses peers
	for peer_id in target_peers:
		NetworkManager.rpc_id(peer_id, method, data)

# ===== QUERIES DE ESTADO =====

## Retorna um objeto pelo ID
func get_object(object_id: int) -> Node:
	if not object_index.has(object_id):
		return null
	return object_index[object_id]["node"]

## Retorna todos os objetos de uma rodada
func get_round_objects(round_id: int) -> Array:
	if not spawned_objects_by_round.has(round_id):
		return []
	return spawned_objects_by_round[round_id].values()

## Retorna todos os objetos de todas as rodadas
func get_all_objects() -> Array:
	var all_objects = []
	for round_id in spawned_objects_by_round:
		all_objects.append_array(spawned_objects_by_round[round_id].values())
	return all_objects

## Retorna contagem de objetos de uma rodada
func get_round_object_count(round_id: int) -> int:
	if not spawned_objects_by_round.has(round_id):
		return 0
	return spawned_objects_by_round[round_id].size()

## Retorna contagem total de objetos
func get_total_object_count() -> int:
	return object_index.size()

## Verifica se um objeto existe
func object_exists(object_id: int) -> bool:
	if not object_index.has(object_id):
		return false
	var node = object_index[object_id]["node"]
	return is_instance_valid(node)

## Retorna a rodada de um objeto
func get_object_round_id(object_id: int) -> int:
	if not object_index.has(object_id):
		return -1
	return object_index[object_id]["round_id"]

## Retorna todos os objetos de um item específico em uma rodada
func get_round_objects_by_item_name(round_id: int, item_name: String) -> Array:
	var result = []
	var round_objects = get_round_objects(round_id)
	
	for obj in round_objects:
		if is_instance_valid(obj) and obj.get("item_name") == item_name:
			result.append(obj)
	
	return result

## Retorna todos os objetos de um tipo em uma rodada
func get_round_objects_by_item_type(round_id: int, item_type: String) -> Array:
	var result = []
	var round_objects = get_round_objects(round_id)
	
	for obj in round_objects:
		if is_instance_valid(obj) and obj.get("item_type") == item_type:
			result.append(obj)
	
	return result

## NOVO: Retorna estatísticas de spawning
func get_spawn_stats() -> Dictionary:
	var stats = {
		"total_objects": object_index.size(),
		"active_rounds": spawned_objects_by_round.size(),
		"objects_by_round": {}
	}
	
	for round_id in spawned_objects_by_round:
		stats["objects_by_round"][round_id] = spawned_objects_by_round[round_id].size()
	
	return stats

# ===== CALLBACKS =====

func _on_round_ended(round_data: Dictionary):
	"""Limpa objetos quando rodada termina"""
	var round_id = round_data["round_id"]
	
	_log_debug("Rodada %d terminou - limpando %d objetos" % [
		round_id,
		get_round_object_count(round_id)
	])
	
	despawn_round_objects(round_id)

# ===== UTILITÁRIOS =====

func _generate_object_id() -> int:
	var id = next_object_id
	next_object_id += 1
	return id

func _log_debug(message: String):
	if debug_mode:
		print("[ObjectSpawner] " + message)

# ===== LIMPEZA =====

func cleanup():
	_log_debug("Limpando todos os objetos spawnados...")
	despawn_all()
	spawned_objects_by_round.clear()
	object_index.clear()
	next_object_id = 1
	_log_debug(" Cleanup completo")

# ===== DEBUG =====

func print_spawn_info():
	"""Imprime informações de debug sobre objetos spawnados"""
	print("\n=== OBJECT SPAWNER STATUS ===")
	print("Total de objetos: %d" % object_index.size())
	print("Rodadas ativas: %d" % spawned_objects_by_round.size())
	
	for round_id in spawned_objects_by_round:
		var count = spawned_objects_by_round[round_id].size()
		print("  Rodada %d: %d objetos" % [round_id, count])
		
## Spawna item e adiciona automaticamente ao inventário do jogador mais próximo
func spawn_and_collect(round_id: int, item_name: String, spawn_position: Vector3, auto_collect_radius: float = 2.0) -> Dictionary:
	"""
	Spawna item e adiciona ao inventário se houver jogador próximo.
	Retorna: {spawned: bool, collected: bool, player_id: int, object_id: int}
	"""
	if not multiplayer.is_server():
		return {}
	
	# Spawna o item
	var object_id = await spawn_item(round_id, item_name, spawn_position)
	
	if object_id == -1:
		return {"spawned": false, "collected": false, "player_id": -1, "object_id": -1}
	
	# Verifica jogador próximo
	var dummy_node = Node3D.new()
	dummy_node.global_position = spawn_position
	get_tree().root.add_child(dummy_node)
	
	var nearest = player_registry.get_nearest_player_to(dummy_node, auto_collect_radius)
	dummy_node.queue_free()
	
	if nearest.is_empty():
		return {"spawned": true, "collected": false, "player_id": -1, "object_id": object_id}
	
	# Adiciona ao inventário
	var player_id = nearest["id"]
	var collected = player_registry.add_item_to_inventory(round_id, player_id, item_name)
	
	if collected:
		# Despawna o objeto já que foi coletado
		despawn_object(object_id)
		_log_debug(" Item auto-coletado: %s por Player %d" % [item_name, player_id])
	
	return {
		"spawned": true,
		"collected": collected,
		"player_id": player_id,
		"object_id": object_id if not collected else -1
	}

## Spawna item diretamente no inventário (sem aparecer no mundo)
func spawn_item_to_inventory(round_id: int, player_id: int, item_name: String) -> bool:
	"""
	Adiciona item diretamente ao inventário do jogador sem spawnar no mundo.
	Útil para recompensas, crafting, etc.
	"""
	if not multiplayer.is_server():
		return false
	
	# Valida item
	if not ItemDatabase.item_exists(item_name):
		push_error("Item inválido: %s" % item_name)
		return false
	
	# Adiciona ao inventário
	var success = player_registry.add_item_to_inventory(round_id, player_id, item_name)
	
	if success:
		_log_debug(" Item adicionado ao inventário: %s → Player %d" % [item_name, player_id])
		
		# Notifica cliente via RPC
		_notify_inventory_update(round_id, player_id)
	
	return success

## Spawna múltiplos itens direto no inventário
func spawn_items_to_inventory(round_id: int, player_id: int, items: Array) -> Dictionary:
	"""
	Adiciona múltiplos itens ao inventário.
	items: Array de Strings (item_names)
	Retorna: {added: int, failed: Array}
	"""
	if not multiplayer.is_server():
		return {}
	
	var result = {
		"added": 0,
		"failed": []
	}
	
	for item_name in items:
		var success = spawn_item_to_inventory(round_id, player_id, item_name)
		if success:
			result["added"] += 1
		else:
			result["failed"].append(item_name)
	
	_log_debug("Itens adicionados ao inventário: %d/%d (Player %d)" % [
		result["added"],
		items.size(),
		player_id
	])
	
	return result

## Dropa item do inventário no mundo
func drop_item_from_inventory(round_id: int, player_id: int, item_name: String, drop_offset: Vector3 = Vector3(0, 1, 2)) -> int:
	"""
	Remove item do inventário e spawna no mundo próximo ao jogador.
	Retorna object_id do item spawnado ou -1 se falhar.
	"""
	if not multiplayer.is_server():
		return -1
	
	# Verifica se jogador tem o item
	if not player_registry.has_item(round_id, player_id, item_name):
		_log_debug("⚠ Player %d não possui item %s" % [player_id, item_name])
		return -1
	
	# Obtém posição do jogador
	var player_node = player_registry.get_player_node(player_id)
	if not player_node or not player_node is Node3D:
		push_error("Nó do player inválido: %d" % player_id)
		return -1
	
	var drop_position = player_node.global_position + drop_offset
	
	# Remove do inventário
	if not player_registry.remove_item_from_inventory(round_id, player_id, item_name):
		return -1
	
	# Spawna no mundo
	var object_id = await spawn_item(round_id, item_name, drop_position)
	
	if object_id != -1:
		_log_debug(" Item dropado: %s por Player %d em %s" % [item_name, player_id, drop_position])
	
	return object_id

## Spawna loot aleatório para um jogador específico
func spawn_loot_for_player(round_id: int, player_id: int, loot_table: Dictionary) -> Dictionary:
	"""
	Spawna loot baseado em uma tabela de probabilidades.
	
	loot_table formato:
	{
		"sword_1": 0.5,    # 50% de chance
		"shield_2": 0.3,   # 30% de chance
		"cape_1": 0.2      # 20% de chance
	}
	
	Retorna: {item: String, success: bool}
	"""
	if not multiplayer.is_server():
		return {}
	
	# Valida loot table
	if loot_table.is_empty():
		return {"item": "", "success": false}
	
	# Sorteia item baseado em probabilidades
	var roll = randf()
	var cumulative = 0.0
	var selected_item = ""
	
	for item_name in loot_table:
		cumulative += loot_table[item_name]
		if roll <= cumulative:
			selected_item = item_name
			break
	
	if selected_item.is_empty():
		# Fallback: pega primeiro item
		selected_item = loot_table.keys()[0]
	
	# Adiciona ao inventário
	var success = spawn_item_to_inventory(round_id, player_id, selected_item)
	
	_log_debug("Loot sorteado para Player %d: %s (sucesso: %s)" % [
		player_id,
		selected_item,
		success
	])
	
	return {"item": selected_item, "success": success}

## Coleta item do mundo e adiciona ao inventário
func collect_item_object(object_id: int, player_id: int) -> bool:
	"""
	Coleta um item spawnado no mundo e adiciona ao inventário do jogador.
	Remove o objeto do mundo após coletar.
	"""
	if not multiplayer.is_server():
		return false
	
	# Verifica se objeto existe
	if not object_exists(object_id):
		push_error("Objeto não existe: %d" % object_id)
		return false
	
	var obj = get_object(object_id)
	if not obj:
		return false
	
	# Obtém dados do item
	var item_name = obj.get_meta("item_name", "")
	var round_id = obj.get_meta("round_id", -1)
	
	if item_name.is_empty() or round_id == -1:
		push_error("Objeto %d não tem metadados de item" % object_id)
		return false
	
	# Adiciona ao inventário
	var success = player_registry.add_item_to_inventory(round_id, player_id, item_name)
	
	if success:
		# Remove do mundo
		despawn_object(object_id)
		_log_debug(" Item coletado: %s por Player %d (objeto %d)" % [item_name, player_id, object_id])
		
		# Notifica cliente
		_notify_inventory_update(round_id, player_id)
	
	return success

## Retorna itens coletáveis próximos ao jogador
func get_collectible_items_near_player(round_id: int, player_id: int, radius: float = 5.0) -> Array:
	"""
	Retorna array de objetos coletáveis próximos ao jogador.
	Cada elemento: {object_id: int, item_name: String, distance: float}
	"""
	if not multiplayer.is_server():
		return []
	
	var player_node = player_registry.get_player_node(player_id)
	if not player_node or not player_node is Node3D:
		return []
	
	var player_pos = player_node.global_position
	var nearby_items = []
	
	# Busca objetos da rodada
	var round_objects = get_round_objects(round_id)
	
	for obj in round_objects:
		if not is_instance_valid(obj) or not obj is Node3D:
			continue
		
		var distance = player_pos.distance_to(obj.global_position)
		if distance <= radius:
			nearby_items.append({
				"object_id": obj.get_meta("object_id", -1),
				"item_name": obj.get_meta("item_name", ""),
				"distance": distance,
				"position": obj.global_position
			})
	
	# Ordena por distância (mais próximo primeiro)
	nearby_items.sort_custom(func(a, b): return a["distance"] < b["distance"])
	
	return nearby_items

## Auto-coleta itens próximos ao jogador
func auto_collect_nearby_items(round_id: int, player_id: int, radius: float = 2.0) -> int:
	"""
	Coleta automaticamente todos os itens próximos ao jogador.
	Retorna quantidade de itens coletados.
	"""
	if not multiplayer.is_server():
		return 0
	
	var nearby = get_collectible_items_near_player(round_id, player_id, radius)
	var collected = 0
	
	for item_data in nearby:
		var object_id = item_data["object_id"]
		if collect_item_object(object_id, player_id):
			collected += 1
	
	if collected > 0:
		_log_debug(" Auto-coleta: %d itens coletados por Player %d" % [collected, player_id])
	
	return collected

## Spawna recompensa para todos os jogadores da rodada
func spawn_reward_for_all_players(round_id: int, item_name: String) -> Dictionary:
	"""
	Adiciona um item ao inventário de todos os jogadores da rodada.
	Retorna: {success: Array[player_id], failed: Array[player_id]}
	"""
	if not multiplayer.is_server():
		return {}
	
	var round_data = round_registry.get_round(round_id)
	if round_data.is_empty():
		return {"success": [], "failed": []}
	
	var result = {
		"success": [],
		"failed": []
	}
	
	for player_data in round_data["players"]:
		var player_id = player_data["id"]
		var success = spawn_item_to_inventory(round_id, player_id, item_name)
		
		if success:
			result["success"].append(player_id)
		else:
			result["failed"].append(player_id)
	
	_log_debug("Recompensa distribuída: %s para %d/%d jogadores" % [
		item_name,
		result["success"].size(),
		round_data["players"].size()
	])
	
	return result

# ===== RPC PARA NOTIFICAÇÕES =====

func _notify_inventory_update(round_id: int, player_id: int):
	"""Notifica cliente sobre atualização de inventário"""
	var inventory = player_registry.get_player_inventory(round_id, player_id)
	
	if inventory.is_empty():
		return
	
	# Envia dados do inventário para o cliente
	NetworkManager.rpc_id(player_id, "_client_update_inventory", {
		"round_id": round_id,
		"inventory": inventory["inventory"],
		"equipped": inventory["equipped"],
		"stats": inventory["stats"]
	})

# ===== LIMPEZA INTEGRADA =====

## Limpa objetos da rodada E inventários
func cleanup_round_complete(round_id: int):
	"""Limpeza completa: objetos no mundo + inventários"""
	if not multiplayer.is_server():
		return
	
	var obj_count = get_round_object_count(round_id)
	
	# Limpa objetos do mundo
	despawn_round_objects(round_id)
	
	# Limpa inventários (PlayerRegistry já faz isso via signal, mas garante)
	var round_data = round_registry.get_round(round_id)
	if not round_data.is_empty():
		for player_data in round_data["players"]:
			player_registry.clear_player_inventory(round_id, player_data["id"])
	
	_log_debug(" Limpeza completa da rodada %d: %d objetos + inventários" % [round_id, obj_count])

# ===== DEBUG INTEGRADO =====

func debug_print_round_items_and_inventories(round_id: int):
	"""Imprime objetos no mundo E inventários dos jogadores"""
	if not multiplayer.is_server():
		return
	
	print("\n=== RODADA %d: ITENS & INVENTÁRIOS ===" % round_id)
	
	# Objetos no mundo
	var objects = get_round_objects(round_id)
	print("\n[MUNDO] %d objetos:" % objects.size())
	for obj in objects:
		if is_instance_valid(obj):
			var item_name = obj.get_meta("item_name", "?")
			var pos = obj.global_position if obj is Node3D else "N/A"
			print("  • %s em %s" % [item_name, pos])
	
	# Inventários
	var round_data = round_registry.get_round(round_id)
	if not round_data.is_empty():
		print("\n[INVENTÁRIOS] %d jogadores:" % round_data["players"].size())
		for player_data in round_data["players"]:
			var player_id = player_data["id"]
			var inventory = player_registry.get_player_inventory(round_id, player_id)
			
			if not inventory.is_empty():
				print("  Player %d (%s):" % [player_id, player_data.get("name", "?")])
				print("    Inventário: %s" % inventory["inventory"])
				print("    Equipados: %s" % inventory["equipped"])
	
	print("========================================\n")
