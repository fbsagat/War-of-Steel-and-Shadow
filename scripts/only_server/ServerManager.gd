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
## Timer para imprimir estados periodicamente
@export var debug_timer: bool = false
## [TESTES] Usa o TestManager para iniciar logo uma partida na execução (initializer sobrepõe)
@export var fast_round: bool = false
## [TESTES] Define a quantidade de instnacias de clientes para executar fast_round (initializer sobrepõe)
@export var simulador_players_qtd: int = 8
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
# Se ter um uuid aqui, significa que o servidor é compartilhado e tem um dono player, se "", é dedicado.
var server_owner_ : String = ""

@export_category("Default Node References")
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
## Diferença mínima de comparação com time_diff para validação de posição
@export var min_diff: float = 0.005 # ms

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var network_manager: ServerNetworkManager = null
var client_registry : ServerClientRegistry = null
var room_registry: ServerRoomRegistry = null
var round_registry: ServerRoundRegistry = null
var item_database: ItemDatabase = null
var object_manager: ServerObjectManager = null
var test_manager: TestManager = null
var map_manager: MapManager = null
var persistence_manager: ServerPersistence = null
var debug_overlay = null
var warning_overlay = null

# ===== REFERÊNCIAS INTERNAS =====

var all_rounds_node: Node = null
var current_cam_round_index: int = -1
var current_active_camera: Camera3D = null
var mouse_mode: bool = false
var current_active_viewport: SubViewport = null
var viewport_display: TextureRect = null
var test_mode_check_timer: Timer
var initializer: GameInitializer = null

# ===== VARIÁVEIS INTERNAS =====

## Rastreamento de estados dos jogadores para validação anti-cheat
## Formato: {peer_uuid: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
var player_states: Dictionary = {}
var actual_camera: Camera3D = null
var is_loading: bool = false

# ===== INICIALIZAÇÃO DO MANAGER =====

func _ready() -> void:
	if persistence_manager:
		# Injeta em client registry
		client_registry.persistence_manager = persistence_manager

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
	
	# Se persistência estiver ativada
	if persistence_manager:
		# Gera ou carrega id único do servidor
		persistence_manager.init(true if persistence_manager else false)
		server_id = persistence_manager.server_id
		server_secret = persistence_manager.server_secret
		
		# Carrega jogadores salvos
		var loaded = persistence_manager.load_players()
		client_registry.players = loaded["players"]
		client_registry.players_cache = loaded["players_cache"]
		
		# Verifica se jogadores carregados estão conectados e atualiza
		for player_uuid in client_registry.players.keys():
			var player = client_registry.get_player(player_uuid)
			if not _is_peer_connected(player["peer_id"]):
				# Atualiza estado conectado
				client_registry.set_disconnected_peer(player["peer_id"])
				
				# Atualiza sala/round
				# Na inicialização, não existe salas e rounds, portanto, remover do registro
				# Removendo da sala, automaticamente já remove do round.
				if player["room_id"] > 0:
					client_registry.reset_player_room_round(player_uuid)
	
	else:
		var crypto: Crypto = Crypto.new()
		server_id = crypto.generate_random_bytes(16).hex_encode()
		server_secret = crypto.generate_random_bytes(32)
		
	# Inicializa servidor
	_start_server()
	
	# Mostrando a tela de clientes do debug overlay
	if not is_headless and debug_overlay:
		debug_overlay._toggle_tab(debug_overlay.Tab.CLIENTS)

# ===== SETUPS =====

## Gera:
##  - server_id (hex string pública)
##  - server_secret (bytes privados)
## Ambos existem apenas durante esta execução.
func _generate_server_identity() -> void:
	var crypto = Crypto.new()
	server_id = crypto.generate_random_bytes(16).hex_encode()
	server_secret = crypto.generate_random_bytes(32)

## Conecta sinais dos registries
func _connect_signals():
	# Sinais de rodada
	round_registry.round_ending.connect(_on_round_ending)
	room_registry.host_changed.connect(_on_host_changed)
	
## Aqui inicializamos o sistema de verificação automática
func _setup_test_mode_verification():
	test_mode_check_timer = Timer.new()
	test_mode_check_timer.name = "test_mode_verification_timer"
	test_mode_check_timer.wait_time = 2.0 # período em segundos
	test_mode_check_timer.one_shot = false
	test_mode_check_timer.timeout.connect(_on_fast_round_verify_timeout)
	add_child(test_mode_check_timer)
	test_mode_check_timer.start()

## Esta função é chamada automaticamente sempre que o Timer atinge o tempo configurado
func _on_fast_round_verify_timeout():
	if _test_round_check():
		test_mode_check_timer.stop()
		
##  Esta função executa a lógica de verificação. Ela retorna:
##   - true  → quando a partida de teste foi iniciada
##  - false → quando ainda não há jogadores suficientes
func _test_round_check() -> bool:
	_log_debug("Chamada periódica para iniciar o modo de testes")
	# Executar sistema de teste automático no momento que entra e registra a quantidade de players necessária
	var players_on_count = client_registry.get_connected_player_count()
	if players_on_count >= simulador_players_qtd:
		test_manager.create_test_round()
		return true
	return false

## Cria um TextureRect que mostra o viewport atual na tela
func _setup_viewport_display():
	viewport_display = TextureRect.new()
	viewport_display.anchor_right = 1.0
	viewport_display.anchor_bottom = 1.0
	viewport_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	viewport_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	viewport_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport_display.name = "ViewportDisplay"
	
	# Adiciona como child direto da raiz para preencher a tela
	get_tree().root.add_child(viewport_display)

## Cria timer para imprimir estados periodicamente
func _setup_debug_timer():
	var debug_timer_ = Timer.new()
	debug_timer_.wait_time = 5.0
	debug_timer_.autostart = true
	debug_timer_.timeout.connect(_print_player_states)
	debug_timer_.name = "debug_timer"
	add_child(debug_timer_)

## Essa função cria e configura um timer automático no servidor para fazer limpeza periódica 
## de rounds vazios.
func _setup_cleanup_empty_rounds_timer():
	var cleanup_timer_ = Timer.new()
	cleanup_timer_.wait_time = CLEANUP_INTERVAL
	cleanup_timer_.autostart = true
	cleanup_timer_.timeout.connect(_cleanup_empty_rounds)
	cleanup_timer_.name = "cleanup_timer"
	add_child(cleanup_timer_)

# ===== FUNÇÕES DE INPUT =====

## Redireciona inputs para o viewport/câmera ativa
func _unhandled_input(event: InputEvent) -> void:
	if is_headless or not current_active_viewport:
		return
	
	# Não processa Tab (já é usado para trocar câmera)
	if event is InputEventKey and event.keycode == KEY_TAB:
		return
	
	# Envia o evento para o viewport ativo
	if is_instance_valid(current_active_viewport) and current_active_viewport.is_inside_tree():
		current_active_viewport.push_input(event, true)
	
func _input(event: InputEvent) -> void:
	if is_headless:
		return
	
	var showing_message = warning_overlay.is_showing
	var rounds_size = round_registry.get_active_rounds_count()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB and not showing_message and rounds_size > 1:
		_find_a_next_round_to_camera()
	
	if event.is_action_pressed("ui_cancel") and debug_overlay._active_tab == -1:
		_toggle_mouse_mode()
		
	if event.is_action_pressed("ui_cancel") and debug_overlay._active_tab > -1:
		debug_overlay._close()
	
	# Teste
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_BACKSPACE:
		_log_debug("Backspace!!! Coloque algo aqui...")

## Decide e muda a câmera para o próximo round válido
func _find_a_next_round_to_camera(round_id: int = -1):

	var all_rounds := round_registry.get_all_rounds_keys()
	all_rounds.sort()

	# 🔴 1. Se não há rounds
	if all_rounds.is_empty():
		current_cam_round_index = -1
		_log_debug("[Camera] Não há rounds ativos")
		if warning_overlay:
			warning_overlay.show_message("Não há rounds ativos")
		viewport_display.visible = false
		return

	# 🟢 2. Se recebeu round específico
	if round_id != -1:
		if not all_rounds.has(round_id):
			_log_debug("[Camera] Round inválido: %s" % round_id)
			return
		
		current_cam_round_index = round_id

	# 🔵 3. Seleção circular automática
	else:
		# Se nunca selecionou ou não existe mais
		if current_cam_round_index == -1 or not all_rounds.has(current_cam_round_index):
			current_cam_round_index = all_rounds[0]
		else:
			var index := all_rounds.find(current_cam_round_index)
			index = (index + 1) % all_rounds.size()
			current_cam_round_index = all_rounds[index]

	# ✅ 4. Aqui SEMPRE temos um round válido
	_log_debug("[Camera] Indo para round: %s" % current_cam_round_index)
	if warning_overlay:
		warning_overlay.show_message("[Camera] Câmera indo para o round: %s" % current_cam_round_index)

	_switch_camera_to_round(current_cam_round_index)

## Ativa a câmera de um round específico e atualiza o display
func _switch_camera_to_round(round_id: int) -> void:
	_log_debug("[Camera] Movendo câmera para round %s" % round_id)
	
	# 1. Garanta que o display esteja INVISÍVEL enquanto trocamos a textura
	# Isso impede que o renderer tente desenhar uma textura inválida
	viewport_display.visible = false
	
	# Segurança ao pegar round
	var round_ = round_registry.get_round(round_id)
	if not round_:
		push_warning("[Camera] Round não encontrado: %s" % round_id)
		return
		
	var round_node = round_.get("round_node", null)
	
	# Validação robusta do nó
	if not round_node or not is_instance_valid(round_node) or not round_node.is_inside_tree():
		push_warning("[Camera] Round node inválido: %s" % round_id)
		return
	
	if not (round_node is SubViewport):
		push_warning("[Camera] round_node não é um SubViewport")
		return
	
	# Verifica tamanho mínimo (Viewport sem tamanho não gera textura)
	if round_node.size.x <= 0 or round_node.size.y <= 0:
		_log_debug("[Camera] Viewport sem tamanho válido")
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
			
			_log_debug("[Camera] ✓ Câmera ativada: %s em %s" % [new_camera.name, round_node.name])
		else:
			push_warning("[Camera] ✗ Viewport ainda não gerou textura para %s" % round_node.name)
			# Opcional: Mostrar uma tela de "Aguardando..." ao invés de deixar invisível
	else:
		push_warning("[Camera] ✗ Câmera não encontrada em %s" % round_node.name)

## Altera o modo do mouse (reverte estdo ou forçado por comando)
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

