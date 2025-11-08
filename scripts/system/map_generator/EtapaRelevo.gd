# EtapaRelevo.gd
class_name EtapaRelevo extends Resource

@export var nome: String = "Etapa 1"
@export_enum("Flat", "Semi-Flat", "Gentle Hills", "Rolling Hills", "Valleys", "Custom") 
var tipo_relevo: String = "Gentle Hills"
@export_range(0.0, 100.0) var percentual_distancia: float = 25.0
@export var cor_visual: Color = Color.WHITE
