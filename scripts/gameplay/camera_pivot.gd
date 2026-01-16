## CameraController.gd
## Controlador de câmera em terceira pessoa com transições suaves no modo travado
## - FREE_LOOK: movimento livre com mouse
## - BEHIND_PLAYER: câmera travada com elevação e afastamento suaves

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
# EXPORT — TRANSIÇÕES DO MODO TRAVADO (NOVIDADE!)
# ==============================
@export_group("Transições do Modo Travado", "Configurações suaves para altura e distância")
@export var use_smooth_transitions: bool = true  # Ativa transições suaves
@export_range(0.1, 10.0, 0.1) var transition_speed: float = 3.0  # Velocidade geral das transições
@export_range(0.0, 5.0, 0.1) var behind_elevation_offset: float = 1.0  # Quanto subir no modo travado
@export_range(0.0, 10.0, 0.1) var behind_distance_offset: float = 2.0  # Quanto afastar no modo travado
@export_range(0.0, 5.0, 0.1) var elevation_smoothing: float = 1.0  # Suavização específica da altura
@export_range(0.0, 5.0, 0.1) var distance_smoothing: float = 1.0  # Suavização específica da distância
@export var instant_transition_on_activate: bool = false  # Pula transição ao ATIVAR o modo (útil para mira rápida)
@export var instant_transition_on_release: bool = false  # Pula transição ao SAIR do modo

# ==============================
# VARIÁVEIS INTERNAS
# ==============================
var target_rotation: Vector2 = Vector2.ZERO  # (pitch, yaw) em radianos
var current_mode: CameraMode = CameraMode.FREE_LOOK
var is_active: bool = false
var _current_height: float = 0.0  # Altura interpolada
var _current_distance: float = 0.0  # Distância interpolada
var _last_mode: CameraMode = CameraMode.FREE_LOOK  # Para detectar mudanças de modo
var _target_yaw: float = 0.0      # Yaw alvo (atualizado na física)
var _target_pitch: float = 0.0    # Pitch alvo (atualizado na física)
var _visual_yaw: float = 0.0      # Yaw interpolado para renderização
var _visual_pitch: float = 0.0    # Pitch interpolado para renderização
var _mouse_delta: Vector2 = Vector2.ZERO  # Acumulador de mouse

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
	
	# Inicializa valores interpolados
	_current_height = free_look_height_offset
	_current_distance = base_distance
	_last_mode = current_mode

	if debug:
		print("[CameraController] Inicializado. Alvo:", target.name)

func set_target(new_target: Node3D):
	"""Define o alvo da câmera"""
	target = new_target

func set_as_active():
	is_active = true
	if camera:
		camera.current = true
	if debug:
		print("[Camera]  Câmera ativada e mouse capturado")

func _initialize_target_rotation():
	"""Inicializa a rotação alvo com base na rotação atual do alvo."""
	target_rotation.y = target.rotation.y
	target_rotation.x = 0.0

# ==============================
# ENTRADA DE USUÁRIO
# ==============================
func _input(event):
	if not is_active or current_mode != CameraMode.FREE_LOOK:
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	if event is InputEventMouseMotion:
		_mouse_delta += event.relative

# ==============================
# API PÚBLICA — CONTROLE DE MODO
# ==============================

## Força a câmera a entrar no modo travado atrás do jogador.
func force_behind_player():
	# Detecta mudança de modo para resetar transições se necessário
	if current_mode != CameraMode.BEHIND_PLAYER:
		_last_mode = current_mode
		
		# Opção para pular transição na ativação (ex: mira rápida)
		if instant_transition_on_activate:
			_current_height = behind_height_offset + behind_elevation_offset
			_current_distance = base_distance + behind_distance_offset
	
	current_mode = CameraMode.BEHIND_PLAYER
	if debug:
		print("[CameraController] Modo travado ativado.")


## Retorna a câmera ao modo livre com mouse.
func release_to_free_look():
	# Detecta mudança de modo para resetar transições se necessário
	if current_mode != CameraMode.FREE_LOOK:
		_last_mode = current_mode
		
		# Opção para pular transição na liberação
		if instant_transition_on_release:
			_current_height = free_look_height_offset
			_current_distance = base_distance
	
	current_mode = CameraMode.FREE_LOOK
	# Alinha suavemente ao jogador para evitar salto
	target_rotation.y = target.rotation.y
	if debug:
		print("[CameraController] Modo livre reativado.")


# ==============================
# LÓGICA DE TRANSIÇÃO (NOVIDADE!)
# ==============================
func _calculate_target_values() -> Array:
	"""Calcula os valores alvo de altura e distância baseado no modo atual"""
	var target_height: float
	var target_distance: float
	
	match current_mode:
		CameraMode.FREE_LOOK:
			target_height = free_look_height_offset
			target_distance = base_distance
			
		CameraMode.BEHIND_PLAYER:
			target_height = behind_height_offset + behind_elevation_offset
			target_distance = base_distance + behind_distance_offset
	
	return [target_height, target_distance]


