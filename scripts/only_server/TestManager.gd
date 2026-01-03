extends Node
class_name TestManager
## TestManager - Ferramenta de desenvolvimento para testes automatizados
## 
## RESPONSABILIDADES:
## - Criar partidas de teste automaticamente
## - Registrar jogadores fictícios
## - Iniciar rodadas sem interação manual
## - Facilitar testes de funcionalidades
##
## ⚠️ IMPORTANTE: Deve ser DESATIVADO em produção!

# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS (Injetados pelo ServerManager) =====

var server_manager: ServerManager = null
var network_manager: NetworkManager = null
var item_database :ItemDatabase = null
var map_manager: MapManager = null
var player_registry: PlayerRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null

# ===== VARIÁVEIS INTERNAS =====

## Referência à câmera livre para visualização no servidor
var free_camera: Camera3D = null

# Estado de inicialização
var _initialized: bool = false

var dummy_camera: Camera3D

# ===== INICIALIZAÇÃO =====

func initialize():
	"""Inicializa o TestManager (chamado pelo ServerManager)"""
	if _initialized:
		_log_debug("⚠ TestManager já inicializado")
		return
	
	_initialized = true
	_log_debug("✓ TestManager inicializado")

# ===== CRIAÇÃO DE PARTIDA DE TESTE =====

