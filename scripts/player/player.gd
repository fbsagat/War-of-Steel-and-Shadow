extends CharacterBody3D

# Configs
@export_category("Debug")
@export var debug: bool = false

@export_category("Movement")
@export var max_speed: float = 5
@export var walking_speed: float = 2.0
@export var run_multiplier: float = 1.5
@export var jump_velocity: float = 8.0
@export var acceleration: float = 8.0   # Quão rápido acelera
@export var deceleration: float = 8.0  # Quão rápido para ao soltar o input
@export var bobbing_intensity: float = 0.6
@export var turn_speed: float = 8.0
@export var air_control: float = 1.2
@export var air_friction: float = 0.01
@export var preserve_run_on_jump: bool = true
@export var gravity: float = 20.0
@export var enemy_tracking_turn_speed: float = 2.0
@export var aiming_jump_multiplyer: float = 4.2

@export_category("Player actions")
@export var hide_itens_on_start: bool = true
@export var pickup_radius: float = 1.2
@export var pickup_collision_mask: int = 1 << 2
@export var max_pick_results: int = 8
@export var drop_distance: float = 1.2
@export var drop_force: float = 4.0

@export_category("Enemy detection")
@export var detection_radius_fov: float = 14.0      # Raio para detecção no FOV
@export var detection_radius_360: float = 6.0       # Raio menor (ou maior) para fallback 360°
@export_range(0, 360) var field_of_view_degrees: float = 120.0
@export var use_360_vision_as_backup: bool = true  # Ativa a visão 360° como fallback
@export var update_interval: float = 0.5  # atualização a cada X segundos (0 = cada frame)

# Estados
var is_attacking: bool = false
var is_defending: bool = false
var is_jumping: bool = false
var is_aiming: bool = false
var is_running: bool = false
var current_item_right_id: int
var current_item_left_id: int
var current_helmet_item_id: int
var current_cape_item_id: int
var current_attack_item_id: int
var mouse_mode: bool = true
var run_on_jump: bool = false
var nearest_enemy: CharacterBody3D = null
var _detection_timer: Timer = null
var last_simple_directions: Array = []
var is_block_attacking: bool = false
var sword_areas: Array[Area3D] = []
const MAX_DIRECTION_HISTORY = 2

@export_category("Network")
@export var sync_rate: float = 0.05

var player_id: int = 0
var player_name: String = ""
var is_local_player: bool = false
var sync_timer: float = 0.0

# referências
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var attack_timer: Timer = $attack_timer
@onready var CameraController: Node3D
@onready var name_label: Label3D = $NameLabel

# Dinâmicas
var model: Node3D = null
var skeleton: Skeleton3D = null
var damaged_entities = []
var aiming_forward_direction: Vector3 = Vector3.FORWARD
var defense_target_angle: float = 0.0
var _item_data: Array[Dictionary] = []
var hit_targets: Array = []
var cair: bool = false

# Ready
func _ready():
	# Carrega dados de itens na memória
	_load_item_data()
	
	# Connect do Timer (attack_timer)
	attack_timer.timeout.connect(Callable(self, "_on_attack_timer_timeout"))
	
	# Aplicador de tempo de detecção do inimigo
	enemy_detection_timer()
	
	# Gerenciador de hitboxes
	hitboxes_manager()
	
	add_to_group("player")
	
	# visibilidade inicial (modelo)
	if hide_itens_on_start:
		_hide_all_model_items()

# Física geral
func _physics_process(delta):
		var move_dir: Vector3
		_handle_gravity(delta)
		handle_test_equip_inputs()
		
		# Só processa input se for o jogador local
		if is_multiplayer_authority():
			move_dir = _handle_movement_input(delta)
			_send_state_to_network(delta)
	
		_handle_animations(move_dir)
		move_and_slide()
		

func _process(delta: float) -> void:
	if is_aiming and nearest_enemy:
		# 1. Vetor do jogador para o inimigo
		var to_enemy = nearest_enemy.global_transform.origin - global_transform.origin
		# 2. Projeta no plano horizontal (ignora Y)
		var flat_dir = Vector3(to_enemy.x, 0, to_enemy.z)
		# 3. Calcula o ângulo Y (em radianos) dessa direção
		var target_angle = atan2(flat_dir.x, flat_dir.z)  # ← isso é o "45 graus" dinâmico
		# 4. Gira suavemente para esse ângulo
		rotation.y = lerp_angle(rotation.y, target_angle, turn_speed * delta)
		# 5. Atualiza aiming_forward_direction para uso no movimento
		aiming_forward_direction = Vector3(cos(target_angle), 0, sin(target_angle)).normalized()
	else:
		if not is_aiming:
			aiming_forward_direction = Vector3(-global_transform.basis.z.x, 0, -global_transform.basis.z.z).normalized()

	# Atualiza detecção contínua de inimigos (se aplicável)
	if update_interval <= 0.0:
		_update_nearest_enemy()
	
	# Armazena a direção atual para o modo mira
	if is_aiming:
		var dir = _get_current_direction()
		# Se for uma direção simples (não diagonal), atualiza o histórico
		if dir in ["forward", "backward", "left", "right"]:
			if last_simple_directions.is_empty() or last_simple_directions[-1] != dir:
				last_simple_directions.append(dir)
				if last_simple_directions.size() > MAX_DIRECTION_HISTORY:
					last_simple_directions.pop_front()
		# Diagonais NÃO entram no histórico (são usadas imediatamente no ataque)