## Inicializa servidor dedicado e todos os subsistemas
func _start_server():
	var timestamp = Time.get_datetime_string_from_system()
	_log_debug("================================================================")
	_log_debug("▶️ INICIANDO SERVIDOR DEDICADO ▶️")
	_log_debug("================================================================")
	_log_debug("Em: %s" % timestamp)
	_log_debug("Porta: %d" % server_port)
	_log_debug("ID: %s" % server_id)
	_log_debug("👑 Servidor de %s" % server_owner_ if is_shared_server() else "👑 Servidor dedicado")
	_log_debug("Máximo de clientes: %d" % max_clients)
	_log_debug("Trainer de testes: %s, Fast Round: %s" % [test_trainer, fast_round])
	_log_debug("Min. de jogadores/sala: %s, Max. de jogadores/sala: %s" % [min_players_to_start, max_players_per_room])
	_log_debug("Tempo de espera de reconexão(peer): %sms" % reconnect_timout)
	_log_debug("-----------------------------------------------------------------")
	var c = self.get_node_or_null("cleanup_timer")
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
		
		# Se for compartilhado, desliga o servidor
		if is_shared_server():
			shutdown_server()
		return
	
	multiplayer.multiplayer_peer = peer
	
	# Conecta sinais de rede
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func finish_start_server_log():
	_log_debug("================================================================")
	_log_debug("▶️ Servidor inicializado com sucesso! ▶️")
	_log_debug("================================================================")
	print("")

# ===== SISTEMA DE IDENTIFIAÇÃO =====

## 1) Cliente envia:
##   - uuid_base
##   - token (opcional)
## 2) Se token válido → autentica.
## 3) Se token inválido ou ausente:
##   - Se jogador existe e está desconectado → reconectar.
##   - Se novo jogador → criar registro.
##   - Gerar novo token e retornar ao cliente.
## Retorna:
## {
## "status": "ok" | "new_token" | "reject",
## "token": String (se new_token),
## "server_id": String
## }
func process_client_hello(payload: Dictionary, peer_id: int) -> Dictionary:
	_log_debug("Processando client hello: %s, peer_id: %s" % [payload, peer_id])
	
	var uuid_base : String = payload.get("uuid_base", "")
	var client_token : String = payload.get("token", "")
	
	# Validação básica
	if uuid_base.is_empty() or uuid_base.length() != 32:
		return {"status": "reject", "reason": "missing_uuid"}
	
	# Validações para servidor compartilhado
	# Se for servidor compartilhado, continuar apenas se a sala já existir e estiver destrancada,
	# caso contrário, emitir 'rejeitado pelo servidor'
	if is_shared_server() and not room_registry.get_room_count() == 0:
		var keys = room_registry.rooms.keys()
		var room = room_registry.rooms[keys[0]]
		if room["settings"]["locked"]:
			return {"status": "reject", "reason": "locked_room"}
	
	# Se for servidor compartilhado e não for o proprietário e não houver sala criada, o cliente
	# entrou antes dele: 'rejeitado pelo servidor'
	if is_shared_server() and uuid_base != server_owner_ and room_registry.get_room_count() == 0:
		return {"status": "reject", "reason": "await_owner"}
	
	# Se a sala já estiver em jogo
	if is_shared_server() and room_registry.get_room_count() > 0:
		var keys = room_registry.rooms.keys()
		var room = room_registry.rooms[keys[0]]
		if room["in_game"]:
			return {"status": "reject", "reason": "in_game"}
	
	# Se o jogador está em quitted_players (Saiu permanentemente da partida)
	if is_shared_server() and room_registry.get_room_count() > 0:
		var keys = room_registry.rooms.keys()
		var room = room_registry.rooms[keys[0]]
		for player in room["kicked_players"]:
			if player["uuid_base"] == uuid_base:
				return {"status": "reject", "reason": "player_kicked"}
		
	# Validação caracteres válidos
	for c in uuid_base:
		if not (
			(c >= "0" and c <= "9") or
			(c >= "a" and c <= "f") or
			(c >= "A" and c <= "F")
		):
			return {"status": "reject", "reason": "invalid_format"}

	# Bloqueia duplicidade ativa
	if client_registry._is_uuid_connected(uuid_base):
		return {"status": "reject", "reason": "dup_session"}

	# Se cliente enviou token, validar
	if not client_token.is_empty():
		var expected = client_registry._compute_token(uuid_base)
		if client_token == expected:
			var player = client_registry.get_player_by_uuid(uuid_base)
			client_registry.update_peer_id(uuid_base, peer_id)
			client_registry._register_connection(uuid_base)
			
			# Verificar se tem um round carregado no servidor com este cliente conectado nele
			# Se sim, envia 'ok_in_round', se não, envia apenas 'ok'
			var player_round = round_registry.get_round_by_player_uuid(uuid_base)
			
			# Se não tem, muda estado do jogador para LOBBY
			if not player_round:
				var client_uuid = client_registry.get_uuid_by_peer_id(peer_id)
				var client = client_registry.get_player(client_uuid)
				if client and client["round_id"] == -1:
					client_registry.set_player_state(client_uuid, client_registry.ClientState.LOBBY)
				
				# Se for shared server e já estiver com nome definido, cria sala, adiciona na sala e
				# envia dados dela para o cliente
				if player["name"] != "" and is_shared_server():
					if player["entry_position"] == 1:
						if client_uuid == server_owner_ and player["room_id"] < 0:
							# Função para criar partida local
							create_shared_round(peer_id)
					
					var host = client_registry.get_player(server_owner_)
					if host:
						_handle_join_room(peer_id, host["room_id"], "")
				
				return {"status": "ok", "server_id": server_id, "player_name": player["name"]}
			else:
				# Marca player como conectado no round
				round_registry._unmark_player_disconnected(player_round["id"], uuid_base)
				return {"status": "ok_in_round", "server_id": server_id, "player_name": player["name"]}
				
	# Token inválido ou inexistente → emitir novo
	if not client_registry.get_player_by_uuid(uuid_base):
				
		client_registry.add_peer(peer_id, uuid_base)
	client_registry._register_connection(uuid_base)

	var new_token = client_registry._compute_token(uuid_base)
	client_registry.register_player(uuid_base, peer_id)
	return {
		"status": "new_token",
		"token": new_token,
		"server_id": server_id
	}

# ===== CALLBACKS DE CONEXÃO =====

## Callback quando um cliente conecta ao servidor
func _on_peer_connected(peer_id: int):
	_log_debug("✓ Cliente conectado: Peer ID %d" % peer_id)

## Callback quando um cliente desconecta
func _on_peer_disconnected(peer_id: int):
	# Desabilita o peer_id para o sync de objetos
	network_manager.stop_peer_sync(peer_id)
	
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Se o servidor for local e o dono for este cliente, fecha o processo
	# (Redundância/godot já fecha processos filhos)
	if is_server_owner(player_uuid):
		shutdown_server()
	
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
				room_registry.remove_player_from_room(room_id, player_uuid)
				_log_debug("%s Removido da sala: %s" % [player_data["name"], room["name"]])
				
				# Verifica se sala ainda existe antes de notificar
				if room_registry.room_exists(room_id):
					# Atualiza informações de sala para os outros
					_notify_room_update(room_id)
					
					# Notifica outros jogadores da sala sobre a desconexão
					var updated_room = room_registry.get_room(room_id)
					for player in updated_room["players"]:
						if player["peer_id"] != peer_id and _is_peer_connected(player["peer_id"]):
							_log_debug("_client_remove_player", true)
							network_manager.rpc_id(player["peer_id"], "_client_remove_player", player_uuid)
				else:
					_log_debug("Sala foi deletada (ficou vazia)")
					_send_rooms_list_to_all()
	
	# Define cliente como desconectado
	client_registry.set_disconnected_peer(peer_id)
	_log_debug("❌ Cliente desconectado: Peer ID %d" % peer_id)
	
	
# ===== HANDLERS DE JOGADOR =====

## Processa solicitação de registro de nome de jogador
func _handle_register_player_name(peer_id: int, player_name: String):
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
		
	await get_tree().process_frame
	
	# Valida nome
	var validation_result = client_registry._validate_player_name(player_name)
	if validation_result != "":
		_log_debug("❌ Nome rejeitado: " + validation_result)
		_log_debug("_client_name_rejected", true)
		network_manager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
	
	await get_tree().process_frame
	
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
		
	# Valida estado da partida
	var player = client_registry.get_player(player_uuid)
	var room_in_game = room_registry.is_room_in_game(player["room_id"])
	if room_in_game:
		_log_debug("❌ Jogador tentou registrar nome duarante a partida")
		return
		
	await get_tree().process_frame
	
	# Registra no ServerClientRegistry
	var success = client_registry.register_player_name(player_uuid, player_name)
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		
		var room_data_filtered: Dictionary = {}
		# Se for shred server, adiciona na sala e envia dados dela para o cliente
		if is_shared_server() and player["uuid_base"] != server_owner_:
			var host = client_registry.get_player(server_owner_)
			if host:
				room_data_filtered = room_registry.get_room_filtered(host["room_id"])
				_handle_join_room(peer_id, host["room_id"], "")
		_log_debug("_client_name_accepted", true)
		network_manager.rpc_id(peer_id, "_client_name_accepted", player_name, room_data_filtered)
		
		# Atualzia a sala deste player, se ele estiver em uma

		if player["room_id"] > 0:
			_notify_room_update(player["room_id"])
		
		# Se for servidor compartilhado, já cria a sala única (verificando se é o primeiro a conectar/o dono)
		if player and is_shared_server() and player["entry_position"] == 1:
			if player_uuid == server_owner_ and player["room_id"] < 0:
				# Função para criar partida local
				create_shared_round(peer_id)
	else:
		_log_debug("❌ Falha ao registrar jogador")
		_log_debug("_client_name_rejected", true)
		network_manager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")
		
		
# ===== HANDLERS DE SALAS =====

## Cria uma sala local para o cliente proprietário do servidor. Chamado automaticamente.
func create_shared_round(peer_id, nome_sala_: String = "Partida Local"):
	
	# Valida registries
	if not client_registry or not room_registry or not round_registry:
		_log_debug("❌ Registries não disponíveis!")
		return
	
	var selected_map: int = 3
	
	# Cria sala no ServerRoomRegistry
	_handle_create_room(peer_id, nome_sala_, "", true, selected_map)
	
## Envia lista de salas disponíveis (não em jogo) para o cliente que requisitou
func _handle_request_rooms_list(peer_id: int):
	_log_debug("Cliente %d solicitou lista de salas" % peer_id)
	
	if not _is_peer_connected(peer_id):
		return
		
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	
	# Valida se player está registrado
	if not client_registry.is_player_registered(player_uuid):
		_send_error_to_client(peer_id, "Jogador não registrado")
		return
		
	await get_tree().process_frame
	
	# Verificar se jogador está em uma partida no momento (no servidor)
	if client_registry.in_round(player_uuid):
		# Se estiver em uma partida, perguntar se quer retornar para ela
		var room_id = client_registry.get_player_room(player_uuid)
		var room = room_registry.get_room(room_id)
		_log_debug("Requisitando para cliente %d retorno à partida em que estava ao desconectar")
		_log_debug("_client_receive_round_return_request", true)
		network_manager.rpc_id(peer_id, "_client_receive_round_return_request", room["name"])
	else:
		# Se não estiver, enviar lista de salas para ele escolher
		# Busca salas disponíveis (fora de jogo)
		var available_rooms = room_registry.get_rooms_in_lobby_clean_to_menu()
		_log_debug("Enviando %d salas para o cliente, qtd: " % available_rooms.size())
		if _is_peer_connected(peer_id):
			_log_debug("_client_receive_rooms_list", true)
			network_manager.rpc_id(peer_id, "_client_receive_rooms_list", available_rooms)