func criar_partida_teste(nome_sala: String = "Sala de Teste", configuracoes_round: Dictionary = {}):
	"""
	Cria uma partida de teste usando os peers conectados reais
	
	FLUXO:
	1. Valida peers conectados
	2. Registra jogadores no PlayerRegistry (se necessário)
	3. Cria sala no RoomRegistry
	4. Adiciona jogadores à sala
	5. Valida requisitos para iniciar
	6. Cria rodada no RoundRegistry
	7. Gera spawn points
	8. Envia comandos aos clientes
	9. Instancia rodada no servidor
	10. Inicia rodada
	
	@param nome_sala: Nome da sala a ser criada
	@param configuracoes_round: Configurações personalizadas da rodada
	"""
	
	if not _initialized:
		_log_debug("❌ TestManager não inicializado!")
		return
	
	# Valida registries
	if not player_registry or not room_registry or not round_registry:
		_log_debug("❌ Registries não disponíveis!")
		return
	
	# Obtém peers conectados (exclui servidor - ID 1)
	var connected_peers = multiplayer.get_peers()
	connected_peers.erase(1)  # Remove servidor
	
	if connected_peers.is_empty():
		_log_debug("⚠ Nenhum cliente conectado para criar partida de teste")
		return
	
	# Limita à quantidade configurada no ServerManager
	var num_players = min(server_manager.simulador_players_qtd, connected_peers.size())
	connected_peers = connected_peers.slice(0, num_players)
	
	_log_debug("========================================")
	_log_debug("🎮 CRIANDO PARTIDA DE TESTE")
	_log_debug("Sala: '%s'" % nome_sala)
	_log_debug("Jogadores: %d" % num_players)
	_log_debug("========================================")
	
	# Registra jogadores no PlayerRegistry
	var players: Array = []
	
	for i in range(num_players):
		var peer_id = connected_peers[i]
		
		# Verifica se peer já está registrado
		var player_data = player_registry.get_player(peer_id)
		
		if player_data.is_empty() or not player_data["registered"]:
			# Adiciona peer se não existe
			if player_data.is_empty():
				player_registry.add_peer(peer_id)
			
			# Registra com nome padrão
			var player_name = "TestPlayer%d - %d" % [i + 1, peer_id]
			var success = player_registry.register_player(peer_id, player_name)
			
			if not success:
				_log_debug("❌ Falha ao registrar jogador %d" % peer_id)
				continue
			
			player_data = player_registry.get_player(peer_id)
		
		# Adiciona à lista de jogadores
		players.append({
			"id": peer_id,
			"name": player_data["name"],
			"is_host": (i == 0)  # Primeiro é o host
		})
		
		_log_debug("  ✓ Jogador registrado: %s (ID: %d)" % [player_data["name"], peer_id])
	
	if players.is_empty():
		_log_debug("❌ Nenhum jogador válido para criar partida")
		return
	
	# Cria sala no RoomRegistry
	var room_id = _get_next_test_room_id()
	
	var room_data = room_registry.create_room(
		room_id,
		nome_sala,
		"",  # Sem senha
		players[0]["id"],  # Host é o primeiro jogador
		server_manager.min_players_to_start,
		server_manager.max_players_per_room
	)
	
	if room_data.is_empty():
		_log_debug("❌ Falha ao criar sala!")
		return
	
	_log_debug("  ✓ Sala criada: '%s' (ID: %d)" % [nome_sala, room_id])
	
	# Adiciona outros jogadores à sala (host já foi adicionado)
	for i in range(1, players.size()):
		var success = room_registry.add_player_to_room(room_id, players[i]["id"])
		if not success:
			_log_debug("  ⚠ Falha ao adicionar jogador %s à sala" % players[i]["name"])
	
	# Valida requisitos para iniciar
	if not room_registry.can_start_match(room_id):
		var reqs = room_registry.get_match_requirements(room_id)
		_log_debug("❌ Requisitos não atendidos: %d/%d jogadores (mínimo: %d)" % [
			reqs["current_players"],
			reqs["max_players"],
			reqs["min_players"]
		])
		return
	
	if room_registry.is_room_in_game(room_id):
		_log_debug("❌ A sala já está em uma rodada")
		return
	
	# Cria rodada no RoundRegistry
	_log_debug("  ✓ Iniciando rodada de teste...")
	
	# Atualiza sala como em jogo
	room_registry.set_room_in_game(room_id, true)
	
	# Obtém dados atualizados da sala
	room_data = room_registry.get_room(room_id)
	
	# Cria rodada
	var round_data = round_registry.create_round(
		room_id,
		room_data["name"],
		room_data["players"],
		configuracoes_round
	)
	
	# Criar cena de organização do round
	var round_node = Node.new()
	round_node.name = "Round_%d_%d" % [room_data["id"], round_data["round_id"]]
	
	# Adiciona à raiz
	get_tree().root.add_child(round_node)
	
	round_registry.set_round_node(round_data["round_id"], round_node)
	
	# Cria nós organizacionais
	var players_node = Node.new()
	players_node.name = "Players"
	round_node.add_child(players_node)

	var objects_node = Node.new()
	objects_node.name = "Objects"
	round_node.add_child(objects_node)
	
	if round_data.is_empty():
		_log_debug("❌ Erro ao criar rodada")
		room_registry.set_room_in_game(room_id, false)
		return
	
	_log_debug("  ✓ Rodada criada: ID %d" % round_data["round_id"])
	
	# Gera spawn points
	var players_qtd = round_registry.get_total_players(round_data["round_id"])
	var spawn_points = server_manager._create_spawn_points(players_qtd)
	
	# Gera dados de spawn para cada jogador
	var spawn_data = {}
	for i in range(room_data["players"].size()):
		var p = room_data["players"][i]
		spawn_data[p["id"]] = {
			"spawn_index": i,
			"team": 0
		}
	
	# Atualiza settings da rodada
	var round_settings = round_data.get("settings", {})
	round_settings["round_players_count"] = players_qtd
	round_settings["spawn_points"] = spawn_points
	var map_scene = round_settings.get("map_scene", server_manager.map_scene)
	
	# Prepara dados para clientes
	var match_data = {
		"round_id": round_data["round_id"],
		"room_id": room_id,
		"map_scene": map_scene,
		"settings": round_settings,
		"players": room_data["players"],
		"spawn_data": spawn_data
	}
	
	_log_debug("  ✓ Enviando dados para clientes...")
	
	# Envia comando de início para todos os clientes
	for room_player in room_data["players"]:
		network_manager.rpc_id(room_player["id"], "_client_round_started", match_data)
	
	# Instancia rodada no servidor
	await _server_instantiate_round(match_data, players_node, round_node)
	
	# Inicia rodada (ativa timers)
	round_registry.start_round(round_data["round_id"])
	
	if server_manager.item_trainer:
		# Spawna alguns objetos
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(1, 4, 1), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "steel_helmet", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "cape_1", Vector3(2, 4, 4), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "sword_2", Vector3(2, 30, 1), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "shield_3", Vector3(0, 500, 0), Vector3(0, 0, 0))
	
	# Atualiza lista de salas para os players no menu
	server_manager._send_rooms_list_to_all()
	
	_log_debug("========================================")
	_log_debug("✓ PARTIDA DE TESTE INICIADA COM SUCESSO")
	_log_debug("  Jogadores: %d" % players_qtd)
	_log_debug("  Sala: %s (ID: %d)" % [nome_sala, room_id])
	_log_debug("  Rodada: %d" % round_data["round_id"])
	_log_debug("========================================")

# ===== INSTANCIAÇÃO NO SERVIDOR =====

func _server_instantiate_round(match_data: Dictionary, players_node, round_node):
	"""
	Instancia a rodada no servidor (mapa e players)
	Similar ao ServerManager, mas com validações extras para testes
	"""
	
	_log_debug("  Instanciando rodada no servidor...")
	
	# Carrega o mapa
	await map_manager.load_map(match_data["map_scene"], round_node, match_data["settings"])
	
	# Salva referência no RoundRegistry
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = server_manager.map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		_spawn_player_on_server(player_data, spawn_data, match_data["round_id"], players_node)
	
	# Cria câmera livre se não estiver em modo headless
	if not server_manager.is_headless:
		var debug_cam = preload(server_manager.server_camera).instantiate()
		
		players_node.add_child(debug_cam)
		debug_cam.global_position = Vector3(0, 3, 5)  # X=0, Y=10 (altura), Z=15 (distância)
	else:
		# Se estiver em modo headless criar uma câmera dummy
		dummy_camera = Camera3D.new()
		dummy_camera.name = "ServerCamera"
		add_child(dummy_camera)
		
		# Posiciona em algum lugar (não importa muito)
		dummy_camera.global_position = Vector3(0, 100, 0)
		
		# Define como câmera ativa
		dummy_camera.current = true
		
		# Aguarda um frame para garantir que tudo está inicializado
		await get_tree().process_frame
		
		var terrain_3d = round_node.get_node_or_null("Terrain3D")
		
		# Configura o Terrain3D para usar essa câmera
		if terrain_3d:
			terrain_3d.set_camera(dummy_camera)
			_log_debug("✓ is_headless = false, terrain3D configurado com câmera dummy")
	
	# Tira ui (desnecessária para o servidor)
	var ui = get_tree().root.get_node_or_null("MainMenu")
	if ui:
		ui.queue_free()
	
	_log_debug("  ✓ Rodada instanciada no servidor")

