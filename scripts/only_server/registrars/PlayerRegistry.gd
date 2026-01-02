extends Node
class_name PlayerRegistry
## PlayerRegistry - Registro centralizado de jogadores (SERVIDOR APENAS)
## Gerencia informações de todos os jogadores conectados + Inventário por Rodada
## 
## RESPONSABILIDADES:
## - Adicionar/remover peers conectados
## - Registrar nomes de jogadores
## - Gerenciar inventários por rodada
## - Rastrear em qual sala/rodada cada jogador está
## - Fornecer queries de localização de jogadores

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true
@export var max_inventory_slots: int = 9 # Limite de itens por jogador

# ===== REGISTROS (Injetados pelo ServerManager) =====

var room_registry: RoomRegistry = null  # Injetado
var round_registry: RoundRegistry = null  # Injetado
var object_manager: ObjectManager = null  # Injetado
var item_database: ItemDatabase = null  # Referência ao ItemDatabase

# ===== VARIÁVEIS INTERNAS =====

## Dados completos dos jogadores: {peer_id: PlayerData}
var players: Dictionary = {}

## Cache de NodePath para acesso rápido: {peer_id: NodePath_string}
var players_cache: Dictionary = {}

## Inventários organizados por rodada: {round_id: {player_id: InventoryData}}
var player_inventories: Dictionary = {}

# Estado de inicialização
var _initialized: bool = false

# ===== SINAIS =====

# --- Sinais de Conexão ---
signal peer_added(peer_id: int)
signal peer_removed(peer_id: int)
signal player_registered(peer_id: int, player_name: String)

# --- Sinais de Localização ---
signal player_joined_room(peer_id: int, room_id: int)
signal player_left_room(peer_id: int, room_id: int)
signal player_joined_round(peer_id: int, round_id: int)
signal player_left_round(peer_id: int, round_id: int)

# --- Sinais de Inventário ---
#signal item_added_to_inventory(round_id: int, player_id: int, item_name: String)
#signal item_removed_from_inventory(round_id: int, player_id: int, item_name: String)
#signal item_equipped(round_id: int, player_id: int, item_name: String, slot: String)
#signal item_unequipped(round_id: int, player_id: int, item_name: String, slot: String)
#signal inventory_full(round_id: int, player_id: int)
#signal item_swapped(round_id: int, player_id: int, old_item: String, new_item: String, slot: String)

# ===== ESTRUTURAS DE DADOS =====

## PlayerData:
## {
##   "id": int,
##   "name": String,
##   "registered": bool,
##   "connected_at": float,
##   "room_id": int (-1 se não estiver em sala),
##   "round_id": int (-1 se não estiver em rodada),
##   "node_path": String
## }

## InventoryData:
## {
##   "inventory": Array[Dictionary],  # Lista de {item_id: String, object_id: int}
##   "equipped": {                     # Itens equipados por slot
##     "hand-right": Dictionary,       # {item_name: String, item_id: String, object_id: int}
##     "hand-left": Dictionary,
##     "head": Dictionary,
##     "body": Dictionary,
##     "back": Dictionary
##   }
## }

# ===== INICIALIZAÇÃO =====

func initialize():
	"""Inicializa o PlayerRegistry (chamado apenas no servidor)"""
	if _initialized:
		_log_debug("⚠ PlayerRegistry já inicializado")
		return
	
	_initialized = true
	_log_debug("✓ PlayerRegistry inicializado")

func reset():
	"""Reseta completamente o registro (usado ao desligar servidor)"""
	players.clear()
	players_cache.clear()
	player_inventories.clear()
	_initialized = false
	_log_debug("🔄 PlayerRegistry resetado")

# ===== GERENCIAMENTO DE PEERS =====

func add_peer(peer_id: int):
	"""Adiciona um novo peer conectado (ainda não registrado)"""
	if players.has(peer_id):
		_log_debug("⚠ Peer %d já existe" % peer_id)
		return
	
	players[peer_id] = {
		"id": peer_id,
		"name": "",
		"registered": false,
		"connected_at": Time.get_unix_time_from_system(),
		"room_id": -1,
		"round_id": -1,
		"node_path": ""
	}
	
	_log_debug("✓ Peer adicionado: %d" % peer_id)
	peer_added.emit(peer_id)

