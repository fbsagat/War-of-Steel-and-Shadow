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

var initializer: Initializer = null

# ===== FILA ESTÁTICA COMPARTILHADA =====
## Compartilhada entre TODAS as instâncias de MapManager.
## Garante que apenas um load ocorra por vez no ResourceLoader global.

## Requisições pendentes: Array de Dictionaries com chaves:
##   path, round_node, camera, manager, completed, result
static var _global_queue: Array[Dictionary] = []

## Instância atual responsável por processar a fila.
## Quando nil, a próxima instância que enfileirar assume o papel.
static var _queue_processor: MapManager = null

# ===== VARIÁVEIS INTERNAS =====

## Referência ao mapa carregado atualmente
var current_map: Node = null

## Lista de pontos de spawn encontrados no mapa
var spawn_points: Dictionary = {}

## Índices de spawn já utilizados (para evitar sobreposição)
var used_spawn_indices: Array = []

## Configurações do mapa atual
var map_settings: Dictionary = {}

## Controle de estado de carregamento (apenas para _execute_load_map)
var is_loading: bool = false

# ===== SINAIS =====

signal map_loaded(map_node: Node)
signal spawn_points_ready(count: int)
signal map_load_progress(progress: float)
## Emitido quando a posição desta instância na fila muda.
## position = 0 significa que é a vez desta instância.
signal queue_position_changed(position: int)

func _ready() -> void:
	if test_threaded:
		test_threaded_loading()

func test_threaded_loading():
	var path = "res://scenes/gameplay/terrain_3d.tscn"

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

# ===== FILA DE CARREGAMENTO =====

## Ponto de entrada público para carregar um mapa.
## Enfileira a solicitação e aguarda sua vez na fila global.
func load_map(map_scene_path: String, round_node: Node, actual_camera: Camera3D) -> bool:
	if not round_node:
		push_error("Load map: Round node não encontrado")
		return false

	# Monta a requisição para esta instância
	var request: Dictionary = {
		"path":       map_scene_path,
		"round_node": round_node,
		"camera":     actual_camera,
		"manager":    self,
		"completed":  false,
		"result":     false,
	}

	_global_queue.append(request)
	var queue_pos: int = _global_queue.size() - 1
	_log_debug("Enfileirado na posição %d (fila total: %d)" % [queue_pos, _global_queue.size()])
	queue_position_changed.emit(queue_pos)

	# Se nenhuma instância está processando, esta assume o papel
	if _queue_processor == null:
		_queue_processor = self
		_run_queue()  # Não await aqui — _run_queue roda de forma cooperativa
	else:
		_log_debug("Aguardando fila... processador atual: %s" % _queue_processor.name)

	# Aguarda esta requisição específica ser concluída
	while not request["completed"]:
		# Atualiza a posição na fila para quem ouvir o sinal
		var current_pos: int = _global_queue.find(request)
		if current_pos != queue_pos:
			queue_pos = current_pos
			queue_position_changed.emit(maxi(queue_pos, 0))
		await get_tree().process_frame

	_log_debug("Requisição concluída com resultado: %s" % request["result"])
	return request["result"]

## Loop principal da fila — executado apenas pela instância processadora.
## Processa uma requisição por vez de forma sequencial e cooperativa.
func _run_queue() -> void:
	_log_debug("Iniciando processamento da fila (%d itens)" % _global_queue.size())

	while not _global_queue.is_empty():
		# Verifica se o processador ainda é válido (pode ter sido freed)
		if not is_instance_valid(_queue_processor) or _queue_processor != self:
			_log_debug("Processador inválido ou substituído, encerrando loop")
			return

		var request: Dictionary = _global_queue[0]
		var target_manager: MapManager = request["manager"]

		# Verifica se o manager alvo ainda é válido
		if not is_instance_valid(target_manager):
			push_warning("MapManager da requisição foi liberado, descartando.")
			_global_queue.pop_front()
			continue

		_log_debug("Processando requisição: %s (manager: %s)" % [request["path"], target_manager.name])

		var result: bool = await target_manager._execute_load_map(
			request["path"],
			request["round_node"],
			request["camera"]
		)

		request["result"]    = result
		request["completed"] = true
		_global_queue.pop_front()

		_log_debug("Requisição finalizada. Restam %d na fila." % _global_queue.size())

		# Yield de um frame entre carregamentos para não travar a engine
		await get_tree().process_frame

	_log_debug("Fila de carregamento concluída.")
	_queue_processor = null

