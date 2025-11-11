## CameraController.gd
## Controlador de câmera em terceira pessoa com dois modos:
## - FREE_LOOK: movimento livre com mouse
## - BEHIND_PLAYER: câmera travada suavemente atrás do jogador
##
## Recomenda-se usar com um SpringArm3D filho para colisão com o ambiente.

extends Node3D

# ==============================
# TIPOS DE MODO DE CÂMERA
# ==============================
enum CameraMode { FREE_LOOK, BEHIND_PLAYER }


# ==============================
# EXPORT — CONFIGURAÇÕES GERAIS
# ==============================
@export var debug: bool = false
@export var target: Node3D:
	set(value):
		target = value
		if is_node_ready():
			_initialize_target_rotation()
@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D

@export_range(0.1, 20.0, 0.1) var base_distance: float = 8.0:
	set(value):
		base_distance = value
		if spring_arm:
			spring_arm.spring_length = base_distance

@export var collision_margin: float = 0.2


# ==============================
# EXPORT — CONFIGURAÇÕES DO MODO LIVRE (FREE_LOOK)
# ==============================
@export_group("Modo Livre (Free Look)")
@export var free_look_rotation_speed: float = 0.002
@export_range(1.0, 30.0, 0.1) var free_look_smoothness: float = 10.0
@export_range(-80, 0, 1) var free_look_min_pitch_deg: float = -70
@export_range(0, 80, 1) var free_look_max_pitch_deg: float = 70
@export var free_look_height_offset: float = 1.6


# ==============================
# EXPORT — CONFIGURAÇÕES DO MODO TRAVADO (BEHIND_PLAYER)
# ==============================
@export_group("Modo Travado (Behind Player)")
@export_range(1.0, 30.0, 0.1) var behind_smoothness: float = 12.0
@export var behind_height_offset: float = 1.4
@export_range(-30, 30, 1) var behind_target_pitch_deg: float = -10  # inclinação suave para baixo
@export var disable_mouse_in_behind_mode: bool = true


# ==============================
# VARIÁVEIS INTERNAS
# ==============================
var target_rotation: Vector2 = Vector2.ZERO  # (pitch, yaw) em radianos
var current_mode: CameraMode = CameraMode.FREE_LOOK
var is_active: bool = false

# ==============================
# INICIALIZAÇÃO
# ==============================
func _ready():
	add_to_group("camera_controller")
	if target == null:
		push_error("[CameraController] Alvo (target) não definido no Inspector!")
		return

	spring_arm = get_node_or_null("SpringArm3D") as SpringArm3D
	if spring_arm:
		spring_arm.spring_length = base_distance
		spring_arm.margin = collision_margin

	_initialize_target_rotation()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if debug:
		print("[CameraController] Inicializado. Alvo:", target.name)

func set_target(new_target: Node3D):
	"""Define o alvo da câmera"""
	target = new_target

func set_as_active():
	is_active = true
	if camera:
		camera.current = true
	print("[Camera] ✓ Câmera ativada e mouse capturado")

func _initialize_target_rotation():
	"""Inicializa a rotação alvo com base na rotação atual do alvo."""
	target_rotation.y = target.rotation.y
	target_rotation.x = 0.0


# ==============================
# ENTRADA DE USUÁRIO
# ==============================
func _input(event):
	if target == null:
		return

	# Ignora mouse no modo travado, se configurado
	if current_mode == CameraMode.BEHIND_PLAYER and disable_mouse_in_behind_mode:
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		target_rotation.y -= event.relative.x * free_look_rotation_speed
		target_rotation.x += event.relative.y * free_look_rotation_speed


# ==============================
# API PÚBLICA — CONTROLE DE MODO
# ==============================

## Força a câmera a entrar no modo travado atrás do jogador.
func force_behind_player():
	current_mode = CameraMode.BEHIND_PLAYER
	if debug:
		print("[CameraController] Modo travado ativado.")


## Retorna a câmera ao modo livre com mouse.
func release_to_free_look():
	current_mode = CameraMode.FREE_LOOK
	# Alinha suavemente ao jogador para evitar salto
	target_rotation.y = target.rotation.y
	if debug:
		print("[CameraController] Modo livre reativado.")


# ==============================
# ATUALIZAÇÃO PRINCIPAL
# ==============================
func _process(delta):
	if not is_active:
		return
	if target == null:
		return

	# Atualiza parâmetros com base no modo atual
	var current_smoothness: float
	var current_height_offset: float
	var current_target_pitch_rad: float
	var min_pitch_rad: float
	var max_pitch_rad: float

	match current_mode:
		CameraMode.FREE_LOOK:
			current_smoothness = free_look_smoothness
			current_height_offset = free_look_height_offset
			min_pitch_rad = deg_to_rad(free_look_min_pitch_deg)
			max_pitch_rad = deg_to_rad(free_look_max_pitch_deg)
			# target_rotation.x já é controlado por _input

		CameraMode.BEHIND_PLAYER:
			current_smoothness = behind_smoothness
			current_height_offset = behind_height_offset
			current_target_pitch_rad = deg_to_rad(behind_target_pitch_deg)
			min_pitch_rad = current_target_pitch_rad
			max_pitch_rad = current_target_pitch_rad
			# Sincroniza yaw com o jogador
			target_rotation.y = target.rotation.y
			# Suaviza pitch para o valor alvo
			target_rotation.x = lerp(target_rotation.x, current_target_pitch_rad, current_smoothness * delta)

	# Aplica limites de pitch
	target_rotation.x = clamp(target_rotation.x, min_pitch_rad, max_pitch_rad)

	# Aplica interpolação suave na rotação da câmera
	rotation.x = lerp_angle(rotation.x, target_rotation.x, current_smoothness * delta)
	rotation.y = lerp_angle(rotation.y, target_rotation.y, current_smoothness * delta)

	# Atualiza posição da câmera
	global_position = target.global_position + Vector3.UP * current_height_offset

	# Atualiza SpringArm (se existir)
	if spring_arm:
		spring_arm.spring_length = base_distance

	# Debug opcional
	if debug:
		var mode_name = "BEHIND" if current_mode == CameraMode.BEHIND_PLAYER else "FREE"
		print("[CameraController] Modo:", mode_name,
			  "| Yaw:", "%.1f°" % rad_to_deg(rotation.y),
			  "| Pitch:", "%.1f°" % rad_to_deg(rotation.x))
