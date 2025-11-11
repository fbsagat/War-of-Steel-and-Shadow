extends CharacterBody3D
## SimplePlayer - Player multiplayer simples com sincronização
## Movimento baseado na direção da câmera com strafe

# ===== CONFIGURAÇÕES =====
@export_category("Movement")
@export var walk_speed: float = 5.0
@export var run_speed: float = 8.0
@export var jump_velocity: float = 6.0
@export var acceleration: float = 10.0
@export var deceleration: float = 12.0
@export var air_control: float = 0.3
@export var gravity: float = 20.0
@export var rotation_speed: float = 10.0

@export_category("Network")
@export var sync_rate: float = 0.05  # 20 updates por segundo

@export_category("Debug")
@export var debug: bool = false

# ===== IDENTIFICAÇÃO MULTIPLAYER =====
var player_id: int = 0
var player_name: String = ""
var is_local_player: bool = false

# ===== ESTADO DO JOGADOR =====
var is_running: bool = false
var is_jumping: bool = false

# ===== SINCRONIZAÇÃO =====
var sync_timer: float = 0.0

# ===== REFERÊNCIAS =====
@onready var camera_controller: Node3D = $CameraController
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var name_label: Label3D = $NameLabel

# ===== CORES PARA JOGADORES =====
const PLAYER_COLORS: Array[Color] = [
	Color(0.3, 0.5, 0.8),  # Azul
	Color(0.8, 0.3, 0.3),  # Vermelho
	Color(0.3, 0.8, 0.3),  # Verde
	Color(0.8, 0.8, 0.3),  # Amarelo
	Color(0.8, 0.3, 0.8),  # Roxo
	Color(0.3, 0.8, 0.8),  # Ciano
	Color(0.8, 0.5, 0.3),  # Laranja
	Color(0.5, 0.3, 0.8),  # Índigo
]

# ===== INICIALIZAÇÃO =====

func _ready():
	add_to_group("player")
	
	# Desativa processos por padrão (será ativado após initialize())
	set_physics_process(false)
	set_process(false)

# ===== INICIALIZAÇÃO MULTIPLAYER =====

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
	
	# Aplica cor baseada no ID
	_apply_player_color()
	
	# Ativa processos
	set_physics_process(true)
	set_process(true)
	
	_log_debug("Player inicializado: %s (ID: %d)" % [player_name, player_id])
	
	# Registra no RoundRegistry
	if RoundRegistry:
		RoundRegistry.register_spawned_player(player_id, self)

func set_as_local_player():
	"""Configura este player como o jogador local"""
	is_local_player = true
	_log_debug("✓ Configurado como jogador local")

# ===== FÍSICA E MOVIMENTO =====

func _physics_process(delta: float):
	# Gravidade
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	# Só processa input se for o jogador local
	if is_multiplayer_authority():
		_process_local_movement(delta)
		_send_state_to_network(delta)
	
	# Move o personagem
	move_and_slide()

func _process_local_movement(delta: float):
	"""Processa movimento do jogador local"""
	
	# Input de movimento
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Verifica corrida
	is_running = Input.is_action_pressed("run")
	
	# Pulo
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity
		is_jumping = true
	elif is_on_floor():
		is_jumping = false
	
	# Calcula direção do movimento baseado na câmera
	var move_dir = Vector3.ZERO
	
	if input_dir.length() > 0.1 and camera_controller:
		# Pega direções da câmera
		var cam_forward = camera_controller.get_forward_direction()
		var cam_right = camera_controller.get_right_direction()
		
		# Movimento relativo à câmera (strafe)
		move_dir = (cam_forward * input_dir.y + cam_right * input_dir.x).normalized()
	
	# Aplica movimento
	var target_speed = run_speed if is_running else walk_speed
	var current_accel = acceleration if is_on_floor() else acceleration * air_control
	
	if move_dir.length() > 0.1:
		# Acelera na direção do input
		var target_velocity = move_dir * target_speed
		velocity.x = lerp(velocity.x, target_velocity.x, current_accel * delta)
		velocity.z = lerp(velocity.z, target_velocity.z, current_accel * delta)
		
		# Rotaciona o corpo na direção do movimento
		var target_rotation = atan2(move_dir.x, move_dir.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	else:
		# Desacelera
		velocity.x = lerp(velocity.x, 0.0, deceleration * delta)
		velocity.z = lerp(velocity.z, 0.0, deceleration * delta)

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

# ===== VISUAL =====

func _apply_player_color():
	"""Aplica cor única ao player baseada no ID"""
	if not mesh:
		return
	
	# Seleciona cor baseada no ID
	var color_index = player_id % PLAYER_COLORS.size()
	var player_color = PLAYER_COLORS[color_index]
	
	# Cria material
	var material = StandardMaterial3D.new()
	material.albedo_color = player_color
	material.metallic = 0.3
	material.roughness = 0.7
	material.rim_enabled = true
	material.rim = 0.5
	material.rim_tint = 0.8
	
	# Aplica material
	mesh.material_override = material
	
	_log_debug("Cor aplicada: %s" % player_color)

# ===== CLEANUP =====

func _exit_tree():
	# Remove do registro
	if RoundRegistry:
		RoundRegistry.unregister_spawned_player(player_id)
	
	# Libera mouse se for local
	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	_log_debug("Player destruído")

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug:
		print("[Player:%d] %s" % [player_id, message])

func teleport_to(new_position: Vector3):
	"""Teleporta o player (apenas servidor)"""
	if multiplayer.is_server():
		global_position = new_position
