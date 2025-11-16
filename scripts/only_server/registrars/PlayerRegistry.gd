extends Node
## PlayerRegistry - Registro centralizado de jogadores (SERVIDOR APENAS)
## Gerencia informações de todos os jogadores conectados + Inventário por Rodada

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true
@export var max_inventory_slots: int = 20  # Limite de itens por jogador

# ===== REGISTROS =====

var room_registry = ServerManager.player_registry
var round_registry = ServerManager.round_registry
var object_spawner = ServerManager.object_spawner

# ===== VARIÁVEIS INTERNAS =====

var players: Dictionary = {}
var players_cache: Dictionary = {}  # Cache de NodePath para acesso rápido

## Inventários organizados por rodada e jogador: {round_id: {player_id: {equipped: {}, inventory: []}}}
var player_inventories: Dictionary = {}

# Estado de inicialização
var _is_server: bool = false
var _initialized: bool = false

# ===== SINAIS =====

signal item_added_to_inventory(round_id: int, player_id: int, item_name: String)
signal item_removed_from_inventory(round_id: int, player_id: int, item_name: String)
signal item_equipped(round_id: int, player_id: int, item_name: String, slot: String)
signal item_unequipped(round_id: int, player_id: int, slot: String)
signal inventory_full(round_id: int, player_id: int)

# ===== INICIALIZAÇÃO CONTROLADA =====

func initialize_as_server():
	if _initialized:
		return
	
	_is_server = true
	_initialized = true
	
	_log_debug("PlayerRegistry inicializado")

func initialize_as_client():
	if _initialized:
		return
	
	_is_server = false
	_initialized = true
	_log_debug("PlayerRegistry acessado como CLIENTE (operações bloqueadas)")

func reset():
	players.clear()
	players_cache.clear()
	player_inventories.clear()
	_initialized = false
	_is_server = false
	_log_debug("PlayerRegistry resetado")

# ===== GERENCIAMENTO DE JOGADORES =====

func add_peer(peer_id: int):
	if not _is_server:
		return
	
	players[peer_id] = {
		"id": peer_id,
		"name": "",
		"registered": false,
		"connected_at": Time.get_unix_time_from_system(),
		"in_game": false,
		"node_path": ""
	}
	_log_debug("Peer adicionado: %d" % peer_id)

func set_player_in_game(player_id: int, in_game: bool):
	if not _is_server:
		return
	if players.has(player_id):
		players[player_id]["in_game"] = in_game
		_log_debug("Player %d in_game = %s" % [player_id, in_game])

func get_in_game_players_list(out_game: bool = false) -> Array:
	if not _is_server:
		return []
	
	var players_list_in = []
	var players_list_out = []
	var players_ = players.duplicate()
	for p_id in players_:
		if get_player(p_id)["in_game"] == true:
			players_list_in.append(p_id)
		else:
			players_list_out.append(p_id)
	return players_list_out if out_game else players_list_in

func remove_peer(peer_id: int):
	if not _is_server:
		return
	
	if players.has(peer_id):
		var player = players[peer_id]
		_log_debug("Peer removido: %d (%s)" % [peer_id, player["name"] if player["name"] else "sem_nome"])
		
		# Limpa inventários do jogador em todas as rodadas
		_cleanup_player_inventories(peer_id)
		
		players.erase(peer_id)
		players_cache.erase(peer_id)

func register_player(peer_id: int, player_name: String) -> bool:
	if not _is_server:
		return false
	
	if not players.has(peer_id):
		_log_debug("Tentativa de registrar jogador inexistente: %d" % peer_id)
		return false
	
	if is_name_taken(player_name):
		_log_debug("Nome já está em uso: %s" % player_name)
		return false
	
	players[peer_id]["name"] = player_name
	players[peer_id]["registered"] = true
	
	_log_debug(" Jogador registrado: %s (ID: %d)" % [player_name, peer_id])
	return true

