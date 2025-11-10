extends CharacterBody3D

# ===== REFERÊNCIAS =====
@onready var name_label: Label3D = $NameLabel
@onready var camera_controller: Node3D = $CameraController
@onready var debug_info: Label3D = $DebugInfo

# ===== DADOS DO JOGADOR =====
var player_id: int = 0
var player_name: String = ""
var is_local_player: bool = false

# ===== CONFIGURAÇÕES DE MOVIMENTO =====
@export var move_speed: float = 5.0
@export var run_speed: float = 8.0
@export var jump_velocity: float = 6.0
@export var gravity: float = 9.8
@export var rotation_speed: float = 10.0

# ===== ESTADO =====
var is_running: bool = false
var is_jumping: bool = false

# ===== SINCRONIZAÇÃO =====
@export var sync_rate: float = 20.0  # 20 updates/segundo
var sync_timer: float = 0.0
var sync_interval: float = 0.0

# ===== INICIALIZAÇÃO =====

func _ready():
	add_to_group("player")
	sync_interval = 1.0 / sync_rate
	
	if name_label:
		name_label.text = player_name if not player_name.is_empty() else "Player"
		name_label.pixel_size = 0.01
		name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	
	if debug_info:
		debug_info.visible = false

func initialize(p_id: int, p_name: String, spawn_position: Vector3):
	player_id = p_id
	player_name = p_name
	global_position = spawn_position
	
	if name_label:
		name_label.text = player_name
		name_label.visible = true  # Será escondido se for local

func set_as_local_player():
	is_local_player = true
	
	# Ativa física
	set_physics_process(true)
	
	# Ativa câmera
	if camera_controller and camera_controller.has_method("set_as_active"):
		camera_controller.set_as_active()
	
	# Esconde próprio nome
	if name_label:
		name_label.visible = false
	
	# Ativa debug
	if debug_info:
		debug_info.visible = true
	
	add_to_group("local_player")

# ===== MOVIMENTO E SINCRONIZAÇÃO =====

func _physics_process(delta: float):
	if is_local_player:
		_process_local_input(delta)
	
	# Aplica gravidade SEMPRE (importante para interpolação)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	
	move_and_slide()
	
	# Debug
	if debug_info and debug_info.visible and is_local_player:
		_update_debug_info()

func _process_local_input(delta: float):
	# Mouse capturado?
	var can_move = true
	if camera_controller and camera_controller.has_method("is_mouse_captured"):
		can_move = camera_controller.is_mouse_captured()
	
	# Pulo
	if can_move and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
		is_jumping = true
	elif is_on_floor():
		is_jumping = false
	
	# Corrida
	is_running = can_move and Input.is_action_pressed("run") and is_on_floor()
	var current_speed = run_speed if is_running else move_speed
	
	# Input de movimento
	var input_dir = Vector2.ZERO
	if can_move:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Direção baseada na câmera
	var direction = _calculate_movement_direction(input_dir)
	
	if direction.length() > 0.1:
		# Aplica velocidade
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
		
		# Rotaciona para frente do movimento
		var target_rotation = atan2(-direction.x, -direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	else:
		# Desacelera
		velocity.x = move_toward(velocity.x, 0, current_speed * delta * 10)
		velocity.z = move_toward(velocity.z, 0, current_speed * delta * 10)
	
	# Envia estado para servidor (só se conectado)
	if multiplayer.has_multiplayer_peer() and is_inside_tree():
		sync_timer += delta
		if sync_timer >= sync_interval:
			sync_timer = 0.0
			rpc("_server_receive_state", global_position, rotation, velocity, is_running, is_jumping)

# ===== CÁLCULO DE DIREÇÃO =====

func _calculate_movement_direction(input_dir: Vector2) -> Vector3:
	if input_dir.length() == 0:
		return Vector3.ZERO
	
	if not camera_controller:
		return Vector3(input_dir.x, 0, input_dir.y).normalized()
	
	var cam_basis = camera_controller.global_transform.basis
	var cam_forward = -cam_basis.z
	cam_forward.y = 0
	cam_forward = cam_forward.normalized()
	
	var cam_right = cam_basis.x
	cam_right.y = 0
	cam_right = cam_right.normalized()
	
	return (cam_forward * input_dir.y + cam_right * input_dir.x).normalized()

# ===== RPCs DE SINCRONIZAÇÃO =====

## Recebido no SERVIDOR
@rpc("any_peer", "call_remote", "unreliable")
func _server_receive_state(pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	# Apenas o servidor processa
	if not (multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() == 1):
		return
	
	global_position = pos
	rotation = rot
	velocity = vel
	is_running = running
	is_jumping = jumping
	
	# Reenvia para todos os outros clientes
	var sender_id = multiplayer.get_remote_sender_id()
	for peer_id in multiplayer.get_peers():
		if peer_id != sender_id:
			rpc_id(peer_id, "_client_receive_state", pos, rot, vel, running, jumping)

## Recebido no CLIENTE REMOTO
@rpc("authority", "call_remote", "unreliable")
func _client_receive_state(pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	if is_local_player:
		return  # Ignora para si mesmo
	
	# Atualiza estado diretamente (interpolação simples)
	global_position = pos
	rotation = rot
	velocity = vel
	is_running = running
	is_jumping = jumping

# ===== DEBUG =====

func _update_debug_info():
	var vel_horizontal = Vector2(velocity.x, velocity.z).length()
	
	debug_info.text = "╔═══ PLAYER ═══╗\n"
	debug_info.text += "%s (ID: %d)\n" % [player_name, player_id]
	debug_info.text += "Local: %s\n" % ("SIM" if is_local_player else "NÃO")
	debug_info.text += "──────────────\n"
	debug_info.text += "Vel: %.1f m/s\n" % vel_horizontal
	debug_info.text += "Pos: %.1f, %.1f, %.1f\n" % [global_position.x, global_position.y, global_position.z]
	debug_info.text += "Chão: %s\n" % ("SIM" if is_on_floor() else "NÃO")
	debug_info.text += "Correndo: %s | Pulando: %s\n" % [str(is_running), str(is_jumping)]
	debug_info.text += "╚══════════════╝"

# ===== GETTERS =====

func get_player_id() -> int:
	return player_id

func get_player_name() -> String:
	return player_name

func is_local() -> bool:
	return is_local_player
