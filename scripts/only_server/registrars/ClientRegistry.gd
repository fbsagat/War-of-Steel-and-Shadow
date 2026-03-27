extends Node
class_name ClientRegistry
## ClientRegistry - Registro centralizado de jogadores (SERVIDOR APENAS)
## Gerencia informações de todos os jogadores conectados + Inventário por Rodada
##
## RESPONSABILIDADES:
## - Adicionar/remover peers conectados
## - Registrar nomes de jogadores
## - Gerenciar inventários por rodada
## - Rastrear em qual sala/rodada cada jogador está
## - Fornecer queries de localização de jogadores
##
## IDENTIFICAÇÃO:
## - uuid_base (String) é o identificador PRIMÁRIO e persistente do jogador
## - peer_id (int) é a sessão de rede atual, armazenada como campo e usada apenas para RPCs
## - Use get_uuid_by_peer_id() / get_peer_id_by_uuid() para conversões quando necessário

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true
@export var max_inventory_slots: int = 9 # Limite de itens por jogador

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var network_manager: NetworkManager = null
var server_manager: ServerManager = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null
var item_database: ItemDatabase = null
var debug_overlay = null
var initializer = null

# ===== VARIÁVEIS INTERNAS =====

## Dados completos dos jogadores: {uuid_base: PlayerData}
var players: Dictionary = {}

## Cache de NodePath para acesso rápido: {uuid_base: NodePath_string}
var players_cache: Dictionary = {}

## Inventários organizados por rodada: {round_id: {uuid_base: InventoryData}}
var player_inventories: Dictionary = {}

## Estado de inicialização
var _initialized: bool = false

## Próxima posição de entrada no servidor
var entry_position: int = 0

## Estados do cliente
enum ClientState {
	CONNECTING,     # Index: 0
	LOBBY,          # Index: 1
	LOADING,        # Index: 2
	IN_GAME,        # Index: 3
	RETURNING,      # Index: 4
	DISCONNECTED    # Index: 5
}
## Nomes dos estados
const CLIENT_STATE_NAMES = {
	ClientState.CONNECTING: "Connecting",
	ClientState.LOBBY: "Lobby",
	ClientState.LOADING: "Loading",
	ClientState.IN_GAME: "In_Game",
	ClientState.RETURNING: "Returning",
	ClientState.DISCONNECTED: "Disconnected",
}

# ===== SINAIS =====

# --- Sinais de Conexão ---
signal peer_added(uuid_base: String)
signal peer_connected(uuid_base: String)
signal peer_disconnected(uuid_base: String)
signal peer_removed(uuid_base: String)
signal player_name_registered(uuid_base: String, player_name: String)
signal peer_id_updated(uuid_base: String, new_peer_id: int)
signal peer_state_changed()

# --- Sinais de Localização ---
signal player_joined_room(uuid_base: String, room_id: int)
signal player_left_room(uuid_base: String, room_id: int)
signal player_joined_round(uuid_base: String, round_id: int)
signal player_left_round(uuid_base: String, round_id: int)

# ===== ESTRUTURAS DE DADOS =====

## PlayerData:
## {
##   "peer_id": int,          # Sessão de rede atual (muda a cada conexão)
##   "uuid_base": String,     # Identificador fixo e persistente (CHAVE PRIMÁRIA)
##   "connected": bool,
##   "entry_position": int,
##   "name": String,
##   "registered": bool,
##   "disconnected_at": float,
##   "room_id": int,          # -1 se não estiver em sala
##   "round_id": int,         # -1 se não estiver em rodada
##   "node_path": String
##   "ClientState": {CONNECTING, LOBBY, IN_GAME, RETURNING, DISCONNECTED}
## }

## InventoryData:
## {
##   "inventory": Array[Dictionary],  # Lista de {item_id: String, object_id: int}
##   "equipped": {
##     "hand-right": Dictionary,
##     "hand-left": Dictionary,
##     "head": Dictionary,
##     "body": Dictionary,
##     "back": Dictionary
##   }
## }

# ===== INICIALIZAÇÃO =====

func initialize():
	"""Inicializa o ClientRegistry (chamado apenas no servidor)"""
	if _initialized:
		_log_debug("⚠ ClientRegistry já inicializado")
		return

	_initialized = true
	_log_debug("▶️ ClientRegistry inicializado com sucesso!")

func reset():
	"""Reseta completamente o registro (usado ao desligar servidor)"""
	players.clear()
	players_cache.clear()
	player_inventories.clear()
	_initialized = false
	_log_debug("🔄 ClientRegistry resetado")

# ===== GERENCIAMENTO DE PEERS =====

func _get_next_position() -> int:
	entry_position += 1
	return entry_position

