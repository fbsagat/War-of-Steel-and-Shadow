extends Node
## ServerManager - Gerenciador central do servidor dedicado
## 
## RESPONSABILIDADES:
## - Inicializar servidor e registries
## - Gerenciar conexões/desconexões de peers
## - Processar comandos de players (registro, salas, rodadas)
## - Validar movimentos (anti-cheat)
## - Coordenar ciclo de vida de rodadas
## - Gerenciar spawn de objetos e players
##
## IMPORTANTE: Este script só executa quando iniciado com --server ou --dedicated

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true
@export var debug_timer: bool = false
@export var simulador_ativado: bool = true
@export var simulador_players_qtd: int = 2

@export_category("Server Settings")
@export var server_port: int = 7777
@export var max_clients: int = 32
@export var is_headless : bool = true

@export_category("Room Settings")
@export var max_players_per_room: int = 12
@export var min_players_to_start: int = 2

@export_category("Round Settings")
## Tempo de transição entre fim de rodada e volta à sala (segundos)
@export var round_transition_time: float = 5.0

@export_category("Anti-Cheat")
## Velocidade máxima permitida (m/s)
@export var max_player_speed: float = 15.0
## Margem de tolerância para lag (multiplicador)
@export var speed_tolerance: float = 1.5
## Tempo mínimo entre validações (segundos)
@export var validation_interval: float = 0.1
## Ativar validação anti-cheat
@export var enable_anticheat: bool = true

@export_category("Spawn Settings")
## Raio do círculo de spawn
@export var spawn_radius: float = 5.0
## Altura acima do chão
@export var spawn_height: float = 1.0
## Centro do círculo
@export var spawn_center: Vector3 = Vector3.ZERO
## Variação aleatória na posição (em unidades)
@export var position_variance: float = 4.0
## Variação na rotação (em radianos, ~5.7 graus)
@export var rotation_variance: float = 0.2

# ===== REGISTROS (Injetados após inicialização) =====

var player_registry : PlayerRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null
var test_manager: TestManager = null

# ===== VARIÁVEIS INTERNAS =====

## ID incremental para criação de salas
var next_room_id: int = 1

## Pontos de spawn calculados para rodada atual
var spawn_points: Array = []

## Referência ao MapManager do servidor (criado durante rodada)
var server_map_manager: Node = null

## Rastreamento de estados dos jogadores para validação anti-cheat
## Formato: {peer_id: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
var player_states: Dictionary = {}

# ===== INICIALIZAÇÃO =====

func _ready():
	"""Ponto de entrada principal - verifica se é servidor e inicializa"""
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args
	is_headless = DisplayServer.get_name() == "headless"
	
	if is_headless and is_server:
		_log_debug("Modo HEADLESS detectado (sem janela)")
	elif not is_headless and is_server:
		_log_debug("Modo VISUAL detectado (com janela)")
		
	if is_server:
		_start_server()
		_connect_signals()
		
		# Timer de debug opcional
		if debug_timer:
			_setup_debug_timer()

func _start_server():
	"""Inicializa servidor dedicado e todos os subsistemas"""
	var timestamp = Time.get_datetime_string_from_system()
	_log_debug("========================================")
	_log_debug("INICIANDO SERVIDOR DEDICADO")
	_log_debug(timestamp)
	_log_debug("Porta: %d" % server_port)
	_log_debug("Máximo de clientes: %d" % max_clients)
	_log_debug("========================================")
	
	# Cria peer de rede
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(server_port, max_clients)
	
	if error != OK:
		push_error("ERRO ao criar servidor: " + str(error))
		return
	
	multiplayer.multiplayer_peer = peer
	
	# Conecta sinais de rede
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	# Instancia registries
	player_registry = load("res://scripts/only_server/registrars/PlayerRegistry.gd").new()
	room_registry = load("res://scripts/only_server/registrars/RoomRegistry.gd").new()
	round_registry = load("res://scripts/only_server/registrars/RoundRegistry.gd").new()
	object_manager = load("res://scripts/only_server/ObjectManager.gd").new()
	test_manager = load("res://scripts/only_server/TestManager.gd").new()
	
	# Nomeia para facilitar visualização
	player_registry.name = "PlayerRegistry"
	room_registry.name = "RoomRegistry"
	round_registry.name = "RoundRegistry"
	object_manager.name = "ObjectManager"
	test_manager.name = "TestManager"
	
	# Adiciona à árvore
	add_child(player_registry)
	add_child(room_registry)
	add_child(round_registry)
	add_child(object_manager)
	add_child(test_manager)
	
	# Injeta dependências cruzadas
	_inject_dependencies()
	
	# Inicializa registries
	player_registry.initialize()
	room_registry.initialize()
	round_registry.initialize()
	test_manager.initialize()
	object_manager.initialize()
	
	_log_debug("✓ Servidor inicializado com sucesso!")

func _inject_dependencies():
	"""Injeta referências cruzadas entre registries"""
	# PlayerRegistry precisa de:
	player_registry.room_registry = room_registry
	player_registry.round_registry = round_registry
	player_registry.object_manager = object_manager
	player_registry.item_database = ItemDatabase
	
	# RoomRegistry precisa de:
	room_registry.player_registry = player_registry
	room_registry.round_registry = round_registry
	room_registry.object_manager = object_manager
	
	# RoundRegistry precisa de:
	round_registry.player_registry = player_registry
	round_registry.room_registry = room_registry
	round_registry.object_manager = object_manager
	
	# ObjectManager precisa de:
	object_manager.player_registry = player_registry
	object_manager.round_registry = round_registry
	object_manager.item_database = ItemDatabase

