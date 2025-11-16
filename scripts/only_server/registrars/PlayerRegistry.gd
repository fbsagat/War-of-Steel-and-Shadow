extends Node
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
@export var max_inventory_slots: int = 20  # Limite de itens por jogador

# ===== REGISTROS (Injetados pelo ServerManager) =====

var room_registry = null  # Injetado
var round_registry = null  # Injetado
var object_spawner = null  # Injetado

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
signal item_added_to_inventory(round_id: int, player_id: int, item_name: String)
signal item_removed_from_inventory(round_id: int, player_id: int, item_name: String)
signal item_equipped(round_id: int, player_id: int, item_name: String, slot: String)
signal item_unequipped(round_id: int, player_id: int, slot: String)
signal inventory_full(round_id: int, player_id: int)

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
##   "inventory": Array[String],  # Lista de item_names
##   "equipped": {                 # Itens equipados por slot
##     "hand_right": String,
##     "hand_left": String,
##     "head": String,
##     "body": String
##   },
##   "stats": {
##     "items_collected": int,
##     "items_used": int
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
	# Limpa todos os dados
	players.clear()
	players_cache.clear()
	player_inventories.clear()
	
	_initialized = false
	_log_debug("🔄 PlayerRegistry resetado")

# ===== GERENCIAMENTO DE PEERS =====

func add_peer(peer_id: int):
	"""
	Adiciona um novo peer conectado (ainda não registrado)
	Chamado quando um cliente se conecta ao servidor
	"""
	if players.has(peer_id):
		_log_debug("⚠ Peer %d já existe" % peer_id)
		return
	
	players[peer_id] = {
		"id": peer_id,
		"name": "",
		"registered": false,
		"connected_at": Time.get_unix_time_from_system(),
		"room_id": -1,  # -1 = não está em sala
		"round_id": -1,  # -1 = não está em rodada
		"node_path": ""
	}
	
	_log_debug("✓ Peer adicionado: %d" % peer_id)
	peer_added.emit(peer_id)

func remove_peer(peer_id: int):
	"""
	Remove um peer desconectado
	Limpa todas as referências (inventários, cache, etc)
	"""
	if not players.has(peer_id):
		_log_debug("⚠ Tentou remover peer inexistente: %d" % peer_id)
		return
	
	var player = players[peer_id]
	var player_name = player["name"] if player["name"] else "sem_nome"
	
	# Remove das salas/rodadas (se estiver)
	if player["room_id"] != -1:
		_leave_room_internal(peer_id)
	
	# Limpa inventários do jogador em todas as rodadas
	_cleanup_player_inventories(peer_id)
	
	# Remove dados e cache
	players.erase(peer_id)
	players_cache.erase(peer_id)
	
	_log_debug("✓ Peer removido: %d (%s)" % [peer_id, player_name])
	peer_removed.emit(peer_id)

func register_player(peer_id: int, player_name: String) -> bool:
	"""
	Registra nome do jogador (transforma peer em player)
	Retorna false se nome já está em uso
	"""
	if not players.has(peer_id):
		_log_debug("❌ Tentou registrar jogador inexistente: %d" % peer_id)
		return false
	
	# Verifica se nome já está em uso
	if is_name_taken(player_name):
		_log_debug("❌ Nome já em uso: %s" % player_name)
		return false
	
	# Registra nome
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
	"""
	Marca jogador como dentro de uma sala
	IMPORTANTE: Não adiciona na RoomRegistry, apenas rastreia aqui
	"""
	if not players.has(peer_id):
		push_error("PlayerRegistry: Tentou marcar player %d em sala, mas não existe" % peer_id)
		return
	
	var player = players[peer_id]
	
	# Se já estava em outra sala, sai primeiro
	if player["room_id"] != -1 and player["room_id"] != room_id:
		_leave_room_internal(peer_id)
	
	player["room_id"] = room_id
	_log_debug("✓ Player %d entrou na sala %d" % [peer_id, room_id])
	player_joined_room.emit(peer_id, room_id)

func leave_room(peer_id: int):
	"""Remove jogador da sala atual"""
	_leave_room_internal(peer_id)