func set_as_local_player():
	"""Configura este player como o jogador local"""
	is_local_player = true

func initialize(p_id: int, p_name: String, spawn_pos: Vector3):
	"""Inicializa o player com dados multiplayer"""
	player_id = p_id
	player_name = p_name
	
	# Nome do nó = ID do player (importante para sincronização)
	name = str(player_id)
	
	# Posiciona no spawn
	global_position = spawn_pos
	
	# Atualiza label de nome
	if name_label:
		name_label.text = player_name
	
	# Define autoridade multiplayer
	set_multiplayer_authority(player_id)
	
	# Ativa processos
	set_physics_process(true)
	set_process(true)

func hitboxes_manager():
	# Conecta todos os hitboxes de ataque
	var all_areas = find_children("*", "Area3D", true)
	var hitboxes = all_areas.filter(func(n): return n.is_in_group("hitboxes"))
	for area in hitboxes:
		if area.is_queued_for_deletion() or not area.is_inside_tree():
			continue
		if not area.is_connected("body_entered", Callable(self, "_on_hitbox_body_entered")):
			area.connect("body_entered", Callable(self, "_on_hitbox_body_entered").bind(area))
			area.monitoring = false

# 1. Funções para requisição de itens do modelo
func _load_item_data():
	var file = FileAccess.open("res://scripts/utils/model_map.json", FileAccess.READ)
	if file:
		var json_text = file.get_as_text()
		file.close()
		var json = JSON.new()
		var parse_result = json.parse(json_text)
		if parse_result == OK:
			var raw_data = json.get_data()
			# Corrige os IDs para inteiros
			_item_data.clear()
			for entry in raw_data:
				var fixed_entry = entry.duplicate(true)  # deep copy
				if fixed_entry.has("id"):
					fixed_entry["id"] = int(fixed_entry["id"])
				_item_data.append(fixed_entry)
		else:
			push_error("Erro ao fazer parse do model_map.json: " + str(json.get_error_line()))
	else:
		push_error("Não foi possível abrir model_map.json")

# 1.1. Retorna o item completo pelo ID
func _get_item_by_id(p_id: int) -> Dictionary:
	for item in _item_data:  # ✅ Corrigido: _item_data
		if item.has("id") and item["id"] == p_id:
			return item.duplicate()
	return {}

# 1.2. Retorna uma lista de IDs com base em um filtro
func _get_item_ids_by_filter(p_key: String, p_value) -> Array[int]:
	var ids: Array[int] = []
	for item in _item_data:
		if item.has(p_key) and item[p_key] == p_value:
			ids.append(item["id"])
	return ids

# 1.3. Retorna o Node referenciado por ID
func _get_node_by_id(p_id: int) -> Node:
	var item = _get_item_by_id(p_id)
	if item.is_empty():
		push_error("Item com ID %d não encontrado." % p_id)
		return null

	var node_path = item["node_link"]
	if node_path.is_empty():
		push_error("node_link vazio para ID %d." % p_id)
		return null

	var current_scene = $"."
	if current_scene:
		var node = current_scene.get_node_or_null(node_path)
		if node:
			return node
		else:
			push_error("Nó não encontrado no caminho: %s" % node_path)
			return null
	else:
		push_error("Cena atual não disponível.")
		return null

# 1.4. Retorna todos os itens IDs do player
func _get_all_item_ids():
	var ids: Array[int] = []
	for item in _item_data:
		ids.append(item["id"])
	return ids

# 1.5. Retorna todos os nodes do player
func _get_all_item_nodes(list: Array = []) -> Array:
	var nodes: Array = []
	var ids_to_use: Array
	
	# Se a lista vier vazia ou não for passada, pega todos os IDs
	if list.is_empty():
		ids_to_use = _get_all_item_ids()
	else:
		ids_to_use = list
	
	for id in ids_to_use:
		var node = _get_node_by_id(id)
		if node:
			nodes.append(node)
		else:
			push_warning("Nó não encontrado para ID: %s" % str(id))
	
	if debug:
		print("get_all_item_nodes: %d nós encontrados: %s" % [len(nodes), nodes])
	
	return nodes

# 1.6. Retorna o item_name correspondente a um ID (ou lista de IDs)
func _get_item_name_by_id(p_id) -> Variant:
	# caso único: ID individual
	if typeof(p_id) == TYPE_INT:
		for item in _item_data:
			if item.get("id", -1) == p_id:
				return item.get("item_name", "")
		push_error("get_item_name_by_id: ID %d não encontrado." % p_id)
		return null

	# caso lista: retornar lista de nomes
	if typeof(p_id) == TYPE_ARRAY:
		var names: Array = []
		for id in p_id:
			if typeof(id) == TYPE_INT:
				var found := false
				for item in _item_data:
					if item.get("id", -1) == id:
						names.append(item.get("item_name", ""))
						found = true
						break
				if not found:
					push_warning("get_item_name_by_id: ID %s não encontrado." % str(id))
					names.append(null)
			else:
				push_warning("get_item_name_by_id: tipo inválido na lista: %s" % str(id))
				names.append(null)
		return names

	# tipo inválido
	push_error("get_item_name_by_id: tipo inválido para p_id: %s (esperado int ou Array)" % str(typeof(p_id)))
	return null

