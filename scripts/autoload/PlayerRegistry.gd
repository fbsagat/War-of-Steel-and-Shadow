extends Node
## PlayerRegistry - Registro centralizado de jogadores (SERVIDOR APENAS)
## Gerencia informações de todos os jogadores conectados

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

var players: Dictionary = {}

# Estado de inicialização
var _is_server: bool = false
var _initialized: bool = false

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
	
	# PlayerRegistry NÃO DEVE ser usado no cliente!
	_is_server = false
	_initialized = true
	_log_debug("PlayerRegistry acessado como CLIENTE (operações bloqueadas)")

func reset():
	players.clear()
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
		"connected_at": Time.get_unix_time_from_system()
	}
	_log_debug("Peer adicionado: %d" % peer_id)

func remove_peer(peer_id: int):
	if not _is_server:
		return
	
	if players.has(peer_id):
		var player = players[peer_id]
		_log_debug("Peer removido: %d (%s)" % [peer_id, player["name"]])
		players.erase(peer_id)

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
	
	_log_debug("✓ Jogador registrado: %s (ID: %d)" % [player_name, peer_id])
	return true

func is_name_taken(player_name: String) -> bool:
	if not _is_server:
		return false  # ou true, para bloquear no cliente
	
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

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if _is_server else "[CLIENT]"
		print("[PlayerRegistry] %s %s" % [prefix, message])
