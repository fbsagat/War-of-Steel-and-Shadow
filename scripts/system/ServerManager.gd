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
## Ativa/desativa o debug visual na gameplay (initializer sobrepõe)
@export var visual_debug: bool = false
@export var debug_timer: bool = false
## [TESTES] Usa o TestManager para iniciar logo uma partida na execução (initializer sobrepõe)
@export var fast_round: bool = false
## [TESTES] Define a quantidade de instnacias de clientes para executar fast_round (initializer sobrepõe)
@export var simulador_players_qtd: int = 12
## [TESTES] Dropa itens perto dos players e ativa o trainer de cada player (initializer sobrepõe)
@export var test_trainer: bool = false

@export_category("Server Settings")
@export var server_port: int = 7777
@export var max_clients: int = 64
@export var is_headless: bool
@export var public_server_name: String = "Games da PQP! Diversão garantida!"
@export var kicked_default_timer: float = 120.0 # Tempo padrão em que um cliente fica banido de uma sala
@export var reconnect_timout : float = 120.0
## Habilita remoção de salas quando ficam vazias (mas continuam esperando o seu round fechar)
@export var remove_empty_rooms: bool = true

var server_id : String
var server_secret : PackedByteArray

@export_category("Default Node References")
const map_scene : String = "res://scenes/gameplay/terrain_3d.tscn"
const player_scene : String = "res://scenes/gameplay/player_warrior.tscn"
const camera_controller : String = "res://scenes/system/camera_controller.tscn"
const server_camera : String = "res://scenes/server_scenes/server_camera.tscn"

@export_category("Room Settings")
@export var max_players_per_room: int = 20
@export var min_players_to_start: int = 1

@export_category("Round Settings")
## Tempo de transição entre fim de rodada e volta à sala (segundos)
@export var round_transition_time: float = 5.0
## Intervalo de tempo para o servidor fazer a verificação de rodadas vazias para remover
@export var CLEANUP_INTERVAL := 10 # segundos
## Tempo que uma rodada vai ficar vazia para ser removida irreversivelmente
@export var ROUND_EMPTY_TIMEOUT = 120  # segundos

@export_category("Anti-Cheat")
## Velocidade máxima permitida (m/s)
@export var max_player_speed: float = 15.0
## Margem de tolerância para lag (multiplicador)
@export var speed_tolerance: float = 1.5
## Tempo mínimo entre validações (segundos)
@export var validation_interval: float = 0.1
## Ativar validação anti-cheat
@export var enable_anticheat: bool = true

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var network_manager: NetworkManager = null
var client_registry : ClientRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var item_database: ItemDatabase = null
var object_manager: ObjectManager = null
var test_manager: TestManager = null
var map_manager: Node = null
var debug_overlay = null

# ===== REFERÊNCIAS INTERNAS =====

var all_rounds_node: Node = null
var current_cam_round_index: int = -1
var current_active_camera: Camera3D = null
var mouse_mode: bool = false
var current_active_viewport: SubViewport = null
var viewport_display: TextureRect = null
var test_mode_check_timer: Timer
var initializer = null

# ===== VARIÁVEIS INTERNAS =====

## Rastreamento de estados dos jogadores para validação anti-cheat
## Formato: {peer_uuid: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
var player_states: Dictionary = {}
var actual_camera: Camera3D = null

# ===== INICIALIZAÇÃO DO MANAGER =====

func _ready() -> void:
	pass

func initialize():
	# Conecta sinais
	_connect_signals()
	
	# Inicializa verificador de teste automático se fast_round true
	if fast_round:
		_setup_test_mode_verification()
	
	# Timer automático no servidor para fazer limpeza periódica de rounds vazios
	_setup_cleanup_empty_rounds_timer()
	
	# Cria uma SubViewportContainer chamada ActiveRoundDisplay para exibir as câmeras(uma por vez)
	# das rodadas em curso, se is_headless estiver desativado
	if not is_headless:
		_setup_viewport_display()
	
	# Timer de debug periódico (opcional)
	if debug_timer:
		_setup_debug_timer()
	
	# Cria nó organizacional para os Rounds
	all_rounds_node = Node.new()
	get_tree().root.add_child(all_rounds_node)
	all_rounds_node.name = "All_Rounds"
	
	# Gera id único do servidor
	_generate_server_identity()
	
	# Inicializa servidor
	_start_server()
	
	# Mostrando a tela de clientes do debug overlay
	if not is_headless and debug_overlay:
		debug_overlay._toggle_tab(debug_overlay.Tab.CLIENTS)

# ===== SETUPS =====

func _generate_server_identity() -> void:
	""" Gera:
	- server_id (hex string pública)
	- server_secret (bytes privados)
	Ambos existem apenas durante esta execução.
	"""
	var crypto = Crypto.new()
	server_id = crypto.generate_random_bytes(16).hex_encode()
	server_secret = crypto.generate_random_bytes(32)

func _connect_signals():
	"""Conecta sinais dos registries"""
	# Sinais de rodada
	round_registry.round_ending.connect(_on_round_ending)
	room_registry.host_changed.connect(_on_host_changed)
	
func _setup_test_mode_verification():
	"""Aqui inicializamos o sistema de verificação automática"""
	test_mode_check_timer = Timer.new()
	test_mode_check_timer.wait_time = 2.0 # período em segundos
	test_mode_check_timer.one_shot = false
	test_mode_check_timer.timeout.connect(_on_fast_round_verify_timeout)
	add_child(test_mode_check_timer)
	test_mode_check_timer.start()
		
func _on_fast_round_verify_timeout():
	"""Esta função é chamada automaticamente sempre que o Timer atinge o tempo configurado"""
	if _test_round_check():
		test_mode_check_timer.stop()
		
func _test_round_check() -> bool:
	"""Esta função executa a lógica de verificação. Ela retorna:
	- true  → quando a partida de teste foi iniciada
	- false → quando ainda não há jogadores suficientes"""
	_log_debug("Chamada periódica para iniciar o modo de testes")
	# Executar sistema de teste automático no momento que entra e registra a quantidade de players necessária
	var players_on_count = client_registry.get_connected_player_count()
	if players_on_count >= simulador_players_qtd:
		test_manager.create_test_round()
		return true
	return false
	
func _setup_viewport_display():
	"""Cria um TextureRect que mostra o viewport atual na tela"""
	viewport_display = TextureRect.new()
	viewport_display.anchor_right = 1.0
	viewport_display.anchor_bottom = 1.0
	viewport_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	viewport_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	viewport_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport_display.name = "ViewportDisplay"
	
	# Adiciona como child direto da raiz para preencher a tela
	get_tree().root.add_child(viewport_display)

func _setup_debug_timer():
	"""Cria timer para imprimir estados periodicamente"""
	var debug_timer_ = Timer.new()
	debug_timer_.wait_time = 5.0
	debug_timer_.autostart = true
	debug_timer_.timeout.connect(_print_player_states)
	debug_timer_.name = "DebugTimer"
	add_child(debug_timer_)
	
func _setup_cleanup_empty_rounds_timer():
	"""Essa função cria e configura um timer automático no servidor para fazer limpeza periódica 
	de rounds vazios."""
	var cleanup_timer_ = Timer.new()
	cleanup_timer_.wait_time = CLEANUP_INTERVAL
	cleanup_timer_.autostart = true
	cleanup_timer_.timeout.connect(_cleanup_empty_rounds)
	cleanup_timer_.name = "CleanupTimer"
	add_child(cleanup_timer_)

# ===== FUNÇÕES DE INPUT =====

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
		_find_a_next_round_to_camera()
	
	if event.is_action_pressed("ui_cancel") and debug_overlay._active_tab == -1:
		_toggle_mouse_mode()
		
	if event.is_action_pressed("ui_cancel") and debug_overlay._active_tab > -1:
		debug_overlay._close()
	
	# Teste
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_BACKSPACE:
		_log_debug("Backspace!!! Coloque algo aqui...")

func _find_a_next_round_to_camera(round_id: int = -1):
	"""Encontra um round ativo corretamente para mudar a câmera para este round"""
	# Se receber id, envia para o round deste id, se não receber, envia para o próximo a partir de
	# current_cam_round_index e o salva como o novo current_cam_round_index
	
	if round_id != -1:
		_log_debug("Movendo câmera do servidor para o round: %s" % round_id)
		current_cam_round_index = round_id
	else:
		_log_debug("Movendo câmera do servidor para o próximo round encontrado")
		
		var all_running_rounds_ids = round_registry.get_all_rounds_keys()
		
		# Se estiver vazio pega -1 novamente
		if all_running_rounds_ids.is_empty():
			current_cam_round_index = -1
			_log_debug("Não tem round para mandar a câmera")
			#current_active_viewport = null
			viewport_display.visible = false
			return
			
		# Garante ordem
		all_running_rounds_ids.sort()
		
		var index = all_running_rounds_ids.find(current_cam_round_index)
		# Se não encontrar
		if index == -1:
			# Pega o próximo maior
			var next = null
			
			for n in all_running_rounds_ids:
				if n > current_cam_round_index:
					if next == null or n < next:
						next = n
			
			if next != null:
				current_cam_round_index = next
			else:
				# Se não tem maior, volta pro primeiro
				current_cam_round_index = all_running_rounds_ids[0]
				
		# Se encontrar
		else:
			# Fluxo circular normal
			current_cam_round_index = all_running_rounds_ids[(index + 1) % all_running_rounds_ids.size()]

	_log_debug("Câmera indo para o round: %s" % current_cam_round_index)
	_switch_camera_to_round(current_cam_round_index)