# 1.6. Retorna o Id pelo node
func _get_id_by_node(p_node: Node) -> int:
	if p_node == null:
		push_error("Node fornecido é nulo.")
		return -1  # retorna -1 para indicar "não encontrado"

	for item in _item_data:
		if item.has("node_link"):
			var node_path = item["node_link"]
			if node_path != "":
				var current_scene = $"."
				if current_scene:
					var node_in_scene = current_scene.get_node_or_null(node_path)
					if node_in_scene == p_node:
						return item.get("id", -1)  # retorna ID ou -1 se não tiver
				else:
					push_error("Cena atual não disponível.")
					return -1
	# Se nenhum item corresponde ao node
	push_error("Nenhum item corresponde ao Node fornecido: %s" % p_node.name)
	return -1

# Retorna item mais próximos do player
func _get_nearby_items(radius: float = pickup_radius, _collision_mask: int = pickup_collision_mask, max_results: int = max_pick_results) -> Array:
	var space_state = get_world_3d().direct_space_state
	var shape = SphereShape3D.new()
	shape.radius = radius
	var params = PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D.IDENTITY.translated(global_transform.origin)
	params.collision_mask = _collision_mask
	params.collide_with_bodies = true
	params.collide_with_areas = true
	var results: Array = space_state.intersect_shape(params, max_results)
	var items: Array = []
	if debug:
		print("--- intersect_shape results:", results.size())
	for r in results:
		var body = r.collider
		if body == null: continue
		if body == self: continue
		if debug:
			print(" -> collider:", body.name, " type:", body.get_class())
		if body.is_in_group("item"):
			items.append(body); continue
		if body.has_method("pick_up"):
			items.append(body); continue
		var maybe_name = body.get("item_name")
		if maybe_name != null:
			items.append(body); continue
	items.sort_custom(Callable(self, "_sort_by_distance"))
	if debug: print(" -> items filtrados:", items.size())
	return items

# Pega o nó da câmera
func _get_camera_controller() -> Node3D:
	var camera_list = get_tree().get_nodes_in_group("camera_controller")
	if not camera_list.is_empty():
		return camera_list[0]
	var root = get_tree().root
	if root.has_node("CameraController"):
		return root.get_node("CameraController")
	return null

# Funções da câmera livre
func _get_movement_direction_free_cam() -> Vector3:
	var camera := _get_camera_controller()
	if camera and camera.is_inside_tree():
		var cam_basis := camera.global_transform.basis
		var cam_forward := (-cam_basis.z).normalized()
		cam_forward.y = 0.0
		var cam_right := Vector3.UP.cross(cam_forward).normalized()
		var input_vec := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if input_vec.length() > 0.1:
			return (cam_forward * input_vec.y + cam_right * input_vec.x).normalized()
	else:
		if debug:
			print("[Player] Câmera não disponível. Usando eixos fixos.")
		var world_input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if world_input.length() > 0.1:
			return Vector3(-world_input.x, 0.0, world_input.y).normalized()
	return Vector3.ZERO
	
# Funções da câmera lockada
func _get_movement_direction_locked() -> Vector3:
	var input_vec := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	if input_vec.length() <= 0.1:
		return Vector3.ZERO

	# ✅ Usa a FRENTE ATUAL DO CORPO (não aiming_forward_direction)
	var forward = Vector3(-global_transform.basis.z.x, 0, -global_transform.basis.z.z).normalized()
	var right = Vector3.UP.cross(forward).normalized()

	# ✅ Input: Y = para frente/trás, X = strafe
	return (forward * input_vec.y + right * input_vec.x).normalized()

# Configura timer para atualização periódica de inimigos próximos
func enemy_detection_timer():
	if update_interval > 0.0:
		_detection_timer = Timer.new()
		_detection_timer.wait_time = update_interval
		_detection_timer.autostart = true
		_detection_timer.one_shot = false
		add_child(_detection_timer)
		_detection_timer.timeout.connect(_update_nearest_enemy)
	else:
		# Atualiza a cada frame via _process/_physics_process
		pass

