extends Node
## ItemDatabase - Sistema centralizado de gerenciamento de itens
## 100% baseado em JSON - sem paths hardcoded

# ===== CONFIGURAÇÕES =====

@export_category("Database Settings")
@export var json_path: String = "res://scripts/utils/item_database.json"
@export var preload_on_client: bool = true
@export var auto_reload_on_change: bool = false  # Dev mode: recarrega se JSON mudar

@export_category("Debug")
@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

var _is_server: bool = false

# ===== ESTRUTURA DE DADOS =====

## Classe interna para representar um item
class ItemData:
	var id: int
	var item_name: String
	var node_link: String
	var item_type: String  # hand, head, body
	var item_side: String  # left, right, up, down, both
	var item_level: int
	var scene_path: String
	var cached_scene: PackedScene = null
	var metadata: Dictionary = {}  # Campos extras do JSON
	
	func _init(json_data: Dictionary):
		id = json_data.get("id", 0)
		item_name = json_data.get("item_name", "")
		node_link = json_data.get("node_link", "")
		item_type = json_data.get("item_type", "")
		item_side = json_data.get("item_side", "")
		item_level = int(json_data.get("item_level", 1))
		scene_path = json_data.get("scene_path", "")
		
		# Armazena campos extras
		for key in json_data:
			if key not in ["id", "item_name", "node_link", "item_type", "item_side", "item_level", "scene_path"]:
				metadata[key] = json_data[key]
	
	func to_dictionary() -> Dictionary:
		var dict = {
			"id": id,
			"item_name": item_name,
			"node_link": node_link,
			"item_type": item_type,
			"item_side": item_side,
			"item_level": item_level,
			"scene_path": scene_path
		}
		
		# Adiciona metadata
		for key in metadata:
			dict[key] = metadata[key]
		
		return dict
	
	func get_metadata(key: String, default = null):
		"""Retorna valor de metadata customizado"""
		return metadata.get(key, default)
	
	func has_metadata(key: String) -> bool:
		"""Verifica se tem metadata específico"""
		return metadata.has(key)

# ===== DADOS =====

## Database principal: {item_name: ItemData}
var items: Dictionary = {}

## Índices para queries rápidas
var items_by_id: Dictionary = {}  # {id: ItemData}
var items_by_type: Dictionary = {}  # {type: [ItemData, ...]}
var items_by_level: Dictionary = {}  # {level: [ItemData, ...]}
var items_by_side: Dictionary = {}  # {side: [ItemData, ...]}

## Cache de validação
var valid_scene_paths: Dictionary = {}  # {path: bool}

## Estatísticas
var load_time: float = 0.0
var cache_hit_count: int = 0
var cache_miss_count: int = 0

# ===== INICIALIZAÇÃO =====

func _ready():
	var start_time = Time.get_ticks_msec()
	
	var args = OS.get_cmdline_args()
	_is_server = "--server" in args or "--dedicated" in args
	
	# Carrega database do JSON
	if not _load_json_data():
		push_error("Falha ao carregar ItemDatabase!")
		return
	
	# Clientes fazem preload das cenas
	if not _is_server and preload_on_client:
		_preload_all_scenes()
	
	load_time = (Time.get_ticks_msec() - start_time) / 1000.0

# ===== CARREGAMENTO DE DADOS =====

func _load_json_data() -> bool:
	"""Carrega e processa o JSON de itens"""
	
	# Verifica se arquivo existe
	if not FileAccess.file_exists(json_path):
		push_error("Arquivo JSON não encontrado: %s" % json_path)
		return false
	
	var file = FileAccess.open(json_path, FileAccess.READ)
	
	if file == null:
		push_error("Falha ao abrir arquivo JSON: %s (Erro: %d)" % [json_path, FileAccess.get_open_error()])
		return false
	
	var json_text = file.get_as_text()
	file.close()
	
	if json_text.is_empty():
		push_error("Arquivo JSON está vazio: %s" % json_path)
		return false
	
	# Parse JSON
	var json = JSON.new()
	var error = json.parse(json_text)
	
	if error != OK:
		push_error("Erro ao parsear JSON: %s (Linha %d)" % [json.get_error_message(), json.get_error_line()])
		return false
	
	var json_data = json.data
	
	if not json_data is Array:
		push_error("JSON deve ser um array de itens")
		return false
	
	if json_data.is_empty():
		push_warning("Array de itens está vazio no JSON")
		return false
	
	# Limpa dados anteriores (caso esteja recarregando)
	_clear_database()
	
	# Processa cada item
	var loaded_count = 0
	var error_count = 0
	
	for item_dict in json_data:
		if _register_item(item_dict):
			loaded_count += 1
		else:
			error_count += 1
	
	_log_debug("Modo: %s, Total de itens: %d, Tempo de carga: %.3fs" % ["Servidor" if _is_server else "Cliente", items.size(), load_time])
	_log_debug(" %d itens carregados, %d erros" % [loaded_count, error_count])
	
	return loaded_count > 0

