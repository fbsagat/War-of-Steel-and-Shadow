extends RigidBody3D
class_name DroppedItem
## Script para itens dropados no mundo - Sincronização servidor/cliente

# ===== VARIÁVEIS NECESSÁRIAS =====
var object_id: int = -1
var round_id: int = -1
var item_name: String = ""
var item_data: Dictionary = {}
var owner_id: int = -1
var initial_velocity: Vector3 = Vector3.ZERO

# ===== CONFIGURAÇÕES =====
@export_category("Collection Settings")
@export var auto_collect: bool = false
@export var collection_radius: float = 1.5
@export var auto_collect_delay: float = 0.5

@export_category("Network Sync")
@export var sync_enabled: bool = true
@export var sync_rate: float = 0.03
@export var interpolation_speed: float = 22.0
@export var teleport_threshold: float = 0.01
@export var sync_rotation: bool = true

@export_category("Lifetime")
@export var has_lifetime: bool = false
@export var lifetime_seconds: float = 300.0

@export_category("Debug")
@export var debug_mode: bool = true
@export var debug_show_sync: bool = false

# ===== VARIÁVEIS INTERNAS =====
var lifetime_timer: Timer = null
var is_collected: bool = false
var spawn_time: float = 0.0
var can_be_collected: bool = false

# ===== VARIÁVEIS DE SINCRONIZAÇÃO =====
var sync_timer: float = 0.0
var network_position: Vector3 = Vector3.ZERO
var network_rotation: Vector3 = Vector3.ZERO
var last_received_time: float = 0.0
var has_received_first_sync: bool = false

# ===== SINAIS =====
signal despawned(object_id: int)

# ===== INICIALIZAÇÃO =====
func initialize(
	_object_id: int,
	_round_id: int,
	_item_name: String,
	_item_data: Dictionary,
	_owner_id: int,
	_initial_velocity: Vector3
):
	object_id = _object_id
	round_id = _round_id
	item_name = _item_name
	item_data = _item_data
	owner_id = _owner_id
	initial_velocity = _initial_velocity
	spawn_time = Time.get_unix_time_from_system()
	
	# Configura autoridade
	_setup_authority_settings()
	
	# ✅ CORRIGIDO: Aplica velocidade inicial DEPOIS de configurar física
	if is_server_authority() and initial_velocity != Vector3.ZERO:
		await get_tree().process_frame  # Aguarda física estabilizar
		linear_velocity = initial_velocity
		_log_debug("  Velocidade inicial aplicada: %s" % initial_velocity)
	
	# Inicia delay de coleta
	_start_collection_delay()
	
	# Configura lifetime apenas no servidor
	if has_lifetime and is_server_authority():
		_setup_lifetime_timer()
	
	_setup_visual()
	
	_log_debug("✓ Item inicializado: %s (ID: %d, Sync: %s)" % [item_name, object_id, sync_enabled])

func _ready():
	add_to_group("item")
	body_entered.connect(_on_body_entered)
	_setup_authority_settings()
	
func _setup_authority_settings():
	"""
	Configura RigidBody com base na autoridade:
	- Servidor: Física ativa
	- Cliente: Física congelada, apenas interpolação visual
	"""
	if is_server_authority():
		# SERVIDOR: Física completa
		gravity_scale = 1.0
		sleeping = false
		can_sleep = true
		freeze = false
		contact_monitor = true  # Para detecção de colisão
		max_contacts_reported = 4
		_log_debug("🖥️  [SERVIDOR] Física ativa")
	else:
		# CLIENTE: Física desabilitada
		freeze = true
		sleeping = true
		gravity_scale = 0.0
		contact_monitor = false
		_log_debug("💻 [CLIENTE] Física congelada")

# ===== VERIFICAÇÕES DE REDE =====
func is_server_authority() -> bool:
	return !has_network() or (multiplayer.has_multiplayer_peer() and multiplayer.is_server())

func has_network() -> bool:
	return multiplayer != null and multiplayer.has_multiplayer_peer()

# ===== PROCESSAMENTO PRINCIPAL =====
func _physics_process(delta: float):
	if is_collected:
		return
	
	# Sincronização de rede
	if sync_enabled and has_network():
		if is_server_authority():
			_server_sync_update(delta)
		else:
			_client_interpolate(delta)
	
	# Sistema de coleta (apenas servidor)
	if is_server_authority() and can_be_collected and !is_collected:
		_check_nearby_players()

# ===== SINCRONIZAÇÃO DE REDE =====
func _server_sync_update(delta: float):
	"""
	Servidor: Envia atualizações periódicas de estado para clientes
	"""
	if !sync_enabled or !has_network():
		return
	
	sync_timer += delta
	if sync_timer < sync_rate:
		return
	
	sync_timer = 0.0
	_send_sync_to_clients()

func _send_sync_to_clients():
	"""
	✅ CORRIGIDO: Envia estado via RPC broadcast
	"""
	if !has_network() or !is_server_authority():
		return
	
	var pos = global_position
	var rot = global_rotation if sync_rotation else Vector3.ZERO
	
	# ✅ CORRIGIDO: Usa rpc() sem ID para broadcast
	_receive_sync.rpc(object_id, pos, rot)
	
	if debug_show_sync:
		_log_debug("📤 Sync enviado: pos=%s, id=%d" % [pos, object_id])

