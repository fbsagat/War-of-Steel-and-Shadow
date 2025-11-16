extends Node
## Executará alguns comando no servidor ou no cliente para facilitar o trabalho do programador
## Deve ser desativado em produção

@export_category("Debug")
@export var debug_mode: bool = true

# ===== REGISTROS =====

var player_registry = ServerManager.player_registry
var room_registry = ServerManager.room_registry
var round_registry = ServerManager.round_registry
var object_spawner = ServerManager.object_spawner

# Estado de inicialização
var _is_server: bool = false
var _initialized: bool = false


func initialize_as_server():
	if _initialized:
		return
	
	_is_server = true
	_initialized = true
	_log_debug("TestManager inicializado")

func initialize_as_client():
	if _initialized:
		return
	
	# PlayerRegistry NÃO DEVE ser usado no cliente!
	_is_server = false
	_initialized = true
	_log_debug("TestManager inicializado")

# =============================================================================
# FUNÇÕES DE TESTE / CRIA PARTIDA DE TESTE COM PEERS CONECTADOS REAIS (apenas para desenvolvimento)
# =============================================================================
func criar_partida_teste(nome_sala: String = "Sala de Teste", configuracoes_round: Dictionary = {}):
	"""
	Cria uma partida de teste usando os peers conectados reais.
	- Cria uma sala
	- Adiciona todos os peers conectados à sala
	- Define o primeiro como host
	- Inicia a rodada automaticamente
	
	@param nome_sala: Nome da sala a ser criada
	@param configuracoes_round: Configurações personalizadas para a rodada
	"""
	if not _is_server:
		_log_debug("❌ Esta função só pode ser chamada no servidor!")
		return
	
	if not _initialized:
		_log_debug("❌ TestManager não inicializado!")
		return
	
	# Obtém peers conectados (exclui servidor - ID 1)
	var connected_peers = multiplayer.get_peers()
	connected_peers.erase(1)  # Remove o servidor da lista
	
	if connected_peers.is_empty():
		_log_debug("⚠ Nenhum cliente conectado para criar partida de teste")
		return
	
	# Limita para máximo 12 jogadores
	connected_peers = connected_peers.slice(0, 12)
	var num_players = connected_peers.size()
	
	_log_debug("🎮 Criando partida de teste com %d jogadores conectados na sala '%s'" % [num_players, nome_sala])
	
	# Passo 1: Garante que todos os peers conectados estão registrados no PlayerRegistry
	var players: Array = []
	
	for i in range(0, ServerManager.simulador_players_qtd):
		var peer_id = connected_peers[i]
		
		# Verifica se o peer já está registrado
		var player_data = player_registry.get_player(peer_id)
		if not (player_data and player_data.has("name") and player_data["registered"]):
			# Registra com nome padrão
			var player_name = "Player %d" % (i + 1)
			player_registry.add_peer(peer_id)
			player_registry.register_player(peer_id, player_name)
			player_data = player_registry.get_player(peer_id)
		
		players.append({
			"id": peer_id,
			"name": player_data["name"],
			"is_host": (i == 0)  # Primeiro peer conectado é o host
		})
		
		_log_debug("   Jogador registrado: %s (ID: %d)" % [player_data["name"], peer_id])
	
	# Passo 2: Cria sala no RoomRegistry
	var randomized_ = randi_range(1, 1000)
	var room_id = room_registry.get_room_count() + randomized_ # ID único
	
	var room_data = room_registry.create_room(
		room_id,
		nome_sala,
		"",  # sem senha
		players[0]["id"]  # host é o primeiro peer
	)
	
	if room_data.is_empty():
		_log_debug("❌ Falha ao criar sala!")
		return
	
	_log_debug("   Sala criada: '%s' (ID: %d)" % [nome_sala, room_id])
	
	# Passo 3: Adiciona todos os outros jogadores à sala (host já foi adicionado)
	for i in range(1, players.size()):
		var success = room_registry.add_player_to_room(room_id, players[i]["id"])
		if not success:
			_log_debug("⚠ Falha ao adicionar jogador %s à sala" % players[i]["name"])
	
	# Passo 4: Verifica se pode iniciar a rodada (mesma lógica de _handle_start_round)
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
	
	# Passo 5: Define o primeiro jogador como host e inicia a rodada
	
	_log_debug("========================================")
	_log_debug("HOST INICIANDO RODADA (TESTE)")
	_log_debug("Sala: %s (ID: %d)" % [room_data["name"], room_id])
	_log_debug("Jogadores participantes:")
	
	for room_player in room_data["players"]:
		player_registry.set_player_in_game(room_player["id"], true)
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %d)%s" % [room_player["name"], room_player["id"], is_host_mark])
	
	_log_debug("========================================")
	
	# Cria rodada no RoundRegistry
	var round_data = round_registry.create_round(
		room_id,
		room_data["name"],
		room_data["players"],
		configuracoes_round
	)
	
	if round_data.is_empty():
		_log_debug("❌ Erro ao criar rodada")
		return
	
	# Atualiza estado da sala
	room_registry.set_room_in_game(room_id, true)
	
	# Gera dados de spawn para cada jogador
	var spawn_data = {}
	var players_qtd = round_registry.get_total_players(round_data["round_id"])
	
	# Cria pontos de spawn
	var spawn_points = ServerManager._create_spawn_points(players_qtd)
	
	for i in range(room_data["players"].size()):
		var p = room_data["players"][i]
		spawn_data[p["id"]] = {
			"spawn_index": i,
			"team": 0
		}
	
	# Atualiza settings da rodada
	var round_settings = round_data.get("settings")
	round_settings["round_players_count"] = players_qtd
	round_settings["spawn_points"] = spawn_points
	var map_scene = round_settings.get("map_scene", "res://scenes/system/WorldGenerator.tscn")
	
	# Prepara dados para enviar aos clientes
	var match_data = {
		"round_id": round_data["round_id"],
		"room_id": room_id,
		"map_scene": map_scene,
		"settings": round_settings,
		"players": room_data["players"],
		"spawn_data": spawn_data
	}
	
	# Envia comando de início para todos os clientes da sala
	for room_player in room_data["players"]:
		NetworkManager.rpc_id(room_player["id"], "_client_round_started", match_data)
	
	# Sincroniza dados da rodada com todos os clientes (para RoundRegistry local)
	for room_player in room_data["players"]:
		NetworkManager.rpc_id(room_player["id"], "_server_start_round", round_data)
	
	# Instancia mapa e players no servidor também
	await _server_instantiate_round(match_data)
	
	# Inicia a rodada
	round_registry.start_round(round_data["round_id"])
	
	# Atualiza lista de salas
	ServerManager._send_rooms_list_to_all()
	
	_log_debug("Partida de teste iniciada com sucesso!")
	_log_debug("   Jogadores: %d | Sala: %s | Rodada: %d" % [players_qtd, nome_sala, round_data["round_id"]])

