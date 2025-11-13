extends Node
## ServerManager - Gerenciador do servidor dedicado
## Este script só é executado quando o jogo está rodando como servidor
## Todos os RPCs estão em NetworkManager

# ===== CONFIGURAÇÕES (Editáveis no Inspector) =====
@export_category("Debug")
@export var debug_mode: bool = true
@export var debug_timer: bool = true
@export var simulador_ativado: bool = false
@export var simulador_players_qtd: int = 2

@export_category("Server Settings")
@export var server_port: int = 7777
@export var max_clients: int = 32

@export_category("Round Settings")
## Tempo de transição entre fim de rodada e volta à sala (segundos)
@export var round_transition_time: float = 5.0
## Tempo de espera antes de iniciar próxima rodada (segundos)
@export var round_preparation_time: float = 3.0

@export_category("Anti-Cheat")
## Velocidade máxima permitida (m/s)
@export var max_player_speed: float = 15.0
## Margem de tolerância para lag (multiplicador)
@export var speed_tolerance: float = 1.5
## Tempo mínimo entre validações (segundos)
@export var validation_interval: float = 0.1
## Ativar validação anti-cheat
@export var enable_anticheat: bool = true

@export_category("Configurações de spawn")
## Raio do círculo
@export	var spawn_radius: float = 5.0
## Altura acima do chão
@export	var spawn_height: float = 1.0
## Centro do círculo
@export	var spawn_center: Vector3 = Vector3.ZERO
## Variação aleatória na posição (em unidades)
@export	var position_variance: float = 4.0
## Variação na rotação (em radianos, ~5.7 graus)
@export	var rotation_variance: float = 0.2

# ===== VARIÁVEIS INTERNAS =====

var next_room_id: int = 1

var spawn_points = []

## Referência ao MapManager do servidor (criado durante rodada)
var server_map_manager: Node = null

## Rastreamento de estados dos jogadores
var player_states: Dictionary = {}

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_start_server()
		_connect_round_signals()
		
		if debug_timer:
			var debug_timer_ = Timer.new()
			debug_timer_.wait_time = 5.0
			debug_timer_.autostart = true
			debug_timer_.timeout.connect(_print_player_states)
			add_child(debug_timer_)
		
func _start_server():
	"""Inicia o servidor dedicado"""
	_log_debug("========================================")
	_log_debug("INICIANDO SERVIDOR DEDICADO")
	_log_debug("Porta: %d" % server_port)
	_log_debug("Máximo de clientes: %d" % max_clients)
	_log_debug("========================================")
	
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(server_port, max_clients)
	
	if error != OK:
		_log_debug("✗ ERRO ao criar servidor: " + str(error))
		return
	
	multiplayer.multiplayer_peer = peer
	
	# Conecta sinais de rede
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	PlayerRegistry.initialize_as_server()
	RoomRegistry.initialize_as_server()
	RoundRegistry.initialize_as_server()
	
	if TestManager:
		TestManager.initialize_as_server()
	
	_log_debug("✓ Servidor inicializado com sucesso!")

func _connect_round_signals():
	"""Conecta sinais do RoundRegistry"""
	RoundRegistry.round_ending.connect(_on_round_ending)
	RoundRegistry.all_players_disconnected.connect(_on_all_players_disconnected)
	RoundRegistry.round_timeout.connect(_on_round_timeout)

# ===== CALLBACKS DE CONEXÃO =====

func _on_peer_connected(peer_id: int):
	"""Callback quando um cliente conecta"""
	_log_debug("✓ Cliente conectado: Peer ID %d" % peer_id)
	PlayerRegistry.add_peer(peer_id)
	if simulador_ativado and (multiplayer.get_peers().size() >= simulador_players_qtd) and TestManager:
		TestManager.criar_partida_teste()

