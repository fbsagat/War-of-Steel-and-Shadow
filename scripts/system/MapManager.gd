extends Node
class_name MapManager

## MapManager - Gerenciador de mapas e spawns
## Responsável por carregar/descarregar mapas e gerenciar pontos de spawn

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true
@export var test_threaded: bool = false
@export var is_server: bool = false

@export_category("Spawn Settings")
## Raio do círculo de spawn
@export var spawn_radius: float = 3.0
## Altura acima do chão
@export var spawn_height: float = 0.0
## Centro do círculo
@export var spawn_center: Vector3 = Vector3.ZERO
## Nó filho do mapa que se existir definirá o ponto para adição de spawns
@export var central_spawn: Node3D = null
## Variação aleatória na posição (em unidades)
@export var position_variance: float = 4.0
## Variação na rotação (em radianos, ~5.7 graus)
@export var rotation_variance: float = 0.2

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var initializer = null

# ===== VARIÁVEIS INTERNAS =====

## Referência ao mapa carregado atualmente
var current_map: Node = null

## Lista de pontos de spawn encontrados no mapa
var spawn_points: Dictionary = {}

## Índices de spawn já utilizados (para evitar sobreposição)
var used_spawn_indices: Array = []

## Configurações do mapa atual
var map_settings: Dictionary = {}

## Controle de estado de carregamento
var is_loading: bool = false

# ===== SINAIS =====

signal map_loaded(map_node: Node)
signal spawn_points_ready(count: int)
signal map_load_progress(progress: float) # Novo sinal para feedback de loading

func _ready() -> void:
	if test_threaded:
		test_threaded_loading()

func test_threaded_loading():
	var path = "res://scenes/gameplay/terrain_3d.tscn"  # Colocar algum mapa aqui
	
	print("Testando carregamento em thread: %s" % path)
	print("Arquivo existe: %s" % FileAccess.file_exists(path))
	
	var err = ResourceLoader.load_threaded_request(path)
	print("Erro ao iniciar request: %s" % error_string(err))
	
	var frames = 0
	while frames < 100:
		var progress = []
		var status = ResourceLoader.load_threaded_get_status(path, progress)
		print("Frame %d - Status: %d, Progresso: %s" % [frames, status, progress])
		
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			print("✓ Carregamento concluído!")
			var resource = ResourceLoader.load_threaded_get(path)
			print("Recurso: %s" % resource)
			break
		
		await get_tree().process_frame
		frames += 1
		
# ===== CARREGAMENTO DE MAPA =====

