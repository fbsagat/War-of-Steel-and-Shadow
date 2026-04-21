extends Node
class_name MapManager

## MapManager - Base compartilhada mínima
## Contém apenas o fluxo de carregamento e configuração que AMBOS os lados executam.
## Comportamentos exclusivos de cada lado são injetados via hooks virtuais.

# ===== CONFIGURAÇÕES COMUNS =====

@export var debug_mode: bool = true
@export var is_server: bool = false

# ===== REGISTROS =====

var initializer: GameInitializer = null

# ===== FILA ESTÁTICA COMPARTILHADA =====

static var _global_queue: Array[Dictionary] = []
static var _queue_processor: MapManager = null

# ===== VARIÁVEIS INTERNAS =====

## Mapas carregados indexados pelo instance_id do round_node.
## Evita sobrescrita quando múltiplos loads ocorrem no mesmo manager.
var loaded_maps: Dictionary = {}

## Atalho de leitura: retorna o mapa do round_node fornecido,
## ou o último carregado se round_node for null.
var current_map: Node:
	get:
		if loaded_maps.is_empty():
			return null
		return loaded_maps.values().back()

var spawn_points: Dictionary = {}
var map_settings: Dictionary = {}
var is_loading: bool = false

# ===== SINAIS =====

signal map_loaded(map_node: Node)
signal spawn_points_ready(count: int)
signal map_load_progress(progress: float)
signal queue_position_changed(position: int)

# ===== FILA DE CARREGAMENTO =====

func load_map(map_scene_path: String, round_node: Node, actual_camera: Camera3D = null) -> bool:
	if not round_node:
		push_error("load_map: Round node não encontrado")
		return false

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

	if _queue_processor == null:
		_queue_processor = self
		_run_queue()
	else:
		_log_debug("Aguardando fila... processador atual: %s" % _queue_processor.name)

	while not request["completed"]:
		var current_pos: int = _global_queue.find(request)
		if current_pos != queue_pos:
			queue_pos = current_pos
			queue_position_changed.emit(maxi(queue_pos, 0))
		await get_tree().process_frame

	_log_debug("Requisição concluída com resultado: %s" % request["result"])
	return request["result"]

func _run_queue() -> void:
	_log_debug("Iniciando processamento da fila (%d itens)" % _global_queue.size())

	while not _global_queue.is_empty():
		if not is_instance_valid(_queue_processor) or _queue_processor != self:
			_log_debug("Processador inválido ou substituído, encerrando loop")
			return

		var request: Dictionary = _global_queue[0]
		var target_manager: MapManager = request["manager"]

		if not is_instance_valid(target_manager):
			push_warning("MapManager da requisição foi liberado, descartando.")
			_global_queue.pop_front()
			continue

		_log_debug("Processando: %s (manager: %s)" % [request["path"], target_manager.name])

		var result: bool = await target_manager._execute_load_map(
			request["path"], request["round_node"], request["camera"]
		)

		request["result"]    = result
		request["completed"] = true
		_global_queue.pop_front()

		_log_debug("Finalizado. Restam %d na fila." % _global_queue.size())
		await get_tree().process_frame

	_log_debug("Fila concluída.")
	_queue_processor = null

func get_queue_position() -> int:
	for i in range(_global_queue.size()):
		if _global_queue[i]["manager"] == self:
			return i
	return -1

static func get_global_queue_size() -> int:
	return _global_queue.size()

# ===== CARREGAMENTO INTERNO =====

