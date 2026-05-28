extends CanvasLayer

@onready var panel: Panel = $Panel
@onready var label: Label = $Panel/Label
@onready var canva: CanvasLayer = $"."

var queue: Array = []
var is_showing := false
var current_tween: Tween
var message_id := 0

# Configuração dos tipos
var message_styles = {
	"info": {
		"color": Color.WHITE,
		"bg": Color(0.1, 0.1, 0.1, 0.9)
	},
	"success": {
		"color": Color(0.4, 1.0, 0.4),
		"bg": Color(0.0, 0.3, 0.0, 0.9)
	},
	"warning": {
		"color": Color(1.0, 0.8, 0.2),
		"bg": Color(0.4, 0.3, 0.0, 0.9)
	},
	"error": {
		"color": Color(1.0, 0.3, 0.3),
		"bg": Color(0.4, 0.0, 0.0, 0.9)
	}
}

func _ready():
	panel.visible = false
	panel.modulate.a = 0

# 🔹 Função pública
func show_message(text: String, duration: float = 3.0, type: String = "info"):
	queue.append({
		"text": text,
		"duration": duration,
		"type": type
	})
	
	if not is_showing:
		_show_next()

# 🔹 Processa fila
func _show_next():
	if queue.is_empty():
		is_showing = false
		return
	
	is_showing = true
	
	var local_id = message_id
	
	var msg = queue.pop_front()
	
	_apply_style(msg.type)
	label.text = msg.text
	
	panel.visible = true
	
	# Fade in
	current_tween = create_tween()
	current_tween.tween_property(panel, "modulate:a", 1.0, 0.25)
	
	await current_tween.finished
	
	# Verifica se foi resetado
	if local_id != message_id:
		return
	
	# Espera
	await get_tree().create_timer(msg.duration).timeout
	
	# Verifica novamente
	if local_id != message_id:
		return
	
	# Fade out
	current_tween = create_tween()
	current_tween.tween_property(panel, "modulate:a", 0.0, 0.25)
	
	await current_tween.finished
	
	# Verifica novamente
	if local_id != message_id:
		return
	
	panel.visible = false
	
	_show_next()

# 🔹 Aplica estilo
func _apply_style(type: String):
	var style = message_styles.get(type, message_styles["info"])
	
	label.add_theme_color_override("font_color", style.color)
	panel.self_modulate = style.bg

func show_canva():
	canva.visible = true

func hide_canva():
	canva.visible = false


func reset_all():
	message_id += 1
	
	queue.clear()
	is_showing = false
	
	if current_tween:
		current_tween.kill()
		current_tween = null
	
	panel.visible = false
	panel.modulate.a = 0