## Carrega um mapa a partir do caminho da cena de forma assíncrona
func load_map(map_scene_path: String, round_node: Node, actual_camera: Camera3D) -> bool:
	"""Carrega um mapa a partir do caminho da cena usando ResourceLoader assíncrono."""
	if is_loading:
		push_warning("MapManager já está carregando um mapa. Ignorando solicitação.")
		return false
	
	is_loading = true
	_log_debug("Carregando mapa (Async): %s" % map_scene_path)
	
	# Verifica se o arquivo existe
	if not FileAccess.file_exists(map_scene_path):
		push_error("Arquivo do mapa não existe: %s" % map_scene_path)
		is_loading = false
		return false
	
	_log_debug("Arquivo existe, iniciando carregamento em thread...")
	
	# Inicia o carregamento em thread
	var err = ResourceLoader.load_threaded_request(map_scene_path)
	if err != OK:
		push_error("Falha ao iniciar carregamento em thread: %s (Erro: %s)" % [map_scene_path, error_string(err)])
		is_loading = false
		return false
	
	_log_debug("Carregamento em thread iniciado, aguardando conclusão...")
	
	# Aguarda o carregamento terminar com timeout de segurança
	var timeout_frames: int = 600
	var frames_waited: int = 0
	
	while frames_waited < timeout_frames:
		var progress = []
		var status = ResourceLoader.load_threaded_get_status(map_scene_path, progress)
		
		if frames_waited % 60 == 0:
			if not progress.is_empty():
				_log_debug("Progresso do carregamento: %.0f%%" % (progress[0] * 100))
		
		if not progress.is_empty():
			map_load_progress.emit(progress[0])
		
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			_log_debug("Carregamento concluído com sucesso!")
			break
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			push_error("Falha ao carregar mapa em thread: %s" % map_scene_path)
			is_loading = false
			return false
		elif status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("Recurso inválido: %s" % map_scene_path)
			is_loading = false
			return false
		
		await get_tree().process_frame
		frames_waited += 1
	
	if frames_waited >= timeout_frames:
		push_error("Timeout ao carregar mapa: %s" % [map_scene_path])
		is_loading = false
		return false
	
	# Recupera o recurso carregado
	_log_debug("Obtendo recurso carregado...")
	var map_resource: PackedScene = ResourceLoader.load_threaded_get(map_scene_path)
	if map_resource == null:
		push_error("Falha ao obter recurso do mapa após carregamento.")
		is_loading = false
		return false
	
	_log_debug("Recurso obtido, instanciando mapa...")
	
	# Instancia o mapa
	current_map = map_resource.instantiate()
	if current_map == null:
		push_error("Falha ao instanciar mapa")
		is_loading = false
		return false
	
	# Verifica se o nó tem script e se o script tem _ready
	var has_ready = false
	if current_map.get_script() and current_map.has_method("_ready"):
		has_ready = true
		_log_debug("Mapa tem método _ready, aguardando...")
	else:
		_log_debug("Mapa NÃO tem método _ready, pulando await ready...")
		
	# Adiciona o mapa à cena
	round_node.add_child(current_map)
	_log_debug("Mapa adicionado à cena (tipo: %s)" % current_map.get_class())
	
	# Aguarda o ready APENAS se o nó tiver o método _ready
	if has_ready:
		var ready_timeout = 120  # ~2 segundos
		var ready_waited = 0
		while not current_map.is_node_ready() and ready_waited < ready_timeout:
			await get_tree().process_frame
			ready_waited += 1
		
		if ready_waited >= ready_timeout:
			push_warning("Timeout aguarding ready do mapa, continuando mesmo assim...")
		else:
			_log_debug("Mapa está pronto (_ready chamado)!")
	else:
		# Aguarda alguns frames para garantir que o nó foi adicionado à árvore
		await get_tree().process_frame
		await get_tree().process_frame
		_log_debug("Nós filhos devem estar disponíveis agora")
	
	_log_debug("Verificando nós filhos do mapa...")
	for child in current_map.get_children():
		_log_debug("  - Filho: %s (%s)" % [child.name, child.get_class()])
	
	# Desativa o physics_process inicialmente
	current_map.set_physics_process(false)
	# Configura o Terrain3D para usar actual_camera
	current_map.set_camera(actual_camera)
	# Ativa o physics_process após atribuir a câmera
	current_map.set_physics_process(true)
	
	is_loading = false
	_log_debug("✓ Mapa carregado e instanciado com sucesso!")
	
	return true

func apply_map_configs(settings: Dictionary = {}):
	# Garante que o mapa está carregado e pronto
	if not current_map:
		push_error("Tentativa de aplicar configs sem mapa carregado.")
		return false

	# Aguarda novamente por segurança se chamado externamente sem await no load_map
	if not current_map.is_node_ready():
		await current_map.ready
	
	# Aplicar configurações do Terrain3D
	# Ainda não aplica nada para Terrain3D
	
	# Aplicar configurações do Sky3D
	var sky_node = current_map.get_node_or_null("Sky3D")
	apply_sky_configs(sky_node, settings.get("sky_rand_configs"))
	
	# Aguarda um frame para garantir que alterações de renderização foram processadas
	await get_tree().process_frame
	
	# Encontra os pontos de spawn
	if settings.has("spawn_points"):
		spawn_points = settings["spawn_points"]
	else:
		# Se não vierem nas settings, gera baseado nos jogadores (lógica externa deve chamar _create_spawn_points)
		pass
		
	spawn_points_ready.emit(spawn_points.size())
	
	# Aplica configurações ao mapa (se o mapa tiver método configure)
	if current_map.has_method("configure"):
		current_map.configure(settings)
	
	_log_debug(" Mapa carregado com sucesso: %d spawn points encontrados" % spawn_points.size())
	
	# Armazena settings atuais
	map_settings = settings.duplicate()
	
	map_loaded.emit(current_map)
	return true