func get_nearest_enemy() -> CharacterBody3D:
	var space_state = get_world_3d().direct_space_state
	var closest_in_fov: CharacterBody3D = null
	var closest_in_fov_dist_sq: float = INF

	var closest_in_360: CharacterBody3D = null
	var closest_in_360_dist_sq: float = INF

	var enemies = get_tree().get_nodes_in_group("enemies")
	if enemies.is_empty():
		return null

	var player_pos = global_transform.origin
	var player_forward = Vector3(global_transform.basis.z.x, 0, global_transform.basis.z.z).normalized()

	for enemy in enemies:
		if not enemy is CharacterBody3D or not enemy.is_inside_tree():
			continue

		var enemy_pos = enemy.global_transform.origin
		var to_enemy = enemy_pos - player_pos
		var dist_sq = to_enemy.length_squared()

		# --- Verificação de linha de visão (raycast) ---
		var query = PhysicsRayQueryParameters3D.new()
		query.from = player_pos
		query.to = enemy_pos
		query.collision_mask = 1
		query.exclude = [self]

		var result = space_state.intersect_ray(query)
		if result and result.collider != enemy:
			continue  # Obstáculo bloqueando

		# --- Verificação para FOV ---
		var in_fov = false
		if field_of_view_degrees >= 360.0:
			in_fov = true
		else:
			var to_enemy_flat = Vector3(to_enemy.x, 0, to_enemy.z).normalized()
			if to_enemy_flat.length_squared() >= 0.001:
				var angle_to_enemy = player_forward.angle_to(to_enemy_flat)
				if angle_to_enemy <= deg_to_rad(field_of_view_degrees / 2.0):
					in_fov = true

		# --- Atualiza candidato no FOV (se dentro do raio FOV) ---
		if in_fov and dist_sq <= detection_radius_fov * detection_radius_fov:
			if dist_sq < closest_in_fov_dist_sq:
				closest_in_fov_dist_sq = dist_sq
				closest_in_fov = enemy

		# --- Atualiza candidato em 360° (se dentro do raio 360°) ---
		if dist_sq <= detection_radius_360 * detection_radius_360:
			if dist_sq < closest_in_360_dist_sq:
				closest_in_360_dist_sq = dist_sq
				closest_in_360 = enemy

	# --- Prioridade: FOV primeiro ---
	if closest_in_fov != null:
		if debug:
			print("Inimigo mais próximo (FOV): ", closest_in_fov)
		return closest_in_fov

	# --- Fallback: 360° (se ativado e dentro do raio menor) ---
	if use_360_vision_as_backup and closest_in_360 != null:
		if debug:
			print("Inimigo mais próximo (360° fallback): ", closest_in_360)
		return closest_in_360

	if debug:
		print("Nenhum inimigo detectado.")
	return null

func _update_nearest_enemy() -> void:
	nearest_enemy = get_nearest_enemy()

func _on_node_visibility_changed() -> void:
	cair = true
	
# Gravidade
func _handle_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		if velocity.y < 0:
			velocity.y = 0
		if is_jumping:
			is_jumping = false

# Animações
func _handle_animations(move_dir):
	var speed = Vector2(velocity.x, velocity.z).length()
	#var input_dir = Vector2(velocity.x, velocity.z).normalized()
	if is_aiming:
		pass
		# Com strafe_mode (FALTA FAZER A ANIMAÇÃO) por enquanto essa \/
		animation_tree["parameters/Locomotion/blend_position"] = speed
	else:
		# Sem strafe_mode
		animation_tree["parameters/Locomotion/blend_position"] = speed
	
	# Bobbing
	if move_dir.length() > 0.1:
		animation_tree["parameters/bobbing/add_amount"] = bobbing_intensity * speed
	else:
		animation_tree["parameters/bobbing/add_amount"] = 0
	
func _handle_movement_input(delta: float):
	var move_dir: Vector3
	if is_aiming:
		move_dir = _get_movement_direction_locked()
	else:
		move_dir = _get_movement_direction_free_cam()
	_apply_movement(move_dir, delta)
	return move_dir

# Movimentos para a função de escoher o movimento da espada
func _get_current_direction() -> String:
	var f = Input.is_action_pressed("move_forward")
	var b = Input.is_action_pressed("move_backward")
	var l = Input.is_action_pressed("move_left")
	var r = Input.is_action_pressed("move_right")

	# Diagonais têm prioridade
	if f and r: return "forward_right"
	if f and l: return "forward_left"
	if b and r: return "backward_right"
	if b and l: return "backward_left"
	if f: return "forward"
	if b: return "backward"
	if l: return "left"
	if r: return "right"
	return ""