func add_peer(peer_id: int, uuid_base: String):
	"""Adiciona um novo peer conectado (ainda não registrado).
	uuid_base é obrigatório e será a chave primária do jogador."""
	if uuid_base.is_empty():
		push_error("ClientRegistry: Tentou adicionar peer %d sem uuid_base" % peer_id)
		return

	if players.has(uuid_base):
		_log_debug("⚠ UUID %s já existe, atualizando peer_id para %d" % [uuid_base, peer_id])
		players[uuid_base]["peer_id"] = peer_id
		return

	players[uuid_base] = {
		"peer_id": peer_id,
		"uuid_base": uuid_base,
		"entry_position": _get_next_position(),
		"name": "",
		"registered": false,
		"connected": false,
		"disconnected_at": Time.get_unix_time_from_system(),
		"room_id": -1,
		"round_id": -1,
		"node_path": "",
		"ClientState": ClientState.LOBBY
	}

	_log_debug("✓ Peer adicionado: uuid=%s peer_id=%d" % [uuid_base, peer_id])
	peer_added.emit(uuid_base)

func update_peer_id(uuid_base: String, new_peer_id: int):
	"""Atualiza peer_id quando jogador reconecta com nova sessão.
	Substitui o antigo update_player_id — sem necessidade de mover entradas."""
	if not players.has(uuid_base):
		push_error("ClientRegistry: UUID %s não encontrado para atualizar peer_id" % uuid_base)
		return

	var old_peer_id = players[uuid_base]["peer_id"]
	players[uuid_base]["peer_id"] = new_peer_id
	
	# Se o cliente ter um personagem ativo em um round, atualizar seu novo id para os outros clientes no round
	# Apenas os que estão conectados
	var round_id = in_round(uuid_base)
	if round_id:
		var round_ = get_players_in_round(round_id)
		for player_uuid in round_:
			# Se estiver conectado e não for o próprio,
			# _handle_request_return_or_exit já vai criar como novo session id.
			if players[player_uuid]["connected"] == true and player_uuid != uuid_base:
				var peer_id = get_peer_id_by_uuid(player_uuid)
				network_manager.rpc_id(peer_id, "_client_update_character_peer_id", uuid_base, new_peer_id)
				_log_debug("Enviando comando para cliente %s para atualizar session id de remoto de uuid: %s para este novo: %d" % [player_uuid, uuid_base, new_peer_id])
	
	# Atualizar também no round do servidor
	var node = get_player_node(uuid_base)
	if node:
		node.name = str(new_peer_id)
		node.player_id = new_peer_id
		
		# Se visual_debug true, atualiza name_label poir mudou o id de sessão (peer_id)
		# Se visual_debug false, não precisa atualizar pois o nome não muda na reconexão
		if server_manager.visual_debug:
			var start = uuid_base.substr(0, 4)
			var end = uuid_base.substr(uuid_base.length() - 4, 4)
			var player_name = get_player_name(uuid_base)
			node.name_label.text = "%s\n%s[...]%s\n%s" % [player_name, start, end, new_peer_id]
		
		# Atualizar o node path
		# pega o path do parent
		var parent_path := str(node.get_parent().get_path())
		# cria novo path com session_id no final
		var new_path := parent_path + "/" + str(new_peer_id)
		players[uuid_base]["node_path"] = new_path
		players_cache[uuid_base] = new_path
		_log_debug("Node path atualizado: %s, para este peer_id %d" % [new_path, new_peer_id])
		
	else:
		_log_debug("⚠ Servidor tentou atualizar o node deste player (%s) no servidor e não conseguiu" % uuid_base)
	
	_log_debug("✓ peer_id atualizado para %s: %d → %d" % [uuid_base, old_peer_id, new_peer_id])
	peer_id_updated.emit(uuid_base, new_peer_id)
	
func set_disconnected_peer(peer_id: int):
	"""Marca jogador como desconectado do servidor a partir do peer_id da sessão."""
	var uuid_base = get_uuid_by_peer_id(peer_id)
	if uuid_base.is_empty():
		_log_debug("⚠ Tentou desconectar peer inexistente: %d" % peer_id)
		return
	
	# Muda estado do jogador
	set_player_state(uuid_base, ClientState.DISCONNECTED)
	
	players[uuid_base]["connected"] = false
	players[uuid_base]["disconnected_at"] = Time.get_unix_time_from_system()
	set_disconnected_peer_from_room_and_round(peer_id)
	peer_disconnected.emit(uuid_base)

func set_disconnected_peer_from_room_and_round(peer_id: int, from_room: bool = true, from_round: bool = true):
	"""Marca jogador como desconectado de sala e round a partir do peer_id da sessão."""

	var uuid_base = get_uuid_by_peer_id(peer_id)
	if uuid_base.is_empty():
		_log_debug("⚠ Tentou desconectar peer inexistente: %d" % peer_id)
		return
		
	var room = get_player_room(uuid_base)
	if room > 0 and from_room:
		_log_debug("Definindo player como desconectado da sala em que está")
		room_registry._set_disconnected_peer(peer_id, room)
		
	var round_ = get_player_round(uuid_base)
	if round_ > 0 and from_round:
		_log_debug("Definindo player como desconectado da rodada em que está")
		round_registry._mark_player_disconnected(round_, uuid_base)

func remove_peer(peer_id: int):
	"""Remove jogador desconectado a partir do peer_id da sessão."""
	var uuid_base = get_uuid_by_peer_id(peer_id)
	if uuid_base.is_empty():
		_log_debug("⚠ Tentou remover peer inexistente: %d" % peer_id)
		return

	var player = players[uuid_base]
	var player_name = player["name"] if player["name"] else "sem_nome"

	if player["room_id"] != -1:
		_leave_room_internal(uuid_base)

	_cleanup_player_inventories(uuid_base)

	players.erase(uuid_base)
	players_cache.erase(uuid_base)

	_log_debug("✓ Peer removido: %d (%s / uuid=%s)" % [peer_id, player_name, uuid_base])
	peer_removed.emit(uuid_base)