func is_name_taken(player_name: String) -> bool:
	if not _is_server:
		return false
	
	var normalized_name = player_name.strip_edges().to_lower()
	for player in players.values():
		if player.has("name") and player["name"].strip_edges().to_lower() == normalized_name:
			return true
	return false

func get_player(peer_id: int) -> Dictionary:
	if not _is_server or not players.has(peer_id):
		return {}
	return players[peer_id]

func get_player_name(peer_id: int) -> String:
	if not _is_server or not players.has(peer_id):
		return ""
	return players[peer_id]["name"]

func is_player_registered(peer_id: int) -> bool:
	if not _is_server or not players.has(peer_id):
		return false
	return players[peer_id]["registered"]

func get_all_players() -> Array:
	if not _is_server:
		return []
	return players.values()

func get_player_count() -> int:
	return players.size() if _is_server else 0

func get_registered_player_count() -> int:
	if not _is_server:
		return 0
	
	var count = 0
	for player in players.values():
		if player["registered"]:
			count += 1
	return count

func clear_all():
	if not _is_server:
		return
	
	_log_debug("Limpando todos os jogadores")
	players.clear()
	players_cache.clear()
	player_inventories.clear()

# ===== SISTEMA DE INVENTÁRIO POR RODADA =====

## Inicializa inventário do jogador em uma rodada
func init_player_inventory(round_id: int, player_id: int) -> bool:
	if not _is_server:
		return false
	
	if not is_player_registered(player_id):
		push_error("Tentou inicializar inventário de player %d não registrado" % player_id)
		return false
	
	# Cria estrutura da rodada se não existir
	if not player_inventories.has(round_id):
		player_inventories[round_id] = {}
	
	# Cria inventário do jogador
	player_inventories[round_id][player_id] = {
		"inventory": [],  # Array de item_names
		"equipped": {     # Itens equipados por slot
			"hand_right": "",
			"hand_left": "",
			"head": "",
			"body": ""
		},
		"stats": {
			"items_collected": 0,
			"items_used": 0
		}
	}
	
	_log_debug(" Inventário inicializado: Player %d na rodada %d" % [player_id, round_id])
	return true

## Adiciona item ao inventário
func add_item_to_inventory(round_id: int, player_id: int, item_name: String) -> bool:
	if not _is_server:
		return false
	
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		push_error("Inventário não encontrado: Player %d, Rodada %d" % [player_id, round_id])
		return false
	
	# Verifica limite de slots
	if inventory["inventory"].size() >= max_inventory_slots:
		_log_debug("⚠ Inventário cheio: Player %d" % player_id)
		inventory_full.emit(round_id, player_id)
		return false
	
	# Valida item no database
	if not ItemDatabase.item_exists(item_name):
		push_error("Item inválido: %s" % item_name)
		return false
	
	# Adiciona ao inventário
	inventory["inventory"].append(item_name)
	inventory["stats"]["items_collected"] += 1
	
	_log_debug(" Item adicionado: %s → Player %d (Rodada %d)" % [item_name, player_id, round_id])
	item_added_to_inventory.emit(round_id, player_id, item_name)
	
	return true

## Remove item do inventário
func remove_item_from_inventory(round_id: int, player_id: int, item_name: String) -> bool:
	if not _is_server:
		return false
	
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	var idx = inventory["inventory"].find(item_name)
	if idx == -1:
		_log_debug("⚠ Item não encontrado no inventário: %s" % item_name)
		return false
	
	inventory["inventory"].remove_at(idx)
	inventory["stats"]["items_used"] += 1
	
	_log_debug(" Item removido: %s de Player %d (Rodada %d)" % [item_name, player_id, round_id])
	item_removed_from_inventory.emit(round_id, player_id, item_name)
	
	return true