## Envia lista de salas disponíveis para todos os jogadores fora de partida 
## (cliente ignora se não estiver na lista de salas) (não envia para jogadores em partida)
func _send_rooms_list_to_all():
	if is_shared_server():
		_log_debug("Não enviando lista de salas: Servidor compartilhado")
		return
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
			_log_debug("_client_broadcast_rooms_list", true)
			network_manager.rpc_id(peer_id, "_client_broadcast_rooms_list", available_rooms)
			## Aqui deu o erro Unnable to send packet on channel 0, max channels: 0
			
## Servidor recebe resposta de cliente sobre voltar (true) ou abandonar (false) round em andamento
## Depois:
## 1. Se ele clicar em retornar, se estiver em uma round em andamento, retornar para o round, se
## não estiver ou round não está mais em andamento, retornar para a sala apenas, se a sala não existir
## mais, reseta registro e retorna para a lista de salas (verificar tudo isso no momento da execução).
## 2. Se ele clicar em 'sair de vez': Retirar (descarregar nós e mudar estados) o jogador da 
## sala/partida(no servidor e cliente(caso esteja) e enviar normalmente a lista de salas
## pra ele escolher.
## chosen = true - Cliente quer voltr ao round / false: Cliente saiu de vez
func _handle_request_return_or_exit(peer_id: int, chosen: bool):
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
		
	_player_exit_from_round(peer_id, player_uuid)

## Esta função deve ser executada quando o cliente simplesmente reconecta ao round em que está,
## neste caso o cliente ainda está com a partida carregada, está apenas retornando de uma queda de
## conexão. Esta função é necesária porque as posições de players e objetos são alteradas durante a
##  gameplay enquando o cliente está ausente da partida.
func _execute_player_simple_return_to_round(peer_id: int, player_uuid: String):
	var round_id = client_registry.get_player_round(player_uuid)
	var round_ = round_registry.get_round(round_id)
	# Filtrar players que ainda estão na partida (apenas spawned players)
	var filtered_players = round_registry.get_round_players_spawned_filter(round_["id"])
	
	var match_data = {
	"settings": {},
	"round_objects": {},
	}
	match_data["settings"]["spawn_points"] = {}
	
	for f_player in filtered_players:
		# Prepara posições e rotações de cada remoto na partida
		# {peer_uuid: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
		var position: Vector3 = player_states[f_player["uuid_base"]].get("pos")
		var rotation: Vector3 = player_states[f_player["uuid_base"]].get("rot")
		match_data["settings"]["spawn_points"][f_player["uuid_base"]] = {
			"position": position,
			"rotation": rotation}
		await get_tree().process_frame
	
	# Prepara objetos da cena para atualização visual
	var round_objects = object_manager.get_round_objects(round_["id"])
	# round_objects: [Object_1_torch_1:<RigidBody3D#123765524253>, Object_2_torch_1:<RigidBody3D#123916521411>]
	# executa no game manager: _spawn_on_client(object_id: int, round_id: int, 
	# item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_uuid: String)
	var all_objects: Dictionary
	for object in round_objects:
		await get_tree().process_frame
		all_objects[object["object_id"]] = {
			"position": object.global_position,
			"rotation": object.global_rotation,
			"linear_velocity": object["linear_velocity"],
			"owner_uuid": object["owner_uuid"],
		}
	match_data["round_objects"] = all_objects
	
	# Envia comando de retorno para o cliente
	_log_debug("_client_player_simple_return", true)
	network_manager.rpc_id(peer_id, "_client_player_simple_return", server_id, match_data)
	
## Esta função deve ser executada quando o cliente sinaliza que quer voltar ao round em que está,
## mas não está com a partida carregada, portanto precisa dos dados completos para o retorno, acontece 
## quando, no servidor, seu personagem está instanciado em um round e seu registros indicam isso também
func _execute_player_return_to_round(peer_id: int, player_uuid: String):
	var player = client_registry.get_player(player_uuid)
	_log_debug("Player %s quer retornar à partida em que estava" % player["name"])
	# Verifica de novo se a partida/round está em andamente, se sim, entra, se não, volta pra sala apenas
	var round_id = client_registry.get_player_round(player_uuid)
	var round_ = round_registry.get_round(round_id)
	
	if round_registry.is_round_active(round_id):
		_log_debug("enviando comando para o cliente carregar a partida dele")
		
		# Tratar round settings para enviar atualizadas para o cliente
		var terrain_ = round_["map_node"]
		var sky_node = terrain_.get_node("Sky3D")
		var time_node = sky_node.get_node_or_null("TimeOfDay")
		round_["settings"]["sky_rand_configs"]["time"]["current_time"] = time_node.current_time
		
		# Filtrar players que ainda estão na partida (apenas spawned players)
		var filtered_players = round_registry.get_round_players_spawned_filter(round_["id"])
		
		# Pega scene_path do mapa selecionado para a rodada
		var map = map_manager.map_database.get_map_by_id(round_["settings"]["selected_map"])
		
		var match_data = {
			"round_id": round_["id"],
			"room_id": round_["room_id"],
			"map_scene": map["scene_path"],
			"settings": round_["settings"],
			"players": filtered_players,
			"player_items": [],
			"equipped_items": {},
			"round_objects": {},
		}
		match_data["settings"]["spawn_points"] = {}
		
		for f_player in filtered_players:
			# Prepara posições e rotações de cada remoto na partida
			# {peer_uuid: {pos: Vector3, vel: Vector3, rot: Vector3, timestamp: int}}
			var position: Vector3 = player_states[f_player["uuid_base"]].get("pos")
			var rotation: Vector3 = player_states[f_player["uuid_base"]].get("rot")
			match_data["settings"]["spawn_points"][f_player["uuid_base"]] = {
				"position": position,
				"rotation": rotation}
				
			await get_tree().process_frame
			
			# Prepara modelos de personagens (próprio e remotos) para atualização visual
			var player_equip = client_registry.get_equipped_items(round_id, f_player["uuid_base"])
			match_data["equipped_items"][f_player["uuid_base"]] = player_equip
		
		# Prepara seu inventário para atualização visual
		var player_items = client_registry.get_inventory_items(round_id, player_uuid)
		match_data["player_items"] = player_items
		
		# Prepara objetos da cena para atualização visual
		var round_objects = object_manager.get_round_objects(round_["id"])
		# round_objects: [Object_1_torch_1:<RigidBody3D#123765524253>, Object_2_torch_1:<RigidBody3D#123916521411>]
		# executa no game manager: _spawn_on_client(object_id: int, round_id: int, 
		# item_name: String, position: Vector3, rotation: Vector3, drop_velocity: Vector3, owner_uuid: String)
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
		
		# Muda estado do jogador
		client_registry.set_player_state(player_uuid, client_registry.ClientState.LOADING)
		
		# Envia comando de retorno para o cliente
		_log_debug("_client_round_return", true)
		network_manager.rpc_id(peer_id, "_client_round_return", server_id, match_data)

## Esta função deve ser executada quando o cliente sinaliza que quer abandonar o round em que está, 
## quando seu personagem está instanciado em um round e seu registros indicam isso também
func _player_exit_from_round(peer_id: int, player_uuid: String):
	var player = client_registry.get_player(player_uuid)
	_log_debug("Player %s quer abandonar a partida em que estava" % player["name"])
	
	# 1. Limpa nó da rodada (se estiver em uma) (se não estiver vazia)
	var p_round = round_registry.get_round_by_player_uuid(player_uuid)
	var round_id = p_round["id"]
	
	if not p_round.is_empty():
		# Remove node da cena do servidor
		var player_node = round_registry.get_spawned_player(round_id, player_uuid)
		if player_node and is_instance_valid(player_node):
			player_node.queue_free()
			_log_debug("Nó do player removido da cena")
			
		await get_tree().process_frame
		
		# Remove registro de spawn, limpa node path e remove do round
		round_registry.remove_player(round_id, player_uuid)
		client_registry.clear_player_node_path(player_uuid)
	
		await get_tree().process_frame
		
		# Executa rpcs nos outros clientes
		for r_player in p_round["players"]:
			if r_player["peer_id"] != peer_id and _is_peer_connected(r_player["peer_id"]):
				# Tem que estar fora das listas disconnected e quitted e não ser o próprio
				if r_player["uuid_base"] in round_registry.connected_clients and not r_player["uuid_base"] == player_uuid:
					
					# Envia aviso para os outros de que este jogador saiu permanentemente
					var r_player_tt = client_registry.get_player(r_player["uuid_base"])
					var text = "Jogador %s desistiu da partida" % player["name"]
					_log_debug("_client_receive_message", true)
					network_manager._client_receive_message.rpc_id(r_player_tt["peer_id"], text, 6, "info")
					
					# Eviar comando para os outros clientes removerem também node da cena
					_log_debug("_client_remove_player", true)
					network_manager.rpc_id(r_player["peer_id"], "_client_remove_player", player_uuid)
		
	await get_tree().process_frame
	
	# 2. LIMPA SALA (se estiver em uma)
	var player_data = client_registry.get_player(player_uuid)
	var room = room_registry.get_player_room(player_uuid)
	
	if not player_data.is_empty() and player_data["name"] != "":
		
		if not room.is_empty():
			var room_id = room["id"]
			
			# Remove da sala (pode deletá-la se ficar vazia)
			room_registry.remove_player_from_room(room_id, player_uuid)
			_log_debug("%s Removido da sala: %s" % [player_data["name"], room["name"]])
			
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
	
	# 5. Remover player da sala no registro (já remove do round também)
	#room_registry.remove_player_from_room(player_room_id, player_uuid)
	
	# 6. Depois disso, verificar se todos quitaram permanentemente do round, se sim, finaliza automaticamente
	if round_registry.get_total_players(round_id) == 0:
		_log_debug("Finalizando round imediatamente, todos os players quitaram")
		round_registry.end_round(round_id, "all_quitted")
	
	# 7. Enviar a lista de salas pro player
	_handle_request_rooms_list(peer_id)
	