func register_player_name(uuid_base: String, player_name: String) -> bool:
	"""Registra nome do jogador."""
	if not players.has(uuid_base):
		_log_debug("❌ Tentou registrar nome de UUID inexistente: %s" % uuid_base)
		return false

	players[uuid_base]["name"] = player_name
	players[uuid_base]["registered"] = true
	player_name_registered.emit(uuid_base, player_name)
	_log_debug("✓ Nome registrado: %s (uuid=%s)" % [player_name, uuid_base])
	return true

func _register_connection(uuid_base: String):
	"""Marca jogador como conectado."""
	if not players.has(uuid_base):
		_log_debug("❌ Tentou registrar conexão de UUID inexistente: %s" % uuid_base)
		return
	
	# muda estado do jogador
	set_player_state(uuid_base, ClientState.LOBBY)
	players[uuid_base]["connected"] = true
	players[uuid_base]["disconnected_at"] = 0.0
	_log_debug("Peer uuid=%s marcado como conectado" % uuid_base)
	
	# Remove do timout detection
	network_manager.remove_client_from_timeout_detection(uuid_base)
	
	# Sinal
	peer_connected.emit(uuid_base)
	
func _is_uuid_connected(uuid_base: String) -> bool:
	"""Verifica se já existe jogador com este uuid_base conectado"""
	if players.has(uuid_base):
		return players[uuid_base].get("connected", false)
	return false

func is_name_taken(player_name: String) -> bool:
	"""Verifica se um nome já está em uso."""
	var normalized_name = player_name.strip_edges().to_lower()
	for player in players.values():
		if player.has("name") and player["name"].strip_edges().to_lower() == normalized_name:
			return true
	return false

# ===== CONVERSÃO PEER_ID ↔ UUID_BASE =====

func get_uuid_by_peer_id(peer_id: int) -> String:
	"""Retorna uuid_base a partir do peer_id atual.
	Necessário para callbacks de rede que entregam peer_id.
	Complexidade O(n) — use com parcimônia em loops."""
	for uuid_base in players:
		if players[uuid_base]["peer_id"] == peer_id:
			return uuid_base
	return ""

func get_peer_id_by_uuid(uuid_base: String) -> int:
	"""Retorna peer_id atual a partir do uuid_base.
	Use este valor apenas para chamadas RPC (network_manager.rpc_id)."""
	if not players.has(uuid_base):
		return -1
	return players[uuid_base].get("peer_id", -1)

# ===== GERENCIAMENTO DE SALAS/RODADAS =====

func join_room(uuid_base: String, room_id: int):
	"""Marca jogador como dentro de uma sala."""
	if not players.has(uuid_base):
		push_error("ClientRegistry: UUID %s não existe para join_room" % uuid_base)
		return

	var player = players[uuid_base]

	if player["room_id"] != -1 and player["room_id"] != room_id:
		_leave_room_internal(uuid_base)

	player["room_id"] = room_id
	_log_debug("✓ %s entrou na sala %d" % [uuid_base, room_id])
	player_joined_room.emit(uuid_base, room_id)

func leave_room(uuid_base: String):
	"""Remove jogador da sala atual."""
	_leave_room_internal(uuid_base)

func _leave_room_internal(uuid_base: String):
	if not players.has(uuid_base):
		return

	var player = players[uuid_base]
	var old_room_id = player["room_id"]

	if old_room_id == -1:
		return
	
	# Tira do round tbm
	if player["round_id"] != -1:
		_leave_round_internal(uuid_base)

	player["room_id"] = -1
	_log_debug("✓ %s saiu da sala %d" % [uuid_base, old_room_id])
	player_left_room.emit(uuid_base, old_room_id)

func join_round(uuid_base: String, round_id: int):
	"""Marca jogador como dentro de uma rodada e inicializa inventário."""
	if not players.has(uuid_base):
		push_error("ClientRegistry: UUID %s não existe para join_round" % uuid_base)
		return

	var player = players[uuid_base]

	if player["round_id"] != -1 and player["round_id"] != round_id:
		_leave_round_internal(uuid_base)

	player["round_id"] = round_id
	init_player_inventory(round_id, uuid_base)

	_log_debug("✓ %s entrou na rodada %d" % [uuid_base, round_id])
	player_joined_round.emit(uuid_base, round_id)

func leave_round(uuid_base: String):
	"""Remove jogador da rodada atual."""
	_leave_round_internal(uuid_base)

func _leave_round_internal(uuid_base: String):
	if not players.has(uuid_base):
		return

	var player = players[uuid_base]
	var old_round_id = player["round_id"]

	if old_round_id == -1:
		return

	clear_player_inventory(old_round_id, uuid_base)
	player["round_id"] = -1

	_log_debug("✓ %s saiu da rodada %d" % [uuid_base, old_round_id])
	player_left_round.emit(uuid_base, old_round_id)

