extends Node
class_name ItemDatabase
## ItemDatabase - Sistema de consulta e leitura de itens
## 
## Gerencia database de itens carregado do JSON.
## Fornece queries rápidas por ID, nome, categoria, tipo, owner, etc.
## 
## RESPONSABILIDADES:
## - Carregar dados de itens do JSON
## - Fornecer queries otimizadas através de índices
## - Validar existência e compatibilidade de itens
## - Fornecer informações de slots, equipabilidade, consumibilidade, craftabilidade

## ═══════════════════════════════════════════════════════════════════════════
## TUTORIAL BREVE: ADICIONAR/REMOVER CAMPOS DE ITENS
## 
## ✅ Para campos experimentais ou raros:
##    - Adicione diretamente no JSON.
##    - Acesse via item.get_metadata("chave", padrão).
##    - Não requer alteração de código.
##
## ✅ Para campos centrais ao gameplay:
##    1. Declare var novo_campo na classe ItemData.
##    2. Leia em _init(): novo_campo = json_data.get("novo_campo", valor_padrão)
##    3. Adicione "novo_campo" à lista known_fields (evita duplicar em metadata).
##    4. Inclua em to_dictionary().
##    5. (Opcional) Crie métodos de acesso específicos.
##
## 🗑️ Para remover campo:
##    - Se era em metadata: só remover do JSON.
##    - Se era nativo: remova variável, leitura, known_fields, to_dictionary e usos.
## ═══════════════════════════════════════════════════════════════════════════

# CONFIGURAÇÕES

@export_category("Database Settings")
## Caminho do arquivo JSON com registro de itens
@export var json_path: String = "res://scripts/utils/item_database_regs.json"
## Se true, carrega database automaticamente no _ready()
@export var auto_load_on_ready: bool = false

@export_category("Debug")
## Ativa logs detalhados de operações
@export var debug_mode: bool = true
@export var log_stats: bool = false

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var initializer: Initializer_ = null

# ===== VARIÁVEIS INTERNAS =====

## Detecta se está rodando como servidor dedicado
var is_server: bool = false

# CLASSE ITEMDATA