func remove_peer(peer_id: int):
	"""Remove um peer desconectado"""
	if not players.has(peer_id):
		_log_debug("⚠ Tentou remover peer inexistente: %d" % peer_id)
		return
	
	var player = players[peer_id]
	var player_name = player["name"] if player["name"] else "sem_nome"
	
	if player["room_id"] != -1:
		_leave_room_internal(peer_id)
	
	_cleanup_player_inventories(peer_id)
	
	players.erase(peer_id)
	players_cache.erase(peer_id)
	
	_log_debug("✓ Peer removido: %d (%s)" % [peer_id, player_name])
	peer_removed.emit(peer_id)

func register_player(peer_id: int, player_name: String) -> bool:
	"""Registra nome do jogador"""
	if not players.has(peer_id):
		_log_debug("❌ Tentou registrar jogador inexistente: %d" % peer_id)
		return false
	
	if is_name_taken(player_name):
		_log_debug("❌ Nome já em uso: %s" % player_name)
		return false
	
	players[peer_id]["name"] = player_name
	players[peer_id]["registered"] = true
	
	_log_debug("✓ Jogador registrado: %s (ID: %d)" % [player_name, peer_id])
	player_registered.emit(peer_id, player_name)
	return true

func is_name_taken(player_name: String) -> bool:
	"""Verifica se um nome já está em uso"""
	var normalized_name = player_name.strip_edges().to_lower()
	for player in players.values():
		if player.has("name") and player["name"].strip_edges().to_lower() == normalized_name:
			return true
	return false

# ===== GERENCIAMENTO DE SALAS/RODADAS =====

func join_room(peer_id: int, room_id: int):
	"""Marca jogador como dentro de uma sala"""
	if not players.has(peer_id):
		push_error("PlayerRegistry: Tentou marcar player %d em sala, mas não existe" % peer_id)
		return
	
	var player = players[peer_id]
	
	if player["room_id"] != -1 and player["room_id"] != room_id:
		_leave_room_internal(peer_id)
	
	player["room_id"] = room_id
	_log_debug("✓ Player %d entrou na sala %d" % [peer_id, room_id])
	player_joined_room.emit(peer_id, room_id)

func leave_room(peer_id: int):
	"""Remove jogador da sala atual"""
	_leave_room_internal(peer_id)

func _leave_room_internal(peer_id: int):
	if not players.has(peer_id):
		return
	
	var player = players[peer_id]
	var old_room_id = player["room_id"]
	
	if old_room_id == -1:
		return
	
	if player["round_id"] != -1:
		_leave_round_internal(peer_id)
	
	player["room_id"] = -1
	_log_debug("✓ Player %d saiu da sala %d" % [peer_id, old_room_id])
	player_left_room.emit(peer_id, old_room_id)

func join_round(peer_id: int, round_id: int):
	"""Marca jogador como dentro de uma rodada e inicializa inventário"""
	if not players.has(peer_id):
		push_error("PlayerRegistry: Tentou marcar player %d em rodada, mas não existe" % peer_id)
		return
	
	var player = players[peer_id]
	
	if player["round_id"] != -1 and player["round_id"] != round_id:
		_leave_round_internal(peer_id)
	
	player["round_id"] = round_id
	init_player_inventory(round_id, peer_id)
	
	_log_debug("✓ Player %d entrou na rodada %d" % [peer_id, round_id])
	player_joined_round.emit(peer_id, round_id)

func leave_round(peer_id: int):
	"""Remove jogador da rodada atual"""
	_leave_round_internal(peer_id)

func _leave_round_internal(peer_id: int):
	if not players.has(peer_id):
		return
	
	var player = players[peer_id]
	var old_round_id = player["round_id"]
	
	if old_round_id == -1:
		return
	
	clear_player_inventory(old_round_id, peer_id)
	player["round_id"] = -1
	
	_log_debug("✓ Player %d saiu da rodada %d" % [peer_id, old_round_id])
	player_left_round.emit(peer_id, old_round_id)

# ===== QUERIES DE LOCALIZAÇÃO =====

func in_room(peer_id: int) -> bool:
	if not players.has(peer_id):
		return false
	return players[peer_id]["room_id"] != -1

func in_round(peer_id: int) -> bool:
	if not players.has(peer_id):
		return false
	return players[peer_id]["round_id"] != -1

func get_player_room(peer_id: int) -> int:
	if not players.has(peer_id):
		return -1
	return players[peer_id]["room_id"]