# ===== QUERIES DE LOCALIZAÇÃO =====

func in_room(uuid_base: String) -> bool:
	if not players.has(uuid_base):
		return false
	return players[uuid_base]["room_id"] != -1

func in_round(uuid_base: String) -> bool:
	if not players.has(uuid_base):
		return false
	return players[uuid_base]["round_id"] != -1

func get_player_room(uuid_base: String) -> int:
	if not players.has(uuid_base):
		return -1
	return players[uuid_base]["room_id"]

func get_player_round(uuid_base: String) -> int:
	if not players.has(uuid_base):
		return -1
	return players[uuid_base]["round_id"]

func get_players_in_room(room_id: int) -> Array:
	"""Retorna array de uuid_bases dos jogadores na sala."""
	var result = []
	for uuid_base in players:
		if players[uuid_base]["room_id"] == room_id:
			result.append(uuid_base)
	return result

func get_players_in_round(round_id: int) -> Array:
	"""Retorna array de uuid_bases dos jogadores na rodada."""
	var result = []
	for uuid_base in players:
		if players[uuid_base]["round_id"] == round_id:
			result.append(uuid_base)
	return result

# ===== QUERIES DE DADOS =====

func get_player(uuid_base: String) -> Dictionary:
	if not players.has(uuid_base):
		return {}
	return players[uuid_base].duplicate()

func get_player_state(uuid_base: String) -> int:
	if not players.has(uuid_base):
		return -1
	
	return players[uuid_base].get("ClientState", -1)

func get_player_state_name(uuid_base: String) -> String:
	if not players.has(uuid_base):
		return "UNKNOWN"
	
	var state: int = players[uuid_base].get("ClientState", -1)
	
	return CLIENT_STATE_NAMES.get(state, "UNKNOWN")

func set_player_state(uuid_base: String, new_state: int) -> bool:
	"""Modifica o estado do jogador
	Ex (exeterno/fora de client_registry): set_player_state(peer_id, client_registry.ClientState.RETURNING)"""
	
	# Verificar se existe
	if not players.has(uuid_base):
		return false
	
	var old_state: int = players[uuid_base]["ClientState"]
	
	# Evita mudança redundante
	if old_state == new_state:
		return false
	
	# Aplica mudança
	players[uuid_base]["ClientState"] = new_state
	
	peer_state_changed.emit()
	_log_debug("Mundano estado de player %s: %s → %s" % [uuid_base, str(old_state),str(new_state)])
	
	return true

func get_player_by_uuid(uuid_base: String) -> Dictionary:
	"""Alias de get_player() para compatibilidade explícita."""
	return get_player(uuid_base)

func get_player_name(uuid_base: String) -> String:
	if not players.has(uuid_base):
		return ""
	return players[uuid_base]["name"]

func get_short_uuid(uuid_base: String) -> String:
	if not players.has(uuid_base):
		return ""
	var player_uuid = players[uuid_base]["uuid_base"]
	var short: String = (
			"%s[...]%s" % [
				player_uuid.substr(0, 4),
				player_uuid.substr(player_uuid.length() - 4, 4)])
	return short

func is_player_registered(uuid_base: String) -> bool:
	if not players.has(uuid_base):
		return false
	return players[uuid_base]["registered"]

func get_all_players() -> Array:
	print("players.values(): " , players.values())
	return players.values().duplicate()

func get_all_players_uuid() -> Array:
	var uuids: Array = []
	for player in players.values():
		if player.has("uuid_base"):
			uuids.append(player["uuid_base"])
	return uuids

func get_player_count() -> int:
	return players.size()

func get_registered_player_count() -> int:
	var count = 0
	for player in players.values():
		if player["registered"]:
			count += 1
	return count

func get_connected_player_count() -> int:
	var count = 0
	for player in players.values():
		if player["connected"]:
			count += 1
	return count

# ===== SISTEMA DE INVENTÁRIO POR RODADA =====

func init_player_inventory(round_id: int, uuid_base: String) -> bool:
	"""Inicializa inventário do jogador em uma rodada específica."""

	if not is_player_registered(uuid_base):
		push_error("ClientRegistry: Tentou inicializar inventário de UUID %s não registrado" % uuid_base)
		return false

	if not player_inventories.has(round_id):
		player_inventories[round_id] = {}

	if player_inventories[round_id].has(uuid_base):
		_log_debug("⚠ Inventário de %s na rodada %d já existe" % [uuid_base, round_id])
		return true

	player_inventories[round_id][uuid_base] = {
		"inventory": [],
		"equipped": {
			"hand-right": {},
			"hand-left": {},
			"head": {},
			"body": {},
			"back": {}
		}
	}

	_log_debug("✓ Inventário inicializado: %s na rodada %d" % [uuid_base, round_id])
	return true