## Classe interna que representa um item do database
class ItemData:
	# ─── Identificação ───
	var id: int
	var name: String
	
	# ─── Cena e modelo ───
	var scene_path: String
	var model_node_link: String
	
	# ─── Categorização ───
	var owner: String
	var type: String
	var level: int
	var function: String
	var category: String
	var auto_equip: bool
	var rarity: String
	
	# ─── Sistema de stack ───
	var stackable: bool = false
	var max_stack: int = 1
	
	# ─── Atributos físicos ───
	var weight: float = 0.0
	var value: int = 0
	
	# ─── Atributos de combate ───
	var damage: int = 0
	var damage_type: String = ""
	var defense: int = 0
	var block_chance: float = 0.0
	
	# ─── Durabilidade ───
	var durability: Dictionary = {"max": 0, "current": 0}
	
	# ─── Sistema de craft ───
	var craftable: bool = false
	var craft_type: String = ""
	var craft_uses: Array = []
	var ingredients: Array = []
	
	# ─── Efeitos ───
	var effects: Variant = null  # Pode ser Dictionary ou Array
	
	# ─── Tempos de uso ───
	var use_time_seconds: float = 0.0
	var cooldown_seconds: float = 0.0
	
	# ─── Notas e metadata extra ───
	var notes: String = ""
	var metadata: Dictionary = {}
	
	## Construtor que inicializa ItemData a partir do JSON
	func _init(json_data: Dictionary):
		# Identificação
		id = json_data.get("id", 0)
		name = json_data.get("name", "")
		
		# Cena e modelo
		scene_path = json_data.get("scene_path", "")
		model_node_link = json_data.get("model_node_link", "")
		
		# Categorização
		owner = json_data.get("owner", "all")
		type = json_data.get("type", "")
		level = int(json_data.get("level", 1))
		function = json_data.get("function", "")
		category = json_data.get("category", "misc")
		auto_equip = json_data.get("auto_equip", true)
		rarity = json_data.get("rarity", "common")
		
		# Sistema de stack
		stackable = json_data.get("stackable", false)
		max_stack = int(json_data.get("max_stack", 1))
		
		# Atributos físicos
		weight = float(json_data.get("weight", 0.0))
		value = int(json_data.get("value", 0))
		
		# Atributos de combate
		damage = int(json_data.get("damage", 0))
		damage_type = json_data.get("damage_type", "")
		defense = int(json_data.get("defense", 0))
		block_chance = float(json_data.get("block_chance", 0.0))
		
		# Durabilidade
		durability = json_data.get("durability", {"max": 0, "current": 0}).duplicate()
		
		# Sistema de craft
		craftable = json_data.get("craftable", false)
		craft_type = json_data.get("craft_type", "")
		craft_uses = json_data.get("craft_uses", []).duplicate()
		ingredients = json_data.get("ingredients", []).duplicate()
		
		# Efeitos (pode ser Dict ou Array)
		effects = json_data.get("effects", null)
		if effects != null:
			if effects is Dictionary:
				effects = effects.duplicate()
			elif effects is Array:
				effects = effects.duplicate()
		
		# Tempos
		use_time_seconds = float(json_data.get("use_time_seconds", 0.0))
		cooldown_seconds = float(json_data.get("cooldown_seconds", 0.0))
		
		# Notas
		notes = json_data.get("notes", "")
		
		# Armazena campos extras em metadata
		var known_fields = [
			"id", "name", "scene_path", "model_node_link",
			"owner", "type", "level", "function", "category", "auto_equip", "rarity",
			"stackable", "max_stack", "weight", "value",
			"damage", "damage_type", "defense", "block_chance",
			"durability", "craftable", "craft_type", "craft_uses", "ingredients",
			"effects", "use_time_seconds", "cooldown_seconds", "notes"
		]
		
		for key in json_data:
			if key not in known_fields:
				metadata[key] = json_data[key]
	
	## Converte ItemData de volta para Dictionary
	func to_dictionary() -> Dictionary:
		var dict = {
			"id": id,
			"name": name,
			"scene_path": scene_path,
			"model_node_link": model_node_link,
			"owner": owner,
			"type": type,
			"level": level,
			"function": function,
			"category": category,
			"auto_equip": auto_equip,
			"rarity": rarity,
			"stackable": stackable,
			"max_stack": max_stack,
			"weight": weight,
			"value": value,
			"damage": damage,
			"damage_type": damage_type,
			"defense": defense,
			"block_chance": block_chance,
			"durability": durability.duplicate(),
			"craftable": craftable,
			"craft_type": craft_type,
			"craft_uses": craft_uses.duplicate(),
			"ingredients": ingredients.duplicate(),
			"use_time_seconds": use_time_seconds,
			"cooldown_seconds": cooldown_seconds,
			"notes": notes
		}
		
		# Adiciona effects se existir
		if effects != null:
			if effects is Dictionary:
				dict["effects"] = effects.duplicate()
			elif effects is Array:
				dict["effects"] = effects.duplicate()
		
		# Adiciona metadata extra
		for key in metadata:
			dict[key] = metadata[key]
		
		return dict
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE SLOT E EQUIPAMENTO
	# ───────────────────────────────────────────────────────────────────────
	
	## Retorna o slot de equipamento (type)
	func get_slot() -> String:
		return type
	
	## Verifica se é item de mão (hand-left ou hand-right)
	func is_hand_item() -> bool:
		return type in ["hand-left", "hand-right"]
	
	## Verifica se item pode ser equipado
	func is_equipable() -> bool:
		return type in ["head", "body", "hand-left", "hand-right", "back"]
	
	## Verifica se pode equipar neste slot específico
	func can_equip_in_slot(target_slot: String) -> bool:
		return type == target_slot
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE CATEGORIA E FUNÇÃO
	# ───────────────────────────────────────────────────────────────────────
	
	## Verifica se é arma
	func is_weapon() -> bool:
		return category == "weapon"
	
	## Verifica se é armadura
	func is_armor() -> bool:
		return category == "armor"
	
	## Verifica se é consumível
	func is_consumable() -> bool:
		return category == "consumable"
	
	## Verifica se é material
	func is_material() -> bool:
		return category == "material"
	
	## Verifica se é utilitário
	func is_utility() -> bool:
		return category == "utility"
	
	## Verifica se tem função de ataque
	func is_attack_function() -> bool:
		return function == "attack"
	
	## Verifica se tem função de defesa
	func is_defense_function() -> bool:
		return function == "defense"
	
	## Verifica se tem função de equipar automaticamente
	func is_auto_equip_function() -> bool:
		return auto_equip == true
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE STACK
	# ───────────────────────────────────────────────────────────────────────
	
	## Verifica se o item é empilhável
	func is_stackable() -> bool:
		return stackable
	
	## Retorna quantidade máxima de stack
	func get_max_stack() -> int:
		return max_stack
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE CRAFT
	# ───────────────────────────────────────────────────────────────────────
	
	## Verifica se o item pode ser craftado
	func is_craftable() -> bool:
		return craftable
	
	## Retorna array com ingredientes necessários
	func get_ingredients() -> Array:
		return ingredients.duplicate()
	
	## Verifica se tem ingredientes definidos
	func has_ingredients() -> bool:
		return not ingredients.is_empty()
	
	## Retorna craft_uses (em quais receitas pode ser usado)
	func get_craft_uses() -> Array:
		return craft_uses.duplicate()
	
	## Verifica se pode ser usado para craft
	func can_be_used_in_craft() -> bool:
		return not craft_uses.is_empty()
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE DURABILIDADE
	# ───────────────────────────────────────────────────────────────────────
	
	## Retorna durabilidade máxima
	func get_max_durability() -> int:
		return durability.get("max", 0)
	
	## Retorna durabilidade atual
	func get_current_durability() -> int:
		return durability.get("current", 0)
	
	## Verifica se tem durabilidade
	func has_durability() -> bool:
		return get_max_durability() > 0
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE COMBATE
	# ───────────────────────────────────────────────────────────────────────
	
	## Retorna dano do item
	func get_damage() -> int:
		return damage
	
	## Retorna tipo de dano
	func get_damage_type() -> String:
		return damage_type
	
	## Retorna defesa do item
	func get_defense() -> int:
		return defense
	
	## Retorna chance de bloquear
	func get_block_chance() -> float:
		return block_chance
	
	## Verifica se causa dano
	func deals_damage() -> bool:
		return damage > 0
	
	## Verifica se fornece defesa
	func provides_defense() -> bool:
		return defense > 0
	
	## Verifica se pode bloquear
	func can_block() -> bool:
		return block_chance > 0.0
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE EFEITOS
	# ───────────────────────────────────────────────────────────────────────
	
	## Verifica se tem efeitos
	func has_effects() -> bool:
		return effects != null
	
	## Retorna efeitos (pode ser Dict ou Array)
	func get_effects() -> Variant:
		if effects == null:
			return null
		if effects is Dictionary:
			return effects.duplicate()
		elif effects is Array:
			return effects.duplicate()
		return null
	
	## Pega valor de efeito específico (se effects for Dictionary)
	func get_effect_value(key: String, default = null):
		if effects is Dictionary:
			return effects.get(key, default)
		return default
	
	# ───────────────────────────────────────────────────────────────────────
	# FUNÇÕES DE METADATA
	# ───────────────────────────────────────────────────────────────────────
	
	## Retorna valor de metadata customizado
	func get_metadata(key: String, default = null):
		return metadata.get(key, default)
	
	## Verifica se tem metadata específico
	func has_metadata(key: String) -> bool:
		return metadata.has(key)

