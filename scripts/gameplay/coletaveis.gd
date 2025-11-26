extends RigidBody3D
class_name DroppedItem
## Script para itens dropados no mundo - Sincronização servidor/cliente

# ===== VARIÁVEIS NECESSÁRIAS (Configuradas pelo ObjectManager) =====
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
@export var sync_enabled: bool = false
@export var sync_rate: float = 0.05
@export var interpolation_speed: float = 15.0
@export var teleport_threshold: float = 2.0
@export var sync_rotation: bool = true
@export var sync_physics: bool = false  # Não sincronizar física diretamente no cliente

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
var initial_height: float = 0.0
var accumulated_time: float = 0.0

# ===== VARIÁVEIS DE SINCRONIZAÇÃO =====
var sync_timer: float = 0.0  # Apenas servidor
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
	
	# Configura RigidBody baseado na autoridade
	_setup_authority_settings()
	
	# Guarda altura inicial
	initial_height = global_position.y
	
	# Inicia delay de coleta
	_start_collection_delay()
	
	# Configura lifetime apenas no servidor
	if has_lifetime and is_server_authority():
		_setup_lifetime_timer()
	
	_setup_visual()
	
	_log_debug("✓ Item inicializado: %s (ID: %d)" % [item_name, object_id])

func _ready():
	add_to_group("item")
	body_entered.connect(_on_body_entered)
	
	# Configurações iniciais baseadas na autoridade
	_setup_authority_settings()

func _setup_authority_settings():
	"""
	Configura o RigidBody com base na autoridade de rede:
	- Servidor: Física ativa
	- Cliente: Física congelada, apenas interpolação visual
	"""
	if is_server_authority():
		# SERVIDOR: Física completa
		gravity_scale = 1.0
		sleeping = false
		can_sleep = true
		freeze = false
		_log_debug("🖥️  [SERVIDOR] Física ativa")
	else:
		# CLIENTE: Física desabilitada
		freeze = true
		sleeping = true
		gravity_scale = 0.0
		_log_debug("💻 [CLIENTE] Física congelada")

# ===== VERIFICAÇÕES DE REDE SEGURAS =====
func is_server_authority() -> bool:
	"""
	Verificação segura para determinar se este nó tem autoridade de servidor
	Retorna true também em modo offline (singleplayer)
	"""
	return !has_network() or (multiplayer.has_multiplayer_peer() and multiplayer.is_server())

func has_network() -> bool:
	"""
	Verifica se o multiplayer está ativo e pronto para uso
	"""
	return multiplayer != null and (
		Engine.is_editor_hint() or  # Permite edição no editor
		multiplayer.has_multiplayer_peer()
	)

