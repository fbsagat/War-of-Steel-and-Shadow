extends CanvasLayer

@onready var panel: Panel = $Panel
@onready var label: Label = $Panel/Label

var queue: Array = []
var is_showing := false

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
	
	var msg = queue.pop_front()
	
	_apply_style(msg.type)
	label.text = msg.text
	
	panel.visible = true
	
	# Fade in
	var tween = create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.25)
	
	await tween.finished
	
	# Espera tempo da mensagem
	await get_tree().create_timer(msg.duration).timeout
	
	# Fade out
	var tween_out = create_tween()
	tween_out.tween_property(panel, "modulate:a", 0.0, 0.25)
	
	await tween_out.finished
	
	panel.visible = false
	
	# Próxima da fila
	_show_next()

# 🔹 Aplica estilo
func _apply_style(type: String):
	var style = message_styles.get(type, message_styles["info"])
	
	label.add_theme_color_override("font_color", style.color)
	panel.self_modulate = style.bg