## Recebe aviso do cliente de que está desconectado (_chosen = false) ou reconectado 
## (_chosen = true) em um round.
##   - Não envia rpcs de sincronia e round em geral para ele durante desconexão/economia de rede
func _mark_player_disconnected(peer_id: int, _chosen: bool):
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	if not player_uuid:
		return
		
	var _round = round_registry.get_round_by_player_uuid(player_uuid)
	
	if not _round:
		return
	
	if _chosen:
		# Marca player como desconectado no round
		round_registry._mark_player_disconnected(_round["id"], player_uuid)
		
		_log_debug("⚠ %s marcado como desconectado na rodada %d" % [player["name"], _round["id"]])
	else:
		# Marca player como conectado no round
		round_registry._unmark_player_disconnected(_round["id"], player_uuid)
		
		_log_debug("✓ uuid=%s removido de disconnected_players na rodada %d" % [player["name"], _round["id"]])

# Cria uma nova sala e adiciona o criador como host
func _handle_create_room(peer_id: int, room_name: String, password: String, locked = false, selected_map: int = 3):
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		_log_debug("Jogador %s já está em uma partida" % player["name"])
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
		_log_debug("_client_room_name_error", true)
		network_manager.rpc_id(peer_id, "_client_room_name_error", validation)
		return
	
	_log_debug("Criando sala '%s' para jogador %s (ID: %d)" % [room_name, player["name"], peer_id])
	
	# Cria sala
	var room_data = room_registry.create_room(
		room_name,
		password,
		player_uuid,
		min_players_to_start,
		max_players_per_room,
		locked,
		selected_map)
	
	if room_data.is_empty():
		_send_error_to_client(peer_id, "Erro ao criar sala")
		return
	
	_log_debug("✓ Sala criada: %s (ID: %d, Host: %s)" % [room_name, room_data["id"], player["name"]])
		
	await get_tree().process_frame
	
	# Atualiza lista de salas para todos (útil para quem está na lista de salas)
	_send_rooms_list_to_all()
	
	# Confirma criação para o criador
	_log_debug("_client_room_created", true)
	network_manager.rpc_id(peer_id, "_client_room_created", room_data)

## Wrapper: entra por ID
func _handle_join_room(peer_id: int, room_id: int, password: String) -> bool:
	return await _handle_join_room_common(peer_id, room_id, password, false)

## Wrapper: entra por nome
func _handle_join_room_by_name(peer_id: int, room_name: String, password: String) -> bool:
	return await _handle_join_room_common(peer_id, room_name, password, true)

## Executado quando um cliente pede pra entrar em uma sala
func _handle_join_room_common(peer_id: int, room_identifier: Variant, password: String, by_name: bool) -> bool:
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala ID: %d" % [player["name"], peer_id, int(room_identifier)])
	
	# Se estiver em um partida não executa
	if client_registry.in_round(player_uuid):
		_log_debug("Jogador %s tentou entrar na sala %d mas está em uma partida" % [player["name"], int(room_identifier)])
		return false
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_log_debug("Jogador não registrado")
		_send_error_to_client(peer_id, "Jogador não registrado")
		return false
	
	# Verifica se já está em uma sala
	var current_room: Dictionary = room_registry.get_player_room(player_uuid)
	if not current_room.is_empty():
		_log_debug("Jogador %s já está em uma sala." % player["name"])
		_send_error_to_client(peer_id, "Jogador já está em uma sala. Saia primeiro.")
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
		_log_debug("_client_room_not_found", true)
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
		_log_debug("_client_wrong_password", true)
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
		
	var room_data_filtered: Dictionary = room_registry.get_room_filtered(room_id)
	_log_debug("_client_joined_room", true)
	network_manager.rpc_id(peer_id, "_client_joined_room", room_data_filtered)
		
	await get_tree().process_frame
	
	# Atualiza sala para todos
	_notify_room_update(room_id)
	
	return true

## Recebe pedido de alteração. Valida se quem enviou é o host. Aplica alterações e replica para todos.
func _handle_update_room_settings(peer_id, _changed_settings: Dictionary):
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
	if room["host_uuid"] != player_uuid:
		_log_debug("Tem alguém enviando comandos de host sem ser host, nome do safadão: %s, peer_id: %s" % [player["name"], peer_id])
		return
	
	# Aplica apenas o que mudou
	for key in _changed_settings.keys():
		room_registry.update_room_setting(room_id, key, _changed_settings[key])
		
	await get_tree().process_frame
	
	# Replica para todos os clientes
	for peer in room["players"]:
		var player_peer_id = client_registry.get_peer_id_by_uuid(peer["uuid_base"])
		if _is_peer_connected(player_peer_id):
			_log_debug("_client_update_match_settings", true)
			network_manager.rpc_id(player_peer_id, "_client_update_match_settings", _changed_settings)

## Remove jogador da sala atual
func _handle_leave_room(peer_id: int):
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

## Servidor recebe pedido para expulsar player de sala
func _handle_kick_player_from_room(peer_id: int, _selected_player_uuid: String):
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

## Fecha uma sala (apenas host pode fazer isso)
func _handle_close_room(peer_id: int):
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
	if room["host_uuid"] != player_uuid:
		return
	
	_log_debug("Host %s fechou a sala: %s" % [player["name"], room["name"]])
	
	var room_id = room["id"]
		
	await get_tree().process_frame
	
	# Notifica todos os players antes de deletar
	for room_player in room["players"]:
		var player_peer_id = client_registry.get_peer_id_by_uuid(room_player["uuid_base"])
		if player_peer_id != peer_id and _is_peer_connected(player_peer_id):
			_log_debug("_client_room_closed", true)
			network_manager.rpc_id(player_peer_id, "_client_room_closed", "O host fechou a sala")
	
	# Remove sala
	room_registry.remove_room(room_id)
	
	# Atualiza lista global
	_send_rooms_list_to_all()

