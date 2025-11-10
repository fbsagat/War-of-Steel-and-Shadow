extends Node
## NetworkSync - Gerencia sincronização de estado do jogador
## Deve ser filho do nó Player

# Configurações
@export var sync_rate: float = 20.0  # Estados por segundo
@export var interpolation_speed: float = 15.0  # Velocidade de interpolação
@export var position_threshold: float = 0.1  # Distância mínima para sincronizar
@export var rotation_threshold: float = 0.05  # Rotação mínima para sincronizar

# Referências
var player: CharacterBody3D = null
var player_id: int = 0
var is_local: bool = false

# Controle de envio
var time_since_last_sync: float = 0.0
var sync_interval: float = 0.0

# Estado anterior (para detecção de mudanças)
var last_synced_position: Vector3 = Vector3.ZERO
var last_synced_rotation: Vector3 = Vector3.ZERO
var last_synced_velocity: Vector3 = Vector3.ZERO

# Estado recebido (para jogadores remotos)
var target_position: Vector3 = Vector3.ZERO
var target_rotation: Vector3 = Vector3.ZERO
var target_velocity: Vector3 = Vector3.ZERO
var received_running: bool = false
var received_jumping: bool = false

# Buffer de estados (para interpolação mais suave)
var state_buffer: Array = []
var max_buffer_size: int = 3

func _ready():
	player = get_parent() as CharacterBody3D
	sync_interval = 1.0 / sync_rate
	
	if not player:
		push_error("[NetworkSync] Deve ser filho de CharacterBody3D")
		return
	
	set_physics_process(false)  # Ativa apenas quando configurado

func setup(p_id: int, is_local_player: bool):
	"""Configura o NetworkSync"""
	player_id = p_id
	is_local = is_local_player
	
	if is_local:
		# Jogador local: envia estados
		last_synced_position = player.global_position
		last_synced_rotation = player.rotation
	else:
		# Jogador remoto: recebe estados
		target_position = player.global_position
		target_rotation = player.rotation
	
	set_physics_process(true)
	print("[NetworkSync] Configurado para jogador %d (Local: %s)" % [player_id, is_local])

func _physics_process(delta: float):
	if is_local:
		_process_local_sync(delta)
	else:
		_process_remote_sync(delta)

func _process_local_sync(delta: float):
	"""Processa sincronização do jogador local (envia estados)"""
	time_since_last_sync += delta
	
	# Verifica se é hora de sincronizar
	if time_since_last_sync < sync_interval:
		return
	
	# Verifica se houve mudança significativa
	if not _should_sync():
		return
	
	time_since_last_sync = 0.0
	
	# DEBUG
	if player.frame_count % 60 == 0:
		print("[NetworkSync %d] Enviando estado: pos=%s, vel=%s" % [
			player_id,
			player.global_position,
			player.velocity
		])
	
	# Envia estado atual via NetworkManager
	if NetworkManager and NetworkManager.is_connected:
		NetworkManager.send_player_state(
			player_id,
			player.global_position,
			player.rotation,
			player.velocity,
			player.is_running,
			player.is_jumping
		)
	else:
		if player.frame_count % 300 == 0:  # A cada 5 segundos
			print("[NetworkSync %d] ⚠ NetworkManager não conectado!" % player_id)
	
	# Atualiza último estado sincronizado
	last_synced_position = player.global_position
	last_synced_rotation = player.rotation
	last_synced_velocity = player.velocity

func _should_sync() -> bool:
	"""Verifica se deve sincronizar (otimização)"""
	# Sempre sincroniza se estiver se movendo
	if player.velocity.length() > 0.1:
		return true
	
	# Sincroniza se posição mudou significativamente
	if player.global_position.distance_to(last_synced_position) > position_threshold:
		return true
	
	# Sincroniza se rotação mudou significativamente
	var rot_diff = (player.rotation - last_synced_rotation).length()
	if rot_diff > rotation_threshold:
		return true
	
	# Sincroniza se velocidade mudou
	if player.velocity.distance_to(last_synced_velocity) > 0.5:
		return true
	
	# Sincroniza mudanças de estado
	if player.is_running != (last_synced_velocity.length() > player.move_speed):
		return true
	
	return false

func _process_remote_sync(delta: float):
	"""Processa sincronização do jogador remoto (aplica estados recebidos)"""
	if state_buffer.is_empty():
		return
	
	# Pega o estado mais recente do buffer
	var state = state_buffer[0]
	target_position = state["position"]
	target_rotation = state["rotation"]
	target_velocity = state["velocity"]
	received_running = state["running"]
	received_jumping = state["jumping"]
	
	# Remove estado processado
	state_buffer.pop_front()
	
	# Interpola posição
	var distance = player.global_position.distance_to(target_position)
	
	if distance > 5.0:
		# Teleporta se muito longe (evita lag acumulado)
		player.global_position = target_position
	elif distance > 0.01:
		# Interpolação adaptativa baseada na distância
		var interp_speed = interpolation_speed
		if distance > 2.0:
			interp_speed *= 2.0  # Acelera convergência se longe
		
		player.global_position = player.global_position.lerp(
			target_position, 
			min(interp_speed * delta, 1.0)
		)
	
	# Interpola rotação
	player.rotation.y = lerp_angle(
		player.rotation.y,
		target_rotation.y,
		interpolation_speed * delta
	)
	
	# Aplica velocidade (para animações)
	player.velocity = target_velocity
	player.is_running = received_running
	player.is_jumping = received_jumping

func receive_state(pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Recebe estado da rede (chamado pelo RPC)"""
	if is_local:
		return  # Ignora estados recebidos no jogador local
	
	# DEBUG periódico
	if state_buffer.size() == 0:
		print("[NetworkSync %d] Primeiro estado recebido: pos=%s" % [player_id, pos])
	
	# Adiciona ao buffer
	var state = {
		"position": pos,
		"rotation": rot,
		"velocity": vel,
		"running": running,
		"jumping": jumping,
		"timestamp": Time.get_ticks_msec()
	}
	
	state_buffer.append(state)
	
	# Limita tamanho do buffer
	if state_buffer.size() > max_buffer_size:
		state_buffer.pop_front()
	
	# DEBUG
	#if player and player.has("frame_count") and player.frame_count % 120 == 0:
		#print("[NetworkSync %d] Buffer: %d estados, distância: %.2fm" % [
			#player_id,
			#state_buffer.size(),
			#player.global_position.distance_to(pos) if player else 0.0
		#])

func update_state(pos: Vector3, rot: Vector3, vel: Vector3, running: bool, jumping: bool):
	"""Atualiza estado local (chamado pelo Player)"""
	# Este método existe apenas para compatibilidade
	# A sincronização real acontece em _process_local_sync
	pass

func get_network_stats() -> Dictionary:
	"""Retorna estatísticas de rede para debug"""
	return {
		"player_id": player_id,
		"is_local": is_local,
		"buffer_size": state_buffer.size(),
		"last_sync": time_since_last_sync,
		"position": player.global_position if player else Vector3.ZERO
	}
