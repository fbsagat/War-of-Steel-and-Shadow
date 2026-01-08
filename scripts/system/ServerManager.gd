extends Node
class_name ServerManager

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
## [TESTES] Usa o TestManager para iniciar logo uma partida na execução
@export var fast_round: bool = true
## [TESTES] Define a quantidade de instnacias de clientes para executar fast_round
@export var simulador_players_qtd: int = 2
## [TESTES] Dropa itens perto dos players e ativa o trainer de cada player
@export var item_trainer: bool = true

@export_category("Server Settings")
@export var server_port: int = 7777
@export var max_clients: int = 32
@export var is_headless : bool

@export_category("Default Node References")
const map_scene : String = "res://scenes/gameplay/terrain_3d.tscn"
const player_scene : String = "res://scenes/gameplay/player_warrior.tscn"
const camera_controller : String = "res://scenes/system/camera_controller.tscn"
const server_camera : String = "res://scenes/server_scenes/server_camera.tscn"

@export_category("Room Settings")
@export var max_players_per_room: int = 12
@export var min_players_to_start: int = 1

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
@export var enable_anticheat: bool = false

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var network_manager: NetworkManager = null
var player_registry : PlayerRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var item_database: ItemDatabase = null
var object_manager: ObjectManager = null
var test_manager: TestManager = null
var map_manager: Node = null
var all_rounds_node: Node = null
var current_cam_round_index: int = -1
var current_active_camera: Camera3D = null
var mouse_mode: bool = true
var current_active_viewport: SubViewport = null  # Adicione esta
var viewport_display: TextureRect = null


# ===== VARIÁVEIS INTERNAS =====

## ID incremental para criação de salas
var next_room_id: int = 1

## Rastreamento de estados dos jogadores para validação anti-cheat
## Formato: {peer_id: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
var player_states: Dictionary = {}

# ===== INICIALIZAÇÃO =====

func _ready() -> void:
	pass

func initialize():
	_start_server()
	_connect_signals()
		
	# Timer de debug opcional
	if debug_timer:
		_setup_debug_timer()
	
	# Cria nó organizacional para os Rounds
	all_rounds_node = Node.new()
	get_tree().root.add_child(all_rounds_node)
	all_rounds_node.name = "All_Rounds"
	
	# Cria uma SubViewportContainer chamada ActiveRoundDisplay para exibir as câmeras(uma por vez)
	# das rodadas em curso, se is_headless estiver desativado
	if not is_headless:
		_setup_viewport_display()

func _setup_viewport_display():
	"""Cria um TextureRect que mostra o viewport atual na tela"""
	viewport_display = TextureRect.new()
	viewport_display.name = "ViewportDisplay"
	viewport_display.anchor_right = 1.0
	viewport_display.anchor_bottom = 1.0
	viewport_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	viewport_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	viewport_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Adiciona como child direto da raiz para preencher a tela
	get_tree().root.add_child(viewport_display)
	
	_log_debug("Display do viewport criado")

func _unhandled_input(event: InputEvent) -> void:
	"""Redireciona inputs para o viewport/câmera ativa"""
	if is_headless or not current_active_viewport:
		return
	
	# Não processa Tab (já é usado para trocar câmera)
	if event is InputEventKey and event.keycode == KEY_TAB:
		return
	
	# Envia o evento para o viewport ativo
	current_active_viewport.push_input(event, true)
	
func _input(event: InputEvent) -> void:
	if is_headless:
		return
		
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_log_debug("Movendo câmera do servidor para a próxima partida")
		var round_nodes := all_rounds_node.get_children()
		if round_nodes.is_empty():
			return
		# avança circularmente
		current_cam_round_index = (current_cam_round_index + 1) % round_nodes.size()
		var next_round := round_nodes[current_cam_round_index]
		_switch_camera_to_round(next_round)
	
	if event.is_action_pressed("ui_cancel"):
		_toggle_mouse_mode()
		
func _switch_camera_to_round(round_node: Node) -> void:
	"""
	Ativa a câmera de um round E atualiza o display
	"""
	if not round_node or not round_node is SubViewport:
		push_warning("round_node inválido")
		return
	
	# Desativa câmera anterior
	if current_active_camera and is_instance_valid(current_active_camera):
		current_active_camera.current = false
		current_active_camera.set_process_input(false)
		current_active_camera.set_process_unhandled_input(false)
	
	# Busca nova câmera
	var new_camera = round_node.get_node_or_null("FreeCamera")
	if not new_camera:
		new_camera = round_node.get_node_or_null("DummyCamera")
	
	if new_camera and new_camera is Camera3D:
		new_camera.current = true
		current_active_camera = new_camera
		current_active_viewport = round_node
		
		# ATUALIZA O DISPLAY COM A TEXTURA DESTE VIEWPORT
		if viewport_display:
			viewport_display.texture = round_node.get_texture()
		
		# ATIVA O PROCESSAMENTO DE INPUT DA CÂMERA
		new_camera.set_process_input(true)
		new_camera.set_process_unhandled_input(true)

		_log_debug("✓ Câmera ativada: %s em %s" % [new_camera.name, round_node.name])
	else:
		push_warning("✗ Câmera não encontrada em %s" % round_node.name)