## Equipa item em um slot
func equip_item(round_id: int, player_id: int, item_name: String) -> bool:
	if not _is_server:
		return false
	
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	# Verifica se item está no inventário
	if item_name not in inventory["inventory"]:
		_log_debug("⚠ Item não está no inventário: %s" % item_name)
		return false
	
	# Obtém dados do item
	var item_data = ItemDatabase.get_item(item_name)
	if not item_data:
		return false
	
	# Determina slot baseado no tipo
	var slot = _get_slot_for_item(item_data)
	if slot.is_empty():
		push_error("Não foi possível determinar slot para item: %s" % item_name)
		return false
	
	# Desequipa item atual se houver
	var current_item = inventory["equipped"][slot]
	if not current_item.is_empty():
		unequip_item(round_id, player_id, slot)
	
	# Equipa novo item
	inventory["equipped"][slot] = item_name
	
	_log_debug(" Item equipado: %s em %s (Player %d, Rodada %d)" % [item_name, slot, player_id, round_id])
	item_equipped.emit(round_id, player_id, item_name, slot)
	
	return true

## Desequipa item de um slot
func unequip_item(round_id: int, player_id: int, slot: String) -> bool:
	if not _is_server:
		return false
	
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	if not inventory["equipped"].has(slot):
		push_error("Slot inválido: %s" % slot)
		return false
	
	var item_name = inventory["equipped"][slot]
	if item_name.is_empty():
		return false
	
	inventory["equipped"][slot] = ""
	
	_log_debug(" Item desequipado: %s de %s (Player %d, Rodada %d)" % [item_name, slot, player_id, round_id])
	item_unequipped.emit(round_id, player_id, slot)
	
	return true

## Retorna inventário completo do jogador
func get_player_inventory(round_id: int, player_id: int) -> Dictionary:
	return _get_player_inventory(round_id, player_id).duplicate(true)

## Retorna apenas itens no inventário (não equipados)
func get_inventory_items(round_id: int, player_id: int) -> Array:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return []
	return inventory["inventory"].duplicate()

## Retorna itens equipados
func get_equipped_items(round_id: int, player_id: int) -> Dictionary:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	return inventory["equipped"].duplicate()

## Verifica se jogador tem um item
func has_item(round_id: int, player_id: int, item_name: String) -> bool:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	return item_name in inventory["inventory"]

## Verifica se item está equipado
func is_item_equipped(round_id: int, player_id: int, item_name: String) -> bool:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	return item_name in inventory["equipped"].values()

## Retorna slot onde item está equipado
func get_equipped_slot(round_id: int, player_id: int, item_name: String) -> String:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return ""
	
	for slot in inventory["equipped"]:
		if inventory["equipped"][slot] == item_name:
			return slot
	
	return ""

## Retorna contagem de itens no inventário
func get_inventory_count(round_id: int, player_id: int) -> int:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return 0
	return inventory["inventory"].size()

## Verifica se inventário está cheio
func is_inventory_full(round_id: int, player_id: int) -> bool:
	return get_inventory_count(round_id, player_id) >= max_inventory_slots

## Limpa inventário do jogador em uma rodada
func clear_player_inventory(round_id: int, player_id: int):
	if not _is_server:
		return
	
	if not player_inventories.has(round_id):
		return
	
	if player_inventories[round_id].has(player_id):
		player_inventories[round_id].erase(player_id)
		_log_debug("Inventário limpo: Player %d na rodada %d" % [player_id, round_id])

## Retorna estatísticas do inventário
func get_inventory_stats(round_id: int, player_id: int) -> Dictionary:
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	return inventory["stats"].duplicate()

## NOVO: Transfere item entre jogadores (trade)
func transfer_item(round_id: int, from_player: int, to_player: int, item_name: String) -> bool:
	if not _is_server:
		return false
	
	# Verifica se from_player tem o item
	if not has_item(round_id, from_player, item_name):
		_log_debug("⚠ Player %d não possui item %s" % [from_player, item_name])
		return false
	
	# Verifica se to_player tem espaço
	if is_inventory_full(round_id, to_player):
		_log_debug("⚠ Inventário de Player %d está cheio" % to_player)
		inventory_full.emit(round_id, to_player)
		return false
	
	# Remove do remetente
	if not remove_item_from_inventory(round_id, from_player, item_name):
		return false
	
	# Adiciona ao destinatário
	if not add_item_to_inventory(round_id, to_player, item_name):
		# Rollback: devolve ao remetente
		add_item_to_inventory(round_id, from_player, item_name)
		return false
	
	_log_debug(" Item transferido: %s (Player %d → Player %d)" % [item_name, from_player, to_player])
	return true