func get_player_round(peer_id: int) -> int:
	if not players.has(peer_id):
		return -1
	return players[peer_id]["round_id"]

func get_players_in_room(room_id: int) -> Array:
	var result = []
	for peer_id in players:
		if players[peer_id]["room_id"] == room_id:
			result.append(peer_id)
	return result

func get_players_in_round(round_id: int) -> Array:
	var result = []
	for peer_id in players:
		if players[peer_id]["round_id"] == round_id:
			result.append(peer_id)
	return result

# ===== QUERIES DE DADOS =====

func get_player(peer_id: int) -> Dictionary:
	if not players.has(peer_id):
		return {}
	return players[peer_id].duplicate()

func get_player_name(peer_id: int) -> String:
	if not players.has(peer_id):
		return ""
	return players[peer_id]["name"]

func is_player_registered(peer_id: int) -> bool:
	if not players.has(peer_id):
		return false
	return players[peer_id]["registered"]

func get_all_players() -> Array:
	return players.values().duplicate()

func get_player_count() -> int:
	return players.size()

func get_registered_player_count() -> int:
	var count = 0
	for player in players.values():
		if player["registered"]:
			count += 1
	return count

# ===== SISTEMA DE INVENTÁRIO POR RODADA =====

func init_player_inventory(round_id: int, player_id: int) -> bool:
	"""Inicializa inventário do jogador em uma rodada específica"""
	if not is_player_registered(player_id):
		push_error("PlayerRegistry: Tentou inicializar inventário de player %d não registrado" % player_id)
		return false
	
	if not player_inventories.has(round_id):
		player_inventories[round_id] = {}
	
	if player_inventories[round_id].has(player_id):
		_log_debug("⚠ Inventário do player %d na rodada %d já existe" % [player_id, round_id])
		return true
	
	player_inventories[round_id][player_id] = {
		"inventory": [],
		"equipped": {
			"hand-right": {},
			"hand-left": {},
			"head": {},
			"body": {},
			"back": {}
		}
	}
	
	_log_debug("✓ Inventário inicializado: Player %d na rodada %d" % [player_id, round_id])
	return true

func add_item_to_inventory(round_id: int, player_id: int, item_id: String, object_id: int) -> bool:
	"""Adiciona item ao inventário do jogador"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		push_error("PlayerRegistry: Inventário não encontrado: Player %d, Rodada %d" % [player_id, round_id])
		return false
	
	if inventory["inventory"].size() >= max_inventory_slots:
		_log_debug("⚠ Inventário cheio: Player %d" % player_id)
		#inventory_full.emit(round_id, player_id)
		return false
	
	# Valida item no ItemDatabase se disponível
	if item_database and not item_database.item_exists_by_id(int(item_id)):
		push_error("PlayerRegistry: Item inválido: %s" % item_id)
		return false
	
	var item_name = item_database.get_item_by_id(int(item_id)).to_dictionary()['name']
	var item_data = {
		"item_id": item_id,
		"object_id": object_id
	}
	
	inventory["inventory"].append(item_data)
	
	_log_debug("✓ Item adicionado: %s (ID: %s, Object: %d) → Player %d (Rodada %d)" % [item_name, item_id, object_id, player_id, round_id])
	#item_added_to_inventory.emit(round_id, player_id, item_name)
	
	# Atualizar o do player local também via rpc
	NetworkManager.rpc_id(player_id, "local_add_item_to_inventory", item_id, object_id)
	
	return true

func remove_item_from_inventory(round_id: int, player_id: int, object_id: int) -> bool:
	"""Remove item do inventário pelo object_id"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	var idx = -1
	for i in range(inventory["inventory"].size()):
		if inventory["inventory"][i]["object_id"] == object_id:
			idx = i
			break
	
	if idx == -1:
		_log_debug("⚠ Item com object_id %d não encontrado no inventário" % object_id)
		return false
	
	var item_id = inventory["inventory"][idx]["item_id"]
	var item_name = item_database.get_item_by_id(int(item_id))["name"]
	inventory["inventory"].remove_at(idx)
	
	_log_debug("✓ Item removido por object_id: %d (%s) de Player %d (Rodada %d)" % [object_id, item_name, player_id, round_id])
	#item_removed_from_inventory.emit(round_id, player_id, item_name)
	
	# Atualizar o do player local também via rpc
	NetworkManager.rpc_id(player_id, "local_remove_item_from_inventory", object_id)
	
	return true