func add_item_to_inventory(round_id: int, uuid_base: String, item_id: String, object_id: int) -> bool:
	"""Adiciona item ao inventário do jogador."""
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		push_error("ClientRegistry: Inventário não encontrado: uuid=%s, rodada=%d" % [uuid_base, round_id])
		return false

	if inventory["inventory"].size() >= max_inventory_slots:
		_log_debug("⚠ Inventário cheio: %s" % uuid_base)
		return false

	if item_database and not item_database.item_exists_by_id(int(item_id)):
		push_error("ClientRegistry: Item inválido: %s" % item_id)
		return false

	var item_name = item_database.get_item_by_id(int(item_id)).to_dictionary()['name']
	inventory["inventory"].append({
		"item_id": item_id,
		"object_id": object_id
	})

	_log_debug("✓ Item adicionado: %s (ID: %s, Object: %d) → %s (Rodada %d)" % [item_name, item_id, object_id, uuid_base, round_id])

	var peer_id = get_peer_id_by_uuid(uuid_base)
	network_manager.rpc_id(peer_id, "_client_add_item_to_inventory", item_id, object_id)
	return true

func remove_item_from_inventory(round_id: int, uuid_base: String, object_id: int) -> bool:
	"""Remove item do inventário pelo object_id."""
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return false

	var idx = -1
	for i in range(inventory["inventory"].size()):
		if inventory["inventory"][i]["object_id"] == object_id:
			idx = i
			break

	if idx == -1:
		_log_debug("⚠ Item com object_id %d não encontrado no inventário de %s" % [object_id, uuid_base])
		return false

	var item_id = inventory["inventory"][idx]["item_id"]
	var item_name = item_database.get_item_by_id(int(item_id))["name"]
	inventory["inventory"].remove_at(idx)

	_log_debug("✓ Item removido: object_id=%d (%s) de %s (Rodada %d)" % [object_id, item_name, uuid_base, round_id])

	var peer_id = get_peer_id_by_uuid(uuid_base)
	network_manager.rpc_id(peer_id, "_client_remove_item_from_inventory", object_id)
	return true

func equip_item(round_id: int, uuid_base: String, item_name: String, object_id, slot: String = "") -> bool:
	"""Equipa item em um slot (detecta automaticamente se não especificado).
	Slots válidos: hand-right, hand-left, head, body, back"""
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return false

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

	if slot.is_empty():
		if item_database:
			slot = item_database.get_slot(item_name)
		if slot.is_empty():
			push_error("ClientRegistry: Não foi possível detectar slot para item: %s" % item_name)
			return false

	if not inventory["equipped"].has(slot):
		push_error("ClientRegistry: Slot inválido: %s" % slot)
		return false

	if item_database and not item_database.can_equip_in_slot(item_name, slot):
		push_error("ClientRegistry: Item %s não pode ser equipado em %s" % [item_name, slot])
		return false

	if not inventory["equipped"][slot].is_empty():
		unequip_item(round_id, uuid_base, slot)

	inventory["equipped"][slot] = item_data
	inventory["inventory"].remove_at(item_idx)

	_log_debug("✓ Item equipado: %s em %s (%s, Rodada %d)" % [item_name, slot, uuid_base, round_id])

	var peer_id = get_peer_id_by_uuid(uuid_base)
	network_manager.rpc_id(peer_id, "_client_equip_item", item_name, object_id, slot)
	return true

func unequip_item(round_id: int, uuid_base: String, slot: String, verify: bool = true) -> bool:
	"""Desequipa item de um slot e retorna ao inventário.
	verify=false: não verifica max_inventory_slots (usado quando item será dropado)."""
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return false

	if not inventory["equipped"].has(slot):
		push_error("ClientRegistry: Slot inválido: %s" % slot)
		return false

	var item_data = inventory["equipped"][slot]
	if item_data.is_empty():
		return false

	if verify and inventory["inventory"].size() >= max_inventory_slots:
		_log_debug("⚠ Inventário cheio, não pode desequipar item")
		return false

	var item_name = item_database.get_item_by_id(int(item_data["item_id"]))["name"]

	inventory["inventory"].append(item_data)
	inventory["equipped"][slot] = {}

	_log_debug("✓ Item desequipado: %s de %s (%s, Rodada %d)" % [item_name, slot, uuid_base, round_id])

	var peer_id = get_peer_id_by_uuid(uuid_base)
	network_manager.rpc_id(peer_id, "_client_unequip_item", item_data["item_id"], slot, verify)
	return true

func swap_equipped_item(round_id: int, uuid_base: String, new_item_name: String, inventory_item: Dictionary, equiped_item_id: int, target_slot: String) -> bool:
	"""Troca item equipado diretamente (desequipa antigo, equipa novo)."""
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return false

	if not inventory["equipped"].has(target_slot):
		push_error("ClientRegistry: Slot inválido para swap: %s" % target_slot)
		return false

	var old_item_data = inventory["equipped"][target_slot]
	if old_item_data.is_empty():
		push_error("ClientRegistry: Nenhum item equipado no slot %s para trocar" % target_slot)
		return false

	var new_item_idx = -1
	for i in range(inventory["inventory"].size()):
		if inventory["inventory"][i]["object_id"] == int(inventory_item["object_id"]):
			new_item_idx = i
			break

	if new_item_idx == -1:
		push_error("ClientRegistry: Item arrastado não encontrado no inventário de %s" % uuid_base)
		return false

	var new_item_data = inventory["inventory"][new_item_idx]

	inventory["inventory"].remove_at(new_item_idx)
	inventory["inventory"].append(old_item_data)
	inventory["equipped"][target_slot] = new_item_data

	var old_item_name = item_database.get_item_by_id(int(old_item_data["item_id"]))["name"]
	_log_debug("🔄 Item trocado: %s <-> %s em %s (%s, Rodada %d)" % [
		old_item_name, new_item_name, target_slot, uuid_base, round_id
	])

	var peer_id = get_peer_id_by_uuid(uuid_base)
	network_manager.rpc_id(peer_id, "_client_swap_equipped_item", new_item_name, inventory_item, equiped_item_id, target_slot)
	return true