# ===== FUNÇÕES INTERNAS =====

func _get_player_inventory(round_id: int, player_id: int) -> Dictionary:
	"""Retorna referência interna do inventário (não duplica)"""
	if not player_inventories.has(round_id):
		return {}
	
	if not player_inventories[round_id].has(player_id):
		return {}
	
	return player_inventories[round_id][player_id]

func _get_slot_for_item(item_data) -> String:
	"""Determina slot baseado no tipo e lado do item"""
	match item_data.item_type:
		"hand":
			return "hand_right" if item_data.item_side == "right" else "hand_left"
		"head":
			return "head"
		"body":
			return "body"
		_:
			return ""

func _cleanup_player_inventories(player_id: int):
	"""Remove inventários do jogador de todas as rodadas"""
	for round_id in player_inventories:
		if player_inventories[round_id].has(player_id):
			player_inventories[round_id].erase(player_id)

func _on_round_ended(round_data: Dictionary):
	"""Limpa inventários quando rodada termina"""
	var round_id = round_data["round_id"]
	
	if player_inventories.has(round_id):
		var player_count = player_inventories[round_id].size()
		player_inventories.erase(round_id)
		_log_debug(" Inventários da rodada %d limpos (%d jogadores)" % [round_id, player_count])

# ===== QUERIES AVANÇADAS =====

## Retorna todos os jogadores que possuem um item específico
func get_players_with_item(round_id: int, item_name: String) -> Array:
	var result = []
	
	if not player_inventories.has(round_id):
		return result
	
	for player_id in player_inventories[round_id]:
		if has_item(round_id, player_id, item_name):
			result.append(player_id)
	
	return result

## Retorna jogador com mais itens na rodada
func get_richest_player(round_id: int) -> Dictionary:
	if not player_inventories.has(round_id):
		return {}
	
	var richest_id = -1
	var max_items = 0
	
	for player_id in player_inventories[round_id]:
		var count = get_inventory_count(round_id, player_id)
		if count > max_items:
			max_items = count
			richest_id = player_id
	
	if richest_id == -1:
		return {}
	
	return {
		"player_id": richest_id,
		"item_count": max_items,
		"items": get_inventory_items(round_id, richest_id)
	}

## Estatísticas gerais da rodada
func get_round_inventory_stats(round_id: int) -> Dictionary:
	if not player_inventories.has(round_id):
		return {}
	
	var stats = {
		"total_players": 0,
		"total_items": 0,
		"total_collected": 0,
		"total_used": 0,
		"items_by_type": {}
	}
	
	for player_id in player_inventories[round_id]:
		stats["total_players"] += 1
		
		var inv = player_inventories[round_id][player_id]
		stats["total_items"] += inv["inventory"].size()
		stats["total_collected"] += inv["stats"]["items_collected"]
		stats["total_used"] += inv["stats"]["items_used"]
		
		# Conta por tipo
		for item_name in inv["inventory"]:
			var item_data = ItemDatabase.get_item(item_name)
			if item_data:
				var type = item_data.item_type
				if not stats["items_by_type"].has(type):
					stats["items_by_type"][type] = 0
				stats["items_by_type"][type] += 1
	
	return stats

# ===== GERENCIAMENTO DE NODES (continuação do código original) =====

func register_player_node(p_id: int, player_node: Node):
	if not _is_server:
		push_warning("register_player_node chamado no cliente!")
		return
	
	if not is_player_registered(p_id):
		push_error("Tentou registrar nó de player %d não registrado" % p_id)
		return
	
	if not player_node or not player_node.is_inside_tree():
		push_error("Tentou registrar nó inválido ou não na árvore para player %d" % p_id)
		return
	
	var node_path = player_node.get_path()
	players[p_id]["node_path"] = str(node_path)
	players_cache[p_id] = str(node_path)
	
	_log_debug(" Nó registrado: Player %d → %s" % [p_id, node_path])