func _on_peer_disconnected(peer_id: int):
	"""Callback quando um cliente desconecta"""
	_log_debug("✗ Cliente desconectado: Peer ID %d" % peer_id)
	
	# PRIMEIRO: Remove da rodada (atualiza lista de players imediatamente)
	var p_round = RoundRegistry.get_round_by_player_id(peer_id)
	if not p_round.is_empty():
		var round_id = p_round["round_id"]
		
		# Marca como desconectado na rodada
		RoundRegistry.mark_player_disconnected(round_id, peer_id)
		_log_debug("  Marcado como desconectado na rodada %d" % round_id)
		
		# REMOVE DA LISTA DE PLAYERS DA RODADA
		RoundRegistry.unregister_spawned_player(round_id, peer_id)
		
		# REMOVE O NÓ DO PLAYER DA CENA DO SERVIDOR
		var player_node = RoundRegistry.get_spawned_player(round_id, peer_id)
		if player_node and player_node.is_inside_tree():
			player_node.queue_free()
			_log_debug("  Nó do player removido da cena do servidor")
		
		# Verifica se todos os players desconectaram
		if RoundRegistry.get_active_player_count(round_id) == 0:
			RoundRegistry.end_round(round_id, "all_disconnected")
	
	# DEPOIS: Remove da sala
	var player_data = PlayerRegistry.get_player(peer_id)
	var room = RoomRegistry.get_room_by_player(peer_id)
	
	if player_data and player_data.has("name"):
		_log_debug("  Jogador: %s" % player_data["name"])
		
		if room and not room.is_empty():
			RoomRegistry.remove_player_from_room(room["id"], peer_id)
			_log_debug("  Removido da sala: %s" % room["name"])
			_notify_room_update(room["id"])
			
			# Notifica outros jogadores da sala sobre a desconexão
			for player in room["players"]:
				# VERIFICA SE O PEER AINDA ESTÁ CONECTADO ANTES DE ENVIAR RPC
				if player["id"] != peer_id and _is_peer_connected(player["id"]):
					NetworkManager.rpc_id(player["id"], "_client_remove_player", peer_id)
	
	# Limpeza final
	_cleanup_player_state(peer_id)
	PlayerRegistry.remove_peer(peer_id)

# ===== HANDLERS DE JOGADOR =====

func _handle_register_player(peer_id: int, player_name: String):
	"""Registra um novo jogador no servidor"""
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
	
	var validation_result = _validate_player_name(player_name)
	if validation_result != "":
		_log_debug("✗ Nome rejeitado: " + validation_result)
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
	
	var success = PlayerRegistry.register_player(peer_id, player_name)
	
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		NetworkManager.rpc_id(peer_id, "_client_name_accepted", player_name)
	else:
		_log_debug("✗ Falha ao registrar jogador")
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")

func _validate_player_name(player_name: String) -> String:
	"""Valida o nome do jogador"""
	var trimmed_name = player_name.strip_edges()
	
	if trimmed_name.is_empty():
		return "O nome não pode estar vazio"
	
	if trimmed_name.length() < 3:
		return "O nome deve ter pelo menos 3 caracteres"
	
	if trimmed_name.length() > 20:
		return "O nome deve ter no máximo 20 caracteres"
	
	var regex = RegEx.new()
	regex.compile("^[a-zA-Z0-9_ ]+$")
	if not regex.search(trimmed_name):
		return "O nome só pode conter letras, números, espaços e underscores"
	
	if PlayerRegistry.is_name_taken(trimmed_name):
		return "Este nome já está sendo usado"
	
	return ""

# ===== HANDLERS DE SALAS =====

func _handle_request_rooms_list(peer_id: int):
	"""Envia lista de salas para o cliente"""
	_log_debug("Cliente %d solicitou lista de salas" % peer_id)
	
	if not PlayerRegistry.is_player_registered(peer_id):
		_send_error(peer_id, "Jogador não registrado")
		return
	var all_out_rooms = RoomRegistry.get_in_game_rooms_list(true)
	_log_debug("Enviando %d salas para o cliente" % all_out_rooms.size())
	
	NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list", all_out_rooms)

