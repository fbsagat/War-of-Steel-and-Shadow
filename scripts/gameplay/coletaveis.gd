extends RigidBody3D
class_name ItemDrop

# ==============================================================================
# CONFIGURAÇÕES - PROPRIEDADES DO ITEM
# ==============================================================================
@export_group("Item Properties")
@export var item_name: String = ""
@export var item_id: int = 0
@export_enum("Weapon", "Armor", "Consumable", "Material", "Quest") var item_type: String = "Material"
@export_enum("Left", "Right", "Both", "None") var item_side: String = "None"
@export_range(1, 100) var item_level: int = 1

# ==============================================================================
# CONFIGURAÇÕES - FÍSICA E COMPORTAMENTO
# ==============================================================================
@export_group("Physics Settings")
@export var rand_rotation: bool = true
@export var item_shot: bool = false  ## false = drop normal, true = arremessado
@export var impact_threshold: float = 2.0  ## Limite para detectar impacto
@export var object_rest_speed: float = 0.5  ## Velocidade mínima para considerar em repouso

# ==============================================================================
# CONFIGURAÇÕES - MULTIPLAYER
# ==============================================================================
@export_group("Multiplayer Settings")
@export var sync_interval: float = 0.1  ## Intervalo de sincronização (segundos)
@export var interpolate_movement: bool = true  ## Interpolar movimento nos clientes
@export var position_sync_threshold: float = 0.1  ## Mínimo de diferença para sincronizar posição

# ==============================================================================
# CONFIGURAÇÕES - DEBUG
# ==============================================================================
@export_group("Debug")
@export var debug: bool = false
@export var show_sync_markers: bool = false

# ==============================================================================
# NODES E VARIÁVEIS INTERNAS
# ==============================================================================
@onready var impact_sensor = $impact_sensor

# Variáveis de sincronização
var sync_timer: float = 0.0
var last_synced_position: Vector3 = Vector3.ZERO
var last_synced_rotation: Vector3 = Vector3.ZERO
var target_position: Vector3 = Vector3.ZERO
var target_rotation: Vector3 = Vector3.ZERO
var target_linear_velocity: Vector3 = Vector3.ZERO
var target_angular_velocity: Vector3 = Vector3.ZERO
var is_initialized: bool = false
var authority_set: bool = false

# ==============================================================================
# SINAIS
# ==============================================================================
signal picked_up(by_player: Node)
signal item_synced()
signal authority_changed(new_authority: int)

# ==============================================================================
# INICIALIZAÇÃO
# ==============================================================================
func _ready() -> void:
	# CRÍTICO: Aguardar estar completamente na árvore
	if not is_inside_tree():
		await tree_entered
	
	# Aguardar um frame para garantir que multiplayer está pronto
	await get_tree().process_frame
	
	if debug:
		print("[ItemDrop] _ready() chamado | Nome: %s | Autoridade atual: %d | É servidor: %s" % [name, get_multiplayer_authority(), multiplayer.is_server()])
	
	# Conectar sensor de impacto
	if impact_sensor:
		impact_sensor.body_entered.connect(_on_impact_sensor_body_entered)
	else:
		push_warning("[ItemDrop] impact_sensor não encontrado em: %s" % name)
	
	# Configurar autoridade SEMPRE (servidor controla física)
	_setup_multiplayer()
	
	is_initialized = true

func _setup_multiplayer() -> void:
	"""Configura autoridade e sincronização multiplayer"""
	
	# Servidor SEMPRE tem autoridade sobre física
	if multiplayer.is_server():
		set_multiplayer_authority(1)
		authority_set = true
		
		if debug:
			print("[ItemDrop] Servidor configurou autoridade: %s" % name)
		
		# Aplicar física inicial apenas no servidor
		if rand_rotation:
			call_deferred("_apply_initial_physics")
	else:
		# Cliente: apenas visualiza, não simula física
		# Mantém autoridade do servidor
		if get_multiplayer_authority() != 1:
			set_multiplayer_authority(1)
		
		authority_set = true
		
		# Desabilitar física no cliente (só interpola)
		freeze = false  # Mantém freeze false para permitir interpolação
		
		if debug:
			print("[ItemDrop] Cliente configurado (autoridade do servidor): %s" % name)
	
	emit_signal("authority_changed", get_multiplayer_authority())
	
	# Habilitar processamento
	set_physics_process(true)

func _apply_initial_physics() -> void:
	"""Aplica rotação e velocidade inicial (apenas servidor)"""
	if not is_multiplayer_authority():
		return
	
	_apply_random_rotation()
	_apply_random_angular_velocity()
	
	# Sincronizar estado inicial imediatamente
	await get_tree().process_frame
	_sync_to_clients()

