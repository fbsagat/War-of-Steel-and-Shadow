extends Label3D
## PlayerDebugInfo - Exibe informações de debug sobre o player
## Attach este script ao Label3D "DebugInfo"

@export var update_interval: float = 0.5
@export var show_debug: bool = false

var player: CharacterBody3D
var update_timer: float = 0.0

func _ready():
	player = get_parent() as CharacterBody3D
	visible = show_debug
	
	if not player:
		push_error("DebugInfo precisa ser filho de um Player!")
		queue_free()

func _process(delta: float) -> void:
	if not show_debug or not player:
		visible = false
		return
	
	visible = true
	update_timer += delta
	
	if update_timer >= update_interval:
		update_timer = 0.0
		_update_debug_text()

func _update_debug_text() -> void:
	var info = []
	
	# ID e nome
	info.append("ID: %d" % player.player_id)
	
	# Autoridade
	if player.is_local_player:
		info.append("[LOCAL]")
	else:
		info.append("[REMOTE]")
	
	# Velocidade
	var speed = Vector2(player.velocity.x, player.velocity.z).length()
	info.append("Speed: %.1f" % speed)
	
	# Posição
	info.append("Pos: (%.1f, %.1f, %.1f)" % [
		player.global_position.x,
		player.global_position.y,
		player.global_position.z
	])
	
	# Estados
	var states = []
	if player.is_on_floor():
		states.append("Floor")
	if player.is_jumping:
		states.append("Jump")
	if player.is_aiming:
		states.append("Aim")
	if player.is_attacking:
		states.append("Attack")
	
	if not states.is_empty():
		info.append("State: %s" % ", ".join(states))
	
	text = "\n".join(info)