## Retorna a posição atual desta instância na fila (0 = sendo processada, -1 = não está na fila).
func get_queue_position() -> int:
	for i in range(_global_queue.size()):
		if _global_queue[i]["manager"] == self:
			return i
	return -1

## Retorna o total de requisições pendentes na fila global.
static func get_global_queue_size() -> int:
	return _global_queue.size()

# ===== CARREGAMENTO INTERNO =====

## Lógica de carregamento de mapa.
## Chamado exclusivamente pelo _run_queue — não chamar diretamente.
func _execute_load_map(map_scene_path: String, round_node: Node, actual_camera: Camera3D) -> bool:
	if not round_node:
		push_error("_execute_load_map: Round node não encontrado")
		return false

	var round_name = round_node.name

	if is_loading:
		push_warning("_execute_load_map: Esta instância já está carregando. Isso não deveria acontecer com a fila ativa.")
		return false

	is_loading = true
	_log_debug("Carregando mapa (Async): %s" % map_scene_path)

	if not FileAccess.file_exists(map_scene_path):
		push_error("Arquivo do mapa não existe: %s" % map_scene_path)
		is_loading = false
		return false

	_log_debug("Arquivo existe, iniciando carregamento em thread para %s..." % round_name)

	var err = ResourceLoader.load_threaded_request(map_scene_path)
	if err != OK:
		push_error("Falha ao iniciar carregamento em thread: %s (Erro: %s)" % [map_scene_path, error_string(err)])
		is_loading = false
		return false

	_log_debug("Carregamento em thread iniciado, aguardando conclusão...")

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
		push_error("Timeout ao carregar mapa: %s" % map_scene_path)
		is_loading = false
		return false

	_log_debug("Obtendo recurso carregado...")
	var map_resource: PackedScene = ResourceLoader.load_threaded_get(map_scene_path)
	if map_resource == null:
		push_error("Falha ao obter recurso do mapa após carregamento.")
		is_loading = false
		return false

	_log_debug("Recurso obtido, instanciando mapa...")

	current_map = map_resource.instantiate()
	if current_map == null:
		push_error("Falha ao instanciar mapa")
		is_loading = false
		return false
	
	_make_resources_unique(current_map)
	
	var has_ready = false
	if current_map.get_script() and current_map.has_method("_ready"):
		has_ready = true
		_log_debug("Mapa tem método _ready, aguardando...")
	else:
		_log_debug("Mapa NÃO tem método _ready, pulando await ready...")

	round_node.add_child(current_map)
	_log_debug("Mapa adicionado à cena (tipo: %s)" % current_map.get_class())

	if has_ready:
		var ready_timeout = 120
		var ready_waited = 0
		while not current_map.is_node_ready() and ready_waited < ready_timeout:
			await get_tree().process_frame
			ready_waited += 1

		if ready_waited >= ready_timeout:
			push_warning("Timeout aguardando ready do mapa, continuando mesmo assim...")
		else:
			_log_debug("Mapa está pronto (_ready chamado)!")
	else:
		await get_tree().process_frame
		await get_tree().process_frame
		_log_debug("Nós filhos devem estar disponíveis agora")

	_log_debug("Verificando nós filhos do mapa...")
	for child in current_map.get_children():
		_log_debug("  - Filho: %s (%s)" % [child.name, child.get_class()])
	
	current_map.set_physics_process(false)
	current_map.set_camera(actual_camera)
	current_map.set_physics_process(true)

	is_loading = false
	_log_debug("✓ Mapa de %s carregado e instanciado com sucesso!" % round_name)

	return true

func apply_map_configs(settings: Dictionary = {}):
	if not current_map:
		push_error("Tentativa de aplicar configs sem mapa carregado.")
		return false

	if not current_map.is_node_ready():
		await current_map.ready

	var sky_node = current_map.get_node_or_null("Sky3D")
	apply_sky_configs(sky_node, settings.get("sky_rand_configs"))

	await get_tree().process_frame

	if settings.has("spawn_points"):
		spawn_points = settings["spawn_points"]

	spawn_points_ready.emit(spawn_points.size())

	if current_map.has_method("configure"):
		current_map.configure(settings)

	_log_debug("Mapa carregado com sucesso: %d spawn points encontrados" % spawn_points.size())

	map_settings = settings.duplicate()
	map_loaded.emit(current_map)
	return true