## Notifica todos os players de uma sala sobre atualização nos dados da sala
func _notify_room_update(room_id: int):
	var room = room_registry.get_room_filtered(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		var player_peer_id = client_registry.get_peer_id_by_uuid(player["uuid_base"])
		if _is_peer_connected(player_peer_id):
			_log_debug("_client_room_updated", true)
			network_manager.rpc_id(player_peer_id, "_client_room_updated", room)

## Notifica um player de uma sala que ele foi kickado
func _notify_kicked_player(kicked_player_uuid: String):
	var player = client_registry.get_player(kicked_player_uuid)
	_log_debug("Player %s foi expulso de sua sala, notificando" % player["name"])
	var player_peer_id = client_registry.get_peer_id_by_uuid(kicked_player_uuid)
	if _is_peer_connected(player_peer_id):
		_log_debug("_client_kicked_from_room", true)
		network_manager.rpc_id(player_peer_id, "_client_kicked_from_room")


# ===== HANDLER DE INÍCIO DE RODADA =====

## Inicia uma nova rodada na sala.
func _handle_start_round(peer_id: int, round_settings: Dictionary, is_test: bool = false):
	# Aguarda liberação com timeout de segurança (~10s a 60fps)
	var timeout_frames: int = 600
	var waited_frames: int = 0

	while is_loading:
		await get_tree().process_frame
		waited_frames += 1
		if waited_frames >= timeout_frames:
			_log_debug("Timeout: is_loading não liberou após %d frames" % timeout_frames)
			break
	
	is_loading = true
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	
	# Valida jogador
	if player.is_empty() or not player.has("name"):
		_send_error_to_client(peer_id, "Jogador não registrado")
		return
	
	# Valida sala
	var room = room_registry.get_player_room(player_uuid)
	
	if not room:
		_send_error_to_client(peer_id, "Primeiro crie uma sala")
		return
		
	await get_tree().process_frame
	
	# Verifica se pode iniciar um round e retorna erro se houver
	var response = room_registry.can_start_match(room["id"], player_uuid)
	if not response[0]:
		_send_error_to_client(peer_id, response[1])
		return
	
	# Se não houver erros, continua
	# Muda estado do jogador
	client_registry.set_player_state(player_uuid, client_registry.ClientState.LOADING)
	
	# LOG DO INÍCIO
	print("")
	_log_debug("========================================")
	_log_debug("%s INICIANDO RODADA %s" % ["SERVER" if is_test else "HOST", "DE TESTE" if is_test else ""])
	_log_debug("Sala: %s (ID: %d)" % [room["name"], room["id"]])
	_log_debug("Jogadores participantes:")
	for room_player in room["players"]:
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %s)%s" % [room_player["name"], room_player["uuid_base"], is_host_mark])
	_log_debug("========================================")
	print("")
	await get_tree().process_frame
	
	# Cria rodada no ServerRoundRegistry
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
	round_node.name = "Round_%d_%d" % [room["id"], round_data["id"]]
	
	# Registra node deste round
	round_registry.set_round_node(round_data["id"], round_node)
		
	await get_tree().process_frame
	
	# Configurações para renderização fora de container
	round_node.size = Vector2i(1920, 1080)  # ou resolução da janela
	round_node.render_target_update_mode = SubViewport.UPDATE_ALWAYS  # ← força renderização
	
	all_rounds_node.add_child(round_node)
		
	await get_tree().process_frame
	
	# Cria nós organizacionais
	var players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	var objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	if round_data.is_empty():
		push_warning("Erro ao criar rodada")
		return
		
	await get_tree().process_frame
	
	# Extrai configurações da rodada
	var final_settings = round_data.get("settings", {})
	
	# Pega scene_path do mapa selecionado para a rodada
	var map = map_manager.map_database.get_map_by_id(round_settings["selected_map"])
	var map_scene_ = map["scene_path"]
	
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
		actual_camera.current = true
	
	await get_tree().process_frame
	
	# Carrega o mapa
	var result: bool = await map_manager.load_map(map_scene_, round_node, actual_camera)
	
	if not result:
		push_error("Falha crítica ao carregar o mapa!: ", result)
	else:
		_log_debug("Mapa carregado com sucesso")
		round_registry.set_round_map_node(round_data["id"], map_manager.get_current_map())
		
	await get_tree().process_frame
	
	# Pega a quantidade de jogadores neste round
	var players_count: int = round_registry.get_total_players(round_data["id"])
	# Atribui totalidade de jogadores no round
	final_settings["round_players_count"] = players_count
	# Gera spawn points para todos os jogadores
	final_settings["spawn_points"] = map_manager._create_spawn_points(room["players"])
	
	await get_tree().process_frame
	
	# Prepara pacote de dados para enviar aos clientes
	var match_data = {
		"round_id": round_data["id"],
		"room_id": room["id"],
		"map_scene": map_scene_,
		"settings": final_settings,
		"players": room["players"],
	}
		
	await get_tree().process_frame
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room["players"]:
		var player_sesion_id = client_registry.get_peer_id_by_uuid(room_player["uuid_base"])
		client_registry.set_player_state(room_player["uuid_base"], client_registry.ClientState.LOADING)
		if _is_peer_connected(player_sesion_id):
			_log_debug("_client_round_started", true)
			network_manager.rpc_id(player_sesion_id, "_client_round_started",server_id , match_data)
		
	await get_tree().process_frame
	
	# Instancia mapa e players no servidor também
	await _server_instantiate_round(match_data, players_node)
			
	await get_tree().process_frame
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room["id"], true)
		
	await get_tree().process_frame
	
	# INICIA a rodada (ativa timers e verificações)
	round_registry.start_round(round_data["id"])
		
	await get_tree().process_frame
	
	# Atualiza lista de salas (remove esta sala da lista de disponíveis)
	_send_rooms_list_to_all()
			
	await get_tree().process_frame
	
	# Se for partida de testes, spawna alguns objetos
	if test_trainer:
		object_manager.spawn_item(objects_node, round_data["id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "steel_helmet", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "cape_1", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "sword_2", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "shield_3", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "potion_glass_heal", Vector3(0, 3, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "potion_glass_stamina", Vector3(0, 3, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["id"], "potion_glass_poison", Vector3(4.577, 3, 22.876), Vector3(0, 0, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["id"], "potion_glass_poison", Vector3(-7.998, 4.937, -10.437), Vector3(0, 0, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["id"], "potion_glass_stamina", Vector3(-2.561, 4.937, 9.187), Vector3(0, 0, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["id"], "potion_glass_heal", Vector3(-42.622, 41.035, 0.898), Vector3(0, 0, 0), Vector3(0, 0, 0))
		
	await get_tree().process_frame
	
	# Inicia a sincronização de objetos
	network_manager.start_round_sync(round_data["id"], 0.04)
	
	await get_tree().process_frame
	
	# Se não headless, joga este primeiro round para a camera do servidor
	if not is_headless:
		var rounds_count = round_registry.get_active_rounds_count()
		if rounds_count == 1:
			await get_tree().process_frame
			_find_a_next_round_to_camera(round_data["id"])
	
	# termina de carregar o round
	is_loading = false


# ===== INSTANCIAÇÃO NO SERVIDOR =====

## Instancia a rodada no servidor (mapa e players)
## Chamado após enviar comando para clientes carregarem
func _server_instantiate_round(match_data: Dictionary, players_node):
	_log_debug("Instanciando rodada no servidor...")
	
	# Aplica configurações de mapa
	await map_manager.apply_map_configs(match_data["settings"])
	var terrain = round_registry.get_round(match_data["round_id"])["map_node"]
	var terrain_3d = terrain.get_node_or_null("Terrain3D")
		
	await get_tree().process_frame
	
	# Salva referência no ServerRoundRegistry
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = map_manager
		
	await get_tree().process_frame
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["settings"]["spawn_points"][player_data["uuid_base"]]
		_spawn_player_on_server(player_data, spawn_data, players_node)
		
	await get_tree().process_frame
	
	# Se for o primeiro round, esta é a câmera atual
	if match_data["round_id"] != 1 and not is_headless:
		actual_camera.current = false
		
	await get_tree().process_frame
	
	# Configura o Terrain3D para usar actual_camera
	if terrain_3d:
		_log_debug("Terrain_3d encontrado neste mapa, configurando câmera")
		terrain_3d.set_camera(actual_camera)
		# Ativa o physics_process após atribuir a câmera
		terrain_3d.set_physics_process(true)

## Spawna um jogador no servidor (versão autoritativa)
## Registra node e inicializa estado para validação
## Com controle assíncrono e timeouts de segurança
func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary, players_node):
	# VALIDAÇÕES INICIAIS
	if not player_data.has("uuid_base") or not player_data.has("name") or not player_data.has("peer_id"):
		push_error("TestManager: player_data inválido: faltam campos obrigatórios")
		return

	var p_uuid = player_data["uuid_base"]
	var player_name = player_data["name"]
	var peer_id = player_data["peer_id"]
	
	_log_debug("🔄 [SPAWN] Iniciando spawn: %s (Session: %s, UUID: %s)" % [player_name, peer_id, p_uuid])
	
	# CARREGAMENTO DA CENA
	_log_debug("📦 [SPAWN] Carregando cena do player: %s" % player_scene)
	
	var player_scene_: PackedScene = preload(player_scene)
	if not player_scene_:
		push_error("TestManager: Falha ao carregar player_scene: %s" % player_scene)
		return
	
	# INSTANCIAÇÃO
	var player_instance = player_scene_.instantiate()
	if not player_instance:
		push_error("TestManager: Falha ao instanciar player_scene")
		return
	
	_log_debug("✓ [SPAWN] Cena instanciada com sucesso")
	
	# CONFIGURAÇÕES PRÉ-ÁRVORE
	# Configurações que podem ser feitas antes de adicionar à árvore
	player_instance.add_to_group("remote_player")
	player_instance.add_to_group("player")
	
	_log_debug("⚙️ [SPAWN] Configurações básicas aplicadas")
	
	# ADIÇÃO À ÁRVORE DE CENA
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
	
	# INJEÇÃO DE DEPENDÊNCIAS
	_log_debug("💉 [SPAWN] Injetando dependências...")
	
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.server_manager = self
	player_instance.initializer = initializer
	
	# Aguarda processamento das dependências
	await get_tree().process_frame
	
	# AGUARDA READY COM TIMEOUT
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
	
	# INICIALIZAÇÃO DO JOGADOR
	_log_debug("🔧 [SPAWN] Inicializando dados do player...")
	
	var color: Color = Color(0.0, 0.0, 0.0, 1.0)
	var final_color = player_data["character"]["color"] if player_data["character"]["color"] else color
	
	player_instance.initialize(
		true, # is_server
		false, # is_local_player
		player_data["name"], 
		final_color, 
		peer_id, 
		p_uuid, 
	)
	
	# Posiciona
	player_instance.positionate(spawn_data["position"], spawn_data["rotation"])
	
	# Aguarda processamento da inicialização
	await get_tree().process_frame
	
	# CONFIGURAÇÕES DO MAPA
	_log_debug("🗺️ [SPAWN] Configurando referências do mapa...")
	
	player_instance.terrain_ = map_manager.current_map
	if player_instance.terrain_:
		player_instance.central_spawn = player_instance.terrain_.get_node_or_null("central_spawn")
		_log_debug("  - Terrain: %s" % ("✓" if player_instance.terrain_ else "✗"))
		_log_debug("  - Central Spawn: %s" % ("✓" if player_instance.central_spawn else "✗"))
	else:
		push_warning("⚠️ [SPAWN] MapManager não tem mapa carregado!")
	
	await get_tree().process_frame
	
	# REGISTRO NO CLIENT REGISTRY
	_log_debug("📝 [SPAWN] Registrando no ServerClientRegistry...")
	
	client_registry.register_player_node(p_uuid, player_instance)
	
	await get_tree().process_frame
	
	# REGISTRO NO ROUND REGISTRY
	_log_debug("📝 [SPAWN] Registrando no ServerRoundRegistry...")
	
	var p_round = round_registry.get_round_by_player_uuid(p_uuid)
	if p_round.is_empty():
		push_warning("⚠️ [SPAWN] Rodada não encontrada para player %s, usando fallback" % p_uuid)
		round_registry.register_spawned_player(1, p_uuid, player_instance)  # Fallback para round 1
	else:
		round_registry.register_spawned_player(p_round["id"], p_uuid, player_instance)
		_log_debug("  - Round ID: %s" % p_round["id"])
	
	await get_tree().process_frame
	
	# INICIALIZA ESTADO PARA VALIDAÇÃO ANTI-CHEAT
	_log_debug("🛡️ [SPAWN] Inicializando estado de validação...")
	
	player_states[p_uuid] = {
		"pos": spawn_data["position"],
		"vel": Vector3.ZERO,
		"rot": spawn_data["rotation"],
		"timestamp": Time.get_ticks_msec()
	}
	
	# VALIDAÇÃO FINAL
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
	var room = room_registry.get_room(room_id)
	var text = "Agora você é o host dessa sala: %s" % room["name"]
	var player_ = client_registry.get_player_by_uuid(new_host_uuid)
	
	if not _is_peer_connected(player_["peer_id"]):
		return
	_log_debug("_client_receive_message", true)
	network_manager._client_receive_message.rpc_id(player_["peer_id"], text, 6, "info")

## Callback quando uma rodada está terminando
## Aguarda tempo de transição antes de finalizar completamente
func _on_round_ending(round_id: int, reason: String):
	_log_debug("Rodada %d finalizando. Razão: %s" % [round_id, reason])
	
	# Aguarda tempo de transição (para mostrar resultados)
	await get_tree().create_timer(round_transition_time).timeout
	
	# Para totalmente o sync de objetos para este round:
	network_manager.stop_round_sync(round_id)
	
	# Limpa os objetos do round
	object_manager.clear_round_objects(round_id)
		
	await get_tree().process_frame
	
	# Remove o nó deste round da lista de rounds do servidor
	var round_ = round_registry.get_round(round_id)
	all_rounds_node.remove_child(round_["round_node"])
		
	await get_tree().process_frame
	
	# Finaliza completamente a rodada
	_complete_round_end(round_id)

## Completa o fim da rodada e retorna players à sala
## ORDEM:
##  1. Adiciona ao histórico da sala
##  2. Limpa objetos da cena
##  3. Finaliza no ServerRoundRegistry
##  4. Marca sala como fora de jogo
##  5. Notifica clientes para voltar ao lobby
func _complete_round_end(round_id: int):
	var round_data = round_registry.get_round(round_id)
	
	if round_data.is_empty():
		_log_debug("⚠ Tentou finalizar rodada inexistente: %d" % round_id)
		return
	
	var room_id = round_data["room_id"]
	
	# LOG DE FINALIZAÇÃO
	_log_debug("========================================")
	_log_debug("RODADA FINALIZADA COMPLETAMENTE")
	_log_debug("Rodada ID: %d" % round_data["id"])
	_log_debug("Duração: %.1f segundos" % round_data["duration"])
	
	if not round_data["winner"].is_empty():
		_log_debug("Vencedor: %s (Score: %d)" % [
			round_data["winner"]["name"],
			round_data["winner"]["score"]
		])
	
	_log_debug("========================================")
	
	# Finaliza completamente no ServerRoundRegistry
	# IMPORTANTE: Isso adiciona ao histórico da sala automaticamente e já executa _cleanup_round
	round_registry.complete_round_end(round_id)
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room_id, false)
		
	await get_tree().process_frame
	
	# Notifica clientes para voltar à sala
	var room = room_registry.get_room(room_id)
	if not room.is_empty():
		for player in room["players"]:
			var player_peer_id = client_registry.get_peer_id_by_uuid(player["uuid_base"])
			if _is_peer_connected(player_peer_id):
				_log_debug("_client_return_to_room", true)
				network_manager.rpc_id(player_peer_id, "_client_return_to_room", room)
		
	await get_tree().process_frame
	
	var active_count = round_registry.get_active_rounds_count()

	if active_count == 0:
		current_cam_round_index = -1
		if viewport_display:
			viewport_display.visible = false
		if warning_overlay:
			warning_overlay.show_message("Não há rounds ativos")
		return

	if not is_headless and current_cam_round_index == round_id:
		_find_a_next_round_to_camera()
	
	# Atualiza lista de salas (sala volta a ficar disponível)
	_send_rooms_list_to_all()