func _connect_signals():
	"""Conecta sinais dos registries"""
	# Sinais de rodada
	round_registry.round_ending.connect(_on_round_ending)
	round_registry.all_players_disconnected.connect(_on_all_players_disconnected)
	round_registry.round_timeout.connect(_on_round_timeout)

func _setup_debug_timer():
	"""Cria timer para imprimir estados periodicamente"""
	var debug_timer_ = Timer.new()
	debug_timer_.wait_time = 5.0
	debug_timer_.autostart = true
	debug_timer_.timeout.connect(_print_player_states)
	add_child(debug_timer_)

# ===== CALLBACKS DE CONEXÃO =====

func _on_peer_connected(peer_id: int):
	"""Callback quando um cliente conecta ao servidor"""
	_log_debug("✓ Cliente conectado: Peer ID %d" % peer_id)
	
	# Adiciona peer ao PlayerRegistry
	player_registry.add_peer(peer_id)
	
	# Envia configurações do servidor para o cliente
	var configs: Dictionary = {
		"max_players_per_room": max_players_per_room,
		"min_players_to_start": min_players_to_start,
	}
	
	# Atualiza max_players_per_room e min_players_to_start para clientes
	NetworkManager.rpc_id(peer_id, "update_client_info", configs)
	
	# Sistema de teste automático (se ativado)
	if simulador_ativado and (multiplayer.get_peers().size() >= simulador_players_qtd) and test_manager:
		test_manager.criar_partida_teste()

func _on_peer_disconnected(peer_id: int):
	"""
	Callback quando um cliente desconecta
	
	ORDEM DE LIMPEZA:
	1. Remove da rodada (se estiver em uma)
	2. Remove da sala (se estiver em uma)
	3. Limpa estado de validação
	4. Remove do PlayerRegistry
	"""
	_log_debug("❌ Cliente desconectado: Peer ID %d" % peer_id)
	
	# 1. LIMPA RODADA (se estiver em uma)
	var p_round = round_registry.get_round_by_player_id(peer_id)
	if not p_round.is_empty():
		var round_id = p_round["round_id"]
		
		# Marca como desconectado
		round_registry.mark_player_disconnected(round_id, peer_id)
		_log_debug("  Marcado como desconectado na rodada %d" % round_id)
		
		# Remove registro de spawn
		round_registry.unregister_spawned_player(round_id, peer_id)
		
		# Remove node da cena do servidor
		var player_node = round_registry.get_spawned_player(round_id, peer_id)
		if player_node and is_instance_valid(player_node) and player_node.is_inside_tree():
			player_node.queue_free()
			_log_debug("Nó do player removido da cena")
		
		# Verifica se todos desconectaram (auto-end)
		if round_registry.get_active_player_count(round_id) == 0:
			_log_debug("Todos os players desconectaram - finalizando rodada")
			round_registry.end_round(round_id, "all_disconnected")
	
	# 2. LIMPA SALA (se estiver em uma)
	var player_data = player_registry.get_player(peer_id)
	var room = room_registry.get_player_room(peer_id)
	
	if not player_data.is_empty() and player_data["name"] != "":
		
		if not room.is_empty():
			var room_id = room["id"]
			
			# Remove da sala (pode deletá-la se ficar vazia)
			room_registry.remove_player_from_room(room_id, peer_id)
			_log_debug("%s Removido da sala: %s" % [peer_id, room["name"]])
			
			# Verifica se sala ainda existe antes de notificar
			if room_registry.room_exists(room_id):
				_notify_room_update(room_id)
				
				# Notifica outros jogadores da sala sobre a desconexão
				var updated_room = room_registry.get_room(room_id)
				for player in updated_room["players"]:
					if player["id"] != peer_id and _is_peer_connected(player["id"]):
						NetworkManager.rpc_id(player["id"], "_client_remove_player", peer_id)
			else:
				_log_debug("Sala foi deletada (ficou vazia)")
				_send_rooms_list_to_all()
	
	# 3. LIMPA ESTADO DE VALIDAÇÃO
	_cleanup_player_state(peer_id)
	
	# 4. REMOVE DO PLAYER REGISTRY (limpeza final)
	player_registry.remove_peer(peer_id)

# ===== HANDLERS DE JOGADOR =====

func _handle_register_player(peer_id: int, player_name: String):
	"""Processa solicitação de registro de nome de jogador"""
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
	
	# Valida nome
	var validation_result = _validate_player_name(player_name)
	if validation_result != "":
		_log_debug("❌ Nome rejeitado: " + validation_result)
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
	
	# Registra no PlayerRegistry
	var success = player_registry.register_player(peer_id, player_name)
	
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		NetworkManager.rpc_id(peer_id, "_client_name_accepted", player_name)
	else:
		_log_debug("❌ Falha ao registrar jogador")
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")

func _validate_player_name(player_name: String) -> String:
	"""
	Valida nome do jogador
	Retorna string vazia se válido, mensagem de erro caso contrário
	"""
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
	
	if player_registry.is_name_taken(trimmed_name):
		return "Este nome já está sendo usado"
	
	return ""

# ===== HANDLERS DE SALAS =====

func _handle_request_rooms_list(peer_id: int):
	"""Envia lista de salas disponíveis (não em jogo) para o cliente"""
	_log_debug("Cliente %d solicitou lista de salas" % peer_id)
	
	# Valida se player está registrado
	if not player_registry.is_player_registered(peer_id):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	# Busca salas disponíveis (fora de jogo)
	var available_rooms = room_registry.get_rooms_in_lobby()
	_log_debug("Enviando %d salas para o cliente" % available_rooms.size())
	
	NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list", available_rooms)