func _switch_camera_to_round(round_id: int) -> void:
	"""Ativa a câmera de um round específico e atualiza o display"""
	
	_log_debug("Movendo câmera para round %s" % round_id)
	
	# 1. Garanta que o display esteja INVISÍVEL enquanto trocamos a textura
	# Isso impede que o renderer tente desenhar uma textura inválida
	viewport_display.visible = false
	
	# Segurança ao pegar round
	var round_ = round_registry.get_round(round_id)
	if not round_:
		push_warning("Round não encontrado: %s" % round_id)
		return
		
	var round_node = round_.get("round_node", null)
	
	# Validação robusta do nó
	if not round_node or not is_instance_valid(round_node) or not round_node.is_inside_tree():
		push_warning("Round node inválido: %s" % round_id)
		return
	
	if not (round_node is SubViewport):
		push_warning("round_node não é um SubViewport")
		return
	
	# Verifica tamanho mínimo (Viewport sem tamanho não gera textura)
	if round_node.size.x <= 0 or round_node.size.y <= 0:
		_log_debug("Viewport sem tamanho válido")
		return

	# Garante que o SubViewport está pronto
	if not round_node.is_inside_tree():
		await round_node.ready

	# --- Troca de Câmera ---
	if current_active_camera and is_instance_valid(current_active_camera):
		current_active_camera.current = false
		current_active_camera.set_process_input(false)
		current_active_camera.set_process_unhandled_input(false)

	var new_camera = round_node.get_node_or_null("FreeCamera")
	if not new_camera:
		new_camera = round_node.get_node_or_null("DummyCamera")

	# Aguarda o processamento do frame para garantir que a cena do round carregou
	await get_tree().process_frame
	await get_tree().process_frame

	if new_camera and new_camera is Camera3D:
		new_camera.current = true
		current_active_camera = new_camera
		current_active_viewport = round_node
		
		# Ativa input da nova câmera
		new_camera.set_process_input(true)
		new_camera.set_process_unhandled_input(true)
		
		current_cam_round_index = round_id
		
		# --- Lógica Crítica da Textura ---
		var tex: Texture2D = round_node.get_texture()
		
		if tex:
			# 2. Usa call_deferred para atribuir a textura no final do frame
			# Isso dá tempo ao SubViewport de criar o render target interno
			viewport_display.call_deferred("set_texture", tex)
			
			# 3. Aguarda mais um frame para garantir que a textura foi vinculada
			await get_tree().process_frame
			
			# 4. Só mostra o display agora que a textura está segura
			viewport_display.visible = true
			
			_log_debug("✓ Câmera ativada: %s em %s" % [new_camera.name, round_node.name])
		else:
			push_warning("Viewport ainda não gerou textura para %s" % round_node.name)
			# Opcional: Mostrar uma tela de "Aguardando..." ao invés de deixar invisível
	else:
		push_warning("✗ Câmera não encontrada em %s" % round_node.name)

func _toggle_mouse_mode(force_visible: bool = false, force_captured: bool = false):
	# Prioridade: parâmetros forçados
	if force_visible:
		mouse_mode = false
	elif force_captured:
		mouse_mode = true
	else:
		mouse_mode = not mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouse_mode else Input.MOUSE_MODE_VISIBLE

# ===== INICIALIZAÇÃO DE SERVIDOR =====

func _start_server():
	"""Inicializa servidor dedicado e todos os subsistemas"""
	var timestamp = Time.get_datetime_string_from_system()
	_log_debug("================================================================")
	_log_debug("▶️ INICIANDO SERVIDOR DEDICADO ▶️")
	_log_debug("================================================================")
	_log_debug("Em: %s" % timestamp)
	_log_debug("Porta: %d" % server_port)
	_log_debug("ID: %s" % server_id)
	_log_debug("Máximo de clientes: %d" % max_clients)
	_log_debug("Trainer de testes: %s, Fast Round: %s" % [test_trainer, fast_round])
	_log_debug("Min. de jogadores/sala: %s, Max. de jogadores/sala: %s" % [min_players_to_start, max_players_per_room])
	_log_debug("Tempo de espera de reconexão(peer): %sms" % reconnect_timout)
	_log_debug("-----------------------------------------------------------------")
	var c = get_node_or_null("CleanupTimer")
	_log_debug("🆗 Limpador periódico de rounds carregado com sucesso" if c else
	 "❌ Limpador periódico de rounds não foi carregado")
	var d = get_node_or_null("DebugTimer")
	_log_debug("🆗 Timer de debug carregado com sucesso" if d else
	 "ℹ️ Timer de debug desativado")
	var v = get_tree().root.get_node_or_null("ViewportDisplay")
	_log_debug("🆗 Viewport Display carregado com sucesso" if v else
	 "ℹ️ Viewport Display não foi carregado")
	
	# Cria peer de rede
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(server_port, max_clients)
	
	if error != OK:
		_log_debug("================================================================")
		push_error("ERRO ao criar servidor: " + str(error))
		_log_debug("================================================================")
		return
	
	multiplayer.multiplayer_peer = peer
	
	# Conecta sinais de rede
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_log_debug("================================================================")
	_log_debug("▶️ Servidor inicializado com sucesso! ▶️")
	_log_debug("================================================================")
	print("")

# ===== SISTEMA DE IDENTIFIAÇÃO =====

func process_client_hello(payload: Dictionary, peer_id: int) -> Dictionary:
	""" Fluxo:
	1) Cliente envia:
	   - uuid_base
	   - token (opcional)
	2) Se token válido → autentica.
	3) Se token inválido ou ausente:
	   - Se jogador existe e está desconectado → reconectar.
	   - Se novo jogador → criar registro.
	   - Gerar novo token e retornar ao cliente.
	Retorna:
	{
	  "status": "ok" | "new_token" | "reject",
	  "token": String (se new_token),
	  "server_id": String
	}
	"""
	_log_debug("Processando client hello: %s, peer_id: %s" % [payload, peer_id])
	
	var uuid_base : String = payload.get("uuid_base", "")
	var client_token : String = payload.get("token", "")

	if uuid_base.is_empty():
		return {"status": "reject", "reason": "missing_uuid"}

	# 🔒 Bloqueia duplicidade ativa
	if client_registry._is_uuid_connected(uuid_base):
		return {"status": "reject", "reason": "dup_session"}

	# 🔎 Se cliente enviou token, validar
	if not client_token.is_empty():
		var expected = client_registry._compute_token(uuid_base)
		if client_token == expected:
			var player = client_registry.get_player_by_uuid(uuid_base)
			client_registry.update_peer_id(uuid_base, peer_id)
			client_registry._register_connection(uuid_base)
				
			# Muda estado do jogador para LOBBY se não estiver em uma partida
			var client_uuid = client_registry.get_uuid_by_peer_id(peer_id)
			var client = client_registry.get_player(client_uuid)
			if client and client["round_id"] == -1:
				client_registry.set_player_state(client_uuid, client_registry.ClientState.LOBBY)
			
			return {"status": "ok", "server_id": server_id, "player_name": player["name"]}

	# 🔄 Token inválido ou inexistente → emitir novo
	if not client_registry.get_player_by_uuid(uuid_base):
		client_registry.add_peer(peer_id, uuid_base)
	client_registry._register_connection(uuid_base)

	var new_token = client_registry._compute_token(uuid_base)

	return {
		"status": "new_token",
		"token": new_token,
		"server_id": server_id
	}

# ===== CALLBACKS DE CONEXÃO =====

func _on_peer_connected(peer_id: int):
	"""Callback quando um cliente conecta ao servidor"""
	if multiplayer.get_peers().size() > max_clients:
		_log_debug("🚫 Limite atingido, recusando: %s" % peer_id)
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	
	_log_debug("✓ Cliente conectado: Peer ID %d" % peer_id)
	
	# Envia configurações do servidor para o cliente
	var configs: Dictionary = {
		"max_players_per_room": max_players_per_room,
		"min_players_to_start": min_players_to_start,
		"server_name": public_server_name,
		"server_id": server_id,
	}
	
	# Atualiza max_players_per_room e min_players_to_start para clientes
	# atualiza nome do servidor e envia id do servidor
	network_manager.rpc_id(peer_id, "_client_update_info", configs)

func _on_peer_disconnected(peer_id: int):
	"""Callback quando um cliente desconecta"""

	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Sistema para impedir execução múltipla
	# Só passa se não for DISCONNECTED
	var state = client_registry.get_player_state(player_uuid)
	var state_list = [client_registry.ClientState.DISCONNECTED]
	if state in state_list:
		return
	
	_log_debug("❌ Desconectando cliente: Peer ID %d" % peer_id)
	
	var room = room_registry.get_player_room(player_uuid)
	# Só apaga se não estiver em jogo
	# (Se estiver em jogo, só vai apagar quando todos ficarem offline no tempo de ROUND_EMPTY_TIMEOUT)
	if room and remove_empty_rooms and not room["in_game"]:

		var player_data = client_registry.get_player(player_uuid)
		
		if not player_data.is_empty() and player_data["name"] != "":
			
			if not room.is_empty():
				var room_id = room["id"]
				
				# Remove da sala (pode deletá-la se ficar vazia)
				var new_host = room_registry.remove_player_from_room(room_id, player_uuid)
				var host_session_id: int = -1
				if new_host != "":
					# notificar novo host
					host_session_id = client_registry.get_peer_id_by_uuid(new_host)
				_log_debug("%s Removido da sala: %s" % [peer_id, room["name"]])
				
				# Verifica se sala ainda existe antes de notificar
				if room_registry.room_exists(room_id):
					# Atualiza informações de sala para os outros
					_notify_room_update(room_id)
					
					# Notifica outros jogadores da sala sobre a desconexão
					var updated_room = room_registry.get_room(room_id)
					for player in updated_room["players"]:
						if player["session_id"] != peer_id and _is_peer_connected(player["session_id"]):
							network_manager.rpc_id(player["session_id"], "_client_remove_player", peer_id)
					if host_session_id >= 0:
						_send_error_to_client(host_session_id, "Você é o novo host dessa sala")
				else:
					_log_debug("Sala foi deletada (ficou vazia)")
					_send_rooms_list_to_all()
		
	# Define cliente como desconectado
	client_registry.set_disconnected_peer(peer_id)
	_log_debug("❌ Cliente desconectado: Peer ID %d" % peer_id)

# ===== HANDLERS DE JOGADOR =====

func _handle_register_player_name(peer_id: int, player_name: String):
	"""Processa solicitação de registro de nome de jogador"""
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
		
	await get_tree().process_frame
	
	# Valida nome
	var validation_result = client_registry._validate_player_name(player_name)
	if validation_result != "":
		_log_debug("❌ Nome rejeitado: " + validation_result)
		network_manager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
		
	await get_tree().process_frame
	
	# Registra no ClientRegistry
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var success = client_registry.register_player_name(player_uuid, player_name)
	
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		
		network_manager.rpc_id(peer_id, "_client_name_accepted", player_name)
	else:
		_log_debug("❌ Falha ao registrar jogador")
		network_manager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")

# ===== HANDLERS DE SALAS =====

func _handle_request_rooms_list(peer_id: int):
	"""Envia lista de salas disponíveis (não em jogo) para o cliente que requisitou"""
	_log_debug("Cliente %d solicitou lista de salas" % peer_id)
	
	if not _is_peer_connected(peer_id):
		return
		
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Valida se player está registrado
	if not client_registry.is_player_registered(player_uuid):
		_send_error_to_client(peer_id, "Jogador não registrado")
		return
		
	await get_tree().process_frame
	
	# Verificar se jogador está em uma partida no momento
	if client_registry.in_round(player_uuid):
		# Se estiver em uma partida, perguntar se quer retornar para ela
		var room_id = client_registry.get_player_room(player_uuid)
		var room = room_registry.get_room(room_id)
		_log_debug("Requisitando para cliente %d retorno à partida em que estava ao desconectar")
		network_manager.rpc_id(peer_id, "_client_receive_round_return_request", room["name"])
	else:
		# Se não estiver, enviar lista de salas para ele escolher
		# Busca salas disponíveis (fora de jogo)
		var available_rooms = room_registry.get_rooms_in_lobby_clean_to_menu()
		_log_debug("Enviando %d salas para o cliente, qtd: " % available_rooms.size())
		network_manager.rpc_id(peer_id, "_client_receive_rooms_list", available_rooms)

