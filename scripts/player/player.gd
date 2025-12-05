extends CharacterBody3D

# ===== CONFIGURAÇÕES GERAIS =====

@export_category("Debug")
@export var debug: bool = true

@export_category("Movement")
@export var max_speed: float = 5
@export var walking_speed: float = 2.0
@export var run_multiplier: float = 1.5
@export var jump_velocity: float = 8.0
@export var acceleration: float = 8.0
@export var deceleration: float = 8.0
@export var bobbing_intensity: float = 0.6
@export var turn_speed: float = 8.0
@export var air_control: float = 1.2
@export var air_friction: float = 0.01
@export var preserve_run_on_jump: bool = true
@export var gravity: float = 20.0
@export var aiming_jump_multiplyer: float = 4.2

@export_category("Player actions")
@export var hide_itens_on_start: bool = true

@export_category("Item Detection")
@export var pickup_radius: float = 1.2
@export var pickup_collision_mask: int = 1 << 2 # Layer 3
@export var max_pickup_results: int = 10

@export_category("Enemy detection")
@export var detection_radius_fov: float = 14.0 # Raio para detecção no FOV
@export var detection_radius_360: float = 6.0 # Raio menor (ou maior) para fallback 360°
@export_range(0, 360) var field_of_view_degrees: float = 120.0
@export var use_360_vision_as_backup: bool = true # Ativa a visão 360° como fallback
@export var update_interval: float = 0.5 # atualização a cada X segundos (0 = cada frame)

# ===== CONFIGURAÇÕES DE REDE =====

@export_category("Network Sync")
@export var sync_rate: float = 0.03 # 33 updates/segundo (melhor que 0.05)
@export var interpolation_speed: float = 12.0 # Interpolação mais rápida
@export var position_threshold: float = 0.01 # Distância mínima para sincronizar
@export var rotation_threshold: float = 0.01 # Rotação mínima para sincronizar
@export var anim_sync_rate: float = 0.1  # 10 updates/segundo (menos que posição)

# referências
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var attack_timer: Timer = $attack_timer
@onready var name_label: Label3D = $NameLabel

# Estados de sincronização
var target_position: Vector3 = Vector3.ZERO
var target_rotation_y: float = 0.0
var sync_timer: float = 0.0

# Estados de animação (para sincronização)
var anim_sync_timer: float = 0.0
var last_anim_state: Dictionary = {}

# Identificação multiplayer
var player_id: int = 0
var player_name: String = ""
var is_local_player: bool = false
var _is_server: bool = false

# Estados
var is_attacking: bool = false
var is_defending: bool = false
var is_jumping: bool = false
var is_aiming: bool = false
var is_running: bool = false
var current_item_right_id: int # substituir pela variável atualizada pelo server
var current_item_left_id: int # substituir pela variável atualizada pelo server
var current_helmet_item_id: int # substituir pela variável atualizada pelo server
var current_cape_item_id: int # substituir pela variável atualizada pelo server
var current_attack_item_id: int # substituir pela variável atualizada pelo server
var mouse_mode: bool = true
var run_on_jump: bool = false
var nearest_enemy: CharacterBody3D = null
var _detection_timer: Timer = null
var last_simple_directions: Array = []
var is_block_attacking: bool = false
var local_inventory: Dictionary = {} # Inventário(de itens e equipamentos) local do player.
const MAX_DIRECTION_HISTORY = 2

# Dinâmicas
var model: Node3D = null
var skeleton: Skeleton3D = null
var camera_controller: Node3D
var aiming_forward_direction: Vector3 = Vector3.FORWARD
var defense_target_angle: float = 0.0
var _item_data: Array[Dictionary] = [] # Futuramente substituir pelo ItemDatabase
var hit_targets: Array = []
var cair: bool = false

# Ready
func _ready():
	# Detecta se é servidor dedicado
	var args = OS.get_cmdline_args()
	_is_server = "--server" in args or "--dedicated" in args
	
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
func _physics_process(delta: float) -> void:
	"""
	Versão final: clara, sem erros, com fallback para singleplayer
	"""
	var move_dir: Vector3 = Vector3.ZERO
	
	_handle_gravity(delta)
	
	# ✅ Verificação de segurança
	var has_network = multiplayer and multiplayer.has_multiplayer_peer()
	
	# Processamento de movimento
	# Servidor não processa movimento aqui (definido por RPC)
	if is_local_player:
		# Jogador controlado pelo usuário
		move_dir = _handle_movement_input(delta)
		move_and_slide()
		
		# Sincronização de rede (se aplicável)
		if has_network:
			_send_state_to_server(delta)
			_send_animation_state(delta)
		
		# Input de teste
		handle_test_equip_inputs_call()
	
	elif verificar_rede() and has_network and multiplayer.has_multiplayer_peer():
		if not multiplayer.is_server():
			# Jogador remoto no cliente
			_interpolate_remote_player(delta)
	
	# Animações (sempre server/client)
	_handle_animations(move_dir)
		
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
	var file = FileAccess.open("res://scripts/utils/item_database_regs.json", FileAccess.READ)
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
		push_error("Não foi possível abrir item_database.json")
		
