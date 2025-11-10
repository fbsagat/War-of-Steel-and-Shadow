extends CharacterBody3D
## VERSÃO DE DEBUG - Player com logs detalhados

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

# Física
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Estado atual
var is_jumping: bool = false
var is_running: bool = false
var current_speed: float = 0.0

# Debug
var frame_count: int = 0
var last_debug_time: float = 0.0

func _ready():
	print("\n╔════════════════════════════════════════╗")
	print("║    PLAYER _ready() CHAMADO             ║")
	print("╚════════════════════════════════════════╝")
	print("  Name: %s" % name)
	print("  Player ID: %d" % player_id)
	print("  Player Name: %s" % player_name)
	print("  Is Local: %s" % is_local_player)
	print("  Physics Process: %s" % is_physics_processing())
	
	add_to_group("player")
	
	# Verifica componentes
	_check_components()
	
	# NÃO desabilita physics aqui - espera initialize()
	if name_label:
		name_label.text = player_name if not player_name.is_empty() else "Player"
		name_label.pixel_size = 0.01
		name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	
	if debug_info:
		debug_info.visible = true  # Sempre visível para debug
		debug_info.text = "Aguardando inicialização..."

func _check_components():
	"""Verifica se todos componentes necessários existem"""
	print("\n  🔍 Verificando componentes:")
	
	var components = {
		"CollisionShape3D": get_node_or_null("CollisionShape3D"),
		"NameLabel": name_label,
		"CameraController": camera_controller,
		"NetworkSync": network_sync,
		"DebugInfo": debug_info
	}
	
	for comp_name in components:
		var comp = components[comp_name]
		if comp:
			print("    ✓ %s: OK" % comp_name)
		else:
			print("    ✗ %s: FALTANDO!" % comp_name)
	
	# Verifica collision shape
	var collision = get_node_or_null("CollisionShape3D")
	if collision:
		print("    Shape Type: %s" % collision.shape.get_class())
		print("    Disabled: %s" % collision.disabled)
	
	print("")

func initialize(p_id: int, p_name: String, spawn_position: Vector3):
	"""Inicializa o jogador com seus dados"""
	print("\n╔════════════════════════════════════════╗")
	print("║    INITIALIZE CHAMADO                  ║")
	print("╚════════════════════════════════════════╝")
	print("  Player ID: %d" % p_id)
	print("  Player Name: %s" % p_name)
	print("  Spawn Position: %s" % spawn_position)
	
	player_id = p_id
	player_name = p_name
	global_position = spawn_position
	
	if name_label:
		name_label.text = player_name
	
	print("  ✓ Inicialização completa")
	print("")

func set_as_local_player():
	"""Define este jogador como o jogador local (controlável)"""
	print("\n╔════════════════════════════════════════╗")
	print("║    SET_AS_LOCAL_PLAYER CHAMADO        ║")
	print("╚════════════════════════════════════════╝")
	
	is_local_player = true
	
	# CRÍTICO: Ativa physics process
	set_physics_process(true)
	print("  ✓ Physics Process ativado: %s" % is_physics_processing())
	
	# Ativa a câmera
	if camera_controller:
		camera_controller.set_as_active()
		print("  ✓ Câmera ativada")
	else:
		print("  ✗ ERRO: CameraController não encontrado!")
	
	# Esconde label do nome
	if name_label:
		name_label.visible = false
		print("  ✓ Label do nome escondido")
	
	# Configura NetworkSync
	if network_sync:
		network_sync.setup(player_id, true)
		print("  ✓ NetworkSync configurado")
	else:
		print("  ⚠ NetworkSync não encontrado (opcional)")
	
	# Ativa debug info
	if debug_info:
		debug_info.visible = true
		print("  ✓ Debug info ativado")
	
	# Adiciona ao grupo para fácil identificação
	add_to_group("local_player")
	
	print("  ✓ JOGADOR LOCAL CONFIGURADO COM SUCESSO!")
	print("  Player: %s (ID: %d)" % [player_name, player_id])
	print("")
	
	# Testa input imediatamente
	await get_tree().process_frame
	_test_input()

func _test_input():
	"""Testa se o sistema de input está funcionando"""
	print("\n🎮 TESTANDO SISTEMA DE INPUT:")
	
	var actions = ["move_forward", "move_backward", "move_left", "move_right", "jump", "run"]
	var all_ok = true
	
	for action in actions:
		if InputMap.has_action(action):
			var events = InputMap.action_get_events(action)
			print("  ✓ %s: %d teclas mapeadas" % [action, events.size()])
		else:
			print("  ✗ %s: NÃO EXISTE!" % action)
			all_ok = false
	
	if all_ok:
		print("  ✓ Sistema de input OK!")
	else:
		print("  ✗ ERRO: Input Map incompleto!")
		print("\n  💡 Execute _ensure_input_map() para corrigir")
	print("")