func _leave_room_internal(peer_id: int):
	"""Implementação interna de sair da sala"""
	if not players.has(peer_id):
		return
	
	var player = players[peer_id]
	var old_room_id = player["room_id"]
	
	if old_room_id == -1:
		return  # Já não estava em sala
	
	# Se estava em rodada, sai também
	if player["round_id"] != -1:
		_leave_round_internal(peer_id)
	
	player["room_id"] = -1
	_log_debug("✓ Player %d saiu da sala %d" % [peer_id, old_room_id])
	player_left_room.emit(peer_id, old_room_id)

func join_round(peer_id: int, round_id: int):
	"""
	Marca jogador como dentro de uma rodada
	Inicializa inventário automaticamente
	"""
	if not players.has(peer_id):
		push_error("PlayerRegistry: Tentou marcar player %d em rodada, mas não existe" % peer_id)
		return
	
	var player = players[peer_id]
	
	# Se já estava em outra rodada, sai primeiro
	if player["round_id"] != -1 and player["round_id"] != round_id:
		_leave_round_internal(peer_id)
	
	player["round_id"] = round_id
	
	# Inicializa inventário
	init_player_inventory(round_id, peer_id)
	
	_log_debug("✓ Player %d entrou na rodada %d" % [peer_id, round_id])
	player_joined_round.emit(peer_id, round_id)

func leave_round(peer_id: int):
	"""Remove jogador da rodada atual"""
	_leave_round_internal(peer_id)

func _leave_round_internal(peer_id: int):
	"""Implementação interna de sair da rodada"""
	if not players.has(peer_id):
		return
	
	var player = players[peer_id]
	var old_round_id = player["round_id"]
	
	if old_round_id == -1:
		return  # Já não estava em rodada
	
	# Limpa inventário
	clear_player_inventory(old_round_id, peer_id)
	
	player["round_id"] = -1
	_log_debug("✓ Player %d saiu da rodada %d" % [peer_id, old_round_id])
	player_left_round.emit(peer_id, old_round_id)

# ===== QUERIES DE LOCALIZAÇÃO =====

func in_room(peer_id: int) -> bool:
	"""Verifica se jogador está em alguma sala"""
	if not players.has(peer_id):
		return false
	return players[peer_id]["room_id"] != -1

func in_round(peer_id: int) -> bool:
	"""Verifica se jogador está em alguma rodada"""
	if not players.has(peer_id):
		return false
	return players[peer_id]["round_id"] != -1

func get_player_room(peer_id: int) -> int:
	"""Retorna ID da sala em que o jogador está (-1 se não estiver)"""
	if not players.has(peer_id):
		return -1
	return players[peer_id]["room_id"]

func get_player_round(peer_id: int) -> int:
	"""Retorna ID da rodada em que o jogador está (-1 se não estiver)"""
	if not players.has(peer_id):
		return -1
	return players[peer_id]["round_id"]

func get_players_in_room(room_id: int) -> Array:
	"""Retorna lista de peer_ids na sala especificada"""
	var result = []
	for peer_id in players:
		if players[peer_id]["room_id"] == room_id:
			result.append(peer_id)
	return result

func get_players_in_round(round_id: int) -> Array:
	"""Retorna lista de peer_ids na rodada especificada"""
	var result = []
	for peer_id in players:
		if players[peer_id]["round_id"] == round_id:
			result.append(peer_id)
	return result

# ===== QUERIES DE DADOS =====

func get_player(peer_id: int) -> Dictionary:
	"""Retorna cópia completa dos dados do jogador"""
	if not players.has(peer_id):
		return {}
	return players[peer_id].duplicate()

func get_player_name(peer_id: int) -> String:
	"""Retorna nome do jogador"""
	if not players.has(peer_id):
		return ""
	return players[peer_id]["name"]

func is_player_registered(peer_id: int) -> bool:
	"""Verifica se jogador completou registro (tem nome)"""
	if not players.has(peer_id):
		return false
	return players[peer_id]["registered"]

func get_all_players() -> Array:
	"""Retorna lista de todos os PlayerData"""
	return players.values().duplicate()

func get_player_count() -> int:
	"""Retorna total de peers conectados"""
	return players.size()

func get_registered_player_count() -> int:
	"""Retorna total de jogadores registrados"""
	var count = 0
	for player in players.values():
		if player["registered"]:
			count += 1
	return count

# ===== SISTEMA DE INVENTÁRIO POR RODADA =====