# 1.1. Retorna o item completo pelo ID
func _get_item_by_id(p_id: int) -> Dictionary:
	for item in _item_data:  # Corrigido: _item_data
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
func get_nearby_items(
	radius: float = pickup_radius,
	_collision_mask: int = pickup_collision_mask,
	max_results: int = max_pickup_results,
	sort_by_distance: bool = true
) -> Array:
	"""
	Retorna itens próximos do player usando PhysicsShapeQuery
	
	@param radius: Raio de detecção
	@param _collision_mask: Máscara de colisão (default: layer 3)
	@param max_results: Número máximo de itens
	@param sort_by_distance: Ordenar do mais próximo ao mais distante
	@return: Array de nodes (itens detectados)
	"""
	
	var space_state = get_world_3d().direct_space_state
	
	# Cria shape esférico
	var shape = SphereShape3D.new()
	shape.radius = radius
	
	# Configura parâmetros da query
	var params = PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D.IDENTITY.translated(global_position)
	params.collision_mask = _collision_mask
	params.collide_with_bodies = true
	params.collide_with_areas = true
	
	# Executa query
	var results: Array = space_state.intersect_shape(params, max_results)
	
	# Filtra apenas itens válidos
	var items: Array = []
	for result in results:
		var body = result.collider
		
		if not body or body == self:
			continue
		
		# Verifica se é item (qualquer um desses critérios)
		if body.is_in_group("item") or \
			body.has_method("collect") or \
			"item_name" in body:
			items.append(body)
	
	# Ordena por distância (opcional)
	if sort_by_distance and items.size() > 1:
		items.sort_custom(func(a, b):
			var dist_a = global_position.distance_to(a.global_position)
			var dist_b = global_position.distance_to(b.global_position)
			return dist_a < dist_b
		)
	
	return items
	
# Funções da câmera livre
func _get_movement_direction_free_cam() -> Vector3:
	var camera := camera_controller
	if camera and camera.is_inside_tree():
		var cam_basis := camera.global_transform.basis
		var cam_forward := (-cam_basis.z).normalized()
		cam_forward.y = 0.0
		var cam_right := Vector3.UP.cross(cam_forward).normalized()
		var input_vec := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if input_vec.length() > 0.1:
			return (cam_forward * input_vec.y + cam_right * input_vec.x).normalized()
	else:
		_log_debug("Câmera não disponível. Usando eixos fixos")
		var world_input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if world_input.length() > 0.1:
			return Vector3(-world_input.x, 0.0, world_input.y).normalized()
	return Vector3.ZERO
	
# Funções da câmera lockada
func _get_movement_direction_locked() -> Vector3:
	var input_vec := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	if input_vec.length() <= 0.1:
		return Vector3.ZERO
		
	# Usa a frente atual do corpo
	var forward = Vector3(-global_transform.basis.z.x, 0, -global_transform.basis.z.z).normalized()
	var right = Vector3.UP.cross(forward).normalized()

	# Input: Y = para frente/trás, X = strafe
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

# Detectar inimigo mais próximo
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

		# Verificação de linha de visão (raycast)
		var query = PhysicsRayQueryParameters3D.new()
		query.from = player_pos
		query.to = enemy_pos
		query.collision_mask = 1
		query.exclude = [self]

		var result = space_state.intersect_ray(query)
		if result and result.collider != enemy:
			continue  # Obstáculo bloqueando

		# Verificação para FOV
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
		_log_debug("Inimigo mais próximo (FOV): %s" % closest_in_fov)
		return closest_in_fov
		
	# --- Fallback: 360° (se ativado e dentro do raio menor) ---
	if use_360_vision_as_backup and closest_in_360 != null:
		_log_debug("Inimigo mais próximo (360° fallback): %s" % closest_in_360)
		return closest_in_360
		
	_log_debug("Nenhum inimigo detectado.")
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
	# Pulo: Preserva velocidade horizontal EXATA do chão
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
			
			_log_debug("Pulando com velocidade XZ: (%.2f, %.2f)" % [velocity.x, velocity.z])
			
			return
			
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
		
	# Movimento no chão
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
			
	# Movimento no ar (após o frame do pulo)
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
	is_running = Input.is_action_pressed("run") and is_on_floor()
	