func _clear_database():
	"""Limpa todos os dados do database"""
	items.clear()
	items_by_id.clear()
	items_by_type.clear()
	items_by_level.clear()
	items_by_side.clear()
	valid_scene_paths.clear()

func _register_item(json_data: Dictionary) -> bool:
	"""Registra um item no database"""
	
	# Validação básica
	if not json_data.has("item_name") or json_data["item_name"].is_empty():
		push_warning("Item sem 'item_name' encontrado no JSON")
		return false
	
	if not json_data.has("scene_path") or json_data["scene_path"].is_empty():
		push_warning("Item '%s' sem 'scene_path'" % json_data["item_name"])
		return false
	
	var item_name = json_data["item_name"]
	
	# Verifica duplicatas
	if items.has(item_name):
		push_warning("Item duplicado ignorado: %s" % item_name)
		return false
	
	# Cria ItemData
	var item_data = ItemData.new(json_data)
	
	# Valida scene_path (apenas aviso, não bloqueia)
	if not _validate_scene_path(item_data.scene_path):
		push_warning("Scene path pode estar incorreto: %s" % item_data.scene_path)
		# Não retorna false, permite continuar
	
	# Registra no database principal
	items[item_name] = item_data
	
	# Cria índices
	items_by_id[item_data.id] = item_data
	
	# Índice por tipo
	if not items_by_type.has(item_data.item_type):
		items_by_type[item_data.item_type] = []
	items_by_type[item_data.item_type].append(item_data)
	
	# Índice por level
	if not items_by_level.has(item_data.item_level):
		items_by_level[item_data.item_level] = []
	items_by_level[item_data.item_level].append(item_data)
	
	# Índice por side
	if not item_data.item_side.is_empty():
		if not items_by_side.has(item_data.item_side):
			items_by_side[item_data.item_side] = []
		items_by_side[item_data.item_side].append(item_data)
	
	return true

func _validate_scene_path(path: String) -> bool:
	"""Valida se um scene path existe (com cache)"""
	
	# Usa cache se já validou antes
	if valid_scene_paths.has(path):
		return valid_scene_paths[path]
	
	# Valida
	var is_valid = ResourceLoader.exists(path)
	valid_scene_paths[path] = is_valid
	
	return is_valid

func _preload_all_scenes():
	"""Pré-carrega todas as cenas (apenas clientes)"""
	var loaded_count = 0
	var failed_count = 0
	
	for item_name in items:
		var item_data: ItemData = items[item_name]
		
		if item_data.scene_path.is_empty():
			failed_count += 1
			continue
		
		var scene = load(item_data.scene_path)
		
		if scene:
			item_data.cached_scene = scene
			loaded_count += 1
			cache_hit_count += 1
		else:
			push_error("Falha ao carregar cena: %s (Item: %s)" % [item_data.scene_path, item_name])
			failed_count += 1
	
	_log_debug(" %d/%d cenas pré-carregadas (%d falhas)" % [loaded_count, items.size(), failed_count])

# ===== API PÚBLICA - QUERIES BÁSICAS =====

func get_item(item_name: String) -> ItemData:
	"""Retorna dados completos de um item"""
	return items.get(item_name, null)

func get_item_by_id(id: int) -> ItemData:
	"""Retorna item por ID"""
	return items_by_id.get(id, null)

func get_item_scene(item_name: String) -> PackedScene:
	"""Retorna cena pré-carregada (ou carrega sob demanda)"""
	var item_data = get_item(item_name)
	
	if item_data == null:
		push_error("Item não encontrado: %s" % item_name)
		return null
	
	# Usa cache se disponível
	if item_data.cached_scene != null:
		cache_hit_count += 1
		return item_data.cached_scene
	
	# Carrega sob demanda
	cache_miss_count += 1
	var scene = load(item_data.scene_path)
	
	if scene:
		item_data.cached_scene = scene  # Cacheia para próxima vez
	
	return scene

func get_item_path(item_name: String) -> String:
	"""Retorna scene_path de um item"""
	var item_data = get_item(item_name)
	return item_data.scene_path if item_data else ""

