extends Node
## RoundRegistry - Gerenciador de rodadas individuais
## Cada rodada é uma instância de jogo dentro de uma sala
## Autoload compartilhado (servidor e clientes mantêm cópias sincronizadas)
##
## CICLO DE UMA RODADA:
## 1. create_round() - Cria nova rodada
## 2. start_round() - Inicia após spawns completos
## 3. [GAMEPLAY] - Rodada em andamento
## 4. end_round() - Finaliza por alguma razão
## 5. complete_round_end() - Limpa e volta à sala

# ===== CONFIGURAÇÕES =====

@export_category("Round Duration")
## Tempo máximo de uma rodada em segundos (0 = ilimitado)
@export var max_round_duration: float = 600.0
## Tempo de exibição de resultados antes de voltar à sala
@export var results_display_time: float = 5.0

@export_category("Auto-End Settings")
## Intervalo para verificar se todos desconectaram
@export var disconnect_check_interval: float = 2.0
## Se deve finalizar automaticamente quando todos desconectam
@export var auto_end_on_disconnect: bool = true

@export_category("Debug")
@export var debug_mode: bool = true

# ===== VARIÁVEIS DE ESTADO =====

## Dados da rodada atual (vazio quando não há rodada ativa)
var current_round: Dictionary = {}

## Estado atual da rodada
## Valores possíveis: "none", "loading", "playing", "ending", "results"
var round_state: String = "none"

## Próximo ID de rodada global (incrementa sempre)
var next_round_id: int = 1

## Referências importantes da rodada
var map_manager: Node = null
var spawned_players: Dictionary = {}  # {peer_id: Node}

## Timer para verificar desconexões
var disconnect_check_timer: Timer = null

## Timer para duração máxima da rodada
var round_duration_timer: Timer = null

# ===== SINAIS =====

## Emitido quando uma rodada é criada
signal round_created(round_data: Dictionary)

## Emitido quando a rodada inicia (players spawnados)
signal round_started(round_id: int)

## Emitido quando a rodada termina (antes de mostrar resultados)
signal round_ending(round_id: int, reason: String)

## Emitido quando a rodada foi finalizada (após resultados)
signal round_ended(round_data: Dictionary)

## Emitido quando todos os players desconectaram
signal all_players_disconnected(round_id: int)

## Emitido quando a duração máxima foi atingida
signal round_timeout(round_id: int)

# ===== INICIALIZAÇÃO =====

func _ready():
	_log_debug("RoundRegistry inicializado")
	
	# Cria timers apenas no servidor
	if multiplayer.is_server():
		_setup_disconnect_check_timer()
		_setup_round_duration_timer()

func _setup_disconnect_check_timer():
	"""Configura timer para verificar desconexões automáticas"""
	disconnect_check_timer = Timer.new()
	disconnect_check_timer.wait_time = disconnect_check_interval
	disconnect_check_timer.autostart = false
	disconnect_check_timer.one_shot = false
	add_child(disconnect_check_timer)
	disconnect_check_timer.timeout.connect(_check_all_disconnected)
	
	_log_debug("Timer de verificação de desconexão configurado")

func _setup_round_duration_timer():
	"""Configura timer para duração máxima da rodada"""
	round_duration_timer = Timer.new()
	round_duration_timer.one_shot = true
	round_duration_timer.autostart = false
	add_child(round_duration_timer)
	round_duration_timer.timeout.connect(_on_round_timeout)
	
	_log_debug("Timer de duração máxima configurado")

# ===== GERENCIAMENTO DE RODADAS =====