func _handle_create_room(peer_id: int, room_name: String, password: String):
	"""Cria uma nova sala e adiciona o criador como host"""
	var player = player_registry.get_player(peer_id)
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Criando sala '%s' para jogador %s (ID: %d)" % [room_name, player["name"], peer_id])
	
	# Valida nome da sala
	var validation = _validate_room_name(room_name)
	if validation != "":
		NetworkManager.rpc_id(peer_id, "_client_room_name_error", validation)
		return
	
	# Verifica se nome já existe
	if room_registry.room_name_exists(room_name):
		NetworkManager.rpc_id(peer_id, "_client_room_name_exists")
		return
	
	# Verifica se jogador já está em uma sala
	var current_room = room_registry.get_player_room(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala")
		return
	
	# Cria sala
	var room_id = next_room_id
	next_room_id += 1
	
	var room_data = room_registry.create_room(
		room_id,
		room_name,
		password,
		peer_id,
		min_players_to_start,
		max_players_per_room
	)
	
	if room_data.is_empty():
		_send_error(peer_id, "Erro ao criar sala")
		return
	
	_log_debug("✓ Sala criada: %s (ID: %d, Host: %s)" % [room_name, room_id, player["name"]])
	
	# Atualiza lista de salas para todos
	_send_rooms_list_to_all()
	
	# Confirma criação para o criador
	NetworkManager.rpc_id(peer_id, "_client_room_created", room_data)

func _validate_room_name(room_name: String) -> String:
	"""
	Valida nome da sala
	Retorna string vazia se válido, mensagem de erro caso contrário
	"""
	var trimmed = room_name.strip_edges()
	
	if trimmed.is_empty():
		return "O nome da sala não pode estar vazio"
	
	if trimmed.length() < 3:
		return "O nome da sala deve ter pelo menos 3 caracteres"
	
	if trimmed.length() > 30:
		return "O nome da sala deve ter no máximo 30 caracteres"
	
	return ""

func _handle_join_room(peer_id: int, room_id: int, password: String):
	"""Adiciona jogador a uma sala existente por ID"""
	var player = player_registry.get_player(peer_id)
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala ID: %d" % [player["name"], peer_id, room_id])
	
	# Verifica se já está em uma sala
	var current_room = room_registry.get_player_room(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	# Valida sala
	var room = room_registry.get_room(room_id)
	if room.is_empty():
		_send_error(peer_id, "Sala não encontrada")
		return
	
	# Verifica senha
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	# Adiciona à sala
	var success = room_registry.add_player_to_room(room_id, peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia ou em jogo)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	# Envia dados da sala para o jogador
	var room_data = room_registry.get_room(room_id)
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	# Notifica todos na sala sobre atualização
	_notify_room_update(room_id)

func _handle_join_room_by_name(peer_id: int, room_name: String, password: String):
	"""Adiciona jogador a uma sala existente por nome"""
	var player = player_registry.get_player(peer_id)
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala: '%s'" % [player["name"], peer_id, room_name])
	
	# Verifica se já está em uma sala
	var current_room = room_registry.get_player_room(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	# Busca sala por nome
	var room = room_registry.get_room_by_name(room_name)
	if room.is_empty():
		NetworkManager.rpc_id(peer_id, "_client_room_not_found")
		return
	
	# Verifica senha
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	# Adiciona à sala
	var success = room_registry.add_player_to_room(room["id"], peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia ou em jogo)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	# Envia dados da sala para o jogador
	var room_data = room_registry.get_room(room["id"])
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	# Notifica todos na sala sobre atualização
	_notify_room_update(room["id"])

func _handle_leave_room(peer_id: int):
	"""Remove jogador da sala atual"""
	var player = player_registry.get_player(peer_id)
	
	if player.is_empty() or not player.has("name"):
		return
	
	var room = room_registry.get_player_room(peer_id)
	if room.is_empty():
		return
	
	var room_id = room["id"]
	
	_log_debug("Jogador %s saiu da sala: %s" % [player["name"], room["name"]])
	
	# Remove da sala (pode deletá-la se ficar vazia)
	room_registry.remove_player_from_room(room_id, peer_id)
	
	# Verifica se sala ainda existe antes de notificar
	if room_registry.room_exists(room_id):
		_notify_room_update(room_id)
	else:
		_send_rooms_list_to_all()

func _handle_close_room(peer_id: int):
	"""Fecha uma sala (apenas host pode fazer isso)"""
	var player = player_registry.get_player(peer_id)
	
	if player.is_empty() or not player.has("name"):
		return
	
	var room = room_registry.get_player_room(peer_id)
	if room.is_empty():
		return
	
	# Verifica se é host
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode fechar a sala")
		return
	
	_log_debug("Host %s fechou a sala: %s" % [player["name"], room["name"]])
	
	var room_id = room["id"]
	
	# Notifica todos os players antes de deletar
	for room_player in room["players"]:
		if room_player["id"] != peer_id and _is_peer_connected(room_player["id"]):
			NetworkManager.rpc_id(room_player["id"], "_client_room_closed", "O host fechou a sala")
	
	# Remove sala
	room_registry.remove_room(room_id)
	
	# Atualiza lista global
	_send_rooms_list_to_all()

func _send_rooms_list_to_all():
	"""
	Envia lista de salas disponíveis para todos os jogadores no lobby
	(não envia para jogadores em partida)
	"""
	var available_rooms = room_registry.get_rooms_in_lobby()
	
	# Busca todos os jogadores que NÃO estão em rodada
	var lobby_players = []
	for player_data in player_registry.get_all_players():
		var peer_id = player_data["id"]
		if peer_id != 1 and not player_registry.in_round(peer_id):  # Ignora servidor (ID 1)
			lobby_players.append(peer_id)
	
	# Envia lista para cada um
	for peer_id in lobby_players:
		if _is_peer_connected(peer_id):
			NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list_update", available_rooms)

func _notify_room_update(room_id: int):
	"""Notifica todos os players de uma sala sobre atualização nos dados"""
	var room = room_registry.get_room(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		if _is_peer_connected(player["id"]):
			NetworkManager.rpc_id(player["id"], "_client_room_updated", room)

# ===== HANDLER DE INÍCIO DE RODADA =====

func _handle_start_round(peer_id: int, round_settings: Dictionary):
	"""
	Inicia uma nova rodada na sala
	
	FLUXO:
	1. Valida requisitos (host, players suficientes, etc)
	2. Cria rodada no RoundRegistry
	3. Gera spawn points
	4. Envia comando para clientes carregarem mapa
	5. Instancia rodada no servidor
	6. Inicia rodada (ativa timers)
	"""
	var player = player_registry.get_player(peer_id)
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	# Valida sala
	var room = room_registry.get_player_room(peer_id)
	if room.is_empty():
		_send_error(peer_id, "Você não está em nenhuma sala")
		return
	
	# Verifica se é host
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode iniciar a rodada")
		return
	
	# Valida requisitos para iniciar
	if not room_registry.can_start_match(room["id"]):
		var reqs = room_registry.get_match_requirements(room["id"])
		_send_error(peer_id, "Requisitos não atendidos: %d/%d jogadores (mínimo: %d)" % [
			reqs["current_players"],
			reqs["max_players"],
			reqs["min_players"]
		])
		return
	
	# Verifica se sala já está em jogo
	if room_registry.is_room_in_game(room["id"]):
		_send_error(peer_id, "A sala já está em uma rodada")
		return
	
	# LOG DO INÍCIO
	_log_debug("========================================")
	_log_debug("HOST INICIANDO RODADA")
	_log_debug("Sala: %s (ID: %d)" % [room["name"], room["id"]])
	_log_debug("Jogadores participantes:")
	
	for room_player in room["players"]:
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %d)%s" % [room_player["name"], room_player["id"], is_host_mark])
	
	_log_debug("========================================")
	
	# Cria rodada no RoundRegistry
	# IMPORTANTE: Isso JÁ chama player_registry.join_round() para cada player
	var round_data = round_registry.create_round(
		room["id"],
		room["name"],
		room["players"],
		round_settings
	)
	
	if round_data.is_empty():
		_send_error(peer_id, "Erro ao criar rodada")
		return
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room["id"], true)
	
	# Extrai configurações da rodada
	var final_settings = round_data.get("settings", {})
	var map_scene = final_settings.get("map_scene", "res://scenes/system/WorldGenerator.tscn")
	
	# Gera spawn points para todos os jogadores
	var players_count = round_registry.get_total_players(round_data["round_id"])
	final_settings["round_players_count"] = players_count
	final_settings["spawn_points"] = _create_spawn_points(players_count)
	
	# Gera dados de spawn para cada jogador
	var spawn_data = {}
	for i in range(room["players"].size()):
		var p = room["players"][i]
		spawn_data[p["id"]] = {
			"spawn_index": i,
			"team": 0
		}
	
	# Prepara pacote de dados para enviar aos clientes
	var match_data = {
		"round_id": round_data["round_id"],
		"room_id": room["id"],
		"map_scene": map_scene,
		"settings": final_settings,
		"players": room["players"],
		"spawn_data": spawn_data
	}
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room["players"]:
		NetworkManager.rpc_id(room_player["id"], "_client_round_started", match_data)
	
	# Instancia mapa e players no servidor também
	await _server_instantiate_round(match_data)
	
	# INICIA a rodada (ativa timers e verificações)
	round_registry.start_round(round_data["round_id"])
	
	# Atualiza lista de salas (remove esta sala da lista de disponíveis)
	_send_rooms_list_to_all()

func _create_spawn_points(match_players_count: int) -> Array:
	"""
	Gera pontos de spawn em formação circular
	Suporta de 1 a 14 jogadores com distribuição uniforme
	
	Retorna Array de Dictionaries: [{position: Vector3, rotation: Vector3}]
	"""
	spawn_points.clear()
	
	# Caso especial: apenas 1 jogador
	if match_players_count == 1:
		var spawn_data = {
			"position": spawn_center + Vector3(0, spawn_height, spawn_radius),
			"rotation": Vector3(0, PI, 0)  # Olhando para o centro
		}
		spawn_points.append(spawn_data)
		_log_debug("✓ Spawn point único criado no centro")
		return spawn_points
	
	# Limita entre 1 e 14 jogadores
	match_players_count = clamp(match_players_count, 1, 14)
	
	# Gera pontos em círculo
	for i in range(match_players_count):
		# Distribui uniformemente em círculo
		var angle = (i * 2.0 * PI) / match_players_count
		
		# Calcula posição base no círculo
		var base_x = cos(angle) * spawn_radius
		var base_z = sin(angle) * spawn_radius
		
		# Adiciona variação aleatória (se configurado)
		var variance_x = randf_range(-position_variance, position_variance)
		var variance_z = randf_range(-position_variance, position_variance)
		
		var final_position = spawn_center + Vector3(
			base_x + variance_x,
			spawn_height,
			base_z + variance_z
		)
		
		# Calcula rotação apontando PARA o centro
		var to_center = spawn_center - final_position
		var rotation_y = atan2(to_center.x, to_center.z)
		
		# Adiciona variação aleatória à rotação
		rotation_y += randf_range(-rotation_variance, rotation_variance)
		
		var spawn_data = {
			"position": final_position,
			"rotation": Vector3(0, rotation_y, 0)
		}
		
		spawn_points.append(spawn_data)
	
	_log_debug("✓ Spawn points criados: %d jogadores em círculo (raio: %.1f)" % [spawn_points.size(), spawn_radius])
	return spawn_points

# ===== INSTANCIAÇÃO NO SERVIDOR =====

func _server_instantiate_round(match_data: Dictionary):
	"""
	Instancia a rodada no servidor (mapa e players)
	Chamado após enviar comando para clientes carregarem
	"""
	_log_debug("Instanciando rodada no servidor...")
	
	# Cria MapManager
	server_map_manager = preload("res://scripts/gameplay/MapManager.gd").new()
	get_tree().root.add_child(server_map_manager)
	
	# Carrega o mapa
	await server_map_manager.load_map(match_data["map_scene"], match_data["settings"])
	
	# Salva referência no RoundRegistry
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = server_map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		_spawn_player_on_server(player_data, spawn_data)
	
	_log_debug("✓ Rodada instanciada no servidor")

func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary):
	"""
	Spawna um jogador no servidor (versão autoritativa)
	Registra node e inicializa estado para validação
	"""
	var player_scene = preload("res://scenes/system/player_warrior.tscn")
	var player_instance = player_scene.instantiate()
	
	# CONFIGURAÇÃO CRÍTICA: Nome = ID do peer
	player_instance.name = str(player_data["id"])
	player_instance.player_id = player_data["id"]
	player_instance.player_name = player_data["name"]
	
	# IMPORTANTE: No servidor, nenhum player é "local"
	player_instance.is_local_player = false
	
	# Adiciona à cena
	get_tree().root.add_child(player_instance)
	
	# Registra node no PlayerRegistry
	player_registry.register_player_node(player_data["id"], player_instance)
	
	# Posiciona
	var spawn_pos = server_map_manager.get_spawn_position(spawn_data["spawn_index"])
	player_instance.initialize(player_data["id"], player_data["name"], spawn_pos)
	
	# Registra no RoundRegistry
	var p_round = round_registry.get_round_by_player_id(player_instance.player_id)
	if not p_round.is_empty():
		round_registry.register_spawned_player(p_round["round_id"], player_data["id"], player_instance)
	
	# INICIALIZA ESTADO PARA VALIDAÇÃO ANTI-CHEAT
	player_states[player_data["id"]] = {
		"pos": spawn_pos,
		"vel": Vector3.ZERO,
		"rot": Vector3.ZERO,
		"timestamp": Time.get_ticks_msec()
	}
	
	_log_debug("✓ Player spawnado no servidor: %s (ID: %d) em %s" % [
		player_data["name"], 
		player_data["id"],
		spawn_pos
	])

# ===== CALLBACKS DE RODADA =====

func _on_round_ending(round_id: int, reason: String):
	"""
	Callback quando uma rodada está terminando
	Aguarda tempo de transição antes de finalizar completamente
	"""
	_log_debug("Rodada %d finalizando. Razão: %s" % [round_id, reason])
	
	# Aguarda tempo de transição (para mostrar resultados)
	await get_tree().create_timer(round_transition_time).timeout
	
	# Finaliza completamente a rodada
	_complete_round_end(round_id)

func _on_all_players_disconnected(round_id: int):
	"""
	Callback quando todos os players desconectam da rodada
	Finaliza rodada imediatamente
	"""
	_log_debug("⚠ Todos os players desconectaram da rodada %d" % round_id)
	
	# Finaliza rodada imediatamente (sem aguardar)
	round_registry.end_round(round_id, "all_disconnected")

func _on_round_timeout(round_id: int):
	"""
	Callback quando o tempo máximo da rodada é atingido
	Finaliza rodada por timeout
	"""
	_log_debug("⏱ Tempo máximo da rodada %d atingido" % round_id)
	
	# Finaliza rodada por timeout
	round_registry.end_round(round_id, "timeout")

# ===== FIM DE RODADA =====

func _complete_round_end(round_id: int):
	"""
	Completa o fim da rodada e retorna players à sala
	
	ORDEM:
	1. Adiciona ao histórico da sala
	2. Limpa objetos da cena
	3. Finaliza no RoundRegistry
	4. Marca sala como fora de jogo
	5. Notifica clientes para voltar ao lobby
	"""
	var round_data = round_registry.get_round(round_id)
	
	if round_data.is_empty():
		_log_debug("⚠ Tentou finalizar rodada inexistente: %d" % round_id)
		return
	
	var room_id = round_data["room_id"]
	
	# LOG DE FINALIZAÇÃO
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
	
	# Limpa objetos da rodada (players, mapa, etc)
	_cleanup_round_objects(round_id)
	
	# Finaliza completamente no RoundRegistry
	# IMPORTANTE: Isso adiciona ao histórico da sala automaticamente
	round_registry.complete_round_end(round_id)
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room_id, false)
	
	# Notifica clientes para voltar à sala
	var room = room_registry.get_room(room_id)
	if not room.is_empty():
		for player in room["players"]:
			if _is_peer_connected(player["id"]):
				NetworkManager.rpc_id(player["id"], "_client_return_to_room", room)
	
	# Atualiza lista de salas (sala volta a ficar disponível)
	_send_rooms_list_to_all()