func equip_item(round_id: int, player_id: int, item_name: String, object_id, slot: String = "") -> bool:
	"""
	Equipa item em um slot (detecta automaticamente se não especificado)
	Slots válidos: hand-right, hand-left, head, body, back
	"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	# Procura o item no inventário
	var item_data: Dictionary = {}
	var item_idx = -1
	for i in range(inventory["inventory"].size()):
		if inventory["inventory"][i]["object_id"] == int(object_id):
			item_data = inventory["inventory"][i]
			item_idx = i
			break
	
	if item_data.is_empty():
		_log_debug("⚠ Item não está no inventário: %s" % item_name)
		return false
	
	# Detecta slot automaticamente se não especificado
	if slot.is_empty():
		if item_database:
			slot = item_database.get_slot(item_name)
		if slot.is_empty():
			push_error("PlayerRegistry: Não foi possível detectar slot para item: %s" % item_name)
			return false
	
	# Valida slot
	if not inventory["equipped"].has(slot):
		push_error("PlayerRegistry: Slot inválido: %s" % slot)
		return false
	
	# Valida se item pode ser equipado neste slot
	if item_database and not item_database.can_equip_in_slot(item_name, slot):
		push_error("PlayerRegistry: Item %s não pode ser equipado em %s" % [item_name, slot])
		return false
	
	# Desequipa item atual se houver
	if not inventory["equipped"][slot].is_empty():
		unequip_item(round_id, player_id, slot)
	
	# Equipa novo item
	inventory["equipped"][slot] = item_data
	
	# Remove do inventário
	inventory["inventory"].remove_at(item_idx)
	
	_log_debug("✓ Item equipado: %s em %s (Player %d, Rodada %d)" % [item_name, slot, player_id, round_id])
	#item_equipped.emit(round_id, player_id, item_name, slot)
		
	# Atualizar o do player local também via rpc
	NetworkManager.rpc_id(player_id, "local_equip_item", item_name, object_id, slot)
	
	return true

func unequip_item(round_id: int, player_id: int, slot: String, verify: bool = true) -> bool:
	"""Desequipa item de um slot e retorna ao inventário
	verify false: Não faz verificação de max_inventory_slots, usado quando vai desequipar para 
	item diretamente para ser dropado, ou seja, não retorna para inventário"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	if not inventory["equipped"].has(slot):
		push_error("PlayerRegistry: Slot inválido: %s" % slot)
		return false
	
	var item_data = inventory["equipped"][slot]
	if item_data.is_empty():
		return false
	
	# Verifica se há espaço no inventário
	if verify and inventory["inventory"].size() >= max_inventory_slots:
		_log_debug("⚠ Inventário cheio, não pode desequipar item")
		#inventory_full.emit(round_id, player_id)
		return false
	
	var item_name = item_database.get_item_by_id(int(item_data["item_id"]))["name"]
	
	# Adiciona de volta ao inventário
	inventory["inventory"].append(item_data)
	
	# Limpa slot
	inventory["equipped"][slot] = {}
	
	_log_debug("✓ Item desequipado: %s de %s (Player %d, Rodada %d)" % [item_name, slot, player_id, round_id])
	#item_unequipped.emit(round_id, player_id, item_name, slot)
		
	# Atualizar o do player local também via rpc
	NetworkManager.rpc_id(player_id, "local_unequip_item", item_data["item_id"], slot, verify)
	
	return true