func get_item_node_link(item_name: String) -> String:
	"""Retorna node_link para equipar no jogador"""
	var item_data = get_item(item_name)
	return item_data.node_link if item_data else ""

func item_exists(item_name: String) -> bool:
	"""Verifica se um item existe"""
	return items.has(item_name)

func get_all_item_names() -> Array:
	"""Retorna todos os nomes de itens"""
	return items.keys()

func get_item_count() -> int:
	"""Retorna contagem total de itens"""
	return items.size()

# ===== API PÚBLICA - QUERIES POR ÍNDICE =====

func get_items_by_type(type: String) -> Array:
	"""Retorna todos os itens de um tipo"""
	return items_by_type.get(type, [])

func get_items_by_level(level: int) -> Array:
	"""Retorna todos os itens de um level"""
	return items_by_level.get(level, [])

func get_items_by_side(side: String) -> Array:
	"""Retorna itens de um lado específico"""
	return items_by_side.get(side, [])

# ===== API PÚBLICA - QUERIES AVANÇADAS =====

func get_equipable_items(slot_type: String, max_level: int = 999) -> Array:
	"""Retorna itens que o jogador pode equipar em um slot específico"""
	var result = []
	
	var type_items = get_items_by_type(slot_type)
	
	for item_data in type_items:
		if item_data.item_level <= max_level:
			result.append(item_data)
	
	# Ordena por level
	result.sort_custom(func(a, b): return a.item_level < b.item_level)
	
	return result

func get_best_item(type: String) -> ItemData:
	"""Retorna o melhor item de um tipo (maior level)"""
	var type_items = get_items_by_type(type)
	
	if type_items.is_empty():
		return null
	
	var best = type_items[0]
	for item in type_items:
		if item.item_level > best.item_level:
			best = item
	
	return best

func query_items(filters: Dictionary) -> Array:
	"""
	Busca itens por filtros múltiplos
	
	Filtros suportados:
	- type: String
	- side: String
	- min_level: int
	- max_level: int
	- has_metadata: String (chave)
	- metadata_value: {key: value}
	"""
	var result = []
	
	for item_data in items.values():
		if _matches_filters(item_data, filters):
			result.append(item_data)
	
	return result

func _matches_filters(item: ItemData, filters: Dictionary) -> bool:
	"""Verifica se item corresponde aos filtros"""
	
	if filters.has("type") and item.item_type != filters["type"]:
		return false
	
	if filters.has("side") and item.item_side != filters["side"]:
		return false
	
	if filters.has("min_level") and item.item_level < filters["min_level"]:
		return false
	
	if filters.has("max_level") and item.item_level > filters["max_level"]:
		return false
	
	if filters.has("has_metadata") and not item.has_metadata(filters["has_metadata"]):
		return false
	
	if filters.has("metadata_value"):
		var meta_filter = filters["metadata_value"]
		for key in meta_filter:
			if item.get_metadata(key) != meta_filter[key]:
				return false
	
	return true

func get_random_item(type: String = "") -> ItemData:
	"""Retorna um item aleatório (opcionalmente de um tipo)"""
	var pool = items.values() if type.is_empty() else get_items_by_type(type)
	
	if pool.is_empty():
		return null
	
	return pool[randi() % pool.size()]

func get_items_by_level_range(min_level: int, max_level: int) -> Array:
	"""Retorna itens dentro de uma faixa de levels"""
	return query_items({"min_level": min_level, "max_level": max_level})

# ===== EXPORTAÇÃO DE DADOS =====

func export_database() -> Dictionary:
	"""Exporta todos os dados para Dictionary"""
	var export_data = {}
	
	for item_name in items:
		export_data[item_name] = items[item_name].to_dictionary()
	
	return export_data

func export_item_data(item_name: String) -> Dictionary:
	"""Exporta dados de um item específico"""
	var item_data = get_item(item_name)
	return item_data.to_dictionary() if item_data else {}

func export_to_json(file_path: String = "") -> bool:
	"""Exporta database para arquivo JSON"""
	if file_path.is_empty():
		file_path = "res://data/items_export.json"
	
	var export_array = []
	
	for item_data in items.values():
		export_array.append(item_data.to_dictionary())
	
	var json_string = JSON.stringify(export_array, "\t")
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("Falha ao criar arquivo de exportação: %s" % file_path)
		return false
	
	file.store_string(json_string)
	file.close()
	
	_log_debug(" Database exportado para: %s" % file_path)
	return true

# ===== RELOAD / HOT-RELOAD =====