func update_player_node_path(p_id: int, new_path: NodePath) -> bool:
	if not _is_server:
		push_warning("update_player_node_path chamado no cliente!")
		return false
	
	if not is_player_registered(p_id):
		push_error("Tentou atualizar node_path de player %d não registrado" % p_id)
		return false
	
	var node = get_node_or_null(new_path)
	if not node:
		push_error("Caminho inválido ao atualizar node_path de player %d: %s" % [p_id, new_path])
		return false
	
	players[p_id]["node_path"] = str(new_path)
	players_cache[p_id] = str(new_path)
	
	_log_debug(" Node path atualizado: Player %d → %s" % [p_id, new_path])
	return true

func get_player_node(p_id: int) -> Node:
	if not _is_server:
		return null
	
	if not is_player_registered(p_id):
		return null
	
	if players_cache.has(p_id):
		var cached_path = players_cache[p_id]
		var node = get_node_or_null(cached_path)
		if node:
			return node
		else:
			players_cache.erase(p_id)
			_log_debug("⚠ Cache desatualizado para player %d, removido" % p_id)
	
	var player_data = get_player(p_id)
	var node_path = player_data.get("node_path", "")
	
	if node_path.is_empty():
		return null
	
	var player_node = get_node_or_null(node_path)
	
	if player_node:
		players_cache[p_id] = node_path
	else:
		_log_debug("⚠ Nó não encontrado no caminho: %s (Player %d)" % [node_path, p_id])
	
	return player_node

func unregister_player_node(p_id: int) -> void:
	if not _is_server:
		return
	
	if players.has(p_id):
		players[p_id]["node_path"] = ""
	
	players_cache.erase(p_id)
	_log_debug("Nó desregistrado: Player %d" % p_id)

func has_player_node(p_id: int) -> bool:
	if not _is_server:
		return false
	
	var player_data = get_player(p_id)
	if player_data.is_empty():
		return false
	
	var node_path = player_data.get("node_path", "")
	if node_path.is_empty():
		return false
	
	var node = get_node_or_null(node_path)
	return node != null

func get_player_node_path(p_id: int) -> String:
	if not _is_server:
		return ""
	
	var player_data = get_player(p_id)
	return player_data.get("node_path", "")

func get_players_in_node(parent_path: NodePath) -> Array[int]:
	if not _is_server:
		return []
	
	var result: Array[int] = []
	var parent_str = str(parent_path)
	
	for p_id in players.keys():
		var node_path = get_player_node_path(p_id)
		if node_path.begins_with(parent_str):
			result.append(p_id)
	
	return result

func get_nearest_player_to(target_node: Node3D, max_distance: float = INF) -> Dictionary:
	if not _is_server or not target_node:
		return {}
	
	var closest_id: int = -1
	var closest_node: Node = null
	var closest_distance: float = INF
	
	for p_id in players.keys():
		var player_node = get_player_node(p_id)
		if not player_node or not player_node is Node3D:
			continue
		
		var distance = target_node.global_position.distance_to(player_node.global_position)
		
		if distance < closest_distance and distance <= max_distance:
			closest_distance = distance
			closest_node = player_node
			closest_id = p_id
	
	if closest_id == -1:
		return {}
	
	return {
		"id": closest_id,
		"node": closest_node,
		"distance": closest_distance
	}

# ===== DEBUG =====