# ===== PROCESSAMENTO PRINCIPAL =====
func _physics_process(delta: float):
	if is_collected:
		return
	
	accumulated_time += delta
	
	# Sincronização de rede (apenas se ativado e com rede ativa)
	if sync_enabled and has_network():
		if is_server_authority():
			_server_sync_update(delta)
		else:
			_client_interpolate(delta)
	
	# Sistema de coleta (apenas servidor tem autoridade)
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
	Servidor: Envia estado atual para todos os clientes via RPC
	"""
	if !has_network() or !is_server_authority():
		return
	
	var pos = global_position
	var rot = global_rotation if sync_rotation else Vector3.ZERO
	
	# Envia para todos os peers conectados
	rpc_id(0, "_receive_sync", object_id, pos, rot)
	
	if debug_show_sync:
		_log_debug("📤 Sync enviado: pos=%s" % [pos])

@rpc("call_local")
func _receive_sync(item_id: int, pos: Vector3, rot: Vector3):
	"""
	Recebe atualizações de sincronização do servidor (chamado via RPC)
	"""
	if is_server_authority() or item_id != object_id:
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
		if debug_show_sync:
			_log_debug("📥 Primeiro sync recebido")
	
	if debug_show_sync:
		_log_debug("📥 Sync recebido: pos=%s" % [pos])

func _client_interpolate(delta: float):
	"""
	Cliente: Interpola suavemente até a posição do servidor
	"""
	if !has_received_first_sync or !sync_enabled:
		return
	
	# Calcula tempo desde última atualização (para correção de jitter)
	var time_since_last_update = Time.get_unix_time_from_system() - last_received_time
	var effective_delta = min(delta + time_since_last_update, 0.1)  # Limita a 100ms
	
	# Verifica se precisa teleportar
	var distance = global_position.distance_to(network_position)
	if distance > teleport_threshold:
		global_position = network_position
		if debug_show_sync:
			_log_debug("⚡ Teleportado para %s (dist: %.2f)" % [network_position, distance])
	elif distance > 0.01:  # Limiar mínimo para interpolação
		global_position = global_position.lerp(
			network_position, 
			interpolation_speed * effective_delta
		)
	
	# Interpola rotação se necessário
	if sync_rotation:
		var rot_distance = global_rotation.distance_to(network_rotation)
		if rot_distance > 0.01:
			global_rotation = global_rotation.slerp(
				network_rotation, 
				interpolation_speed * effective_delta
			)

# ===== SISTEMA DE COLETA =====
func _start_collection_delay():
	"""
	Inicia delay antes de permitir coleta (apenas no servidor)
	"""
	if !is_server_authority():
		return
	
	can_be_collected = false
	var timer = get_tree().create_timer(auto_collect_delay)
	await timer.timeout
	
	if !is_collected:
		can_be_collected = true
		_log_debug("  Item pronto para coleta")

func _check_nearby_players():
	"""
	Servidor: Verifica se há players próximos para coletar
	"""
	if !auto_collect or !has_network():
		return
	
	# Obtém players ativos da rodada
	var active_players = ServerManager.round_registry.get_all_spawned_players(round_id)
	
	for player_data in active_players:
		var player_node = player_data["node"]
		if !player_node:
			continue
		
		var distance = global_position.distance_to(player_node.global_position)
		if distance <= collection_radius:
			collect(player_data["player_id"])
			return

@rpc("authority")
func collect(collector_id: int) -> bool:
	"""
	Coleta o item - Chamado via RPC pelo cliente ou localmente no servidor
	Autoridade exclusiva do servidor
	"""
	if !is_server_authority() or is_collected:
		return false
	
	if !can_be_collected:
		_log_debug("  Tentou coletar antes do delay")
		return false
	
	# Validação adicional: verifica distância no servidor
	var player_node = ServerManager.player_registry.get_player_node(collector_id)
	if player_node and global_position.distance_to(player_node.global_position) > collection_radius * 1.5:
		_log_debug("  Coleta rejeitada: distância inválida")
		return false
	
	# Marca como coletado e notifica
	is_collected = true
	_notify_collected(collector_id)
	
	return true

func _notify_collected(collector_id: int):
	"""
	Notifica todos os clientes sobre a coleta e remove o item
	"""
	# Adiciona ao inventário (servidor)
	ServerManager.player_registry.add_item_to_inventory(round_id, collector_id, item_name)
	
	_log_debug("✓ Item coletado por player %d" % collector_id)
	
	# Notifica clientes para removerem visualmente
	rpc_id(0, "_despawn_visual")
	
	# Remove do servidor
	despaawn()

@rpc("call_local")
func _despawn_visual():
	"""
	Remove o item visualmente nos clientes
	"""
	if is_server_authority():
		return
	
	queue_free()
	emit_signal("despawned", object_id)

func despaawn():
	"""
	Remove o item do servidor e notifica clientes
	"""
	if !is_server_authority():
		return
	
	# Cancela timers
	if lifetime_timer:
		lifetime_timer.stop()
	
	# Remove do gerenciador
	ServerManager.object_manager.despawn_object(round_id, object_id)
	
	# Remove visualmente no servidor (se aplicável)
	if !Engine.is_editor_hint():
		queue_free()
	
	emit_signal("despawned", object_id)

# ===== LIFETIME =====
func _setup_lifetime_timer():
	"""
	Timer de lifetime - Somente no servidor
	"""
	lifetime_timer = Timer.new()
	lifetime_timer.wait_time = lifetime_seconds
	lifetime_timer.one_shot = true
	lifetime_timer.timeout.connect(_on_lifetime_expired)
	add_child(lifetime_timer)
	lifetime_timer.start()

func _on_lifetime_expired():
	"""
	Quando o tempo de vida expira - Somente no servidor
	"""
	if !is_server_authority():
		return
	
	_log_debug("  Lifetime expirado")
	despaawn()

# ===== FUNÇÕES AUXILIARES =====
func try_collect_from_client():
	"""
	Cliente: Solicita coleta ao servidor
	Chamado quando o jogador pressiona a tecla de coleta
	"""
	if !has_network() || is_server_authority():
		return
	
	# Envia RPC para o servidor
	rpc_id(1, "collect", get_tree().get_multiplayer_peer().get_unique_id())

func _setup_visual():
	"""
	Configura visual do item baseado nos dados
	Implementação dependente do seu sistema de itens
	"""
	pass

func _on_body_entered(body: Node):
	"""
	Callback de colisão - Pode ser usado para efeitos visuais
	"""
	pass

func _log_debug(message: String):
	if debug_mode:
		var prefix = "[SERVER]" if is_server_authority() else "[CLIENT]"
		print("%s [DroppedItem:%d] %s" % [prefix, object_id, message])