func clear_player_inventory(round_id: int, uuid_base: String):
	"""Limpa inventário do jogador em uma rodada."""
	if not player_inventories.has(round_id):
		return

	if player_inventories[round_id].has(uuid_base):
		player_inventories[round_id].erase(uuid_base)
		_log_debug("✓ Inventário limpo: %s na rodada %d" % [uuid_base, round_id])

func clear_round_inventories(round_id: int):
	"""Limpa todos os inventários de uma rodada."""
	if not player_inventories.has(round_id):
		return

	var player_count = player_inventories[round_id].size()
	player_inventories.erase(round_id)
	_log_debug("✓ Inventários da rodada %d limpos (%d jogadores)" % [round_id, player_count])

# ===== QUERIES DE INVENTÁRIO =====

func get_player_inventory(round_id: int, uuid_base: String) -> Dictionary:
	return _get_player_inventory(round_id, uuid_base).duplicate(true)

func get_inventory_items(round_id: int, uuid_base: String) -> Array:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return []
	return inventory["inventory"].duplicate()

func get_inventory_item_names(round_id: int, uuid_base: String) -> Array:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return []
	var names = []
	for item_data in inventory["inventory"]:
		names.append(item_data["item_name"])
	return names

func get_equipped_items(round_id: int, uuid_base: String) -> Dictionary:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return {}
	return inventory["equipped"].duplicate()

func get_equipped_item_in_slot(round_id: int, uuid_base: String, slot: String) -> Dictionary:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return {}
	return inventory["equipped"].get(slot, {})

func get_equipped_item_name_in_slot(round_id: int, uuid_base: String, slot: String) -> String:
	var item_data = get_equipped_item_in_slot(round_id, uuid_base, slot)
	return item_data.get("item_name", "")

func get_all_player_items(round_id: int, uuid_base: String) -> Array:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return []
	var all_items = inventory["inventory"].duplicate()
	for item_data in inventory["equipped"].values():
		if not item_data.is_empty():
			all_items.append(item_data)
	return all_items

func get_all_player_item_names(round_id: int, uuid_base: String) -> Array:
	var all_items = get_all_player_items(round_id, uuid_base)
	var names = []
	for item_data in all_items:
		names.append(item_data["item_name"])
	return names

func has_item(round_id: int, uuid_base: String, object_id: int) -> bool:
	return has_item_in_inventory(round_id, uuid_base, object_id) or is_item_equipped(round_id, uuid_base, object_id)

func has_any_item(round_id: int, uuid_base: String) -> bool:
	var inventory = _get_player_inventory(round_id, uuid_base)
	return not inventory["inventory"].is_empty()

func has_item_in_inventory(round_id: int, uuid_base: String, object_id: int) -> bool:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return false
	for item_data in inventory["inventory"]:
		if int(item_data["object_id"]) == object_id:
			return true
	return false

func is_item_equipped(round_id: int, uuid_base: String, object_id: int) -> bool:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return false
	for item_data in inventory["equipped"].values():
		if not item_data.is_empty() and item_data["object_id"] == int(object_id):
			return true
	return false

func get_equipped_slot(round_id: int, uuid_base: String, item_name: String) -> String:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return ""
	for slot in inventory["equipped"]:
		var item_data = inventory["equipped"][slot]
		if not item_data.is_empty() and item_data["item_name"] == item_name:
			return slot
	return ""

func is_slot_empty(round_id: int, uuid_base: String, slot: String) -> bool:
	return get_equipped_item_in_slot(round_id, uuid_base, slot).is_empty()

func get_empty_slots(round_id: int, uuid_base: String) -> Array:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return []
	var empty = []
	for slot in inventory["equipped"]:
		if inventory["equipped"][slot].is_empty():
			empty.append(slot)
	return empty

func get_occupied_slots(round_id: int, uuid_base: String) -> Array:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return []
	var occupied = []
	for slot in inventory["equipped"]:
		if not inventory["equipped"][slot].is_empty():
			occupied.append(slot)
	return occupied

func get_inventory_count(round_id: int, uuid_base: String) -> int:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return 0
	return inventory["inventory"].size()

func get_equipped_count(round_id: int, uuid_base: String) -> int:
	var equipped = get_equipped_items(round_id, uuid_base)
	var count = 0
	for item_data in equipped.values():
		if not item_data.is_empty():
			count += 1
	return count

func get_total_item_count(round_id: int, uuid_base: String) -> int:
	return get_inventory_count(round_id, uuid_base) + get_equipped_count(round_id, uuid_base)

func is_inventory_full(round_id: int, uuid_base: String) -> bool:
	return get_inventory_count(round_id, uuid_base) >= max_inventory_slots