# ==============================================================================
# FÍSICA E ROTAÇÃO INICIAL
# ==============================================================================
func _apply_random_rotation() -> void:
	var random_rot = Vector3(
		randf_range(0, TAU),
		randf_range(0, TAU),
		randf_range(0, TAU)
	)
	rotation = random_rot
	last_synced_rotation = random_rot
	
	if debug:
		print("[ItemDrop] Rotação aplicada: %s" % random_rot)

func _apply_random_angular_velocity() -> void:
	angular_velocity = Vector3(
		randf_range(-4, 4),
		randf_range(-4, 4),
		randf_range(-4, 4)
	)
	
	if debug:
		print("[ItemDrop] Velocidade angular aplicada: %s" % angular_velocity)

# ==============================================================================
# SINCRONIZAÇÃO MULTIPLAYER
# ==============================================================================
func _physics_process(delta: float) -> void:
	if not is_initialized or not authority_set:
		return
	
	if is_multiplayer_authority():
		# SERVIDOR: Envia dados periodicamente
		sync_timer += delta
		if sync_timer >= sync_interval:
			sync_timer = 0.0
			_sync_to_clients()
	else:
		# CLIENTE: Interpola para a posição alvo
		if interpolate_movement:
			_interpolate_physics(delta)

func _sync_to_clients() -> void:
	"""Servidor envia estado atual para todos os clientes"""
	if not is_multiplayer_authority():
		return
	
	# Só sincroniza se houver mudança significativa
	var pos_changed = global_position.distance_to(last_synced_position) > position_sync_threshold
	var rot_changed = rotation.distance_to(last_synced_rotation) > 0.01
	
	if not pos_changed and not rot_changed and linear_velocity.length() < 0.1:
		return  # Sem mudanças significativas
	
	last_synced_position = global_position
	last_synced_rotation = rotation
	
	# Envia para todos os clientes
	_receive_sync_data.rpc(
		global_position,
		rotation,
		linear_velocity,
		angular_velocity,
		sleeping
	)
	
	if debug and show_sync_markers:
		print("[ItemDrop] Sync enviado: pos=%s, vel=%s" % [global_position, linear_velocity])

@rpc("authority", "unreliable", "call_remote")
func _receive_sync_data(
	pos: Vector3,
	rot: Vector3,
	lin_vel: Vector3,
	ang_vel: Vector3,
	is_sleeping: bool
) -> void:
	"""Cliente recebe estado do servidor"""
	if is_multiplayer_authority():
		return  # Ignora no servidor
	
	# Se está dormindo no servidor, aplicar imediatamente
	if is_sleeping:
		global_position = pos
		rotation = rot
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true
		
		if debug:
			print("[ItemDrop] Estado 'dormindo' recebido")
		return
	
	# Atualizar alvos para interpolação
	target_position = pos
	target_rotation = rot
	target_linear_velocity = lin_vel
	target_angular_velocity = ang_vel
	
	if debug and show_sync_markers:
		print("[ItemDrop] Sync recebido: pos=%s" % pos)

func _interpolate_physics(delta: float) -> void:
	"""Interpola suavemente para o estado do servidor (apenas clientes)"""
	var interp_speed = 10.0
	
	# Interpolar posição
	global_position = global_position.lerp(target_position, interp_speed * delta)
	
	# Interpolar rotação (usando slerp para rotações)
	rotation.x = lerp_angle(rotation.x, target_rotation.x, interp_speed * delta)
	rotation.y = lerp_angle(rotation.y, target_rotation.y, interp_speed * delta)
	rotation.z = lerp_angle(rotation.z, target_rotation.z, interp_speed * delta)
	
	# Interpolar velocidades (apenas para visualização suave)
	linear_velocity = linear_velocity.lerp(target_linear_velocity, interp_speed * delta)
	angular_velocity = angular_velocity.lerp(target_angular_velocity, interp_speed * delta)

# ==============================================================================
# CONFIGURAÇÃO EXTERNA (CHAMADO PELO SPAWNER)
# ==============================================================================
func configure(data: Dictionary) -> void:
	"""Configura o item com dados externos (chamado após spawn)"""
	if data.has("item_name"):
		item_name = data.item_name
	if data.has("item_id"):
		item_id = data.item_id
	if data.has("item_type"):
		item_type = data.item_type
	if data.has("item_side"):
		item_side = data.item_side
	if data.has("item_level"):
		item_level = data.item_level
	if data.has("item_shot"):
		set_shot_mode(data.item_shot)
	
	if debug:
		print("[ItemDrop] Configurado: %s (ID: %d)" % [item_name, item_id])