func _toggle_mouse_mode():
	mouse_mode = not mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if not mouse_mode else Input.MOUSE_MODE_CAPTURED

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
	
	_log_debug("✓ Servidor inicializado com sucesso!")

func _connect_signals():
	"""Conecta sinais dos registries"""
	# Sinais de rodada
	round_registry.round_ending.connect(_on_round_ending)
	round_registry.all_players_disconnected.connect(_on_all_players_disconnected)

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
	network_manager.rpc_id(peer_id, "update_client_info", configs)
	
	# Sistema de teste automático (se ativado)
	if fast_round and (multiplayer.get_peers().size() == simulador_players_qtd) and test_manager:
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
						network_manager.rpc_id(player["id"], "_client_remove_player", peer_id)
			else:
				_log_debug("Sala foi deletada (ficou vazia)")
				_send_rooms_list_to_all()
	
	# 3. Limpa estado de validação
	_cleanup_player_state(peer_id)
	
	# 4. Remove do player registry (limpeza final)
	player_registry.remove_peer(peer_id)

# ===== HANDLERS DE JOGADOR =====

func _handle_register_player(peer_id: int, player_name: String):
	"""Processa solicitação de registro de nome de jogador"""
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
	
	# Valida nome
	var validation_result = _validate_player_name(player_name)
	if validation_result != "":
		_log_debug("❌ Nome rejeitado: " + validation_result)
		network_manager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
	
	# Registra no PlayerRegistry
	var success = player_registry.register_player(peer_id, player_name)
	
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		network_manager.rpc_id(peer_id, "_client_name_accepted", player_name)
	else:
		_log_debug("❌ Falha ao registrar jogador")
		network_manager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")

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
	var available_rooms = room_registry.get_rooms_in_lobby_clean_to_menu()
	_log_debug("Enviando %d salas para o cliente, qtd: " % available_rooms.size())
	
	network_manager.rpc_id(peer_id, "_client_receive_rooms_list", available_rooms)

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
		network_manager.rpc_id(peer_id, "_client_room_name_error", validation)
		return
	
	# Verifica se nome já existe
	if room_registry.room_name_exists(room_name):
		network_manager.rpc_id(peer_id, "_client_room_name_exists")
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
	network_manager.rpc_id(peer_id, "_client_room_created", room_data)

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
		network_manager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	# Adiciona à sala
	var success = room_registry.add_player_to_room(room_id, peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia ou em jogo)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	# Envia dados da sala para o jogador
	var room_data = room_registry.get_room(room_id)
	network_manager.rpc_id(peer_id, "_client_joined_room", room_data)
	
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
		network_manager.rpc_id(peer_id, "_client_room_not_found")
		return
	
	# Verifica senha
	if room["has_password"] and room["password"] != password:
		network_manager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	# Adiciona à sala
	var success = room_registry.add_player_to_room(room["id"], peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia ou em jogo)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	# Envia dados da sala para o jogador
	var room_data = room_registry.get_room(room["id"])
	network_manager.rpc_id(peer_id, "_client_joined_room", room_data)
	
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
			network_manager.rpc_id(room_player["id"], "_client_room_closed", "O host fechou a sala")
	
	# Remove sala
	room_registry.remove_room(room_id)
	
	# Atualiza lista global
	_send_rooms_list_to_all()

func _send_rooms_list_to_all():
	"""
	Envia lista de salas disponíveis para todos os jogadores no lobby
	(não envia para jogadores em partida)
	"""
	var available_rooms = room_registry.get_rooms_in_lobby_clean_to_menu()
	
	# Busca todos os jogadores que NÃO estão em rodada
	var lobby_players = []
	for player_data in player_registry.get_all_players():
		var peer_id = player_data["id"]
		if peer_id != 1 and not player_registry.in_round(peer_id):  # Ignora servidor (ID 1)
			lobby_players.append(peer_id)
	
	# Envia lista para cada um
	for peer_id in lobby_players:
		if _is_peer_connected(peer_id):
			network_manager.rpc_id(peer_id, "_client_receive_rooms_list_update", available_rooms)

