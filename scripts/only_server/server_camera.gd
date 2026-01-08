extends Camera3D

@export var base_speed: float = 5.0
@export var speed_step: float = 1.0
@export var min_speed: float = 2.0
@export var max_speed: float = 60.0
@export var mouse_sensitivity: float = 0.002
@export var round_id: int


var current_speed: float = 5.0
var rotation_y: float = 0.0
var rotation_x: float = 0.0
var mouse_mode: bool = true
var debug: bool = true

func _ready():
	if not OS.has_feature("Server"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		queue_free()

func _input(event):
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotation_y -= event.relative.x * mouse_sensitivity
			rotation_x -= event.relative.y * mouse_sensitivity
			rotation_x = clamp(rotation_x, -PI/2, PI/2)
		
		# Roda do mouse para ajustar velocidade
		if event is InputEventMouseButton && event.is_pressed():
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				current_speed = min(current_speed + speed_step, max_speed)
				if debug:
					print("[Camera] Velocidade: %.1f" % current_speed)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				current_speed = max(current_speed - speed_step, min_speed)
				if debug:
					print("[Camera] Velocidade: %.1f" % current_speed)

	if event.is_action_pressed("ui_cancel"):
		_toggle_mouse_mode()
		
func _toggle_mouse_mode():
	mouse_mode = not mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if not mouse_mode else Input.MOUSE_MODE_CAPTURED
	if debug:
		print("[Player] Mouse %s." % ("liberado" if not mouse_mode else "capturado"))

func _process(delta):
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	# Monta vetor de movimento no plano local (X = direita, Z = frente)
	var input_dir = Vector3.ZERO

	if Input.is_action_pressed("move_forward"):   # W
		input_dir.z -= 1
	if Input.is_action_pressed("move_backward"): # S
		input_dir.z += 1
	if Input.is_action_pressed("move_left"):     # A
		input_dir.x -= 1
	if Input.is_action_pressed("move_right"):    # D
		input_dir.x += 1

	# Aplica rotação da câmera (pitch + yaw) ao movimento horizontal/plano
	if input_dir.length_squared() > 0.01:
		var camera_basis = Basis.from_euler(Vector3(rotation_x, rotation_y, 0))
		var direction = camera_basis * input_dir.normalized()
		global_position += direction * current_speed * delta

	# Movimento vertical absoluto (Shift = subir, Ctrl = descer)
	if Input.is_key_pressed(KEY_SHIFT):
		global_position += Vector3.UP * current_speed * delta
	if Input.is_key_pressed(KEY_CTRL):
		global_position -= Vector3.UP * current_speed * delta

	# Atualiza rotação
	rotation = Vector3(rotation_x, rotation_y, 0)