func swap_equipped_item(round_id: int, player_id: int, new_item_name: String, inventory_item: Dictionary, equiped_item_id: int, target_slot: String) -> bool:
	"""
	Troca item equipado diretamente (desequipa antigo, equipa novo)
	- Não emite sinais intermediários de equip/unequip
	- Mantém ambos os itens no inventário/equipamento
	- Emite apenas items_swapped no final
	"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	if not inventory["equipped"].has(target_slot):
		push_error("PlayerRegistry: Slot inválido para swap: %s" % target_slot)
		return false
	
	var old_item_data = inventory["equipped"][target_slot]
	if old_item_data.is_empty():
		push_error("PlayerRegistry: Nenhum item equipado no slot %s para trocar" % target_slot)
		return false
	
	# Verifica se o dragged_item realmente está no inventário
	var new_item_idx = -1
	for i in range(inventory["inventory"].size()):
		if inventory["inventory"][i]["object_id"] == int(inventory_item["object_id"]):
			new_item_idx = i
			break
	
	if new_item_idx == -1:
		push_error("PlayerRegistry: Item arrastado não encontrado no inventário")
		return false
	
	var new_item_data = inventory["inventory"][new_item_idx]
	
	# 1. Remove o NOVO item do inventário
	inventory["inventory"].remove_at(new_item_idx)
	
	# 2. Coloca o ITEM ANTIGO no inventário (no lugar do novo)
	inventory["inventory"].append(old_item_data)
	
	# 3. Equipa o NOVO item no slot
	inventory["equipped"][target_slot] = new_item_data
	
	var old_item_name = item_database.get_item_by_id(int(old_item_data["item_id"]))["name"]
	
	_log_debug("🔄 Item trocado diretamente: %s <-> %s em %s (Player %d, Rodada %d)" % [
		old_item_name, new_item_name, target_slot, player_id, round_id
	])
	
	# Atualiza o cliente via RPC
	NetworkManager.rpc_id(player_id, "local_swap_equipped_item", new_item_name, inventory_item, equiped_item_id, target_slot)
	
	return true

func clear_player_inventory(round_id: int, player_id: int):
	"""Limpa inventário do jogador em uma rodada"""
	if not player_inventories.has(round_id):
		return
	
	if player_inventories[round_id].has(player_id):
		player_inventories[round_id].erase(player_id)
		_log_debug("✓ Inventário limpo: Player %d na rodada %d" % [player_id, round_id])

func clear_round_inventories(round_id: int):
	"""Limpa todos os inventários de uma rodada"""
	if not player_inventories.has(round_id):
		return
	
	var player_count = player_inventories[round_id].size()
	player_inventories.erase(round_id)
	_log_debug("✓ Inventários da rodada %d limpos (%d jogadores)" % [round_id, player_count])

# ===== QUERIES DE INVENTÁRIO =====

func get_player_inventory(round_id: int, player_id: int) -> Dictionary:
	"""Retorna cópia completa do inventário do jogador"""
	return _get_player_inventory(round_id, player_id).duplicate(true)

func get_inventory_items(round_id: int, player_id: int) -> Array:
	"""Retorna apenas lista de itens no inventário (não equipados)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return []
	return inventory["inventory"].duplicate()

func get_inventory_item_names(round_id: int, player_id: int) -> Array:
	"""Retorna apenas os nomes dos itens no inventário"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return []
	
	var names = []
	for item_data in inventory["inventory"]:
		names.append(item_data["item_name"])
	return names

func get_equipped_items(round_id: int, player_id: int) -> Dictionary:
	"""Retorna dicionário de itens equipados {slot: item_data}"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	return inventory["equipped"].duplicate()

func get_equipped_item_in_slot(round_id: int, player_id: int, slot: String) -> Dictionary:
	"""Retorna dados completos do item equipado em slot específico"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	return inventory["equipped"].get(slot, {})

func get_equipped_item_name_in_slot(round_id: int, player_id: int, slot: String) -> String:
	"""Retorna nome do item equipado em slot específico"""
	var item_data = get_equipped_item_in_slot(round_id, player_id, slot)
	return item_data.get("item_name", "")

func get_all_player_items(round_id: int, player_id: int) -> Array:
	"""Retorna TODOS os itens do jogador (inventário + equipados)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return []
	
	var all_items = inventory["inventory"].duplicate()
	for item_data in inventory["equipped"].values():
		if not item_data.is_empty():
			all_items.append(item_data)
	
	return all_items

func get_all_player_item_names(round_id: int, player_id: int) -> Array:
	"""Retorna apenas os nomes de TODOS os itens do jogador"""
	var all_items = get_all_player_items(round_id, player_id)
	var names = []
	for item_data in all_items:
		names.append(item_data["item_name"])
	return names

func has_item(round_id: int, player_id: int, item_name: String) -> bool:
	"""Verifica se jogador possui um item especifico (em qualquer lugar)"""
	return has_item_in_inventory(round_id, player_id, item_name) or is_item_equipped(round_id, player_id, item_name)

func has_any_item(round_id: int, player_id: int) -> bool:
	"""Verifica se jogador possui algum item qualquer (em qualquer lugar)"""
	var inventory = _get_player_inventory(round_id, player_id)
	return not inventory["inventory"].is_empty()