func _send_rooms_list_to_all():
	"""
	Envia lista de salas disponíveis para todos os jogadores fora de partida 
	(cliente ignora se não estiver na lista de salas) (não envia para jogadores em partida)
	"""
	_log_debug("Servidor enviando lista de salas para todos os jogadores fora de uma sala")
	var available_rooms = room_registry.get_rooms_in_lobby_clean_to_menu()
		
	await get_tree().process_frame
	
	# Busca todos os jogadores que NÃO estão em salas
	var lobby_players = []
	for player_data in client_registry.get_all_players():
		var peer_id = player_data["peer_id"]
		var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
		if peer_id != 1 and not client_registry.in_room(player_uuid):  # Ignora servidor (ID 1)
			lobby_players.append(peer_id)
		
	await get_tree().process_frame
	
	# Envia lista para cada um
	for peer_id in lobby_players:
		if _is_peer_connected(peer_id):
			network_manager.rpc_id(peer_id, "_client_broadcast_rooms_list", available_rooms)

func _handle_request_return_or_exit(peer_id: int, chosen: bool):
	"""Servidor recebe resposta de cliente sobre voltar (true) ou abandonar (false) round em andamento
	# Depois:
	# 1. Se ele clicar em retornar, se estiver em uma round em andamento, retornar para o round, se
	# não estiver ou round não está mais em andamento, retornar para a sala apenas, se a sala não existir
	# mais, reseta registro e retorna para a lista de salas (verificar tudo isso no momento da execução).
	# 2. Se ele clicar em 'sair de vez': Retirar (descarregar nós e mudar estados) o jogador da 
	# sala/partida(no servidor e cliente(caso esteja) e enviar normalmente a lista de salas
	# pra ele escolher.
	# chosen = true - Cliente quer voltr ao round"""
	
	var player_uuid: String = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Validar player no registro
	if not player_uuid:
		return
	
	var player_room_id = client_registry.get_player_room(player_uuid)
	
	# Validar sala onde cliente está
	if not player_room_id:
		return
	
	if chosen:
		_execute_player_return_to_round(peer_id, player_uuid)
		return
		
	_player_exit_from_round(player_room_id, peer_id, player_uuid)

func _execute_player_return_to_round(peer_id: int, player_uuid: String):
	"""Esta função deve ser executada quando o cliente sinaliza que quer voltar ao round em que está, 
	quando seu personagem está instanciado em um round e seu registros indicam isso também"""
	
	_log_debug("Player %s quer retornar à partida em que estava" % peer_id)
	# Verifica de novo se a partida/round está em andamente, se sim, entra, se não, volta pra sala apenas
	var round_id = client_registry.get_player_round(player_uuid)
	var round_ = round_registry.get_round(round_id)
	
	if round_registry.is_round_active(round_id):
		_log_debug("enviando comando para o cliente carregar a partida dele")
		
		# Tratar round settings para enviar atualizadas para o cliente
		var round_node = round_["round_node"]
		var terrain_ = round_node.get_node("Terrain3D")
		var sky_node = terrain_.get_node("Sky3D")
		var time_node = sky_node.get_node_or_null("TimeOfDay")
		round_["settings"]["sky_rand_configs"]["time"]["current_time"] = time_node.current_time
		
		# Filtrar players que ainda estão na partida (apenas spawned players)
		var filtered_players = round_registry.get_round_players_spawned_filter(round_["round_id"])
		
		var match_data = {
			"round_id": round_["round_id"],
			"room_id": round_["room_id"],
			"map_scene": map_scene,
			"settings": round_["settings"],
			"players": filtered_players,
			"player_items": [],
			"equipped_items": {},
			"round_objects": {},
		}
		match_data["settings"]["spawn_points"] = {}
		
		for player in filtered_players:
			# Prepara posições e rotações de cada remoto na partida
			# {peer_uuid: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
			var position: Vector3 = player_states[player["id"]].get("pos")
			var rotation: Vector3 = player_states[player["id"]].get("rot")
			match_data["settings"]["spawn_points"][player["session_id"]] = {
				"position": position,
				"rotation": rotation}
			await get_tree().process_frame
			
			# Prepara modelos de personagens (próprio e remotos) para atualização visual
			var player_equip = client_registry.get_equipped_items(round_id, player["id"])
			match_data["equipped_items"][player["session_id"]] = player_equip
		
		# Prepara seu inventário para atualização visual
		var player_items = client_registry.get_inventory_items(round_id, player_uuid)
		match_data["player_items"] = player_items
		
		# Prepara objetos da cena para atualização visual
		var round_objects = object_manager.get_round_objects(round_["round_id"])
		# round_objects: [Object_1_torch_1:<RigidBody3D#123765524253>, Object_2_torch_1:<RigidBody3D#123916521411>]"""
		# executa no game manager: _spawn_on_client(object_id: int, round_id: int, 
		# item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_uuid: String)"""
		var all_objects: Dictionary
		for object in round_objects:
			await get_tree().process_frame
			all_objects[object["object_id"]] = {
				"round_id": object["round_id"],
				"item_name": object["item_name"],
				"position": object.global_position,
				"rotation": object.global_rotation,
				"drop_velocity": object["linear_velocity"],
				"owner_uuid": object["owner_uuid"],
			}
		match_data["round_objects"] = all_objects
		
		# Define o player como conectado de novo na sala
		room_registry._set_connected_peer(peer_id, round_["room_id"])
		
		# Define o player como conectado de novo no round
		round_registry._unmark_player_disconnected(round_["round_id"], player_uuid)
		
		# muda estado do jogador
		client_registry.set_player_state(player_uuid, client_registry.ClientState.LOADING)
		
		# Envia comando de retorno para o cliente
		network_manager.rpc_id(peer_id, "_client_round_return", server_id, match_data)

func _player_exit_from_round(player_room_id: int, peer_id: int, player_uuid: String):
	"""Esta função deve ser executada quando o cliente sinaliza que quer abandonar o round em que está, 
	quando seu personagem está instanciado em um round e seu registros indicam isso também"""
	
	_log_debug("Player %s quer abandonar a partida em que estava" % peer_id)
	# Remover player da sala no registro
	room_registry.remove_player_from_room(player_room_id, player_uuid)
	# Enviar a lista de salas pro player
	_handle_request_rooms_list(peer_id)
	
	# 1. LIMPA RODADA (se estiver em uma) (se estiver vazia)
	var p_round = round_registry.get_round_by_player_uuid(player_uuid)
	if not p_round.is_empty():
		var round_id = p_round["round_id"]
		
		# Remove node da cena do servidor
		var player_node = round_registry.get_spawned_player(round_id, player_uuid)
		if player_node and is_instance_valid(player_node):
			player_node.queue_free()
			_log_debug("Nó do player removido da cena")
			
		await get_tree().process_frame
	
		# Eviar comando para os outros clientes removerem também node da cena
		for player in p_round["players"]:
			if player["session_id"] != peer_id and _is_peer_connected(player["session_id"]):
				network_manager.rpc_id(player["session_id"], "_client_remove_player", peer_id)
			
		await get_tree().process_frame
	
		# Remove registro de spawn, limpa node path e remove do round
		round_registry.unregister_spawned_player(round_id, player_uuid)
		client_registry.clear_player_node_path(player_uuid)
		round_registry.remove_player(round_id, player_uuid)
		# quitted_players buscar isso pra ver se uso em putros lugares
		# Se todos quitaram permanentemente do round, finaliza automaticamente
		if round_registry.get_total_players(round_id) == 0:
			_log_debug("Finalizando round imediatamente, todos os players quitaram")
			round_registry.end_round(round_id, "all_quitted")
		
	await get_tree().process_frame
	
	# 2. LIMPA SALA (se estiver em uma)
	var player_data = client_registry.get_player(player_uuid)
	var room = room_registry.get_player_room(player_uuid)
	
	if not player_data.is_empty() and player_data["name"] != "":
		
		if not room.is_empty():
			var room_id = room["id"]
			
			# Remove da sala (pode deletá-la se ficar vazia)
			room_registry.remove_player_from_room(room_id, player_uuid)
			_log_debug("%s Removido da sala: %s" % [peer_id, room["name"]])
			
			# Verifica se sala ainda existe antes de notificar
			if room_registry.room_exists(room_id):
				_notify_room_update(room_id)
			else:
				_log_debug("Sala foi deletada (ficou vazia)")
				_send_rooms_list_to_all()
		
	await get_tree().process_frame
	
	# 3. Limpa estado de validação
	_cleanup_player_state(player_uuid)
	
	# 4. Muda estado do jogador
	client_registry.set_player_state(player_uuid, client_registry.ClientState.LOBBY)
	
func _mark_player_disconnected(peer_id: int, _chosen: bool):
	"""Recebe aviso do cliente de que está desconectado (_chosen = false) ou reconectado 
	(_chosen = true) em um round.
	- Não envia rpcs de sincronia e round em geral para ele durante desconexão/economia de rede"""
	
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	if not player_uuid:
		return
		
	var _round = round_registry.get_round_by_player_uuid(player_uuid)
	
	if not _round:
		return
	
	if _chosen:
		round_registry._mark_player_disconnected(_round["round_id"], player_uuid)
		_log_debug("⚠ uuid=%s marcado como desconectado na rodada %d" % [player_uuid, _round["round_id"]])
	else:
		round_registry._unmark_player_disconnected(_round["round_id"], player_uuid)
		_log_debug("✓ uuid=%s removido de disconnected_players na rodada %d" % [player_uuid, _round["round_id"]])

