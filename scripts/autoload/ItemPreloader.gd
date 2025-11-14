extends Node
## ItemDatabase - Sistema centralizado de gerenciamento de itens
## Unifica: JSON (metadados) + Paths (cenas) + Cache (preload)

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true
@export var json_path: String = "res://data/items.json"
@export var preload_on_client: bool = true

# ===== ESTRUTURA DE DADOS =====

## Classe interna para representar um item
class ItemData:
	var id: int
	var item_name: String
	var node_link: String
	var item_type: String  # hand, head, body
	var item_side: String  # left, right, up, down
	var item_level: int
	var scene_path: String  # path da cena
	var cached_scene: PackedScene  # cena pré-carregada (apenas clientes)
	
	func _init(json_data: Dictionary, scene_path_str: String):
		id = json_data.get("id", 0)
		item_name = json_data.get("item_name", "")
		node_link = json_data.get("node_link", "")
		item_type = json_data.get("item_type", "")
		item_side = json_data.get("item_side", "")
		item_level = int(json_data.get("item_level", "1"))
		scene_path = scene_path_str
		cached_scene = null
	
	func to_dictionary() -> Dictionary:
		return {
			"id": id,
			"item_name": item_name,
			"node_link": node_link,
			"item_type": item_type,
			"item_side": item_side,
			"item_level": item_level,
			"scene_path": scene_path
		}

# ===== DADOS =====

## Database principal: {item_name: ItemData}
var items: Dictionary = {}

## Índices para queries rápidas
var items_by_id: Dictionary = {}  # {id: ItemData}
var items_by_type: Dictionary = {}  # {type: [ItemData, ...]}
var items_by_level: Dictionary = {}  # {level: [ItemData, ...]}

## Paths das cenas (mantido por compatibilidade)
var item_paths: Dictionary = {
	"cape_1": "res://scenes/collectibles/cape_1.tscn",
	"cape_2": "res://scenes/collectibles/cape_2.tscn",
	"iron_helmet": "res://scenes/collectibles/iron_helmet.tscn",
	"shield_1": "res://scenes/collectibles/shield_1.tscn",
	"shield_2": "res://scenes/collectibles/shield_2.tscn",
	"shield_3": "res://scenes/collectibles/shield_3.tscn",
	"steel_helmet": "res://scenes/collectibles/steel_helmet.tscn",
	"sword_1": "res://scenes/collectibles/sword_1.tscn",
	"sword_2": "res://scenes/collectibles/sword_2.tscn",
	"torch": "res://scenes/collectibles/torch.tscn"
}

# ===== INICIALIZAÇÃO =====

func _ready():
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	# Carrega metadados do JSON
	_load_json_data()
	
	# Clientes fazem preload das cenas
	if not is_server and preload_on_client:
		_preload_all_scenes()
		_log_debug("✓ Cliente: %d itens carregados em cache" % items.size())
	else:
		_log_debug("✓ Servidor: %d itens carregados (sem cache)" % items.size())

# ===== CARREGAMENTO DE DADOS =====

## Carrega e processa o JSON de itens
func _load_json_data():
	var file = FileAccess.open(json_path, FileAccess.READ)
	
	if file == null:
		push_error("Falha ao abrir arquivo JSON: %s" % json_path)
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_text)
	
	if error != OK:
		push_error("Erro ao parsear JSON: %s" % json.get_error_message())
		return
	
	var json_data = json.data
	
	if not json_data is Array:
		push_error("JSON deve ser um array de itens")
		return
	
	# Processa cada item
	for item_dict in json_data:
		_register_item(item_dict)
	
	_log_debug("✓ %d itens carregados do JSON" % items.size())

## Registra um item no database
func _register_item(json_data: Dictionary):
	var item_name = json_data.get("item_name", "")
	
	if item_name.is_empty():
		push_warning("Item sem nome encontrado no JSON")
		return
	
	# Obtém path da cena
	var scene_path = item_paths.get(item_name, "")
	
	if scene_path.is_empty():
		push_warning("Path não encontrado para item: %s" % item_name)
		return
	
	# Cria ItemData
	var item_data = ItemData.new(json_data, scene_path)
	
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

## Pré-carrega todas as cenas (apenas clientes)
func _preload_all_scenes():
	var loaded_count = 0
	
	for item_name in items:
		var item_data: ItemData = items[item_name]
		var scene = load(item_data.scene_path)
		
		if scene:
			item_data.cached_scene = scene
			loaded_count += 1
		else:
			push_error("Falha ao carregar cena: %s" % item_data.scene_path)
	
	_log_debug("✓ %d/%d cenas pré-carregadas" % [loaded_count, items.size()])

# ===== API PÚBLICA - QUERIES =====