# ===== VALIDAÇÃO ANTI-CHEAT =====

## Anticheat básico, validações de movimentos do personagem do cliente
func _validate_player_movement(
		_player_node: CharacterBody3D,
		p_uuid: String,
		pos: Vector3,
		vel: Vector3,
		rot: Vector3 = Vector3.ZERO
) -> String:
	# Se anti-cheat desativado, sempre aceita
	if not enable_anticheat:
		return "pass"

	# Primeira sincronização: sem estado anterior, apenas registra e aceita
	if not player_states.has(p_uuid):
		player_states[p_uuid] = {
			"pos": pos,
			"vel": vel,
			"rot": rot,
			"timestamp": Time.get_ticks_msec()
		}
		return "pass"

	var last_state: Dictionary = player_states[p_uuid]
	var current_time: int = Time.get_ticks_msec()
	var time_diff: float = (current_time - last_state["timestamp"]) / 1000.0

	if time_diff < min_diff:
		return "pass"

	var distance: float = pos.distance_to(last_state["pos"])

	# VALIDAÇÃO 1: Distância máxima permitida no intervalo de tempo
	# Se o jogador "pulou" mais do que poderia andar no tempo decorrido → teleporte
	var max_distance: float = max_player_speed * time_diff * speed_tolerance

	if distance > max_distance:
		_log_debug("⚠️ ANTI-CHEAT: Distância suspeita")
		_log_debug("Player: %s" % p_uuid)
		_log_debug("Distância: %.2f m em %.3f s" % [distance, time_diff])
		_log_debug("Máximo permitido: %.2f m" % max_distance)
		_log_debug("Vel. efetiva: %.2f m/s (máx: %.2f m/s)" % [
			distance / time_diff,
			max_player_speed * speed_tolerance
		])
		return "distance"

	# VALIDAÇÃO 2: Velocidade reportada vs máxima permitida
	# O cliente informa sua própria velocidade; verificamos se é fisicamente possível
	var reported_speed: float = vel.length()

	if reported_speed > max_player_speed * speed_tolerance:
		_log_debug("⚠️ ANTI-CHEAT: Velocidade reportada suspeita")
		_log_debug("Player: %s" % p_uuid)
		_log_debug("Reportada: %.2f m/s" % reported_speed)
		_log_debug("Máximo: %.2f m/s" % (max_player_speed * speed_tolerance))
		return "max_speed"

	# VALIDAÇÃO 3: Discrepância entre velocidade real (calculada) e reportada
	# Apenas loga — não rejeita, pois lag legítimo pode causar discrepância
	var actual_speed: float = distance / time_diff

	if abs(actual_speed - reported_speed) > max_player_speed * 0.5:
		_log_debug("⚠️ ANTI-CHEAT: Discrepância de velocidade (possível lag)")
		_log_debug("Player: %s" % p_uuid)
		_log_debug("Real: %.2f m/s | Reportada: %.2f m/s" % [actual_speed, reported_speed])
		
	return "pass"


# ===== SINCRONIZAÇÃO =====

## Aplica estado do personagem do cliente no servidor, após validações
func _apply_player_state_on_server(
		p_id: int,
		pos: Vector3,
		rot: Vector3,
		vel: Vector3,
		running: bool,
		jumping: bool
) -> void:
	var player_uuid: String = client_registry.get_uuid_by_peer_id(p_id)
	if not player_uuid:
		return

	var player_node: CharacterBody3D = client_registry.get_player_node(player_uuid)
	if not (player_node and player_node.is_inside_tree()):
		return

	# Executa validação ANTES de qualquer modificação no nó
	var result: String = _validate_player_movement(player_node, player_uuid, pos, vel, rot)

	# Caso 1: Teleporte detectado
	# Reenvia ao cliente a posição do último estado válido no servidor
	if result == "distance":
		if _is_peer_connected(p_id):
			network_manager._correct_player_position(p_id, player_states[player_uuid]["pos"])
		return

	if result == "max_speed":
		var safe_vel: Vector3 = Vector3.ZERO
		if player_states.has(player_uuid):
			safe_vel = player_states[player_uuid]["vel"]

		player_node.global_position = pos
		player_node.global_rotation = rot
		player_node.is_running = running
		player_node.is_jumping = jumping
		player_node.velocity = safe_vel  # Velocidade hackeada descartada

		# Registra estado com velocidade segura para a próxima validação
		player_states[player_uuid] = {
			"pos": pos,
			"rot": rot,
			"vel": safe_vel,
			"running": running,
			"jumping": jumping,
			"timestamp": Time.get_ticks_msec()
		}
		return

	# Caso normal ("pass"): aplica tudo como recebido
	player_node.global_position = pos
	player_node.global_rotation = rot
	player_node.is_running = running
	player_node.is_jumping = jumping
	player_node.velocity = vel

	# Atualiza estado para a próxima rodada de validação
	player_states[player_uuid] = {
		"pos": pos,
		"rot": rot,
		"vel": vel,
		"running": running,
		"jumping": jumping,
		"timestamp": Time.get_ticks_msec()
	}

## Aplica estado de animações do personagem do cliente no servidor
func _apply_animation_state_on_server(p_id: int, speed: float, attacking: bool, defending: bool,
									jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
										
	var player_uuid = client_registry.get_uuid_by_peer_id(p_id)
	#var player = client_registry.get_player(player_uuid)
	var node = client_registry.get_player_node(player_uuid)
	if not (node and node.is_inside_tree()):
		return
		
	if node and node.has_method("_character_receive_animation_state"):
		node._character_receive_animation_state(speed, attacking, defending, jumping,
											   aiming, running, block_attacking, on_floor)

## Envia comando de despawn para clientes
## Chamado pelo ServerObjectManager.despawn_object()
func _rpc_despawn_on_clients(player_ids: Array, round_id: int, object_id: int):
	if not multiplayer.is_server():
		return
	
	# Envia RPC para cada cliente
	for player_id in player_ids:
		var player_peer_id = client_registry.get_peer_id_by_uuid(player_id)
		_log_debug("_client_despawn_item", true)
		network_manager._client_despawn_item.rpc_id(player_peer_id, object_id, round_id)


# ===== VALIDAÇÃO DE ITENS =====

## Servidor recebe pedido de pegar item para o inventário, valida e redistribui
func _server_validate_pick_up_item(requesting_player_id: int, object_id: int):
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var round_id = client_registry.get_player_round(player_uuid)
	var object = object_manager.get_object_node(round_id ,object_id)
	
	# Verificação se item é válido (é um objeto spawnado corretamente / tem os atributos adicionado pelo objeta manager)
	if not object:
		return
	
	var player_node = client_registry.get_player_node(player_uuid)
	var server_nearby = player_node.get_nearby_items()
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	var item = item_database.get_item(object["item_name"]).to_dictionary()
	var round_players = round_registry.get_active_players_uuids(round_["id"])
	
	_log_debug("[ITEM] Player %s pediu para pegar item %d(%s), no round %d" % [player["name"], object_id, object["item_name"], round_["id"]])
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	# Verificação se o item está perto do player na cena do servidor também
	if not server_nearby.has(object):
		_log_debug("O nó deste player no servidor não tem este item por perto para pickup, recusar!")
		return
	
	# Verifica se o item que o player enviou é o mesmo que o server detectou
	if object_id != server_nearby[0].object_id:
		return
	
	# Se for item equipável de knight
	if not item_database.get_items_by_owner("knight"):
		return
	
	# Verifica se tem espaço no inventário
	if client_registry.is_inventory_full(round_["id"], player_uuid):
		_log_debug("Impossível pegar item, inventário cheio!")
		return
		
	await get_tree().process_frame
	
	client_registry.add_item_to_inventory(round_["id"], player_uuid, item["id"], object_id)
	
	# Despawn do objeto no mapa dos clientes
	_rpc_despawn_on_clients(round_players, round_["id"], object_id)
		
	await get_tree().process_frame
	
	# Define objeto armazenado / sai do spawned objects
	object_manager.store_object(round_["id"], object_id, player_uuid)
	
	# Executa animação no personagem remoto do servidor e nos clientes
	for peer_id in round_players:
		var player_peer_id = client_registry.get_peer_id_by_uuid(peer_id)
		_log_debug("_client_apply_pick_up", true)
		network_manager._client_apply_pick_up.rpc_id(player_peer_id, requesting_player_id)
		
	await get_tree().process_frame
	
	# Executa animação no nó do servidor tbm
	if player_node and player_node.has_method("action_pick_up_item"):
		player_node.action_pick_up_item()
	
	# Se o slot deste item estiver vazio, equipar este item lá automaticamente \/
	if not client_registry.is_slot_empty(round_["id"], player_uuid, item["type"]):
		return
	
	# Se auto equip false, não equipar automaticamente
	if not item_database.get_item(item["name"]).is_auto_equip_function():
		return
		
	await get_tree().process_frame
	
	# Equipa o item no registro do player
	client_registry.equip_item(round_["id"], player_uuid, item["name"], object_id)
	
	_log_debug("[ITEM]📦 Slot deste item está vazio, equipando automaticamente: Player %d equipou item %d" % [requesting_player_id, item["id"]])
	
	# Envia para todos os clientes do round (para atualizar visual)
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["id"])
	for peer in filtered_:
		if _is_peer_connected(peer["peer_id"]):
			_log_debug("_client_apply_equip", true)
			network_manager.rpc_id(peer["peer_id"], "_client_apply_equip", requesting_player_id, item["id"])
		
	await get_tree().process_frame
	
	# Aplica visual tbm na cena do servidor
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(item["id"])

