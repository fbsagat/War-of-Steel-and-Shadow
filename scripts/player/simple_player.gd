extends CharacterBody3D
## Player com movimento strafe correto baseado na direção da câmera

# Referências dos nós
@onready var name_label: Label3D = $NameLabel
@onready var camera_controller: Node3D = $CameraController
@onready var network_sync: Node = $NetworkSync
@onready var debug_info: Label3D = $DebugInfo

# Dados do jogador
var player_id: int = 0
var player_name: String = ""
var is_local_player: bool = false

# Configurações de movimento
@export var move_speed: float = 5.0
@export var run_speed: float = 8.0
@export var jump_velocity: float = 6.0
@export var acceleration: float = 10.0
@export var deceleration: float = 8.0
@export var air_control: float = 0.3
@export var rotation_speed: float = 10.0  # Velocidade de rotação do personagem

# Física
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Estado atual
var is_jumping: bool = false
var is_running: bool = false
var current_speed: float = 0.0

# Debug
var frame_count: int = 0

func _ready():
	add_to_group("player")
	
	if name_label:
		name_label.text = player_name if not player_name.is_empty() else "Player"
		name_label.pixel_size = 0.01
		name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	
	if debug_info:
		debug_info.visible = false

func initialize(p_id: int, p_name: String, spawn_position: Vector3):
	"""Inicializa o jogador com seus dados"""
	player_id = p_id
	player_name = p_name
	global_position = spawn_position
	
	if name_label:
		name_label.text = player_name
	
	# IMPORTANTE: Configura NetworkSync para jogadores remotos
	if network_sync and not is_local_player:
		await get_tree().process_frame
		network_sync.setup(player_id, false)
		set_physics_process(false)  # Desabilita physics para remotos
		print("[Player %d] Configurado como REMOTO" % player_id)
	
	print("[Player] Inicializado: %s (ID: %d) em %s" % [player_name, player_id, spawn_position])

func set_as_local_player():
	"""Define este jogador como o jogador local (controlável)"""
	is_local_player = true
	
	# Ativa physics process
	set_physics_process(true)
	
	# Ativa a câmera
	if camera_controller:
		camera_controller.set_as_active()
		print("[Player] Câmera ativada")
	
	# Esconde label do nome
	if name_label:
		name_label.visible = false
	
	# Configura NetworkSync
	if network_sync:
		network_sync.setup(player_id, true)
		print("[Player] NetworkSync configurado para LOCAL")
	
	# Ativa debug
	if debug_info:
		debug_info.visible = true
	
	# Adiciona ao grupo
	add_to_group("local_player")
	
	print("[Player] ✓ Definido como jogador local: %s (ID: %d)" % [player_name, player_id])

func _physics_process(delta: float):
	frame_count += 1
	
	# Apenas processa physics no jogador local
	if not is_local_player:
		return
	
	# Verifica se mouse está capturado
	var can_move = true
	if camera_controller and camera_controller.has_method("is_mouse_captured"):
		can_move = camera_controller.is_mouse_captured()
	
	# Aplica gravidade
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		if velocity.y < 0:
			velocity.y = 0
	
	# Pulo (apenas se pode mover)
	if can_move and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
		is_jumping = true
	elif is_on_floor():
		is_jumping = false
	
	# Corrida
	is_running = can_move and Input.is_action_pressed("run") and is_on_floor()
	current_speed = run_speed if is_running else move_speed
	
	# Captura input de movimento
	var input_dir = Vector2.ZERO
	if can_move:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Calcula direção de movimento BASEADA NA CÂMERA
	var direction = _calculate_movement_direction(input_dir)
	
	# Aplica movimento
	if direction.length() > 0.1:
		# Calcula velocidade alvo
		var target_velocity = direction * current_speed
		var control_factor = air_control if not is_on_floor() else 1.0
		
		# Interpola velocidade horizontal
		velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta * control_factor)
		velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta * control_factor)
		
		# Rotaciona o personagem na direção do movimento
		var target_rotation = atan2(-direction.x, -direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	else:
		# Desacelera
		velocity.x = lerp(velocity.x, 0.0, deceleration * delta)
		velocity.z = lerp(velocity.z, 0.0, deceleration * delta)
	
	# Move o personagem
	move_and_slide()
	
	# Atualiza debug
	if debug_info and debug_info.visible:
		_update_debug_info()
	
	# Toggle debug com Tab
	if Input.is_action_just_pressed("ui_focus_next"):  # Tab
		if debug_info:
			debug_info.visible = !debug_info.visible

func _calculate_movement_direction(input_dir: Vector2) -> Vector3:
	"""
	Calcula direção de movimento baseada na câmera
	W/S = Frente/Trás na direção da câmera
	A/D = Strafe esquerda/direita
	"""
	if input_dir.length() == 0:
		return Vector3.ZERO
	
	if not camera_controller:
		# Fallback: movimento mundial
		return Vector3(input_dir.x, 0, input_dir.y).normalized()
	
	# Pega direções da câmera (apenas no plano horizontal)
	var cam_basis = camera_controller.global_transform.basis
	
	# Frente da câmera (W/S)
	var cam_forward = -cam_basis.z
	cam_forward.y = 0
	cam_forward = cam_forward.normalized()
	
	# Direita da câmera (A/D)
	var cam_right = cam_basis.x
	cam_right.y = 0
	cam_right = cam_right.normalized()
	
	# Combina as direções baseado no input
	# input_dir.y = frente/trás (W/S)
	# input_dir.x = esquerda/direita (A/D)
	var direction = (cam_forward * input_dir.y + cam_right * input_dir.x).normalized()
	
	return direction

func _update_debug_info():
	"""Atualiza informações de debug"""
	var vel_horizontal = Vector2(velocity.x, velocity.z).length()
	
	debug_info.text = "╔═══ PLAYER ═══╗\n"
	debug_info.text += "%s (ID: %d)\n" % [player_name, player_id]
	debug_info.text += "Local: %s\n" % ("SIM" if is_local_player else "NÃO")
	debug_info.text += "──────────────\n"
	debug_info.text += "Vel: %.1f m/s\n" % vel_horizontal
	debug_info.text += "Pos: %.1f, %.1f\n" % [global_position.x, global_position.z]
	debug_info.text += "Y: %.1f\n" % global_position.y
	debug_info.text += "──────────────\n"
	debug_info.text += "%s%s\n" % [
		"Correndo" if is_running else "Andando",
		" | Pulando" if is_jumping else ""
	]
	debug_info.text += "Chão: %s\n" % ("SIM" if is_on_floor() else "NÃO")
	
	# Info de rede
	if network_sync and network_sync.has_method("get_network_stats"):
		var stats = network_sync.get_network_stats()
		debug_info.text += "──────────────\n"
		debug_info.text += "Buffer: %d\n" % stats.get("buffer_size", 0)
	
	debug_info.text += "╚══════════════╝"

# ===== GETTERS =====

func get_player_id() -> int:
	return player_id

func get_player_name() -> String:
	return player_name

func is_local() -> bool:
	return is_local_player
