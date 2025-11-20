extends RigidBody3D
class_name DroppedItem
## Script para itens dropados no mundo
## Usado por TODOS os itens coletáveis
## Sincronizado entre servidor e clientes via ObjectManager

# ===== VARIÁVEIS NECESSÁRIAS (Configuradas pelo ObjectManager) =====

## ID único do objeto (gerado pelo ObjectManager)
var object_id: int = -1

## ID da rodada onde o objeto existe
var round_id: int = -1

## Nome do item no ItemDatabase
var item_name: String = ""

## Dados completos do item (do ItemDatabase)
var item_data: Dictionary = {}

## ID do player que dropou o item (-1 se não foi dropado por ninguém)
var owner_id: int = -1

## Velocidade inicial ao ser dropado
var initial_velocity: Vector3 = Vector3.ZERO

# ===== CONFIGURAÇÕES =====

@export_category("Collection Settings")
@export var auto_collect: bool = false # Ativar auto-collect
@export var collection_radius: float = 1.5  # Distância para coleta
@export var auto_collect_delay: float = 0.5  # Delay antes de poder coletar (evita coleta imediata)

@export_category("Network Sync")

# TUDO FUNCIONANDO NORMALMENTE, MENOS QUANDO ATIVA O SYNC (RESOLVER!)
# RESOLVER O SYNC DEPOIS DE RESOLVER PROBLEMAS MENORES COMO ANIMAÇÃO DE DROP, ESCONDER ITEM NO MODELO APÓS O DROP E ETC...

@export var sync_enabled: bool = false  # Ativa sincronização de posição
@export var sync_rate: float = 0.1  # Intervalo entre atualizações (10 updates/segundo)
@export var interpolation_speed: float = 10.0  # Velocidade de interpolação
@export var teleport_threshold: float = 5.0  # Distância para teleportar ao invés de interpolar
@export var sync_rotation: bool = true  # Sincronizar rotação
@export var sync_physics: bool = true  # Sincronizar velocidades

@export_category("Lifetime")
@export var has_lifetime: bool = false
@export var lifetime_seconds: float = 300.0  # 5 minutos

@export_category("Debug")
@export var debug_mode: bool = false
@export var debug_show_sync: bool = false  # Mostra logs de sincronização

# ===== VARIÁVEIS INTERNAS =====

## Timer de vida do objeto
var lifetime_timer: Timer = null

## Marca se já foi coletado (evita coleta dupla)
var is_collected: bool = false

## Tempo em que foi spawnado
var spawn_time: float = 0.0

## Permite coleta (após delay)
var can_be_collected: bool = false

## Altura inicial (para hover)
var initial_height: float = 0.0

## Tempo acumulado (para animações)
var accumulated_time: float = 0.0

# ===== VARIÁVEIS DE SINCRONIZAÇÃO (REDE) =====

## Timer para enviar atualizações (apenas servidor)
var sync_timer: float = 0.0

## Estado de rede recebido (apenas clientes)
var network_position: Vector3 = Vector3.ZERO
var network_rotation: Vector3 = Vector3.ZERO
var network_linear_velocity: Vector3 = Vector3.ZERO
var network_angular_velocity: Vector3 = Vector3.ZERO

## Flags de sincronização
var has_received_first_sync: bool = false

# ===== SINAIS =====

signal item_collected(object_id: int, collector_id: int, item_name: String)

# ===== INICIALIZAÇÃO =====