# ===== GERENCIAMENTO DE SPAWN POINTS =====

func _create_spawn_points(players: Array) -> Dictionary:
	"""
	Gera pontos de spawn em formação circular
	Suporta de 1 a 14 jogadores com distribuição uniforme
	
	Retorna Array de Dictionaries: [{position: Vector3, rotation: Vector3}]
	"""
	if not current_map:
		push_error("Não é possível criar spawns sem mapa carregado.")
		return {}

	var match_players_count = players.size()
	spawn_points.clear()
	
	central_spawn = current_map.get_node_or_null("central_spawn") as Node3D
	if central_spawn:
		spawn_center = central_spawn.global_position
	
	# Caso especial: apenas 1 jogador
	if match_players_count == 1:

		var spawn := {
			"position": spawn_center + Vector3(0, spawn_height, spawn_radius),
			"rotation": Vector3(0, PI, 0)
		}

		var peer_id: int = players[0]["session_id"]

		spawn_points[peer_id] = spawn

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
		
		var spawn := {
			"position": final_position,
			"rotation": Vector3(0, rotation_y, 0)
		}

		var peer_id: int = players[i]["session_id"]

		spawn_points[peer_id] = spawn
		
	_log_debug("✓ Spawn points criados: %d jogadores em círculo (raio: %.1f)" % [spawn_points.size(), spawn_radius])
	return spawn_points

## Retorna a posição de spawn para um índice específico
func get_spawn_position(player_index: int) -> Variant:
	if spawn_points.is_empty():
		push_warning("Nenhum spawn point disponível!")
		return Vector3.ZERO
	
	# Usa módulo para evitar índices fora do alcance
	var spawn_index = player_index % spawn_points.size()
	
	var spawn_data = spawn_points[spawn_index]
	used_spawn_indices.append(spawn_index)
	
	_log_debug("Spawn position retornada: índice %d" % spawn_index)
	
	return spawn_data["position"]

## Retorna dados completos de spawn (posição + rotação)
func get_spawn_data(player_index: int) -> Dictionary:
	if spawn_points.is_empty():
		return {
			"position": Vector3.ZERO,
			"rotation": Vector3.ZERO
		}
	
	var spawn_index = player_index % spawn_points.size()
	used_spawn_indices.append(spawn_index)
	
	return spawn_points[spawn_index].duplicate()

## Retorna um spawn point aleatório não utilizado
func get_random_unused_spawn() -> Dictionary:
	if spawn_points.is_empty():
		return {
			"position": Vector3.ZERO,
			"rotation": Vector3.ZERO
		}
	
	var available_indices = []
	for i in range(spawn_points.size()):
		if i not in used_spawn_indices:
			available_indices.append(i)
	
	# Se todos foram usados, reseta
	if available_indices.is_empty():
		used_spawn_indices.clear()
		available_indices = range(spawn_points.size())
	
	# Seleciona aleatório
	var selected_index = available_indices[randi() % available_indices.size()]
	used_spawn_indices.append(selected_index)
	
	return spawn_points[selected_index].duplicate()

## Reseta o tracking de spawns usados
func reset_spawn_tracking():
	used_spawn_indices.clear()
	_log_debug("Spawn tracking resetado")

# ===== QUERIES =====

## Verifica se há um mapa carregado
func is_map_loaded() -> bool:
	return current_map != null and is_instance_valid(current_map)

## Retorna referência ao mapa atual
func get_current_map() -> Node:
	return current_map

## Retorna número de spawn points disponíveis
func get_spawn_count() -> int:
	return spawn_points.size()

## Retorna configurações do mapa
func get_settings() -> Dictionary:
	return map_settings.duplicate()

# ===== UTILITÁRIOS =====

## Encontra um nó específico no mapa
func find_map_node(node_name: String) -> Node:
	if current_map == null:
		return null
	
	return current_map.find_child(node_name, true, false)

## Encontra todos os nós de um grupo no mapa
func find_map_nodes_in_group(group_name: String) -> Array:
	if current_map == null:
		return []
	
	return current_map.get_children().filter(func(n): return n.is_in_group(group_name))