# ═══════════════════════════════════════════════════════════════════════════
# ESTRUTURA DE DADOS - DATABASES E ÍNDICES
# ═══════════════════════════════════════════════════════════════════════════

## Database principal: {item_name: ItemData}
var items: Dictionary = {}

## Índices para queries rápidas
var items_by_id: Dictionary = {}
var items_by_type: Dictionary = {}
var items_by_category: Dictionary = {}
var items_by_function: Dictionary = {}
var items_by_owner: Dictionary = {}
var items_by_rarity: Dictionary = {}
var items_by_level: Dictionary = {}
var items_by_craft_type: Dictionary = {}

## Arrays especializados para queries frequentes
var craftable_items: Array = []
var stackable_items: Array = []
var equipable_items: Array = []
var consumable_items: Array = []
var material_items: Array = []

## Estatísticas do database
var load_time: float = 0.0
var is_loaded: bool = false

# INICIALIZAÇÃO

func _ready():
	# Carrega database automaticamente se configurado
	if auto_load_on_ready:
		load_database()

## Carrega o database do arquivo JSON
func load_database() -> bool:
	# Detecta se é servidor
	var start_time = Time.get_ticks_msec()
	
	if not _load_json_data():
		push_error("[ItemDatabase] Falha ao carregar database!")
		return false
	
	load_time = (Time.get_ticks_msec() - start_time) / 1000.0
	is_loaded = true
	
	if log_stats:
		_log_stats()
	
	_log_debug("▶️ ItemDatabase inicializado com sucesso!")
	return true

## Recarrega o database (útil para hot-reload em desenvolvimento)
func reload_database() -> bool:
	_log_debug("Recarregando database...")
	_clear_database()
	return load_database()

# ═══════════════════════════════════════════════════════════════════════════
# CARREGAMENTO DE DADOS
# ═══════════════════════════════════════════════════════════════════════════

## Carrega e parseia o arquivo JSON
func _load_json_data() -> bool:
	_log_debug("✓ Registrando itens")
	
	# Verifica existência do arquivo
	if not FileAccess.file_exists(json_path):
		push_error("[ItemDatabase] Arquivo JSON não encontrado: %s" % json_path)
		return false
	
	# Abre o arquivo
	var file = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("[ItemDatabase] Falha ao abrir arquivo JSON: %s" % json_path)
		return false
	
	# Lê conteúdo
	var json_text = file.get_as_text()
	file.close()
	
	if json_text.is_empty():
		push_error("[ItemDatabase] Arquivo JSON está vazio")
		return false
	
	# Parseia JSON
	var json = JSON.new()
	var error = json.parse(json_text)
	
	if error != OK:
		push_error("[ItemDatabase] Erro ao parsear JSON linha %d: %s" % [json.get_error_line(), json.get_error_message()])
		return false
	
	var json_data = json.data
	
	# Valida estrutura
	if not json_data is Array:
		push_error("[ItemDatabase] JSON deve ser um array de itens")
		return false
	
	# Limpa database existente
	_clear_database()
	
	# Registra todos os itens
	var loaded_count = 0
	for item_dict in json_data:
		if _register_item(item_dict):
			loaded_count += 1
	
	_log_debug("✓ Registrados %d/%d itens" % [loaded_count, json_data.size()])
	
	return loaded_count > 0