# movimentos: Pulo e corrida
func _apply_movement(move_dir: Vector3, delta: float) -> void:
	# === PULO: preserva velocidade horizontal EXATA do chão ===
	if not is_aiming:
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_velocity
			is_jumping = true
			run_on_jump = Input.is_action_pressed("run")
			animation_tree["parameters/final_transt/transition_request"] = "jump_start"
			
			# Opcional: reduzir velocidade ao pular (ex: pular parado = menos inércia)
			if not preserve_run_on_jump:
				# Ex: ao pular sem correr, reduz velocidade
				if not run_on_jump:
					velocity.x *= 0.7
					velocity.z *= 0.7
			
			if debug:
				print("[Player] Pulando com velocidade XZ: (%.2f, %.2f)" % [velocity.x, velocity.z])
			return  # ←←← PRESERVA a velocidade; não recalcula movimento neste frame

		elif is_on_floor():
			is_jumping = false
			run_on_jump = false
			animation_tree["parameters/final_transt/transition_request"] = "jump_land"
			animation_tree["parameters/final_transt/transition_request"] = "walking_e_blends"
	else:
		if Input.is_action_just_pressed("jump") and is_on_floor():
			animation_tree.set("parameters/Jump_Full_Short/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			velocity.y = jump_velocity / 2.2
			is_jumping = true
		
	# === MOVIMENTO NO CHÃO ===
	if is_on_floor():
		var speed: float = max_speed
		if Input.is_action_pressed("run") and not is_aiming:
			speed *= run_multiplier
		elif Input.is_action_pressed("walking"):
			speed = walking_speed

		if move_dir.length() > 0.1:
			if not is_aiming:
				var target_angle = atan2(move_dir.x, move_dir.z)
				rotation.y = lerp_angle(rotation.y, target_angle, turn_speed * delta)

			var target_velocity = move_dir * speed
			velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta)
			velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta)
		else:
			velocity.x = lerp(velocity.x, 0.0, deceleration * delta)
			velocity.z = lerp(velocity.z, 0.0, deceleration * delta)

	# === MOVIMENTO NO AR (após o frame do pulo) ===
	else:
		# 1. Aplica atrito no ar (desaceleração suave)
		velocity.x = lerp(velocity.x, 0.0, air_friction)
		velocity.z = lerp(velocity.z, 0.0, air_friction)

		# 2. Aplica controle aéreo (se houver input)
		if move_dir.length() > 0.1 and air_control > 0.0:
			var air_speed = max_speed * air_control
			var multiplier = aiming_jump_multiplyer if is_aiming else 1.0
			velocity.x += move_dir.x * air_speed * delta * multiplier
			velocity.z += move_dir.z * air_speed * delta * multiplier


# Chama a câmera lockada e transiciona p/ movimentação strafe
func _strafe_mode(ativar : bool = true, com_camera_lock = true):
	# Falta criar a animação e implementar no handle_animations
	if ativar:
		is_aiming = true
		# ✅ SALVA A FRENTE DO JOGADOR NO MOMENTO DO TRAVAMENTO
		var cam_forward := -CameraController.global_transform.basis.z
		cam_forward.y = 0.0
		cam_forward = cam_forward.normalized()
		defense_target_angle = atan2(-cam_forward.x, -cam_forward.z)
		if com_camera_lock:
			get_tree().call_group("camera_controller", "force_behind_player")
	else:
		is_aiming = false
		get_tree().call_group("camera_controller", "release_to_free_look")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_mouse_mode()
	elif event.is_action_pressed("interact"):
		action_pick_up_item()
	elif event.is_action_pressed("attack"):
		action_sword_attack()
	elif event.is_action_pressed("lock"):
		action_lock()
	elif event.is_action_released("lock"):
		action_stop_locking()
	elif event.is_action_pressed("block_attack"):
		action_block_attack()
	elif event.is_action_pressed("drop"):
		action_drop_item()

# Mouse
func _toggle_mouse_mode():
	mouse_mode = not mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if not mouse_mode else Input.MOUSE_MODE_CAPTURED
	if debug:
		print("[Player] Mouse %s." % ("liberado" if not mouse_mode else "capturado"))
		
# Visual
func _hide_all_model_items():
	var nodes: Array = _get_all_item_nodes()
	for node in nodes:
		if node is Node and node.has_method("set_visible"):
			node.visible = false
			
# Modifica a visibilidade do item na mão do modelo e desativa hitbox (suporta Dictionary)
func _item_model_change_visibility(item: Dictionary, drop: bool = false) -> void:
	# garante que recebeu um Dictionary
	if typeof(item) != TYPE_DICTIONARY:
		push_error("_item_model_change_visibility: 'item' deve ser Dictionary.")
		return

	if debug:
		print("item_model_change_visibility: Dictionary: ", item)

	# extrai valores do dicionário (suporta "item_id" ou "id")
	var side = item.get("item_side", null)
	var itype = item.get("item_type", null)
	var id: int = item.get("item_id", item.get("id", -1))

	# validações básicas
	if side == null and itype == null:
		push_error("item_model_change_visibility: item sem 'item_side' e sem 'item_type'.")
		return
	if id == -1:
		push_error("item_model_change_visibility: id inválido no item.")
		return

	# tenta por item_side; se não achar, por item_type
	var nodes_ids := _get_item_ids_by_filter("item_side", side)
	if nodes_ids == null or nodes_ids.is_empty():
		nodes_ids = _get_item_ids_by_filter("item_type", itype)

	# esconde nós encontrados (se houver)
	if nodes_ids != null and not nodes_ids.is_empty():
		var nodes_links := _get_all_item_nodes(nodes_ids)
		if nodes_links != null:
			for node in nodes_links:
				
				# ✅ Desativa a área de dano (se existir)
				var hitbox = node.get_node_or_null("hitbox")  # ou o caminho real da sua Area3D
				if hitbox and hitbox is Area3D:
					hitbox.monitoring = false
					if debug:
						print("item ", node.name, " hitbox.monitoring: ", hitbox.monitoring)
				
				if node and node is Node:
					# trata nós 2D/3D explicitamente para setar visible com segurança
					if node is CanvasItem:
						node.visible = false
					elif node is VisualInstance3D:
						node.visible = false
					elif node.has_method("set_visible"):
						node.set_visible(false)

	# se não for drop, mostra o nó correspondente ao id atual (se existir)
	if not drop:
		var node_i := _get_node_by_id(id)
		if node_i and node_i is Node:
			if node_i is CanvasItem or node_i is VisualInstance3D:
				node_i.visible = true
			elif node_i.has_method("set_visible"):
				node_i.set_visible(true)
		else:
			push_error("item_model_change_visibility: nó com id %d não encontrado ou inválido." % id)
			