## Aplica as configurações geradas no nó Sky3D
## @param sky_node: Referência ao nó Sky3D
## @param config: Dicionário de configurações (gerado por gerar_configuracoes_randomicas)
func apply_sky_configs(sky_node: Node, config: Dictionary) -> void:
	if sky_node == null or config.is_empty():
		# Não é necessariamente um erro, alguns mapas podem não ter Sky3D
		if sky_node == null:
			_log_debug("Sky3D não encontrado no mapa, pulando configuração de céu.")
		return
	
	var time_node = sky_node.get_node_or_null("TimeOfDay")
	var sky_dome = sky_node.get_node_or_null("SkyDome")
	var env_node = sky_node.get_node_or_null("Environment")
	
	if config.has("time") and time_node:
		if "current_time" in time_node: time_node.current_time = config["time"]["current_time"]
		if "day_duration" in time_node: time_node.day_duration = config["time"]["day_duration"]
		if "auto_advance" in time_node: time_node.auto_advance = config["time"]["auto_advance"]
		if "time_scale" in time_node: time_node.time_scale = config["time"]["time_scale"]
	
	if config.has("sky") and sky_dome:
		var sky = config["sky"]
		if "sky_contribution" in sky_dome: sky_dome.sky_contribution = sky.get("sky_contribution", 1.0)
		if "rayleigh_coefficient" in sky_dome: sky_dome.rayleigh_coefficient = sky.get("rayleigh_coefficient", 1.0)
		if "mie_coefficient" in sky_dome: sky_dome.mie_coefficient = sky.get("mie_coefficient", 0.01)
		if "turbidity" in sky_dome: sky_dome.turbidity = sky.get("turbidity", 2.0)
		if "sky_top_color" in sky_dome: sky_dome.sky_top_color = sky.get("sky_color", Color.WHITE)
		if "sky_horizon_color" in sky_dome: sky_dome.sky_horizon_color = sky.get("horizon_color", Color.WHITE)
	
	if config.has("fog") and env_node and env_node.environment:
		var fog = config["fog"]
		env_node.environment.fog_enabled = fog.get("enabled", false)
		env_node.environment.fog_density = fog.get("density", 0.01)
		env_node.environment.fog_light_color = fog.get("color", Color.WHITE)
		env_node.environment.fog_height = fog.get("height", 0.0)
		env_node.environment.fog_height_density = fog.get("height_density", 0.0)
	
	if config.has("clouds") and sky_dome:
		var clouds = config["clouds"]
		if "clouds_coverage" in sky_dome: sky_dome.clouds_coverage = clouds.get("coverage", 0.5)
		if "clouds_size" in sky_dome: sky_dome.clouds_size = clouds.get("size", 1.0)
		if "clouds_speed" in sky_dome: sky_dome.clouds_speed = clouds.get("speed", 0.1)
		if "clouds_direction" in sky_dome: sky_dome.clouds_direction = clouds.get("wind_direction", 0.0)
		if "clouds_opacity" in sky_dome: sky_dome.clouds_opacity = clouds.get("opacity", 1.0)
		if "clouds_brightness" in sky_dome: sky_dome.clouds_brightness = clouds.get("brightness", 1.0)
		if "clouds_color" in sky_dome: sky_dome.clouds_color = clouds.get("color", Color.WHITE)
	
	if config.has("exposure") and env_node and env_node.environment:
		env_node.environment.tonemap_exposure = config["exposure"].get("exposure", 1.0)
		env_node.environment.tonemap_white = config["exposure"].get("white_point", 8.0)
	
	if config.has("ambient") and env_node and env_node.environment:
		var ambient = config["ambient"]
		env_node.environment.ambient_light_sky_contribution = 1.0
		env_node.environment.ambient_light_color = ambient.get("sky_color", Color.WHITE)
	
	_log_debug("✓ Configurações de céu aplicadas!")

func _log_debug(message: String):
	if not debug_mode:
		return
		
	# Configurações do initializer
	if initializer and initializer.activate_only_selected and not "MapManager" in initializer.selected:
		return
	
	var server: String = "[SERVER]" if is_server else "[CLIENT]"
	print("%s[MapManager]%s" % [server, message])