func has_item_in_inventory(round_id: int, player_id: int, item_name: String) -> bool:
	"""Verifica se item está no inventário (não equipado)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	for item_data in inventory["inventory"]:
		if item_data["item_name"] == item_name:
			return true
	return false

func is_item_equipped(round_id: int, player_id: int, object_id: String) -> bool:
	"""Verifica se item está equipado pelo id do objeto"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	for item_data in inventory["equipped"].values():
		if not item_data.is_empty() and item_data["object_id"] == int(object_id):
			return true
	return false

func get_equipped_slot(round_id: int, player_id: int, item_name: String) -> String:
	"""Retorna slot onde item está equipado (ou "" se não equipado)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return ""
	
	for slot in inventory["equipped"]:
		var item_data = inventory["equipped"][slot]
		if not item_data.is_empty() and item_data["item_name"] == item_name:
			return slot
	
	return ""

func is_slot_empty(round_id: int, player_id: int, slot: String) -> bool:
	"""Verifica se slot está vazio"""
	return get_equipped_item_in_slot(round_id, player_id, slot).is_empty()

func get_empty_slots(round_id: int, player_id: int) -> Array:
	"""Retorna array de slots vazios"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return []
	
	var empty = []
	for slot in inventory["equipped"]:
		if inventory["equipped"][slot].is_empty():
			empty.append(slot)
	
	return empty

func get_occupied_slots(round_id: int, player_id: int) -> Array:
	"""Retorna array de slots ocupados"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return []
	
	var occupied = []
	for slot in inventory["equipped"]:
		if not inventory["equipped"][slot].is_empty():
			occupied.append(slot)
	
	return occupied

func get_inventory_count(round_id: int, player_id: int) -> int:
	"""Retorna quantidade de itens no inventário (não equipados)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return 0
	return inventory["inventory"].size()

func get_equipped_count(round_id: int, player_id: int) -> int:
	"""Retorna quantidade de itens equipados"""
	var equipped = get_equipped_items(round_id, player_id)
	var count = 0
	for item_data in equipped.values():
		if not item_data.is_empty():
			count += 1
	return count

func get_total_item_count(round_id: int, player_id: int) -> int:
	"""Retorna total de itens (inventário + equipados)"""
	return get_inventory_count(round_id, player_id) + get_equipped_count(round_id, player_id)

func is_inventory_full(round_id: int, player_id: int) -> bool:
	"""Verifica se inventário está cheio"""
	return get_inventory_count(round_id, player_id) >= max_inventory_slots

func get_inventory_space_left(round_id: int, player_id: int) -> int:
	"""Retorna espaço disponível no inventário"""
	return max(0, max_inventory_slots - get_inventory_count(round_id, player_id))

func has_any_equipped(round_id: int, player_id: int) -> bool:
	"""Verifica se jogador tem algum item equipado"""
	return get_equipped_count(round_id, player_id) > 0

func has_full_equipment(round_id: int, player_id: int) -> bool:
	"""Verifica se todos os slots estão equipados"""
	return get_empty_slots(round_id, player_id).is_empty()