## Limpa todos os dados do database
func _clear_database():
	items.clear()
	items_by_id.clear()
	items_by_type.clear()
	items_by_category.clear()
	items_by_function.clear()
	items_by_owner.clear()
	items_by_rarity.clear()
	items_by_level.clear()
	items_by_craft_type.clear()
	craftable_items.clear()
	stackable_items.clear()
	equipable_items.clear()
	consumable_items.clear()
	material_items.clear()
	is_loaded = false

## Registra um item no database e em todos os índices
func _register_item(json_data: Dictionary) -> bool:
	# Validação básica
	if not json_data.has("name") or json_data["name"].is_empty():
		push_warning("[ItemDatabase] Item sem 'name' - ignorado")
		return false
	
	if not json_data.has("scene_path") or json_data["scene_path"].is_empty():
		push_warning("[ItemDatabase] Item '%s' sem 'scene_path' - ignorado" % json_data["name"])
		return false
	
	var item_name = json_data["name"]
	
	# Verifica duplicatas
	if items.has(item_name):
		push_warning("[ItemDatabase] Item duplicado ignorado: %s" % item_name)
		return false
	
	# Cria ItemData
	var item_data = ItemData.new(json_data)
	
	# Registra no database principal
	items[item_name] = item_data
	items_by_id[item_data.id] = item_data
	
	# ─── Índice por type ───
	if not item_data.type.is_empty():
		if not items_by_type.has(item_data.type):
			items_by_type[item_data.type] = []
		items_by_type[item_data.type].append(item_data)
	
	# ─── Índice por category ───
	if not items_by_category.has(item_data.category):
		items_by_category[item_data.category] = []
	items_by_category[item_data.category].append(item_data)
	
	# ─── Índice por function ───
	if not item_data.function.is_empty():
		if not items_by_function.has(item_data.function):
			items_by_function[item_data.function] = []
		items_by_function[item_data.function].append(item_data)
	
	# ─── Índice por owner ───
	if not items_by_owner.has(item_data.owner):
		items_by_owner[item_data.owner] = []
	items_by_owner[item_data.owner].append(item_data)
	
	# ─── Índice por rarity ───
	if not items_by_rarity.has(item_data.rarity):
		items_by_rarity[item_data.rarity] = []
	items_by_rarity[item_data.rarity].append(item_data)
	
	# ─── Índice por level ───
	if not items_by_level.has(item_data.level):
		items_by_level[item_data.level] = []
	items_by_level[item_data.level].append(item_data)
	
	# ─── Índice por craft_type ───
	if not item_data.craft_type.is_empty():
		if not items_by_craft_type.has(item_data.craft_type):
			items_by_craft_type[item_data.craft_type] = []
		items_by_craft_type[item_data.craft_type].append(item_data)
	
	# ─── Arrays especializados ───
	if item_data.is_craftable():
		craftable_items.append(item_data)
	
	if item_data.is_stackable():
		stackable_items.append(item_data)
	
	if item_data.is_equipable():
		equipable_items.append(item_data)
	
	if item_data.is_consumable():
		consumable_items.append(item_data)
	
	if item_data.is_material():
		material_items.append(item_data)
	
	return true

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - QUERIES BÁSICAS
# ═══════════════════════════════════════════════════════════════════════════

## Retorna ItemData pelo nome
func get_item(item_name: String) -> ItemData:
	return items.get(item_name, null)

## Retorna ItemData pelo ID
func get_item_by_id(id: int) -> ItemData:
	return items_by_id.get(id, null)

## Verifica se item existe no database
func item_exists(item_name: String) -> bool:
	return items.has(item_name)

## Verifica se item existe no database
func item_exists_by_id(item_id: int) -> bool:
	var item_name = get_item_by_id(item_id)["name"]
	return items.has(item_name)

## Retorna array com nomes de todos os itens
func get_all_item_names() -> Array:
	return items.keys()

## Retorna array com todos os ItemData
func get_all_items() -> Array:
	return items.values()

## Retorna quantidade total de itens registrados
func get_item_count() -> int:
	return items.size()

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - INFORMAÇÕES BÁSICAS DE ITEM
# ═══════════════════════════════════════════════════════════════════════════

## Retorna caminho da cena do item
func get_scene_path(item_name: String) -> String:
	var item = get_item(item_name)
	return item.scene_path if item else ""

## Retorna link do modelo 3D do item
func get_model_node_link(item_name: String) -> String:
	var item = get_item(item_name)
	return item.model_node_link if item else ""

## Retorna owner do item (knight, archer, all, etc)
func get_item_owner(item_name: String) -> String:
	var item = get_item(item_name)
	return item.owner if item else ""

## Retorna tipo do item (head, hand-left, material, etc)
func get_type(item_name: String) -> String:
	var item = get_item(item_name)
	return item.type if item else ""

## Retorna level do item
func get_level(item_name: String) -> int:
	var item = get_item(item_name)
	return item.level if item else 0

## Retorna função do item (attack, defense, food, etc)
func get_function(item_name: String) -> String:
	var item = get_item(item_name)
	return item.function if item else ""