func _execute_load_map(map_scene_path: String, round_node: Node, actual_camera: Camera3D) -> bool:
	if not round_node:
		push_error("_execute_load_map: Round node não encontrado")
		return false

	if is_loading:
		push_warning("_execute_load_map: Já está carregando — fila com falha.")
		return false

	is_loading = true

	if not FileAccess.file_exists(map_scene_path):
		push_error("Arquivo não existe: %s" % map_scene_path)
		is_loading = false
		return false

	var err = ResourceLoader.load_threaded_request(map_scene_path)
	if err != OK:
		push_error("Falha ao iniciar thread: %s (%s)" % [map_scene_path, error_string(err)])
		is_loading = false
		return false

	var timeout_frames: int = 600
	var frames_waited: int = 0

	while frames_waited < timeout_frames:
		var progress = []
		var status = ResourceLoader.load_threaded_get_status(map_scene_path, progress)

		if not progress.is_empty():
			if frames_waited % 60 == 0:
				_log_debug("Progresso: %.0f%%" % (progress[0] * 100))
			map_load_progress.emit(progress[0])

		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			push_error("Falha no carregamento em thread: %s" % map_scene_path)
			is_loading = false
			return false
		elif status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("Recurso inválido: %s" % map_scene_path)
			is_loading = false
			return false

		await get_tree().process_frame
		frames_waited += 1

	if frames_waited >= timeout_frames:
		push_error("Timeout ao carregar: %s" % map_scene_path)
		is_loading = false
		return false

	var map_resource: PackedScene = ResourceLoader.load_threaded_get(map_scene_path)
	if map_resource == null:
		push_error("Recurso nulo após carregamento.")
		is_loading = false
		return false

	var map: Node = map_resource.instantiate()
	if map == null:
		push_error("Falha ao instanciar mapa.")
		is_loading = false
		return false

	# Registra o mapa pelo id do round_node — não sobrescreve outros rounds
	var round_id: int = round_node.get_instance_id()
	loaded_maps[round_id] = map

	# Hook pré-add_child: prepara recursos antes de entrar na árvore
	_on_map_pre_add(map)

	var has_ready: bool = map.get_script() != null and map.has_method("_ready")
	round_node.add_child(map)
	_log_debug("Mapa adicionado à cena (tipo: %s, round: %s)" % [map.get_class(), round_node.name])

	if has_ready:
		var ready_waited: int = 0
		while not map.is_node_ready() and ready_waited < 120:
			await get_tree().process_frame
			ready_waited += 1
		if ready_waited >= 120:
			push_warning("Timeout aguardando _ready do mapa.")
	else:
		await get_tree().process_frame
		await get_tree().process_frame

	# Hook pós-ready: câmera configurada com o nó já na árvore e pronto
	_on_map_ready(map, actual_camera)

	is_loading = false
	_log_debug("✓ Mapa '%s' carregado para round '%s'" % [map_scene_path.get_file(), round_node.name])
	return true

# ===== CONFIGURAÇÃO PÓS-CARREGAMENTO =====

## round_node opcional: se fornecido, configura o mapa daquele round específico.
## Se null, usa o último mapa carregado.
func apply_map_configs(settings: Dictionary = {}, round_node: Node = null) -> bool:
	var map: Node = get_map_for(round_node)
	if not map:
		push_error("apply_map_configs: Nenhum mapa encontrado%s." % \
			(" para '%s'" % round_node.name if round_node else ""))
		return false

	if not map.is_node_ready():
		await map.ready

	# Hook: cliente aplica sky/fog; servidor ignora
	_on_apply_visual_configs(map, settings)

	await get_tree().process_frame

	if settings.has("spawn_points"):
		spawn_points = settings["spawn_points"]

	spawn_points_ready.emit(spawn_points.size())

	if map.has_method("configure"):
		map.configure(settings)

	map_settings = settings.duplicate()
	_log_debug("✓ Configs aplicadas: %d spawn points" % spawn_points.size())
	map_loaded.emit(map)
	return true

# ===== HOOKS VIRTUAIS =====

## Chamado após instantiate(), ANTES de add_child().
## Cliente: duplica recursos e materiais.
func _on_map_pre_add(_map: Node) -> void:
	pass

## Chamado APÓS add_child() e após o nó estar pronto na árvore.
## Pós-ready: câmera configurada agora que o nó está na árvore e pronto.
## Terrain3D exige que set_camera seja chamado com o nó já em _physics_process.
func _on_map_ready(map: Node, camera: Camera3D) -> void:
	if camera != null and map.has_method("set_camera"):
		map.set_physics_process(false)
		map.set_camera(camera)
		map.set_physics_process(true)

## Chamado no início de apply_map_configs().
## Cliente: aplica sky, fog, nuvens, exposição.
func _on_apply_visual_configs(_map: Node, _settings: Dictionary) -> void:
	pass

# ===== QUERIES =====

## Retorna o mapa do round_node fornecido, ou o último carregado se null.
func get_map_for(round_node: Node = null) -> Node:
	if round_node == null:
		return loaded_maps.values().back() if not loaded_maps.is_empty() else null
	return loaded_maps.get(round_node.get_instance_id(), null)

func is_map_loaded(round_node: Node = null) -> bool:
	var map := get_map_for(round_node)
	return map != null and is_instance_valid(map)

func get_current_map() -> Node:
	return current_map

# ===== LOG =====

func _log_debug(message: String) -> void:
	if not debug_mode:
		return
	if initializer and initializer.activate_only_selected and not "MapManager" in initializer.selected:
		return
	var tag: String = "[SERVER]" if is_server else "[CLIENT]"
	print("%s[MapManager] %s" % [tag, message])
