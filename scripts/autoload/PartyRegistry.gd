extends Node
## PartyRegistry - Gerenciador de estado de partidas/rodadas
## Autoload que controla o estado da partida atual

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true

# ===== VARIÁVEIS DE ESTADO =====

## Dados da partida atual (vazio quando não há partida ativa)
var current_party: Dictionary = {}

## Estado atual da partida
var party_state: String = "none"  # "none", "loading", "playing", "round_end"

## Próximo ID de partida
var next_party_id: int = 1

## Scores dos jogadores na partida atual
var scores: Dictionary = {}  # {peer_id: score}

## Referências importantes
var map_manager: Node = null
var spawned_players: Dictionary = {}  # {peer_id: Node}

# ===== SINAIS =====

signal party_created(party_data: Dictionary)
signal round_started(round_number: int)
signal round_ended(round_data: Dictionary)
signal party_ended()
signal player_scored(peer_id: int, new_score: int)

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	_log_debug("PartyRegistry inicializado")

# ===== GERENCIAMENTO DE PARTIDAS =====

## Cria uma nova partida
func create_party(room_id: int, map_scene: String, settings: Dictionary) -> Dictionary:
	if not current_party.is_empty():
		_log_debug("Já existe uma partida ativa!")
		return {}
	
	var party_id = next_party_id
	next_party_id += 1
	
	current_party = {
		"party_id": party_id,
		"room_id": room_id,
		"round_number": 1,
		"max_rounds": settings.get("max_rounds", 3),
		"map_scene": map_scene,
		"settings": settings,
		"players": [],
		"start_time": Time.get_ticks_msec() / 1000.0,
		"scores": {}
	}
	
	party_state = "loading"
	scores = {}
	
	_log_debug("✓ Partida criada: ID %d, Sala %d" % [party_id, room_id])
	party_created.emit(current_party)
	
	return current_party

## Adiciona jogadores à partida
func set_players(players: Array):
	if current_party.is_empty():
		return
	
	current_party["players"] = players
	
	# Inicializa scores
	for player in players:
		scores[player["id"]] = 0
		current_party["scores"][player["id"]] = 0
	
	_log_debug("Jogadores adicionados à partida: %d" % players.size())

## Inicia uma rodada
func start_round():
	if current_party.is_empty():
		return
	
	party_state = "playing"
	
	_log_debug("Rodada %d/%d iniciada" % [current_party["round_number"], current_party["max_rounds"]])
	round_started.emit(current_party["round_number"])

## Finaliza a rodada atual
func end_round(winner_data: Dictionary = {}):
	if current_party.is_empty():
		return
	
	party_state = "round_end"
	
	var round_data = {
		"round_number": current_party["round_number"],
		"winner": winner_data,
		"scores": scores.duplicate()
	}
	
	_log_debug("Rodada %d finalizada" % current_party["round_number"])
	round_ended.emit(round_data)
	
	return round_data

## Avança para a próxima rodada
func next_round():
	if current_party.is_empty():
		return false
	
	current_party["round_number"] += 1
	
	if current_party["round_number"] > current_party["max_rounds"]:
		return false  # Partida acabou
	
	party_state = "loading"
	_log_debug("Avançando para rodada %d" % current_party["round_number"])
	
	return true

## Finaliza a partida completamente
func end_party():
	if current_party.is_empty():
		return
	
	_log_debug("Partida finalizada: ID %d" % current_party["party_id"])
	
	# Limpa referências
	map_manager = null
	spawned_players.clear()
	
	current_party = {}
	party_state = "none"
	scores = {}
	
	party_ended.emit()

# ===== GERENCIAMENTO DE SCORES =====

## Adiciona pontos a um jogador
func add_score(peer_id: int, points: int):
	if not scores.has(peer_id):
		scores[peer_id] = 0
	
	scores[peer_id] += points
	current_party["scores"][peer_id] = scores[peer_id]
	
	_log_debug("Score atualizado: Peer %d = %d pontos" % [peer_id, scores[peer_id]])
	player_scored.emit(peer_id, scores[peer_id])

## Define score diretamente
func set_score(peer_id: int, score: int):
	scores[peer_id] = score
	current_party["scores"][peer_id] = score
	
	player_scored.emit(peer_id, score)

## Retorna o score de um jogador
func get_score(peer_id: int) -> int:
	return scores.get(peer_id, 0)

## Retorna todos os scores
func get_scores() -> Dictionary:
	return scores.duplicate()

## Retorna o jogador com maior score
func get_winner() -> Dictionary:
	if scores.is_empty():
		return {}
	
	var max_score = -999999
	var winner_id = 0
	
	for peer_id in scores:
		if scores[peer_id] > max_score:
			max_score = scores[peer_id]
			winner_id = peer_id
	
	# Busca dados do jogador
	for player in current_party.get("players", []):
		if player["id"] == winner_id:
			return {
				"id": winner_id,
				"name": player["name"],
				"score": max_score
			}
	
	return {}

# ===== GERENCIAMENTO DE SPAWN =====

## Retorna dados de spawn para um jogador
func get_player_spawn_data(peer_id: int) -> Dictionary:
	if current_party.is_empty():
		return {}
	
	# Encontra índice do jogador
	var player_index = 0
	for i in range(current_party["players"].size()):
		if current_party["players"][i]["id"] == peer_id:
			player_index = i
			break
	
	return {
		"spawn_index": player_index,
		"team": 0,  # Futuramente pode ter times
		"player_index": player_index
	}

## Registra um player spawnado
func register_spawned_player(peer_id: int, player_node: Node):
	spawned_players[peer_id] = player_node
	_log_debug("Player registrado no PartyRegistry: %d" % peer_id)

## Remove um player spawnado
func unregister_spawned_player(peer_id: int):
	if spawned_players.has(peer_id):
		spawned_players.erase(peer_id)
		_log_debug("Player removido do PartyRegistry: %d" % peer_id)

## Retorna um player spawnado
func get_spawned_player(peer_id: int) -> Node:
	return spawned_players.get(peer_id, null)

## Retorna todos os players spawnados
func get_all_spawned_players() -> Array:
	return spawned_players.values()

# ===== QUERIES DE ESTADO =====

## Verifica se há partida ativa
func is_party_active() -> bool:
	return not current_party.is_empty()

## Retorna o estado atual
func get_party_state() -> String:
	return party_state

## Retorna dados da partida atual
func get_current_party() -> Dictionary:
	return current_party.duplicate()

## Retorna o número da rodada atual
func get_current_round() -> int:
	return current_party.get("round_number", 0)

## Verifica se é a última rodada
func is_last_round() -> bool:
	if current_party.is_empty():
		return false
	
	return current_party["round_number"] >= current_party["max_rounds"]

## Retorna configurações da partida
func get_settings() -> Dictionary:
	return current_party.get("settings", {})

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[PartyRegistry] " + message)