# ===== SPAWN DE JOGADORES =====

func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary, round_id: int, players_node):
	"""
	Spawna um jogador no servidor (versão autoritativa)
	
	ORDEM CRÍTICA:
	1. Valida dados
	2. Carrega e instancia cena
	3. Configura identificação
	4. Adiciona à árvore
	5. Aguarda processamento completo
	6. Valida que está na árvore
	7. Registra no PlayerRegistry
	8. Calcula posição de spawn
	9. Configura transform
	10. Inicializa player
	11. Registra no RoundRegistry
	12. Inicializa estado de validação
	"""
	
	# Validações iniciais
	if not player_data.has("id") or not player_data.has("name"):
		push_error("TestManager: player_data inválido: faltam 'id' ou 'name'")
		return
	
	var p_id = player_data["id"]
	var p_name = player_data["name"]
	
	# Carrega e instancia a cena do player
	var player_scene = preload(server_manager.player_scene)
	if not player_scene:
		push_error("TestManager: Falha ao carregar player_warrior.tscn")
		return
	
	var player_instance = player_scene.instantiate()
	if not player_instance:
		push_error("TestManager: Falha ao instanciar player_scene")
		return
	
	# Configura identificação básica
	player_instance.name = str(p_id)
	player_instance.player_id = p_id
	player_instance.player_name = p_name
	
	# IMPORTANTE: No servidor, nenhum player é "local"
	player_instance.is_local_player = false
	
	# ADICIONA À ÁRVORE PRIMEIRO
	players_node.add_child(player_instance)
	
	# Injeta dependências
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.server_manager = server_manager
	
	# configura
	player_instance._is_server = true
	
	# AGUARDA PROCESSAMENTO COMPLETO
	if not player_instance.is_node_ready():
		await player_instance.ready
	await get_tree().process_frame
	
	# VALIDA QUE ESTÁ NA ÁRVORE
	if not player_instance.is_inside_tree():
		push_error("TestManager CRÍTICO: Player %d não foi adicionado à árvore!" % p_id)
		player_instance.queue_free()
		return
	
	# REGISTRA NO PlayerRegistry
	player_registry.register_player_node(p_id, player_instance)
	
	# Debug: Verifica registro
	if debug_mode:
		var registered_path = player_registry.get_player_node_path(p_id)
		if registered_path.is_empty():
			push_warning("TestManager: node_path vazio após registro (player %d)" % p_id)
		else:
			_log_debug("Player node registrado: %d → %s" % [p_id, registered_path])
	
	# Calcula posição de spawn
	var spawn_pos = Vector3.ZERO
	
	if map_manager and map_manager.has_method("get_spawn_position"):
		var spawn_index = spawn_data.get("spawn_index", 0)
		spawn_pos = map_manager.get_spawn_position(spawn_index)
		_log_debug("Spawn position: %s (index: %d)" % [spawn_pos, spawn_index])
	else:
		push_warning("TestManager: MapManager não disponível, usando posição (0,0,0)")
	
	# CONFIGURA TRANSFORM
	if player_instance is Node3D:
		player_instance.global_position = spawn_pos
		player_instance.global_rotation = Vector3.ZERO
	
	# Inicializa o player
	if player_instance.has_method("initialize"):
		player_instance.initialize(p_id, p_name, spawn_pos)
	
	# Registra no RoundRegistry
	round_registry.register_spawned_player(round_id, p_id, player_instance)
	
	# Inicializa estado de validação no ServerManager
	if server_manager.player_states != null:
		server_manager.player_states[p_id] = {
			"pos": spawn_pos,
			"vel": Vector3.ZERO,
			"rot": Vector3.ZERO,
			"timestamp": Time.get_ticks_msec()
		}
	
	_log_debug("✓ Player spawnado: %s (ID: %d)" % [p_name, p_id])

# ===== UTILITÁRIOS =====

func _get_next_test_room_id() -> int:
	"""
	Gera ID único para sala de teste
	Usa timestamp + random para evitar colisões
	"""
	var base_id = 1000  # IDs de teste começam em 1000
	var random_offset = randi_range(0, 999)
	return base_id + room_registry.get_room_count() + random_offset

func _log_debug(message: String):
	"""Função padrão de debug"""
	if debug_mode:
		print("[SERVER][TestManager] %s" % message)