func get_item_by_object_id(round_id: int, player_id: int, object_id: int) -> Dictionary:
	"""Retorna dados do item pelo object_id (busca em inventário e equipados)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	
	# Busca no inventário
	for item_data in inventory["inventory"]:
		if item_data["object_id"] == object_id:
			return item_data.duplicate()
	
	# Busca nos equipados
	for item_data in inventory["equipped"].values():
		if not item_data.is_empty() and item_data["object_id"] == object_id:
			return item_data.duplicate()
	
	return {}

# ===== QUERIES DE FACILITAÇÃO =====

func get_equipped_hand_items(round_id: int, player_id: int) -> Dictionary:
	"""Retorna itens equipados nas mãos {hand-left: item_data, hand-right: item_data}"""
	return {
		"hand-left": get_equipped_item_in_slot(round_id, player_id, "hand-left"),
		"hand-right": get_equipped_item_in_slot(round_id, player_id, "hand-right")
	}

func has_weapon_equipped(round_id: int, player_id: int) -> bool:
	"""Verifica se tem arma equipada (mão direita ou esquerda)"""
	var left = get_equipped_item_in_slot(round_id, player_id, "hand-left")
	var right = get_equipped_item_in_slot(round_id, player_id, "hand-right")
	return not left.is_empty() or not right.is_empty()

func has_both_hands_equipped(round_id: int, player_id: int) -> bool:
	"""Verifica se ambas as mãos estão equipadas"""
	var left = get_equipped_item_in_slot(round_id, player_id, "hand-left")
	var right = get_equipped_item_in_slot(round_id, player_id, "hand-right")
	return not left.is_empty() and not right.is_empty()

func get_equipped_armor(round_id: int, player_id: int) -> Dictionary:
	"""Retorna armadura equipada {head: item_data, body: item_data}"""
	return {
		"head": get_equipped_item_in_slot(round_id, player_id, "head"),
		"body": get_equipped_item_in_slot(round_id, player_id, "body")
	}

func has_armor_equipped(round_id: int, player_id: int) -> bool:
	"""Verifica se tem armadura equipada"""
	var head = get_equipped_item_in_slot(round_id, player_id, "head")
	var body = get_equipped_item_in_slot(round_id, player_id, "body")
	return not head.is_empty() or not body.is_empty()
	
func has_shield_equipped(round_id: int, player_id: int) -> bool:
	"""Verifica se tem escudo equipado"""
	var hand_left_data = get_equipped_item_in_slot(round_id, player_id, "hand-left")
	if hand_left_data.is_empty():
		return false
	
	if hand_left_data.has("item_id"):
		var item_id = hand_left_data["item_id"]
		var item = item_database.get_item_by_id(int(item_id)).to_dictionary()
		return item["function"] == "defense"
	return false
	
func count_items_of_type(round_id: int, player_id: int, item_type: String) -> int:
	"""Conta quantos itens de um tipo específico o jogador possui"""
	if not item_database:
		return 0
	
	var all_items = get_all_player_item_names(round_id, player_id)
	var count = 0
	
	for item_name in all_items:
		if item_database.get_type(item_name) == item_type:
			count += 1
	
	return count

func find_items_by_level(round_id: int, player_id: int, min_level: int = 1, max_level: int = 999) -> Array:
	"""Retorna itens do jogador dentro de um range de level"""
	if not item_database:
		return []
	
	var all_items = get_all_player_item_names(round_id, player_id)
	var result = []
	
	for item_name in all_items:
		var level = item_database.get_item_level(item_name)
		if level >= min_level and level <= max_level:
			result.append(item_name)
	
	return result

func get_first_equipped_item(round_id: int, player_id: int) -> Dictionary:
	"""
	Retorna o primeiro item equipado seguindo a ordem de prioridade:
	mão esquerda -> mão direita -> corpo -> cabeça -> costas
	Retorna dicionário vazio se nenhum item equipado
	"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	
	var priority_order = ["hand-left", "hand-right", "body", "head", "back"]
	
	for slot in priority_order:
		var item_data = inventory["equipped"].get(slot, {})
		if not item_data.is_empty():
			return item_data.duplicate()
	
	return {}

# ===== GERENCIAMENTO DE NODES =====

func register_player_node(peer_id: int, player_node: Node):
	"""Registra referência ao node do jogador na cena"""
	if not is_player_registered(peer_id):
		push_error("PlayerRegistry: Tentou registrar nó de player %d não registrado" % peer_id)
		return
	
	if not player_node or not player_node.is_inside_tree():
		push_error("PlayerRegistry: Tentou registrar nó inválido para player %d" % peer_id)
		return
	
	var node_path = str(player_node.get_path())
	players[peer_id]["node_path"] = node_path
	players_cache[peer_id] = node_path
	
	_log_debug("✓ Nó registrado: Player %d → %s" % [peer_id, node_path])

func unregister_player_node(peer_id: int):
	"""Remove referência ao node do jogador"""
	if not players.has(peer_id):
		return
	
	players[peer_id]["node_path"] = ""
	players_cache.erase(peer_id)
	_log_debug("✓ Nó desregistrado: Player %d" % peer_id)

func get_player_node(peer_id: int) -> Node:
	"""Retorna o node do jogador na cena"""
	if not is_player_registered(peer_id):
		return null
	
	if players_cache.has(peer_id):
		var cached_path = players_cache[peer_id]
		var node = get_node_or_null(cached_path)
		if node:
			return node
		else:
			players_cache.erase(peer_id)
			_log_debug("⚠ Cache desatualizado para player %d" % peer_id)
	
	var player_data = players[peer_id]
	var node_path = player_data.get("node_path", "")
	
	if node_path.is_empty():
		return null
	
	var player_node = get_node_or_null(node_path)
	
	if player_node:
		players_cache[peer_id] = node_path
	else:
		_log_debug("⚠ Nó não encontrado: %s (Player %d)" % [node_path, peer_id])
	
	return player_node

