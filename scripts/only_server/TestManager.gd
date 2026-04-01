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


# ===== REGISTROS (Injetados pelo initializer.gd) =====

var server_manager: ServerManager = null
var network_manager: NetworkManager = null
var item_database :ItemDatabase = null
var map_manager: MapManager = null
var client_registry: ClientRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null
var initializer = null


# ===== VARIÁVEIS INTERNAS =====

## Referência à câmera livre para visualização no servidor
var free_camera: Camera3D = null

# Estado de inicialização
var _initialized: bool = false

var actual_camera: Camera3D = null
var dummy_camera: Camera3D


# ===== INICIALIZAÇÃO =====

## Inicializa o TestManager (chamado pelo ServerManager).
func initialize():
	if _initialized:
		_log_debug("⚠ TestManager já inicializado")
		return
	
	_initialized = true
	_log_debug("▶️ TestManager inicializado com sucesso!")


# ===== CRIAÇÃO DE PARTIDA DE TESTE =====

func sort_num(min_val: int, max_val: int) -> int:
	return randi_range(min_val, max_val)
	
## Cria uma partida de teste usando os peers conectados reais.
func create_test_round(nome_sala: String = "Sala de Teste", configuracoes_round: Dictionary = {}):
	if not _initialized:
		_log_debug("❌ TestManager não inicializado!")
		return
	
	# Valida registries
	if not client_registry or not room_registry or not round_registry:
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
	
	await get_tree().process_frame
	
	# Registra jogadores no ClientRegistry
	var players: Array = []
	for i in range(num_players):
		var peer_id = connected_peers[i]
		var _uuid_base = client_registry.get_uuid_by_peer_id(peer_id)
		
		# Verifica se peer já está registrado
		var player_data = client_registry.get_player(_uuid_base)
			
		# Registra com nome padrão
		var player_name = "TestPlayer%d" % [i + 1]
		client_registry.register_player_name(_uuid_base, player_name)
		
		# Atualiza o cliente
		network_manager.rpc_id(peer_id, "_client_name_accepted", player_name)
		
		player_data = client_registry.get_player(_uuid_base)
		
		# Adiciona à lista de jogadores
		players.append({
			"peer_id": peer_id,
			"uuid_base": _uuid_base,
			"name": player_data["name"],
			"is_host": (i == 0)  # Primeiro é o host
		})
		
		_log_debug("  ✓ Jogador registrado: %s (ID: %d)" % [player_data["name"], peer_id])

	if players.is_empty():
		_log_debug("❌ Nenhum jogador válido para criar partida")
		return
	
	await get_tree().process_frame
	
	# Cria sala no RoomRegistry
	var room_data = room_registry.create_room(
		nome_sala,
		"",  # Sem senha
		players[0]["uuid_base"],  # Host é o primeiro jogador
		server_manager.min_players_to_start,
		server_manager.max_players_per_room
	)
	var room_id = room_data["id"]
	if room_data.is_empty():
		_log_debug("❌ Falha ao criar sala!")
		return

	_log_debug(" ✓ Sala criada: '%s' (ID: %d)" % [nome_sala, room_id])
	
	# Atualiza o cliente
	for i in range(num_players):
		var peer_id = connected_peers[i]
		network_manager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	await get_tree().process_frame
	
	# Adiciona outros jogadores à sala (host já foi adicionado)
	for i in range(1, players.size()):
		var _success = room_registry.add_player_to_room(room_id, players[i]["uuid_base"])
		if not _success:
			_log_debug("  ⚠ Falha ao adicionar jogador %s à sala" % players[i]["name"])
	
	# Valida requisitos para iniciar (teste de função)
	var response = room_registry.can_start_match(room_id, players[0]["uuid_base"])
	if not response[0]:
		_log_debug(response[1])
		return
	
	await get_tree().process_frame
	
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
	
	await get_tree().process_frame
	
	# Criar cena de organização do round
	var round_node = SubViewport.new()
	round_node.own_world_3d = true
	round_node.name = "Round_%d_%d" % [room_data["id"], round_data["round_id"]]
	
	round_data["round_node"] = round_node
	
	# Configurações para renderização fora de container
	round_node.size = Vector2i(1920, 1080)  # ou resolução da janela
	round_node.render_target_update_mode = SubViewport.UPDATE_ALWAYS  # ← força renderização
	
	server_manager.all_rounds_node.add_child(round_node)
	
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
		_log_debug("❌ Erro ao criar rodada")
		room_registry.set_room_in_game(room_id, false)
		return
	
	_log_debug("  ✓ Rodada criada: ID %d" % round_data["round_id"])
		
	await get_tree().process_frame
	
	# Cria câmera livre se não estiver em modo headless(sem renderização)
	if not server_manager.is_headless:
		_log_debug("Criando câmera livre: Não está em modo headless")
		actual_camera = preload(server_manager.server_camera).instantiate()
		actual_camera.name = "FreeCamera"
		round_node.add_child(actual_camera)
		actual_camera.global_position = Vector3(0, 3, 5)  # X=0, Y=10 (altura), Z=15 (distância)
		actual_camera.current = true
	else:
		_log_debug("Criando câmera dummy: Está em modo headless")
		actual_camera = Camera3D.new()
		actual_camera.name = "DummyCamera"
		round_node.add_child(actual_camera)
		actual_camera.global_position = Vector3(0, 100, 0)
		actual_camera.current = false
		
	await get_tree().process_frame
	
	# Carrega o mapa
	var success = await map_manager.load_map(server_manager.map_scene, round_node, actual_camera)
	
	if not success:
		push_error("Falha crítica ao carregar o mapa!")
	else:
		_log_debug("Mapa carregado com sucesso")
		round_registry.set_round_map_node(round_data["round_id"], round_node.get_node_or_null("Terrain3D"))
		
	# Gera spawn points
	var players_qtd = round_registry.get_total_players(round_data["round_id"])
	var spawn_points = map_manager._create_spawn_points(room_data["players"])
	
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
	}
	
	_log_debug("  ✓ Enviando dados para clientes...")
	
	await get_tree().process_frame
	
	# Envia comando de início para todos os clientes
	for room_player in match_data["players"]:
		client_registry.set_player_state(room_player["id"], client_registry.ClientState.IN_GAME)
		network_manager.rpc_id(room_player["session_id"], "_client_round_started", server_manager.server_id, match_data)

	# Instancia rodada no servidor
	await _server_instantiate_round(match_data, players_node, round_node)
	
	# Inicia rodada (ativa timers)
	round_registry.start_round(round_data["round_id"])
	
	await get_tree().process_frame
	
	if server_manager.test_trainer:
		# Spawna alguns objetos
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "torch", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "steel_helmet", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "cape_1", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "sword_2", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "shield_3", Vector3(0, 2, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "potion_glass_heal", Vector3(0, 3, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "potion_glass_stamina", Vector3(0, 3, 0), Vector3(0, 0, 0), Vector3(sort_num(-3, 3), sort_num(20, 30), sort_num(-3, 3)))
		object_manager.spawn_item(objects_node, round_data["round_id"], "potion_glass_poison", Vector3(4.577, 3, 22.876), Vector3(0, 0, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "potion_glass_poison", Vector3(-7.998, 4.937, -10.437), Vector3(0, 0, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "potion_glass_stamina", Vector3(-2.561, 4.937, 9.187), Vector3(0, 0, 0), Vector3(0, 0, 0))
		object_manager.spawn_item(objects_node, round_data["round_id"], "potion_glass_heal", Vector3(-42.622, 41.035, 0.898), Vector3(0, 0, 0), Vector3(0, 0, 0))
	
	await get_tree().process_frame
	
	# Inicia a sincronização de objetos
	network_manager.start_round_sync(round_data["round_id"], 0.04)
	
	await get_tree().process_frame
	
	# Atualiza lista de salas para os players no menu
	server_manager._send_rooms_list_to_all()
	
	_log_debug("==============================================")
	_log_debug("✓ PARTIDA DE TESTE INICIADA COM SUCESSO")
	_log_debug("  Jogadores: %d" % players_qtd)
	_log_debug("  Sala: %s (ID: %d)" % [nome_sala, room_id])
	_log_debug("  Rodada: %d" % round_data["round_id"])
	_log_debug("==============================================")


# ===== INSTANCIAÇÃO NO SERVIDOR =====

## Instancia a rodada no servidor (mapa e players).
## Similar ao ServerManager, mas com validações extras para testes.
func _server_instantiate_round(match_data: Dictionary, players_node, round_node):
	_log_debug(" Instanciando rodada no servidor...")
	
	# Aplica configurações de mapa
	await map_manager.apply_map_configs(match_data["settings"])
	var terrain_3d = round_node.get_node_or_null("Terrain3D")
	var pressure_plate: Node3D = terrain_3d.get_node_or_null("Pressure_plate")
	pressure_plate.request_spawn.connect(on_spawn_requested)
	
	await get_tree().process_frame
	
	# Salva referência no RoundRegistry
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = server_manager.map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["settings"]["spawn_points"][player_data["session_id"]]
		await get_tree().process_frame
		_spawn_player_on_server(player_data, spawn_data, match_data["round_id"], players_node)
	
	await get_tree().process_frame
	
	# Se for o primeiro round, esta é a câmera atual
	if match_data["round_id"] != 1 and not server_manager.is_headless:
		actual_camera.current = false
		
	await get_tree().process_frame
	
	# Se não headless, joga este primeiro round para a camera do servidor
	var rounds_count = round_registry.get_active_rounds_count()
	if not server_manager.is_headless and rounds_count == 1:
		server_manager._switch_camera_to_round(match_data["round_id"])
	
	_log_debug("  ✓ Rodada instanciada no servidor")


# ===== SPAWN DE JOGADORES =====

## Spawna um jogador no servidor (versão autoritativa).
## Com carregamento assíncrono e timeouts de segurança.
func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary, round_id: int, players_node):
	# VALIDAÇÕES INICIAIS
	if not player_data.has("id") or not player_data.has("name"):
		push_error("TestManager: player_data inválido: faltam 'id' ou 'name'")
		return
	
	var p_uuid = player_data["id"]
	var player_name = player_data["name"]
	
	_log_debug("🔄 Iniciando spawn do player: %s (UUID: %s)" % [player_name, p_uuid])
	
	# CARREGAMENTO DA CENA
	# Opção 1: preload() - Mais rápido, recurso já em memória (RECOMENDADO para players)
	var player_scene = preload(server_manager.player_scene)
	if not player_scene:
		push_error("TestManager: Falha ao carregar player_scene: %s" % server_manager.player_scene)
		return
	
	# Opção 2: ResourceLoader assíncrono - Carregamento em thread
	# var player_scene = await _load_player_scene_async(server_manager.player_scene)
	# if not player_scene:
	# 	return
	
	_log_debug("📦 Cena do player carregada, instanciando...")
	
	# INSTANCIAÇÃO
	var player_instance = player_scene.instantiate()
	if not player_instance:
		push_error("TestManager: Falha ao instanciar player_scene")
		return
	
	# Configurações básicas antes de adicionar à árvore
	player_instance.add_to_group("remote_player")
	player_instance.add_to_group("player")
	player_instance.is_local_player = false
	player_instance._is_server = true
	
	# Injeta dependências ANTES de adicionar à árvore
	player_instance.item_database = item_database
	player_instance.network_manager = network_manager
	player_instance.server_manager = server_manager
	player_instance.initializer = initializer
	
	_log_debug("🌳 Adicionando player à cena...")
	
	# ADIÇÃO À ÁRVORE DE CENA
	players_node.add_child(player_instance)
	
	# Aguarda o player estar na árvore
	var tree_timeout = 60  # ~1 segundo
	var tree_waited = 0
	while not player_instance.is_inside_tree() and tree_waited < tree_timeout:
		await get_tree().process_frame
		tree_waited += 1
	
	if not player_instance.is_inside_tree():
		push_error("TestManager CRÍTICO: Player %s não foi adicionado à árvore após %d frames!" % [p_uuid, tree_timeout])
		player_instance.queue_free()
		return
	
	_log_debug("✓ Player adicionado à árvore de cena")
	
	# AGUARDA READY COM TIMEOUT
	if player_instance.has_method("_ready"):
		_log_debug("⏳ Aguardando _ready() do player...")
		
		var ready_timeout = 120  # ~2 segundos
		var ready_waited = 0
		
		while not player_instance.is_node_ready() and ready_waited < ready_timeout:
			await get_tree().process_frame
			ready_waited += 1
		
		if ready_waited >= ready_timeout:
			push_warning("⚠️ Timeout aguardando _ready() do player %s, continuando mesmo assim..." % p_uuid)
		else:
			_log_debug("✓ Player está ready!")
	else:
		_log_debug("ℹ️ Player não tem _ready(), pulando espera")
		# Aguarda alguns frames para garantir que nós filhos foram criados
		await get_tree().process_frame
		await get_tree().process_frame
	
	# INICIALIZAÇÃO DO JOGADOR
	_log_debug("🔧 Inicializando player %s..." % player_name)
	
	var color: Color = Color(0.0, 0.0, 0.0, 1.0)
	var final_color: Color = player_data["character"]["color"] if player_data["character"]["color"] else color
	
	player_instance.initialize(
		player_data["name"], 
		final_color, 
		player_data["session_id"],
		player_data["id"], 
		spawn_data["position"]
	)
	
	player_instance.rotation = spawn_data["rotation"]
	
	# Aguarda processamento da inicialização
	await get_tree().process_frame
	
	# CONFIGURAÇÕES DO MAPA
	_log_debug("🗺️ Configurando referências do mapa...")
	
	player_instance.terrain_ = map_manager.current_map
	if player_instance.terrain_:
		player_instance.central_spawn = player_instance.terrain_.get_node_or_null("central_spawn")
		_log_debug("  - Terrain: %s" % ("✓" if player_instance.terrain_ else "✗"))
		_log_debug("  - Central Spawn: %s" % ("✓" if player_instance.central_spawn else "✗"))
	else:
		push_warning("⚠️ MapManager não tem mapa carregado!")
	
	# VALIDAÇÃO FINAL
	if not player_instance.is_inside_tree():
		push_error("TestManager CRÍTICO: Player %s removido da árvore após inicialização!" % p_uuid)
		player_instance.queue_free()
		return
	
	# REGISTROS
	_log_debug("📝 Registrando player nos registries...")
	
	client_registry.register_player_node(p_uuid, player_instance)
	round_registry.register_spawned_player(round_id, p_uuid, player_instance)
	
	await get_tree().process_frame

	# ESTADO NO SERVER MANAGER
	server_manager.player_states[p_uuid] = {
		"pos": spawn_data["position"],
		"vel": Vector3.ZERO,
		"rot": spawn_data["rotation"],
		"timestamp": Time.get_ticks_msec()
	}
	
	_log_debug("✅ Player spawnado com sucesso: %s (ID: %s) em %s" % [
		player_name, 
		p_uuid,
		spawn_data["position"]
	])

func on_spawn_requested(_character) -> void:
	var uuid_base = client_registry.get_uuid_by_peer_id(_character.player_id)
	var _round_id = client_registry.get_player_round(uuid_base)
	var _round = round_registry.get_round(_round_id)
	var objects_node = _round["round_node"].get_node_or_null("Objects")
	var potions = ["potion_glass_heal", "potion_glass_stamina", "potion_glass_poison"]
	object_manager.spawn_item(objects_node, _round_id, potions.pick_random(), Vector3(8.204, 2.30, 14.222), Vector3(randi_range(-5, 5), randi_range(-5, 5), randi_range(-5, 5)), Vector3(randi_range(-5, 5), randi_range(5, 30), randi_range(-5, 5)))
	
	
# ===== UTILITÁRIOS =====

## Função padrão de debug.
func _log_debug(message: String):
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "TestManager" in initializer.selected:
		return	
		
	print("[SERVER][TestManager] %s" % message)