# Equipar item pelo ID
func equip_item_by_id(item_id: int, drop_last_item: bool):
	# Encontra o item correspondente pelo ID na lista global de itens
	var item_data = null
	for data in _item_data:
		if data["id"] == item_id:
			item_data = data
			break

	if item_data == null:
		if debug:
			print("equip_item_by_id: item_id não encontrado -> ", item_id)
		return

	# Extrai os campos do item
	var id: int = item_data["id"]
	var node_link: String = item_data["node_link"]
	var item_name: String = item_data["item_name"]
	var item_type: String = item_data["item_type"]
	var item_side: String = item_data["item_side"]
	
	# Define a variável de controle correta com base no tipo e lado
	match [item_type, item_side]:
		["hand", "right"]:
			if drop_last_item and current_item_right_id != 0:
				_item_drop([current_item_right_id])
			current_item_right_id = id
		["hand", "left"]:
			if drop_last_item and current_item_left_id != 0:
				_item_drop([current_item_left_id])
			current_item_left_id = id
		["head", "up"]:
			if drop_last_item and current_helmet_item_id != 0:
				_item_drop([current_helmet_item_id])
			current_helmet_item_id = id
		["body", "down"]:
			if drop_last_item and current_cape_item_id != 0:
				_item_drop([current_cape_item_id])
			current_cape_item_id = id
		_:
			if debug:
				print("equip_item_by_id: combinação tipo/lado desconhecida -> ", item_type, "/", item_side)
	if debug:
		print("equip_item_by_id: equipado ->", item_name, " em ", node_link)
	_item_model_change_visibility(_get_item_by_id(item_id))
			
# Dropar item na frente do player
func _item_drop(item_ids: Array) -> Array:
	var dropped: Array = []
	if typeof(item_ids) != TYPE_ARRAY:
		push_error("item_drop: esperado Array para item_ids.")
		return dropped
	
	# Pegar cena atual para adicionar os itens como filhos (ou use get_tree().root se preferir)
	var scene_root = $"../objects/coletaveis"
	if not scene_root:
		push_error("item_drop: cena atual não disponível para adicionar instâncias.")
		return dropped
	
	for id in item_ids:
		var item_name: String = ""
		item_name = _get_item_name_by_id(id)
		
		# Se não tiver implementado ainda, avisar e pular
		if item_name == null:
			push_warning("_item_drop: nome do item não fornecido para ID %s. Pulei." % str(id))
			dropped.append(null)
			continue

		# montar caminho da cena. espera-se arquivos .tscn em res://scenes/collectibles/
		var scene_path := "res://scenes/collectibles/%s.tscn" % item_name
		var packed := ResourceLoader.load(scene_path)
		if not packed or not (packed is PackedScene):
			push_error("_item_drop: não foi possível carregar PackedScene: %s" % scene_path)
			dropped.append(null)
			continue

		var inst = packed.instantiate()
		if not inst:
			push_error("_item_drop: falha ao instanciar %s" % scene_path)
			dropped.append(null)
			continue

		# garantir que o nó instanciado seja (ou contenha) um RigidBody3D
		var rigid: RigidBody3D = null
		if inst is RigidBody3D:
			rigid = inst
		else:
			# tenta encontrar um RigidBody3D dentro da cena instanciada
			rigid = inst.get_node_or_null("RigidBody3D")
			# alternativa genérica: procurar recursivamente o primeiro RigidBody3D
			if not rigid:
				for child in inst.get_children():
					if child is RigidBody3D:
						rigid = child
						break

		if not rigid:
			push_error("_item_drop: instância %s não contém RigidBody3D." % scene_path)
			dropped.append(null)
			# opcional: liberar instância (se não anexada a árvore)
			continue

		# calcular posição de drop (um pouco à frente do player)
		var forward_dir: Vector3 = global_transform.basis.z
		var drop_origin: Vector3 = global_transform.origin + forward_dir * drop_distance + Vector3.UP * 0.4

		# anexar a cena (como filho da cena atual)
		scene_root.add_child(inst)
		# definir transform global da instância:
		# manter a base (rot) da instância local, mas ajustar a origem
		var new_transform: Transform3D = inst.global_transform
		new_transform.origin = drop_origin
		inst.global_transform = new_transform

		# aplicar velocidade inicial ao rigidbody (simula o "soltar/empurrar")
		# usamos linear_velocity para simplicidade
		if rigid is RigidBody3D:
			rigid.linear_velocity = forward_dir.normalized() * drop_force
			# opcional: pequena rotação aleatória para visual
			rigid.angular_velocity = Vector3(randf(), randf(), randf()) * 1.2
		else:
			push_warning("_item_drop: nó encontrado não é RigidBody3D apesar das checagens.")
		# Animação Interact de item_drop
		_execute_animation("Interact","parameters/Interact/transition_request", "parameters/Interact_shot/request")
		dropped.append(rigid)

	# debug
	if debug:
		print("_item_drop: dropped %d / %d" % [dropped.count(null), item_ids.size()])
	return dropped