func _handle_create_room(peer_id: int, room_name: String, password: String):
	"""Cria uma nova sala"""
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Criando sala '%s' para jogador %s (ID: %d)" % [room_name, player["name"], peer_id])
	
	var validation = _validate_room_name(room_name)
	if validation != "":
		NetworkManager.rpc_id(peer_id, "_client_room_name_error", validation)
		return
	
	if RoomRegistry.room_name_exists(room_name):
		NetworkManager.rpc_id(peer_id, "_client_room_name_exists")
		return
	
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala")
		return
	
	var room_id = next_room_id
	next_room_id += 1
	
	var room_data = RoomRegistry.create_room(room_id, room_name, password, peer_id)
	
	_log_debug("✓ Sala criada: %s (ID: %d, Host: %s)" % [room_name, room_id, player["name"]])
	
	_send_rooms_list_to_all()
	
	NetworkManager.rpc_id(peer_id, "_client_room_created", room_data)

func _validate_room_name(room_name: String) -> String:
	"""Valida o nome da sala"""
	var trimmed = room_name.strip_edges()
	
	if trimmed.is_empty():
		return "O nome da sala não pode estar vazio"
	
	if trimmed.length() < 3:
		return "O nome da sala deve ter pelo menos 3 caracteres"
	
	if trimmed.length() > 30:
		return "O nome da sala deve ter no máximo 30 caracteres"
	
	return ""