func _handle_create_room(peer_id: int, room_name: String, password: String):
	"""Cria uma nova sala e adiciona o criador como host"""
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		return
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error_to_client(peer_id, "Jogador não registrado")
		return
	
	# Verifica se jogador já está em uma sala
	var current_room = room_registry.get_player_room(player_uuid)
	if not current_room.is_empty():
		_send_error_to_client(peer_id, "Você já está em uma sala")
		return
	
	# Valida sala
	var validation = room_registry._validate_room_name(room_name)
	if validation != "":
		network_manager.rpc_id(peer_id, "_client_room_name_error", validation)
		return
	
	_log_debug("Criando sala '%s' para jogador %s (ID: %d)" % [room_name, player["name"], peer_id])
	# Cria sala
	var room_data = room_registry.create_room(
		room_name,
		password,
		player_uuid,
		min_players_to_start,
		max_players_per_room
	)
	
	if room_data.is_empty():
		_send_error_to_client(peer_id, "Erro ao criar sala")
		return
	
	_log_debug("✓ Sala criada: %s (ID: %d, Host: %s)" % [room_name, room_data["id"], player["name"]])
		
	await get_tree().process_frame
	
	# Atualiza lista de salas para todos (útil para quem está na lista de salas)
	_send_rooms_list_to_all()
	
	# Confirma criação para o criador
	network_manager.rpc_id(peer_id, "_client_room_created", room_data)

func _handle_join_room(peer_id: int, room_id: int, password: String) -> bool:
	"""Wrapper: entra por ID"""
	return await _handle_join_room_common(peer_id, room_id, password, false)

func _handle_join_room_by_name(peer_id: int, room_name: String, password: String) -> bool:
	"""Wrapper: entra por nome"""
	return await _handle_join_room_common(peer_id, room_name, password, true)

func _handle_join_room_common(peer_id: int, room_identifier: Variant, password: String, by_name: bool) -> bool:
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala ID: %d" % [player["name"], peer_id, int(room_identifier)])
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		return false
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error_to_client(peer_id, "Jogador não registrado")
		return false
	
	# Verifica se já está em uma sala
	var current_room: Dictionary = room_registry.get_player_room(player_uuid)
	if not current_room.is_empty():
		_send_error_to_client(peer_id, "Você já está em uma sala. Saia primeiro.")
		return false
			
	await get_tree().process_frame
	
	# Busca sala
	var room: Dictionary = {}
	if by_name:
		room = room_registry.get_room_by_name(str(room_identifier))
	else:
		room = room_registry.get_room(int(room_identifier))
	
	if room.is_empty():
		_log_debug("Sala não encontrada %s" % int(room_identifier))
		network_manager.rpc_id(peer_id, "_client_room_not_found")
		return false
	
	var room_id: int = int(room["id"])
	
	# Verifica se está kickado (timeout)
	var uuid_base: String = str(player.get("uuid_base", ""))
	if uuid_base != "":
		var has_kicked: bool = room_registry.check_kicked_timeout(
			room_id,
			uuid_base,
			kicked_default_timer
		)
		if has_kicked:
			_send_error_to_client(peer_id, "Você foi expulso desta sala.")
			return false
	
	# Verifica senha
	var has_password: bool = bool(room.get("has_password", false))
	var room_password: String = str(room.get("password", ""))
	if has_password and room_password != password:
		network_manager.rpc_id(peer_id, "_client_wrong_password")
		return false
	
	# Verifica locked
	var settings: Dictionary = room.get("settings", {}) as Dictionary
	if settings.has("locked") and bool(settings["locked"]):
		_send_error_to_client(
			peer_id,
			"A sala '%s' foi trancada pelo host." % room.get("name", "")
		)
		return false
	
	# Verifica lotação
	var players_arr: Array = room.get("players", []) as Array
	if players_arr.size() >= max_players_per_room:
		_send_error_to_client(peer_id, "A sala está lotada.")
		return false
	
	_log_debug("Jogador %s (ID: %d) entrando na sala ID: %d" % [player["name"], peer_id, int(room_identifier)])
		
	await get_tree().process_frame
	
	# Adiciona jogador
	var success: bool = room_registry.add_player_to_room(room_id, player_uuid)
	if not success:
		_send_error_to_client(
			peer_id,
			"Não foi possível entrar na sala (pode estar cheia ou em jogo)"
		)
		return false
	
	_log_debug("✓ Jogador %s entrou na sala: %s" %
		[player["name"], room.get("name", "")])
	
	# Envia dados da sala para o novato
	var room_data: Dictionary = room_registry.get_room(room_id)
	network_manager.rpc_id(peer_id, "_client_joined_room", room_data)
		
	await get_tree().process_frame
	
	# Atualiza sala para todos
	_notify_room_update(room_id)
	
	return true

func _handle_update_room_settings(peer_id, _changed_settings: Dictionary):
	"""
	Recebe pedido de alteração. Valida se quem enviou é o host. Aplica alterações e replica para todos.
	"""
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var room_id = client_registry.get_player_room(player_uuid)
	var room = room_registry.get_room(room_id)
	var player = client_registry.get_player(player_uuid)
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		return
	
	# verificar se a sala existe
	if not room_registry.room_exists(room_id):
		return
	
	# Verificar se tem um não host safado na labuta
	if room["host_id"] != player_uuid:
		_log_debug("Tem alguém enviando comandos de host sem ser host, nome do safadão: %s, session_id: %s" % [player["name"], peer_id])
		return
	
	# Aplica apenas o que mudou
	for key in _changed_settings.keys():
		room_registry.update_room_setting(room_id, key, _changed_settings[key])
		
	await get_tree().process_frame
	
	# Replica para todos os clientes
	for peer in room["players"]:
		var player_session_id = client_registry.get_peer_id_by_uuid(peer["id"])
		if _is_peer_connected(player_session_id):
			network_manager.rpc_id(player_session_id, "_client_update_match_settings", _changed_settings)

func _handle_leave_room(peer_id: int):
	"""Remove jogador da sala atual"""
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		return
	
	if player.is_empty() or not player.has("name"):
		return
	
	var room = room_registry.get_player_room(player_uuid)
	if room.is_empty():
		return
	
	var room_id = room["id"]
	
	_log_debug("Jogador %s saiu da sala: %s" % [player["name"], room["name"]])
		
	await get_tree().process_frame
	
	# Remove da sala (pode deletá-la se ficar vazia)
	room_registry.remove_player_from_room(room_id, player_uuid)
	
	# Verifica se sala ainda existe antes de notificar
	if room_registry.room_exists(room_id):
		_notify_room_update(room_id)
	else:
		_send_rooms_list_to_all()

func _handle_kick_player_from_room(peer_id: int, _selected_player_uuid: String):
	"""Servidor recebe pedido para expulsar player de sala"""
	
	# Informações do requerente
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var room = room_registry.get_player_room(player_uuid)
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		return
	
	# Verificar se este peer é o host de sua sala e está nela
	if not room_registry.is_player_host(player_uuid, room["id"]):
		return
	
	# Verificar se a sala está vazia
	if room.is_empty():
		return
	
	# Verificar se o player alvo está na sala
	if not room_registry.is_player_in_room(_selected_player_uuid, room["id"]):
		return
	
	# Verificar se o host está expulsando ele mesmo kkkk
	if player_uuid == _selected_player_uuid:
		return
		
	await get_tree().process_frame
	
	# Remover player da sala
	var kicked_player = client_registry.get_player(_selected_player_uuid)
	room_registry.remove_player_from_room(room["id"], _selected_player_uuid)
	room_registry.add_player_to_kicked(room["id"], _selected_player_uuid)
	
	# Atualizar a todos os clientes na sala
	_notify_room_update(room["id"])
	_notify_kicked_player(_selected_player_uuid)
	var minutos = int(kicked_default_timer / 60)
	_send_error_to_client(peer_id, "%s foi expulso da sala, ele poderá voltar
	 novamente em %s minuto%s" % [kicked_player["name"], minutos, "s" if minutos > 2 else ""])

func _handle_close_room(peer_id: int):
	"""Fecha uma sala (apenas host pode fazer isso)"""
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	if player.is_empty() or not player.has("name"):
		return
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		return
	
	var room = room_registry.get_player_room(player_uuid)
	if room.is_empty():
		return
	
	# Verifica se é host
	if room["host_id"] != player_uuid:
		return
	
	_log_debug("Host %s fechou a sala: %s" % [player["name"], room["name"]])
	
	var room_id = room["id"]
		
	await get_tree().process_frame
	
	# Notifica todos os players antes de deletar
	for room_player in room["players"]:
		var player_session_id = client_registry.get_peer_id_by_uuid(room_player["id"])
		if player_session_id != peer_id and _is_peer_connected(player_session_id):
			network_manager.rpc_id(player_session_id, "_client_room_closed", "O host fechou a sala")
	
	# Remove sala
	room_registry.remove_room(room_id)
	
	# Atualiza lista global
	_send_rooms_list_to_all()

func _notify_room_update(room_id: int):
	"""Notifica todos os players de uma sala sobre atualização nos dados da sala"""
	var room = room_registry.get_room(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		var player_session_id = client_registry.get_peer_id_by_uuid(player["id"])
		if _is_peer_connected(player_session_id):
			network_manager.rpc_id(player_session_id, "_client_room_updated", room)

func _notify_kicked_player(kicked_player_uuid: String):
	"""Notifica um player de uma sala que ele foi kickado"""
	_log_debug("Player %s foi expulso de sua sala, notificando" % kicked_player_uuid)
	var player_session_id = client_registry.get_peer_id_by_uuid(kicked_player_uuid)
	if _is_peer_connected(player_session_id):
		network_manager.rpc_id(player_session_id, "_client_kicked_from_room")

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
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error_to_client(peer_id, "Jogador não registrado")
		return
		
	await get_tree().process_frame
	
	# Valida sala
	var room = room_registry.get_player_room(player_uuid)
	
	if not room:
		_send_error_to_client(peer_id, "Primeiro crie uma sala")
		return
		
	var response = room_registry.can_start_match(room["id"], player_uuid)
	if not response[0]:
		_send_error_to_client(peer_id, response[1])
		return
			
	await get_tree().process_frame
	
	# muda estado do jogador
	client_registry.set_player_state(player_uuid, client_registry.ClientState.LOADING)
	
	# LOG DO INÍCIO
	_log_debug("========================================")
	_log_debug("HOST INICIANDO RODADA")
	_log_debug("Sala: %s (ID: %d)" % [room["name"], room["id"]])
	_log_debug("Jogadores participantes:")
	
	for room_player in room["players"]:
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %s)%s" % [room_player["name"], room_player["id"], is_host_mark])
	
	_log_debug("========================================")
		
	await get_tree().process_frame
	
	# Cria rodada no RoundRegistry
	# IMPORTANTE: Isso já chama client_registry.join_round() para cada player
	var round_data = round_registry.create_round(
		room["id"],
		room["name"],
		room["players"],
		round_settings
	)
		
	await get_tree().process_frame
	
	# Criar cena de organização do round
	var round_node = SubViewport.new()
	round_node.own_world_3d = true
	round_node.name = "Round_%d_%d" % [room["id"], round_data["round_id"]]
	
	round_data["round_node"] = round_node
		
	await get_tree().process_frame
	
	# Configurações para renderização fora de container
	round_node.size = Vector2i(1920, 1080)  # ou resolução da janela
	round_node.render_target_update_mode = SubViewport.UPDATE_ALWAYS  # ← força renderização
	
	all_rounds_node.add_child(round_node)
	
	round_registry.set_round_node(round_data["round_id"], round_node)
		
	await get_tree().process_frame
	
	# Cria nós organizacionais
	var players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	var objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	if round_data.is_empty():
		_send_error_to_client(peer_id, "Erro ao criar rodada")
		return
		
	await get_tree().process_frame
	
	# Extrai configurações da rodada
	var final_settings = round_data.get("settings", {})
	var map_scene_ = final_settings.get("map_scene", map_scene)
		
	await get_tree().process_frame
		
	# Cria câmera livre se não estiver em modo headless
	if not is_headless:
		actual_camera = preload(server_camera).instantiate()
		actual_camera.name = "FreeCamera"
		round_node.add_child(actual_camera)
		actual_camera.global_position = Vector3(0, 3, 5)  # X=0, Y=10 (altura), Z=15 (distância)
		actual_camera.current = true
	else:
		# Se estiver em modo headless criar uma câmera dummy
		actual_camera = Camera3D.new()
		actual_camera.name = "DummyCamera"
		round_node.add_child(actual_camera)
		actual_camera.global_position = Vector3(0, 100, 0)
		actual_camera.current = false
	
	await get_tree().process_frame
	
	# Carrega o mapa
	var success = await map_manager.load_map(map_scene, round_node, actual_camera)
	
	if not success:
		push_error("Falha crítica ao carregar o mapa!: ", success)
	else:
		_log_debug("Mapa carregado com sucesso")
		
	await get_tree().process_frame
	
	# Gera spawn points para todos os jogadores
	var players_count: int = round_registry.get_total_players(round_data["round_id"])
	final_settings["round_players_count"] = players_count
	final_settings["spawn_points"] = map_manager._create_spawn_points(room["players"])
		
	await get_tree().process_frame
	
	# Prepara pacote de dados para enviar aos clientes
	var match_data = {
		"round_id": round_data["round_id"],
		"room_id": room["id"],
		"map_scene": map_scene_,
		"settings": final_settings,
		"players": room["players"],
	}
		
	await get_tree().process_frame
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room["players"]:
		var player_sesion_id = client_registry.get_peer_id_by_uuid(room_player["id"])
		client_registry.set_player_state(room_player["id"], client_registry.ClientState.LOADING)
		network_manager.rpc_id(player_sesion_id, "_client_round_started",server_id , match_data)
		
	await get_tree().process_frame
	
	# Instancia mapa e players no servidor também
	await _server_instantiate_round(match_data, round_node, players_node)
			
	await get_tree().process_frame
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room["id"], true)
		
	await get_tree().process_frame
	
	# INICIA a rodada (ativa timers e verificações)
	round_registry.start_round(round_data["round_id"])
		
	await get_tree().process_frame
	
	# Atualiza lista de salas (remove esta sala da lista de disponíveis)
	_send_rooms_list_to_all()
			
	await get_tree().process_frame
	
	# Spawna alguns objetos
	if test_trainer:
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(1, 4, 1), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "steel_helmet", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "cape_1", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "sword_2", Vector3(2, 30, 1), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "shield_3", Vector3(0, 500, 0), Vector3(0, 0, 0))
		
	await get_tree().process_frame
	
	# Se não headless, joga este primeiro round para a camera do servidor
	var rounds_count = round_registry.get_active_rounds_count()
	if not is_headless and rounds_count == 1:
		await get_tree().process_frame
		_find_a_next_round_to_camera(round_data["round_id"])