# Executa uma animação one-shot e retorna sua duração
func _execute_animation(anim_name: String, anim_param_path: String, oneshot_request_path: String = "") -> float:
	# Verifica existência da animação no AnimationPlayer
	if not animation_player.has_animation(anim_name):
		push_error("Animação não encontrada no AnimationPlayer: %s" % anim_name)
		return 0.0
		
	# Atribui o nome da animação apenas ao caminho apropriado (String)
	if anim_param_path != "":
		animation_tree.set(anim_param_path, anim_name)

	# Dispara o request (int) no caminho apropriado
	if oneshot_request_path != "":
		animation_tree.set(oneshot_request_path, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

	# Retorna duração da animação (segundos)
	var anim = animation_player.get_animation(anim_name)
	return anim.length if anim else 0.0

# Movimentos da espada de acordo com o imput
func _determine_attack_from_input() -> String:
	var current_dir = _get_current_direction()
	# 1. PRIORIDADE: inputs diagonais simultâneos
	if current_dir == "forward_right" or current_dir == "backward_right":
		return "1H_Melee_Attack_Slice_Diagonal"
	# (Você pode adicionar outras diagonais se quiser, ex: forward_left → outra animação)
	# 2. Se não for diagonal, usa o histórico de direções simples
	if last_simple_directions.is_empty():
		return "1H_Melee_Attack_Slice_Horizontal"
	if last_simple_directions.size() == 1:
		match last_simple_directions[0]:
			"backward": return "1H_Melee_Attack_Chop"
			"forward":  return "1H_Melee_Attack_Stab"
			"left", "right": return "1H_Melee_Attack_Slice_Horizontal"
	if last_simple_directions.size() >= 2:
		var first = last_simple_directions[-2]
		var second = last_simple_directions[-1]
		# De cima pra baixo
		if first == "forward" and second == "backward":
			return "1H_Melee_Attack_Chop"
		# Horizontal esquerda → direita
		if first == "left" and second == "right":
			return "1H_Melee_Attack_Slice_Horizontal"
		# Última direção define o ataque em muitos casos
		if second == "backward":
			return "1H_Melee_Attack_Chop"
		if second == "forward":
			return "1H_Melee_Attack_Stab"
	# Fallback
	return "1H_Melee_Attack_Slice_Horizontal"

# Ações do player (Espadada)
func action_sword_attack():
	# Limpa hit_targets sempre que iniciar algum ataque
	hit_targets.clear()
	
	if current_item_right_id != 0 and not is_attacking:
		is_attacking = true
		current_attack_item_id = current_item_right_id
		var anim_time: float = _execute_animation(_determine_attack_from_input(),
			"parameters/sword_attacks/transition_request",
			"parameters/Attack/request")
		_on_attack_timer_timeout(anim_time * 0.4, current_item_right_id)

# Função acionada pelas animações(AnimationPlayer), habilita hitbox na hora
# exata do golpe; Pega current_item_right_id para saber qual foi a espada usada
func _enable_attack_area():
	var node = _get_node_by_id(current_attack_item_id)
	var hitbox = node.get_node("hitbox")
	if hitbox is Area3D:
		hitbox.monitoring = true

# Para o contato das hitboxes das espadas(no momento ativo) com inimigos (área3D)
func _on_hitbox_body_entered(body: Node, hitbox_area: Area3D) -> void:
	if body.is_in_group("enemies") and (is_attacking or is_block_attacking):
		# evita bater várias vezes no mesmo alvo durante o mesmo swing
		if body in hit_targets:
			return
			
		# apenas inimigos
		if body.is_in_group("enemies"):
			hit_targets.append(body)
			body.take_damage(10)
			if debug:
				print(body.name, " foi acertado por ", hitbox_area.get_parent().name)

# Ações do player (Trancar visão no inimigo)
func action_lock():
	if current_item_left_id != 10:
		_strafe_mode(true, true)
	if current_item_left_id != 0:
		is_defending = true
		animation_tree.set("parameters/Blocking/blend_amount", 1.0)
		
func _on_block_attack_timer_timeout(duration):
	await get_tree().create_timer(duration).timeout
	is_block_attacking = false
	
func action_block_attack():
	if not is_block_attacking and is_defending:
		hit_targets.clear()
		is_block_attacking = true
		current_attack_item_id = current_item_left_id
		var anim_time = _execute_animation("Block_Attack",
				"parameters/sword_attacks/transition_request",
				"parameters/Attack/request")
		_on_block_attack_timer_timeout(anim_time * 0.85)
			
# Ações do player (Quando guardar o escudo)
func action_stop_locking():
	_strafe_mode(false, true)
	if current_item_left_id != 0:
		is_defending = false
		is_attacking = false
		animation_tree.set("parameters/Blocking/blend_amount", 0.0)

# Ações do player (Pegar item)
func action_pick_up_item():
	var found = _get_nearby_items()
	if found.size() == 0:
		if debug:
			print("Nenhum item por perto")
		return
	var item = found[0]
	if item.has_method("pick_up"):
		item.pick_up(self)
		equip_item_by_id(item.item_id, true)
		
# Ações do player (Dropar item) *por enquanto dropa tudo sequencialmente
func action_drop_item() -> void:
	var items = [
		current_cape_item_id,
		current_helmet_item_id,
		current_item_left_id,
		current_item_right_id
	]
	var items_tt = []
	for item_id in items:
		if item_id == 0:
			continue
		else:
			items_tt.append(item_id)
			
	if len(items_tt) > 0:
			
		# Executa o drop do node do item
		_item_drop([items_tt[0]])
		
		# Atualiza visibilidade do item no modelo (uma vez)
		_item_model_change_visibility(_get_item_by_id(items_tt[0]), true)
		var item_id = _get_item_by_id(items_tt[0])["id"]
		if item_id == current_cape_item_id:
			current_cape_item_id = 0
		elif item_id == current_helmet_item_id:
			current_helmet_item_id = 0
		elif item_id == current_item_left_id:
			current_item_left_id = 0
		elif item_id == current_item_right_id:
			current_item_right_id = 0

func _on_impact_detected(impulse: float):
	if debug:
		print("FUI ATINGIDO! Impulso: ", impulse)
	# Reduzir vida, ative efeito de hit, etc.
	
	if is_defending:
		animation_tree.set("parameters/Blocking/blend_amount", 0.0)	
	var random_hit = ["parameters/Hit_B/request", "parameters/Hit_A/request"].pick_random()
	animation_tree.set(random_hit, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

# Quando terminar o ataque desativar hitbox da espada, is_attacking false e 
# timer para impedir repetição de golpe antes do final
func _on_attack_timer_timeout(duration, current_id):
	await get_tree().create_timer(duration).timeout
	var node = _get_node_by_id(current_id)
	var hitbox = node.get_node("hitbox")
	if hitbox is Area3D:
		hitbox.monitoring = false
		is_attacking = false
		is_block_attacking = false
	
# Trainer de testes
func handle_test_equip_inputs() -> void:
	# mapa base (ajuste se algum action deve apontar pra outro item_id)
	var test_equip_map: Dictionary = {}

	# preenche o resto até 8 com o padrão action_n -> n
	for i in range(1, 9):
		var key: String = "test_equip%d" % i
		if not test_equip_map.has(key):
			test_equip_map[key] = i

	# Checa entradas e executa a lógica
	for action_name in test_equip_map.keys():
		if Input.is_action_just_pressed(action_name):
			var mapped_id: int = int(test_equip_map[action_name])

			# tenta obter o nó; se nulo, avisa e pula
			var node := _get_node_by_id(mapped_id)
			if node == null:
				push_error("handle_test_equip_inputs: get_node_by_id(%d) retornou null." % mapped_id)
				continue

			# equipa o item
			equip_item_by_id(mapped_id, true)

			# tenta resolver o id a partir do nó; se falhar, usa o id mapeado
			var resolved_id: int = _get_id_by_node(node)
			if resolved_id == -1:
				resolved_id = mapped_id

			# pega o item e valida
			var item := _get_item_by_id(resolved_id)
			if item == null or (item is Dictionary and item.is_empty()):
				push_error("handle_test_equip_inputs: item não encontrado para id %d." % resolved_id)
				continue

# ===== SINCRONIZAÇÃO DE REDE =====
		
func _send_state_to_network(delta: float):
	"""Envia estado do player para o servidor"""
	if not is_local_player:
		return
	
	sync_timer += delta
	
	if sync_timer >= sync_rate:
		sync_timer = 0.0
		
		# Envia estado via NetworkManager
		if NetworkManager and NetworkManager.is_connected:
			NetworkManager.send_player_state(
				player_id,
				global_position,
				rotation,
				velocity,
				is_running,
				is_jumping
			)

func teleport_to(new_position: Vector3):
	"""Teleporta o player (apenas servidor)"""
	if multiplayer.is_server():
		global_position = new_position

# ===== CLEANUP =====

func _exit_tree():
	# Remove do registro
	if RoundRegistry:
		RoundRegistry.unregister_spawned_player(player_id)
	
	# Libera mouse se for local
	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ===== UTILS =====

# Usado por get_nearby_items
func _sort_by_distance(a, b) -> int:
	var da = a.global_transform.origin.distance_to(global_transform.origin)
	var db = b.global_transform.origin.distance_to(global_transform.origin)
	if da < db: return -1
	if da > db: return 1
	return 0