func _handle_join_room(peer_id: int, room_id: int, password: String):
	"""Adiciona jogador a uma sala existente"""
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala ID: %d" % [player["name"], peer_id, room_id])
	
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	var room = RoomRegistry.get_room(room_id)
	if room.is_empty():
		_send_error(peer_id, "Sala não encontrada")
		return
	
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	var success = RoomRegistry.add_player_to_room(room_id, peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	var room_data = RoomRegistry.get_room(room_id)
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	_notify_room_update(room_id)

func _handle_join_room_by_name(peer_id: int, room_name: String, password: String):
	"""Adiciona jogador a uma sala pelo nome"""
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala: '%s'" % [player["name"], peer_id, room_name])
	
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	var room = RoomRegistry.get_room_by_name(room_name)
	if room.is_empty():
		NetworkManager.rpc_id(peer_id, "_client_room_not_found")
		return
	
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	var success = RoomRegistry.add_player_to_room(room["id"], peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	var room_data = RoomRegistry.get_room(room["id"])
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	_notify_room_update(room["id"])

func _handle_leave_room(peer_id: int):
	"""Remove jogador da sala atual"""
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		return
	
	_log_debug("Jogador %s saiu da sala: %s" % [player["name"], room["name"]])
	RoomRegistry.remove_player_from_room(room["id"], peer_id)
	
	_notify_room_update(room["id"])

func _handle_close_room(peer_id: int):
	"""Fecha uma sala (apenas host pode fazer isso)"""
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		return
	
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode fechar a sala")
		return
	
	_log_debug("Host %s fechou a sala: %s" % [player["name"], room["name"]])
	
	# Notifica todos os players
	for room_player in room["players"]:
		if room_player["id"] != peer_id:
			NetworkManager.rpc_id(room_player["id"], "_client_room_closed", "O host fechou a sala")
	
	RoomRegistry.remove_room(room["id"])
	_send_rooms_list_to_all()

# ===== HANDLER DE INÍCIO DE RODADA =====

func _handle_start_round(peer_id: int, round_settings: Dictionary):
	"""Inicia uma nova rodada na sala"""
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		_send_error(peer_id, "Você não está em nenhuma sala")
		return
	
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode iniciar a rodada")
		return
	
	if not RoomRegistry.can_start_match(room["id"]):
		var reqs = RoomRegistry.get_match_requirements(room["id"])
		_send_error(peer_id, "Requisitos não atendidos: %d/%d jogadores (mínimo: %d)" % [
			reqs["current_players"],
			reqs["max_players"],
			reqs["min_players"]
		])
		return
	
	if RoomRegistry.is_room_in_game(room["id"]):
		_send_error(peer_id, "A sala já está em uma rodada")
		return
	
	_log_debug("========================================")
	_log_debug("HOST INICIANDO RODADA")
	_log_debug("Sala: %s (ID: %d)" % [room["name"], room["id"]])
	_log_debug("Jogadores participantes:")
	
	for room_player in room["players"]:
		PlayerRegistry.set_player_in_game(room_player["id"],true)
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %d)%s" % [room_player["name"], room_player["id"], is_host_mark])
	
	_log_debug("========================================")
	
	# Cria rodada no RoundRegistry
	var round_data = RoundRegistry.create_round(
		room["id"],
		room["name"],
		room["players"],
		round_settings
	)
	
	# round_settings recebe configurações do round para enviar para clientes/server configurarem
	# seus mapas e enviorments
	round_settings = round_data.get("settings")
	# Define mapa (sempre o mesmo, gerado proceduralmente)
	var map_scene = round_settings.get("map_scene", "res://scenes/system/WorldGenerator.tscn")
	
	if round_data.is_empty():
		_send_error(peer_id, "Erro ao criar rodada")
		return
	
	# Atualiza estado da sala
	RoomRegistry.set_room_in_game(room["id"], true)
	
	# Gera dados de spawn para cada jogador
	var spawn_data = {}
	for i in range(room["players"].size()):
		var p = room["players"][i]
		spawn_data[p["id"]] = {
			"spawn_index": i,
			"team": 0
		}
	var players_qtd = RoundRegistry.get_total_players(round_data["round_id"])
	round_settings["round_players_count"] = players_qtd
	round_settings["spawn_points"] = _create_spawn_points(players_qtd)
	
	# Prepara dados para enviar aos clientes
	var match_data = {
		"round_id": round_data["round_id"],
		"room_id": room["id"],
		"map_scene": map_scene,
		"settings": round_settings,
		"players": room["players"],
		"spawn_data": spawn_data
	}
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room["players"]:
		NetworkManager.rpc_id(room_player["id"], "_client_round_started", match_data)
	
	# Instancia mapa e players no servidor também
	await _server_instantiate_round(match_data)
	
	# Inicia a rodada
	RoundRegistry.start_round(round_data["round_id"])
	_send_rooms_list_to_all()

func _create_spawn_points(match_players_count: int) -> Array:
	"""
	Gera pontos de spawn em formação circular com base no número de jogadores.
	Suporta de 1 a 14 jogadores com distribuição uniforme.
	"""
	
	# Limpa array anterior
	spawn_points.clear()
	
	# Caso especial: apenas 1 jogador
	if match_players_count == 1:
		var spawn_data = {
			"position": Vector3(0, spawn_height, spawn_radius),
			"rotation": Vector3(0, PI, 0)  # Olhando para o centro
		}
		spawn_points.append(spawn_data)
		_log_debug("Spawn point único criado no centro")
		return spawn_points
	
	# Gera pontos de spawn de 2 a 14 jogadores
	match_players_count = clamp(match_players_count, 1, 14)
	
	for i in range(match_players_count):
		# Distribui os jogadores uniformemente em círculo
		var angle = (i * 2.0 * PI) / match_players_count
		
		# Calcula posição base no círculo
		var base_x = cos(angle) * spawn_radius
		var base_z = sin(angle) * spawn_radius
		
		# Adiciona variação aleatória à posição (se configurado)
		var variance_x = randf_range(-position_variance, position_variance)
		var variance_z = randf_range(-position_variance, position_variance)
		
		var final_position = spawn_center + Vector3(
			base_x + variance_x,
			spawn_height,
			base_z + variance_z
		)
		
		# Calcula rotação apontando PARA o centro
		# Usando o vetor do spawn point PARA o centro
		var to_center = spawn_center - final_position
		# atan2(x, z) para sistema de coordenadas do Godot onde -Z é frente
		var rotation_y = atan2(to_center.x, to_center.z)
		
		# Adiciona variação aleatória à rotação
		rotation_y += randf_range(-rotation_variance, rotation_variance)
		
		var spawn_data = {
			"position": final_position,
			"rotation": Vector3(0, rotation_y, 0)
		}
		
		spawn_points.append(spawn_data)
	
	_log_debug("Spawn points criados: %d jogadores em formação circular (raio: %.1f)" % [spawn_points.size(), spawn_radius])
	return spawn_points

# ===== INSTANCIAÇÃO NO SERVIDOR =====

func _server_instantiate_round(match_data: Dictionary):
	"""Instancia a rodada no servidor (mapa e players)"""
	_log_debug("Instanciando rodada no servidor...")
	
	# Cria MapManager
	server_map_manager = preload("res://scripts/gameplay/MapManager.gd").new()
	get_tree().root.add_child(server_map_manager)
	
	# Carrega o mapa
	await server_map_manager.load_map(match_data["map_scene"], match_data["settings"])
	
	if RoundRegistry.rounds.has(match_data["round_id"]):
		RoundRegistry.rounds[match_data["round_id"]]["map_manager"] = server_map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		_spawn_player_on_server(player_data, spawn_data)
	
	_log_debug("✓ Rodada instanciada no servidor")

func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary):
	"""Spawna um jogador no servidor (versão autoritativa)"""
	var player_scene = preload("res://scenes/system/player_warrior.tscn")
	var player_instance = player_scene.instantiate()
	
	# ✅ CONFIGURAÇÃO CRÍTICA: Nome = ID
	player_instance.name = str(player_data["id"])
	player_instance.player_id = player_data["id"]
	player_instance.player_name = player_data["name"]
	
	# ✅ IMPORTANTE: No servidor, nenhum player é "local"
	player_instance.is_local_player = false
	
	# Adiciona à cena
	get_tree().root.add_child(player_instance)
	
	# Posiciona
	var spawn_pos = server_map_manager.get_spawn_position(spawn_data["spawn_index"])
	player_instance.initialize(player_data["id"], player_data["name"], spawn_pos)
	
	# Registra no RoundRegistry
	var p_round = RoundRegistry.get_round_by_player_id(player_instance.player_id)
	if not p_round.is_empty():
		RoundRegistry.register_spawned_player(p_round["round_id"], player_data["id"], player_instance)
	
	# ✅ INICIALIZA ESTADO PARA VALIDAÇÃO
	player_states[player_data["id"]] = {
		"pos": spawn_pos,
		"vel": Vector3.ZERO,
		"timestamp": Time.get_ticks_msec()
	}
	
	_log_debug("✅ Player spawnado no servidor: %s (ID: %d) em %s" % [
		player_data["name"], 
		player_data["id"],
		spawn_pos
	])

