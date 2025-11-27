extends Node
## ItemDatabase - Sistema de consulta e leitura de itens
## Gerencia database de itens carregado do JSON
## 
## RESPONSABILIDADES:
## - Carregar dados de itens do JSON
## - Fornecer queries rápidas por ID, nome, tipo, owner, etc
## - Validar existência de itens
## - Fornecer informações de slots e equipabilidade

# ===== CONFIGURAÇÕES =====

@export_category("Database Settings")
@export var json_path: String = "res://scripts/utils/item_database_regs.json"
@export var auto_load_on_ready: bool = true

@export_category("Debug")
@export var debug_mode: bool = true


# ===== VARIÁVEIS INTERNAS =====
var _is_server: bool = false

# ===== ESTRUTURA DE DADOS =====

## Classe interna para representar um item
class ItemData:
	var id: int
	var scene_path: String
	var model_node_link: String
	var owner: String
	var name: String
	var type: String
	var level: int
	var condition: int
	var dropped_scene: String
	var icon_path: String
	var metadata: Dictionary = {}
	
	func _init(json_data: Dictionary):
		id = json_data.get("id", 0)
		scene_path = json_data.get("scene_path", "")
		model_node_link = json_data.get("model_node_link", "")
		owner = json_data.get("owner", "")
		name = json_data.get("name", "")
		type = json_data.get("type", "")
		level = int(json_data.get("level", 1))
		condition = int(json_data.get("condition", 100))
		dropped_scene = json_data.get("dropped_scene", "res://scenes/items/dropped_item.tscn")
		icon_path = json_data.get("icon_path", "")
		
		# Armazena campos extras em metadata
		for key in json_data:
			if key not in ["id", "scene_path", "model_node_link", "owner", "name", "type", "level", "condition", "dropped_scene", "icon_path"]:
				metadata[key] = json_data[key]
	
	func to_dictionary() -> Dictionary:
		var dict = {
			"id": id,
			"scene_path": scene_path,
			"model_node_link": model_node_link,
			"owner": owner,
			"name": name,
			"type": type,
			"level": level,
			"condition": condition,
			"dropped_scene": dropped_scene,
			"icon_path": icon_path
		}
		for key in metadata:
			dict[key] = metadata[key]
		return dict
	
	func get_slot() -> String:
		"""Retorna o slot de equipamento baseado no type"""
		return type
	
	func is_hand_item() -> bool:
		"""Verifica se é item de mão"""
		return type in ["hand-left", "hand-right"]
	
	func is_equipable() -> bool:
		"""Verifica se item pode ser equipado"""
		return type in ["head", "body", "hand-left", "hand-right", "back"]
	
	func can_equip_in_slot(slot: String) -> bool:
		"""Verifica se pode equipar neste slot específico"""
		return type == slot
	
	func get_metadata(key: String, default = null):
		return metadata.get(key, default)
	
	func has_metadata(key: String) -> bool:
		return metadata.has(key)

# ===== DADOS =====

## Database principal: {item_name: ItemData}
var items: Dictionary = {}

## Índices para queries rápidas
var items_by_id: Dictionary = {}
var items_by_type: Dictionary = {}
var items_by_owner: Dictionary = {}
var items_by_level: Dictionary = {}

## Estatísticas
var load_time: float = 0.0
var is_loaded: bool = false

# ===== INICIALIZAÇÃO =====

func _ready():
	# Detecta se é servidor dedicado
	var args = OS.get_cmdline_args()
	_is_server = "--server" in args or "--dedicated" in args
	
	if auto_load_on_ready:
		load_database()

func load_database() -> bool:
	"""Carrega o database do JSON"""
	var start_time = Time.get_ticks_msec()
	
	if not _load_json_data():
		push_error("[ItemDatabase] Falha ao carregar database!")
		return false
	
	load_time = (Time.get_ticks_msec() - start_time) / 1000.0
	is_loaded = true
	
	_log_debug("✓ Database carregado: %d itens em %.3fs" % [items.size(), load_time])
	return true

func reload_database() -> bool:
	"""Recarrega o database (útil para desenvolvimento)"""
	_clear_database()
	return load_database()