## Servidor recebe pedido de equipar item, valida e redistribui
func _server_validate_equip_item(requesting_player_id: int, object_id: int, _target_slot_type):
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	var item_id = item_database.get_item(object_manager.get_stored_object_item_name(round_["id"] ,object_id))["id"]
	# De vez em quando dá um erro aqui nessa linha! /\
	var item = item_database.get_item_by_id(item_id)
	#var item_slot = item.get_slot()
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	_log_debug("[ITEM]📦 Player %s pediu para equipar item %d no slot %s, no round %d" % [player["name"], item_id, item["type"], round_["id"]])
	
	# Verifica se o id do item é válido
	if not item:
		return
	
	# Verifica se o slot está vazio no inventário do player
	if not client_registry.is_slot_empty(round_["id"], player_uuid, _target_slot_type):
		push_warning("[ITEM]O Slot já está ocupado por outro item, pedido de equipamento cancelado pelo servidor")
		return
		
	await get_tree().process_frame
	
	# Equipa o item no registro do player
	client_registry.equip_item(round_["id"], player_uuid, item["name"], object_id)
	
	_log_debug("✓ Item equipado: %s em %s (Player %s, Rodada %d)" % [item["name"], item["type"], player_uuid, round_["id"]])
	
	# Envia para todos os clientes do round (para atualizar visual)
		
	await get_tree().process_frame
	
	# Para cada player neste round
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["id"])
	for f_player in filtered_:
		var session_id = client_registry.get_peer_id_by_uuid(f_player["uuid_base"])
		if _is_peer_connected(session_id):
			_log_debug("_client_apply_equip", true)
			network_manager.rpc_id(session_id, "_client_apply_equip", requesting_player_id, item_id, false, true)
		
	await get_tree().process_frame
	
	# Aplica visual tbm na cena do servidor
	var player_node = client_registry.get_player_node(player_uuid)
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(item_id, false, true)
			
## Servidor recebe pedido de desequipar item, valida e redistribui
func _server_validate_unequip_item(requesting_player_id: int, slot_type: String):
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	var item_ = client_registry.get_equipped_item_in_slot(round_["id"], player_uuid, slot_type)
	
	if not item_:
		return
		
	var item_id = item_["item_id"]
	var item = item_database.get_item_by_id(int(item_id))
	var item_slot = item.get_slot()
	
	_log_debug("[ITEM]📦 Player %s pediu para desequipar item %d no slot %s, no round %d" % [player["name"], item["id"], item["type"], round_["id"]])
		
	await get_tree().process_frame
	
	# Verificação se o player está conectado
	if not _is_peer_connected(requesting_player_id):
		return
	
	# Verificar se o slot_type recebido é válido
	if not item_:
		return
	
	client_registry.unequip_item(round_["id"], player_uuid, item_slot)
	
	_log_debug("✓ Item desequipado: %s de %s (Player %s, Rodada %d)" % [item["name"], item["type"], player_uuid, round_["id"]])
		
	await get_tree().process_frame
	
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["id"])
	for f_player in filtered_:
		var player_peer_id = client_registry.get_peer_id_by_uuid(f_player["uuid_base"])
		if _is_peer_connected(player_peer_id):
			_log_debug("_client_apply_equip", true)
			network_manager.rpc_id(player_peer_id, "_client_apply_equip", requesting_player_id, int(item_id), true, true)
		
	await get_tree().process_frame
	
	# Aplica na cena do servidor (atualizar visual)
	var player_node = client_registry.get_player_node(player_uuid)
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(item_id, true, true)

## Processa troca entre inventário e equipamento.
## NOTA IMPORTANTE: Esta função SEMPRE chama swap_equipped_item com:
##  - O item do INVENTÁRIO como primeiro item (será equipado)
##  - O item EQUIPADO como segundo item (será substituído)
## Para isso, inverte os IDs se necessário, garantindo que a lógica do servidor
## sempre receba os parâmetros na ordem correta.
func _server_validate_swap_items(peer_id: int, dragged_item_id: int, target_item_id: int):
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	#var player = client_registry.get_player(player_uuid)
	var round_id: int = client_registry.get_player_round(player_uuid)
	var round_data = round_registry.get_round(round_id)
		
	await get_tree().process_frame
	
	# Verifica se o player tem pelo menos um destes itens equipado
	var dragged_equipped := client_registry.is_item_equipped(round_id, player_uuid, dragged_item_id)
	var target_equipped := client_registry.is_item_equipped(round_id, player_uuid, target_item_id)
	
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
	var inventory_item_id: int
	var equipped_item_id: int
	
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
		equipped_item_id,    # ID do item equipado (será substituído)
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
	var player_node = client_registry.get_player_node(player_uuid)
	if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
		player_node.apply_visual_equip_on_player_node(item_data["id"])
	# Ações diversas relacionadas a swap de itens sincronizadas para os remotes e clientes
	if player_node and player_node.has_method("execute_item_swap"):
		player_node.execute_item_swap()
			
	await get_tree().process_frame
	
	# Clientes:
	# _client_apply_equip executa ambas: apply_visual_equip_on_player_node e execute_item_swap
	for player in round_data["players"]:
		var player_peer_id = client_registry.get_peer_id_by_uuid(player["uuid_base"])
		if _is_peer_connected(player_peer_id):
			_log_debug("_client_apply_equip", true)
			network_manager.rpc_id(player_peer_id, "_client_apply_equip", peer_id, item_data["id"], false, false, true)
	
## Servidor recebe pedido de spawnar item na frente do player para testes
func _server_trainer_spawn_item(requesting_peer_id: int, item_id: int):
	if not test_trainer:
		return
	
	# Não quero o shield_3, quero a tocha
	if item_id == 9:
		item_id = 10
	
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_peer_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	_log_debug("[ITEM]📦 Player %s: Trainer pediu para spawnar item %d na sua frente, no round %d" % [player["name"], item_id, round_["id"]])
	
	# Verifica se o id do item é válido
	if not item_database.get_item_by_id(item_id):
		return
		
	await get_tree().process_frame
	
	var objects_node = round_["round_node"].get_node_or_null("Objects")
	var item_name = item_database.get_item_by_id(item_id)
	# ServerObjectManager cuida de spawnar E enviar RPC
	object_manager.spawn_item_over_of_player(objects_node, round_["id"], player_uuid, item_name["name"])

## Servidor recebe pedido de drop, valida e spawna item executando drop_item()
## IMPORTANTE: USA ESTADO DO SERVIDOR, não do cliente
func _server_validate_drop_item(requesting_player_id: int, obj_id: int):
	# Na hora do drop, se tiver um item equipado e for o item dropado, desequipar e dropar, se não for o mesmo, apenas dropar
	# Se não tiver nenhum item equipado, apenas dropar se tiver no inventário
	
	var player_uuid = client_registry.get_uuid_by_peer_id(requesting_player_id)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	
	# Validação 1:
	if not player_states.has(player_uuid):
		push_warning("[ServerManager]: Player %d não tem estado registrado" % requesting_player_id)
		return
		
	# Validação 2:
	if round_registry.get_round_state(round_["id"]) != "playing":
		push_warning("[ServerManager]: Round inválido, não está em partida")
		return
	
	# Validação 3:
	if not object_manager.stored_object_exists(round_["id"], obj_id):
		push_warning("[ServerManager]: Objeto inválido, não existe no ServerObjectManager stored_objects do player")
		return
	
	var is_item_equipped = client_registry.is_item_equipped(round_["id"], player_uuid, obj_id)
	var object_item_name = object_manager.get_stored_object_item_name(round_["id"], obj_id)
	var item_ = item_database.get_item(object_item_name).to_dictionary()
	var item_slot = item_database.get_slot(object_item_name)
	var item_id = 0
		
	await get_tree().process_frame
	
	# Se o item estiver equipado
	if is_item_equipped:
		var equiped_obj_id = client_registry.get_equipped_item_in_slot(round_["id"], player_uuid, item_slot)["object_id"]
			
		# Pega o id do item para esconder no player
		item_id = int(client_registry.get_equipped_item_in_slot(round_["id"], player_uuid, item_slot)["item_id"])
		
		# Verificar se o item dropado é o mesmo item que está equipado, se sim, pedir para desequipar
		if int(equiped_obj_id) == int(obj_id):
			client_registry.unequip_item(round_["id"], player_uuid, item_slot, false)
		
		# Aplica no nó do servidor
		var player_node = client_registry.get_player_node(player_uuid)
		if player_node and player_node.has_method("apply_visual_equip_on_player_node"):
			player_node.apply_visual_equip_on_player_node(item_id, true)
		
		# Aplicar nos players remotos dos clientes
		var filtered_ = round_registry.get_round_players_spawned_filter(round_["id"])
		for f_player in filtered_:
			var session_id = client_registry.get_peer_id_by_uuid(f_player["uuid_base"])
			if _is_peer_connected(session_id):
				_log_debug("_client_apply_equip", true)
				network_manager.rpc_id(session_id, "_client_apply_equip", requesting_player_id, int(item_id), true)
	
	_log_debug("[ITEM]📦 Servidor vai validar pedido de drop de item ObjId: %d tipo %s do player ID %s" % [obj_id, item_["name"], requesting_player_id])
		
	await get_tree().process_frame
	
	# Validação 4:
	if not item_database.get_item_by_id(item_id) and item_id != 0:
		push_warning("[ServerManager]: ID de item inválido recebido: %d" % item_id)
		return
	
	# Se o player não tiver nenhum item no próprio inventário para dropar, não faz nada
	var has_any = client_registry.has_any_item(round_["id"], player_uuid)
	_log_debug("Player tem algum item para dropar?: %s" % has_any)
	if not has_any:
		push_warning("[ServerManager]: Player não tem nenhum item no inentário para dropar")
		return
		
	_log_debug("[ITEM]📦 Pedido válido! Executando drop de item ObjId: %d tipo %s do player ID %s" % [obj_id, item_["name"], requesting_player_id])
		
	await get_tree().process_frame
	
	# Executar drop (o item deve estar no inventário do player / já verificado acima) \/
	# Pegar o item_id do objeto referido
	var player_invent_items = client_registry.get_inventory_items(round_["id"], player_uuid)
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
		object_manager.retrieve_stored_object(objects_node, round_["id"], obj_id, spawn_pos, Vector3(0, 0, 0,), player_uuid)
		
		# Remove item do inentário do player
		client_registry.remove_item_from_inventory(round_["id"], player_uuid, obj_id)
		
		# Executa ações referentes a isso no player no servidor e em seus remotos nos clientes
		var round_players = client_registry.get_players_in_round(round_["id"])
		for peer_id in round_players:
			var session_id = client_registry.get_peer_id_by_uuid(peer_id)
			if _is_peer_connected(session_id):
				_log_debug("_client_apply_drop", true)
				network_manager._client_apply_drop.rpc_id(session_id, requesting_player_id, item_data["name"])
			
		await get_tree().process_frame
	
		# Aplica no nó do servidor
		var player_node = client_registry.get_player_node(player_uuid)
		if player_node and player_node.has_method("execute_item_drop"):
			player_node.execute_item_drop()


# ===== TRAINER DE TESTE =====