func get_inventory_space_left(round_id: int, uuid_base: String) -> int:
	return max(0, max_inventory_slots - get_inventory_count(round_id, uuid_base))

func has_any_equipped(round_id: int, uuid_base: String) -> bool:
	return get_equipped_count(round_id, uuid_base) > 0

func has_full_equipment(round_id: int, uuid_base: String) -> bool:
	return get_empty_slots(round_id, uuid_base).is_empty()

func get_item_by_object_id(round_id: int, uuid_base: String, object_id: int) -> Dictionary:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return {}
	for item_data in inventory["inventory"]:
		if item_data["object_id"] == object_id:
			return item_data.duplicate()
	for item_data in inventory["equipped"].values():
		if not item_data.is_empty() and item_data["object_id"] == object_id:
			return item_data.duplicate()
	return {}

# ===== QUERIES DE FACILITAÇÃO =====

func get_equipped_hand_items(round_id: int, uuid_base: String) -> Dictionary:
	return {
		"hand-left": get_equipped_item_in_slot(round_id, uuid_base, "hand-left"),
		"hand-right": get_equipped_item_in_slot(round_id, uuid_base, "hand-right")
	}

func has_weapon_equipped(round_id: int, uuid_base: String) -> bool:
	var left = get_equipped_item_in_slot(round_id, uuid_base, "hand-left")
	var right = get_equipped_item_in_slot(round_id, uuid_base, "hand-right")
	return not left.is_empty() or not right.is_empty()

func has_both_hands_equipped(round_id: int, uuid_base: String) -> bool:
	var left = get_equipped_item_in_slot(round_id, uuid_base, "hand-left")
	var right = get_equipped_item_in_slot(round_id, uuid_base, "hand-right")
	return not left.is_empty() and not right.is_empty()

func get_equipped_armor(round_id: int, uuid_base: String) -> Dictionary:
	return {
		"head": get_equipped_item_in_slot(round_id, uuid_base, "head"),
		"body": get_equipped_item_in_slot(round_id, uuid_base, "body")
	}

func has_armor_equipped(round_id: int, uuid_base: String) -> bool:
	var head = get_equipped_item_in_slot(round_id, uuid_base, "head")
	var body = get_equipped_item_in_slot(round_id, uuid_base, "body")
	return not head.is_empty() or not body.is_empty()

func has_shield_equipped(round_id: int, uuid_base: String) -> bool:
	var hand_left_data = get_equipped_item_in_slot(round_id, uuid_base, "hand-left")
	if hand_left_data.is_empty():
		return false
	if hand_left_data.has("item_id"):
		var item = item_database.get_item_by_id(int(hand_left_data["item_id"])).to_dictionary()
		return item["function"] == "defense"
	return false

func count_items_of_type(round_id: int, uuid_base: String, item_type: String) -> int:
	if not item_database:
		return 0
	var all_items = get_all_player_item_names(round_id, uuid_base)
	var count = 0
	for item_name in all_items:
		if item_database.get_type(item_name) == item_type:
			count += 1
	return count

func find_items_by_level(round_id: int, uuid_base: String, min_level: int = 1, max_level: int = 999) -> Array:
	if not item_database:
		return []
	var all_items = get_all_player_item_names(round_id, uuid_base)
	var result = []
	for item_name in all_items:
		var level = item_database.get_item_level(item_name)
		if level >= min_level and level <= max_level:
			result.append(item_name)
	return result

func get_first_equipped_item(round_id: int, uuid_base: String) -> Dictionary:
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		return {}
	var priority_order = ["hand-left", "hand-right", "body", "head", "back"]
	for slot in priority_order:
		var item_data = inventory["equipped"].get(slot, {})
		if not item_data.is_empty():
			return item_data.duplicate()
	return {}

# ===== GERENCIAMENTO DE NODES =====

func register_player_node(uuid_base: String, player_node: Node):
	"""Registra referência ao node do jogador na cena."""
	if not is_player_registered(uuid_base):
		push_error("ClientRegistry: Tentou registrar nó de UUID %s não registrado" % uuid_base)
		return

	if not player_node or not player_node.is_inside_tree():
		push_error("ClientRegistry: Tentou registrar nó inválido para uuid=%s" % uuid_base)
		return

	var node_path = str(player_node.get_path())
	players[uuid_base]["node_path"] = node_path
	players_cache[uuid_base] = node_path

	_log_debug("✓ Nó registrado: %s → %s" % [uuid_base, node_path])

func unregister_player_node(uuid_base: String):
	"""Remove referência ao node do jogador."""
	if not players.has(uuid_base):
		return

	players[uuid_base]["node_path"] = ""
	players_cache.erase(uuid_base)
	_log_debug("✓ Nó desregistrado: %s" % uuid_base)

func get_player_node(uuid_base: String) -> Node:
	"""Retorna o node do jogador na cena."""
	if not is_player_registered(uuid_base):
		return null

	if players_cache.has(uuid_base):
		var node = get_node_or_null(players_cache[uuid_base])
		if node:
			return node
		players_cache.erase(uuid_base)
		_log_debug("⚠ Cache desatualizado para %s" % uuid_base)

	var node_path = players[uuid_base].get("node_path", "")
	if node_path.is_empty():
		return null

	var player_node = get_node_or_null(node_path)
	if player_node:
		players_cache[uuid_base] = node_path
	else:
		_log_debug("⚠ Nó não encontrado: %s (%s)" % [node_path, uuid_base])

	return player_node