# ==============================================================================
# COLETA DE ITEM
# ==============================================================================
func pick_up(by_player: Node) -> void:
	"""Inicia processo de coleta (pode ser chamado por cliente ou servidor)"""
	if not is_instance_valid(by_player):
		if debug:
			print("[ItemDrop] Tentativa de coleta por player inválido.")
		return
	
	if not is_multiplayer_authority():
		# Cliente solicita coleta ao servidor
		if debug:
			print("[ItemDrop] Cliente solicitando coleta ao servidor")
		_request_pickup.rpc_id(1, by_player.get_path())
		return
	
	# SERVIDOR: Processa coleta
	_process_pickup(by_player)

@rpc("any_peer", "call_remote", "reliable")
func _request_pickup(player_path: NodePath) -> void:
	"""RPC: Cliente solicita coleta ao servidor"""
	if not is_multiplayer_authority():
		return
	
	var player = get_node_or_null(player_path)
	if not player:
		push_warning("[ItemDrop] Player não encontrado: %s" % player_path)
		return
	
	_process_pickup(player)

func _process_pickup(by_player: Node) -> void:
	"""Processa a coleta no servidor e notifica todos"""
	if debug:
		print("[ItemDrop] Coletado por: %s | Item: %s" % [by_player.name, item_name])
	
	# Notifica todos os clientes
	_notify_pickup.rpc(by_player.get_path())
	
	# Emite sinal e remove
	emit_signal("picked_up", by_player)
	queue_free()

@rpc("authority", "call_remote", "reliable")
func _notify_pickup(player_path: NodePath) -> void:
	"""RPC: Servidor notifica clientes sobre coleta"""
	if is_multiplayer_authority():
		return
	
	var player = get_node_or_null(player_path)
	if player:
		emit_signal("picked_up", player)
	
	queue_free()

# ==============================================================================
# DETECÇÃO DE IMPACTO
# ==============================================================================
func _on_impact_sensor_body_entered(body: Node3D) -> void:
	"""Detecta impacto com personagens (apenas servidor)"""
	if not is_multiplayer_authority():
		return
	
	if not body is CharacterBody3D:
		return
	
	# Só processa impacto se o item foi arremessado
	if not item_shot:
		if debug:
			print("[ItemDrop] Contato ignorado: item não foi arremessado.")
		return
	
	# Ignora se velocidade for muito baixa
	if linear_velocity.length() < object_rest_speed:
		if debug:
			print("[ItemDrop] Velocidade muito baixa — ignorando impacto.")
		return
	
	var body_velocity = body.velocity if body.has_property("velocity") else Vector3.ZERO
	var relative_velocity = (linear_velocity - body_velocity).length()
	
	if relative_velocity > impact_threshold:
		var impulse = relative_velocity * mass
		
		if debug:
			print("[ItemDrop] IMPACTO FORTE! Velocidade relativa: %.2f m/s | Impulso: %.2f" % [relative_velocity, impulse])
		
		# Notifica o personagem sobre o impacto (em todos os clientes)
		if body.has_method("_on_impact_detected"):
			_sync_impact.rpc(body.get_path(), impulse)
	else:
		if debug:
			print("[ItemDrop] Contato suave: velocidade relativa baixa (%.2f m/s)" % relative_velocity)

@rpc("authority", "call_remote", "reliable")
func _sync_impact(body_path: NodePath, impulse: float) -> void:
	"""RPC: Sincroniza impacto em todos os clientes"""
	var body = get_node_or_null(body_path)
	if body and body.has_method("_on_impact_detected"):
		body._on_impact_detected(impulse)
		
		if debug:
			print("[ItemDrop] Impacto aplicado em: %s" % body.name)

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================
func set_shot_mode(shot: bool) -> void:
	"""Define se o item foi arremessado (sincroniza em rede)"""
	if is_multiplayer_authority():
		item_shot = shot
		_sync_shot_mode.rpc(shot)
		
		if debug:
			print("[ItemDrop] Modo arremesso definido: %s" % shot)
	else:
		# Cliente solicita mudança ao servidor
		_request_shot_mode.rpc_id(1, shot)

@rpc("any_peer", "call_remote", "reliable")
func _request_shot_mode(shot: bool) -> void:
	"""RPC: Cliente solicita mudança de modo ao servidor"""
	if not is_multiplayer_authority():
		return
	
	set_shot_mode(shot)

@rpc("authority", "call_remote", "reliable")
func _sync_shot_mode(shot: bool) -> void:
	"""RPC: Servidor sincroniza modo para clientes"""
	item_shot = shot

func get_item_data() -> Dictionary:
	"""Retorna dados do item como dicionário"""
	return {
		"name": item_name,
		"id": item_id,
		"type": item_type,
		"side": item_side,
		"level": item_level,
		"shot": item_shot
	}

func force_sync() -> void:
	"""Força sincronização imediata (útil após spawn)"""
	if is_multiplayer_authority():
		_sync_to_clients()
		
		if debug:
			print("[ItemDrop] Sincronização forçada")