# =============================================================================
# FUNÇÃO AUXILIAR DE INSTANCIAÇÃO DO SERVIDOR
# (Copiada do ServerManager com pequenos ajustes)
# =============================================================================

func _server_instantiate_round(match_data:  Dictionary):
	"""Instancia a rodada no servidor (mapa e players)"""
	_log_debug("Instanciando rodada no servidor...")
	
	# Cria MapManager
	var server_map_manager = preload("res://scripts/gameplay/MapManager.gd").new()
	get_tree().root.add_child(server_map_manager)
	
	# Carrega o mapa
	await server_map_manager.load_map(match_data["map_scene"], match_data["settings"])
	
	if round_registry.rounds.has(match_data["round_id"]):
		round_registry.rounds[match_data["round_id"]]["map_manager"] = server_map_manager
	
	# Spawna todos os jogadores
	for player_data in match_data["players"]:
		var spawn_data = match_data["spawn_data"][player_data["id"]]
		_spawn_player_on_server(player_data, spawn_data)
	
	_log_debug(" Rodada instanciada no servidor")

func _spawn_player_on_server(player_data: Dictionary, spawn_data: Dictionary):
	"""Spawna um jogador no servidor (versão autoritativa)"""
	
	# 1. Validações iniciais
	if not player_data.has("id") or not player_data.has("name"):
		push_error("player_data inválido: faltam 'id' ou 'name'")
		return
	
	var p_id = player_data["id"]
	var p_name = player_data["name"]
	
	# 2. Carrega e instancia a cena do player
	var player_scene = preload("res://scenes/system/player_warrior.tscn")
	if not player_scene:
		push_error("Falha ao carregar player_warrior.tscn")
		return
	
	var player_instance = player_scene.instantiate()
	if not player_instance:
		push_error("Falha ao instanciar player_scene")
		return
	
	# 3. Configura identificação básica
	player_instance.name = str(p_id)
	player_instance.player_id = p_id
	player_instance.player_name = p_name
	
	# 4. ADICIONA À ÁRVORE PRIMEIRO
	get_tree().root.add_child(player_instance)
	
	# 5. AGUARDA PROCESSAMENTO COMPLETO
	if not player_instance.is_node_ready():
		await player_instance.ready
	await get_tree().process_frame
	
	# 6. VALIDA QUE ESTÁ NA ÁRVORE
	if not player_instance.is_inside_tree():
		push_error("CRÍTICO: Player %d não foi adicionado à árvore!" % p_id)
		player_instance.queue_free()
		return
	
	# 7. REGISTRA NO PlayerRegistry
	player_registry.register_player_node(p_id, player_instance)
	
	# 8. Debug: Verifica registro (opcional)
	if debug_mode:
		var registered_path = player_registry.get_player_node_path(p_id)
		if registered_path.is_empty():
			push_warning("Aviso: node_path vazio após registro (player %d)" % p_id)
		else:
			print("[DEBUG] Player registrado: %d → %s" % [p_id, registered_path])
	
	# 9. Calcula posição de spawn
	var spawn_pos = Vector3.ZERO
	var round_id = spawn_data.get("round_id", 0)
	
	if round_registry.rounds.has(round_id):
		var round_data = round_registry.rounds[round_id]
		if round_data.has("map_manager") and round_data["map_manager"]:
			var map_mgr = round_data["map_manager"]
			if map_mgr.has_method("get_spawn_position"):
				var spawn_index = spawn_data.get("spawn_index", 0)
				spawn_pos = map_mgr.get_spawn_position(spawn_index)
				_log_debug("Spawn position obtida: %s (index: %d)" % [spawn_pos, spawn_index])
	
	# 10. CONFIGURA TRANSFORM
	if player_instance is Node3D:
		player_instance.global_position = spawn_pos
		player_instance.global_rotation = Vector3.ZERO
	
	# 11. Inicializa o player
	if player_instance.has_method("initialize"):
		player_instance.initialize(p_id, p_name, spawn_pos)
	
	# 12. Registra no RoundRegistry
	var p_round = round_registry.get_round_by_player_id(p_id)
	if not p_round.is_empty():
		round_registry.register_spawned_player(p_round["round_id"], p_id, player_instance)
	
	_log_debug(" Player spawnado: %s (ID: %d) em %s" % [p_name, p_id, spawn_pos])
	
func _log_debug(message: String):
	if not debug_mode:
		return
	var prefix = "[SERVER]" if _is_server else "[CLIENT]"
	print("%s[TestManager] %s" % [prefix, message])