## Retorna dados completos de um item
func get_item(item_name: String) -> ItemData:
	return items.get(item_name, null)

## Retorna item por ID
func get_item_by_id(id: int) -> ItemData:
	return items_by_id.get(id, null)

## Retorna cena pré-carregada (ou carrega se necessário)
func get_item_scene(item_name: String) -> PackedScene:
	var item_data = get_item(item_name)
	
	if item_data == null:
		push_error("Item não encontrado: %s" % item_name)
		return null
	
	# Usa cache se disponível
	if item_data.cached_scene != null:
		return item_data.cached_scene
	
	# Carrega sob demanda (servidor)
	return load(item_data.scene_path)

## Retorna path da cena de um item
func get_item_path(item_name: String) -> String:
	var item_data = get_item(item_name)
	return item_data.scene_path if item_data else ""

## Retorna todos os itens de um tipo
func get_items_by_type(type: String) -> Array:
	return items_by_type.get(type, [])

## Retorna todos os itens de um level
func get_items_by_level(level: int) -> Array:
	return items_by_level.get(level, [])

## Retorna itens de um lado específico (left, right, up, down)
func get_items_by_side(side: String) -> Array:
	var result = []
	for item_data in items.values():
		if item_data.item_side == side:
			result.append(item_data)
	return result

## Retorna o node_link para equipar no jogador
func get_item_node_link(item_name: String) -> String:
	var item_data = get_item(item_name)
	return item_data.node_link if item_data else ""

## Verifica se um item existe
func item_exists(item_name: String) -> bool:
	return items.has(item_name)

## Retorna todos os nomes de itens
func get_all_item_names() -> Array:
	return items.keys()

## Retorna contagem total de itens
func get_item_count() -> int:
	return items.size()

# ===== API PÚBLICA - QUERIES AVANÇADAS =====

## Retorna itens que o jogador pode equipar em um slot específico
func get_equipable_items(slot_type: String, max_level: int = 999) -> Array:
	var result = []
	
	for item_data in items.values():
		if item_data.item_type == slot_type and item_data.item_level <= max_level:
			result.append(item_data)
	
	# Ordena por level
	result.sort_custom(func(a, b): return a.item_level < b.item_level)
	
	return result

## Retorna o melhor item de um tipo (maior level)
func get_best_item(type: String) -> ItemData:
	var type_items = get_items_by_type(type)
	
	if type_items.is_empty():
		return null
	
	var best = type_items[0]
	for item in type_items:
		if item.item_level > best.item_level:
			best = item
	
	return best

## Busca itens por filtros múltiplos
func query_items(filters: Dictionary) -> Array:
	var result = []
	
	for item_data in items.values():
		var match_all = true
		
		# Verifica cada filtro
		if filters.has("type") and item_data.item_type != filters["type"]:
			match_all = false
		
		if filters.has("side") and item_data.item_side != filters["side"]:
			match_all = false
		
		if filters.has("min_level") and item_data.item_level < filters["min_level"]:
			match_all = false
		
		if filters.has("max_level") and item_data.item_level > filters["max_level"]:
			match_all = false
		
		if match_all:
			result.append(item_data)
	
	return result

# ===== EXPORTAÇÃO DE DADOS =====

## Exporta todos os dados para Dictionary (útil para save/load)
func export_database() -> Dictionary:
	var export_data = {}
	
	for item_name in items:
		export_data[item_name] = items[item_name].to_dictionary()
	
	return export_data

## Exporta dados de um item específico
func export_item_data(item_name: String) -> Dictionary:
	var item_data = get_item(item_name)
	return item_data.to_dictionary() if item_data else {}

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[ItemDatabase] " + message)

# ===== DEBUG / DESENVOLVIMENTO =====

## Imprime informações sobre um item
func print_item_info(item_name: String):
	var item_data = get_item(item_name)
	
	if item_data == null:
		print("❌ Item não encontrado: %s" % item_name)
		return
	
	print("=== %s ===" % item_name)
	print("ID: %d" % item_data.id)
	print("Tipo: %s" % item_data.item_type)
	print("Lado: %s" % item_data.item_side)
	print("Level: %d" % item_data.item_level)
	print("Node: %s" % item_data.node_link)
	print("Path: %s" % item_data.scene_path)
	print("Cached: %s" % ("Sim" if item_data.cached_scene else "Não"))

## Lista todos os itens registrados
func print_all_items():
	print("\n=== DATABASE DE ITENS ===")
	print("Total: %d itens" % items.size())
	
	for type in items_by_type:
		var type_items = items_by_type[type]
		print("\n[%s] - %d itens:" % [type.to_upper(), type_items.size()])
		
		for item_data in type_items:
			print("  • %s (Lv%d) - %s" % [item_data.item_name, item_data.item_level, item_data.item_side])