func reload_database() -> bool:
	"""Recarrega o database do JSON"""
	_log_debug("Recarregando database...")
	
	var old_count = items.size()
	var success = _load_json_data()
	
	if success:
		_log_debug(" Database recarregado: %d → %d itens" % [old_count, items.size()])
		
		# Recarrega cenas se estiver no cliente
		if preload_on_client:
			_preload_all_scenes()
	
	return success

# ===== ESTATÍSTICAS E DEBUG =====

func get_cache_stats() -> Dictionary:
	"""Retorna estatísticas de cache"""
	var total_requests = cache_hit_count + cache_miss_count
	var hit_rate = (float(cache_hit_count) / total_requests * 100.0) if total_requests > 0 else 0.0
	
	return {
		"cache_hits": cache_hit_count,
		"cache_misses": cache_miss_count,
		"hit_rate": hit_rate,
		"cached_scenes": _count_cached_scenes()
	}

func _count_cached_scenes() -> int:
	"""Conta quantas cenas estão em cache"""
	var count = 0
	for item in items.values():
		if item.cached_scene != null:
			count += 1
	return count

func print_item_info(item_name: String):
	"""Imprime informações detalhadas sobre um item"""
	var item_data = get_item(item_name)
	
	if item_data == null:
		print("❌ Item não encontrado: %s" % item_name)
		return
	
	print("\n╔═══ %s ═══╗" % item_name)
	print("  ID: %d" % item_data.id)
	print("  Tipo: %s" % item_data.item_type)
	print("  Lado: %s" % item_data.item_side)
	print("  Level: %d" % item_data.item_level)
	print("  Node Link: %s" % item_data.node_link)
	print("  Scene Path: %s" % item_data.scene_path)
	print("  Cached: %s" % ("" if item_data.cached_scene else "✗"))
	
	if not item_data.metadata.is_empty():
		print("  Metadata:")
		for key in item_data.metadata:
			print("    • %s: %s" % [key, item_data.metadata[key]])
	
	print("╚" + "═".repeat(item_name.length() + 8) + "╝\n")

func print_all_items():
	"""Lista todos os itens registrados"""
	print("\n╔════════════════════════════════════════╗")
	print("║       DATABASE DE ITENS                ║")
	print("╚════════════════════════════════════════╝")
	print("  Total: %d itens" % items.size())
	print("  Tipos: %d" % items_by_type.size())
	print("  Levels: %d diferentes" % items_by_level.size())
	
	for type in items_by_type:
		var type_items = items_by_type[type]
		print("\n  ┌─ [%s] - %d itens" % [type.to_upper(), type_items.size()])
		
		for item_data in type_items:
			var cached_mark = "📦" if item_data.cached_scene else "  "
			print("  │ %s Lv%d • %s (%s)" % [
				cached_mark,
				item_data.item_level,
				item_data.item_name,
				item_data.item_side
			])
	
	print("\n─────────────────────────────────────────")
	
	# Estatísticas de cache
	var cache_stats = get_cache_stats()
	print("  Cache: %d/%d (%.1f%% hit rate)" % [
		cache_stats["cached_scenes"],
		items.size(),
		cache_stats["hit_rate"]
	])
	print("─────────────────────────────────────────\n")

func print_database_stats():
	"""Imprime estatísticas completas"""
	print("\n╔════════════════════════════════════════╗")
	print("║    ESTATÍSTICAS DO DATABASE            ║")
	print("╚════════════════════════════════════════╝")
	print("  Total de itens: %d" % items.size())
	print("  Tempo de carga: %.3fs" % load_time)
	print("")
	print("  📊 Por tipo:")
	for type in items_by_type:
		print("    • %s: %d" % [type, items_by_type[type].size()])
	print("")
	print("  🎚️ Por level:")
	var sorted_levels = items_by_level.keys()
	sorted_levels.sort()
	for level in sorted_levels:
		print("    • Level %d: %d itens" % [level, items_by_level[level].size()])
	print("")
	
	var cache_stats = get_cache_stats()
	print("  💾 Cache:")
	print("    • Scenes cached: %d/%d" % [cache_stats["cached_scenes"], items.size()])
	print("    • Cache hits: %d" % cache_stats["cache_hits"])
	print("    • Cache misses: %d" % cache_stats["cache_misses"])
	print("    • Hit rate: %.1f%%" % cache_stats["hit_rate"])
	print("─────────────────────────────────────────\n")

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if _is_server else "[CLIENT]"
		print("%s[ItemDatabase] %s" % [prefix, message])