func create_round(room_id: int, room_name: String, players: Array, settings: Dictionary) -> Dictionary:
	"""
	Cria uma nova rodada
	
	@param room_id: ID da sala que está criando a rodada
	@param room_name: Nome da sala
	@param players: Array de dicionários {id, name, is_host}
	@param settings: Configurações customizadas da rodada
	@return: Dicionário com dados da rodada criada
	"""
	if not current_round.is_empty():
		push_warning("Já existe uma rodada ativa! Finalize antes de criar nova.")
		return {}
	
	var round_id = next_round_id
	next_round_id += 1
	
	# Cria estrutura da rodada
	current_round = {
		"round_id": round_id,
		"room_id": room_id,
		"room_name": room_name,
		"players": players.duplicate(),
		"settings": settings.duplicate(),
		"start_time": Time.get_unix_time_from_system(),
		"end_time": 0,
		"duration": 0.0,
		"winner": {},  # {peer_id, name, score}
		"scores": {},  # {peer_id: score}
		"events": [],  # Eventos da rodada (opcional)
		"disconnected_players": [],
		"end_reason": ""
	}
	
	# Inicializa scores de todos os players
	for player in players:
		current_round["scores"][player["id"]] = 0
	
	round_state = "loading"
	
	_log_debug("✓ Rodada criada: ID %d, Sala '%s', %d players" % [
		round_id, room_name, players.size()
	])
	
	round_created.emit(current_round.duplicate())
	
	return current_round.duplicate()

func start_round():
	"""
	Inicia a rodada (chamado após spawns estarem completos)
	"""
	if current_round.is_empty():
		push_error("Não há rodada para iniciar!")
		return
	
	round_state = "playing"
	
	# Inicia timer de duração máxima (se configurado e no servidor)
	if multiplayer.is_server() and max_round_duration > 0:
		round_duration_timer.wait_time = max_round_duration
		round_duration_timer.start()
		_log_debug("Timer de duração iniciado: %.1f segundos" % max_round_duration)
	
	# Inicia verificação de desconexão (só no servidor)
	if multiplayer.is_server() and disconnect_check_timer and auto_end_on_disconnect:
		disconnect_check_timer.start()
		_log_debug("Verificação de desconexão ativada")
	
	_log_debug("▶ Rodada %d INICIADA" % current_round["round_id"])
	round_started.emit(current_round["round_id"])

func end_round(reason: String = "completed", winner_data: Dictionary = {}) -> Dictionary:
	"""
	Finaliza a rodada (pode ser chamado por qualquer razão)
	
	@param reason: Razão do término ("completed", "timeout", "all_disconnected", etc)
	@param winner_data: Dados do vencedor (opcional)
	@return: Dados finais da rodada
	"""
	if current_round.is_empty():
		push_warning("Não há rodada ativa para finalizar!")
		return {}
	
	# Evita chamadas duplicadas
	if round_state == "ending" or round_state == "results":
		_log_debug("Rodada já está sendo finalizada, ignorando chamada duplicada")
		return current_round.duplicate()
	
	round_state = "ending"
	
	# Para timers
	if multiplayer.is_server():
		if disconnect_check_timer:
			disconnect_check_timer.stop()
		if round_duration_timer:
			round_duration_timer.stop()
	
	# Atualiza dados finais
	current_round["end_time"] = Time.get_unix_time_from_system()
	current_round["duration"] = current_round["end_time"] - current_round["start_time"]
	current_round["end_reason"] = reason
	
	# Define vencedor
	if winner_data.is_empty():
		winner_data = _calculate_winner()
	current_round["winner"] = winner_data
	
	_log_debug("⏹ Rodada %d FINALIZANDO | Razão: %s | Duração: %.1fs" % [
		current_round["round_id"],
		reason,
		current_round["duration"]
	])
	
	# Adiciona evento de término
	_add_event("round_ended", {"reason": reason, "winner": winner_data})
	
	round_ending.emit(current_round["round_id"], reason)
	
	# Muda para estado de resultados
	round_state = "results"
	
	return current_round.duplicate()

func complete_round_end() -> Dictionary:
	"""
	Completa a finalização da rodada (chamado após exibir resultados)
	Limpa o estado e prepara para próxima rodada
	
	@return: Dados finais da rodada
	"""
	if current_round.is_empty():
		return {}
	
	var final_data = current_round.duplicate()
	
	_log_debug("✓ Rodada %d FINALIZADA | Vencedor: %s" % [
		final_data["round_id"],
		final_data["winner"].get("name", "Nenhum")
	])
	
	round_ended.emit(final_data)
	
	# Limpa estado
	_cleanup_round()
	
	return final_data