# ===== GERENCIAMENTO DE SPAWN POINTS =====

func _create_spawn_points(players: Array) -> Dictionary:
	if not current_map:
		push_error("Não é possível criar spawns sem mapa carregado.")
		return {}

	var match_players_count = players.size()
	spawn_points.clear()

	central_spawn = current_map.get_node_or_null("central_spawn") as Node3D
	if central_spawn:
		spawn_center = central_spawn.global_position

	if match_players_count == 1:
		var spawn := {
			"position": spawn_center + Vector3(0, spawn_height, spawn_radius),
			"rotation": Vector3(0, PI, 0)
		}
		var p_uuid: String = players[0]["uuid_base"]
		spawn_points[p_uuid] = spawn
		_log_debug("✓ Spawn point único criado no centro")
		return spawn_points

	match_players_count = clamp(match_players_count, 1, 14)

	for i in range(match_players_count):
		var angle = (i * 2.0 * PI) / match_players_count
		var base_x = cos(angle) * spawn_radius
		var base_z = sin(angle) * spawn_radius
		var variance_x = randf_range(-position_variance, position_variance)
		var variance_z = randf_range(-position_variance, position_variance)

		var final_position = spawn_center + Vector3(
			base_x + variance_x,
			spawn_height,
			base_z + variance_z
		)

		var to_center = spawn_center - final_position
		var rotation_y = atan2(to_center.x, to_center.z)
		rotation_y += randf_range(-rotation_variance, rotation_variance)

		var spawn := {
			"position": final_position,
			"rotation": Vector3(0, rotation_y, 0)
		}

		var p_uuid: String = players[i]["uuid_base"]
		spawn_points[p_uuid] = spawn

	_log_debug("✓ Spawn points criados: %d jogadores em círculo (raio: %.1f)" % [spawn_points.size(), spawn_radius])
	return spawn_points

func get_spawn_position(player_index: int) -> Variant:
	if spawn_points.is_empty():
		push_warning("Nenhum spawn point disponível!")
		return Vector3.ZERO

	var spawn_index = player_index % spawn_points.size()
	var spawn_data = spawn_points[spawn_index]
	used_spawn_indices.append(spawn_index)
	_log_debug("Spawn position retornada: índice %d" % spawn_index)
	return spawn_data["position"]

func get_spawn_data(player_index: int) -> Dictionary:
	if spawn_points.is_empty():
		return { "position": Vector3.ZERO, "rotation": Vector3.ZERO }

	var spawn_index = player_index % spawn_points.size()
	used_spawn_indices.append(spawn_index)
	return spawn_points[spawn_index].duplicate()

func get_random_unused_spawn() -> Dictionary:
	if spawn_points.is_empty():
		return { "position": Vector3.ZERO, "rotation": Vector3.ZERO }

	var available_indices = []
	for i in range(spawn_points.size()):
		if i not in used_spawn_indices:
			available_indices.append(i)

	if available_indices.is_empty():
		used_spawn_indices.clear()
		available_indices = range(spawn_points.size())

	var selected_index = available_indices[randi() % available_indices.size()]
	used_spawn_indices.append(selected_index)
	return spawn_points[selected_index].duplicate()

func reset_spawn_tracking():
	used_spawn_indices.clear()
	_log_debug("Spawn tracking resetado")

# ===== QUERIES =====

func is_map_loaded() -> bool:
	return current_map != null and is_instance_valid(current_map)

func get_current_map() -> Node:
	return current_map

func get_spawn_count() -> int:
	return spawn_points.size()

func get_settings() -> Dictionary:
	return map_settings.duplicate()

# ===== UTILITÁRIOS =====

func find_map_node(node_name: String) -> Node:
	if current_map == null:
		return null
	return current_map.find_child(node_name, true, false)

func find_map_nodes_in_group(group_name: String) -> Array:
	if current_map == null:
		return []
	return current_map.get_children().filter(func(n): return n.is_in_group(group_name))

