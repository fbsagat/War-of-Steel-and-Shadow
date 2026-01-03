extends Node
class_name RoundRegistry
## RoundRegistry - Gerenciador de rodadas/partidas (SERVIDOR APENAS)
## Rodadas são partidas ativas jogadas dentro de salas
##
## RESPONSABILIDADES:
## - Criar/iniciar rodadas
## - Gerenciar estado da rodada (loading, playing, ending, results)
## - Controlar timer de duração máxima
## - Detectar desconexões e finalizar automaticamente se necessário
## - Rastrear jogadores spawnados na cena
## - Registrar eventos da rodada
## - Finalizar rodada e enviar dados para RoomRegistry

# ===== CONFIGURAÇÕES =====

@export_group("Round Duration")
@export var max_round_duration: float = 600.0  # 10 minutos
@export var results_display_time: float = 5.0

@export_group("Auto-End Settings")
@export var disconnect_check_interval: float = 2.0  # Verifica a cada 2s
@export var auto_end_on_all_disconnected: bool = true

@export_group("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var player_registry = null
var room_registry = null
var object_manager = null

# ===== VARIÁVEIS INTERNAS =====

## Dicionário de todas as rodadas ativas: {round_id: RoundData}
var rounds: Dictionary = {}

## Timer global para verificar desconexões
var disconnect_check_timer: Timer = null

# Estado de inicialização
var _initialized: bool = false

# ===== SINAIS =====

signal round_created(round_data: Dictionary)
signal round_started(round_id: int)
signal round_ending(round_id: int, reason: String)
signal round_ended(round_data: Dictionary)
signal all_players_disconnected(round_id: int)
signal round_timeout(round_id: int)
signal player_spawned_in_round(round_id: int, peer_id: int, player_node: Node)
signal player_despawned_from_round(round_id: int, peer_id: int)

# ===== ESTRUTURAS DE DADOS =====

## RoundData:
## {
##   "round_id": int,
##   "room_id": int,
##   "room_name": String,
##   "players": Array[PlayerInRound],  # [{id, name}]
##   "settings": Dictionary,  # Configurações da partida (mapa, etc)
##   "start_time": float,
##   "end_time": float,
##   "duration": float,
##   "winner": Dictionary,  # {id, name, score}
##   "scores": Dictionary,  # {peer_id: score}
##   "events": Array[Event],  # Histórico de eventos
##   "disconnected_players": Array[int],  # peer_ids desconectados
##   "end_reason": String,  # "completed", "timeout", "all_disconnected"
##   "state": String,  # "loading", "playing", "ending", "results"
##   "map_manager": Node,  # Referência ao gerenciador de mapa
##   "round_node": Node, # Referência ao node do round atual
##   "spawned_players": Dictionary,  # {peer_id: Node}
##   "round_timer": Timer  # Timer específico desta rodada
## }

## Event:
## {
##   "type": String,
##   "timestamp": float,
##   "data": Dictionary
## }

# ===== INICIALIZAÇÃO =====

func initialize():
	"""Inicializa o RoundRegistry (chamado apenas no servidor)"""
	if _initialized:
		_log_debug("⚠ RoundRegistry já inicializado")
		return
	
	_setup_global_timers()
	_initialized = true
	_log_debug("✓ RoundRegistry inicializado")

func reset():
	"""Reseta completamente o registro (usado ao desligar servidor)"""
	# Para e remove timer global
	if disconnect_check_timer:
		disconnect_check_timer.stop()
		if disconnect_check_timer.is_inside_tree():
			remove_child(disconnect_check_timer)
		disconnect_check_timer.queue_free()
		disconnect_check_timer = null
	
	# Limpa todas as rodadas (e seus timers)
	for round_id in rounds.keys():
		_cleanup_round(round_id)
	
	rounds.clear()
	_initialized = false
	_log_debug("🔄 RoundRegistry resetado")

func _setup_global_timers():
	"""Cria timer global de verificação de desconexões"""
	disconnect_check_timer = Timer.new()
	disconnect_check_timer.wait_time = disconnect_check_interval
	disconnect_check_timer.autostart = false
	disconnect_check_timer.one_shot = false
	disconnect_check_timer.timeout.connect(_check_all_disconnected)
	add_child(disconnect_check_timer)

# ===== GERENCIAMENTO DE RODADAS =====

func create_round(room_id: int, room_name: String, players: Array, settings: Dictionary) -> Dictionary:
	"""
	Cria nova rodada (mas não inicia ainda)
	Retorna RoundData completo ou {} se falhar
	
	IMPORTANTE: Não spawna jogadores nem inicia timer aqui!
	Isso é feito em start_round()
	"""
	var round_id = _get_next_round_id()
	
	# Valida sala
	if not room_registry or not room_registry.room_exists(room_id):
		push_error("RoundRegistry: Sala %d não existe" % room_id)
		return {}
	
	# Valida jogadores
	if players.is_empty():
		push_error("RoundRegistry: Tentou criar rodada sem jogadores")
		return {}
	
	# Cria estrutura da rodada
	var round_data = {
		"round_id": round_id,
		"room_id": room_id,
		"room_name": room_name,
		"players": players.duplicate(true),
		"settings": settings.duplicate(true),
		"start_time": Time.get_unix_time_from_system(),
		"end_time": 0,
		"duration": 0.0,
		"winner": {},
		"scores": {},
		"events": [],
		"disconnected_players": [],
		"end_reason": "",
		"state": "loading",  # Estados: loading -> playing -> ending -> results
		"round_node": null,
		"map_manager": null,
		"spawned_players": {},
		"round_timer": null
	}
	
	# Inicializa scores zerados
	for player in players:
		round_data["scores"][player["id"]] = 0
	
	# Gerar configurações do Terrain3D
	
	# Gerar configurações do Sky3D
	round_data["settings"]["sky_rand_configs"] = sky3d_config_generator()
	
	# Armazena rodada
	rounds[round_id] = round_data
	
	# Registra jogadores na rodada (PlayerRegistry)
	if player_registry:
		for player in players:
			player_registry.join_round(player["id"], round_id)
	
	_log_debug("✓ Rodada criada: ID %d, Sala '%s', %d players" % [round_id, room_name, players.size()])
	_add_event(round_id, "round_created", {"room_id": room_id})
	round_created.emit(round_data.duplicate(true))
	
	return round_data.duplicate(true)

# Em RoundRegistry.gd
func set_round_node(round_id: int, node: Node):
	"""Define o nó da cena para uma rodada existente"""
	if not rounds.has(round_id):
		push_error("RoundRegistry: Rodada %d não existe" % round_id)
		return false
	rounds[round_id]["round_node"] = node
	_log_debug("Nó da rodada %d definido: %s" % [round_id, node.name])
	return true

func start_round(round_id: int):
	"""
	Inicia rodada (muda estado para 'playing')
	Ativa timer de duração e verificação de desconexões
	
	Chamado DEPOIS de spawnar todos os jogadores na cena
	"""
	if not rounds.has(round_id):
		push_error("RoundRegistry: Rodada %d não existe" % round_id)
		return
	
	var round_data = rounds[round_id]
	
	if round_data["state"] != "loading":
		_log_debug("⚠ Rodada %d já foi iniciada (estado: %s)" % [round_id, round_data["state"]])
		return
	
	# Muda estado
	round_data["state"] = "playing"
	round_data["start_time"] = Time.get_unix_time_from_system()
	
	# Cria timer de duração específico para esta rodada
	if max_round_duration > 0:
		var round_timer = Timer.new()
		round_timer.wait_time = max_round_duration
		round_timer.autostart = false
		round_timer.one_shot = true
		round_timer.timeout.connect(_on_round_timeout.bind(round_id))
		add_child(round_timer)
		round_data["round_timer"] = round_timer
		round_timer.start()
		_log_debug("  Timer de duração: %.1fs" % max_round_duration)
	
	# Ativa verificação global de desconexão
	if disconnect_check_timer and not disconnect_check_timer.is_stopped():
		disconnect_check_timer.start()
	
	_log_debug("▶ Rodada %d INICIADA" % round_id)
	_add_event(round_id, "round_started", {})
	round_started.emit(round_id)

func end_round(round_id: int, reason: String = "completed", winner_data: Dictionary = {}) -> Dictionary:
	"""
	Finaliza rodada (muda estado para 'ending')
	Não remove da memória ainda, apenas marca como finalizada
	
	reason pode ser: "completed", "timeout", "all_disconnected"
	"""
	if not rounds.has(round_id):
		_log_debug("⚠ Tentou finalizar rodada inexistente: %d" % round_id)
		return {}
	
	var round_data = rounds[round_id]
	
	# Evita finalizar múltiplas vezes
	if round_data["state"] == "ending" or round_data["state"] == "results":
		_log_debug("⚠ Rodada %d já está finalizando/finalizada" % round_id)
		return round_data.duplicate(true)
	
	# Muda estado
	round_data["state"] = "ending"
	
	# Para timer da rodada
	if round_data["round_timer"]:
		round_data["round_timer"].stop()
		round_data["round_timer"].queue_free()
		round_data["round_timer"] = null
	
	# Registra dados finais
	round_data["end_time"] = Time.get_unix_time_from_system()
	round_data["duration"] = round_data["end_time"] - round_data["start_time"]
	round_data["end_reason"] = reason
	round_data["winner"] = winner_data.duplicate(true)
	
	_log_debug("⏹ Rodada %d FINALIZANDO | Razão: %s | Duração: %.1fs" % [
		round_id, reason, round_data["duration"]
	])
	
	_add_event(round_id, "round_ended", {
		"reason": reason,
		"winner": winner_data,
		"duration": round_data["duration"]
	})
	
	round_ending.emit(round_id, reason)
	
	return round_data.duplicate(true)

func complete_round_end(round_id: int) -> Dictionary:
	"""
	Completa finalização da rodada (muda estado para 'results')
	Adiciona ao histórico da sala e limpa recursos
	
	Chamado DEPOIS de mostrar resultados na UI
	"""
	if not rounds.has(round_id):
		return {}
	
	var round_data = rounds[round_id]
	
	if round_data["state"] != "ending":
		_log_debug("⚠ Rodada %d não está no estado 'ending'" % round_id)
		return round_data.duplicate(true)
	
	# Muda para estado final
	round_data["state"] = "results"
	
	# Adiciona ao histórico da sala
	if room_registry:
		room_registry.add_round_to_history(round_data["room_id"], round_data)
	
	# Remove jogadores da rodada (PlayerRegistry)
	if player_registry:
		for player in round_data["players"]:
			player_registry.leave_round(player["id"])
			# Limpa inventário
			player_registry.clear_player_inventory(round_id, player["id"])
	
	_log_debug("✓ Rodada %d FINALIZADA" % round_id)
	round_ended.emit(round_data.duplicate(true))
	
	# Limpa rodada da memória
	var final_data = round_data.duplicate(true)
	_cleanup_round(round_id)
	
	return final_data

func _cleanup_round(round_id: int):
	"""
	Limpa todos os recursos da rodada
	Remove timer, limpa referências, apaga da memória
	"""
	if not rounds.has(round_id):
		return
	
	var round_data = rounds[round_id]
	
	# Remove timer se existir
	if round_data["round_timer"] and is_instance_valid(round_data["round_timer"]):
		round_data["round_timer"].stop()
		if round_data["round_timer"].is_inside_tree():
			remove_child(round_data["round_timer"])
		round_data["round_timer"].queue_free()
	
	# Limpa referências
	round_data["map_manager"] = null
	round_data["map_manager"] = null
	round_data["spawned_players"].clear()
	round_data["round_timer"] = null
	
	# Remove da memória
	rounds.erase(round_id)
	
	# Para verificação de desconexão se não houver mais rodadas
	if rounds.is_empty() and disconnect_check_timer:
		disconnect_check_timer.stop()

func cleanup_inactive_rounds():
	var current_time = Time.get_ticks_msec() / 1000.0
	var inactive_threshold = 30.0  # segundos
	
	for round_id in rounds.keys():
		var last_activity = rounds[round_id].last_activity
		if current_time - last_activity > inactive_threshold:
			_log_debug("Round %d inativo por >%.1fs. Limpando..." % [round_id, inactive_threshold])
			end_round(round_id)  # Dispara cleanup completo

# ===== GERENCIAMENTO DE PLAYERS SPAWNADOS =====

func register_spawned_player(round_id: int, peer_id: int, player_node: Node):
	"""
	Registra player que foi spawnado na cena da rodada
	Usado para rastrear e destruir nodes depois
	"""
	if not rounds.has(round_id):
		push_error("RoundRegistry: Tentou registrar player em rodada inexistente: %d" % round_id)
		return
	
	rounds[round_id]["spawned_players"][peer_id] = player_node
	
	_log_debug("✓ Player %d spawnado na rodada %d" % [peer_id, round_id])
	player_spawned_in_round.emit(round_id, peer_id, player_node)

func unregister_spawned_player(round_id: int, peer_id: int):
	"""
	Remove registro de player spawnado
	Chamado quando player é removido da cena
	"""
	if not rounds.has(round_id):
		return
	
	if rounds[round_id]["spawned_players"].has(peer_id):
		rounds[round_id]["spawned_players"].erase(peer_id)
		_log_debug("✓ Player %d despawnado da rodada %d" % [peer_id, round_id])
		player_despawned_from_round.emit(round_id, peer_id)

func mark_player_disconnected(round_id: int, peer_id: int):
	"""
	Marca player como desconectado durante a rodada
	NÃO remove da rodada, apenas registra desconexão
	"""
	if not rounds.has(round_id):
		return
	
	var round_data = rounds[round_id]
	
	if peer_id in round_data["disconnected_players"]:
		return  # Já está marcado
	
	round_data["disconnected_players"].append(peer_id)
	_add_event(round_id, "player_disconnected", {"peer_id": peer_id})
	_log_debug("⚠ Player %d marcado como desconectado na rodada %d" % [peer_id, round_id])

func get_spawned_player(round_id: int, peer_id: int) -> Node:
	"""Retorna node do player spawnado (ou null se não encontrado)"""
	if not rounds.has(round_id):
		return null
	return rounds[round_id]["spawned_players"].get(peer_id, null)

func get_all_spawned_players(round_id: int) -> Array:
	"""Retorna array com todos os nodes de players spawnados"""
	if not rounds.has(round_id):
		return []
	return rounds[round_id]["spawned_players"].values()

func get_active_players(round_id: int) -> Array:
	"""
	Retorna lista de PlayerData dos jogadores ATIVOS (não desconectados)
	"""
	if not rounds.has(round_id):
		return []
	
	var round_data = rounds[round_id]
	var active = []
	
	for player_data in round_data["players"]:
		if player_data["id"] not in round_data["disconnected_players"]:
			active.append(player_data)
	
	return active

func get_active_players_ids(round_id: int) -> Array:
	"""
	Retorna lista de PlayerData dos jogadores ATIVOS (não desconectados)
	"""
	if not rounds.has(round_id):
		return []
	
	var round_data = rounds[round_id]
	var active = []
	
	for player_data in round_data["players"]:
		if player_data["id"] not in round_data["disconnected_players"]:
			active.append(player_data["id"])
	
	return active

func get_active_player_count(round_id: int) -> int:
	"""Retorna quantidade de jogadores ativos (não desconectados)"""
	return get_active_players(round_id).size()

# ===== EVENTOS DA RODADA =====

func add_event(round_id: int, event_type: String, event_data: Dictionary = {}):
	"""
	Adiciona evento ao histórico da rodada
	Útil para debug e análise posterior
	"""
	_add_event(round_id, event_type, event_data)

func _add_event(round_id: int, event_type: String, event_data: Dictionary = {}):
	"""Implementação interna de adicionar evento"""
	if not rounds.has(round_id):
		return
	
	var round_data = rounds[round_id]
	var event = {
		"type": event_type,
		"timestamp": Time.get_unix_time_from_system(),
		"data": event_data.duplicate(true)
	}
	
	round_data["events"].append(event)

func get_events(round_id: int) -> Array:
	"""Retorna histórico completo de eventos da rodada"""
	if not rounds.has(round_id):
		return []
	return rounds[round_id]["events"].duplicate(true)

func get_events_of_type(round_id: int, event_type: String) -> Array:
	"""Retorna apenas eventos de um tipo específico"""
	var filtered = []
	for event in get_events(round_id):
		if event["type"] == event_type:
			filtered.append(event)
	return filtered

# ===== PONTUAÇÃO =====

func set_player_score(round_id: int, peer_id: int, score: int):
	"""Define pontuação de um jogador"""
	if not rounds.has(round_id):
		return
	
	rounds[round_id]["scores"][peer_id] = score
	_add_event(round_id, "score_updated", {"peer_id": peer_id, "score": score})

func add_player_score(round_id: int, peer_id: int, points: int):
	"""Adiciona pontos à pontuação atual do jogador"""
	if not rounds.has(round_id):
		return
	
	var current = rounds[round_id]["scores"].get(peer_id, 0)
	rounds[round_id]["scores"][peer_id] = current + points
	_add_event(round_id, "score_added", {"peer_id": peer_id, "points": points})

func get_player_score(round_id: int, peer_id: int) -> int:
	"""Retorna pontuação atual do jogador"""
	if not rounds.has(round_id):
		return 0
	return rounds[round_id]["scores"].get(peer_id, 0)

func get_all_scores(round_id: int) -> Dictionary:
	"""Retorna dicionário com todas as pontuações {peer_id: score}"""
	if not rounds.has(round_id):
		return {}
	return rounds[round_id]["scores"].duplicate()

func get_leaderboard(round_id: int) -> Array:
	"""
	Retorna array ordenado por pontuação (maior primeiro)
	Formato: [{peer_id, name, score}, ...]
	"""
	if not rounds.has(round_id):
		return []
	
	var round_data = rounds[round_id]
	var leaderboard = []
	
	for player in round_data["players"]:
		leaderboard.append({
			"peer_id": player["id"],
			"name": player["name"],
			"score": round_data["scores"].get(player["id"], 0)
		})
	
	# Ordena por score (decrescente)
	leaderboard.sort_custom(func(a, b): return a["score"] > b["score"])
	
	return leaderboard

# ===== VERIFICAÇÕES AUTOMÁTICAS =====

func _check_all_disconnected():
	"""
	Verifica se todos os jogadores desconectaram de rodadas ativas
	Finaliza automaticamente se configurado
	Executado pelo timer global
	"""
	for round_id in rounds:
		var round_data = rounds[round_id]
		
		# Só verifica rodadas em andamento
		if round_data["state"] != "playing":
			continue
		
		# Verifica se todos desconectaram
		if get_active_player_count(round_id) == 0:
			_log_debug("⚠ Todos os jogadores desconectaram da rodada %d!" % round_id)
			all_players_disconnected.emit(round_id)
			
			if auto_end_on_all_disconnected:
				end_round(round_id, "all_disconnected")

func _on_round_timeout(round_id: int):
	"""
	Callback do timer de duração da rodada
	Finaliza rodada por timeout
	"""
	if not rounds.has(round_id):
		return
	
	_log_debug("⏱ Tempo máximo da rodada %d atingido!" % round_id)
	round_timeout.emit(round_id)
	end_round(round_id, "timeout")

# ===== QUERIES DE ESTADO =====

func is_round_active(round_id: int) -> bool:
	"""Verifica se rodada existe e está ativa"""
	return rounds.has(round_id)

func get_round_state(round_id: int) -> String:
	"""
	Retorna estado atual da rodada
	Estados: "none", "loading", "playing", "ending", "results"
	"""
	if not rounds.has(round_id):
		return "none"
	return rounds[round_id]["state"]

func get_round(round_id: int) -> Dictionary:
	"""Retorna cópia completa dos dados da rodada"""
	if not rounds.has(round_id):
		return {}
	return rounds[round_id].duplicate(true)

func get_round_by_player_id(player_id: int) -> Dictionary:
	"""
	Retorna rodada em que o jogador está participando
	Útil para localizar jogador quando só temos seu peer_id
	"""
	for round_id in rounds:
		var round_data = rounds[round_id]
		for player in round_data["players"]:
			if player["id"] == player_id:
				return round_data.duplicate(true)
	return {}

func get_round_duration(round_id: int) -> float:
	"""
	Retorna duração da rodada em segundos
	Se ainda está ativa, retorna tempo decorrido
	Se já terminou, retorna duração total
	"""
	if not rounds.has(round_id):
		return 0.0
	
	var round_data = rounds[round_id]
	
	if round_data["state"] == "playing":
		return Time.get_unix_time_from_system() - round_data["start_time"]
	else:
		return round_data.get("duration", 0.0)

func get_settings(round_id: int) -> Dictionary:
	"""Retorna configurações da rodada (mapa, modo, etc)"""
	if not rounds.has(round_id):
		return {}
	return rounds[round_id]["settings"].duplicate(true)

func get_total_players(round_id: int) -> int:
	"""Retorna total de jogadores na rodada (incluindo desconectados)"""
	if not rounds.has(round_id):
		return 0
	return rounds[round_id]["players"].size()

func get_all_rounds() -> Dictionary:
	"""Retorna todas as rodadas ativas"""
	return rounds.duplicate(true)

func get_active_rounds_count() -> int:
	"""Retorna quantidade de rodadas ativas"""
	return rounds.size()

# ===== UTILITÁRIOS =====

func _get_next_round_id() -> int:
	"""Gera próximo ID de rodada disponível"""
	var max_id = 0
	for round_id in rounds:
		if round_id > max_id:
			max_id = round_id
	return max_id + 1

## Gera um dicionário com configurações randômicas para o Sky3D
## @return Dictionary com todas as configurações geradas
func sky3d_config_generator() -> Dictionary:
	var config = {}
	
	# Paletas de cores predefinidas para diferentes atmosferas
	var paletas_cores = _gerar_paletas_cores()
	var paleta = paletas_cores[randi() % paletas_cores.size()]
	
	# TEMPO (TimeOfDay)
	config["time"] = {
		"current_time": randf_range(6.0, 14.0),
		"day_duration": randf_range(840.0, 1200.0),
		"auto_advance": true, # randi() % 2 == 0
		"time_scale": 1.0 # randf_range(0.5, 2.0)
	}
	
	# ATMOSFERA E CÉU (SkyDome)
	config["sky"] = {
		"sky_contribution": randf_range(0.5, 1.5),
		"quality": "high", #["low", "medium", "high"][randi() % 3]
		"rayleigh_coefficient": randf_range(0.5, 3.0),
		"mie_coefficient": randf_range(0.005, 0.05),
		"turbidity": randf_range(1.0, 8.0),
		"sky_color": paleta["sky"],
		"horizon_color": paleta["horizon"]
	}
	
	# NÉVOA (Fog)
	config["fog"] = {
		"enabled": randi() % 2 == 0,
		"density": randf_range(0.001, 0.05),
		"color": paleta["fog"],
		"height": randf_range(-10.0, 50.0),
		"height_density": randf_range(0.0, 2.0)
	}
	
	# NUVENS (Clouds)
	config["clouds"] = {
		"coverage": randf_range(0.2, 0.9),
		"size": randf_range(0.5, 2.0),
		"speed": randf_range(0.01, 0.5),
		"wind_direction": randf_range(0.0, 360.0),
		"opacity": randf_range(0.6, 1.0),
		"brightness": randf_range(0.8, 1.5),
		"color": paleta["clouds"]
	}
	
	# EXPOSIÇÃO E TONEMAP
	config["exposure"] = {
		"exposure": randf_range(0.8, 1.5),
		"white_point": randf_range(6.0, 12.0)
	}
	
	# CORES AMBIENTE
	config["ambient"] = {
		"sky_color": paleta["ambient_sky"],
		"ground_color": paleta["ambient_ground"]
	}
	
	_log_debug("✓ Configurações randômicas geradas: %s" % paleta["nome"])
	return config

## Gera paletas de cores temáticas para diferentes atmosferas
func _gerar_paletas_cores() -> Array:
	return [
		{
			"nome": "Azul Clássico",
			"sky": Color(0.4, 0.6, 0.9),
			"horizon": Color(0.6, 0.7, 0.9),
			"fog": Color(0.7, 0.8, 0.95),
			"clouds": Color(0.95, 0.95, 1.0),
			"ambient_sky": Color(0.5, 0.6, 0.8),
			"ambient_ground": Color(0.3, 0.3, 0.3)
		},
		{
			"nome": "Pôr do Sol Dourado",
			"sky": Color(0.9, 0.5, 0.3),
			"horizon": Color(1.0, 0.7, 0.4),
			"fog": Color(0.95, 0.75, 0.6),
			"clouds": Color(1.0, 0.8, 0.6),
			"ambient_sky": Color(0.8, 0.5, 0.3),
			"ambient_ground": Color(0.4, 0.3, 0.2)
		},
		{
			"nome": "Aurora Roxa",
			"sky": Color(0.6, 0.3, 0.8),
			"horizon": Color(0.8, 0.4, 0.9),
			"fog": Color(0.75, 0.6, 0.85),
			"clouds": Color(0.9, 0.7, 0.95),
			"ambient_sky": Color(0.5, 0.3, 0.6),
			"ambient_ground": Color(0.3, 0.2, 0.4)
		},
		{
			"nome": "Amanhecer Rosa",
			"sky": Color(0.95, 0.6, 0.7),
			"horizon": Color(1.0, 0.75, 0.8),
			"fog": Color(0.95, 0.8, 0.85),
			"clouds": Color(1.0, 0.85, 0.9),
			"ambient_sky": Color(0.8, 0.5, 0.6),
			"ambient_ground": Color(0.4, 0.3, 0.3)
		},
		{
			"nome": "Tempestade Cinza",
			"sky": Color(0.4, 0.4, 0.5),
			"horizon": Color(0.5, 0.5, 0.55),
			"fog": Color(0.6, 0.6, 0.65),
			"clouds": Color(0.7, 0.7, 0.75),
			"ambient_sky": Color(0.3, 0.3, 0.35),
			"ambient_ground": Color(0.2, 0.2, 0.2)
		},
		{
			"nome": "Deserto Âmbar",
			"sky": Color(0.85, 0.7, 0.5),
			"horizon": Color(0.95, 0.8, 0.6),
			"fog": Color(0.9, 0.8, 0.7),
			"clouds": Color(0.95, 0.9, 0.8),
			"ambient_sky": Color(0.7, 0.6, 0.4),
			"ambient_ground": Color(0.5, 0.4, 0.3)
		},
		{
			"nome": "Noite Estrelada",
			"sky": Color(0.1, 0.1, 0.3),
			"horizon": Color(0.2, 0.2, 0.4),
			"fog": Color(0.15, 0.15, 0.35),
			"clouds": Color(0.3, 0.3, 0.5),
			"ambient_sky": Color(0.1, 0.1, 0.2),
			"ambient_ground": Color(0.05, 0.05, 0.1)
		},
		{
			"nome": "Floresta Esmeralda",
			"sky": Color(0.5, 0.8, 0.6),
			"horizon": Color(0.6, 0.85, 0.7),
			"fog": Color(0.7, 0.9, 0.75),
			"clouds": Color(0.85, 0.95, 0.9),
			"ambient_sky": Color(0.4, 0.6, 0.5),
			"ambient_ground": Color(0.2, 0.4, 0.2)
		},
		{
			"nome": "Inverno Gelado",
			"sky": Color(0.7, 0.8, 0.95),
			"horizon": Color(0.8, 0.85, 0.98),
			"fog": Color(0.85, 0.9, 1.0),
			"clouds": Color(0.95, 0.97, 1.0),
			"ambient_sky": Color(0.6, 0.7, 0.8),
			"ambient_ground": Color(0.4, 0.45, 0.5)
		},
		{
			"nome": "Vulcão Laranja",
			"sky": Color(0.8, 0.4, 0.2),
			"horizon": Color(0.9, 0.5, 0.3),
			"fog": Color(0.85, 0.5, 0.4),
			"clouds": Color(0.9, 0.6, 0.5),
			"ambient_sky": Color(0.6, 0.3, 0.2),
			"ambient_ground": Color(0.3, 0.2, 0.1)
		}
	]

func debug_print_all_rounds():
	"""Imprime estado completo de todas as rodadas"""
	print("\n========== ROUND REGISTRY ==========")
	print("Rodadas ativas: %d" % rounds.size())
	print("------------------------------------")
	
	for round_id in rounds:
		var r = rounds[round_id]
		print("\n[Rodada %d]" % round_id)
		print("  Sala: %s (ID: %d)" % [r["room_name"], r["room_id"]])
		print("  Estado: %s" % r["state"])
		print("  Jogadores: %d (%d ativos)" % [r["players"].size(), get_active_player_count(round_id)])
		print("  Duração: %.1fs" % get_round_duration(round_id))
		
		if r["state"] == "playing" and r["round_timer"]:
			print("  Tempo restante: %.1fs" % r["round_timer"].time_left)
		
		print("  Spawnados: %d" % r["spawned_players"].size())
		print("  Eventos: %d" % r["events"].size())
		
		if not r["disconnected_players"].is_empty():
			print("  Desconectados: %s" % r["disconnected_players"])
		
		print("  Pontuações:")
		var scores = get_leaderboard(round_id)
		for entry in scores:
			print("    %s: %d pts" % [entry["name"], entry["score"]])
	
	print("\n====================================\n")

func _log_debug(message: String):
	"""Função padrão de debug"""
	if debug_mode:
		print("[SERVER][RoundRegistry] %s" % message)