func has_player_node(uuid_base: String) -> bool:
	return get_player_node(uuid_base) != null

func get_player_node_path(uuid_base: String) -> String:
	if not players.has(uuid_base):
		return ""
	return players[uuid_base].get("node_path", "")

func clear_player_node_path(uuid_base: String):
	if not players.has(uuid_base):
		return ""
	players[uuid_base]["node_path"] = ""

# ===== FUNÇÕES INTERNAS =====

func _get_player_inventory(round_id: int, uuid_base: String) -> Dictionary:
	"""Retorna referência INTERNA do inventário (não duplica)."""
	if not player_inventories.has(round_id):
		return {}
	if not player_inventories[round_id].has(uuid_base):
		return {}
	return player_inventories[round_id][uuid_base]

func _cleanup_player_inventories(uuid_base: String):
	"""Remove inventários do jogador de todas as rodadas."""
	for round_id in player_inventories:
		if player_inventories[round_id].has(uuid_base):
			player_inventories[round_id].erase(uuid_base)

func _compute_token(uuid_base: String) -> String:
	"""Gera token HMAC-SHA256 baseado em server_secret + server_id + uuid_base."""
	var crypto = Crypto.new()
	var message = (server_manager.server_id + ":" + uuid_base).to_utf8_buffer()
	var hmac = crypto.hmac_digest(HashingContext.HASH_SHA256, server_manager.server_secret, message)
	return hmac.hex_encode()
	
func _validate_player_name(player_name: String) -> String:
	"""
	Valida nome do jogador
	Retorna string vazia se válido, mensagem de erro caso contrário
	"""
	var trimmed_name = player_name.strip_edges()
	
	if trimmed_name.is_empty():
		return "O nome não pode estar vazio"
	
	if trimmed_name.length() < 5:
		return "O nome deve ter pelo menos 5 caracteres"
	
	if trimmed_name.length() > 20:
		return "O nome deve ter no máximo 20 caracteres"
	
	var regex = RegEx.new()
	regex.compile("^[a-zA-Z0-9_ ]+$")
	if not regex.search(trimmed_name):
		return "O nome contém caracteres inválidos"
	
	if is_name_taken(trimmed_name):
		return "Este nome já está sendo usado"
	
	return ""

# ===== DEBUG =====

func debug_print_player_inventory(round_id: int, uuid_base: String):
	var inventory = _get_player_inventory(round_id, uuid_base)
	if inventory.is_empty():
		print("❌ Inventário não encontrado para uuid=%s na rodada %d" % [uuid_base, round_id])
		return

	var player_name = get_player_name(uuid_base)
	print("\n╔═══ INVENTÁRIO: %s (uuid=%s) - Rodada %d ═══╗" % [player_name, uuid_base, round_id])

	print("  [Inventário: %d/%d]" % [inventory["inventory"].size(), max_inventory_slots])
	if inventory["inventory"].is_empty():
		print("    (vazio)")
	else:
		for item_data in inventory["inventory"]:
			print("    - %s (ID: %s, Object: %d)" % [item_data.get("item_name","?"), item_data["item_id"], item_data["object_id"]])

	print("\n  [Equipados]")
	var has_equipped = false
	for slot in inventory["equipped"]:
		var item_data = inventory["equipped"][slot]
		if not item_data.is_empty():
			print("    %s: %s (ID: %s, Object: %d)" % [slot, item_data.get("item_name","?"), item_data["item_id"], item_data["object_id"]])
			has_equipped = true
	if not has_equipped:
		print("    (nenhum)")

	print("╚" + "═".repeat(50) + "╝\n")

func debug_print_all_players():
	print("\n========== PLAYER REGISTRY ==========")
	print("Total de players: %d" % players.size())
	print("Registrados: %d" % get_registered_player_count())
	print("Cache de nodes: %d entradas" % players_cache.size())

	var total_inventories = 0
	for round_id in player_inventories:
		total_inventories += player_inventories[round_id].size()
	print("Inventários ativos: %d" % total_inventories)
	print("-------------------------------------")

	for uuid_base in players:
		var p = players[uuid_base]
		print("\n[uuid=%s | peer_id=%d]" % [uuid_base, p.get("peer_id", -1)])
		print("  Nome: %s" % (p["name"] if p["name"] else "(sem nome)"))
		print("  Registrado: %s" % p["registered"])
		print("  Conectado: %s" % p["connected"])
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
			if player_inventories[round_id].has(uuid_base):
				var inv = player_inventories[round_id][uuid_base]
				print("  Inventário [Rodada %d]: %d itens, %d equipados" % [
					round_id,
					inv["inventory"].size(),
					get_equipped_count(round_id, uuid_base)
				])

	print("\n=====================================\n")

func _log_debug(message: String):
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "ClientRegistry" in initializer.selected:
		return
	print("[SERVER][ClientRegistry] %s" % message)
