extends OmniLight3D

@export var flicker_speed: float = 2.0
@export var intensity_variation: float = 0.3
@export var color_flicker_amount: float = 0.1
@export var base_intensity: float = 1.0
@export var base_color: Color = Color(1.0, 0.65, 0.25)  # Laranja quente

var time: float = 0.0

func _ready():
	light_energy = base_intensity
	light_color = base_color

func _process(delta):
	time += delta

	# Flicker de intensidade
	var intensity_flicker = sin(time * flicker_speed + sin(time * 3.7)) * intensity_variation
	light_energy = base_intensity + intensity_flicker

	# Flicker de cor (R e G variam levemente)
	var r_offset = sin(time * flicker_speed * 1.5 + 0.3) * color_flicker_amount
	var g_offset = sin(time * flicker_speed * 0.8 + 2.1) * color_flicker_amount * 0.6
	var r = clamp(base_color.r + r_offset, 0.5, 1.0)
	var g = clamp(base_color.g + g_offset, 0.3, 0.8)
	var b = base_color.b  # Mantém o azul baixo
	light_color = Color(r, g, b)