# Chama a câmera lockada e transiciona p/ movimentação strafe
func _strafe_mode(ativar: bool = true, com_camera_lock = true):
	# Só o jogador local pode ativar/desativar modo de mira
	if not is_local_player:
		return
	
	if ativar:
		is_aiming = true
		
		# Verifica se câmera existe (deve existir para local)
		if camera_controller and camera_controller.is_inside_tree():
			var cam_forward = -camera_controller.global_transform.basis.z
			cam_forward.y = 0.0
			cam_forward = cam_forward.normalized()
			defense_target_angle = atan2(-cam_forward.x, -cam_forward.z)
		else:
			# Fallback: usa direção do jogador
			var player_forward = -global_transform.basis.z
			player_forward.y = 0.0
			player_forward = player_forward.normalized()
			defense_target_angle = atan2(-player_forward.x, -player_forward.z)
		
		if com_camera_lock and camera_controller and camera_controller.has_method("force_behind_player"):
			camera_controller.force_behind_player()
		# Se não tem câmera, não faz nada (jogador remoto não chega aqui)
	else:
		is_aiming = false
		if camera_controller and camera_controller.has_method("release_to_free_look"):
			camera_controller.release_to_free_look()
			
func _unhandled_input(event: InputEvent) -> void:
	if is_local_player:
		if event.is_action_pressed("ui_cancel"):
			_toggle_mouse_mode()
		elif event.is_action_pressed("interact"):
			action_pick_up_item_call()
		elif event.is_action_pressed("attack"):
			action_sword_attack_call()
		elif event.is_action_pressed("lock"):
			action_lock()
		elif event.is_action_released("lock"):
			action_stop_locking()
		elif event.is_action_pressed("block_attack"):
			action_block_attack()
		elif event.is_action_pressed("drop"):
			action_drop_item_call()
			
# Mouse
func _toggle_mouse_mode():
	mouse_mode = not mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if not mouse_mode else Input.MOUSE_MODE_CAPTURED
	_log_debug("Mouse %s." % ["liberado" if not mouse_mode else "capturado"])
		
# Visual
func _hide_all_model_items():
	var knight_items = ItemDatabase.query_items({"owner": "knight"})
	for item in knight_items:
		if item.owner:
			var target = get_node_or_null(item.model_node_link)
			target.visible = false
			
# Executa uma animação one-shot e retorna sua duração
func _execute_animation(anim_name: String, anim_param_path: String, oneshot_request_path: String = "") -> float:
	# Verifica existência da animação no AnimationPlayer
	
	print("_execute_animation", anim_name, " ", anim_param_path, " ", oneshot_request_path)
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
	
# Movimentos da espada de acordo com o input
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
	
# Função acionada pelas animações(AnimationPlayer), habilita hitbox na hora
# exata do golpe; Pega current_item_right_id para saber qual foi a espada usada
func _enable_attack_area():
	if current_attack_item_id > 0:
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
			_log_debug("%s foi acertado por %s" % [body.name, hitbox_area.get_parent().name])
			
# Ações do player (Trancar visão no inimigo)
func _on_block_attack_timer_timeout(duration):
	await get_tree().create_timer(duration).timeout
	is_block_attacking = false
		