func _cleanup_round():
	"""Limpa todos os dados e referências da rodada"""
	map_manager = null
	spawned_players.clear()
	current_round = {}
	round_state = "none"
	
	_log_debug("Rodada limpa da memória")

# ===== GERENCIAMENTO DE PLAYERS =====

func register_spawned_player(peer_id: int, player_node: Node):
	"""
	Registra um player spawnado na rodada
	
	@param peer_id: ID do peer do jogador
	@param player_node: Nó do player na cena
	"""
	spawned_players[peer_id] = player_node
	_log_debug("Player %d registrado na rodada" % peer_id)

func unregister_spawned_player(peer_id: int):
	"""
	Remove registro de um player spawnado
	
	@param peer_id: ID do peer do jogador
	"""
	if spawned_players.has(peer_id):
		spawned_players.erase(peer_id)
		_log_debug("Player %d removido da rodada" % peer_id)

func mark_player_disconnected(peer_id: int):
	"""
	Marca um player como desconectado durante a rodada
	
	@param peer_id: ID do peer do jogador
	"""
	if current_round.is_empty():
		return
	
	if peer_id not in current_round["disconnected_players"]:
		current_round["disconnected_players"].append(peer_id)
		_log_debug("Player %d marcado como desconectado na rodada" % peer_id)
		
		# Adiciona evento
		_add_event("player_disconnected", {"peer_id": peer_id})

func get_spawned_player(peer_id: int) -> Node:
	"""
	Retorna o nó de um player spawnado
	
	@param peer_id: ID do peer do jogador
	@return: Nó do player ou null
	"""
	return spawned_players.get(peer_id, null)

func get_all_spawned_players() -> Array:
	"""
	Retorna array com todos os nós de players spawnados
	
	@return: Array de Nodes
	"""
	return spawned_players.values()

func get_active_players() -> Array:
	"""
	Retorna players ativos (não desconectados)
	
	@return: Array de dicionários {id, name, is_host}
	"""
	var active = []
	for player_data in current_round.get("players", []):
		if player_data["id"] not in current_round.get("disconnected_players", []):
			active.append(player_data)
	return active

# ===== SISTEMA DE PONTUAÇÃO =====

func add_score(peer_id: int, points: int):
	"""
	Adiciona pontos a um jogador
	
	@param peer_id: ID do peer do jogador
	@param points: Pontos a adicionar (pode ser negativo)
	"""
	if current_round.is_empty():
		return
	
	if not current_round["scores"].has(peer_id):
		current_round["scores"][peer_id] = 0
	
	current_round["scores"][peer_id] += points
	
	_log_debug("Score atualizado: Player %d = %d pontos (+%d)" % [
		peer_id, current_round["scores"][peer_id], points
	])
	
	# Adiciona evento
	_add_event("score_changed", {
		"peer_id": peer_id,
		"points": points,
		"total": current_round["scores"][peer_id]
	})

func set_score(peer_id: int, score: int):
	"""
	Define o score de um jogador diretamente
	
	@param peer_id: ID do peer do jogador
	@param score: Novo score
	"""
	if current_round.is_empty():
		return
	
	current_round["scores"][peer_id] = score
	_log_debug("Score definido: Player %d = %d pontos" % [peer_id, score])
	
	_add_event("score_set", {"peer_id": peer_id, "score": score})

func get_score(peer_id: int) -> int:
	"""
	Retorna o score de um jogador
	
	@param peer_id: ID do peer do jogador
	@return: Score atual
	"""
	if current_round.is_empty():
		return 0
	return current_round["scores"].get(peer_id, 0)

func get_scores() -> Dictionary:
	"""
	Retorna todos os scores
	
	@return: Dicionário {peer_id: score}
	"""
	if current_round.is_empty():
		return {}
	return current_round["scores"].duplicate()