# ===== INSTANCIAÇÃO NO SERVIDOR =====

func _server_instantiate_round(match_data: Dictionary, round_node, players_node):
	"""
	Instancia a rodada no servidor (mapa e players)
	Chamado após enviar comando para clientes carregarem
	"""
	
	_log_debug("Instanciando rodada no servidor...")
	
	# Aplica configurações de mapa
	await map_manager.apply_map_configs(match_data["settings"])
	var terrain_3d = round_node.get_node_or_null("Terrain3D")
		
	await get_tree().process_frame
	
	# Salva referência no RoundRegistry
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = map_manager
		
	await get_tree().process_frame
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["settings"]["spawn_points"][player_data["session_id"]]
		_spawn_player_on_server(player_data, spawn_data, players_node)
		
	await get_tree().process_frame
	
	# Se for o primeiro round, esta é a câmera atual
	if match_data["round_id"] != 1 and not is_headless:
		actual_camera.current = false
		
	await get_tree().process_frame
	
	# Configura o Terrain3D para usar actual_camera
	if terrain_3d:
		terrain_3d.set_camera(actual_camera)
		# Ativa o physics_process após atribuir a câmera
		terrain_3d.set_physics_process(true)
	else:
		push_warning("terrain_3d não encontrado para configurar câmera")

func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary, players_node):
	"""
	Spawna um jogador no servidor (versão autoritativa)
	Registra node e inicializa estado para validação
	Com controle assíncrono e timeouts de segurança
	"""
	
	# ===== VALIDAÇÕES INICIAIS =====
	if not player_data.has("id") or not player_data.has("name") or not player_data.has("session_id"):
		push_error("TestManager: player_data inválido: faltam campos obrigatórios")
		return
	
	var p_uuid = player_data["id"]
	var player_name = player_data["name"]
	var session_id = player_data["session_id"]
	
	_log_debug("🔄 [SPAWN] Iniciando spawn: %s (Session: %s, UUID: %s)" % [player_name, session_id, p_uuid])
	
	# ===== CARREGAMENTO DA CENA =====
	_log_debug("📦 [SPAWN] Carregando cena do player: %s" % player_scene)
	
	var player_scene_: PackedScene = preload(player_scene)
	if not player_scene_:
		push_error("TestManager: Falha ao carregar player_scene: %s" % player_scene)
		return
	
	# ===== INSTANCIAÇÃO =====
	var player_instance = player_scene_.instantiate()
	if not player_instance:
		push_error("TestManager: Falha ao instanciar player_scene")
		return
	
	_log_debug("✓ [SPAWN] Cena instanciada com sucesso")
	
	# ===== CONFIGURAÇÕES PRÉ-ÁRVORE =====
	# Configurações que podem ser feitas antes de adicionar à árvore
	player_instance.add_to_group("remote_player")
	player_instance.add_to_group("player")
	
	# CONFIGURAÇÃO CRÍTICA: Nome = ID do peer
	player_instance.name = str(session_id)
	player_instance.player_id = session_id
	player_instance.player_name = player_name
	player_instance._is_server = true
	player_instance.is_local_player = false
	
	_log_debug("⚙️ [SPAWN] Configurações básicas aplicadas")
	
	# ===== ADIÇÃO À ÁRVORE DE CENA =====
	_log_debug("🌳 [SPAWN] Adicionando player à cena...")
	
	players_node.add_child(player_instance)
	
	# Aguarda o player estar na árvore com timeout
	var tree_timeout = 60  # ~1 segundo a 60 FPS
	var tree_waited = 0
	
	while not player_instance.is_inside_tree() and tree_waited < tree_timeout:
		await get_tree().process_frame
		tree_waited += 1
	
	if not player_instance.is_inside_tree():
		push_error("TestManager CRÍTICO: Player %s não foi adicionado à árvore após %d frames!" % [p_uuid, tree_timeout])
		player_instance.queue_free()
		return
	
	_log_debug("✓ [SPAWN] Player adicionado à árvore de cena")
	
	# ===== INJEÇÃO DE DEPENDÊNCIAS =====
	_log_debug("💉 [SPAWN] Injetando dependências...")
	
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.server_manager = self
	player_instance.initializer = initializer
	
	# Aguarda processamento das dependências
	await get_tree().process_frame
	
	# ===== AGUARDA READY COM TIMEOUT =====
	if player_instance.has_method("_ready"):
		_log_debug("⏳ [SPAWN] Aguardando _ready() do player...")
		
		var ready_timeout = 120  # ~2 segundos
		var ready_waited = 0
		
		while not player_instance.is_node_ready() and ready_waited < ready_timeout:
			await get_tree().process_frame
			ready_waited += 1
		
		if ready_waited >= ready_timeout:
			push_warning("⚠️ [SPAWN] Timeout aguardando _ready() do player %s, continuando..." % p_uuid)
		else:
			_log_debug("✓ [SPAWN] Player está ready!")
	else:
		_log_debug("ℹ️ [SPAWN] Player não tem _ready(), pulando espera")
		await get_tree().process_frame
		await get_tree().process_frame
	
	# ===== INICIALIZAÇÃO DO JOGADOR =====
	_log_debug("🔧 [SPAWN] Inicializando dados do player...")
	
	var color: Color = Color(0.0, 0.0, 0.0, 1.0)
	var final_color = player_data["character"]["color"] if player_data["character"]["color"] else color
	
	player_instance.initialize(
		player_data["name"], 
		final_color, 
		session_id, 
		p_uuid, 
		spawn_data["position"]
	)
	player_instance.rotation = spawn_data["rotation"]
	
	# Aguarda processamento da inicialização
	await get_tree().process_frame
	
	# ===== CONFIGURAÇÕES DO MAPA =====
	_log_debug("🗺️ [SPAWN] Configurando referências do mapa...")
	
	player_instance.terrain_ = map_manager.current_map
	if player_instance.terrain_:
		player_instance.central_spawn = player_instance.terrain_.get_node_or_null("central_spawn")
		_log_debug("  - Terrain: %s" % ("✓" if player_instance.terrain_ else "✗"))
		_log_debug("  - Central Spawn: %s" % ("✓" if player_instance.central_spawn else "✗"))
	else:
		push_warning("⚠️ [SPAWN] MapManager não tem mapa carregado!")
	
	await get_tree().process_frame
	
	# ===== REGISTRO NO CLIENT REGISTRY =====
	_log_debug("📝 [SPAWN] Registrando no ClientRegistry...")
	
	client_registry.register_player_node(p_uuid, player_instance)
	
	await get_tree().process_frame
	
	# ===== REGISTRO NO ROUND REGISTRY =====
	_log_debug("📝 [SPAWN] Registrando no RoundRegistry...")
	
	var p_round = round_registry.get_round_by_player_uuid(p_uuid)
	if p_round.is_empty():
		push_warning("⚠️ [SPAWN] Rodada não encontrada para player %s, usando fallback" % p_uuid)
		round_registry.register_spawned_player(1, p_uuid, player_instance)  # Fallback para round 1
	else:
		round_registry.register_spawned_player(p_round["round_id"], p_uuid, player_instance)
		_log_debug("  - Round ID: %s" % p_round["round_id"])
	
	await get_tree().process_frame
	
	# ===== INICIALIZA ESTADO PARA VALIDAÇÃO ANTI-CHEAT =====
	_log_debug("🛡️ [SPAWN] Inicializando estado de validação...")
	
	player_states[p_uuid] = {
		"pos": spawn_data["position"],
		"vel": Vector3.ZERO,
		"rot": spawn_data["rotation"],
		"timestamp": Time.get_ticks_msec()
	}
	
	# ===== VALIDAÇÃO FINAL =====
	if not player_instance.is_inside_tree():
		push_error("TestManager CRÍTICO: Player %s removido da árvore após spawn!" % p_uuid)
		player_instance.queue_free()
		return
	
	_log_debug("✅ [SPAWN] Player spawnado com sucesso: %s (ID: %s) em %s" % [
		player_name, 
		p_uuid,
		spawn_data["position"]
	])