func init_player_inventory(round_id: int, player_id: int) -> bool:
	"""
	Inicializa inventário do jogador em uma rodada específica
	Chamado automaticamente quando jogador entra em rodada
	"""
	if not is_player_registered(player_id):
		push_error("PlayerRegistry: Tentou inicializar inventário de player %d não registrado" % player_id)
		return false
	
	# Cria estrutura da rodada se não existir
	if not player_inventories.has(round_id):
		player_inventories[round_id] = {}
	
	# Não reinicializa se já existe
	if player_inventories[round_id].has(player_id):
		_log_debug("⚠ Inventário do player %d na rodada %d já existe" % [player_id, round_id])
		return true
	
	# Cria inventário do jogador
	player_inventories[round_id][player_id] = {
		"inventory": [],
		"equipped": {
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
	
	_log_debug("✓ Inventário inicializado: Player %d na rodada %d" % [player_id, round_id])
	return true

func add_item_to_inventory(round_id: int, player_id: int, item_name: String) -> bool:
	"""Adiciona item ao inventário do jogador"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		push_error("PlayerRegistry: Inventário não encontrado: Player %d, Rodada %d" % [player_id, round_id])
		return false
	
	# Verifica limite de slots
	if inventory["inventory"].size() >= max_inventory_slots:
		_log_debug("⚠ Inventário cheio: Player %d" % player_id)
		inventory_full.emit(round_id, player_id)
		return false
	
	# TODO: Validar item no ItemDatabase quando disponível
	# if not ItemDatabase.item_exists(item_name):
	#     push_error("Item inválido: %s" % item_name)
	#     return false
	
	# Adiciona ao inventário
	inventory["inventory"].append(item_name)
	inventory["stats"]["items_collected"] += 1
	
	_log_debug("✓ Item adicionado: %s → Player %d (Rodada %d)" % [item_name, player_id, round_id])
	item_added_to_inventory.emit(round_id, player_id, item_name)
	
	return true

func remove_item_from_inventory(round_id: int, player_id: int, item_name: String) -> bool:
	"""Remove item do inventário do jogador"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	var idx = inventory["inventory"].find(item_name)
	if idx == -1:
		_log_debug("⚠ Item não encontrado no inventário: %s" % item_name)
		return false
	
	inventory["inventory"].remove_at(idx)
	inventory["stats"]["items_used"] += 1
	
	_log_debug("✓ Item removido: %s de Player %d (Rodada %d)" % [item_name, player_id, round_id])
	item_removed_from_inventory.emit(round_id, player_id, item_name)
	
	return true

func equip_item(round_id: int, player_id: int, item_name: String, slot: String) -> bool:
	"""
	Equipa item em um slot específico
	slot pode ser: "hand_right", "hand_left", "head", "body"
	"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	# Verifica se item está no inventário
	if item_name not in inventory["inventory"]:
		_log_debug("⚠ Item não está no inventário: %s" % item_name)
		return false
	
	# Valida slot
	if not inventory["equipped"].has(slot):
		push_error("PlayerRegistry: Slot inválido: %s" % slot)
		return false
	
	# Desequipa item atual se houver
	var current_item = inventory["equipped"][slot]
	if not current_item.is_empty():
		unequip_item(round_id, player_id, slot)
	
	# Equipa novo item
	inventory["equipped"][slot] = item_name
	
	_log_debug("✓ Item equipado: %s em %s (Player %d, Rodada %d)" % [item_name, slot, player_id, round_id])
	item_equipped.emit(round_id, player_id, item_name, slot)
	
	return true

func unequip_item(round_id: int, player_id: int, slot: String) -> bool:
	"""Desequipa item de um slot"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	
	if not inventory["equipped"].has(slot):
		push_error("PlayerRegistry: Slot inválido: %s" % slot)
		return false
	
	var item_name = inventory["equipped"][slot]
	if item_name.is_empty():
		return false
	
	inventory["equipped"][slot] = ""
	
	_log_debug("✓ Item desequipado: %s de %s (Player %d, Rodada %d)" % [item_name, slot, player_id, round_id])
	item_unequipped.emit(round_id, slot)
	
	return true

func transfer_item(round_id: int, from_player: int, to_player: int, item_name: String) -> bool:
	"""Transfere item entre jogadores (trade)"""
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
	
	_log_debug("✓ Item transferido: %s (Player %d → Player %d)" % [item_name, from_player, to_player])
	return true

func clear_player_inventory(round_id: int, player_id: int):
	"""Limpa inventário do jogador em uma rodada"""
	if not player_inventories.has(round_id):
		return
	
	if player_inventories[round_id].has(player_id):
		player_inventories[round_id].erase(player_id)
		_log_debug("✓ Inventário limpo: Player %d na rodada %d" % [player_id, round_id])

func clear_round_inventories(round_id: int):
	"""
	Limpa todos os inventários de uma rodada
	Chamado quando rodada termina
	"""
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

func get_equipped_items(round_id: int, player_id: int) -> Dictionary:
	"""Retorna dicionário de itens equipados"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	return inventory["equipped"].duplicate()

func has_item(round_id: int, player_id: int, item_name: String) -> bool:
	"""Verifica se jogador possui um item"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	return item_name in inventory["inventory"]

func is_item_equipped(round_id: int, player_id: int, item_name: String) -> bool:
	"""Verifica se item está equipado"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return false
	return item_name in inventory["equipped"].values()

func get_equipped_slot(round_id: int, player_id: int, item_name: String) -> String:
	"""Retorna slot onde item está equipado (ou "" se não equipado)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return ""
	
	for slot in inventory["equipped"]:
		if inventory["equipped"][slot] == item_name:
			return slot
	
	return ""

func get_inventory_count(round_id: int, player_id: int) -> int:
	"""Retorna quantidade de itens no inventário"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return 0
	return inventory["inventory"].size()

func is_inventory_full(round_id: int, player_id: int) -> bool:
	"""Verifica se inventário está cheio"""
	return get_inventory_count(round_id, player_id) >= max_inventory_slots

func get_inventory_stats(round_id: int, player_id: int) -> Dictionary:
	"""Retorna estatísticas do inventário (items_collected, items_used)"""
	var inventory = _get_player_inventory(round_id, player_id)
	if inventory.is_empty():
		return {}
	return inventory["stats"].duplicate()

# ===== GERENCIAMENTO DE NODES =====

func register_player_node(peer_id: int, player_node: Node):
	"""
	Registra referência ao node do jogador na cena
	Usado para localizar visualmente o jogador no mundo
	"""
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
	"""
	Retorna o node do jogador na cena
	Usa cache para otimização
	"""
	if not is_player_registered(peer_id):
		return null
	
	# Tenta cache primeiro
	if players_cache.has(peer_id):
		var cached_path = players_cache[peer_id]
		var node = get_node_or_null(cached_path)
		if node:
			return node
		else:
			# Cache desatualizado
			players_cache.erase(peer_id)
			_log_debug("⚠ Cache desatualizado para player %d" % peer_id)
	
	# Busca no registro principal
	var player_data = players[peer_id]
	var node_path = player_data.get("node_path", "")
	
	if node_path.is_empty():
		return null
	
	var player_node = get_node_or_null(node_path)
	
	if player_node:
		# Atualiza cache
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
	"""
	Retorna referência INTERNA do inventário (não duplica)
	Usar apenas internamente, nunca expor ao exterior
	"""
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

func debug_print_all_players():
	"""Imprime estado completo de todos os jogadores"""
	print("\n========== PLAYER REGISTRY ==========")
	print("Total de players: %d" % players.size())
	print("Registrados: %d" % get_registered_player_count())
	print("Cache de nodes: %d entradas" % players_cache.size())
	
	# Conta inventários
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
		
		# Node status
		var node_path = p["node_path"]
		if node_path.is_empty():
			print("  Node: (não registrado)")
		else:
			var node = get_node_or_null(node_path)
			var status = "✓ VÁLIDO" if node else "✗ INVÁLIDO"
			print("  Node: %s [%s]" % [node_path, status])
		
		# Inventários
		for round_id in player_inventories:
			if player_inventories[round_id].has(peer_id):
				var inv = player_inventories[round_id][peer_id]
				print("  Inventário [Rodada %d]: %d itens" % [round_id, inv["inventory"].size()])
	
	print("\n=====================================\n")

func _log_debug(message: String):
	"""Função padrão de debug"""
	if debug_mode:
		print("[PlayerRegistry] %s" % message)
