# CameraController.gd
# Controlador de câmera em terceira pessoa com dois modos:
# - FREE_LOOK: movimento livre com mouse
# - BEHIND_PLAYER: câmera travada suavemente atrás do jogador
#
# Recomenda-se usar com um SpringArm3D filho para colisão com o ambiente.

extends Node3D

# ==============================
# TIPOS DE MODO DE CÂMERA
# ==============================
enum CameraMode { FREE_LOOK, BEHIND_PLAYER }


# ==============================
# EXPORT — CONFIGURAÇÕES GERAIS
# ==============================
var _target: Node3D = null

@export var debug: bool = false

# Export com setter/getter seguro — aceita ser configurado no Inspector
@export var target: Node3D:
	set(value):
		_target = value
		if _target and is_inside_tree():
			_initialize_target_rotation()
	get:
		return _target

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
var spring_arm: SpringArm3D = null
var target_rotation: Vector2 = Vector2.ZERO  # (pitch, yaw) em radianos
var current_mode: CameraMode = CameraMode.FREE_LOOK


# ==============================
# INICIALIZAÇÃO
# ==============================
func _ready():
	# garante estar no grupo (útil para busca por grupo)
	if not is_in_group("camera_controller"):
		add_to_group("camera_controller")

	# tenta resolver target se foi setado via Inspector como NodePath (ou path não resolvido antes)
	if _target == null:
		# tenta localizar um NodePath exportado (se o usuário preferir outra abordagem via inspector)
		# (opcional) não aborta: apenas avisa e permite que set_target() seja chamada depois.
		push_warning("[CameraController] Alvo (target) não definido no Inspector! Vou aguardar atribuição em runtime.")

	spring_arm = get_node_or_null("SpringArm3D") as SpringArm3D
	if spring_arm:
		# mantém distância inicial e margem de colisão
		spring_arm.spring_length = base_distance
		# Alguns projetos usam outra propriedade; mantenha a que sua cena usa.
		# spring_arm.margin = collision_margin  # descomente se sua SpringArm3D tiver essa propriedade

	# se o target já estiver definido, inicializa rotações
	if _target:
		_initialize_target_rotation()

	# captura mouse por padrão (se desejar diferente, mude em runtime)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if debug:
		if _target:
			print("[CameraController] Inicializado. Alvo:", _target.name)
		else:
			print("[CameraController] Inicializado. Alvo: null (aguardando)")


func _initialize_target_rotation():
	"""Inicializa a rotação alvo com base na rotação atual do alvo."""
	# tenta pegar yaw do alvo se disponível
	# target.rotation é um Vector3 (euler), assumimos que .y é o yaw
	target_rotation.y = _target.rotation.y if _target else 0.0
	target_rotation.x = 0.0


# ==============================
# ENTRADA DE USUÁRIO
# ==============================
func _input(event):
	if _target == null:
		return

	# Ignora mouse no modo travado, se configurado
	if current_mode == CameraMode.BEHIND_PLAYER and disable_mouse_in_behind_mode:
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		target_rotation.y -= event.relative.x * free_look_rotation_speed
		target_rotation.x += event.relative.y * free_look_rotation_speed


# ==============================
# API PÚBLICA — CONTROLE DE MODO / TARGET
# ==============================

## Força a câmera a entrar no modo travado atrás do jogador.
func force_behind_player():
	current_mode = CameraMode.BEHIND_PLAYER
	if debug:
		print("[CameraController] Modo travado ativado.")


## Retorna a câmera ao modo livre com mouse.
func release_to_free_look():
	current_mode = CameraMode.FREE_LOOK
	# Alinha suavemente ao jogador para evitar salto, se target definido
	if _target:
		target_rotation.y = _target.rotation.y
	if debug:
		print("[CameraController] Modo livre reativado.")


# Função pública para setar target em runtime (recomendada para usar no spawner)
func set_target(node: Node) -> void:
	if node == null:
		_target = null
		return
	if node is Node3D:
		_target = node
		_initialize_target_rotation()
		if debug:
			print("[CameraController] Target setado via set_target():", _target.name)
	else:
		push_warning("[CameraController] set_target recebeu um nó que não é Node3D.")


# ==============================
# ATUALIZAÇÃO PRINCIPAL
# ==============================
func _process(delta):
	if _target == null:
		return

	# Atualiza parâmetros com base no modo atual
	var current_smoothness: float = 10.0
	var current_height_offset: float = 1.6
	var current_target_pitch_rad: float = 0.0
	var min_pitch_rad: float = deg_to_rad(-70)
	var max_pitch_rad: float = deg_to_rad(70)

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
			target_rotation.y = _target.rotation.y
			# Suaviza pitch para o valor alvo
			target_rotation.x = lerp(target_rotation.x, current_target_pitch_rad, current_smoothness * delta)

	# Aplica limites de pitch
	target_rotation.x = clamp(target_rotation.x, min_pitch_rad, max_pitch_rad)

	# Aplica interpolação suave na rotação da câmera
	rotation.x = lerp_angle(rotation.x, target_rotation.x, current_smoothness * delta)
	rotation.y = lerp_angle(rotation.y, target_rotation.y, current_smoothness * delta)

	# Atualiza posição da câmera (mantém altura relativa ao alvo)
	global_position = _target.global_position + Vector3.UP * current_height_offset

	# Atualiza SpringArm (se existir)
	if spring_arm:
		spring_arm.spring_length = base_distance

	# Debug opcional
	if debug:
		var mode_name = "BEHIND" if current_mode == CameraMode.BEHIND_PLAYER else "FREE"
		print("[CameraController] Modo:", mode_name,
			  "| Yaw:", "%.1f°" % rad_to_deg(rotation.y),
			  "| Pitch:", "%.1f°" % rad_to_deg(rotation.x))