# ===== CALLBACKS DE RODADA =====

func _on_round_ending(round_id: int, reason: String):
	"""Callback quando uma rodada está terminando"""
	_log_debug("Rodada %d finalizando. Razão: %s" % [round_id, reason])
	
	# Aguarda tempo de transição
	await get_tree().create_timer(round_transition_time).timeout
	
	# Finaliza completamente a rodada
	_complete_round_end(round_id)

func _on_all_players_disconnected(round_id: int):
	"""Callback quando todos os players desconectam da rodada"""
	_log_debug("⚠ Todos os players desconectaram da rodada %d" % round_id)
	
	# Finaliza rodada imediatamente
	RoundRegistry.end_round(round_id, "all_disconnected")

func _on_round_timeout(round_id: int):
	"""Callback quando o tempo máximo da rodada é atingido"""
	_log_debug("⏱ Tempo máximo da rodada %d atingido" % round_id)
	
	# Finaliza rodada por timeout
	RoundRegistry.end_round(round_id, "timeout")
	
	# Todos os players in_game = false
	var round_ = RoundRegistry.get_round(round_id)
	for player in round_["players"]:
		PlayerRegistry.set_player_in_game(player.id, false)

# ===== FIM DE RODADA =====

#func end_current_round(reason: String = "completed", winner_data: Dictionary = {}):
	#"""Finaliza a rodada atual (chamado por eventos do jogo)"""
	#if not RoundRegistry.is_round_active():
		#_log_debug("Nenhuma rodada ativa para finalizar")
		#return
	#
	#_log_debug("Finalizando rodada atual. Razão: %s" % reason)
	#
	## Finaliza no RoundRegistry
	#var end_data = RoundRegistry.end_round(reason, winner_data)
	#
	## Notifica todos os clientes
	#var round_data = RoundRegistry.get_current_round()
	#for player in round_data["players"]:
		#NetworkManager.rpc_id(player["id"], "_client_round_ended", end_data)

