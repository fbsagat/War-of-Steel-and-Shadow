extends CharacterBody3D
## Player - Script do jogador multiplayer
## Suporta controle local e replicação remota

# ===== CONFIGURAÇÕES EXPORTADAS =====

@export var move_speed: float = 5.0
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.002
@export var debug_mode: bool = true

# ===== VARIÁVEIS DE IDENTIFICAÇÃO =====

## ID do peer dono deste player
var player_id: int = 0

## Nome do jogador
var player_name: String = ""

## Se este é o jogador local (controlado por este cliente)
var is_local_player: bool = false

# ===== REFERÊNCIAS =====

@onready var camera: Camera3D = $Camera3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var name_label: Label3D = $NameLabel

# ===== VARIÁVEIS DE MOVIMENTO =====

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var camera_rotation: Vector2 = Vector2.ZERO

# ===== INICIALIZAÇÃO =====

func _ready():
	# Adiciona ao grupo de players para fácil localização
	add_to_group("player")
	
	# Esconde câmera por padrão (só o local player a usa)
	if camera:
		camera.current = false
	
	_log_debug("Player criado (ID: %d)" % player_id)

## Inicializa o player com seus dados
func initialize(p_id: int, p_name: String, spawn_pos: Vector3):
	player_id = p_id
	player_name = p_name
	
	# Define o nome do nó como o peer_id (importante para sincronização)
	name = str(player_id)
	
	# Posiciona no spawn
	global_position = spawn_pos
	
	# Atualiza label de nome
	if name_label:
		name_label.text = player_name
	
	# Define autoridade multiplayer
	set_multiplayer_authority(player_id)
	
	_log_debug("Player inicializado: %s (ID: %d) em %s" % [player_name, player_id, spawn_pos])
	
	# Registra no PartyRegistry
	PartyRegistry.register_spawned_player(player_id, self)

## Configura este player como o jogador local
func set_as_local_player():
	is_local_player = true
	
	# Ativa a câmera
	if camera:
		camera.current = true
	
	# Esconde o mesh do próprio jogador (opcional)
	# if mesh:
	# 	mesh.visible = false
	
	# Captura o mouse
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	_log_debug("Configurado como jogador local")

# ===== FÍSICA E MOVIMENTO =====

func _physics_process(delta):
	# Só processa movimento se for o jogador local (tem autoridade)
	if not is_multiplayer_authority():
		return
	
	# Aplica gravidade
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	# Pulo
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity
	
	# Movimento
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)
	
	move_and_slide()

## Captura movimento do mouse (apenas jogador local)
func _unhandled_input(event):
	if not is_local_player:
		return
	
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Rotação horizontal (corpo do player)
		rotate_y(-event.relative.x * mouse_sensitivity)
		
		# Rotação vertical (câmera)
		if camera:
			camera_rotation.x -= event.relative.y * mouse_sensitivity
			camera_rotation.x = clamp(camera_rotation.x, -PI/2, PI/2)
			camera.rotation.x = camera_rotation.x

# ===== AÇÕES DO JOGADOR =====

## Exemplo de ação que afeta o jogo (deve ser sincronizada)
func take_damage(amount: int, attacker_id: int = 0):
	if not is_multiplayer_authority():
		return
	
	_log_debug("Recebeu %d de dano" % amount)
	
	# Aqui você implementaria sistema de vida, morte, etc.
	# Use RPCs para notificar o servidor sobre morte, por exemplo

## Exemplo de disparo/ação
func perform_action():
	if not is_multiplayer_authority():
		return
	
	_log_debug("Ação realizada")
	
	# Notifica o servidor via RPC
	rpc_id(1, "_server_player_action", player_id)

@rpc("any_peer", "call_remote", "reliable")
func _server_player_action(p_id: int):
	if not multiplayer.is_server():
		return
	
	print("[Server] Player %d realizou ação" % p_id)
	# Aqui o servidor processaria a ação e replicaria para outros clients se necessário

# ===== CLEANUP =====

func _exit_tree():
	# Remove do registro ao ser destruído
	PartyRegistry.unregister_spawned_player(player_id)
	
	# Libera o mouse se for o jogador local
	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	_log_debug("Player destruído")

# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	if debug_mode:
		print("[Player:%d] %s" % [player_id, message])

## Retorna se este player está vivo (para futuro sistema de vida)
func is_alive() -> bool:
	return true  # Implementar lógica de vida depois

## Teleporta o player (apenas servidor pode chamar)
func teleport_to(new_position: Vector3):
	if multiplayer.is_server():
		global_position = new_position
		rpc("_sync_position", new_position)

@rpc("authority", "call_remote", "reliable")
func _sync_position(new_position: Vector3):
	global_position = new_position