func initialize(
	_object_id: int,
	_round_id: int,
	_item_name: String,
	_item_data: Dictionary,
	_owner_id: int,
	_initial_velocity: Vector3
):
	"""
	Inicializa o item dropado (chamado pelo ObjectManager)
	
	@param _object_id: ID único do objeto
	@param _round_id: ID da rodada
	@param _item_name: Nome do item no ItemDatabase
	@param _item_data: Dados completos do ItemDatabase
	@param _owner_id: ID de quem dropou
	@param _initial_velocity: Velocidade inicial
	"""
	
	object_id = _object_id
	round_id = _round_id
	item_name = _item_name
	item_data = _item_data
	owner_id = _owner_id
	initial_velocity = _initial_velocity
	spawn_time = Time.get_unix_time_from_system()
	
	# Aplica velocidade inicial (física) - APENAS NO SERVIDOR
	if multiplayer.is_server() and initial_velocity != Vector3.ZERO:
		linear_velocity = initial_velocity
	
	# Guarda altura inicial
	initial_height = global_position.y
	
	# Inicia timer de coleta
	_start_collection_delay()
	
	# Configura lifetime se necessário
	if has_lifetime:
		_setup_lifetime_timer()
	
	# Configura visual baseado no item_data
	_setup_visual()
	
	_log_debug("✓ Item inicializado: %s (ID: %d, Owner: %d)" % [item_name, object_id, owner_id])

func _ready():
	"""Configurações iniciais do RigidBody"""
	
	add_to_group("dropped_items")
	
	# Configurações baseadas em autoridade
	if multiplayer.is_server():
		# === SERVIDOR: Física completa e ativa ===
		gravity_scale = 1.0
		sleeping = false
		can_sleep = true
		freeze = false
		
		_log_debug("🖥️  [SERVIDOR] Física ativa")
	else:
		# === CLIENTE: Física desabilitada, apenas visual ===
		if sync_enabled:
			freeze = true  # Congela física completamente
			sleeping = true
			gravity_scale = 0.0
			
			_log_debug("💻 [CLIENTE] Física desabilitada, apenas interpolação")
		else:
			# Sem sync, deixa física ativa no cliente também
			gravity_scale = 1.0
	
	# Conecta sinais de física
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float):
	"""Atualiza física, sincronização e coleta"""
	
	if is_collected:
		return
	
	accumulated_time += delta
	
	# === SINCRONIZAÇÃO DE REDE ===
	if sync_enabled:
		if multiplayer.is_server():
			_server_sync_update(delta)
		else:
			_client_interpolate(delta)
	
	# === SISTEMA DE COLETA (apenas servidor) ===
	if can_be_collected and multiplayer.is_server():
		_check_nearby_players()

# ===== SINCRONIZAÇÃO DE REDE =====

func _server_sync_update(delta: float):
	"""
	Servidor: Envia atualizações periódicas para clientes
	"""
	
	sync_timer += delta
	
	if sync_timer >= sync_rate:
		sync_timer = 0.0
		_send_sync_to_clients()

func _send_sync_to_clients():
	"""
	Servidor: Envia estado atual para todos os clientes via NetworkManager
	"""
	
	var pos = global_position
	var rot = global_rotation if sync_rotation else Vector3.ZERO
	var lin_vel = linear_velocity if sync_physics else Vector3.ZERO
	var ang_vel = angular_velocity if sync_physics else Vector3.ZERO
	
	# Obtém players ativos da rodada
	var active_players = []
	var players = ServerManager.round_registry.get_all_spawned_players(round_id)
	for player in players:
		active_players.append(player.player_id)
	
	# Envia via NetworkManager
	if active_players.size() > 0:
		NetworkManager._rpc_sync_dropped_item(active_players, object_id, round_id, pos, rot, lin_vel, ang_vel)
	
	if debug_show_sync:
		_log_debug("📤 Sync enviado para %d players: pos=%s" % [active_players.size(), pos])