# ✅ CORRIGIDO: Configuração correta do RPC
@rpc("authority", "call_remote", "unreliable")
func _receive_sync(item_id: int, pos: Vector3, rot: Vector3):
	"""
	Clientes: Recebem atualizações de sincronização do servidor
	"""
	# ✅ VALIDAÇÃO: Ignora se for o servidor ou ID diferente
	if is_server_authority():
		return
	
	if item_id != object_id:
		_log_debug("⚠️  ID incorreto recebido: esperado %d, recebido %d" % [object_id, item_id])
		return
	
	# Atualiza estado de rede
	network_position = pos
	network_rotation = rot
	last_received_time = Time.get_unix_time_from_system()
	
	# Primeiro sync: inicializa posição
	if !has_received_first_sync:
		has_received_first_sync = true
		global_position = network_position
		if sync_rotation:
			global_rotation = network_rotation
		_log_debug("📥 Primeiro sync recebido: pos=%s" % pos)
	
	if debug_show_sync:
		_log_debug("📥 Sync recebido: pos=%s, id=%d" % [pos, item_id])

func _client_interpolate(delta: float):
	"""
	Cliente: Interpola suavemente até a posição do servidor
	"""
	if !has_received_first_sync or !sync_enabled:
		return
	
	# Calcula tempo desde última atualização
	var time_since_last_update = Time.get_unix_time_from_system() - last_received_time
	
	# Se passou muito tempo (>1s), considera desconexão
	if time_since_last_update > 1.0:
		return
	
	var effective_delta = min(delta + time_since_last_update * 0.1, 0.1)
	
	# Verifica se precisa teleportar
	var distance = global_position.distance_to(network_position)
	if distance > teleport_threshold:
		global_position = network_position
		if sync_rotation:
			global_rotation = network_rotation
		if debug_show_sync:
			_log_debug("⚡ Teleportado: dist=%.2f" % distance)
	elif distance > 0.01:
		global_position = global_position.lerp(
			network_position, 
			interpolation_speed * effective_delta
		)
		
		if sync_rotation:
			global_rotation = global_rotation.slerp(
				network_rotation, 
				interpolation_speed * effective_delta
			)

# ===== SISTEMA DE COLETA =====
func _start_collection_delay():
	if !is_server_authority():
		return
	
	can_be_collected = false
	await get_tree().create_timer(auto_collect_delay).timeout
	
	if !is_collected:
		can_be_collected = true
		_log_debug("  Item pronto para coleta")

func _check_nearby_players():
	if !auto_collect or !has_network():
		return
	
	var active_players = ServerManager.round_registry.get_all_spawned_players(round_id)
	
	for player_node in active_players:
		if !player_node or !is_instance_valid(player_node):
			continue
		
		var distance = global_position.distance_to(player_node.global_position)
		if distance <= collection_radius:
			collect(player_node.player_id)
			return

@rpc("any_peer", "call_remote", "reliable")
func collect(collector_id: int) -> bool:
	"""
	Coleta o item - Autoridade exclusiva do servidor
	"""

	if !is_server_authority() or is_collected:
		return false
	
	if !can_be_collected:
		return false
	
	# Validação de distância
	var player_node = ServerManager.player_registry.get_player_node(collector_id)
	if player_node:
		var distance = global_position.distance_to(player_node.global_position)
		if distance > collection_radius * 1.5:
			_log_debug("  Coleta rejeitada: dist=%.2f" % distance)
			return false
	
	is_collected = true
	_notify_collected(collector_id)
	return true

func _notify_collected(collector_id: int):
	# Adiciona ao inventário
	ServerManager.player_registry.add_item_to_inventory(round_id, collector_id, item_name)
	_log_debug("✓ Item coletado por player %d" % collector_id)
	
	# Notifica clientes
	_despawn_visual.rpc()
	
	# Remove do servidor
	despawn()

@rpc("authority", "call_remote", "reliable")
func _despawn_visual():
	if is_server_authority():
		return
	
	queue_free()
	emit_signal("despawned", object_id)

func despawn():
	if !is_server_authority():
		return
	
	if lifetime_timer:
		lifetime_timer.stop()
	
	ServerManager.object_manager.despawn_object(round_id, object_id)
	queue_free()
	emit_signal("despawned", object_id)

# ===== LIFETIME =====
func _setup_lifetime_timer():
	lifetime_timer = Timer.new()
	lifetime_timer.wait_time = lifetime_seconds
	lifetime_timer.one_shot = true
	lifetime_timer.timeout.connect(_on_lifetime_expired)
	add_child(lifetime_timer)
	lifetime_timer.start()

func _on_lifetime_expired():
	if !is_server_authority():
		return
	
	_log_debug("  Lifetime expirado")
	despawn()

# ===== AUXILIARES =====
func try_collect_from_client():
	if !has_network() or is_server_authority():
		return
	
	collect.rpc_id(1, multiplayer.get_unique_id())

func _setup_visual():
	pass

func _on_body_entered(body: Node):
	pass

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if is_server_authority() else "[CLIENT]"
		print("%s[DroppedItem:%d]%s" % [prefix, object_id, message])
