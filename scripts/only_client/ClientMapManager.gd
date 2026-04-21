extends MapManager
class_name ClientMapManager

## ClientMapManager - Lógica exclusiva do cliente
## Implementa os hooks visuais e utilitários de cena que o servidor não executa.

# ===== HOOKS =====

## Pré-add_child: apenas preparação de recursos, sem câmera.
func _on_map_pre_add(map: Node) -> void:
	_make_resources_unique(map)

func _on_apply_visual_configs(map: Node, settings: Dictionary) -> void:
	var sky_node = map.get_node_or_null("Sky3D")
	_apply_sky_configs(sky_node, settings.get("sky_rand_configs", {}))

# ===== SKY / AMBIENTE =====

func _apply_sky_configs(sky_node: Node, config: Dictionary) -> void:
	if sky_node == null or config.is_empty():
		if sky_node == null:
			_log_debug("Sky3D não encontrado, pulando configuração de céu.")
		return

	var time_node = sky_node.get_node_or_null("TimeOfDay")
	var sky_dome  = sky_node.get_node_or_null("SkyDome")
	var env_node  = sky_node.get_node_or_null("Environment")

	if config.has("time") and time_node:
		if "current_time" in time_node: time_node.current_time = config["time"]["current_time"]
		if "day_duration" in time_node: time_node.day_duration  = config["time"]["day_duration"]
		if "auto_advance" in time_node: time_node.auto_advance  = config["time"]["auto_advance"]
		if "time_scale"   in time_node: time_node.time_scale    = config["time"]["time_scale"]

	if config.has("sky") and sky_dome:
		var sky = config["sky"]
		if "sky_contribution"     in sky_dome: sky_dome.sky_contribution     = sky.get("sky_contribution", 1.0)
		if "rayleigh_coefficient" in sky_dome: sky_dome.rayleigh_coefficient = sky.get("rayleigh_coefficient", 1.0)
		if "mie_coefficient"      in sky_dome: sky_dome.mie_coefficient      = sky.get("mie_coefficient", 0.01)
		if "turbidity"            in sky_dome: sky_dome.turbidity             = sky.get("turbidity", 2.0)
		if "sky_top_color"        in sky_dome: sky_dome.sky_top_color        = sky.get("sky_color", Color.WHITE)
		if "sky_horizon_color"    in sky_dome: sky_dome.sky_horizon_color    = sky.get("horizon_color", Color.WHITE)

	if config.has("fog") and env_node and env_node.environment:
		var fog = config["fog"]
		env_node.environment.fog_enabled        = fog.get("enabled", false)
		env_node.environment.fog_density        = fog.get("density", 0.01)
		env_node.environment.fog_light_color    = fog.get("color", Color.WHITE)
		env_node.environment.fog_height         = fog.get("height", 0.0)
		env_node.environment.fog_height_density = fog.get("height_density", 0.0)

	if config.has("clouds") and sky_dome:
		var clouds = config["clouds"]
		if "clouds_coverage"   in sky_dome: sky_dome.clouds_coverage   = clouds.get("coverage", 0.5)
		if "clouds_size"       in sky_dome: sky_dome.clouds_size        = clouds.get("size", 1.0)
		if "clouds_speed"      in sky_dome: sky_dome.clouds_speed       = clouds.get("speed", 0.1)
		if "clouds_direction"  in sky_dome: sky_dome.clouds_direction   = clouds.get("wind_direction", 0.0)
		if "clouds_opacity"    in sky_dome: sky_dome.clouds_opacity     = clouds.get("opacity", 1.0)
		if "clouds_brightness" in sky_dome: sky_dome.clouds_brightness  = clouds.get("brightness", 1.0)
		if "clouds_color"      in sky_dome: sky_dome.clouds_color       = clouds.get("color", Color.WHITE)

	if config.has("exposure") and env_node and env_node.environment:
		env_node.environment.tonemap_exposure = config["exposure"].get("exposure", 1.0)
		env_node.environment.tonemap_white    = config["exposure"].get("white_point", 8.0)

	if config.has("ambient") and env_node and env_node.environment:
		env_node.environment.ambient_light_sky_contribution = 1.0
		env_node.environment.ambient_light_color = config["ambient"].get("sky_color", Color.WHITE)

	_log_debug("✓ Configurações de céu aplicadas!")

# ===== RECURSOS ÚNICOS =====

func _make_resources_unique(node: Node) -> void:
	for child in node.get_children():
		_make_resources_unique(child)

	if node is MeshInstance3D and node.material_override:
		node.material_override = node.material_override.duplicate(true)

	if node.has_method("get_data") and node.has_method("set_data"):
		var data = node.get("data")
		if data:
			node.set("data", data.duplicate(true))

# ===== UTILITÁRIOS DE CENA =====

func find_map_node(node_name: String, round_node: Node = null) -> Node:
	var map := get_map_for(round_node)
	if map == null:
		return null
	return map.find_child(node_name, true, false)

func find_map_nodes_in_group(group_name: String, round_node: Node = null) -> Array:
	var map := get_map_for(round_node)
	if map == null:
		return []
	return map.get_children().filter(func(n): return n.is_in_group(group_name))

func get_settings() -> Dictionary:
	return map_settings.duplicate()