# ===== CALLBACKS DE RODADA =====

func _on_host_changed(room_id: int, new_host_uuid: String):
	"""Esta função é executada quando o host de uma sala é alterado"""
	var room = room_registry.get_room(room_id)
	var text = "Agora você é o caralhudo do host dessa sala: %s" % room["name"]
	var player_ = client_registry.get_player_by_uuid(new_host_uuid)
	
	if not _is_peer_connected(player_["peer_id"]):
		return
		
	network_manager._client_receive_message.rpc_id(player_["peer_id"], text, 6, "info")

func _on_round_ending(round_id: int, reason: String):
	"""
	Callback quando uma rodada está terminando
	Aguarda tempo de transição antes de finalizar completamente
	"""
	_log_debug("Rodada %d finalizando. Razão: %s" % [round_id, reason])
	
	# Aguarda tempo de transição (para mostrar resultados)
	await get_tree().create_timer(round_transition_time).timeout
	
	# Limpa os objetos do round
	object_manager.clear_round_objects(round_id)
		
	await get_tree().process_frame
	
	# Remove o nó deste round da lista de rounds do servidor
	var round_ = round_registry.get_round(round_id)
	all_rounds_node.remove_child(round_["round_node"])
	round_["round_node"].queue_free()
		
	await get_tree().process_frame
	
	# Finaliza completamente a rodada
	_complete_round_end(round_id)
	
	# Se a câmera estiver neste round, mover para o próximo
	if not is_headless and current_cam_round_index == round_["round_id"]:
		_find_a_next_round_to_camera()

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
	
	# Finaliza completamente no RoundRegistry
	# IMPORTANTE: Isso adiciona ao histórico da sala automaticamente
	round_registry.complete_round_end(round_id)
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room_id, false)
		
	await get_tree().process_frame
	
	# Notifica clientes para voltar à sala
	var room = room_registry.get_room(room_id)
	if not room.is_empty():
		for player in room["players"]:
			var player_session_id = client_registry.get_peer_id_by_uuid(player["id"])
			if _is_peer_connected(player_session_id):
				network_manager.rpc_id(player_session_id, "_client_return_to_room", room)
		
	await get_tree().process_frame
	
	# Atualiza lista de salas (sala volta a ficar disponível)
	_send_rooms_list_to_all()

# ===== VALIDAÇÃO ANTI-CHEAT =====

func _validate_player_movement(p_uuid: String, pos: Vector3, vel: Vector3, rot: Vector3 = Vector3.ZERO) -> bool:
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
	if not player_states.has(p_uuid):
		player_states[p_uuid] = {
			"pos": pos,
			"vel": vel,
			"rot": rot,
			"timestamp": Time.get_ticks_msec()
		}
		return true
	
	var last_state = player_states[p_uuid]
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
		_log_debug("Player: %s" % p_uuid)
		_log_debug("Distância: %.2f m em %.3f s" % [distance, time_diff])
		_log_debug("Máximo: %.2f m" % max_distance)
		_log_debug("Velocidade: %.2f m/s (máx: %.2f m/s)" % [distance/time_diff, max_player_speed * speed_tolerance])
		return false
	
	# VALIDAÇÃO 2: Velocidade reportada vs máxima
	var reported_speed = vel.length()
	
	if reported_speed > max_player_speed * speed_tolerance:
		_log_debug("⚠️ ANTI-CHEAT: Velocidade reportada suspeita")
		_log_debug("Player: %s" % p_uuid)
		_log_debug("Reportada: %.2f m/s" % reported_speed)
		_log_debug("Máximo: %.2f m/s" % (max_player_speed * speed_tolerance))
		return false
	
	# VALIDAÇÃO 3: Discrepância entre velocidade real e reportada
	var actual_speed = distance / time_diff if time_diff > 0 else 0
	
	if abs(actual_speed - reported_speed) > max_player_speed * 0.5:
		_log_debug("⚠️ ANTI-CHEAT: Discrepância entre velocidade real e reportada")
		_log_debug("Player: %s" % p_uuid)
		_log_debug("Real: %.2f m/s" % actual_speed)
		_log_debug("Reportada: %.2f m/s" % reported_speed)
		# Nota: Não retorna false aqui, pois pode ser lag legítimo
	
	# ATUALIZA ESTADO PARA PRÓXIMA VALIDAÇÃO
	player_states[p_uuid] = {
		"pos": pos,
		"vel": vel,
		"rot": rot,
		"timestamp": current_time
	}
	
	return true

# ===== SINCRONIZAÇÃO =====