func has_player_node(peer_id: int) -> bool:
	"""Verifica se jogador tem node registrado válido"""
	return get_player_node(peer_id) != null

func get_player_node_path(peer_id: int) -> String:
	"""Retorna string do NodePath do jogador"""
	if not players.has(peer_id):
		return ""
	return players[peer_id].get("node_path", "")

# ===== FUNÇÕES INTERNAS =====

func _get_player_inventory(round_id: int, player_id: int) -> Dictionary:
	"""Retorna referência INTERNA do inventário (não duplica)"""
	if not player_inventories.has(round_id):
		return {}
	
	if not player_inventories[round_id].has(player_id):
		return {}
	
	return player_inventories[round_id][player_id]

func _cleanup_player_inventories(player_id: int):
	"""Remove inventários do jogador de todas as rodadas"""
	for round_id in player_inventories:
		if player_inventories[round_id].has(player_id):
			player_inventories[round_id].erase(player_id)

# ===== DEBUG =====

func debug_print_player_inventory(round_id: int, player_id: int):
	"""Imprime inventário completo de um jogador"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		print("❌ Inventário não encontrado para Player %d na rodada %d" % [player_id, round_id])
		return
	
	var player_name = get_player_name(player_id)
	print("\n╔═══ INVENTÁRIO: %s (ID: %d) - Rodada %d ═══╗" % [player_name, player_id, round_id])
	
	# Itens no inventário
	print("  [Inventário: %d/%d]" % [inventory["inventory"].size(), max_inventory_slots])
	if inventory["inventory"].is_empty():
		print("    (vazio)")
	else:
		for item_data in inventory["inventory"]:
			print("    - %s (ID: %s, Object: %d)" % [item_data["item_name"], item_data["item_id"], item_data["object_id"]])
	
	# Itens equipados
	print("\n  [Equipados]")
	var has_equipped = false
	for slot in inventory["equipped"]:
		var item_data = inventory["equipped"][slot]
		if not item_data.is_empty():
			print("    %s: %s (ID: %s, Object: %d)" % [slot, item_data["item_name"], item_data["item_id"], item_data["object_id"]])
			has_equipped = true
	if not has_equipped:
		print("    (nenhum)")
	
	print("╚" + "═".repeat(50) + "╝\n")

func debug_print_all_players():
	"""Imprime estado completo de todos os jogadores"""
	print("\n========== PLAYER REGISTRY ==========")
	print("Total de players: %d" % players.size())
	print("Registrados: %d" % get_registered_player_count())
	print("Cache de nodes: %d entradas" % players_cache.size())
	
	var total_inventories = 0
	for round_id in player_inventories:
		total_inventories += player_inventories[round_id].size()
	print("Inventários ativos: %d" % total_inventories)
	print("-------------------------------------")
	
	for peer_id in players:
		var p = players[peer_id]
		print("\n[Player %d]" % peer_id)
		print("  Nome: %s" % (p["name"] if p["name"] else "(sem nome)"))
		print("  Registrado: %s" % p["registered"])
		print("  Sala: %s" % (p["room_id"] if p["room_id"] != -1 else "(nenhuma)"))
		print("  Rodada: %s" % (p["round_id"] if p["round_id"] != -1 else "(nenhuma)"))
		
		var node_path = p["node_path"]
		if node_path.is_empty():
			print("  Node: (não registrado)")
		else:
			var node = get_node_or_null(node_path)
			var status = "✓ VÁLIDO" if node else "✗ INVÁLIDO"
			print("  Node: %s [%s]" % [node_path, status])
		
		for round_id in player_inventories:
			if player_inventories[round_id].has(peer_id):
				var inv = player_inventories[round_id][peer_id]
				print("  Inventário [Rodada %d]: %d itens, %d equipados" % [
					round_id,
					inv["inventory"].size(),
					get_equipped_count(round_id, peer_id)
				])
	
	print("\n=====================================\n")

func _log_debug(message: String):
	if debug_mode:
		print("[SERVER][PlayerRegistry] %s" % message)