func _notify_room_update(room_id: int):
	"""Notifica todos os players de uma sala sobre atualização nos dados"""
	var room = room_registry.get_room(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		if _is_peer_connected(player["id"]):
			network_manager.rpc_id(player["id"], "_client_room_updated", room)

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

	# Criar cena de organização do round
	var round_node = SubViewport.new()
	round_node.own_world_3d = true
	round_node.name = "Round_%d_%d" % [room["id"], round_data["round_id"]]
	
	round_data["round_node"] = round_node
	
	# Configurações para renderização fora de container
	round_node.size = Vector2i(1920, 1080)  # ou resolução da janela
	round_node.render_target_update_mode = SubViewport.UPDATE_ALWAYS  # ← força renderização
	
	all_rounds_node.add_child(round_node)
	
	round_registry.set_round_node(round_data["round_id"], round_node)
	
	# Cria nós organizacionais
	var players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	var objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	if round_data.is_empty():
		_send_error(peer_id, "Erro ao criar rodada")
		return
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room["id"], true)
	
	# Extrai configurações da rodada
	var final_settings = round_data.get("settings", {})
	var map_scene_ = final_settings.get("map_scene", map_scene)
	
	# Gera spawn points para todos os jogadores
	var players_count: int = round_registry.get_total_players(round_data["round_id"])
	final_settings["round_players_count"] = players_count
	final_settings["spawn_points"] = map_manager._create_spawn_points(players_count)
	
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
		"map_scene": map_scene_,
		"settings": final_settings,
		"players": room["players"],
		"spawn_data": spawn_data
	}
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room["players"]:
		network_manager.rpc_id(room_player["id"], "_client_round_started", match_data)
	
	# Instancia mapa e players no servidor também
	await _server_instantiate_round(match_data, round_node, players_node)
	
	# INICIA a rodada (ativa timers e verificações)
	round_registry.start_round(round_data["round_id"])
	
	if item_trainer:
		# Spawna alguns objetos
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(1, 4, 1), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "steel_helmet", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "cape_1", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "sword_2", Vector3(2, 30, 1), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "shield_3", Vector3(0, 500, 0), Vector3(0, 0, 0))
	
	# Atualiza lista de salas (remove esta sala da lista de disponíveis)
	_send_rooms_list_to_all()
	
	# Se não headless, joga este primeiro round para a camera do servidor
	if not is_headless and round_data["round_id"] <= 1:
		_switch_camera_to_round(round_node)

# ===== INSTANCIAÇÃO NO SERVIDOR =====

func _server_instantiate_round(match_data: Dictionary, round_node, players_node):
	"""
	Instancia a rodada no servidor (mapa e players)
	Chamado após enviar comando para clientes carregarem
	"""
	
	_log_debug("Instanciando rodada no servidor...")
	
	# Carrega o mapa
	await map_manager.load_map(match_data["map_scene"], round_node, match_data["settings"])
	var terrain_3d = round_node.get_node_or_null("Terrain3D")
	
	# Salva referência no RoundRegistry
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		_spawn_player_on_server(player_data, spawn_data, players_node)
	
	# Cria câmera livre se não estiver em modo headless
	var actual_camera: Camera3D = null
	if not is_headless:
		actual_camera = preload(server_camera).instantiate()
		actual_camera.name = "FreeCamera"
		round_node.add_child(actual_camera)
		actual_camera.global_position = Vector3(0, 3, 5)  # X=0, Y=10 (altura), Z=15 (distância)
		actual_camera.current = true
		await get_tree().process_frame
	else:
		# Se estiver em modo headless criar uma câmera dummy
		actual_camera = Camera3D.new()
		actual_camera.name = "DummyCamera"
		round_node.add_child(actual_camera)
		actual_camera.global_position = Vector3(0, 100, 0)
		actual_camera.current = false
		await get_tree().process_frame
	
	# Se for o primeiro round, esta é a câmera atual
	if match_data["round_id"] != 1 and not is_headless:
		actual_camera.current = false
	
	# Configura o Terrain3D para usar actual_camera
	if terrain_3d:
		terrain_3d.set_camera(actual_camera)
	else:
		push_warning("terrain_3d não encontrado para configurar câmera")

