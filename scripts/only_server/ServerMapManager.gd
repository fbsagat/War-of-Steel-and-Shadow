extends MapManager
class_name ServerMapManager

## ServerMapManager - Lógica exclusiva do servidor
## Implementa criação e gerenciamento de spawn points.
## Não contém nenhum código visual ou de renderização.

# ===== CONFIGURAÇÕES DE SPAWN =====

@export_category("Spawn Settings")
@export var spawn_radius: float = 3.0
@export var spawn_height: float = 0.0
@export var spawn_center: Vector3 = Vector3.ZERO
@export var central_spawn: Node3D = null
@export var position_variance: float = 4.0
@export var rotation_variance: float = 0.2

# ===== VARIÁVEIS INTERNAS =====

var used_spawn_indices: Array = []

# ===== SPAWN POINTS =====

func _create_spawn_points(players: Array) -> Dictionary:
	return create_spawn_points(players)

func create_spawn_points(players: Array) -> Dictionary:
	if not current_map:
		push_error("create_spawn_points: Nenhum mapa carregado.")
		return {}

	spawn_points.clear()

	var central = current_map.get_node_or_null("central_spawn") as Node3D
	if central:
		spawn_center = central.global_position

	var count: int = clamp(players.size(), 1, 14)

	if count == 1:
		spawn_points[players[0]["uuid_base"]] = {
			"position": spawn_center + Vector3(0, spawn_height, spawn_radius),
			"rotation": Vector3(0, PI, 0)
		}
		_log_debug("✓ Spawn único criado no centro")
		spawn_points_ready.emit(spawn_points.size())
		return spawn_points

	for i in range(count):
		var angle: float = (i * 2.0 * PI) / count
		var pos: Vector3 = spawn_center + Vector3(
			cos(angle) * spawn_radius + randf_range(-position_variance, position_variance),
			spawn_height,
			sin(angle) * spawn_radius + randf_range(-position_variance, position_variance)
		)
		var to_center: Vector3 = spawn_center - pos
		var rot_y: float = atan2(to_center.x, to_center.z) + randf_range(-rotation_variance, rotation_variance)

		spawn_points[players[i]["uuid_base"]] = {
			"position": pos,
			"rotation": Vector3(0, rot_y, 0)
		}

	_log_debug("✓ %d spawn points criados (raio: %.1f)" % [spawn_points.size(), spawn_radius])
	spawn_points_ready.emit(spawn_points.size())
	return spawn_points

func get_spawn_data(player_index: int) -> Dictionary:
	if spawn_points.is_empty():
		return { "position": Vector3.ZERO, "rotation": Vector3.ZERO }
	var idx: int = player_index % spawn_points.size()
	used_spawn_indices.append(idx)
	return spawn_points[idx].duplicate()

func get_spawn_position(player_index: int) -> Variant:
	if spawn_points.is_empty():
		push_warning("get_spawn_position: Nenhum spawn disponível!")
		return Vector3.ZERO
	var idx: int = player_index % spawn_points.size()
	used_spawn_indices.append(idx)
	_log_debug("Spawn retornado: índice %d" % idx)
	return spawn_points[idx]["position"]

func get_random_unused_spawn() -> Dictionary:
	if spawn_points.is_empty():
		return { "position": Vector3.ZERO, "rotation": Vector3.ZERO }

	var available: Array = range(spawn_points.size()).filter(func(i): return i not in used_spawn_indices)
	if available.is_empty():
		used_spawn_indices.clear()
		available = range(spawn_points.size())

	var idx: int = available[randi() % available.size()]
	used_spawn_indices.append(idx)
	return spawn_points[idx].duplicate()

func reset_spawn_tracking() -> void:
	used_spawn_indices.clear()
	_log_debug("Spawn tracking resetado")

func get_spawn_count() -> int:
	return spawn_points.size()

func get_settings() -> Dictionary:
	return map_settings.duplicate()