func receive_sync(pos: Vector3, rot: Vector3, lin_vel: Vector3, ang_vel: Vector3):
	"""
	Recebe sincronização do servidor (chamado pelo NetworkManager)
	Esta função é chamada localmente, NÃO é RPC
	"""
	
	if multiplayer.is_server():
		return  # Servidor não recebe sync
	
	# Atualiza estado de rede
	network_position = pos
	network_rotation = rot
	network_linear_velocity = lin_vel
	network_angular_velocity = ang_vel
	
	# Marca que recebeu primeira sincronização
	if not has_received_first_sync:
		has_received_first_sync = true
		# Teleporta para posição inicial
		global_position = network_position
		if sync_rotation:
			global_rotation = network_rotation
		
		if debug_show_sync:
			_log_debug("📥 Primeira sincronização recebida: pos=%s" % pos)
	
	if debug_show_sync:
		_log_debug("📥 Sync recebido: pos=%s, dist=%.2f" % [pos, global_position.distance_to(pos)])

func _client_interpolate(delta: float):
	"""
	Cliente: Interpola suavemente até o estado de rede
	"""
	
	if not has_received_first_sync:
		return  # Aguarda primeira sincronização
	
	# === INTERPOLAÇÃO DE POSIÇÃO ===
	var distance = global_position.distance_to(network_position)
	
	if distance > teleport_threshold:
		# Distância muito grande, teleporta
		global_position = network_position
		if debug_show_sync:
			_log_debug("⚡ Teleportado para %s (dist: %.2f)" % [network_position, distance])
	elif distance > 0.01:
		# Interpola suavemente
		global_position = global_position.lerp(network_position, interpolation_speed * delta)
	
	# === INTERPOLAÇÃO DE ROTAÇÃO ===
	if sync_rotation:
		var rot_distance = global_rotation.distance_to(network_rotation)
		
		if rot_distance > 0.01:
			global_rotation = global_rotation.lerp(network_rotation, interpolation_speed * delta)
	
	# === PREDIÇÃO DE MOVIMENTO (OPCIONAL) ===
	if sync_physics and network_linear_velocity.length() > 0.1:
		# Aplica predição baseada na velocidade
		var predicted_pos = network_position + network_linear_velocity * delta
		network_position = predicted_pos

# ===== SISTEMA DE COLETA =====

func _start_collection_delay():
	"""Inicia delay antes de permitir coleta"""
	can_be_collected = false
	
	await get_tree().create_timer(auto_collect_delay).timeout
	
	if not is_collected:
		can_be_collected = true
		_log_debug("  Item pronto para coleta")

func _check_nearby_players():
	"""Verifica se há players próximos para coletar (APENAS SERVIDOR)"""
	
	if not multiplayer.is_server():
		return
	
	if not auto_collect:
		return  # Auto-collect desabilitado
	
	# Obtém players da rodada
	var players = ServerManager.player_registry.get_players_in_round(round_id)
	
	for player_id in players:
		var player_node = ServerManager.player_registry.get_player_node(player_id)
		
		if not player_node or not player_node is Node3D:
			continue
		
		var distance = global_position.distance_to(player_node.global_position)
		
		if distance <= collection_radius:
			collect(player_id)
			return

func collect(collector_id: int) -> bool:
	"""
	Coleta o item (APENAS SERVIDOR)
	
	@param collector_id: ID do player que coletou
	@return: true se coletado com sucesso
	"""
	
	if not multiplayer.is_server():
		push_error("DroppedItem: collect() só pode ser chamado no servidor!")
		return false
	
	if is_collected:
		return false
	
	if not can_be_collected:
		_log_debug("  Tentou coletar antes do delay")
		return false
	
	# Marca como coletado
	is_collected = true
	
	# Adiciona ao inventário do player
	var success = ServerManager.player_registry.add_item_to_inventory(round_id, collector_id, item_name)
	
	if not success:
		_log_debug("  Falha ao adicionar ao inventário (cheio?)")
		is_collected = false
		return false
	
	_log_debug("✓ Item coletado por player %d" % collector_id)
	
	# Emite sinal
	item_collected.emit(object_id, collector_id, item_name)
	
	# Despawna o objeto
	ServerManager.object_manager.despawn_object(round_id, object_id)
	
	return true