# ===== CARREGAMENTO DE DADOS =====

func _load_json_data() -> bool:
	if not FileAccess.file_exists(json_path):
		push_error("Arquivo JSON não encontrado: %s" % json_path)
		return false
	
	var file = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("Falha ao abrir arquivo JSON: %s" % json_path)
		return false
	
	var json_text = file.get_as_text()
	file.close()
	
	if json_text.is_empty():
		push_error("Arquivo JSON está vazio")
		return false
	
	var json = JSON.new()
	var error = json.parse(json_text)
	
	if error != OK:
		push_error("Erro ao parsear JSON: %s" % json.get_error_message())
		return false
	
	var json_data = json.data
	
	if not json_data is Array:
		push_error("JSON deve ser um array de itens")
		return false
	
	_clear_database()
	
	var loaded_count = 0
	for item_dict in json_data:
		if _register_item(item_dict):
			loaded_count += 1
	
	return loaded_count > 0

func _clear_database():
	items.clear()
	items_by_id.clear()
	items_by_type.clear()
	items_by_owner.clear()
	items_by_level.clear()
	is_loaded = false

func _register_item(json_data: Dictionary) -> bool:
	if not json_data.has("name") or json_data["name"].is_empty():
		push_warning("Item sem 'name'")
		return false
	
	if not json_data.has("scene_path") or json_data["scene_path"].is_empty():
		push_warning("Item '%s' sem 'scene_path'" % json_data["name"])
		return false
	
	var item_name = json_data["name"]
	
	if items.has(item_name):
		push_warning("Item duplicado: %s" % item_name)
		return false
	
	var item_data = ItemData.new(json_data)
	
	# Registra no database principal
	items[item_name] = item_data
	items_by_id[item_data.id] = item_data
	
	# Índice por tipo
	if not items_by_type.has(item_data.type):
		items_by_type[item_data.type] = []
	items_by_type[item_data.type].append(item_data)
	
	# Índice por owner
	if not items_by_owner.has(item_data.owner):
		items_by_owner[item_data.owner] = []
	items_by_owner[item_data.owner].append(item_data)
	
	# Índice por level
	if not items_by_level.has(item_data.level):
		items_by_level[item_data.level] = []
	items_by_level[item_data.level].append(item_data)
	
	return true

# ===== API PÚBLICA - QUERIES BÁSICAS =====

func get_item(item_name: String) -> ItemData:
	"""Retorna ItemData pelo nome"""
	return items.get(item_name, null)

func get_item_by_id(id: int) -> ItemData:
	"""Retorna ItemData pelo ID"""
	return items_by_id.get(id, null)

func item_exists(item_name: String) -> bool:
	"""Verifica se item existe no database"""
	return items.has(item_name)

func get_all_item_names() -> Array:
	"""Retorna array com nomes de todos os itens"""
	return items.keys()

func get_all_items() -> Array:
	"""Retorna array com todos os ItemData"""
	return items.values()

func get_item_count() -> int:
	"""Retorna quantidade total de itens"""
	return items.size()

# ===== API PÚBLICA - INFORMAÇÕES DE ITEM =====

func get_item_scene_path(item_name: String) -> String:
	"""Retorna caminho da cena do item"""
	var item_data = get_item(item_name)
	return item_data.scene_path if item_data else ""

func get_item_model_link(item_name: String) -> String:
	"""Retorna link do modelo 3D do item"""
	var item_data = get_item(item_name)
	return item_data.model_node_link if item_data else ""

func get_item_owner(item_name: String) -> String:
	"""Retorna dono do item (knight, archer, etc)"""
	var item_data = get_item(item_name)
	return item_data.owner if item_data else ""

func get_item_type(item_name: String) -> String:
	"""Retorna tipo do item (head, body, hand-left, etc)"""
	var item_data = get_item(item_name)
	return item_data.type if item_data else ""

func get_item_level(item_name: String) -> int:
	"""Retorna level do item"""
	var item_data = get_item(item_name)
	return item_data.level if item_data else 0