func _physics_process(delta: float):
	# DEBUG: Conta frames
	frame_count += 1
	
	# Verifica se é jogador local
	if not is_local_player:
		if frame_count % 60 == 0:  # A cada 60 frames
			print("⚠ [Player %d] Physics desabilitado (não é local)" % player_id)
		return
	
	# IMPORTANTE: Só processa input se mouse estiver capturado
	var should_process_input = true
	if camera_controller and camera_controller.has_method("is_mouse_captured"):
		should_process_input = camera_controller.is_mouse_captured()
		
		if not should_process_input and frame_count % 60 == 0:
			print("⚠ Mouse não capturado - input ignorado (pressione ESC)")
	
	# Debug periódico (a cada 2 segundos)
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_time > 2.0:
		print("\n📊 [Player %d] Status (Frame %d):" % [player_id, frame_count])
		print("  Posição: %s" % global_position)
		print("  Velocidade: %s (magnitude: %.2f)" % [velocity, velocity.length()])
		print("  No chão: %s" % is_on_floor())
		print("  Physics ativo: %s" % is_physics_processing())
		last_debug_time = current_time
	
	# Aplica gravidade
	if not is_on_floor():
		velocity.y -= gravity * delta
		if frame_count % 30 == 0:
			print("  ⬇ Aplicando gravidade: %.2f" % velocity.y)
	else:
		if velocity.y < 0:
			velocity.y = 0
	
	# Captura input APENAS se mouse capturado
	var input_detected = false
	var input_dir = Vector2.ZERO
	
	if should_process_input:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		
		if input_dir != Vector2.ZERO:
			input_detected = true
			if frame_count % 30 == 0:
				print("  🎮 Input detectado: %s" % input_dir)
	
	# Pulo APENAS se mouse capturado
	if should_process_input and Input.is_action_just_pressed("jump"):
		if is_on_floor():
			velocity.y = jump_velocity
			is_jumping = true
			print("  🦘 PULANDO! (velocity.y = %.2f)" % velocity.y)
		else:
			print("  ⚠ Tentou pular mas não está no chão")
	elif is_on_floor():
		is_jumping = false
	
	# Corrida APENAS se mouse capturado
	if should_process_input:
		is_running = Input.is_action_pressed("run") and is_on_floor()
	else:
		is_running = false
	
	current_speed = run_speed if is_running else move_speed
	
	# Calcula direção de movimento
	var direction = get_movement_direction(input_dir)
	
	# Aplica movimento
	if direction != Vector3.ZERO:
		var target_velocity = direction * current_speed
		var control_factor = air_control if not is_on_floor() else 1.0
		
		velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta * control_factor)
		velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta * control_factor)
		
		# Rotaciona personagem
		if direction.length() > 0.1:
			var target_rotation = atan2(-direction.x, -direction.z)
			rotation.y = lerp_angle(rotation.y, target_rotation, 10.0 * delta)
		
		if frame_count % 30 == 0:
			print("  ➡ Movendo: direção=%s, velocidade=%s" % [direction, velocity])
	else:
		# Desacelera
		velocity.x = lerp(velocity.x, 0.0, deceleration * delta)
		velocity.z = lerp(velocity.z, 0.0, deceleration * delta)
	
	# Move o personagem
	var old_pos = global_position
	move_and_slide()
	
	# Verifica se realmente moveu
	if old_pos.distance_to(global_position) > 0.01:
		if frame_count % 30 == 0:
			print("  ✓ Movimento aplicado: %.3f metros" % old_pos.distance_to(global_position))
	elif input_detected and frame_count % 30 == 0:
		print("  ⚠ Input detectado mas não moveu!")
		print("    Velocity: %s" % velocity)
		print("    Is on floor: %s" % is_on_floor())
		print("    Floor angle: %.2f°" % rad_to_deg(get_floor_angle()))
	
	# Atualiza debug info
	_update_debug_info()

func get_movement_direction(input_dir: Vector2) -> Vector3:
	"""Calcula a direção de movimento baseada na câmera"""
	if not camera_controller:
		# Sem câmera, usa direção mundial
		return Vector3(input_dir.x, 0, input_dir.y).normalized()
	
	var cam_forward = -camera_controller.global_transform.basis.z
	cam_forward.y = 0
	cam_forward = cam_forward.normalized()
	
	var cam_right = camera_controller.global_transform.basis.x
	cam_right.y = 0
	cam_right = cam_right.normalized()
	
	return (cam_right * input_dir.x + cam_forward * input_dir.y).normalized()

func _update_debug_info():
	"""Atualiza informações de debug"""
	if not debug_info:
		return
	
	var vel_horizontal = Vector2(velocity.x, velocity.z).length()
	
	debug_info.text = "╔═══ PLAYER DEBUG ═══╗\n"
	debug_info.text += "ID: %d | %s\n" % [player_id, player_name]
	debug_info.text += "Local: %s\n" % ("SIM ✓" if is_local_player else "NÃO")
	debug_info.text += "Physics: %s\n" % ("ON" if is_physics_processing() else "OFF")
	debug_info.text += "─────────────────────\n"
	debug_info.text += "Vel: %.1f m/s\n" % velocity.length()
	debug_info.text += "Vel H: %.1f m/s\n" % vel_horizontal
	debug_info.text += "Pos: (%.1f, %.1f, %.1f)\n" % [global_position.x, global_position.y, global_position.z]
	debug_info.text += "─────────────────────\n"
	debug_info.text += "Estado: %s%s\n" % [
		"Correndo" if is_running else "Andando",
		" (Pulando)" if is_jumping else ""
	]
	debug_info.text += "Chão: %s\n" % ("SIM ✓" if is_on_floor() else "NÃO")
	debug_info.text += "Frame: %d\n" % frame_count
	debug_info.text += "╚═══════════════════╝"

# ===== GETTERS PÚBLICOS =====

func get_player_id() -> int:
	return player_id

func get_player_name() -> String:
	return player_name

func is_local() -> bool:
	return is_local_player

# ===== MÉTODO DE COMPATIBILIDADE =====

func apply_network_state(pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Método legado - mantido para compatibilidade"""
	if is_local_player:
		return
	
	if network_sync and network_sync.has_method("receive_state"):
		network_sync.receive_state(pos, rot, vel, running, jumping)
