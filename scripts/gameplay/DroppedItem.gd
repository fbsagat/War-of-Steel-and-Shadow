extends RigidBody3D
class_name DroppedItem
## Script para itens dropados no mundo - Sincronização servidor/cliente

# ===== CONFIGURAÇÕES =====

@export_category("Collection Settings")
@export var auto_collect: bool = false
@export var collection_radius: float = 1.5
@export var auto_collect_delay: float = 0.5

@export_category("Network Sync")
@export var sync_enabled: bool = true
@export var sync_rate: float = 0.04
@export var interpolation_speed: float = 50.0
@export var teleport_threshold: float = 0.01
@export var sync_rotation: bool = true

@export_category("Lifetime")
@export var has_lifetime: bool = false
@export var lifetime_seconds: float = 300.0

@export_category("Debug")
@export var debug_mode: bool = true
@export var debug_show_sync: bool = false

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var network_manager: NetworkManager = null
var server_manager: ServerManager = null
var initializer: Initializer = null

# ===== VARIÁVEIS INTERNAS =====

var object_id: int = -1
var round_id: int = -1
var item_name: String = ""
var item_data: Dictionary = {}
var owner_uuid: String = ""
var initial_velocity: Vector3 = Vector3.ZERO
var lifetime_timer: Timer = null
var is_collected: bool = false
var spawn_time: float = 0.0
var can_be_collected: bool = false
var is_server: bool = false

# ===== INICIALIZAÇÃO =====
func initialize(
	_object_id: int,
	_round_id: int,
	_item_name: String,
	_item_data: Dictionary,
	_owner_uuid: String,
	_initial_velocity: Vector3
):
	object_id = _object_id
	round_id  = _round_id
	item_name = _item_name
	item_data = _item_data
	owner_uuid = _owner_uuid
	initial_velocity = _initial_velocity
	spawn_time = Time.get_unix_time_from_system()

	_setup_authority_settings()

	if is_server and initial_velocity != Vector3.ZERO:
		await get_tree().process_frame
		linear_velocity = initial_velocity

	# Registra no NetworkManager com round_id no config
	# A frequência de envio é gerenciada por start_round_sync(), não aqui
	if sync_enabled and is_server:
		network_manager.register_syncable_object(
			object_id,
			self,
			{
				"round_id":             round_id,
				"interpolation_speed":  interpolation_speed,
				"teleport_threshold":   teleport_threshold,
				"sync_rotation":        sync_rotation
			}
		)

	_log_debug("✓ Item inicializado: %s (ID: %d)" % [item_name, object_id])

func get_sync_config() -> Dictionary:
	return {
		"round_id":            round_id,
		"interpolation_speed": interpolation_speed,
		"teleport_threshold":  teleport_threshold,
		"sync_rotation":       sync_rotation
	}

func _ready():
	add_to_group("item")
	_setup_authority_settings()
	
## Configura RigidBody com base na autoridade:
##  - Servidor: Física ativa
##  - Cliente: Física congelada, apenas interpolação visual
func _setup_authority_settings():
	if is_server:
		# SERVIDOR: Física completa
		gravity_scale = 1.0
		sleeping = false
		can_sleep = true
		freeze = false
		contact_monitor = true  # Para detecção de colisão
		max_contacts_reported = 4
		_log_debug("🖥️ Física ativa")
	else:
		# CLIENTE: Física desabilitada
		freeze = true
		sleeping = true
		gravity_scale = 0.0
		contact_monitor = false
		_log_debug("💻 Física congelada")

func _log_debug(message: String):
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "DroppedItem" in initializer.selected:
		return
	
	var prefix = "[SERVER]" if is_server else "[CLIENT]"
	print("%s[DroppedItem:%d]%s" % [prefix, object_id, message])
