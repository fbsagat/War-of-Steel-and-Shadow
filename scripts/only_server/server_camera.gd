extends Camera3D

@export var move_speed: float = 5.0
@export var mouse_sensitivity: float = 0.002

var rotation_y: float = 0.0
var rotation_x: float = 0.0
var mouse_mode: bool = true
var debug: bool = true

func _ready():
	if not OS.has_feature("Server"):  # Só ativa se NÃO for headless
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		queue_free()  # Remove no servidor headless

func _input(event):
	if event is InputEventMouseMotion && Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation_y -= event.relative.x * mouse_sensitivity
		rotation_x -= event.relative.y * mouse_sensitivity
		rotation_x = clamp(rotation_x, -PI/2, PI/2)
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

	var input_dir = Vector3.ZERO
	if Input.is_action_pressed("move_forward"):    input_dir.z -= 1
	if Input.is_action_pressed("move_backward"):  input_dir.z += 1
	if Input.is_action_pressed("move_left"):  input_dir.x -= 1
	if Input.is_action_pressed("move_right"): input_dir.x += 1

	if input_dir.length_squared() > 0.01:
		var yaw = Basis(Vector3.UP, rotation_y)
		var direction = input_dir.normalized()
		var movement = yaw * direction
		global_position += movement * move_speed * delta

	rotation = Vector3(rotation_x, rotation_y, 0)
