extends Node
class_name MapManager

## MapManager - Gerenciador de mapas e spawns
## Responsável por carregar/descarregar mapas e gerenciar pontos de spawn

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = true
@export var is_server: bool = false

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

# ===== VARIÁVEIS INTERNAS =====

## Referência ao mapa carregado atualmente
var current_map: Node = null

## Lista de pontos de spawn encontrados no mapa
var spawn_points: Array = []

## Índices de spawn já utilizados (para evitar sobreposição)
var used_spawn_indices: Array = []

## Configurações do mapa atual
var map_settings: Dictionary = {}

# ===== SINAIS =====

signal map_loaded(map_node: Node)
signal map_unloaded()
signal spawn_points_ready(count: int)

# ===== CARREGAMENTO DE MAPA =====

## Carrega um mapa a partir do caminho da cena
func load_map(map_scene_path: String, round_node, settings: Dictionary = {}):
	"""Carrega um mapa a partir do caminho da cena. 
	_handle_start_round no ServerManager é quem envia informações(settings) para cá"""
	print("[111]load_map! executado!")
	if current_map != null:
		_log_debug("Já existe um mapa carregado. Descarregando primeiro...")
		unload_map()
	
	_log_debug("Carregando mapa: %s" % map_scene_path)
	map_settings = settings
	
	# Carrega a cena do mapa
	var map_scene = load(map_scene_path)
	if map_scene == null:
		push_error("Falha ao carregar mapa: %s" % map_scene_path)
		return false
	
	# Instancia o mapa
	current_map = map_scene.instantiate()
	if current_map == null:
		push_error("Falha ao instanciar mapa")
		return false
	
	# Aplicar configurações do Terrain3D
	# Gerar um terreno novo com as configurações compartilhadas
	
	# Aplicar configurações do Sky3D
	apply_sky_configs(current_map.get_node("Sky3D"), settings.get("sky_rand_configs"))
	
	# Adiciona o mapa à cena
	round_node.add_child(current_map)
	
	# Aguarda um frame para garantir que tudo foi adicionado à árvore
	await get_tree().process_frame
	
	# Encontra os pontos de spawn
	print("[111]spawn_points atual: ", spawn_points)
	spawn_points = settings["spawn_points"]
	spawn_points_ready.emit(spawn_points.size())
	print("[111]spawn_points atual: ", spawn_points)
	
	# Aplica configurações ao mapa (se o mapa tiver método configure)
	if current_map.has_method("configure"):
		current_map.configure(settings)
	
	_log_debug(" Mapa carregado com sucesso: %d spawn points encontrados" % spawn_points.size())
	
	map_loaded.emit(current_map)
	return true

## Remove o mapa atual da cena
func unload_map():
	if current_map == null:
		return
	
	_log_debug("Descarregando mapa...")
	
	# Remove o mapa da árvore
	current_map.queue_free()
	current_map = null
	
	# Limpa arrays
	spawn_points.clear()
	used_spawn_indices.clear()
	map_settings = {}
	
	map_unloaded.emit()
	_log_debug(" Mapa descarregado")

# ===== GERENCIAMENTO DE SPAWN POINTS =====

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
	return current_map != null

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
		push_error("❌ Sky3D nulo ou configurações vazias!")
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
	
	_log_debug("✓ Configurações aplicadas!")

func _log_debug(message: String):
	if debug_mode:
		var server: String = "[SERVER]" if is_server else "[CLIENT]"
		print("%s[MapManager]%s" % [server, message])