func _apply_player_state_on_server(p_id: int, pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	
	var player_uuid = client_registry.get_uuid_by_peer_id(p_id)
	#var player = client_registry.get_player(player_uuid)
	var node = client_registry.get_player_node(player_uuid)
	if not (node and node.is_inside_tree()):
		return
	
	# Aplica no nó
	node.global_position = pos
	node.global_rotation = rot
	
	node.is_running = running
	node.is_jumping = jumping
	node.velocity = vel
	
	# Atualiza player_states para validação futura
	player_states[player_uuid] = {
		"pos": pos,
		"rot": rot,
		"vel": vel,
		"running": running,
		"jumping": jumping,
		"timestamp": Time.get_ticks_msec()
	}
	
	# Validação de movimento
	#_validate_player_movement(player_uuid, pos, vel, rot)

func _apply_animation_state_on_server(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
										
	var player_uuid = client_registry.get_uuid_by_peer_id(p_id)
	#var player = client_registry.get_player(player_uuid)
	var node = client_registry.get_player_node(player_uuid)
	if not (node and node.is_inside_tree()):
		return
		
	if node and node.has_method("_client_receive_animation_state"):
		node._client_receive_animation_state(speed, attacking, defending, jumping,
											   aiming, running, block_attacking, on_floor)

func _rpc_despawn_on_clients(player_ids: Array, round_id: int, object_id: int):
	"""
	Envia comando de despawn para clientes
	Chamado pelo ObjectManager.despawn_object()
	"""
	
	if not multiplayer.is_server():
		return
	
	# Envia RPC para cada cliente
	for player_id in player_ids:
		var player_session_id = client_registry.get_peer_id_by_uuid(player_id)
		network_manager._client_despawn_item.rpc_id(player_session_id, object_id, round_id)

# ===== VALIDAÇÃO DE ITENS =====

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_pick_up_item(requesting_player_id: int, object_id: int):
	"""Servidor recebe pedido de pegar item para o inventário, valida e redistribui"""
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var round_id = client_registry.get_player_round(player_uuid)
	var object = _get_spawned_object(round_id ,object_id)
	
	# Verificação se item é válido (é um objeto spawnado corretamente / tem os atributos adicionado pelo objeta manager)
	if not object:
		return
	
	var player_node = client_registry.get_player_node(player_uuid)
	var server_nearby = player_node.get_nearby_items()
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
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
	if client_registry.is_inventory_full(round_["round_id"], player_uuid):
		_log_debug("Impossível pegar item, inventário cheio!")
		return
		
	await get_tree().process_frame
	
	client_registry.add_item_to_inventory(round_["round_id"], player_uuid, str(item["id"]), object_id)
	
	# Despawn do objeto no mapa dos clientes
	_rpc_despawn_on_clients(round_players, round_["round_id"], object_id)
	
	# Despawn do objeto no mapa do servidor
	var item_node = object.get("node")
	if item_node and is_instance_valid(item_node) and item_node.is_inside_tree():
		item_node.queue_free()
		_log_debug("_server_validate_pick_up_item: Node removido da cena")
		
	await get_tree().process_frame
	
	# Define objeto armazenado / sai do spawned objects
	object_manager.store_object(round_["round_id"], object_id, player_uuid)
	
	# Executa animação no personagem remoto do servidor e nos clientes
	for peer_id in round_players:
		var player_session_id = client_registry.get_peer_id_by_uuid(peer_id)
		network_manager._client_apply_pick_up.rpc_id(player_session_id, requesting_player_id)
		
	await get_tree().process_frame
	
	# Executa animação no nó do servidor tbm
	if player_node and player_node.has_method("action_pick_up_item"):
		player_node.action_pick_up_item()
	
	# Se o slot deste item estiver vazio, equipar este item lá automaticamente \/
	if not client_registry.is_slot_empty(round_["round_id"], player_uuid, item["type"]):
		return
	
	# Se auto equip false, não equipar automaticamente
	if not item_database.get_item(item["name"]).is_auto_equip_function():
		return
		
	await get_tree().process_frame
	
	# Equipa o item no registro do player
	client_registry.equip_item(round_["round_id"], player_uuid, item["name"], object_id)
	
	_log_debug("[ITEM]📦 Slot deste item está vazio, equipando automaticamente: Player %d equipou item %d" % [requesting_player_id, item["id"]])
	
	# Envia para todos os clientes do round (para atualizar visual)
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["round_id"])
	for peer in filtered_:
		if _is_peer_connected(peer["session_id"]):
			network_manager.rpc_id(peer["session_id"], "_client_apply_equip", requesting_player_id, item["id"])
		
	await get_tree().process_frame
	
	# Aplica visual tbm na cena do servidor
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(str(item["id"]))

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_equip_item(requesting_player_id: int, object_id: int, _target_slot_type):
	"""Servidor recebe pedido de equipar item, valida e redistribui"""
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
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
	if not client_registry.is_slot_empty(round_["round_id"], player_uuid, _target_slot_type):
		push_warning("[ITEM]O Slot já está ocupado por outro item, pedido de equipamento cancelado pelo servidor")
		return
		
	await get_tree().process_frame
	
	# Equipa o item no registro do player
	client_registry.equip_item(round_["round_id"], player_uuid, item["name"], object_id)
	
	_log_debug("✓ Item equipado: %s em %s (Player %s, Rodada %d)" % [item["name"], item["type"], player_uuid, round_["round_id"]])
	
	# Envia para todos os clientes do round (para atualizar visual)
		
	await get_tree().process_frame
	
	# Para cada player neste round
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["round_id"])
	for peer in filtered_:
		var session_id = client_registry.get_peer_id_by_uuid(peer["id"])
		if _is_peer_connected(session_id):
			network_manager.rpc_id(session_id, "_client_apply_equip", requesting_player_id, item_id, false, true)
		
	await get_tree().process_frame
	
	# Aplica visual tbm na cena do servidor
	var player_node = players_node.get_node_or_null(str(requesting_player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(item_id, false, true)
			
@rpc("any_peer", "call_remote", "reliable")
func _server_validate_unequip_item(requesting_player_id: int, slot_type: String):
	"""Servidor recebe pedido de desequipar item, valida e redistribui"""

	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	var item_ = client_registry.get_equipped_item_in_slot(round_["round_id"], player_uuid, slot_type)
	
	if not item_:
		return
		
	var item_id = item_["item_id"]
	var players_node = round_["round_node"].get_node_or_null("Players")
	var item = item_database.get_item_by_id(int(item_id))
	var item_slot = item.get_slot()
	
	_log_debug("[ITEM]📦 Player %s pediu para desequipar item %d no slot %s, no round %d" % [player["name"], item["id"], item["type"], round_["round_id"]])
		
	await get_tree().process_frame
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	# Verificar se o slot_type recebido é válido
	if not item_:
		return
	
	client_registry.unequip_item(round_["round_id"], player_uuid, item_slot)
	
	_log_debug("✓ Item desequipado: %s de %s (Player %s, Rodada %d)" % [item["name"], item["type"], player_uuid, round_["round_id"]])
		
	await get_tree().process_frame
	
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["round_id"])
	for peer in filtered_:
		var player_session_id = client_registry.get_peer_id_by_uuid(peer["id"])
		if _is_peer_connected(player_session_id):
			network_manager.rpc_id(player_session_id, "_client_apply_equip", requesting_player_id, int(item_id), true, true)
		
	await get_tree().process_frame
	
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
	var player_uuid = client_registry.get_uuid_by_peer_id(player_id)
	#var player = client_registry.get_player(player_uuid)
	var round_id: int = client_registry.get_player_round(player_uuid)
	var round_data = round_registry.get_round(round_id)
		
	await get_tree().process_frame
	
	# Verifica se o player tem pelo menos um destes itens equipado
	var dragged_equipped := client_registry.is_item_equipped(round_id, player_uuid, int(dragged_item_id))
	var target_equipped := client_registry.is_item_equipped(round_id, player_uuid, int(target_item_id))
	
	await get_tree().process_frame
	
	# XOR: um true e o outro false
	if dragged_equipped == target_equipped:
		return
		
	# Verifica se o player tem pelo menos um destes itens no inventário
	var dragged_in_inventory := client_registry.has_item_in_inventory(round_id, player_uuid, int(dragged_item_id))
	var target_in_inventory := client_registry.has_item_in_inventory(round_id, player_uuid, int(target_item_id))
	# XOR: um true e o outro false
	if dragged_in_inventory == target_in_inventory:
		return
		
	await get_tree().process_frame
	
	# PASSO 1: IDENTIFICAR QUAL ITEM VEM DO INVENTÁRIO (será equipado)
	
	var is_dragged_equipped: bool = client_registry.is_item_equipped(round_id, player_uuid, int(dragged_item_id))
	
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
	
	await get_tree().process_frame
	
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
		
	await get_tree().process_frame
	
	# PASSO 3: EXECUTAR TROCA (usando EXATAMENTE sua lógica original)
	
	# NOTA: Usamos item_data["type"] como slot de destino (como no seu código original)
	client_registry.swap_equipped_item(
		round_id,
		player_uuid,
		item_name,                # Nome do item do inventário
		inventory_item_dict,      # Dados do item do inventário
		int(equipped_item_id),    # ID do item equipado (será substituído)
		item_data["type"]         # Tipo do slot (ex: "hand-left", "head") - MANTENHA "type"
	)
	
	await get_tree().process_frame
	
	# PASSO 4: ATUALIZAR VISUAL (mantendo sua lógica original)
	var players_node = round_data["round_node"].get_node_or_null("Players")
	if not players_node:
		return
		
	await get_tree().process_frame
	
	# Servidor:
	# Mudança de visual sincronizada para os remotes e clientes
	var player_node = players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(item_data["id"])
	# Ações diversas relacionadas a swap de itens sincronizadas para os remotes e clientes
	if player_node and player_node.has_method("execute_item_swap"):
		player_node.execute_item_swap()
			
	await get_tree().process_frame
	
	# Clientes:
	# _client_apply_equip executa ambas: apply_visual_equip_on_player_node e execute_item_swap
	for peer in round_data["players"]:
		var player_session_id = client_registry.get_peer_id_by_uuid(peer["id"])
		if _is_peer_connected(player_session_id):
			network_manager.rpc_id(player_session_id, "_client_apply_equip", player_id, item_data["id"], false, false, true)
	
@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_spawn_item(requesting_player_id: int, item_id: int):
	"""Servidor recebe pedido de spawnar item na frente do player para testes"""
	
	if not test_trainer:
		return
	
	# Não quero o shield_3, quero a tocha
	if item_id == 9:
		item_id = 10
	
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	_log_debug("[ITEM]📦 Player %s: Trainer pediu para spawnar item %d na sua frente, no round %d" % [player["name"], item_id, round_["round_id"]])
	
	# Verifica se o id do item é válido
	if not item_database.get_item_by_id(item_id):
		return
		
	await get_tree().process_frame
	
	var objects_node = round_["round_node"].get_node_or_null("Objects")
	var item_name = item_database.get_item_by_id(item_id)
	# ObjectManager cuida de spawnar E enviar RPC
	object_manager.spawn_item_over_of_player(objects_node, round_["round_id"], player_uuid, item_name["name"])

@rpc("any_peer", "call_remote", "reliable")
func _server_validate_drop_item(requesting_player_id: int, obj_id: int):
	"""Servidor recebe pedido de drop, valida e spawna item executando drop_item()
	IMPORTANTE: USA ESTADO DO SERVIDOR, não do cliente"""
	# Na hora do drop, se tiver um item equipado e for o item dropado, desequipar e dropar, se não for o mesmo, apenas dropar
	# Se não tiver nenhum item equipado, apenas dropar se tiver no inventário
	
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	
	# Validação 1:
	if not player_states.has(player_uuid):
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
	
	var is_item_equipped = client_registry.is_item_equipped(round_["round_id"], player_uuid, obj_id)
	var object_item_name = object_manager.get_stored_object_item_name(round_["round_id"], obj_id)
	var item_ = item_database.get_item(object_item_name).to_dictionary()
	var item_slot = item_database.get_slot(object_item_name)
	var item_id = 0
		
	await get_tree().process_frame
	
	# Se o item estiver equipado
	if is_item_equipped:
		var equiped_obj_id = client_registry.get_equipped_item_in_slot(round_["round_id"], player_uuid, item_slot)["object_id"]
			
		# Pega o id do item para esconder no player
		item_id = int(client_registry.get_equipped_item_in_slot(round_["round_id"], player_uuid, item_slot)["item_id"])
		
		# Verificar se o item dropado é o mesmo item que está equipado, se sim, pedir para desequipar
		if int(equiped_obj_id) == int(obj_id):
			client_registry.unequip_item(round_["round_id"], player_uuid, item_slot, false)
		
		# Aplica no nó do servidor
		var player_node = client_registry.get_player_node(player_uuid)
		if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(int(item_id), true)
		
		# Aplicar nos players remotos dos clientes
		var filtered_ = round_registry.get_round_players_spawned_filter(round_["round_id"])
		for peer in filtered_:
			var session_id = client_registry.get_peer_id_by_uuid(peer["id"])
			if _is_peer_connected(session_id):
				network_manager.rpc_id(session_id, "_client_apply_equip", requesting_player_id, int(item_id), true)
	
	_log_debug("[ITEM]📦 Servidor vai validar pedido de drop de item ObjId: %d tipo %s do player ID %s" % [obj_id, item_["name"], requesting_player_id])
		
	await get_tree().process_frame
	
	# Validação 4:
	if not item_database.get_item_by_id(item_id) and item_id != 0:
		push_warning("[ServerManager]: ID de item inválido recebido: %d" % item_id)
		return
	
	# Se o player não tiver nenhum item no próprio inventário para dropar, não faz nada
	var has_any = client_registry.has_any_item(round_["round_id"], player_uuid)
	_log_debug("Player tem algum item para dropar?: %s" % has_any)
	if not has_any:
		push_warning("[ServerManager]: Player não tem nenhum item no inentário para dropar")
		return
		
	_log_debug("[ITEM]📦 Pedido válido! Executando drop de item ObjId: %d tipo %s do player ID %s" % [obj_id, item_["name"], requesting_player_id])
		
	await get_tree().process_frame
	
	# Executar drop (o item deve estar no inventário do player / já verificado acima) \/
	# Pegar o item_id do objeto referido
	var player_invent_items = client_registry.get_inventory_items(round_["round_id"], player_uuid)
	for item in player_invent_items:
		if item["object_id"] == obj_id:
			item_id = item["item_id"]
			break
		
	await get_tree().process_frame
			
	var item_data = item_database.get_item_by_id(int(item_id))
	var objects_node = round_["round_node"].get_node_or_null("Objects")
	
	if item_data:
		# Dados de posição e rotação do player para dropar obj item à sua frente
		var player_state = player_states[player_uuid]
		var player_pos = player_state["pos"]
		var player_rot = player_state["rot"]
		var spawn_pos = object_manager._calculate_front_position(player_pos, player_rot)
		
		# Object Manager, retomar o nó do item de volta à cena
		object_manager.retrieve_stored_object(objects_node, round_["round_id"], obj_id, spawn_pos, Vector3(0, 0, 0,), player_uuid)
		
		# Remove item do inentário do player
		client_registry.remove_item_from_inventory(round_["round_id"], player_uuid, obj_id)
		
		# Executa ações referentes a isso no player no servidor e em seus remotos nos clientes
		var round_players = client_registry.get_players_in_round(round_["round_id"])
		for peer_id in round_players:
			var session_id = client_registry.get_peer_id_by_uuid(peer_id)
			if _is_peer_connected(session_id):
				network_manager._client_apply_drop.rpc_id(session_id, requesting_player_id, item_data["name"])
			
		await get_tree().process_frame
	
		# Aplica no nó do servidor
		var player_node = client_registry.get_player_node(player_uuid)
		if player_node and player_node.has_method("execute_item_drop"):
			player_node.execute_item_drop()

# ===== TRAINER DE TESTE =====

@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_drop_item(player_id):
	"""Servidor recebe pedido de dropar item do inventário(apenas do inventário) na frente do player para testes"""
	_log_debug('_server_trainer_drop_item')
	
	if not test_trainer:
		return
	
	var player_uuid = client_registry.get_uuid_by_peer_id(player_id)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	
	# Se o player não tiver nenhum item no inventário para dropar, não faz nada
	var has_any = client_registry.has_any_item(round_["round_id"], player_uuid)
	_log_debug("Player tem algum item para dropar?: %s" % has_any)
	if not has_any:
		return
	
	#var player = client_registry.get_player(player_id)
	#var item_name = item_database.get_item_by_id(item_id)["name"]
	#var players_node = round_["round_node"].get_node_or_null("Players")
	var obj_id = client_registry.get_inventory_items(round_["round_id"], player_uuid)[0]["object_id"]
	var item_id = int(client_registry.get_inventory_items(round_["round_id"], player_uuid)[0]["item_id"])

	var objects_node = round_["round_node"].get_node_or_null("Objects")
		
	await get_tree().process_frame
	
	# Remover o item do registro do player
	client_registry.remove_item_from_inventory(round_["round_id"], player_uuid, obj_id)
	
	var item_data = item_database.get_item_by_id(item_id)
	if item_data:
		var player_state = player_states[player_uuid]
		var player_pos = player_state["pos"]
		var player_rot = player_state["rot"]
		var spawn_pos = object_manager._calculate_front_position(player_pos, player_rot)
			
		# Retomar o nó do item de volta à cena no object manager
		object_manager.retrieve_stored_object(objects_node, round_["round_id"], obj_id, spawn_pos, Vector3(0, 0, 0,), player_uuid)
		client_registry.remove_item_from_inventory(round_["round_id"], player_uuid, obj_id)
		
@rpc("any_peer", "call_remote", "reliable")
func _server_trainer_repawn_player(player_id, player_uuid):
	"""Servidor recebe pedido de respawnar player para testes"""
	
	# Só passar se estiver com trainer ligado
	if not test_trainer:
		return
	
	var player = client_registry.get_player(player_uuid)
	_log_debug("%s pediu para spawnar novamente" % player["name"])
	
	var round_id: int = client_registry.get_player_round(player_uuid)
	var round_ = round_registry.get_round(round_id)
	var round_data = round_registry.get_round(round_id)
	
	var players_node = round_data["round_node"].get_node_or_null("Players")
	if not players_node:
		return
		
	await get_tree().process_frame
	
	# Aplica na cena de player do servidor
	var player_node = players_node.get_node_or_null(str(player_id))
	if player_node and player_node.has_method("_respawn_player"):
		player_node._respawn_player(map_manager.spawn_center)
		
	await get_tree().process_frame
	
	# Aplica nas cenas do players remotos
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["round_id"])
	for peer in filtered_:
		var player_session_id = client_registry.get_peer_id_by_uuid(peer["id"])
		if _is_peer_connected(player_session_id):
			network_manager.rpc_id(player_session_id, "_client_apply_respawn", player_id, map_manager.spawn_center)
		