func _update_transitions(delta: float) -> void:
	"""Atualiza as transições suaves de altura e distância"""
	if not use_smooth_transitions:
		return
	
	var target_values = _calculate_target_values()
	var target_height = target_values[0]
	var target_distance = target_values[1]
	
	# Velocidades de interpolação personalizadas
	var height_speed = transition_speed * elevation_smoothing
	var distance_speed = transition_speed * distance_smoothing
	
	# Interpolação suave
	_current_height = lerp(_current_height, target_height, height_speed * delta)
	_current_distance = lerp(_current_distance, target_distance, distance_speed * delta)


# ==============================
# ATUALIZAÇÃO PRINCIPAL
# ==============================
func _physics_process(delta):
	if not is_active or target == null:
		return
	
		# Atualiza rotação ALVO com base no mouse acumulado
	if current_mode == CameraMode.FREE_LOOK:
		if _mouse_delta.length() > 0.1:
			_target_yaw -= _mouse_delta.x * free_look_rotation_speed
			_target_pitch += _mouse_delta.y * free_look_rotation_speed
			_mouse_delta = Vector2.ZERO
		
		# Aplica limites de pitch no ALVO
		_target_pitch = clamp(_target_pitch, 
			deg_to_rad(free_look_min_pitch_deg),
			deg_to_rad(free_look_max_pitch_deg))
	
	elif current_mode == CameraMode.BEHIND_PLAYER:
		_target_yaw = target.rotation.y
		_target_pitch = deg_to_rad(behind_target_pitch_deg)
	
	# Atualiza transições primeiro
	_update_transitions(delta)
	
	# Define parâmetros com base no modo atual
	var current_smoothness: float
	var current_target_pitch_rad: float
	var min_pitch_rad: float
	var max_pitch_rad: float
	var current_height_offset: float = _current_height  # Usa altura interpolada
	var current_distance: float = _current_distance    # Usa distância interpolada

	match current_mode:
		CameraMode.FREE_LOOK:
			current_smoothness = free_look_smoothness
			min_pitch_rad = deg_to_rad(free_look_min_pitch_deg)
			max_pitch_rad = deg_to_rad(free_look_max_pitch_deg)
			# target_rotation.x já é controlado por _input

		CameraMode.BEHIND_PLAYER:
			current_smoothness = behind_smoothness
			current_target_pitch_rad = deg_to_rad(behind_target_pitch_deg)
			min_pitch_rad = current_target_pitch_rad
			max_pitch_rad = current_target_pitch_rad
			# Sincroniza yaw com o jogador
			target_rotation.y = target.rotation.y
			# Suaviza pitch para o valor alvo
			target_rotation.x = lerp_angle(target_rotation.x, current_target_pitch_rad, current_smoothness * delta)

	# Aplica limites de pitch
	target_rotation.x = clamp(target_rotation.x, min_pitch_rad, max_pitch_rad)

	# Aplica interpolação suave na rotação da câmera
	rotation.x = lerp_angle(rotation.x, target_rotation.x, current_smoothness * delta)
	rotation.y = lerp_angle(rotation.y, target_rotation.y, current_smoothness * delta)

	# Atualiza posição da câmera COM ALTURA INTERPOLADA
	global_position = target.global_position + Vector3.UP * current_height_offset

	# Atualiza SpringArm com DISTÂNCIA INTERPOLADA
	if spring_arm:
		spring_arm.spring_length = current_distance

	# Debug opcional
	if debug:
		var mode_name = "BEHIND" if current_mode == CameraMode.BEHIND_PLAYER else "FREE"
		print("[CameraController] Modo:", mode_name,
			  "| Altura:", "%.2f" % current_height_offset,
			  "| Distância:", "%.2f" % current_distance,
			  "| Yaw:", "%.1f°" % rad_to_deg(rotation.y),
			  "| Pitch:", "%.1f°" % rad_to_deg(rotation.x))

# ==============================
# RENDERIZAÇÃO: interpola visualmente
# ==============================
func _process(delta):
	if not is_active or target == null:
		return
	
	# Interpolação SUAVE para renderização
	var interp_speed = 18.0  # Ajustar conforme necessidade (10-20 é bom)
	_visual_yaw = lerp_angle(_visual_yaw, _target_yaw, interp_speed * delta)
	_visual_pitch = lerp_angle(_visual_pitch, _target_pitch, interp_speed * delta)
	
	# Aplica a rotação INTERPOLADA visualmente
	rotation.y = _visual_yaw
	rotation.x = _visual_pitch
	
	# Atualiza posição da câmera (com altura interpolada)
	global_position = target.global_position + Vector3.UP * _current_height
	if spring_arm:
		spring_arm.spring_length = _current_distance
