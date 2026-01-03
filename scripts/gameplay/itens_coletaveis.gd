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
@export var sync_rate: float = 0.05
@export var interpolation_speed: float = 50.0
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

# ===== SINAIS =====
signal despawned(object_id: int)

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var network_manager: NetworkManager = null
var server_manager: ServerManager = null

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
	
	# ✅ Registra no NetworkManager se sync_enabled
	if sync_enabled and is_server_authority():
		# Servidor registra imediatamente
		network_manager.register_syncable_object(
			object_id,
			self,
			{
				"sync_rate": sync_rate,
				"interpolation_speed": interpolation_speed,
				"teleport_threshold": teleport_threshold,
				"sync_rotation": sync_rotation
			}
		)
		
	elif sync_enabled and !is_server_authority():
		pass
		# Cliente: espera o primeiro sync para registrar
		# (opcional: pode registrar aqui também, mas sem enviar)
		#NetworkManager.register_syncable_object(...)
	
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
	var peer = multiplayer.multiplayer_peer
	if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return !has_network() or (multiplayer.has_multiplayer_peer() and multiplayer.is_server())
	return false

func has_network() -> bool:
	return multiplayer != null and multiplayer.has_multiplayer_peer()

# ===== PROCESSAMENTO PRINCIPAL =====
func _physics_process(_delta: float):
	if is_collected:
		return
	
	# Sistema de coleta (apenas servidor)
	if is_server_authority() and can_be_collected and !is_collected:
		_check_nearby_players()

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
	
	var active_players = server_manager.round_registry.get_all_spawned_players(round_id)
	
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
	var player_node = server_manager.player_registry.get_player_node(collector_id)
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
	#ServerManager.player_registry.add_item_to_inventory(round_id, collector_id, item_name)
	_log_debug("✓ Item coletado por player %d" % collector_id)
	
	# Remove do servidor
	despawn()

func despawn():
	if !is_server_authority():
		return
	
	# Notifica clientes para despawn
	network_manager.rpc("_rpc_client_despawn_item", object_id, round_id)
	
	# Remove do servidor
	if sync_enabled:
		network_manager.unregister_syncable_object(object_id)  # opcional, mas seguro
	
	server_manager.object_manager.despawn_object(round_id, object_id)
	queue_free()
	emit_signal("despawned", object_id)

func get_sync_config() -> Dictionary:
	"""
	Retorna configuração de sincronização para o NetworkManager.
	"""
	return {
		"sync_rate": sync_rate,
		"interpolation_speed": interpolation_speed,
		"teleport_threshold": teleport_threshold,
		"sync_rotation": sync_rotation
	}

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

func _on_body_entered(_body: Node):
	pass

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if is_server_authority() else "[CLIENT]"
		print("%s[DroppedItem:%d]%s" % [prefix, object_id, message])