func _calculate_winner() -> Dictionary:
	"""
	Calcula e retorna o vencedor baseado nos scores
	
	@return: Dicionário {peer_id, name, score} ou vazio se não houver vencedor
	"""
	if current_round.is_empty() or current_round["scores"].is_empty():
		return {}
	
	var max_score = -999999
	var winner_id = 0
	
	# Encontra maior score
	for peer_id in current_round["scores"]:
		if current_round["scores"][peer_id] > max_score:
			max_score = current_round["scores"][peer_id]
			winner_id = peer_id
	
	# Busca dados do jogador
	for player in current_round.get("players", []):
		if player["id"] == winner_id:
			return {
				"peer_id": winner_id,
				"name": player["name"],
				"score": max_score
			}
	
	return {}

# ===== EVENTOS DA RODADA =====

func _add_event(event_type: String, event_data: Dictionary = {}):
	"""
	Adiciona um evento ao histórico da rodada
	
	@param event_type: Tipo do evento
	@param event_data: Dados adicionais do evento
	"""
	if current_round.is_empty():
		return
	
	var event = {
		"type": event_type,
		"timestamp": Time.get_unix_time_from_system(),
		"data": event_data
	}
	
	current_round["events"].append(event)

func get_events() -> Array:
	"""
	Retorna todos os eventos da rodada
	
	@return: Array de eventos
	"""
	if current_round.is_empty():
		return []
	return current_round["events"].duplicate()

# ===== VERIFICAÇÕES AUTOMÁTICAS (APENAS SERVIDOR) =====

func _check_all_disconnected():
	"""
	Verifica se todos os players desconectaram
	Chamado periodicamente pelo timer
	"""
	if not multiplayer.is_server():
		return
	
	if current_round.is_empty() or round_state != "playing":
		return
	
	var active = get_active_players()
	
	if active.is_empty():
		_log_debug("⚠ Todos os players desconectaram!")
		all_players_disconnected.emit(current_round["round_id"])
		
		# Finaliza rodada automaticamente
		end_round("all_disconnected")

func _on_round_timeout():
	"""
	Callback quando o tempo máximo da rodada é atingido
	"""
	if not multiplayer.is_server():
		return
	
	_log_debug("⏱ Tempo máximo da rodada atingido!")
	round_timeout.emit(current_round["round_id"])
	
	# Finaliza rodada por timeout
	end_round("timeout")

# ===== QUERIES DE ESTADO =====

func is_round_active() -> bool:
	"""Verifica se há rodada ativa"""
	return not current_round.is_empty()

func get_round_state() -> String:
	"""Retorna o estado atual da rodada"""
	return round_state

func get_current_round() -> Dictionary:
	"""Retorna dados da rodada atual"""
	return current_round.duplicate()

func get_round_id() -> int:
	"""Retorna ID da rodada atual (0 se não houver)"""
	return current_round.get("round_id", 0)

func get_round_duration() -> float:
	"""
	Retorna duração da rodada em segundos
	Se ainda estiver em andamento, retorna o tempo decorrido
	"""
	if current_round.is_empty():
		return 0.0
	
	if round_state == "playing":
		return Time.get_unix_time_from_system() - current_round["start_time"]
	else:
		return current_round.get("duration", 0.0)

func get_time_remaining() -> float:
	"""
	Retorna tempo restante da rodada
	-1.0 se for ilimitado
	"""
	if max_round_duration <= 0:
		return -1.0
	
	if not round_duration_timer or not round_duration_timer.is_inside_tree():
		return -1.0
	
	return round_duration_timer.time_left

func get_settings() -> Dictionary:
	"""Retorna configurações da rodada"""
	return current_round.get("settings", {})

func get_total_players() -> int:
	"""Retorna número total de players (incluindo desconectados)"""
	return current_round.get("players", []).size()

func get_active_player_count() -> int:
	"""Retorna número de players ativos"""
	return get_active_players().size()

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		var prefix = "[SERVER]" if multiplayer.is_server() else "[CLIENT]"
		print("[RoundRegistry] %s %s" % [prefix, message])