func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary, players_node):
	"""
	Spawna um jogador no servidor (versão autoritativa)
	Registra node e inicializa estado para validação
	"""
	var player_scene_ : PackedScene = preload(player_scene)
	var player_instance = player_scene_.instantiate()
	
	# CONFIGURAÇÃO CRÍTICA: Nome = ID do peer
	player_instance.name = str(player_data["id"])
	player_instance.player_id = player_data["id"]
	player_instance.player_name = player_data["name"]
	player_instance._is_server = true
	player_instance.add_to_group("remote_player")
	
	# IMPORTANTE: No servidor, nenhum player é "local"
	player_instance.is_local_player = false
	
	# Adiciona à cena
	players_node.add_child(player_instance)
	
	# Injeta dependências
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.server_manager = self
	
	# Registra node no PlayerRegistry
	player_registry.register_player_node(player_data["id"], player_instance)
	
	# Posiciona
	var spawn_pos = map_manager.get_spawn_position(spawn_data["spawn_index"])
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
				network_manager.rpc_id(player["id"], "_client_return_to_room", room)
	
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
	if map_manager and is_instance_valid(map_manager):
		map_manager.unload_map()
		map_manager = null
	
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
		
		network_manager._rpc_client_despawn_item.rpc_id(player_id, object_id, round_id)