func _complete_round_end(round_id : int):
	"""Completa o fim da rodada e retorna players à sala"""
	var round_data = RoundRegistry.get_round(round_id)
	
	if round_data.is_empty():
		return
	
	var room_id = round_data["room_id"]
	
	_log_debug("========================================")
	_log_debug("RODADA FINALIZADA COMPLETAMENTE")
	_log_debug("Rodada ID: %d" % round_data["round_id"])
	_log_debug("Duração: %.1f segundos" % round_data["duration"])
	
	if not round_data["winner"].is_empty():
		_log_debug("Vencedor: %s (Score: %d)" % [
			round_data["winner"]["name"],
			round_data["winner"]["score"]
		])
	
	_log_debug("========================================")
	
	# Adiciona ao histórico da sala
	RoomRegistry.add_round_to_history(room_id, round_data)
	
	# Limpa objetos da rodada
	_cleanup_round_objects()
	
	# Todos os players in_game = false
	var round_ = RoundRegistry.get_round(round_data["round_id"])
	for player in round_["players"]:
		PlayerRegistry.set_player_in_game(player.id, false)
	
	# Finaliza completamente no RoundRegistry
	RoundRegistry.complete_round_end(round_data["round_id"])
	
	# Atualiza estado da sala
	RoomRegistry.set_room_in_game(room_id, false)
	
	# Notifica clientes para voltar à sala
	var room = RoomRegistry.get_room(room_id)
	if not room.is_empty():
		for player in room["players"]:
			NetworkManager.rpc_id(player["id"], "_client_return_to_room", room)

func _cleanup_round_objects():
	"""Limpa todos os objetos da rodada (players, mapa, etc)"""
	_log_debug("Limpando objetos da rodada...")
	
	# Remove players
	for child in get_tree().root.get_children():
		if child.is_in_group("player"):
			child.queue_free()
	
	# Remove mapa
	if server_map_manager:
		server_map_manager.unload_map()
		server_map_manager.queue_free()
		server_map_manager = null
	
	# Limpa objetos spawnados
	ObjectSpawner.cleanup()
	
	_log_debug("✓ Limpeza completa")

# Função de utilidade para verificar peers conectados (adicione se não existir)
func _is_peer_connected(peer_id: int) -> bool:
	"""Verifica se um peer ainda está conectado"""
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

# ===== SINCRONIZAÇÃO DE JOGADORES =====

func _validate_player_movement(p_id: int, pos: Vector3, vel: Vector3) -> bool:
	"""Valida se o movimento do jogador é razoável (anti-cheat)"""
	
	# Se anti-cheat desativado, sempre aceita
	if not enable_anticheat:
		return true
	
	# Se não tem estado anterior, aceita (primeira sincronização)
	if not player_states.has(p_id):
		player_states[p_id] = {
			"pos": pos,
			"vel": vel,
			"timestamp": Time.get_ticks_msec()
		}
		return true
	
	var last_state = player_states[p_id]
	var current_time = Time.get_ticks_msec()
	var time_diff = (current_time - last_state["timestamp"]) / 1000.0
	
	# Ignora validação se intervalo muito curto (evita falsos positivos)
	if time_diff < validation_interval:
		return true
	
	# Calcula distância percorrida
	var distance = pos.distance_to(last_state["pos"])
	
	# ✅ VALIDAÇÃO 1: Distância máxima permitida
	var max_distance = max_player_speed * time_diff * speed_tolerance
	
	if distance > max_distance:
		_log_debug("⚠️ ANTI-CHEAT: Distância suspeita")
		_log_debug("  Player: %d" % p_id)
		_log_debug("  Distância: %.2f m em %.3f s" % [distance, time_diff])
		_log_debug("  Máximo: %.2f m" % max_distance)
		_log_debug("  Velocidade: %.2f m/s (máx: %.2f m/s)" % [distance/time_diff, max_player_speed * speed_tolerance])
		return false
	
	# ✅ VALIDAÇÃO 2: Velocidade reportada vs. real
	var reported_speed = vel.length()
	var actual_speed = distance / time_diff if time_diff > 0 else 0
	
	if reported_speed > max_player_speed * speed_tolerance:
		_log_debug("⚠️ ANTI-CHEAT: Velocidade reportada suspeita")
		_log_debug("  Player: %d" % p_id)
		_log_debug("  Reportada: %.2f m/s" % reported_speed)
		_log_debug("  Máximo: %.2f m/s" % (max_player_speed * speed_tolerance))
		return false
	
	# Diferença muito grande entre velocidade real e reportada
	if abs(actual_speed - reported_speed) > max_player_speed * 0.5:
		_log_debug("⚠️ ANTI-CHEAT: Discrepância entre velocidade real e reportada")
		_log_debug("  Player: %d" % p_id)
		_log_debug("  Real: %.2f m/s" % actual_speed)
		_log_debug("  Reportada: %.2f m/s" % reported_speed)
		# Nota: Não retorna false aqui, pois pode ser lag legítimo
	
	# ✅ ATUALIZA ESTADO PARA PRÓXIMA VALIDAÇÃO
	player_states[p_id] = {
		"pos": pos,
		"vel": vel,
		"timestamp": current_time
	}
	
	return true