## Servidor recebe pedido de dropar item do inventário(apenas do inventário) na frente do player para testes
func _server_trainer_drop_item(peer_id):
	
	if not test_trainer:
		return
		
	_log_debug('Cliente pediu pra dropar um item usando o trainer. test_trainer: %s' % test_trainer)
	
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	
	# Se o player não tiver nenhum item no inventário para dropar, não faz nada
	var has_any = client_registry.has_any_item(round_["id"], player_uuid)
	_log_debug("Player tem algum item para dropar?: %s" % has_any)
	if not has_any:
		return
	
	#var player = client_registry.get_player(player_id)
	#var item_name = item_database.get_item_by_id(item_id)["name"]
	#var players_node = round_["round_node"].get_node_or_null("Players")
	var obj_id = client_registry.get_inventory_items(round_["id"], player_uuid)[0]["object_id"]
	var item_id = int(client_registry.get_inventory_items(round_["id"], player_uuid)[0]["item_id"])

	var objects_node = round_["round_node"].get_node_or_null("Objects")
		
	await get_tree().process_frame
	
	# Remover o item do registro do player
	client_registry.remove_item_from_inventory(round_["id"], player_uuid, obj_id)
	
	var item_data = item_database.get_item_by_id(item_id)
	if item_data:
		var player_state = player_states[player_uuid]
		var player_pos = player_state["pos"]
		var player_rot = player_state["rot"]
		var spawn_pos = object_manager._calculate_front_position(player_pos, player_rot)
			
		# Retomar o nó do item de volta à cena no object manager
		object_manager.retrieve_stored_object(objects_node, round_["id"], obj_id, spawn_pos, Vector3(0, 0, 0,), player_uuid)
		client_registry.remove_item_from_inventory(round_["id"], player_uuid, obj_id)
		
## Servidor recebe pedido de respawnar player para testes
func _server_trainer_repawn_player(peer_id, player_uuid):
	
	# Só passar se estiver com trainer ligado
	if not test_trainer:
		return
	
	var player = client_registry.get_player(player_uuid)
	_log_debug("%s pediu para spawnar novamente. Test trainer: %s" % [player["name"], test_trainer])
	
	var round_id: int = client_registry.get_player_round(player_uuid)
	var round_ = round_registry.get_round(round_id)
	var round_data = round_registry.get_round(round_id)
	
	var players_node = round_data["round_node"].get_node_or_null("Players")
	if not players_node:
		return
		
	await get_tree().process_frame
	
	
	# Aplica na cena de player do servidor
	var player_node = client_registry.get_player_node(player_uuid)
	if player_node and player_node.has_method("_respawn_player"):
		player_node._respawn_player(map_manager.spawn_center)
		
	await get_tree().process_frame
	
	# Atuliza nova posição no player_states
	if player_states.has(player_uuid):
		player_states[player_uuid] = {
		"pos": map_manager.spawn_center,
		"vel": player_node.velocity,
		"rot": player_node.rotation,
		"timestamp": Time.get_ticks_msec()
	}
	
	# Aplica nas cenas do players remotos
	var filtered_ = round_registry.get_round_players_spawned_filter(round_["id"])
	for f_player in filtered_:
		var f_peer_id = client_registry.get_peer_id_by_uuid(f_player["uuid_base"])
		if _is_peer_connected(peer_id):
			_log_debug("_client_apply_respawn", true)
			network_manager.rpc_id(f_peer_id, "_client_apply_respawn", peer_id, map_manager.spawn_center)
			
			
# ===== VALIDAÇÕES DE AÇÕES DO PLAYER =====

# Validações e execução de ataque do personagem
func attack_validation(target_group: String, peer_id: int, actual_weapon: String, victim_peer_id: int):
	# Se alvo for um player remoto
	if target_group == "remote_player":
		var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
		var player = client_registry.get_player(player_uuid)
		var round_ = round_registry.get_round_by_player_uuid(player_uuid)
		var round_players = client_registry.get_players_in_round(round_["id"])
		var victim_uuid = client_registry.get_uuid_by_peer_id(victim_peer_id)
		
		for peer_uuid in round_players:
			var r_peer_id = client_registry.get_peer_id_by_uuid(peer_uuid)
			_log_debug("_client_receive_attack", true)
			network_manager._client_receive_attack.rpc_id(r_peer_id, victim_peer_id)
			
		await get_tree().process_frame
	
		# Aplica no nó do servidor
		var player_node = client_registry.get_player_node(victim_uuid)
		if player_node and player_node.has_method("take_damage"):
			player_node.take_damage()
		
		_log_debug("Ataque executado!: %s, %s com um(a) %s em %d" % [target_group, player["name"], actual_weapon,  victim_peer_id])

## RPC: Servidor recebe ação do jogador e redistribui para os remotos do mesmo round e remoto 
## corresondente no servidor também
func _server_player_action(peer_id: int, action_type: String, item_equipado_nome, anim_name: String):
	var player_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var player = client_registry.get_player(player_uuid)
	var round_ = round_registry.get_round_by_player_uuid(player_uuid)
	var players_round = round_registry.get_active_players_uuids(round_["id"])
	
	# Ignora o próprio player
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != peer_id:
		return
	
	var has_weapon = client_registry.has_weapon_equipped(round_["id"], player_uuid)
	# Se for um ataque
	if action_type == "attack":
		# Servidor verifica se o player tem uma arma equipada
		if not has_weapon:
			return
		_log_debug("%s tem uma arma equipada: %s" % [player["name"], has_weapon])
			
	# Se for um ataque com escudo:
	elif action_type == "block_attack":
		# Servidor verifica se o player tem uma escudo equipado
		if not client_registry.has_shield_equipped(round_["id"], player_uuid):
			return
		_log_debug("%s tem um escudo equipado: %s" % [player["name"], has_weapon])
	
	# Se for um pedido de iniciar defesa com escudo
	elif action_type == "defend_start":
		# Servidor verifica se o player tem uma escudo equipado
		if not client_registry.has_shield_equipped(round_["id"], player_uuid):
			return
	
	# Propaga pra todos os outros clientes (Reliable = Garantido)
	for peer_uuid in players_round:
		if peer_uuid != player_uuid:
			var r_peer_id = client_registry.get_peer_id_by_uuid(peer_uuid)
			_log_debug("_client_player_action", true)
			network_manager._client_player_action.rpc_id(r_peer_id, peer_id, action_type, item_equipado_nome, anim_name)

			# Dica: Outra forma de chamar rpc(quando está inacessível p o server mas existe no pc remoto):
			# if has_method("_client_player_action"):
				# rpc_id(peer_id, "_client_player_action", p_id, action_type, anim_name)
		
	await get_tree().process_frame
	
	# Para defend_stop o servidor aplica sem verificações
	# Aplica no nó do servidor
	var player_node = client_registry.get_player_node(player_uuid)
	if player_node and player_node.has_method("_character_receive_action"):
		player_node._character_receive_action(action_type, item_equipado_nome, anim_name)


# ===== UTILITÁRIOS =====

## Calcula posição na frente e acima do player
##  @param pos: Posição do player
##  @param rot: Rotação do player (Euler angles)
##  @param dist: Distância na frente (positivo = frente)
##  @param height: Altura acima do player
func _get_position_front_and_above(pos: Vector3, rot: Vector3, dist: float = 1.5, height: float = 1.2) -> Vector3:
	var basis = Basis.from_euler(rot)
	var forward: Vector3 = basis.z  # -Z é frente no Godot
	return pos + forward * dist + Vector3.UP * height

## Desliga servidor completamente e limpa todos os recursos
## Obs: Se o servidor não fechar, provalvelmente tem algum erro no caminho até aqui
## (testar com o headless e não headless).
func shutdown_server():
	_log_debug("========================================")
	_log_debug("DESLIGANDO SERVIDOR")
	_log_debug("========================================")
	
	#var text = "O servidor será fechado"
	#_log_debug("_client_receive_message", true)
	#network_manager._client_receive_message.rpc_id(peer_id, text, 6, "error")
	#await get_tree().create_timer(6).timeout
	
	# Limpa debug overlay
	if debug_overlay:
		debug_overlay.queue_free()
	
	# 🔒 Evita novas ações enquanto está desligando
	set_process(false)
	set_physics_process(false)

	# 4. Fecha o servidor de rede corretamente
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	_log_debug("✓ Servidor desligado completamente")

	# 🧨 FINALIZA O PROCESSO
	get_tree().quit()
	
	# fallback caso quit falhe (headless bug / loop preso)
	await get_tree().create_timer(0.2).timeout
	
	OS.kill(OS.get_process_id())

## Remove estado de validação do jogador
## Chamado quando desconecta
func _cleanup_player_state(peer_uuid: String):
	if player_states.has(peer_uuid):
		player_states.erase(peer_uuid)
		_log_debug("Estado de validação removido")

## Kicka um jogador do servidor (anti-cheat ou outras razões)
## Remove da rodada, sala e desconecta
func _kick_player_from_round(peer_id: int, reason: String):
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
	_player_exit_from_round(player["peer_id"], player_uuid)

## Envia mensagem de erro para um cliente
func _send_error_to_client(peer_id: int, message: String):
	var client_uuid = client_registry.get_uuid_by_peer_id(peer_id)
	var client = client_registry.get_player(client_uuid)
	_log_debug("❌ Enviando erro para cliente %s: %s" % [client["name"], message])
	if _is_peer_connected(peer_id):
		_log_debug("_client_receive_error", true)
		network_manager.rpc_id(peer_id, "_client_receive_error", message)

## Verifica se um peer ainda está conectado
func _is_peer_connected(peer_id: int) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	
	var connected_peers = multiplayer.get_peers()
	return peer_id in connected_peers

## Limpa as rounds vazios após tempo determinado desde que ficou vazio
## usa ROUND_EMPTY_TIMEOUT
func _cleanup_empty_rounds():
	var now = Time.get_unix_time_from_system()
	var all_rounds = round_registry.get_all_rounds()

	for round_id in all_rounds.keys():
		# Se round estiver vazio
		var round_ = round_registry.get_round(round_id)
		if round_registry.get_active_player_count(round_["id"]) == 0 and round_["empty_since"]:
			# Se empty_since maior que tempo determinado
			if round_.has("empty_since") and now >= round_["empty_since"] + ROUND_EMPTY_TIMEOUT:
				round_registry.end_round(round_["id"], "all_quitted")
				
				# Neste caso remove a sala também (já remove players dela tbm)
				for player in round_["players"]:
					room_registry.remove_player_from_room(round_["room_id"], player["uuid_base"])
					
func sort_num(min_val: int, max_val: int) -> int:
	return randi_range(min_val, max_val)
	
func is_shared_server() -> bool:
	return server_owner_ != ""
	
func is_server_owner(player_uuid: String) -> bool:
	return server_owner_ == player_uuid
	
# ===== DEBUG =====

## Imprime mensagem de debug se habilitado
func _log_debug(message: String, rpc_debug: bool = false):
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "Server" in initializer.selected:
		return
	
	if rpc_debug and not initializer.rpc_debug:
		return
	print("[SERVER]%s%s" % ["[RPC]" if rpc_debug else "", message])

## Debug: Imprime estados de todos os players para validação
func _print_player_states():
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