# ===== VALIDAÇÃO DE ITENS =====

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_pick_up_item(requesting_player_id: int, object_id: int):
	"""Servidor recebe pedido de pegar item para o inventário, valida e redistribui"""
	
	var player_node = player_registry.get_player_node(requesting_player_id)
	var round_id = player_registry.get_player_round(requesting_player_id)
	var object = _get_spawned_object(round_id ,object_id)
	var server_nearby = player_node.get_nearby_items()
	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	var item = item_database.get_item(object["item_name"]).to_dictionary()
	var round_players = round_registry.get_active_players_ids(round_["round_id"])
	
	_log_debug("[ITEM] Player %s pediu para pegar item %d(%s), no round %d" % [player["name"], object_id, object["item_name"], round_["round_id"]])
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	# Verificação se o item está perto do player na cena do servidor também
	if not server_nearby.has(object["node"]):
		_log_debug("O nó deste player no servidor não tem este item por perto para pickup, recusar!")
		return
	
	# Verifica se o item que o player enviou é o mesmo que o server detectou
	if object_id != server_nearby[0].object_id:
		return
	
	# Se for item equipável de knight
	if not item_database.get_items_by_owner("knight"):
		return
	
	# Verifica se tem espaço no inventário
	if player_registry.is_inventory_full(round_["round_id"], player["id"]):
		_log_debug("Impossível pegar item, inventário cheio!")
		return
	
	player_registry.add_item_to_inventory(round_["round_id"], player["id"], str(item["id"]), object_id)
	
	# Despawn do objeto no mapa dos clientes
	_rpc_despawn_on_clients(round_players, round_["round_id"], object_id)
	
	# Despawn do objeto no mapa do servidor
	var item_node = object.get("node")
	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()
		_log_debug("_server_validate_pick_up_item: Node removido da cena")
	
	# Define objeto armazenado / sai do spawned objects
	object_manager.store_object(round_["round_id"], object_id, player["id"])
	
	# Executa animação no player no servidor e em seus remotos nos clientes
	for peer_id in round_players:
		network_manager.server_apply_picked_up_item.rpc_id(peer_id, requesting_player_id)
	
	# Executa animação no nó do servidor tbm
	if player_node and player_node.has_method("action_pick_up_item"):
		player_node.action_pick_up_item()
	
	# Se o slot deste item estiver vazio, equipar este item lá automaticamente \/
	if not player_registry.is_slot_empty(round_["round_id"], player['id'], item["type"]):
		return
		
	# Equipa o item no registro do player
	player_registry.equip_item(round_["round_id"], player['id'], item["name"], object_id)
	
	_log_debug("[ITEM]📦 Slot deste item está vazio, equipando automaticamente: Player %d equipou item %d" % [requesting_player_id, item["id"]])
	
	# Envia para todos os clientes do round (para atualizar visual)
	
	for peer in round_["players"]:
		var peer_id = peer["id"]
		if _is_peer_connected(peer_id):
			network_manager.rpc_id(peer_id, "server_apply_equiped_item", requesting_player_id, item["id"])
	
	# Aplica visual tbm na cena do servidor
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(str(item["id"]))

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_equip_item(requesting_player_id: int, object_id: int, _target_slot_type):
	"""Servidor recebe pedido de equipar item, valida e redistribui"""

	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	var item_id = item_database.get_item(object_manager.get_stored_object_item_name(round_["round_id"] ,object_id))["id"]
	var players_node = round_["round_node"].get_node_or_null("Players")
	var item = item_database.get_item_by_id(item_id)
	#var item_slot = item.get_slot()
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	_log_debug("[ITEM]📦 Player %s pediu para equipar item %d no slot %s, no round %d" % [player["name"], item_id, item["type"], round_["round_id"]])
	
	# Verifica se o id do item é válido
	if not item_database.get_item_by_id(item_id):
		return
	
	# Verifica se o slot está vazio no inventário do player
	if not player_registry.is_slot_empty(round_["round_id"], player['id'], _target_slot_type):
		push_warning("[ITEM]O Slot já está ocupado por outro item, pedido de equipamento cancelado pelo servidor")
		return
	
	# Equipa o item no registro do player
	player_registry.equip_item(round_["round_id"], player['id'], item["name"], object_id)
	
	_log_debug("✓ Item equipado: %s em %s (Player %d, Rodada %d)" % [item["name"], item["type"], player['id'], round_["round_id"]])
	
	# Envia para todos os clientes do round (para atualizar visual)
	
	# Para cada player neste round
	for peer in round_["players"]:
		var peer_id = peer["id"]
		if _is_peer_connected(peer_id):
			network_manager.rpc_id(peer_id, "server_apply_equiped_item", requesting_player_id, item_id, false, true)
	
	# Aplica visual tbm na cena do servidor
	var player_node = players_node.get_node_or_null(str(requesting_player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(item_id, false, true)
			
@rpc("any_peer", "call_remote", "reliable")
func _server_validate_unequip_item(requesting_player_id: int, slot_type: String):
	"""Servidor recebe pedido de desequipar item, valida e redistribui"""

	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	var item_ = player_registry.get_equipped_item_in_slot(round_["round_id"], requesting_player_id, slot_type)
	
	if not item_:
		return
		
	var item_id = item_["item_id"]
	var players_node = round_["round_node"].get_node_or_null("Players")
	var item = item_database.get_item_by_id(int(item_id))
	var item_slot = item.get_slot()
	
	_log_debug("[ITEM]📦 Player %s pediu para desequipar item %d no slot %s, no round %d" % [player["name"], item["id"], item["type"], round_["round_id"]])
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	# Verificar se o slot_type recebido é válido
	if not item_:
		return
	
	player_registry.unequip_item(round_["round_id"], player["id"], item_slot)
	
	_log_debug("✓ Item desequipado: %s de %s (Player %d, Rodada %d)" % [item["name"], item["type"], player["id"], round_["round_id"]])
	
	for peer in round_["players"]:
		var peer_id = peer["id"]
		if _is_peer_connected(peer_id):
			network_manager.rpc_id(peer_id, "server_apply_equiped_item", requesting_player_id, int(item_id), true, true)
	
	# Aplica na cena do servidor (atualizar visual)
	var player_node = players_node.get_node_or_null(str(requesting_player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(item_id, true, true)

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_swap_items(dragged_item_id: String, target_item_id: String):
	"""
	Processa troca entre inventário e equipamento.
	
	NOTA IMPORTANTE: Esta função SEMPRE chama swap_equipped_item com:
		- O item do INVENTÁRIO como primeiro item (será equipado)
		- O item EQUIPADO como segundo item (será substituído)
	
	Para isso, inverte os IDs se necessário, garantindo que a lógica do servidor
	sempre receba os parâmetros na ordem correta.
	"""
	var player_id: int = multiplayer.get_remote_sender_id()
	var round_id: int = player_registry.get_player_round(player_id)
	var round_data = round_registry.get_round(round_id)
	
	# Verifica se o player tem pelo menos um destes itens equipado
	var dragged_equipped := player_registry.is_item_equipped(round_id, player_id, int(dragged_item_id))
	var target_equipped := player_registry.is_item_equipped(round_id, player_id, int(target_item_id))

	# XOR: um true e o outro false
	if dragged_equipped == target_equipped:
		return
		
	# Verifica se o player tem pelo menos um destes itens no inventário
	var dragged_in_inventory := player_registry.has_item_in_inventory(round_id, player_id, int(dragged_item_id))
	var target_in_inventory := player_registry.has_item_in_inventory(round_id, player_id, int(target_item_id))
	# XOR: um true e o outro false
	if dragged_in_inventory == target_in_inventory:
		return
	
	# PASSO 1: IDENTIFICAR QUAL ITEM VEM DO INVENTÁRIO (será equipado)
	
	var is_dragged_equipped: bool = player_registry.is_item_equipped(round_id, player_id, int(dragged_item_id))
	
	# Determina qual ID representa o item do inventário (será o novo equipado)
	var inventory_item_id: String
	var equipped_item_id: String
	
	if is_dragged_equipped:
		# Item arrastado está equipado → então o ALVO está no inventário
		inventory_item_id = target_item_id
		equipped_item_id = dragged_item_id
	else:
		# Item arrastado está no inventário → então o ALVO está equipado
		inventory_item_id = dragged_item_id
		equipped_item_id = target_item_id

	# PASSO 2: OBTER DADOS DO ITEM QUE VEM DO INVENTÁRIO
	
	var item_name: String = object_manager.get_stored_object_item_name(round_id, int(inventory_item_id))
	if item_name.is_empty():
		push_error("Item para swap não encontrado. ID: %s" % inventory_item_id)
		return
	
	# Carrega dados do item (usando SUA estrutura existente que funciona)
	var item_data: Dictionary = item_database.get_item(item_name).to_dictionary()
	var inventory_item_dict: Dictionary = {
		"item_id": item_data["id"],
		"object_id": inventory_item_id
	}
	
	# PASSO 3: EXECUTAR TROCA (usando EXATAMENTE sua lógica original)
	
	# NOTA: Usamos item_data["type"] como slot de destino (como no seu código original)
	player_registry.swap_equipped_item(
		round_id,
		player_id,
		item_name,                # Nome do item do inventário
		inventory_item_dict,      # Dados do item do inventário
		int(equipped_item_id),    # ID do item equipado (será substituído)
		item_data["type"]         # Tipo do slot (ex: "hand-left", "head") - MANTENHA "type"
	)

	# PASSO 4: ATUALIZAR VISUAL (mantendo sua lógica original)
	var players_node = round_data["round_node"].get_node_or_null("Players")
	if not players_node:
		return
	
	# Servidor:
	# Mudança de visual sincronizada para os remotes e clientes
	var player_node = players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(item_data["id"])
	# Ações diversas relacionadas a swap de itens sincronizadas para os remotes e clientes
	if player_node and player_node.has_method("execute_item_swap"):
		player_node.execute_item_swap()
		
	# Clientes:
	# server_apply_equiped_item executa ambas: apply_visual_equip_on_player_node e execute_item_swap
	for peer in round_data["players"]:
		var peer_id: int = peer["id"]
		if _is_peer_connected(peer_id):
			network_manager.rpc_id(peer_id, "server_apply_equiped_item", player_id, item_data["id"], false, false, true)
	
@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_spawn_item(requesting_player_id: int, item_id: int):
	"""Servidor recebe pedido de spawnar item na frente do player para testes"""
	
	if not item_trainer:
		return
	
	var player = player_registry.get_player(requesting_player_id)
	var round_ = round_registry.get_round_by_player_id(player["id"])
	_log_debug("[ITEM]📦 Player %s: Trainer pediu para spawnar item %d na sua frente, no round %d" % [player["name"], item_id, round_["round_id"]])
	
	# Verifica se o id do item é válido
	if not item_database.get_item_by_id(item_id):
		return
	
	var objects_node = round_["round_node"].get_node_or_null("Objects")
	var item_name = item_database.get_item_by_id(item_id)
	# ObjectManager cuida de spawnar E enviar RPC
	object_manager.spawn_item_over_of_player(objects_node, round_["round_id"], requesting_player_id, item_name["name"])

@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_drop_item(player_id):
	"""Servidor recebe pedido de dropar item do inventário(apenas do inventário) na frente do player para testes"""
	_log_debug('_server_trainer_drop_item')
	
	if not item_trainer:
		return
	
	var round_ = round_registry.get_round_by_player_id(player_id)
	
	# Se o player não tiver nenhum item no inventário para dropar, não faz nada
	var has_any = player_registry.has_any_item(round_["round_id"], player_id)
	_log_debug("Player tem algum item para dropar?: %s" % has_any)
	if not has_any:
		return
	
	#var player = player_registry.get_player(player_id)
	var obj_id = player_registry.get_inventory_items(round_["round_id"], player_id)[0]["object_id"]
	var item_id = int(player_registry.get_inventory_items(round_["round_id"], player_id)[0]["item_id"])
	#var item_name = item_database.get_item_by_id(item_id)["name"]
	#var players_node = round_["round_node"].get_node_or_null("Players")
	var objects_node = round_["round_node"].get_node_or_null("Objects")
	
	# Remover o item do registro do player
	player_registry.remove_item_from_inventory(round_["round_id"], player_id, obj_id)
	
	var item_data = item_database.get_item_by_id(item_id)
	if item_data:
		var player_state = player_states[player_id]
		var player_pos = player_state["pos"]
		var player_rot = player_state["rot"]
		var spawn_pos = object_manager._calculate_front_position(player_pos, player_rot)
			
		# Retomar o nó do item de volta à cena no object manager
		object_manager.retrieve_stored_object(objects_node, round_["round_id"], obj_id, spawn_pos, Vector3(0, 0, 0,), player_id)
		player_registry.remove_item_from_inventory(round_["round_id"], player_id, obj_id)
	
@rpc("any_peer", "call_remote", "reliable")
func _server_validate_drop_item(requesting_player_id: int, obj_id: int):
	"""Servidor recebe pedido de drop, valida e spawna item executando drop_item()
	IMPORTANTE: USA ESTADO DO SERVIDOR, não do cliente"""
	# Na hora do drop, se tiver um item equipado e for o item dropado, desequipar e dropar, se não for o mesmo, apenas dropar
	# Se não tiver nenhum item equipado, apenas dropar se tiver no inventário
	
	var round_ = round_registry.get_round_by_player_id(requesting_player_id)
	var player = player_registry.get_player(requesting_player_id)
	
	# Validação 1:
	if not player_states.has(requesting_player_id):
		push_warning("[ServerManager]: Player %d não tem estado registrado" % requesting_player_id)
		return
		
	# Validação 2:
	if round_registry.get_round_state(round_["round_id"]) != "playing":
		push_warning("[ServerManager]: Round inválido, não está em partida")
		return
	
	# Validação 3:
	if not object_manager.stored_object_exists(round_["round_id"], obj_id):
		push_warning("[ServerManager]: Objeto inválido, não existe no ObjectManager stored_objects do player")
		return
	
	var is_item_equipped = player_registry.is_item_equipped(round_["round_id"], requesting_player_id, obj_id)
	var object_item_name = object_manager.get_stored_object_item_name(round_["round_id"], obj_id)
	var item_ = item_database.get_item(object_item_name).to_dictionary()
	var item_slot = item_database.get_slot(object_item_name)
	var item_id = 0
	
	# Se o item estiver equipado
	if is_item_equipped:
		var equiped_obj_id = player_registry.get_equipped_item_in_slot(round_["round_id"], requesting_player_id, item_slot)["object_id"]
			
		# Pega o id do item para esconder no player
		item_id = int(player_registry.get_equipped_item_in_slot(round_["round_id"], requesting_player_id, item_slot)["item_id"])
		
		# Verificar se o item dropado é o mesmo item que está equipado, se sim, pedir para desequipar
		if int(equiped_obj_id) == int(obj_id):
			player_registry.unequip_item(round_["round_id"], requesting_player_id, item_slot, false)
		
		# Aplica no nó do servidor
		var player_node = player_registry.get_player_node(requesting_player_id)
		if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(int(item_id), true)
		
		# Aplicar nos players remotos dos clientes
		for peer in round_["players"]:
			var peer_id = peer["id"]
			if _is_peer_connected(peer_id):
				network_manager.rpc_id(peer_id, "server_apply_equiped_item", requesting_player_id, int(item_id), true)
	
	_log_debug("[ITEM]📦 Servidor vai validar pedido de drop de item ObjId: %d tipo %s do player ID %s" % [obj_id, item_["name"], requesting_player_id])
	
	# Validação 4:
	if not item_database.get_item_by_id(item_id) and item_id != 0:
		push_warning("[ServerManager]: ID de item inválido recebido: %d" % item_id)
		return
	
	# Se o player não tiver nenhum item no próprio inventário para dropar, não faz nada
	var has_any = player_registry.has_any_item(round_["round_id"], requesting_player_id)
	_log_debug("Player tem algum item para dropar?: %s" % has_any)
	if not has_any:
		push_warning("[ServerManager]: Player não tem nenhum item no inentário para dropar")
		return
		
	_log_debug("[ITEM]📦 Pedido válido! Executando drop de item ObjId: %d tipo %s do player ID %s" % [obj_id, item_["name"], requesting_player_id])
	
	# Executar drop (o item deve estar no inventário do player / já verificado acima) \/
	# Pegar o item_id do objeto referido
	var player_invent_items = player_registry.get_inventory_items(round_["round_id"], requesting_player_id)
	for item in player_invent_items:
		if item["object_id"] == obj_id:
			item_id = item["item_id"]
			break
			
	var item_data = item_database.get_item_by_id(int(item_id))
	var objects_node = round_["round_node"].get_node_or_null("Objects")
	
	if item_data:
		# Dados de posição e rotação do player para dropar obj item à sua frente
		var player_state = player_states[requesting_player_id]
		var player_pos = player_state["pos"]
		var player_rot = player_state["rot"]
		var spawn_pos = object_manager._calculate_front_position(player_pos, player_rot)
		
		# Object Manager, retomar o nó do item de volta à cena
		object_manager.retrieve_stored_object(objects_node, round_["round_id"], obj_id, spawn_pos, Vector3(0, 0, 0,), requesting_player_id)
		
		# Remove item do inentário do player
		player_registry.remove_item_from_inventory(round_["round_id"], player["id"], obj_id)
		
		# Executa ações referentes a isso no player no servidor e em seus remotos nos clientes
		var round_players = player_registry.get_players_in_round(round_["round_id"])
		for peer_id in round_players:
			network_manager.server_apply_drop_item.rpc_id(peer_id, requesting_player_id, item_data["name"])
		
		# Aplica no nó do servidor
		var player_node = player_registry.get_player_node(requesting_player_id)
		if player_node and player_node.has_method("execute_item_drop"):
			player_node.execute_item_drop()
		
# ===== VALIDAÇÕES DE AÇÕES DO PLAYER =====

func attack_validation(group: String, player_id: int, actual_weapon: String, body_name: int):
	
	if group == "player":
		var round_ = round_registry.get_round_by_player_id(player_id)
		var round_players = player_registry.get_players_in_round(round_["round_id"])
		
		for peer_id in round_players:
			network_manager._client_player_receive_attack.rpc_id(peer_id, body_name)
		
		# Aplica no nó do servidor
		var player_node = player_registry.get_player_node(body_name)
		if player_node and player_node.has_method("take_damage"):
			player_node.take_damage()
		
	_log_debug("Ataque executado!: %s, %d com um(a) %s em %d" % [group, player_id, actual_weapon,  body_name])

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""RPC: Servidor recebe ação do jogador e redistribui para os do mesmo round"""
	
	var player = player_registry.get_player_round(p_id)
	var round_id = round_registry.get_round_by_player_id(p_id)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	
	# Ignora pedidos do servidor (redundancia)
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	# Ignora o próprio player
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# Se for um ataque
	if action_type == "attack":
		# Servidor verifica se o player tem uma arma equipada
		if not player_registry.has_weapon_equipped(player, p_id):
			return
		_log_debug("%s tem uma arma equipada: %s" % [player, player_registry.has_weapon_equipped(player, p_id)])
			
	# Se for um ataque com escudo:
	elif action_type == "block_attack":
		# Servidor verifica se o player tem uma escudo equipado
		if not player_registry.has_shield_equipped(player, p_id):
			return
		_log_debug("%s tem um escudo equipado: %s" % [player, player_registry.has_shield_equipped(player, p_id)])
	
	# Se for um pedido de iniciar defesa com escudo
	elif action_type == "defend_start":
		# Servidor verifica se o player tem uma escudo equipado
		if not player_registry.has_shield_equipped(player, p_id):
			return
	
	# Propaga pra todos os outros clientes (Reliable = Garantido)
	for peer_id in players_round:
		if peer_id != p_id:
			network_manager._client_player_action.rpc_id(peer_id, p_id, action_type, item_equipado_nome, anim_name)
			# Dica: Outra forma de chamar rpc(quando está inacessível p o server mas existe no pc remoto):
			# if has_method("_client_player_action"):
				# rpc_id(peer_id, "_client_player_action", p_id, action_type, anim_name)
	
	# Para defend_stop o servidor aplica sem verificações
	# Aplica no nó do servidor
	var player_node = player_registry.get_player_node(p_id)
	if player_node and player_node.has_method("_client_receive_action"):
		player_node._client_receive_action(action_type, item_equipado_nome, anim_name)

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
		network_manager.rpc_id(peer_id, "_client_error", "🚫 Você foi desconectado: " + reason)
	
	# Desconecta após 1 segundo
	await get_tree().create_timer(1.0).timeout
	
	if multiplayer.has_multiplayer_peer() and _is_peer_connected(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		_log_debug("✓ Player desconectado")

func _send_error(peer_id: int, message: String):
	"""Envia mensagem de erro para um cliente"""
	_log_debug("❌ Enviando erro para cliente %d: %s" % [peer_id, message])
	if _is_peer_connected(peer_id):
		network_manager.rpc_id(peer_id, "_client_error", message)

func _is_peer_connected(peer_id: int) -> bool:
	"""Verifica se um peer ainda está conectado"""
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

func _get_spawned_object(round_id: int, object_id: int):
	if (
		object_manager and
		object_manager.spawned_objects.has(round_id) and
		object_manager.spawned_objects[round_id].has(object_id)
	):
		return object_manager.spawned_objects[round_id][object_id]
	return null

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		print("[SERVER]" + message)

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