func try_collect_from_client(collector_id: int):
	"""
	Cliente solicita coleta ao servidor
	Chamado quando player pressiona tecla de coleta
	"""
	
	if multiplayer.is_server():
		collect(collector_id)
	else:
		# Envia solicitação via NetworkManager
		NetworkManager._rpc_request_item_collection.rpc_id(1, object_id, round_id, collector_id)

# ===== VISUAL E ANIMAÇÕES =====

func _setup_visual():
	"""Configura visual baseado nos dados do item"""
	
	# Aqui você pode adicionar lógica para:
	# - Trocar material/textura baseado em item_data
	# - Ajustar escala
	# - Adicionar efeitos visuais
	# - Etc.
	
	pass

# ===== LIFETIME =====

func _setup_lifetime_timer():
	"""Configura timer de vida do objeto"""
	
	lifetime_timer = Timer.new()
	lifetime_timer.wait_time = lifetime_seconds
	lifetime_timer.one_shot = true
	lifetime_timer.timeout.connect(_on_lifetime_expired)
	add_child(lifetime_timer)
	lifetime_timer.start()
	
	_log_debug("  Lifetime configurado: %.1fs" % lifetime_seconds)

func _on_lifetime_expired():
	"""Chamado quando tempo de vida expira"""
	
	if not multiplayer.is_server():
		return
	
	_log_debug("  Lifetime expirado, despawnando...")
	ServerManager.object_manager.despawn_object(round_id, object_id)

# ===== FÍSICA =====

func _on_body_entered(body: Node):
	"""Callback de colisão"""
	
	# Você pode adicionar lógica aqui para:
	# - Sons de impacto
	# - Efeitos visuais ao bater no chão
	# - Etc.
	
	if debug_mode:
		print("DroppedItem: Colidiu com %s" % body.name)

# ===== QUERIES =====

func get_distance_to_player(player_id: int) -> float:
	"""Retorna distância até um player específico"""
	
	var player_node = ServerManager.player_registry.get_player_node(player_id)
	
	if not player_node or not player_node is Node3D:
		return INF
	
	return global_position.distance_to(player_node.global_position)

func is_collectible_by(player_id: int) -> bool:
	"""Verifica se pode ser coletado por um player específico"""
	
	if is_collected or not can_be_collected:
		return false
	
	return get_distance_to_player(player_id) <= collection_radius

func get_item_info() -> Dictionary:
	"""Retorna informações do item para UI"""
	
	return {
		"object_id": object_id,
		"round_id": round_id,
		"item_name": item_name,
		"item_data": item_data,
		"owner_id": owner_id,
		"is_collected": is_collected,
		"can_be_collected": can_be_collected,
		"time_alive": Time.get_unix_time_from_system() - spawn_time
	}

# ===== DEBUG =====

func _log_debug(message: String):
	if debug_mode or debug_show_sync:
		var prefix = "[SERVER]" if multiplayer.is_server() else "[CLIENT]"
		print("%s[DroppedItem:%s] %s" % [prefix, item_name, message])

# ===== FUNÇÕES AUXILIARES DE REDE =====

func get_sync_stats() -> Dictionary:
	"""Retorna estatísticas de sincronização (para debug)"""
	
	if multiplayer.is_server():
		return {
			"role": "server",
			"sync_rate": sync_rate,
			"next_sync_in": sync_rate - sync_timer,
			"position": global_position,
			"velocity": linear_velocity
		}
	else:
		return {
			"role": "client",
			"has_sync": has_received_first_sync,
			"position": global_position,
			"network_position": network_position,
			"distance_to_target": global_position.distance_to(network_position) if has_received_first_sync else 0.0,
			"interpolation_speed": interpolation_speed
		}

func force_teleport_to_network_state():
	"""
	Força teleporte imediato para estado de rede (cliente)
	Útil para resolver desincronizações severas
	"""
	
	if multiplayer.is_server() or not has_received_first_sync:
		return
	
	global_position = network_position
	global_rotation = network_rotation
	_log_debug("🔧 Teleporte forçado para estado de rede")
