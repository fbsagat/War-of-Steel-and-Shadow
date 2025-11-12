extends Node
## MapManager - Gerenciador de mapas e spawns
## Responsável por carregar/descarregar mapas e gerenciar pontos de spawn

# ===== CONFIGURAÇÕES =====

@export var debug_mode: bool = false

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

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	_log_debug("MapManager criado")
	name = "MapManager"  # Nome fixo para fácil localização

# ===== CARREGAMENTO DE MAPA =====

## Carrega um mapa a partir do caminho da cena
func load_map(map_scene_path: String, settings: Dictionary = {}):
	"""Carrega um mapa a partir do caminho da cena. 
	_handle_start_round no ServerManager é quem envia informações(settings) para cá"""
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
		
	current_map.seed_geracao = settings.get("map_seed")
	current_map.preencher_etapas(settings.get("preencher_etapas", []))
	current_map.tamanho_mapa = settings.get("map_size")
	current_map.get_node("Sky3D").current_time = settings.get("env_current_time")
	
	# Adiciona o mapa à cena
	get_tree().root.add_child(current_map)
	
	# Aguarda um frame para garantir que tudo foi adicionado à árvore
	await get_tree().process_frame
	
	# Map settings exemplo: { "map_seed": 247178, 
	#"map_preencher_etapas": [{ "nome": "Etapa 1", "tipo_relevo": "Semi-Flat", "percentual_distancia": 30 },
	# { "nome": "Etapa 2", "tipo_relevo": "Gentle Hills", "percentual_distancia": 30 }, 
	# { "nome": "Etapa 3", "tipo_relevo": "Rolling Hills", "percentual_distancia": 20 }, 
	# { "nome": "Etapa 4", "tipo_relevo": "Valleys", "percentual_distancia": 20 }],
	#  "map_size": (20, 20), "env_current_time": 12.0, "match_players_count": 1 }
	
	# Encontra os pontos de spawn
	var points = _find_spawn_points()
	#var points = _create_spawn_points(settings["match_players_count"])
	#print("match_players_count: ", settings["match_players_count"])
	#print(points)
	
	#_find_spawn_points retorna: [{ "position": (0.0, 1.214169, 1.362243), "rotation": (0.0, 0.0, 0.0) }, { "position": (-2.935883, 1.16964, -0.124041), "rotation": (0.0, 0.0, 0.0) }, { "position": (0.0, 1.459608, -1.695891), "rotation": (0.0, 0.0, 0.0) }, { "position": (1.791235, 1.485599, -0.386114), "rotation": (0.0, 0.0, 0.0) }]
	
	# Aplica configurações ao mapa (se o mapa tiver método configure)
	if current_map.has_method("configure"):
		current_map.configure(settings)
	
	_log_debug("✓ Mapa carregado com sucesso: %d spawn points encontrados" % spawn_points.size())
	
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
	_log_debug("✓ Mapa descarregado")

# ===== GERENCIAMENTO DE SPAWN POINTS =====




## Encontra todos os pontos de spawn no mapa
func _find_spawn_points():
	spawn_points.clear()
	used_spawn_indices.clear()
	
	if current_map == null:
		return
	
	# Busca por nós no grupo "spawn_point"
	var spawns = get_tree().get_nodes_in_group("spawn_point")
	
	if spawns.is_empty():
		push_warning("Nenhum spawn point encontrado no mapa! Adicione nós ao grupo 'spawn_point'")
		# Cria um spawn point padrão na origem
		spawn_points.append({
		"position": Vector3.ZERO,
		"rotation": Vector3.ZERO})
	else:
		# Ordena spawns por nome para consistência
		spawns.sort_custom(func(a, b): return a.name < b.name)
		
		for spawn in spawns:
			var spawn_data = {
				"position": spawn.global_position,
				"rotation": spawn.rotation if spawn is Node3D else spawn.rotation
			}
			spawn_points.append(spawn_data)
	
	#print("spawn_points: ", spawn_points)
	_log_debug("Spawn points criados com base na quantidade de jogadores: %d" % spawn_points.size())
	spawn_points_ready.emit(spawn_points.size())
	return spawn_points



func _create_spawn_points(match_players_count: int) -> Array:
	"""
	Gera pontos de spawn simulados com base no número de jogadores.
	Não depende de nodes filhos - gera posições dinamicamente.
	"""
	
	# Configurações de spawn
	var spawn_radius: float = 30.0  # Distância do centro
	var spawn_height: float = 2.0   # Altura acima do chão
	var spawn_center: Vector3 = Vector3.ZERO  # Centro do mapa
	
	# Gera um ponto de spawn para cada jogador
	for i in range(match_players_count):
		# Distribui os jogadores em círculo ao redor do centro
		var angle = (i * 2.0 * PI) / match_players_count
		var x = cos(angle) * spawn_radius
		var z = sin(angle) * spawn_radius
		var y = spawn_height
		
		# Rotação apontando para o centro
		var rotation_y = angle + PI  # + PI para apontar para o centro
		
		var spawn_data = {
			"position": Vector3(x, y, z),
			"rotation": Vector3(0, rotation_y, 0)
		}
		
		spawn_points.append(spawn_data)
	
	# Se não houver jogadores, adiciona um ponto no centro
	if match_players_count == 0:
		spawn_points.append({
			"position": Vector3(0, spawn_height, 0),
			"rotation": Vector3.ZERO
		})
	_log_debug("Spawn points criados com base na quantidade de jogadores: %d" % spawn_points.size())
	spawn_points_ready.emit(spawn_points.size())
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

func _log_debug(message: String):
	if debug_mode:
		print("[MapManager] " + message)
