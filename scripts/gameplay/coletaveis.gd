extends RigidBody3D

# ==============================================================================
# CONFIGURAÇÕES NO INSPECTOR
# ==============================================================================
@export var debug: bool = false
@export var item_name: String
@export var item_id: int
@export var item_type: String
@export var item_side: String
@export var item_level: String
@export var rand_rotation: bool = true
@export var item_shot: bool = false  # false = drop normal, true = arremessado

@onready var impact_sensor = $impact_sensor

const IMPACT_THRESHOLD: float = 2.0  # ajuste conforme seu jogo
const OBJECT_REST_SPEED: float = 0.5
# ==============================================================================
# SINAIS
# ==============================================================================
signal picked_up(by_player: Node)  # Emitido quando o item é coletado
#signal character_impacted(character_body: CharacterBody3D, impulse: float)

# ==============================================================================
# HANDLE: INICIALIZAÇÃO
# ==============================================================================
func _ready() -> void:
	if impact_sensor:
		impact_sensor.body_entered.connect(_on_impact_sensor_body_entered)
	
	if debug:
		print("[ItemDrop] Inicializando item:", item_name)
	
	if rand_rotation:
	# Aplicar rotação inicial aleatória
		_apply_random_rotation()

	# Aplicar velocidade angular aleatória (para girar ao cair)
		_apply_random_angular_velocity()

func _apply_random_rotation():
	# Gera rotação aleatória em todos os eixos (em radianos)
	var random_rot = Vector3(
		randf_range(0, 90 * PI),
		randf_range(0, 90 * PI),
		randf_range(0, 90 * PI)
	)
	rotation = random_rot

	# Atualiza a transformação imediatamente (opcional, mas útil para visualização)
	# Nota: em RigidBody3D, o motor físico controla a transformação,
	# então a rotação real será aplicada na próxima simulação.
	# Para garantir, usamos set_global_transform ou integração de força.

	# Alternativa mais robusta: forçar a transformação via set_global_transform
	var new_transform = Transform3D(Basis.from_euler(random_rot), global_transform.origin)
	set_global_transform(new_transform)

func _apply_random_angular_velocity():
	# Define uma velocidade angular aleatória (em rad/s)
	# Ajuste os valores conforme o efeito desejado (ex: 2 a 6 rad/s)
	angular_velocity = Vector3(
		randf_range(-4, 4),
		randf_range(-4, 4),
		randf_range(-4, 4)
	)

# ==============================================================================
# COLETAR ITEM
# ==============================================================================
func pick_up(by_player: Node) -> void:
	if not is_instance_valid(by_player):
		if debug:
			print("[ItemDrop] Tentativa de coleta por player inválido.")
		return

	if debug:
		print("[ItemDrop] Coletado por:", by_player.name, "| Item:", item_name)

	emit_signal("picked_up", by_player)
	queue_free()

func _on_impact_sensor_body_entered(body):
	if body is CharacterBody3D:
		# Só processa impacto se o item foi ARREMESSADO
		if not item_shot:
			# Código para apenas aproximação
			if debug:
				print("[ItemDrop] Contato ignorado: item não foi arremessado.")
			return

		# Opcional: ignora se velocidade for muito baixa (segurança extra)
		if linear_velocity.length() < OBJECT_REST_SPEED:
			if debug:
				print("[ItemDrop] Velocidade muito baixa — ignorando impacto.")
			return

		var relative_velocity = (linear_velocity - body.velocity).length()
		
		if relative_velocity > IMPACT_THRESHOLD:
			var impulse = relative_velocity * mass
			if debug:
				print("[ItemDrop] IMPACTO FORTE! Velocidade relativa: %.2f m/s" % relative_velocity)
			
			if body.has_method("_on_impact_detected"):
				body._on_impact_detected(impulse)
		else:
			if debug:
				print("[ItemDrop] Contato suave: velocidade relativa baixa (%.2f m/s)" % relative_velocity)
