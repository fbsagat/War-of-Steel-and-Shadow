extends CharacterBody3D

signal died

@export var debug: bool = false
@export var max_hp: int = 50
@export var speed: float = 2.5
@export var wander_interval_min: float = 0.8
@export var wander_interval_max: float = 2.5
@export var gravity: float = -24.0

# Debug
@export var debug_draw_direction: bool = false

var hp: int
var move_dir: Vector3 = Vector3.ZERO
var rng: RandomNumberGenerator

@onready var mesh: MeshInstance3D = $Mesh
@onready var wander_timer: Timer = $WanderTimer
@onready var hit_flash_timer: Timer = $HitFlashTimer

func _ready() -> void:
	hp = max_hp
	rng = RandomNumberGenerator.new()
	rng.randomize()
	add_to_group("enemy")

	wander_timer.timeout.connect(_on_wander_timeout)
	hit_flash_timer.timeout.connect(_on_hit_flash_timeout)
	_start_wander_timer()
	if debug:
		print("Inimigo spawnado com HP:", hp)

	# Garante que temos um material editável para efeitos visuais
	_ensure_editable_material()


func _ensure_editable_material() -> void:
	if not mesh:
		return

	# Se já temos um material_override, não precisamos fazer nada
	if mesh.material_override:
		return

	# Tenta obter o material original da primeira superfície do mesh
	var original_mat = null
	if mesh.mesh:
		original_mat = mesh.mesh.surface_get_material(0)

	# Se o material original for StandardMaterial3D, duplicamos
	if original_mat is StandardMaterial3D:
		mesh.material_override = original_mat.duplicate()
	else:
		# Caso contrário, cria um novo StandardMaterial3D
		mesh.material_override = StandardMaterial3D.new()


func _start_wander_timer() -> void:
	if wander_timer:
		wander_timer.wait_time = rng.randf_range(wander_interval_min, wander_interval_max)
		wander_timer.start()


func _on_wander_timeout() -> void:
	var x = rng.randf_range(-1.0, 1.0)
	var z = rng.randf_range(-1.0, 1.0)
	move_dir = Vector3(x, 0, z)

	if move_dir.length_squared() < 0.01:
		move_dir = Vector3.ZERO
	else:
		move_dir = move_dir.normalized()

	_start_wander_timer()


func _physics_process(delta: float) -> void:
	# Gravidade
	if not is_on_floor():
		velocity.y += gravity * delta
	else:
		velocity.y = 0.0

	var target_vel := Vector3.ZERO
	if move_dir != Vector3.ZERO:
		target_vel = move_dir * speed

		# Rotação suave (apenas yaw)
		var flat_dir := Vector3(target_vel.x, 0, target_vel.z)
		if flat_dir.length_squared() > 0.01:
			var target_yaw := atan2(-flat_dir.x, -flat_dir.z)
			rotation.y = lerp_angle(rotation.y, target_yaw, 8.0 * delta)

	velocity.x = target_vel.x
	velocity.z = target_vel.z

	move_and_slide()


func take_damage(dmg: int, from_node: Node = null) -> void:
	if hp <= 0:
		if debug:
			print("Inimigo já está morto!")
		return

	hp -= dmg
	if debug:
		print("Inimigo levou", dmg, "de dano! HP restante:", hp)

	if hp <= 0:
		hp = 0
		_die(from_node)
		return

	# Efeito visual de hit: piscar vermelho
	_apply_hit_flash()
	if debug:
		print("Inimigo atingido!")


func _apply_hit_flash() -> void:
	if not mesh or not mesh.material_override:
		return

	if mesh.material_override is StandardMaterial3D:
		mesh.material_override.albedo_color = Color(1.0, 0.3, 0.3)  # Vermelho claro
		hit_flash_timer.start(0.2)


func _on_hit_flash_timeout() -> void:
	if mesh and mesh.material_override is StandardMaterial3D:
		mesh.material_override.albedo_color = Color(1.0, 1.0, 1.0)  # Volta à cor normal


func _die(_from_node: Node = null) -> void:
	if debug:
		print("Inimigo morreu!")
	
	# Efeito visual de morte: vermelho intenso + fade out
	if mesh and mesh.material_override is StandardMaterial3D:
		mesh.material_override.albedo_color = Color(1.0, 0.1, 0.1)
		# Fade out suave antes de sumir
		_start_fade_out()

	emit_signal("died")


func _start_fade_out() -> void:
	# Desativa wander e input
	if wander_timer:
		wander_timer.stop()
	move_dir = Vector3.ZERO

	# Inicia fade out
	var tween = create_tween()
	tween.tween_property(mesh.material_override, "albedo_color:a", 0.0, 0.6)
	tween.tween_callback(queue_free)


func apply_knockback(force: Vector3) -> void:
	if not is_instance_valid(self):
		return
	velocity += force
	if debug:
		print("Inimigo sofreu knockback:", force)