func _on_impact_detected(impulse: float):
	_log_debug("FUI ATINGIDO! Impulso: %d" % impulse)
	# Reduzir vida, ativar efeito de hit, etc.
	
	if is_defending:
		animation_tree.set("parameters/Blocking/blend_amount", 0.0)
	var random_hit = ["parameters/Hit_B/request", "parameters/Hit_A/request"].pick_random()
	animation_tree.set(random_hit, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

# Quando terminar o ataque desativar hitbox da espada, is_attacking false e 
# timer para impedir repetição de golpe antes do final
func _on_attack_timer_timeout(duration, current_id):
	# APENAS JOGADOR LOCAL
	if not is_local_player:
		return
		
	await get_tree().create_timer(duration).timeout
	var node = _get_node_by_id(current_id)
	var hitbox = node.get_node("hitbox")
	if hitbox is Area3D:
		hitbox.monitoring = false
		is_attacking = false
		is_block_attacking = false
	
# ===== UTILS =====

func teleport_to(new_position: Vector3):
	"""Teleporta o player (apenas servidor)"""
	if multiplayer.is_server():
		global_position = new_position
		
# ===== FUNÇÕES DE REDE ====================
# ===== ENVIO DE ESTADO PARA SERVIDOR (APENAS LOCAL) =====

func _send_state_to_server(delta: float):
	"""Envia estado do jogador local para o servidor"""
	
	sync_timer += delta
	
	if sync_timer >= sync_rate:
		sync_timer = 0.0
		
		# Verifica se houve mudança significativa
		var pos_changed = global_position.distance_to(target_position) > position_threshold
		var rot_changed = abs(rotation.y - target_rotation_y) > rotation_threshold
		
		if pos_changed or rot_changed:
			# Atualiza alvos para próxima comparação
			target_position = global_position
			target_rotation_y = rotation.y
			
			# ENVIA VIA NETWORKMANAGER (UNRELIABLE = RÁPIDO)
			if NetworkManager and NetworkManager.is_connected:
				NetworkManager.send_player_state(
					player_id,
					global_position,
					rotation,
					velocity,
					is_running,
					is_jumping
				)
				
# ===== ENVIO DE ANIMAÇÕES (MENOS FREQUENTE) =====

func _send_animation_state(delta: float):
	"""Envia estado das animações para a rede"""
	
	anim_sync_timer += delta
	
	if anim_sync_timer >= anim_sync_rate:
		anim_sync_timer = 0.0
		
		# Captura estado atual
		var current_state = {
			"speed": Vector2(velocity.x, velocity.z).length(),
			"is_attacking": is_attacking,
			"is_defending": is_defending,
			"is_jumping": is_jumping,
			"is_aiming": is_aiming,
			"is_running": is_running,
			"is_block_attacking": is_block_attacking,
			"is_on_floor": is_on_floor()
		}
		
		# Só envia se mudou
		if _animation_state_changed(current_state):
			last_anim_state = current_state.duplicate()
			
			if NetworkManager and NetworkManager.is_connected:
				NetworkManager.send_player_animation_state(
					player_id,
					current_state["speed"],
					current_state["is_attacking"],
					current_state["is_defending"],
					current_state["is_jumping"],
					current_state["is_aiming"],
					current_state["is_running"],
					current_state["is_block_attacking"],
					current_state["is_on_floor"]
				)
				
func _animation_state_changed(new_state: Dictionary) -> bool:
	"""Verifica se o estado de animação mudou significativamente"""
	if last_anim_state.is_empty():
		return true
	
	# Verifica mudanças em flags booleanas
	for key in ["is_attacking", "is_defending", "is_jumping", "is_aiming", "is_running", "is_block_attacking", "is_on_floor"]:
		if new_state.get(key, false) != last_anim_state.get(key, false):
			return true
	
	# Verifica mudança significativa na velocidade
	var speed_diff = abs(new_state.get("speed", 0.0) - last_anim_state.get("speed", 0.0))
	if speed_diff > 0.5:
		return true
	
	return false
	
# ===== INTERPOLAÇÃO DE JOGADORES REMOTOS =====

func _interpolate_remote_player(delta: float):
	"""Interpola suavemente a posição de jogadores remotos"""
	
	# INTERPOLAÇÃO SUAVE (evita teleporte)
	global_position = global_position.lerp(target_position, interpolation_speed * delta)
	
	# INTERPOLAÇÃO DE ROTAÇÃO (apenas Y)
	rotation.y = lerp_angle(rotation.y, target_rotation_y, interpolation_speed * delta)
	
	# OPCIONAL: Simula gravidade para remotos
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0
	
	# Move para aplicar física/colisões
	move_and_slide()
	
# ===== RECEPÇÃO DE ESTADO (REMOTOS) =====

@rpc("authority", "call_remote", "unreliable")
func _client_receive_state(pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Recebe estado de outros jogadores e define alvos para interpolação"""
	
	if is_local_player:
		return  # Ignora para si mesmo
	
	# ATUALIZA ALVOS PARA INTERPOLAÇÃO SUAVE
	target_position = pos
	target_rotation_y = rot.y
	
	# Atualiza estados para animações (opcional: pode vir de _client_receive_animation_state)
	is_running = running
	is_jumping = jumping
	velocity = vel  # Para gravidade

# ===== RECEPÇÃO DE ANIMAÇÕES (REMOTOS) =====

@rpc("authority", "call_remote", "unreliable")
func _client_receive_animation_state(speed: float, attacking: bool, defending: bool,
 jumping: bool, aiming: bool, running: bool, block_attacking: bool, on_floor: bool):
	"""Recebe e aplica estado de animação de outros jogadores"""
	
	if is_local_player:
		return  # Ignora para si mesmo
	
	# ATUALIZA ESTADOS
	is_attacking = attacking
	is_defending = defending
	is_jumping = jumping
	is_aiming = aiming
	is_running = running
	is_block_attacking = block_attacking
	
	# ATUALIZA ANIMATIONTREE
	if animation_tree:
		# Locomotion
		animation_tree["parameters/Locomotion/blend_position"] = speed
		
		# Blocking
		if defending:
			animation_tree.set("parameters/Blocking/blend_amount", 1.0)
		else:
			animation_tree.set("parameters/Blocking/blend_amount", 0.0)
		
		# Jump transitions
		if jumping and not on_floor:
			animation_tree["parameters/final_transt/transition_request"] = "jump_start"
		elif on_floor and not jumping:
			animation_tree["parameters/final_transt/transition_request"] = "jump_land"
			animation_tree["parameters/final_transt/transition_request"] = "walking_e_blends"
		
		# Bobbing (baseado na velocidade)
		if speed > 0.1:
			animation_tree["parameters/bobbing/add_amount"] = bobbing_intensity * speed
		else:
			animation_tree["parameters/bobbing/add_amount"] = 0
			
# ===== RECEPÇÃO DE AÇÕES (ATAQUES, DEFESA) =====

@rpc("authority", "call_remote", "reliable")
func _client_receive_action(action_type: String, anim_name: String):
	"""Recebe e executa ações de outros jogadores (ataques, defesa, etc)"""
	
	if is_local_player:
		return  # Ignora para si mesmo
	
	match action_type:
		"attack":
			if not is_attacking:
				is_attacking = true

				_execute_animation(anim_name,
					"parameters/sword_attacks/transition_request",
					"parameters/Attack/request")
				# Timer para resetar is_attacking
				await get_tree().create_timer(0.5).timeout
				is_attacking = false
		
		"block_attack":
			if not is_block_attacking:
				is_block_attacking = true
				_execute_animation(anim_name,
					"parameters/sword_attacks/transition_request",
					"parameters/Attack/request")
				await get_tree().create_timer(0.5).timeout
				is_block_attacking = false
		
		"defend_start":
			is_defending = true
			animation_tree.set("parameters/Blocking/blend_amount", 1.0)
		
		"defend_stop":
			is_defending = false
			is_attacking = false
			animation_tree.set("parameters/Blocking/blend_amount", 0.0)
			
# ===== AÇÕES DO JOGADOR =====

func action_sword_attack_call():
	
	# Apenas jogador local pede para atacar
	if not is_local_player:
		return
	
	# Apenas atacar se estiver usando um item de ataque
	var item_equipado_nome = local_inventory["equipped"]["hand-right"]
	
	# Apenas atacar se estiver com algo na mão direita
	if not item_equipado_nome:
		return
		
	# apenas atacar se for uma arma
	if ItemDatabase.get_item(item_equipado_nome)["category"] != "weapon":
		return
	
	# Sincroniza ataque pela rede (Reliable = Garantido)
	if NetworkManager and NetworkManager.is_connected:
		var anim_name = _determine_attack_from_input()
		NetworkManager.send_player_action(player_id, "attack", anim_name)
		
		# executa localmente
		_execute_animation(anim_name,"parameters/sword_attacks/transition_request",
		"parameters/Attack/request")
		
	# hitbox
	# hit_targets.clear()
	#var anim_time: float = _execute_animation(anim_name,
		#"parameters/sword_attacks/transition_request",
		#"parameters/Attack/request")
		#_on_attack_timer_timeout(anim_time * 0.4, current_item_right_id)


# PAREI AQUI, FAZER O ACTION_LOCK CALL!
func action_lock():
	"""Versão modificada que sincroniza defesa"""
	
	# APENAS JOGADOR LOCAL
	if not is_local_player:
		return
	
	if current_item_left_id != 10:
		_strafe_mode(true, true)
	
	if current_item_left_id != 0:
		is_defending = true
		animation_tree.set("parameters/Blocking/blend_amount", 1.0)
		
		# SINCRONIZA DEFESA (RELIABLE)
		if NetworkManager and NetworkManager.is_connected:
			NetworkManager.send_player_action(player_id, "defend_start", "")

func action_block_attack():
	"""Versão modificada que sincroniza block attack"""
	
	# APENAS JOGADOR LOCAL
	if not is_local_player:
		return
	
	if not is_block_attacking and is_defending:
		hit_targets.clear()
		is_block_attacking = true
		current_attack_item_id = current_item_left_id
		
		var anim_time = _execute_animation("Block_Attack",
			"parameters/sword_attacks/transition_request",
			"parameters/Attack/request")
		
		_on_block_attack_timer_timeout(anim_time * 0.85)
		
		# SINCRONIZA BLOCK ATTACK (RELIABLE)
		if NetworkManager and NetworkManager.is_connected:
			NetworkManager.send_player_action(player_id, "block_attack", "Block_Attack")

func action_stop_locking():
	"""Versão modificada que sincroniza fim da defesa"""
	
	# APENAS JOGADOR LOCAL
	if not is_local_player:
		return
	
	_strafe_mode(false, true)
	
	if current_item_left_id != 0:
		is_defending = false
		is_attacking = false
		animation_tree.set("parameters/Blocking/blend_amount", 0.0)
		
		# SINCRONIZA FIM DE DEFESA (RELIABLE)
		if NetworkManager and NetworkManager.is_connected:
			NetworkManager.send_player_action(player_id, "defend_stop", "")

# ===== INICIALIZAÇÃO MULTIPLAYER =====

func set_as_local_player():
	"""Configura este player como o jogador local"""
	is_local_player = true
	
	# APENAS JOGADOR LOCAL PROCESSA INPUT
	set_process_input(true)
	set_process_unhandled_input(true)
	
	# Inicializa o inventário
	if not _is_server:
		init_player_inventory()

func initialize(p_id: int, p_name: String, spawn_pos: Vector3):
	"""Inicializa o player com dados multiplayer"""
	player_id = p_id
	player_name = p_name
	
	# NOME DO NÓ = ID DO PLAYER (IMPORTANTE!)
	name = str(player_id)
	
	# Posiciona no spawn
	global_position = spawn_pos
	target_position = spawn_pos  # Inicializa target também
	
	# Atualiza label de nome
	if name_label:
		name_label.text = player_name
		setup_name_label()
	
	# CONFIGURAÇÃO DE PROCESSOS
	if not is_local_player:
		# Remotos não processam input
		set_process_input(false)
		set_process_unhandled_input(false)
	
	# Define autoridade multiplayer
	set_multiplayer_authority(player_id)
	
	# Ativa processos
	set_physics_process(true)
	set_process(true)
	
	
# ===== FUNÇÕES DE ITENS ===============

func handle_test_equip_inputs_call():
	var mapped_id: int
	var test_equip_map: Dictionary = {}

	# preenche o resto até 8 com o padrão action_n -> n
	for i in range(1, 9):
		var key: String = "test_equip%d" % i
		test_equip_map[key] = i

	# Checa entradas em ordem de 1..8 e pega o primeiro pressionado
	for i in range(1, 9):
		var key := "test_equip%d" % i
		if Input.is_action_just_pressed(key):
			mapped_id = i
			break # evita sobrescrever com outra ação no mesmo frame

	# Somente envie ao servidor / equipe se o mapped_id estiver no intervalo válido 1..8
	if mapped_id >= 1 and mapped_id <= 8:
		# envia para o servidor (se conectado)
		if NetworkManager and NetworkManager.is_connected:
			NetworkManager.request_equip_item(player_id, mapped_id, true)
	
func apply_visual_equip_on_player_node(player_node, item_mapped_id):
	
	animation_tree.set("PickUp", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	
	var item_node_link = ItemDatabase.get_item_by_id(item_mapped_id).model_node_link
	
	_item_model_change_visibility(player_node, item_node_link)

# Ações do player (Pegar item)
func action_pick_up_item_call():
	# Servidor não pede, só local pede, servidor recebe pedido e processa usando
	# node do player remoto do servidor

	if not is_local_player:
		return
		
	var found = get_nearby_items()
	if found.size() == 0:
		if debug:
			_log_debug("Nenhum item por perto")
		return
	var object = found[0]
	_log_debug("Player %d pediu para pegar o item %d" % [player_id, object.object_id])
	if NetworkManager and NetworkManager.is_connected and object:
		NetworkManager.request_pick_up_item(player_id, object.object_id)
		
func action_pick_up_item():
	#_execute_animation("Interact", "parameters/Interact/transition_request", "parameters/Interact_shot/request")
	_execute_animation("PickUp", "parameters/PickUp/transition_request", "parameters/Pickup_shot/request")
	
	#animation_tree.set("PickUp", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	
		
# Ações do player (Dropar item) *por enquanto dropa tudo sequencialmente
func action_drop_item_call() -> void:
	if not is_local_player:
		return
	if NetworkManager and NetworkManager.is_connected:
		NetworkManager.request_drop_item(player_id)
		
func execute_item_drop(player_node, item):
	# Executa o drop do node do item
	var item_node_link = ItemDatabase.get_item(item)["model_node_link"]
		
	# Atualiza visibilidade do item no modelo (uma vez)
	_item_model_change_visibility(player_node, item_node_link, false)
	# Animação de drop
	_execute_animation("Interact", "parameters/Interact/transition_request", "parameters/Interact_shot/request")

# Modifica a visibilidade do item na mão do modelo
func _item_model_change_visibility(player_node, node_link: String, visible_ : bool = true):
	"""
	Aplica visibilidade em um item específico através do node_link
	Se visible = true, ESCONDE todos os outros itens no mesmo slot
	
	Args:
		node: O nó do player (CharacterBody3D)
		item: Dicionário com dados do item (deve ter 'node_link')
		visible: true para mostrar (e esconder outros), false para esconder
	
	Returns:
		bool: true se conseguiu aplicar, false se falhou
	
	Exemplo:
		node_link: "Knight/Rig/Skeleton3D/handslot_l/shield_2"
		Se visible=true, TODOS os filhos de "handslot_l" serão escondidos,
		EXCETO "shield_2" que será mostrado
		"""
	# VALIDAÇÃO: Verifica se node é válido
	if not player_node or not is_instance_valid(player_node):
		push_error("apply_item_visibility: node inválido ou null")
		return false
	
	# VALIDAÇÃO: Verifica se item tem node_link
	
	# BUSCA O NÓ DO ITEM A PARTIR DO PLAYER
	var item_node = player_node.get_node_or_null(node_link)
	
	if not item_node:
		push_error("apply_item_visibility: nó não encontrado no caminho '%s'" % node_link)
		_log_debug("Caminho base: %s, caminho completo: %s/%s" % [player_node.get_path(), player_node.get_path(), node_link])
		return false
	
	# SE VISIBLE = TRUE, ESCONDE TODOS OS IRMÃOS (outros itens no mesmo slot)
	if visible_:
		var parent_node = item_node.get_parent()
		
		if parent_node:
			# Esconde todos os filhos do slot (ex: todos em "handslot_l")
			for sibling in parent_node.get_children():
				if sibling == item_node:
					continue  # Pula o item atual (será mostrado depois)
				
				# Esconde o irmão
				if sibling is CanvasItem:
					sibling.visible = false
				elif sibling is VisualInstance3D:
					sibling.visible = false
				elif sibling.has_method("set_visible"):
					sibling.set_visible(false)
				elif "visible" in sibling:
					sibling.visible = false
				
				_log_debug("🚫 Escondendo irmão: %s" % sibling.name)
	
	# APLICA VISIBILIDADE NO ITEM ALVO
	# Suporta Node3D, VisualInstance3D, MeshInstance3D, etc
	var applied = false
	
	if item_node is CanvasItem:
		item_node.visible = visible_
		applied = true
	elif item_node is VisualInstance3D:
		item_node.visible = visible_
		applied = true
	elif item_node.has_method("set_visible"):
		item_node.set_visible(visible_)
		applied = true
	elif "visible" in item_node:
		item_node.visible = visible_
		applied = true
	else:
		push_warning("apply_item_visibility: nó '%s' não tem propriedade 'visible'" % item_node.name)
		return false
	
	if not applied:
		return false
		
# ===== SISTEMA DE INVENTÁRIO POR RODADA =====

func init_player_inventory() -> bool:
	"""Inicializa inventário do jogador em uma rodada específica"""

	local_inventory = {
		"inventory": [],
		"equipped": {
			"hand-right": "",
			"hand-left": "",
			"head": "",
			"body": "",
			"back": ""
		},
		"stats": {
			"items_collected": 0,
			"items_used": 0,
			"items_dropped": 0,
			"items_equipped": 0
		}
	}
	
	_log_debug("✓ Inventário inicializado: Player %d" % player_id)
	return true
		
func add_item_to_inventory(item_name: String) -> bool:
	"""Adiciona item ao inventário do jogador"""
	# Valida item no ItemDatabase se disponível
	if ItemDatabase and not ItemDatabase.item_exists(item_name):
		push_error("PlayerRegistry: Item inválido: %s" % item_name)
		return false
	
	local_inventory["inventory"].append(item_name)
	local_inventory["stats"]["items_collected"] += 1
	
	_log_debug("✓ Item adicionado: %s → Player %s" % [item_name, player_name])
	
	return true

func remove_item_from_inventory(item_name: String) -> bool:
	"""Remove item do inventário do jogador"""
	
	if local_inventory.is_empty():
		return false
	
	var idx = local_inventory["inventory"].find(item_name)
	if idx == -1:
		_log_debug("⚠ Item não encontrado no inventário: %s" % item_name)
		return false
	
	local_inventory["inventory"].remove_at(idx)
	local_inventory["stats"]["items_used"] += 1
	
	_log_debug("✓ Item removido: %s de Player %d" % [item_name, player_id])
	
	return true

func equip_item(item_name: String, slot: String = "") -> bool:
	"""
	Equipa item em um slot (detecta automaticamente se não especificado)
	Slots válidos: hand-right, hand-left, head, body, back
	"""
	
	if local_inventory.is_empty():
		return false
	
	# Verifica se item está no inventário
	if item_name not in local_inventory["inventory"]:
		_log_debug("⚠ Item não está no inventário: %s" % item_name)
		return false
	
	# Detecta slot automaticamente se não especificado
	if slot.is_empty():
		if ItemDatabase:
			slot = ItemDatabase.get_slot(item_name)
		if slot.is_empty():
			push_error("PlayerRegistry: Não foi possível detectar slot para item: %s" % item_name)
			return false
	
	# Valida slot
	if not local_inventory["equipped"].has(slot):
		push_error("PlayerRegistry: Slot inválido: %s" % slot)
		return false
	
	# Valida se item pode ser equipado neste slot
	if ItemDatabase and not ItemDatabase.can_equip_in_slot(item_name, slot):
		push_error("PlayerRegistry: Item %s não pode ser equipado em %s" % [item_name, slot])
		return false
	
	# Desequipa item atual se houver
	var current_item = local_inventory["equipped"][slot]
	if not current_item.is_empty():
		unequip_item(slot)
	
	# Equipa novo item
	local_inventory["equipped"][slot] = item_name
	local_inventory["stats"]["items_equipped"] += 1
	
	_log_debug("✓ Item equipado: %s em %d" % [item_name, player_id])
		
	return true

func unequip_item(slot: String) -> bool:
	"""Desequipa item de um slot"""

	if local_inventory.is_empty():
		return false
	
	if not local_inventory["equipped"].has(slot):
		push_error("PlayerRegistry: Slot inválido: %s" % slot)
		return false
	
	var item_name = local_inventory["equipped"][slot]
	if item_name.is_empty():
		return false
	
	local_inventory["equipped"][slot] = ""
	
	_log_debug("✓ Item desequipado: %s de %s (Player %d)" % [item_name, slot, player_id])
	
	return true
	
func swap_equipped_item(new_item: String, slot: String = "") -> bool:
	"""
	Troca item equipado diretamente (desequipa antigo, equipa novo)
	Útil para trocas rápidas de armas/equipamentos
	"""
	
	if local_inventory.is_empty():
		return false
	
	# Detecta slot se não especificado
	if slot.is_empty():
		if ItemDatabase:
			slot = ItemDatabase.get_slot(new_item)
		if slot.is_empty():
			return false
	
	var old_item = local_inventory["equipped"][slot]
	
	# Desequipa item atual (se houver)
	if not old_item.is_empty():
		unequip_item(slot)
	
	# Equipa novo item
	if equip_item(new_item, slot):
		return true
	
	return false
	
func drop_item(item_name: String) -> bool:
	"""
	Remove item do inventário (simula drop)
	Se equipado, desequipa primeiro
	"""
	# Verifica se está equipado e desequipa
	var slot = get_equipped_slot(item_name)
	if not slot.is_empty():
		unequip_item(slot)
	
	# Remove do inventário
	if remove_item_from_inventory(item_name):
		if not local_inventory.is_empty():
			local_inventory["stats"]["items_dropped"] += 1
		_log_debug("✓ Item dropado: %s por Player %d" % [item_name, player_id])
		return true
	
	return false

func get_equipped_slot(item_name: String) -> String:
	"""Retorna slot onde item está equipado (ou "" se não equipado)"""
	
	if local_inventory.is_empty():
		return ""
	
	for slot in local_inventory["equipped"]:
		if local_inventory["equipped"][slot] == item_name:
			return slot
	
	return ""

func clear_player_inventory():
	"""Limpa inventário do jogador em uma rodada"""
	
	local_inventory.clear()
	_log_debug("✓ Inventário limpo: Player %d" % player_id)

# ===== UTILS =====

func setup_name_label():
	"""Configura label de nome para multiplayer"""
	if not name_label:
		return
	
	name_label.visible = true
	
	# COR BASEADA NO ID (consistente)
	var colors = [
		Color(1, 0.2, 0.2),    # Vermelho
		Color(0.2, 1, 0.2),    # Verde
		Color(0.2, 0.2, 1),    # Azul
		Color(1, 1, 0.2),      # Amarelo
		Color(1, 0.2, 1),      # Magenta
		Color(0.2, 1, 1)       # Ciano
	]
	var color_index = player_id % colors.size()
	name_label.modulate = colors[color_index]
	
	# CONFIGURAÇÃO DE BILLBOARD
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.pixel_size = 0.01
	
	# ESCONDE NOME DO JOGADOR LOCAL (OPCIONAL)
	if is_local_player:
		name_label.visible = false
	else:
		name_label.visible = true
		
func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if not debug:
		return
	
	if _is_server:
		print("[SERVER][PLAYER][ClientID: %d]%s" % [player_id, message])
	else:
		print("[CLIENT][PLAYER][ClientID: %d]%s" % [player_id, message])
		
func verificar_rede():
	var peer = multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	return false
	
