extends Node
## PlayerRegistry - Registro centralizado de jogadores
## Gerencia informações de todos os jogadores conectados

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

## Dicionário com todos os jogadores: {peer_id: player_data}
var players: Dictionary = {}

# ===== GERENCIAMENTO DE JOGADORES =====

## Adiciona um novo peer (quando conecta)
func add_peer(peer_id: int):
	players[peer_id] = {
		"id": peer_id,
		"name": "",
		"registered": false,
		"connected_at": Time.get_unix_time_from_system()
	}
	_log_debug("Peer adicionado: %d" % peer_id)

## Remove um peer (quando desconecta)
func remove_peer(peer_id: int):
	if players.has(peer_id):
		var player = players[peer_id]
		_log_debug("Peer removido: %d (%s)" % [peer_id, player["name"]])
		players.erase(peer_id)

## Registra um jogador (associa nome ao peer)
func register_player(peer_id: int, player_name: String):
	if not players.has(peer_id):
		_log_debug("Tentativa de registrar jogador inexistente: %d" % peer_id)
		return false
	
	# Verifica se o nome já está em uso
	if is_name_taken(player_name):
		_log_debug("Nome já está em uso: %s" % player_name)
		return false
	
	players[peer_id]["name"] = player_name
	players[peer_id]["registered"] = true
	
	_log_debug("✓ Jogador registrado: %s (ID: %d)" % [player_name, peer_id])
	return true

## Verifica se um nome já está sendo usado
func is_name_taken(player_name: String) -> bool:
	var normalized_name = player_name.strip_edges().to_lower()
	
	for player in players.values():
		if player.has("name") and player["name"].strip_edges().to_lower() == normalized_name:
			return true
	
	return false

## Retorna dados de um jogador
func get_player(peer_id: int) -> Dictionary:
	if players.has(peer_id):
		return players[peer_id]
	return {}

## Retorna o nome de um jogador
func get_player_name(peer_id: int) -> String:
	if players.has(peer_id):
		return players[peer_id]["name"]
	return ""

## Verifica se um jogador está registrado
func is_player_registered(peer_id: int) -> bool:
	return players.has(peer_id) and players[peer_id]["registered"]

## Retorna lista de todos os jogadores
func get_all_players() -> Array:
	return players.values()

## Retorna número de jogadores conectados
func get_player_count() -> int:
	return players.size()

## Retorna número de jogadores registrados
func get_registered_player_count() -> int:
	var count = 0
	for player in players.values():
		if player["registered"]:
			count += 1
	return count

## Limpa todos os jogadores (útil ao reiniciar servidor)
func clear_all():
	_log_debug("Limpando todos os jogadores")
	players.clear()

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[PlayerRegistry] " + message)