func get_item_condition(item_name: String) -> int:
	"""Retorna condição do item (0-100)"""
	var item_data = get_item(item_name)
	return item_data.condition if item_data else 0

func get_item_icon_path(item_name: String) -> String:
	"""Retorna caminho do ícone do item"""
	var item_data = get_item(item_name)
	return item_data.icon_path if item_data else ""

func get_item_dropped_scene(item_name: String) -> String:
	"""Retorna caminho da cena de item dropado"""
	var item_data = get_item(item_name)
	return item_data.dropped_scene if item_data else ""

func get_item_metadata(item_name: String, key: String, default = null):
	"""Retorna valor de metadata do item"""
	var item_data = get_item(item_name)
	return item_data.get_metadata(key, default) if item_data else default

func get_item_full_info(item_name: String) -> Dictionary:
	"""Retorna todas as informações do item como Dictionary"""
	var item_data = get_item(item_name)
	return item_data.to_dictionary() if item_data else {}

# ===== API PÚBLICA - DETECÇÃO DE SLOT =====

func get_item_slot(item_name: String) -> String:
	"""Retorna o slot do item (head, body, hand-left, hand-right, back)"""
	var item_data = get_item(item_name)
	return item_data.get_slot() if item_data else ""

func is_equipable(item_name: String) -> bool:
	"""Verifica se item pode ser equipado"""
	var item_data = get_item(item_name)
	return item_data.is_equipable() if item_data else false

func is_hand_item(item_name: String) -> bool:
	"""Verifica se é item de mão (hand-left ou hand-right)"""
	var item_data = get_item(item_name)
	return item_data.is_hand_item() if item_data else false

func can_equip_in_slot(item_name: String, slot: String) -> bool:
	"""Verifica se item pode ser equipado em slot específico"""
	var item_data = get_item(item_name)
	return item_data.can_equip_in_slot(slot) if item_data else false

func get_valid_slots() -> Array:
	"""Retorna lista de slots válidos para equipamento"""
	return ["head", "body", "hand-left", "hand-right", "back"]

func is_valid_slot(slot: String) -> bool:
	"""Verifica se slot é válido"""
	return slot in get_valid_slots()

# ===== API PÚBLICA - QUERIES POR ÍNDICE =====

func get_items_by_type(type: String) -> Array:
	"""Retorna array de ItemData por tipo"""
	return items_by_type.get(type, []).duplicate()

func get_items_by_owner(_owner: String) -> Array:
	"""Retorna array de ItemData por dono"""
	return items_by_owner.get(_owner, []).duplicate()

func get_items_by_level(level: int) -> Array:
	"""Retorna array de ItemData por level"""
	return items_by_level.get(level, []).duplicate()

func get_hand_items() -> Array:
	"""Retorna todos os itens de mão (left + right)"""
	var left = get_items_by_type("hand-left")
	var right = get_items_by_type("hand-right")
	return left + right

func get_armor_items() -> Array:
	"""Retorna todos os itens de armadura (head + body)"""
	var head = get_items_by_type("head")
	var body = get_items_by_type("body")
	return head + body

func get_back_items() -> Array:
	"""Retorna todos os itens de costas"""
	return get_items_by_type("back")

# ===== QUERIES AVANÇADAS =====

func query_items(filters: Dictionary) -> Array:
	"""
	Busca itens por múltiplos filtros
	Filtros disponíveis:
	- type: String
	- owner: String
	- min_level: int
	- max_level: int
	- min_condition: int
	- equipable: bool
	- hand_item: bool
	"""
	var result = []
	
	for item_data in items.values():
		if _matches_filters(item_data, filters):
			result.append(item_data)
	
	return result

func _matches_filters(item: ItemData, filters: Dictionary) -> bool:
	if filters.has("type") and item.type != filters["type"]:
		return false
	
	if filters.has("owner") and item.owner != filters["owner"]:
		return false
	
	if filters.has("min_level") and item.level < filters["min_level"]:
		return false
	
	if filters.has("max_level") and item.level > filters["max_level"]:
		return false
	
	if filters.has("min_condition") and item.condition < filters["min_condition"]:
		return false
	
	if filters.has("equipable") and item.is_equipable() != filters["equipable"]:
		return false
	
	if filters.has("hand_item") and item.is_hand_item() != filters["hand_item"]:
		return false
	
	return true