## Retorna categoria do item (weapon, armor, consumable, etc)
func get_category(item_name: String) -> String:
	var item = get_item(item_name)
	return item.category if item else ""

## Retorna raridade do item (common, uncommon, rare, etc)
func get_rarity(item_name: String) -> String:
	var item = get_item(item_name)
	return item.rarity if item else ""

## Retorna peso do item
func get_weight(item_name: String) -> float:
	var item = get_item(item_name)
	return item.weight if item else 0.0

## Retorna valor monetário do item
func get_value(item_name: String) -> int:
	var item = get_item(item_name)
	return item.value if item else 0

## Retorna notas do item
func get_notes(item_name: String) -> String:
	var item = get_item(item_name)
	return item.notes if item else ""

## Retorna todas as informações do item como Dictionary
func get_item_full_info(item_name: String) -> Dictionary:
	var item = get_item(item_name)
	return item.to_dictionary() if item else {}

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - SLOTS E EQUIPAMENTO
# ═══════════════════════════════════════════════════════════════════════════

## Retorna o slot do item (mesmo que type)
func get_slot(item_name: String) -> String:
	var item = get_item(item_name)
	return item.get_slot() if item else ""

## Verifica se item pode ser equipado
func is_equipable(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.is_equipable() if item else false

## Verifica se é item de mão (hand-left ou hand-right)
func is_hand_item(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.is_hand_item() if item else false

## Verifica se item pode ser equipado em slot específico
func can_equip_in_slot(item_name: String, slot: String) -> bool:
	var item = get_item(item_name)
	return item.can_equip_in_slot(slot) if item else false

## Retorna lista de slots válidos para equipamento
func get_valid_slots() -> Array:
	return ["head", "body", "hand-left", "hand-right", "back"]

## Verifica se slot é válido
func is_valid_slot(slot: String) -> bool:
	return slot in get_valid_slots()

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - COMBATE
# ═══════════════════════════════════════════════════════════════════════════

## Retorna dano do item
func get_damage(item_name: String) -> int:
	var item = get_item(item_name)
	return item.get_damage() if item else 0

## Retorna tipo de dano
func get_damage_type(item_name: String) -> String:
	var item = get_item(item_name)
	return item.get_damage_type() if item else ""

## Retorna defesa do item
func get_defense(item_name: String) -> int:
	var item = get_item(item_name)
	return item.get_defense() if item else 0

## Retorna chance de bloqueio
func get_block_chance(item_name: String) -> float:
	var item = get_item(item_name)
	return item.get_block_chance() if item else 0.0

## Verifica se item causa dano
func deals_damage(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.deals_damage() if item else false

## Verifica se item fornece defesa
func provides_defense(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.provides_defense() if item else false

## Verifica se item pode bloquear
func can_block(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.can_block() if item else false

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - DURABILIDADE
# ═══════════════════════════════════════════════════════════════════════════

## Retorna durabilidade máxima
func get_max_durability(item_name: String) -> int:
	var item = get_item(item_name)
	return item.get_max_durability() if item else 0

## Retorna durabilidade atual (do registro, não da instância)
func get_current_durability(item_name: String) -> int:
	var item = get_item(item_name)
	return item.get_current_durability() if item else 0

## Verifica se item tem durabilidade
func has_durability(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.has_durability() if item else false

## Retorna dicionário completo de durabilidade
func get_durability_info(item_name: String) -> Dictionary:
	var item = get_item(item_name)
	return item.durability.duplicate() if item else {}

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - STACK
# ═══════════════════════════════════════════════════════════════════════════

## Verifica se item é empilhável
func is_stackable(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.is_stackable() if item else false

## Retorna quantidade máxima de stack
func get_max_stack(item_name: String) -> int:
	var item = get_item(item_name)
	return item.get_max_stack() if item else 1

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - CRAFT
# ═══════════════════════════════════════════════════════════════════════════

## Verifica se item pode ser craftado
func is_craftable(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.is_craftable() if item else false

## Retorna tipo de craft
func get_craft_type(item_name: String) -> String:
	var item = get_item(item_name)
	return item.craft_type if item else ""

## Retorna ingredientes necessários para craftar o item
func get_ingredients(item_name: String) -> Array:
	var item = get_item(item_name)
	return item.get_ingredients() if item else []

## Verifica se item tem ingredientes definidos
func has_ingredients(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.has_ingredients() if item else false

## Retorna craft_uses (receitas onde pode ser usado)
func get_craft_uses(item_name: String) -> Array:
	var item = get_item(item_name)
	return item.get_craft_uses() if item else []

## Verifica se item pode ser usado em crafting
func can_be_used_in_craft(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.can_be_used_in_craft() if item else false

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - EFEITOS
# ═══════════════════════════════════════════════════════════════════════════

## Verifica se item tem efeitos
func has_effects(item_name: String) -> bool:
	var item = get_item(item_name)
	return item.has_effects() if item else false

## Retorna efeitos do item (pode ser Dictionary ou Array)
func get_effects(item_name: String) -> Variant:
	var item = get_item(item_name)
	return item.get_effects() if item else null

## Retorna valor de efeito específico (se effects for Dictionary)
func get_effect_value(item_name: String, key: String, default = null):
	var item = get_item(item_name)
	return item.get_effect_value(key, default) if item else default

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - TEMPOS
# ═══════════════════════════════════════════════════════════════════════════

## Retorna tempo de uso em segundos
func get_use_time(item_name: String) -> float:
	var item = get_item(item_name)
	return item.use_time_seconds if item else 0.0

## Retorna tempo de cooldown em segundos
func get_cooldown(item_name: String) -> float:
	var item = get_item(item_name)
	return item.cooldown_seconds if item else 0.0

## Verifica se item tem cooldown
func has_cooldown(item_name: String) -> bool:
	return get_cooldown(item_name) > 0.0

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - QUERIES POR ÍNDICE
# ═══════════════════════════════════════════════════════════════════════════

## Retorna todos os itens de um type
func get_items_by_type(type: String) -> Array:
	return items_by_type.get(type, []).duplicate()

## Retorna todos os itens de uma categoria
func get_items_by_category(category: String) -> Array:
	return items_by_category.get(category, []).duplicate()

## Retorna todos os itens de uma função
func get_items_by_function(function_name: String) -> Array:
	return items_by_function.get(function_name, []).duplicate()

## Retorna todos os itens de um owner
func get_items_by_owner(owner_: String) -> Array:
	return items_by_owner.get(owner_, []).duplicate()

## Retorna todos os itens de uma raridade
func get_items_by_rarity(rarity: String) -> Array:
	return items_by_rarity.get(rarity, []).duplicate()

## Retorna todos os itens de um level
func get_items_by_level(level: int) -> Array:
	return items_by_level.get(level, []).duplicate()

## Retorna todos os itens de um craft_type
func get_items_by_craft_type(craft_type: String) -> Array:
	return items_by_craft_type.get(craft_type, []).duplicate()

## Retorna todos os itens craftáveis
func get_craftable_items() -> Array:
	return craftable_items.duplicate()

## Retorna todos os itens empilháveis
func get_stackable_items() -> Array:
	return stackable_items.duplicate()

## Retorna todos os itens equipáveis
func get_equipable_items() -> Array:
	return equipable_items.duplicate()

## Retorna todos os itens consumíveis
func get_consumable_items() -> Array:
	return consumable_items.duplicate()

## Retorna todos os materiais
func get_material_items() -> Array:
	return material_items.duplicate()

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - QUERIES ESPECIALIZADAS
# ═══════════════════════════════════════════════════════════════════════════

## Retorna todos os itens de mão (left + right)
func get_hand_items() -> Array:
	var left = get_items_by_type("hand-left")
	var right = get_items_by_type("hand-right")
	return left + right

## Retorna todos os itens de armadura (head + body + back)
func get_armor_items() -> Array:
	var head = get_items_by_type("head")
	var body = get_items_by_type("body")
	var back = get_items_by_type("back")
	return head + body + back

## Retorna todas as armas
func get_weapons() -> Array:
	return get_items_by_category("weapon")

## Retorna todas as armaduras
func get_armors() -> Array:
	return get_items_by_category("armor")

## Retorna todos os utilitários
func get_utilities() -> Array:
	return get_items_by_category("utility")

## Retorna todos os materiais
func get_materials() -> Array:
	return get_items_by_category("material")

## Retorna todos os consumíveis
func get_consumables() -> Array:
	return get_items_by_category("consumable")

## Retorna itens com função de ataque
func get_attack_items() -> Array:
	return get_items_by_function("attack")

## Retorna itens com função de defesa
func get_defense_items() -> Array:
	return get_items_by_function("defense")

## Retorna itens com função de comida
func get_food_items() -> Array:
	return get_items_by_function("food")

## Retorna itens que podem ser usados como ingredientes
func get_crafting_ingredients() -> Array:
	var ingredients = []
	for item in items.values():
		if item.can_be_used_in_craft():
			ingredients.append(item)
	return ingredients

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - QUERIES AVANÇADAS
# ═══════════════════════════════════════════════════════════════════════════

## Busca itens por múltiplos filtros
## Filtros disponíveis:
## - type: String
## - category: String
## - function: String
## - owner: String
## - rarity: String
## - level: int
## - min_level: int
## - max_level: int
## - equipable: bool
## - stackable: bool
## - craftable: bool
## - consumable: bool
## - material: bool
## - min_damage: int
## - max_damage: int
## - min_defense: int
## - max_defense: int
## - min_weight: float
## - max_weight: float
## - min_value: int
## - max_value: int
## - has_durability: bool
## - has_effects: bool
func query_items(filters: Dictionary) -> Array:
	var result = []
	
	for item_data in items.values():
		if _matches_filters(item_data, filters):
			result.append(item_data)
	
	return result

## Verifica se ItemData corresponde aos filtros
func _matches_filters(item: ItemData, filters: Dictionary) -> bool:
	# Filtro de type
	if filters.has("type") and item.type != filters["type"]:
		return false
	
	# Filtro de category
	if filters.has("category") and item.category != filters["category"]:
		return false
	
	# Filtro de function
	if filters.has("function") and item.function != filters["function"]:
		return false
	
	# Filtro de owner
	if filters.has("owner") and item.owner != filters["owner"]:
		return false
	
	# Filtro de rarity
	if filters.has("rarity") and item.rarity != filters["rarity"]:
		return false
	
	# Filtro de level exato
	if filters.has("level") and item.level != filters["level"]:
		return false
	
	# Filtro de level mínimo
	if filters.has("min_level") and item.level < filters["min_level"]:
		return false
	
	# Filtro de level máximo
	if filters.has("max_level") and item.level > filters["max_level"]:
		return false
	
	# Filtro de equipable
	if filters.has("equipable") and item.is_equipable() != filters["equipable"]:
		return false
	
	# Filtro de stackable
	if filters.has("stackable") and item.is_stackable() != filters["stackable"]:
		return false
	
	# Filtro de craftable
	if filters.has("craftable") and item.is_craftable() != filters["craftable"]:
		return false
	
	# Filtro de consumable
	if filters.has("consumable") and item.is_consumable() != filters["consumable"]:
		return false
	
	# Filtro de material
	if filters.has("material") and item.is_material() != filters["material"]:
		return false
	
	# Filtro de dano mínimo
	if filters.has("min_damage") and item.damage < filters["min_damage"]:
		return false
	
	# Filtro de dano máximo
	if filters.has("max_damage") and item.damage > filters["max_damage"]:
		return false
	
	# Filtro de defesa mínima
	if filters.has("min_defense") and item.defense < filters["min_defense"]:
		return false
	
	# Filtro de defesa máxima
	if filters.has("max_defense") and item.defense > filters["max_defense"]:
		return false
	
	# Filtro de peso mínimo
	if filters.has("min_weight") and item.weight < filters["min_weight"]:
		return false
	
	# Filtro de peso máximo
	if filters.has("max_weight") and item.weight > filters["max_weight"]:
		return false
	
	# Filtro de valor mínimo
	if filters.has("min_value") and item.value < filters["min_value"]:
		return false
	
	# Filtro de valor máximo
	if filters.has("max_value") and item.value > filters["max_value"]:
		return false
	
	# Filtro de durabilidade
	if filters.has("has_durability") and item.has_durability() != filters["has_durability"]:
		return false
	
	# Filtro de efeitos
	if filters.has("has_effects") and item.has_effects() != filters["has_effects"]:
		return false
	
	return true

## Retorna item aleatório (opcionalmente filtrado)
func get_random_item(filters: Dictionary = {}) -> ItemData:
	var pool = query_items(filters) if not filters.is_empty() else items.values()
	
	if pool.is_empty():
		return null
	
	return pool[randi() % pool.size()]

## Retorna nome de item aleatório
func get_random_item_name(filters: Dictionary = {}) -> String:
	var item = get_random_item(filters)
	return item.name if item else ""

# ═══════════════════════════════════════════════════════════════════════════
# API PÚBLICA - FUNÇÕES DE FACILITAÇÃO
# ═══════════════════════════════════════════════════════════════════════════

## Retorna todos os itens que podem ser equipados em um slot
func get_items_for_slot(slot: String) -> Array:
	return get_items_by_type(slot)

## Retorna lista de todos os types disponíveis
func get_available_types() -> Array:
	return items_by_type.keys()

## Retorna lista de todas as categorias disponíveis
func get_available_categories() -> Array:
	return items_by_category.keys()

## Retorna lista de todas as funções disponíveis
func get_available_functions() -> Array:
	return items_by_function.keys()

## Retorna lista de todos os owners disponíveis
func get_available_owners() -> Array:
	return items_by_owner.keys()

## Retorna lista de todas as raridades disponíveis
func get_available_rarities() -> Array:
	return items_by_rarity.keys()

## Retorna lista de todos os levels disponíveis
func get_available_levels() -> Array:
	return items_by_level.keys()

## Retorna lista de todos os craft_types disponíveis
func get_available_craft_types() -> Array:
	return items_by_craft_type.keys()

## Valida uma lista de nomes de itens
## Retorna: {valid: Array, invalid: Array}
func validate_item_list(item_names: Array) -> Dictionary:
	var valid = []
	var invalid = []
	
	for item_name in item_names:
		if item_exists(item_name):
			valid.append(item_name)
		else:
			invalid.append(item_name)
	
	return {"valid": valid, "invalid": invalid}

## Compara dois itens
## Retorna diferenças em stats, category, type, etc
func compare_items(item1_name: String, item2_name: String) -> Dictionary:
	var item1 = get_item(item1_name)
	var item2 = get_item(item2_name)
	
	if not item1 or not item2:
		return {}
	
	return {
		"level_diff": item2.level - item1.level,
		"same_type": item1.type == item2.type,
		"same_category": item1.category == item2.category,
		"same_function": item1.function == item2.function,
		"same_owner": item1.owner == item2.owner,
		"same_rarity": item1.rarity == item2.rarity,
		"damage_diff": item2.damage - item1.damage,
		"defense_diff": item2.defense - item1.defense,
		"weight_diff": item2.weight - item1.weight,
		"value_diff": item2.value - item1.value,
		"both_equipable": item1.is_equipable() and item2.is_equipable(),
		"both_stackable": item1.is_stackable() and item2.is_stackable(),
		"both_craftable": item1.is_craftable() and item2.is_craftable(),
		"both_consumable": item1.is_consumable() and item2.is_consumable()
	}

## Busca item por ingrediente necessário
func find_recipes_requiring_ingredient(ingredient_name: String) -> Array:
	var recipes = []
	
	for item in items.values():
		if not item.is_craftable():
			continue
		
		for ingredient in item.ingredients:
			if ingredient is Dictionary and ingredient.get("item", "") == ingredient_name:
				recipes.append(item)
				break
	
	return recipes

## Busca itens que podem ser craftados com determinados materiais
func find_craftable_with_materials(material_names: Array) -> Array:
	var craftable = []
	
	for item in craftable_items:
		var has_all = true
		for ingredient in item.ingredients:
			if ingredient is Dictionary:
				var ing_name = ingredient.get("item", "")
				if ing_name not in material_names:
					has_all = false
					break
		
		if has_all and not item.ingredients.is_empty():
			craftable.append(item)
	
	return craftable

# ═══════════════════════════════════════════════════════════════════════════
# DEBUG E LOGGING
# ═══════════════════════════════════════════════════════════════════════════

## Imprime informações completas de um item
func print_item_info(item_name: String):
	var item = get_item(item_name)
	if item == null:
		print("❌ Item não encontrado: %s" % item_name)
		return
	
	print("\n╔═══ %s (ID: %d) ═══╗" % [item.name, item.id])
	print("  Categoria: %s | Tipo: %s | Função: %s" % [item.category, item.type, item.function])
	print("  Owner: %s | Level: %d | Raridade: %s" % [item.owner, item.level, item.rarity])
	print("  Peso: %.1fkg | Valor: %d gold" % [item.weight, item.value])
	
	if item.is_equipable():
		print("  ⚔️ Equipável no slot: %s" % item.type)
	
	if item.damage > 0:
		print("  ⚔️ Dano: %d (%s)" % [item.damage, item.damage_type])
	
	if item.defense > 0:
		print("  🛡️ Defesa: %d" % item.defense)
	
	if item.block_chance > 0:
		print("  🛡️ Chance de Bloqueio: %.1f%%" % (item.block_chance * 100))
	
	if item.has_durability():
		print("  🔧 Durabilidade: %d/%d" % [item.get_current_durability(), item.get_max_durability()])
	
	if item.is_stackable():
		print("  📦 Empilhável: Máx %d" % item.max_stack)
	
	if item.has_effects():
		print("  ✨ Efeitos: %s" % str(item.effects))
	
	if item.use_time_seconds > 0:
		print("  ⏱️ Tempo de Uso: %.1fs" % item.use_time_seconds)
	
	if item.cooldown_seconds > 0:
		print("  ⏱️ Cooldown: %.1fs" % item.cooldown_seconds)
	
	if item.is_craftable():
		print("  🔨 Craftável (%s)" % item.craft_type)
		if item.has_ingredients():
			print("    Ingredientes:")
			for ing in item.ingredients:
				if ing is Dictionary:
					print("      - %s x%d" % [ing.get("item", "?"), ing.get("qty", 1)])
	
	if item.can_be_used_in_craft():
		print("  🔧 Usado em: %s" % ", ".join(item.craft_uses))
	
	if not item.notes.is_empty():
		print("  📝 Notas: %s" % item.notes)
	
	print("  📁 Cena: %s" % item.scene_path)
	print("  🔗 Modelo: %s" % item.model_node_link)
	
	if not item.metadata.is_empty():
		print("  📋 Metadata: %s" % str(item.metadata))
	
	print("╚" + "═".repeat(item.name.length() + 16) + "╝\n")

## Log de estatísticas após carregamento
func _log_stats():
	if not debug_mode:
		return
	
	_log_debug("─── Estatísticas ───")
	_log_debug("  Categorias: %s" % ", ".join(get_available_categories()))
	_log_debug("  Types: %s" % ", ".join(get_available_types()))
	_log_debug("  Raridades: %s" % ", ".join(get_available_rarities()))
	_log_debug("  Equipáveis: %d | Craftáveis: %d | Consumíveis: %d | Materiais: %d" % [
		equipable_items.size(),
		craftable_items.size(),
		consumable_items.size(),
		material_items.size()
	])

## Log interno com suporte a servidor/cliente
func _log_debug(message: String):
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "ItemDatabase" in initializer.selected:
		return
	
	var prefix = "[SERVER]" if is_server else "[CLIENT]"
	print("%s[ItemDatabase] %s" % [prefix, message])
	
