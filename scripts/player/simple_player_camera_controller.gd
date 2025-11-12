extends Node3D
## Controlador de câmera em terceira pessoa - SEM conflitos de input

# Referências
@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D

# Configurações da câmera
@export var mouse_sensitivity: float = 0.3
@export var min_pitch: float = -60.0  # Ângulo mínimo (olhar para baixo)
@export var max_pitch: float = 60.0   # Ângulo máximo (olhar para cima)
@export var camera_distance: float = 5.0  # Distância da câmera
@export var camera_smoothness: float = 10.0  # Suavidade do movimento

# Estado
var is_active: bool = false
var mouse_captured: bool = false
var rotation_x: float = 0.0  # Pitch (vertical)
var rotation_y: float = 0.0  # Yaw (horizontal)

func _ready():
	# Configura SpringArm
	if spring_arm:
		spring_arm.spring_length = camera_distance
		spring_arm.collision_mask = 1  # Colide apenas com layer 1 (mundo)
	
	# Desativa por padrão
	if camera:
		camera.current = false
	
	print("[Camera] Câmera inicializada")

func set_as_active():
	"""Ativa esta câmera como a câmera principal"""
	is_active = true
	
	if camera:
		camera.current = true
	
	# Captura o mouse
	capture_mouse()
	
	print("[Camera] ✓ Câmera ativada e mouse capturado")

func capture_mouse():
	"""Captura o cursor do mouse"""
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	mouse_captured = true
	print("[Camera] Mouse capturado")

func release_mouse():
	"""Libera o cursor do mouse"""
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mouse_captured = false
	print("[Camera] Mouse liberado")

func _input(event: InputEvent):
	if not is_active:
		return
	
	# Toggle captura do mouse com ESC ou ação específica
	if event.is_action_pressed("ui_cancel"):
		if mouse_captured:
			release_mouse()
		else:
			capture_mouse()
		get_viewport().set_input_as_handled()  # IMPORTANTE: Marca input como tratado
		return
	
	# Movimento do mouse - APENAS quando capturado
	if event is InputEventMouseMotion and mouse_captured:
		# Rotação horizontal (yaw)
		rotation_y -= event.relative.x * mouse_sensitivity * 0.01
		
		# Rotação vertical (pitch)
		rotation_x -= event.relative.y * mouse_sensitivity * 0.01
		rotation_x = clamp(rotation_x, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
		
		# Marca como tratado para não propagar
		get_viewport().set_input_as_handled()

func _process(delta: float):
	if not is_active:
		return
	
	# Aplica rotações suavemente
	rotation.y = lerp_angle(rotation.y, rotation_y, camera_smoothness * delta)
	rotation.x = lerp_angle(rotation.x, rotation_x, camera_smoothness * delta)

func get_forward_direction() -> Vector3:
	"""Retorna a direção para frente da câmera (no plano horizontal)"""
	var forward = -global_transform.basis.z
	forward.y = 0
	return forward.normalized()

func get_right_direction() -> Vector3:
	"""Retorna a direção para a direita da câmera"""
	var right = global_transform.basis.x
	right.y = 0
	return right.normalized()

func set_distance(distance: float):
	"""Define a distância da câmera"""
	camera_distance = distance
	if spring_arm:
		spring_arm.spring_length = distance

func set_sensitivity(sensitivity: float):
	"""Define a sensibilidade do mouse"""
	mouse_sensitivity = sensitivity

func is_mouse_captured() -> bool:
	"""Retorna se o mouse está capturado"""
	return mouse_captured