func debug_print_all_players():
	if not _is_server:
		print("[PlayerRegistry] Chamado no cliente, operação bloqueada")
		return
	
	print("\n=== PLAYERS REGISTRADOS ===")
	print("Total: %d players" % players.size())
	print("Cache: %d entradas" % players_cache.size())
	
	# Estatísticas de inventários
	var total_inventories = 0
	for round_id in player_inventories:
		total_inventories += player_inventories[round_id].size()
	print("Inventários ativos: %d" % total_inventories)
	print("---")
	
	for p_id in players.keys():
		var player = players[p_id]
		var name_str = player.get("name", "N/A")
		var registered = player.get("registered", false)
		var in_game = player.get("in_game", false)
		var node_path = player.get("node_path", "")
		
		var node_status = "SEM NÓ"
		if not node_path.is_empty():
			var node = get_node_or_null(node_path)
			node_status = " OK" if node else "MORTO"
		
		print("  Player %d:" % p_id)
		print("    Nome: %s" % name_str)
		print("    Registrado: %s" % registered)
		print("    In Game: %s" % in_game)
		print("    Node: %s [%s]" % [node_path, node_status])
		print("    Cache: %s" % ("SIM" if players_cache.has(p_id) else "NÃO"))
		
		# Mostra inventários do jogador em todas as rodadas
		var player_inv_count = 0
		for round_id in player_inventories:
			if player_inventories[round_id].has(p_id):
				var inv = player_inventories[round_id][p_id]
				var item_count = inv["inventory"].size()
				player_inv_count += item_count
				print("    Inventário [Rodada %d]: %d itens" % [round_id, item_count])
		
		if player_inv_count == 0:
			print("    Inventário: (nenhum)")
		
		print("  ---")
	
	print("===========================\n")

# ===== UTILITÁRIOS =====

func debug_print_inventory(round_id: int, player_id: int):
	"""Imprime inventário detalhado de um jogador"""
	if not _is_server:
		return
	
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		print("❌ Inventário não encontrado: Player %d, Rodada %d" % [player_id, round_id])
		return
	
	print("\n=== INVENTÁRIO DO PLAYER %d (Rodada %d) ===" % [player_id, round_id])
	print("Slots: %d/%d" % [inventory["inventory"].size(), max_inventory_slots])
	print("\nItens no Inventário:")
	for item in inventory["inventory"]:
		var item_data = ItemDatabase.get_item(item)
		if item_data:
			print("  • %s (Tipo: %s, Lv%d)" % [item, item_data.item_type, item_data.item_level])
	
	print("\nItens Equipados:")
	for slot in inventory["equipped"]:
		var item = inventory["equipped"][slot]
		if item.is_empty():
			print("  [%s]: (vazio)" % slot)
		else:
			print("  [%s]: %s" % [slot, item])
	
	print("\nEstatísticas:")
	print("  Coletados: %d" % inventory["stats"]["items_collected"])
	print("  Usados: %d" % inventory["stats"]["items_used"])
	print("=====================================\n")

func validate_all_nodes() -> Dictionary:
	if not _is_server:
		return {}
	
	var stats = {
		"total": 0,
		"valid": 0,
		"invalid": 0,
		"missing": 0,
		"cache_hits": 0,
		"cache_misses": 0
	}
	
	for p_id in players.keys():
		stats.total += 1
		
		var node_path = get_player_node_path(p_id)
		
		if node_path.is_empty():
			stats.missing += 1
			continue
		
		if players_cache.has(p_id):
			stats.cache_hits += 1
		else:
			stats.cache_misses += 1
		
		var node = get_node_or_null(node_path)
		if node:
			stats.valid += 1
		else:
			stats.invalid += 1
			_log_debug("⚠ Nó inválido detectado: Player %d (%s)" % [p_id, node_path])
	
	return stats

func cleanup_invalid_nodes():
	if not _is_server:
		return
	
	var cleaned = 0
	
	for p_id in players.keys():
		var node_path = get_player_node_path(p_id)
		if node_path.is_empty():
			continue
		
		var node = get_node_or_null(node_path)
		if not node:
			players[p_id]["node_path"] = ""
			players_cache.erase(p_id)
			cleaned += 1
			_log_debug(" Nó inválido limpo: Player %d" % p_id)
	
	if cleaned > 0:
		_log_debug("Limpeza completa: %d nós inválidos removidos" % cleaned)

func get_player_node_by_id(p_id: int) -> Node:
	return get_player_node(p_id)

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if _is_server else "[CLIENT]"
		print("%s[PlayerRegistry] %s" % [prefix, message])