# ===== VALIDAÇÕES DE AÇÕES DO PLAYER =====

func attack_validation(group: String, player_id: int, actual_weapon: String, victim_session_id: int):
	#_log_debug("attack_validation: grupo: %s, player_id: %s, actual_weapon: %s, victim_session_id: %s" % 
	#[group, player_id, actual_weapon, victim_session_id])
	
	# Se for um player remoto
	if group == "remote_player":
		var player_uuid = client_registry.get_uuid_by_peer_id(player_id)
		var round_ = round_registry.get_round_by_player_uuid(player_uuid)
		var round_players = client_registry.get_players_in_round(round_["round_id"])
		var victim_uuid = client_registry.get_uuid_by_peer_id(victim_session_id)
		
		for peer_uuid in round_players:
			await get_tree().process_frame
			var session_id = client_registry.get_peer_id_by_uuid(peer_uuid)
			network_manager._client_receive_attack.rpc_id(session_id, victim_session_id)
			
		await get_tree().process_frame
	
		# Aplica no nó do servidor
		var player_node = client_registry.get_player_node(victim_uuid)
		if player_node and player_node.has_method("take_damage"):
			player_node.take_damage()
		
		_log_debug("Ataque executado!: %s, %d com um(a) %s em %d" % [group, player_id, actual_weapon,  victim_session_id])

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(p_id: int, action_type: String, item_equipado_nome, anim_name: String):
	"""RPC: Servidor recebe ação do jogador e redistribui para os remotos do mesmo round e remoto 
	corresondente no servidor também"""
	
	var player_uuid = client_registry.get_uuid_by_peer_id(p_id)
	var player = client_registry.get_player_round(player_uuid)
	var round_id = round_registry.get_round_by_player_uuid(player_uuid)["round_id"]
	var players_round = round_registry.get_active_players_ids(round_id)
	
	# Ignora o próprio player
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != p_id:
		return
	
	# Se for um ataque
	if action_type == "attack":
		# Servidor verifica se o player tem uma arma equipada
		if not client_registry.has_weapon_equipped(player, player_uuid):
			return
		_log_debug("%s tem uma arma equipada: %s" % [player, client_registry.has_weapon_equipped(player, player_uuid)])
			
	# Se for um ataque com escudo:
	elif action_type == "block_attack":
		# Servidor verifica se o player tem uma escudo equipado
		if not client_registry.has_shield_equipped(player, player_uuid):
			return
		_log_debug("%s tem um escudo equipado: %s" % [player, client_registry.has_shield_equipped(player, player_uuid)])
	
	# Se for um pedido de iniciar defesa com escudo
	elif action_type == "defend_start":
		# Servidor verifica se o player tem uma escudo equipado
		if not client_registry.has_shield_equipped(player, player_uuid):
			return
	
	# Propaga pra todos os outros clientes (Reliable = Garantido)
	for peer_uuid in players_round:
		if peer_uuid != player_uuid:
			var session_id = client_registry.get_peer_id_by_uuid(peer_uuid)
			network_manager._client_player_action.rpc_id(session_id, p_id, action_type, item_equipado_nome, anim_name)

			# Dica: Outra forma de chamar rpc(quando está inacessível p o server mas existe no pc remoto):
			# if has_method("_client_player_action"):
				# rpc_id(peer_id, "_client_player_action", p_id, action_type, anim_name)
		
	await get_tree().process_frame
	
	# Para defend_stop o servidor aplica sem verificações
	# Aplica no nó do servidor
	var player_node = client_registry.get_player_node(player_uuid)
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
	for player_data in client_registry.get_all_players():
		var peer_id = player_data["id"]
		if _is_peer_connected(peer_id):
			multiplayer.disconnect_peer(peer_id)
	
	# 4. Reseta registries
	round_registry.reset()
	room_registry.reset()
	client_registry.reset()
	
	_log_debug("✓ Servidor desligado completamente")

func _cleanup_player_state(peer_uuid: String):
	"""
	Remove estado de validação do jogador
	Chamado quando desconecta
	"""
	
	if player_states.has(peer_uuid):
		player_states.erase(peer_uuid)
		_log_debug("Estado de validação removido")

func _kick_player_from_round(peer_id: int, reason: String):
	"""
	Kicka um jogador do servidor (anti-cheat ou outras razões)
	Remove da rodada, sala e desconecta
	"""
	
	# Remove da rodada se estiver em uma
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	var room_ = room_registry.get_player_room(player_uuid)
	
	if not room_ or not player_uuid:
		return
	
	_log_debug("========================================")
	_log_debug("⚠️ KICKANDO JOGADOR")
	_log_debug("Peer ID: %d" % peer_id)
	_log_debug("Razão: %s" % reason)
	_log_debug("========================================")
	
	# Mudar estado do cliente para LOADING
	client_registry.set_player_state(player_uuid, client_registry.ClientState.LOADING)
	
	# Notifica cliente
	_notify_kicked_player(player_uuid)
	
	# Adiciona em expulsos da sala
	room_registry.add_player_to_kicked(room_["id"], player_uuid)
	
	# Executa função de sair
	_player_exit_from_round(player["room_id"], player["peer_id"], player_uuid)

func _send_error_to_client(peer_id: int, message: String):
	"""Envia mensagem de erro para um cliente"""
	_log_debug("❌ Enviando erro para cliente %d: %s" % [peer_id, message])
	if _is_peer_connected(peer_id):
		network_manager.rpc_id(peer_id, "_client_receive_error", message)

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

func _cleanup_empty_rounds():
	"""Limpa as rounds vazios após tempo determinado desde que ficou vazio
	usa ROUND_EMPTY_TIMEOUT"""
	var now = Time.get_unix_time_from_system()
	var all_rounds = round_registry.get_all_rounds()

	for round_id in all_rounds.keys():
		# Se round estiver vazio
		var round_ = round_registry.get_round(round_id)
		if round_registry.get_active_player_count(round_["round_id"]) == 0 and round_["empty_since"]:
			# Se empty_since maior que tempo determinado
			if round_.has("empty_since") and now >= round_["empty_since"] + ROUND_EMPTY_TIMEOUT:
				round_registry.end_round(round_["round_id"], "all_quitted")
				
				# Neste caso remove a sala também (já remove players dela tbm)
				for player in round_["players"]:
					room_registry.remove_player_from_room(round_["room_id"], player["id"])
				
# ===== DEBUG =====

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "Server" in initializer.selected:
		return
	
	print("[SERVER]" + message)

func _print_player_states():
	"""Debug: Imprime estados de todos os players para validação"""
	_log_debug("[PLAYSTATES]========================================")
	_log_debug("[PLAYSTATES]ESTADOS DOS JOGADORES NO SERVIDOR")
	_log_debug("[PLAYSTATES]Total: %d" % player_states.size())
	
	for p_uuid in player_states.keys():
		var state = player_states[p_uuid]
		var age = (Time.get_ticks_msec() - state["timestamp"]) / 1000.0
		
		_log_debug("[PLAYSTATES]Player %s:" % p_uuid)
		_log_debug("[PLAYSTATES]Pos: %s" % str(state["pos"]))
		_log_debug("[PLAYSTATES]Vel: %s (%.2f m/s)" % [str(state["vel"]), state["vel"].length()])
		_log_debug("[PLAYSTATES]Rot: %s" % str(state["rot"]))
		_log_debug("[PLAYSTATES]Última atualização: %.2f s atrás" % age)
		_log_debug("[PLAYSTATES]------------")
	
	_log_debug("========================================")