# ===== UTILITÁRIOS =====

func _cleanup_player_state(peer_id: int):
	"""Remove estado do jogador (chamado quando desconecta)"""
	if player_states.has(peer_id):
		player_states.erase(peer_id)
		_log_debug("  Estado de validação removido")


func _kick_player(peer_id: int, reason: String):
	"""Kicka um jogador do servidor (anti-cheat)"""
	_log_debug("========================================")
	_log_debug("⚠️ KICKANDO JOGADOR")
	_log_debug("Peer ID: %d" % peer_id)
	_log_debug("Razão: %s" % reason)
	_log_debug("========================================")
	
	# Remove da rodada se estiver em uma
	var p_round = RoundRegistry.get_round_by_player_id(peer_id)
	if not p_round.is_empty():
		var round_id = p_round["round_id"]
		RoundRegistry.mark_player_disconnected(round_id, peer_id)
		RoundRegistry.unregister_spawned_player(round_id, peer_id)
		
		var player_node = RoundRegistry.get_spawned_player(round_id, peer_id)
		if player_node and player_node.is_inside_tree():
			player_node.queue_free()
	
	# Remove da sala
	var room = RoomRegistry.get_room_by_player(peer_id)
	if not room.is_empty():
		RoomRegistry.remove_player_from_room(room["id"], peer_id)
		_notify_room_update(room["id"])
	
	# Envia notificação de kick
	NetworkManager.rpc_id(peer_id, "_client_error", "🚫 Você foi desconectado: " + reason)
	
	# Desconecta após 1 segundo
	await get_tree().create_timer(1.0).timeout
	
	if multiplayer.has_multiplayer_peer() and _is_peer_connected(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		_log_debug("✅ Player desconectado")

func _send_rooms_list_to_all():
	"""Esta função atualiza a lista de salas(disponíveis/fora de jogo/não lotadas) 
	para todos os players que não estão em partida"""

	var all_out_rooms = RoomRegistry.get_in_game_rooms_list(true)
	var all_out_play_players = PlayerRegistry.get_in_game_players_list(true)
	for peer_id in all_out_play_players:
		if peer_id != 1:
			NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list_update", all_out_rooms)

func _notify_room_update(room_id: int):
	"""Notifica todos os players de uma sala sobre atualização"""
	var room = RoomRegistry.get_room(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		NetworkManager.rpc_id(player["id"], "_client_room_updated", room)

func _send_error(peer_id: int, message: String):
	"""Envia mensagem de erro para um cliente"""
	_log_debug("Enviando erro para cliente %d: %s" % [peer_id, message])
	NetworkManager.rpc_id(peer_id, "_client_error", message)

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		print("[ServerManager] " + message)

func _print_player_states():
	"""Debug: Imprime estados de todos os players"""
	_log_debug("========================================")
	_log_debug("ESTADOS DOS JOGADORES NO SERVIDOR")
	_log_debug("Total: %d" % player_states.size())
	for p_id in player_states.keys():
		var state = player_states[p_id]
		_log_debug("  Player %d:" % p_id)
		_log_debug("    Posição: %s" % str(state["pos"]))
		_log_debug("    Velocidade: %s" % str(state["vel"]))
		var age = (Time.get_ticks_msec() - state["timestamp"]) / 1000.0
		_log_debug("    Última atualização: %.2f s atrás" % age)
	_log_debug("========================================")