func apply_sky_configs(sky_node: Node, config: Dictionary) -> void:
	if sky_node == null or config.is_empty():
		if sky_node == null:
			_log_debug("Sky3D não encontrado no mapa, pulando configuração de céu.")
		return

	var time_node = sky_node.get_node_or_null("TimeOfDay")
	var sky_dome  = sky_node.get_node_or_null("SkyDome")
	var env_node  = sky_node.get_node_or_null("Environment")

	if config.has("time") and time_node:
		if "current_time"  in time_node: time_node.current_time  = config["time"]["current_time"]
		if "day_duration"  in time_node: time_node.day_duration   = config["time"]["day_duration"]
		if "auto_advance"  in time_node: time_node.auto_advance   = config["time"]["auto_advance"]
		if "time_scale"    in time_node: time_node.time_scale     = config["time"]["time_scale"]

	if config.has("sky") and sky_dome:
		var sky = config["sky"]
		if "sky_contribution"   in sky_dome: sky_dome.sky_contribution   = sky.get("sky_contribution", 1.0)
		if "rayleigh_coefficient" in sky_dome: sky_dome.rayleigh_coefficient = sky.get("rayleigh_coefficient", 1.0)
		if "mie_coefficient"    in sky_dome: sky_dome.mie_coefficient    = sky.get("mie_coefficient", 0.01)
		if "turbidity"          in sky_dome: sky_dome.turbidity           = sky.get("turbidity", 2.0)
		if "sky_top_color"      in sky_dome: sky_dome.sky_top_color      = sky.get("sky_color", Color.WHITE)
		if "sky_horizon_color"  in sky_dome: sky_dome.sky_horizon_color  = sky.get("horizon_color", Color.WHITE)

	if config.has("fog") and env_node and env_node.environment:
		var fog = config["fog"]
		env_node.environment.fog_enabled        = fog.get("enabled", false)
		env_node.environment.fog_density        = fog.get("density", 0.01)
		env_node.environment.fog_light_color    = fog.get("color", Color.WHITE)
		env_node.environment.fog_height         = fog.get("height", 0.0)
		env_node.environment.fog_height_density = fog.get("height_density", 0.0)

	if config.has("clouds") and sky_dome:
		var clouds = config["clouds"]
		if "clouds_coverage"  in sky_dome: sky_dome.clouds_coverage  = clouds.get("coverage", 0.5)
		if "clouds_size"      in sky_dome: sky_dome.clouds_size       = clouds.get("size", 1.0)
		if "clouds_speed"     in sky_dome: sky_dome.clouds_speed      = clouds.get("speed", 0.1)
		if "clouds_direction" in sky_dome: sky_dome.clouds_direction  = clouds.get("wind_direction", 0.0)
		if "clouds_opacity"   in sky_dome: sky_dome.clouds_opacity    = clouds.get("opacity", 1.0)
		if "clouds_brightness" in sky_dome: sky_dome.clouds_brightness = clouds.get("brightness", 1.0)
		if "clouds_color"     in sky_dome: sky_dome.clouds_color      = clouds.get("color", Color.WHITE)

	if config.has("exposure") and env_node and env_node.environment:
		env_node.environment.tonemap_exposure = config["exposure"].get("exposure", 1.0)
		env_node.environment.tonemap_white    = config["exposure"].get("white_point", 8.0)

	if config.has("ambient") and env_node and env_node.environment:
		var ambient = config["ambient"]
		env_node.environment.ambient_light_sky_contribution = 1.0
		env_node.environment.ambient_light_color            = ambient.get("sky_color", Color.WHITE)

	_log_debug("✓ Configurações de céu aplicadas!")

func _make_resources_unique(node: Node):
	for child in node.get_children():
		_make_resources_unique(child)
	
	# Duplica materiais
	if node is MeshInstance3D:
		if node.material_override:
			node.material_override = node.material_override.duplicate(true)
	
	# Duplica Terrain3D (ESSENCIAL)
	if node.has_method("get_data") and node.has_method("set_data"):
		var data = node.get("data")
		if data:
			node.set("data", data.duplicate(true))

func _log_debug(message: String):
	if not debug_mode:
		return
	if initializer and initializer.activate_only_selected and not "MapManager" in initializer.selected:
		return
	var server: String = "[SERVER]" if is_server else "[CLIENT]"
	print("%s[MapManager]%s" % [server, message])