func get_random_item(type: String = "") -> ItemData:
	"""Retorna item aleatório (opcionalmente filtrado por tipo)"""
	var pool = items.values() if type.is_empty() else get_items_by_type(type)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]

func get_random_item_name(type: String = "") -> String:
	"""Retorna nome de item aleatório"""
	var item = get_random_item(type)
	return item.name if item else ""

# ===== FUNÇÕES DE FACILITAÇÃO =====

func get_items_for_slot(slot: String) -> Array:
	"""Retorna todos os itens que podem ser equipados em um slot"""
	return get_items_by_type(slot)

func get_available_types() -> Array:
	"""Retorna lista de todos os tipos de itens disponíveis"""
	return items_by_type.keys()

func get_available_owners() -> Array:
	"""Retorna lista de todos os owners disponíveis"""
	return items_by_owner.keys()

func get_available_levels() -> Array:
	"""Retorna lista de todos os levels disponíveis"""
	return items_by_level.keys()

func validate_item_list(item_names: Array) -> Dictionary:
	"""
	Valida uma lista de nomes de itens
	Retorna: {valid: Array, invalid: Array}
	"""
	var valid = []
	var invalid = []
	
	for item_name in item_names:
		if item_exists(item_name):
			valid.append(item_name)
		else:
			invalid.append(item_name)
	
	return {"valid": valid, "invalid": invalid}

func compare_items(item1_name: String, item2_name: String) -> Dictionary:
	"""
	Compara dois itens
	Retorna diferenças em: level, condition, type, owner
	"""
	var item1 = get_item(item1_name)
	var item2 = get_item(item2_name)
	
	if not item1 or not item2:
		return {}
	
	return {
		"level_diff": item2.level - item1.level,
		"condition_diff": item2.condition - item1.condition,
		"same_type": item1.type == item2.type,
		"same_owner": item1.owner == item2.owner,
		"both_equipable": item1.is_equipable() and item2.is_equipable(),
		"both_hand_items": item1.is_hand_item() and item2.is_hand_item()
	}

# ===== DEBUG =====

func print_item_info(item_name: String):
	"""Imprime informações completas de um item"""
	var item_data = get_item(item_name)
	if item_data == null:
		print("❌ Item não encontrado: %s" % item_name)
		return
	
	print("\n╔═══ %s ═══╗" % item_name)
	print("  ID: %d" % item_data.id)
	print("  Owner: %s" % item_data.owner)
	print("  Type/Slot: %s" % item_data.type)
	print("  Level: %d" % item_data.level)
	print("  Condition: %d%%" % item_data.condition)
	print("  Equipable: %s" % ("Sim" if item_data.is_equipable() else "Não"))
	print("  Model Link: %s" % item_data.model_node_link)
	print("  Scene: %s" % item_data.scene_path)
	if not item_data.icon_path.is_empty():
		print("  Icon: %s" % item_data.icon_path)
	if not item_data.metadata.is_empty():
		print("  Metadata: %s" % str(item_data.metadata))
	print("╚" + "═".repeat(item_name.length() + 8) + "╝\n")

func print_database_stats():
	"""Imprime estatísticas do database"""
	print("\n========== ITEM DATABASE ==========")
	print("Status: %s" % ("Carregado" if is_loaded else "Não carregado"))
	print("Total de itens: %d" % items.size())
	print("Tempo de carga: %.3fs" % load_time)
	print("-----------------------------------")
	print("Tipos disponíveis: %s" % ", ".join(get_available_types()))
	print("Owners disponíveis: %s" % ", ".join(get_available_owners()))
	print("Levels disponíveis: %s" % ", ".join(PackedStringArray(get_available_levels().map(func(x): return str(x)))))
	print("===================================\n")

func _log_debug(message: String):
	var prefix = "[SERVER]" if _is_server else "[CLIENT]"
	if debug_mode:
		print("%s[ItemDatabase]%s" % [prefix, message])
