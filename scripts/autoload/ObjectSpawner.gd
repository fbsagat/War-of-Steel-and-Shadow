extends Node
## ObjectSpawner - Sistema genérico de spawn de objetos sincronizados
## Permite spawnar qualquer objeto de forma sincronizada entre servidor e clientes

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

## Próximo ID de objeto a ser gerado
var next_object_id: int = 1

## Registro de objetos spawnados
var spawned_objects: Dictionary = {}  # {object_id: Node}

# ===== SINAIS =====

signal object_spawned(object_id: int, object_node: Node)
signal object_despawned(object_id: int)

# ===== INICIALIZAÇÃO =====

func _ready():
	pass

# ===== SPAWN DE OBJETOS (SERVIDOR) =====

## Spawna um objeto de forma sincronizada (apenas servidor deve chamar)
func spawn_object(scene_path: String, spawn_position: Variant, data: Dictionary = {}) -> int:
	if not multiplayer.is_server():
		push_error("Apenas o servidor pode spawnar objetos!")
		return -1
	
	var object_id = _generate_object_id()
	
	_log_debug("Spawnando objeto: %s (ID: %d)" % [scene_path.get_file(), object_id])
	
	# Instancia no servidor primeiro
	var obj = _instantiate_object(scene_path, spawn_position, data, object_id)
	
	if obj == null:
		push_error("Falha ao instanciar objeto: %s" % scene_path)
		return -1
	
	# Registra objeto
	spawned_objects[object_id] = obj
	
	# Notifica clientes para spawnarem também
	var spawn_data = {
		"object_id": object_id,
		"scene_path": scene_path,
		"position": spawn_position,
		"data": data
	}
	
	NetworkManager.rpc("_client_spawn_object", spawn_data)
	
	object_spawned.emit(object_id, obj)
	
	return object_id

## Spawna múltiplos objetos de uma vez
func spawn_multiple(scene_path: String, positions: Array, data: Dictionary = {}) -> Array:
	var spawned_ids = []
	
	for pos in positions:
		var id = spawn_object(scene_path, pos, data)
		if id != -1:
			spawned_ids.append(id)
	
	return spawned_ids

# ===== DESPAWN DE OBJETOS (SERVIDOR) =====

## Remove um objeto de forma sincronizada
func despawn_object(object_id: int):
	if not multiplayer.is_server():
		push_error("Apenas o servidor pode despawnar objetos!")
		return
	
	if not spawned_objects.has(object_id):
		push_warning("Tentativa de despawnar objeto inexistente: %d" % object_id)
		return
	
	_log_debug("Despawnando objeto ID: %d" % object_id)
	
	# Remove do servidor
	var obj = spawned_objects[object_id]
	if obj and is_instance_valid(obj):
		obj.queue_free()
	
	spawned_objects.erase(object_id)
	
	# Notifica clientes
	NetworkManager.rpc("_client_despawn_object", object_id)
	
	object_despawned.emit(object_id)

## Remove todos os objetos spawnados
func despawn_all():
	if not multiplayer.is_server():
		return
	
	_log_debug("Despawnando todos os objetos (%d)" % spawned_objects.size())
	
	var object_ids = spawned_objects.keys()
	for object_id in object_ids:
		despawn_object(object_id)

# ===== INSTANCIAÇÃO (USADO INTERNAMENTE) =====

## Instancia um objeto localmente
func _instantiate_object(scene_path: String, spawn_position: Variant, data: Dictionary, object_id: int) -> Node:
	# Carrega a cena
	var scene = load(scene_path)
	if scene == null:
		push_error("Falha ao carregar cena: %s" % scene_path)
		return null
	
	# Instancia
	var obj = scene.instantiate()
	if obj == null:
		push_error("Falha ao instanciar cena: %s" % scene_path)
		return null
	
	# Configura nome e posição
	obj.name = "Object_%d" % object_id
	
	# Define posição (funciona para Node2D e Node3D)
	if obj is Node3D or obj is Node2D:
		obj.global_position = spawn_position
	
	# Aplica dados customizados
	if obj.has_method("configure"):
		obj.configure(data)
	elif not data.is_empty():
		# Tenta aplicar propriedades diretamente
		for key in data:
			if key in obj:
				obj.set(key, data[key])
	
	# Adiciona à cena
	get_tree().root.add_child(obj)
	
	return obj

# ===== QUERIES =====

## Retorna um objeto spawnado pelo ID
func get_object(object_id: int) -> Node:
	return spawned_objects.get(object_id, null)

## Retorna todos os objetos spawnados
func get_all_objects() -> Array:
	return spawned_objects.values()

## Retorna quantos objetos estão spawnados
func get_object_count() -> int:
	return spawned_objects.size()

## Verifica se um objeto existe
func object_exists(object_id: int) -> bool:
	return spawned_objects.has(object_id) and is_instance_valid(spawned_objects[object_id])

# ===== UTILITÁRIOS =====

func _generate_object_id() -> int:
	var id = next_object_id
	next_object_id += 1
	return id

func _log_debug(message: String):
	if debug_mode:
		print("[ObjectSpawner] " + message)

# ===== LIMPEZA =====

## Limpa todos os objetos spawnados (usado ao mudar de cena/rodada)
func cleanup():
	_log_debug("Limpando objetos spawnados...")
	
	for obj in spawned_objects.values():
		if obj and is_instance_valid(obj):
			obj.queue_free()
	
	spawned_objects.clear()
	next_object_id = 1
	
	_log_debug("✓ Cleanup completo")
