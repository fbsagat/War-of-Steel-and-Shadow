extends Node3D

@export var interval: float = 1.0
@export var area_path: NodePath = "Area3D"

var _can_execute := true
@onready var area: Area3D = get_node(area_path)

signal request_spawn

func _ready():
	area.body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node):
	if not body is CharacterBody3D:
		return

	if not _can_execute:
		return

	_can_execute = false
	on_character_enter(body)

	await get_tree().create_timer(interval).timeout
	_can_execute = true

func on_character_enter(_character: CharacterBody3D):
	request_spawn.emit(_character)
	