func _cleanup_round_objects(round_id: int):
	"""
	Limpa todos os objetos da rodada
	Remove players spawnados e mapa da cena
	"""
	_log_debug("Limpando objetos da rodada %d..." % round_id)
	
	# Remove players da cena
	var spawned_players = round_registry.get_all_spawned_players(round_id)
	for player_node in spawned_players:
		if is_instance_valid(player_node) and player_node.is_inside_tree():
			player_node.queue_free()
	
	# Remove mapa
	if server_map_manager and is_instance_valid(server_map_manager):
		server_map_manager.unload_map()
		server_map_manager.queue_free()
		server_map_manager = null
	
	_log_debug("✓ Limpeza completa")

# ===== VALIDAÇÃO ANTI-CHEAT =====

func _validate_player_movement(p_id: int, pos: Vector3, vel: Vector3, rot: Vector3 = Vector3.ZERO) -> bool:
	"""
	Valida se o movimento do jogador é razoável (anti-cheat)
	
	VALIDAÇÕES:
	1. Distância máxima percorrida no intervalo de tempo
	2. Velocidade reportada vs velocidade máxima permitida
	3. Discrepância entre velocidade real e reportada
	
	Retorna true se válido, false se suspeito de hack
	"""
	
	# Se anti-cheat desativado, sempre aceita
	if not enable_anticheat:
		return true
	
	# Se não tem estado anterior, aceita (primeira sincronização)
	if not player_states.has(p_id):
		player_states[p_id] = {
			"pos": pos,
			"vel": vel,
			"rot": rot,
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
	
	# VALIDAÇÃO 1: Distância máxima permitida
	var max_distance = max_player_speed * time_diff * speed_tolerance
	
	if distance > max_distance:
		_log_debug("⚠️ ANTI-CHEAT: Distância suspeita")
		_log_debug("Player: %d" % p_id)
		_log_debug("Distância: %.2f m em %.3f s" % [distance, time_diff])
		_log_debug("Máximo: %.2f m" % max_distance)
		_log_debug("Velocidade: %.2f m/s (máx: %.2f m/s)" % [distance/time_diff, max_player_speed * speed_tolerance])
		return false
	
	# VALIDAÇÃO 2: Velocidade reportada vs máxima
	var reported_speed = vel.length()
	
	if reported_speed > max_player_speed * speed_tolerance:
		_log_debug("⚠️ ANTI-CHEAT: Velocidade reportada suspeita")
		_log_debug("Player: %d" % p_id)
		_log_debug("Reportada: %.2f m/s" % reported_speed)
		_log_debug("Máximo: %.2f m/s" % (max_player_speed * speed_tolerance))
		return false
	
	# VALIDAÇÃO 3: Discrepância entre velocidade real e reportada
	var actual_speed = distance / time_diff if time_diff > 0 else 0
	
	if abs(actual_speed - reported_speed) > max_player_speed * 0.5:
		_log_debug("⚠️ ANTI-CHEAT: Discrepância entre velocidade real e reportada")
		_log_debug("Player: %d" % p_id)
		_log_debug("Real: %.2f m/s" % actual_speed)
		_log_debug("Reportada: %.2f m/s" % reported_speed)
		# Nota: Não retorna false aqui, pois pode ser lag legítimo
	
	# ATUALIZA ESTADO PARA PRÓXIMA VALIDAÇÃO
	player_states[p_id] = {
		"pos": pos,
		"vel": vel,
		"rot": rot,
		"timestamp": current_time
	}
	
	return true

func _apply_player_state_on_server(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	var node = player_registry.get_player_node(p_id)
	if not (node and node.is_inside_tree()):
		return
	
	# Aplica no nó
	node.global_position = pos
	node.global_rotation = rot
	if node.has_method("set_velocity"):
		node.set_velocity(vel)
	
	# Atualiza estado interno
	if node.has_method("_set_state"):
		node._set_state({"running": running, "jumping": jumping})
	
	# Atualiza player_states para validação futura
	player_states[p_id] = {
		"pos": pos,
		"rot": rot,
		"vel": vel,
		"running": running,
		"jumping": jumping,
		"timestamp": Time.get_ticks_msec()
	}

func _rpc_despawn_on_clients(player_ids: Array, round_id: int, object_id: int):
	"""
	Envia comando de despawn para clientes
	Chamado pelo ObjectManager.despawn_object()
	"""
	
	if not multiplayer.is_server():
		return
	
	# Envia RPC para cada cliente
	for player_id in player_ids:
		if player_id == 1:  # Ignora servidor
			continue
		
		NetworkManager._rpc_client_despawn_item.rpc_id(player_id, object_id, round_id)

# ===== VALIDAÇÃO DE ITENS =====

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_pick_up_item(requesting_player_id: int, object_id: int):
	"""Servidor recebe pedido de pegar item, equipa automaticamente se for equipável, valida e redistribui"""
	
	var player_node = get_tree().root.get_node_or_null(str(requesting_player_id))
	var object = object_manager.spawned_objects[1][object_id]
	var server_nearby = player_node.get_nearby_items()
	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	var item = ItemDatabase.get_item(object["item_name"]).to_dictionary()
	var round_players = round_registry.get_active_players_ids(round_["round_id"])
	
	# Verificação se o item está perto do player no servidor também
	if not server_nearby.has(object["node"]):
		_log_debug("O nó deste player no servidor não tem este item por perto para pickup, recusar!")
		return
	
	_log_debug("[ITEM] Player %s pediu para pegar item %d, no round %d" % [player["name"], object_id, round_["round_id"]])
	
	# Se for item equipável de knight
	if ItemDatabase.get_items_by_owner("knight"):
		# Dropar o item anterior se houver
		var item_type = ItemDatabase.get_item_type(item["name"])
		var item_ = player_registry.get_equipped_item_in_slot(round_["round_id"], player["id"], item_type)
		if item_:
			player_registry.unequip_item(round_["round_id"], player["id"], item_type)
			player_registry.remove_item_from_inventory(round_["round_id"], player["id"], item_)
			drop_item(round_["round_id"], player["id"], item_.id)
			
		# Equipar o item novo
		player_registry.add_item_to_inventory(round_["round_id"], player["id"], item["name"])
		player_registry.equip_item(round_["round_id"], player["id"], item["name"])
		
		# Aplica nas cenas dos clientes para o player requerente
		for peer_id in multiplayer.get_peers():
			if _is_peer_connected(peer_id):
				print("[222]: ", item["id"])
				NetworkManager.rpc_id(peer_id, "server_apply_equiped_item", requesting_player_id, item["id"])
				NetworkManager.rpc_id(peer_id, "server_apply_picked_up_item", requesting_player_id)
		
		# Aplica na cena do servidor (atualizar visual)
		if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(player_node, item["id"])
			player_node.action_pick_up_item()
		
		# Despawn do objeto no mapa dos clientes
		_rpc_despawn_on_clients(round_players, round_["round_id"], object_id)
		
		# Despawn do objeto no mapa do servidor
		var item_node = object.get("node")
		if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
			item_node.queue_free()
			_log_debug("Node removido da cena")
		
		# Remove do registro local
		object_manager.spawned_objects[round_["round_id"]].erase(object_id)
	
@rpc("any_peer", "call_remote", "reliable")
func _server_validate_equip_item(requesting_player_id: int, item_id: int, from_test: bool):
	"""Servidor recebe pedido de equipar item, valida e redistribui"""
	
	# Verifica se pode aplicar pelo handle_test_equip_inputs_call, 
	# se simulador_ativado, sim:
	if from_test and not simulador_ativado:
		return
	
	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	var item = ItemDatabase.get_item_by_id(item_id)
	var item_slot = item.get_slot()
	_log_debug("[ITEM]📦 Player %s pediu para equipar item %d, no round %d" % [player["name"], item_id, round_["round_id"]])
	# FAZER TODAS AS VALIDAÇÕES DE EQUIPAR ITEM NO CLIENTE
	
	# Verifica se o id do item é válido
	if not ItemDatabase.get_item_by_id(item_id):
		return
	
	# Verificar se o player já tem o item no slot deste item, se não, equipar este item, se sim, eqipar o novo e dropar o anterior
	if not player_registry.is_slot_empty(round_["round_id"], player['id'], item_slot):
		# Dropar o item anterior
		var item_anterior = player_registry.get_equipped_item_in_slot(round_["round_id"], player['id'], item_slot)
		var item_ant_id = ItemDatabase.get_item(item_anterior)["id"]
		drop_item(round_["round_id"], player['id'], item_ant_id)
	
	# Add no inventário
	player_registry.add_item_to_inventory(round_["round_id"], player['id'], item["name"])
	
	# Equipa o item
	player_registry.equip_item(round_["round_id"], player['id'], item["name"])
	
	_log_debug("[ITEM]📦 Item equipado validado: Player %d equipou item %d" % [requesting_player_id, item_id])
	_log_debug("[ITEM]📦 Itens equipados no player: %s" % str(player_registry.get_equipped_items(round_["round_id"], player['id'])))
	
	# Envia para todos os clientes do round (para atualizar visual)
	
	# FALTA APLICAR À APENAS O PLAYERS DO ROUND REFERENTE \/\/\/

	for peer_id in multiplayer.get_peers():
		if _is_peer_connected(peer_id):
			print("[222]: ", item_id)
			NetworkManager.rpc_id(peer_id, "server_apply_equiped_item", requesting_player_id, item_id)
	
	# Aplica na cena do servidor (atualizar visual)
	var player_node = get_tree().root.get_node_or_null(str(requesting_player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(player_node, item_id)
			
@rpc("any_peer", "call_remote", "reliable")
func _server_validate_drop_item(requesting_player_id: int, item_id: int):
	"""Servidor recebe pedido de drop, valida e spawna item executando drop_item()
	IMPORTANTE: USA ESTADO DO SERVIDOR, não do cliente"""
	_log_debug("[ITEM]📦 Servidor vai validar pedido de drop de item %d do player ID %s" % [item_id, requesting_player_id])
	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	
	if not ItemDatabase.get_item_by_id(item_id) and item_id != 0:
		push_warning("ServerManager: ID de item inválido recebido: %d" % item_id)
		return
	
	if not player_states.has(requesting_player_id):
		push_warning("ServerManager: Player %d não tem estado registrado" % requesting_player_id)
		return
				
	if round_registry.get_round_state(round_["round_id"]) != "playing":
		push_warning("ServerManager: Round inválido, não está em partida")
		return
		
	_log_debug("[ITEM]📦 Player %s pediu para dropar item %d, no round %d" % [player["name"], item_id, round_["round_id"]])
	drop_item(round_["round_id"], player["id"], item_id)

func drop_item(round_id, player_id, item_id):
	# Se item_id == 0, é pedido do player, pegar o item de menor valor do player
	# Se não, é pedido do server, pegar item_id que veio e dropar
	var item_name = null
	if item_id == 0:
		item_name = player_registry.get_first_equipped_item(round_id, player_id)
	
		# Valida estado do player NO SERVIDOR
		if item_name:
			var item_type = ItemDatabase.get_item_type(item_name)
			var first_item = ItemDatabase.get_item(item_name).to_dictionary()
			player_registry.unequip_item(round_id, player_id, item_type)
			player_registry.remove_item_from_inventory(round_id, player_id, item_name)
			_log_debug("[ITEM]📦 Itens equipados no player: %s" % str(player_registry.get_equipped_items(round_id, player_id)))
			
			# ObjectManager cuida de spawnar E enviar RPC
			# Não precisa chamar NetworkManager diretamente
			object_manager.spawn_item_in_front_of_player(round_id, player_id, item_name)
			
			# Atualiza o inventário do player
			player_registry.drop_item(round_id, player_id, item_name)
			
			# Aplica na cena do servidor (atualizar visual)
			var player_node = get_tree().root.get_node_or_null(str(player_id))
			if player_node and player_node.has_method("execute_item_drop"):
				player_node.execute_item_drop(player_node, item_name)
				
			# Aplica na cena dos clientes no round (atualizar visual)
			var players_ids_round = round_registry.get_active_players_ids(round_id)
			for peer_id in multiplayer.get_peers():
				if _is_peer_connected(peer_id) and peer_id in players_ids_round:
					NetworkManager.rpc_id(peer_id, "server_apply_drop_item", player_id, first_item['name'])
		else:
			_log_debug("[ITEM]📦 Não tem item no inventário do player")
	else:
		var item_data = ItemDatabase.get_item_by_id(item_id)
		if item_data:
			player_registry.drop_item(round_id, player_id, item_data.name)
			object_manager.spawn_item_in_front_of_player(round_id, player_id, item_data.name)

# ===== UTILITÁRIOS =====

func _get_position_front_and_above(pos: Vector3, rot: Vector3, dist: float = 1.5, height: float = 1.2) -> Vector3:
	"""
	Calcula posição na frente e acima do player
	@param pos: Posição do player
	@param rot: Rotação do player (Euler angles)
	@param dist: Distância na frente (positivo = frente)
	@param height: Altura acima do player
	"""
	var basis = Basis.from_euler(rot)
	var forward: Vector3 = basis.z  # -Z é frente no Godot
	return pos + forward * dist + Vector3.UP * height

func shutdown_registry():
	"""
	Desliga servidor completamente e limpa todos os recursos
	
	ORDEM:
	1. Finaliza todas as rodadas ativas
	2. Remove todas as salas
	3. Desconecta todos os jogadores
	4. Reseta registries
	"""
	_log_debug("========================================")
	_log_debug("DESLIGANDO SERVIDOR")
	_log_debug("========================================")
	
	# 1. Finaliza todas as rodadas ativas
	for round_id in round_registry.get_all_rounds().keys():
		round_registry.end_round(round_id, "server_shutdown")
		round_registry.complete_round_end(round_id)
	
	# 2. Remove todas as salas
	var all_rooms = room_registry.get_rooms_list(true)
	for room_data in all_rooms:
		room_registry.remove_room(room_data["id"])
	
	# 3. Desconecta todos os jogadores
	for player_data in player_registry.get_all_players():
		var peer_id = player_data["id"]
		if _is_peer_connected(peer_id):
			multiplayer.disconnect_peer(peer_id)
	
	# 4. Reseta registries
	round_registry.reset()
	room_registry.reset()
	player_registry.reset()
	
	_log_debug("✓ Servidor desligado completamente")

func _cleanup_player_state(peer_id: int):
	"""
	Remove estado de validação do jogador
	Chamado quando desconecta
	"""
	if player_states.has(peer_id):
		player_states.erase(peer_id)
		_log_debug("Estado de validação removido")

func _kick_player(peer_id: int, reason: String):
	"""
	Kicka um jogador do servidor (anti-cheat ou outras razões)
	Remove da rodada, sala e desconecta
	"""
	_log_debug("========================================")
	_log_debug("⚠️ KICKANDO JOGADOR")
	_log_debug("Peer ID: %d" % peer_id)
	_log_debug("Razão: %s" % reason)
	_log_debug("========================================")
	
	# Remove da rodada se estiver em uma
	var p_round = round_registry.get_round_by_player_id(peer_id)
	if not p_round.is_empty():
		var round_id = p_round["round_id"]
		round_registry.mark_player_disconnected(round_id, peer_id)
		round_registry.unregister_spawned_player(round_id, peer_id)
		
		var player_node = round_registry.get_spawned_player(round_id, peer_id)
		if player_node and is_instance_valid(player_node) and player_node.is_inside_tree():
			player_node.queue_free()
	
	# Remove da sala
	var room = room_registry.get_player_room(peer_id)
	if not room.is_empty():
		room_registry.remove_player_from_room(room["id"], peer_id)
		
		# Notifica se sala ainda existe
		if room_registry.room_exists(room["id"]):
			_notify_room_update(room["id"])
	
	# Envia notificação de kick
	if _is_peer_connected(peer_id):
		NetworkManager.rpc_id(peer_id, "_client_error", "🚫 Você foi desconectado: " + reason)
	
	# Desconecta após 1 segundo
	await get_tree().create_timer(1.0).timeout
	
	if multiplayer.has_multiplayer_peer() and _is_peer_connected(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		_log_debug("✓ Player desconectado")

func _send_error(peer_id: int, message: String):
	"""Envia mensagem de erro para um cliente"""
	_log_debug("❌ Enviando erro para cliente %d: %s" % [peer_id, message])
	if _is_peer_connected(peer_id):
		NetworkManager.rpc_id(peer_id, "_client_error", message)

func _is_peer_connected(peer_id: int) -> bool:
	"""Verifica se um peer ainda está conectado"""
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		print("[SERVERMANAGER]" + message)

# ===== DEBUG =====

func _print_player_states():
	"""Debug: Imprime estados de todos os players para validação"""
	_log_debug("========================================")
	_log_debug("ESTADOS DOS JOGADORES NO SERVIDOR")
	_log_debug("Total: %d" % player_states.size())
	
	for p_id in player_states.keys():
		var state = player_states[p_id]
		var age = (Time.get_ticks_msec() - state["timestamp"]) / 1000.0
		
		_log_debug("Player %d:" % p_id)
		_log_debug("Pos: %s" % str(state["pos"]))
		_log_debug("Vel: %s (%.2f m/s)" % [str(state["vel"]), state["vel"].length()])
		_log_debug("Rot: %s" % str(state["rot"]))
		_log_debug("Última atualização: %.2f s atrás" % age)
	
	_log_debug("========================================")
