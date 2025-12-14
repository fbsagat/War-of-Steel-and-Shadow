# InventoryUI.gd
extends Control

# Referências da UI
@onready var background = $Background
@onready var center_container = $CenterContainer
@onready var main_vbox = $CenterContainer/MainVBox

# Barras de status
@onready var health_bar = $CenterContainer/MainVBox/BarsHBox/HealthContainer/HealthBar
@onready var stamina_bar = $CenterContainer/MainVBox/BarsHBox/StaminaContainer/StaminaBar

# Slots de equipamento
@onready var helmet_slot = $CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/HelmetContainer/HelmetSlot
@onready var cape_slot = $CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/CapeContainer/CapeSlot
@onready var right_hand_slot = $CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/RightHandContainer/RightHandSlot
@onready var left_hand_slot = $CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/LeftHandContainer/LeftHandSlot

# Slots de itens
@onready var item_slots_grid = $CenterContainer/MainVBox/ItemsPanel/MarginContainer/ItemsGrid

# Área de drop
@onready var drop_area = $CenterContainer/MainVBox/EquipmentContainer/DropArea

# Valores do jogador
var max_health = 100.0
var current_health = 85.0
var max_stamina = 100.0
var current_stamina = 60.0

# Sistema de drag
var dragged_item = null
var drag_preview = null
var original_slot = null

func _ready():
	update_bars()
	setup_slot_metadata()
	add_test_items()

func setup_slot_metadata():
	# Configurar metadados dos slots de equipamento
	helmet_slot.set_meta("slot_type", "helmet")
	helmet_slot.set_meta("is_equipment", true)
	
	cape_slot.set_meta("slot_type", "cape")
	cape_slot.set_meta("is_equipment", true)
	
	right_hand_slot.set_meta("slot_type", "right_hand")
	right_hand_slot.set_meta("is_equipment", true)
	
	left_hand_slot.set_meta("slot_type", "left_hand")
	left_hand_slot.set_meta("is_equipment", true)
	
	# Configurar metadados dos slots de inventário
	var index = 0
	for slot in item_slots_grid.get_children():
		slot.set_meta("slot_index", index)
		slot.set_meta("is_equipment", false)
		index += 1

func update_bars():
	if health_bar:
		health_bar.value = (current_health / max_health) * 100
	if stamina_bar:
		stamina_bar.value = (current_stamina / max_stamina) * 100

func set_health(value: float):
	current_health = clamp(value, 0, max_health)
	update_bars()

func set_stamina(value: float):
	current_stamina = clamp(value, 0, max_stamina)
	update_bars()

func damage_health(amount: float):
	set_health(current_health - amount)

func restore_health(amount: float):
	set_health(current_health + amount)

func consume_stamina(amount: float):
	set_stamina(current_stamina - amount)

func restore_stamina(amount: float):
	set_stamina(current_stamina + amount)

# Sistema de Drag & Drop
func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				try_start_drag(event.position)
			else:
				try_end_drag(event.position)
	
	elif event is InputEventMouseMotion and dragged_item:
		update_drag_preview(event.position)

func try_start_drag(mouse_pos: Vector2):
	var slot = find_slot_at_position(mouse_pos)
	if not slot:
		return
	
	var item = find_item_in_slot(slot)
	if not item:
		return
	
	dragged_item = item
	original_slot = slot
	
	# Criar preview visual
	drag_preview = Control.new()
	drag_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_preview.z_index = 100
	
	var item_scene = item.get_meta("item_scene") if item.has_meta("item_scene") else null
	if item_scene:
		var preview_instance = item_scene.instantiate()
		preview_instance.modulate.a = 0.7
		drag_preview.add_child(preview_instance)
	
	add_child(drag_preview)
	update_drag_preview(mouse_pos)
	
	item.modulate.a = 0.3

func update_drag_preview(mouse_pos: Vector2):
	if drag_preview:
		drag_preview.global_position = mouse_pos - Vector2(25, 25)

func try_end_drag(mouse_pos: Vector2):
	if not dragged_item:
		return
	
	# Verificar área de drop
	if is_over_drop_area(mouse_pos):
		drop_item()
		cleanup_drag()
		return
	
	# Verificar slot válido
	var target_slot = find_slot_at_position(mouse_pos)
	if target_slot and can_place_item(dragged_item, target_slot):
		place_item_in_slot(dragged_item, target_slot)
	else:
		dragged_item.modulate.a = 1.0
	
	cleanup_drag()

func find_slot_at_position(pos: Vector2) -> Panel:
	# Slots de equipamento
	var equipment_slots = [helmet_slot, cape_slot, right_hand_slot, left_hand_slot]
	
	for slot in equipment_slots:
		if slot:
			var rect = Rect2(slot.global_position, slot.size)
			if rect.has_point(pos):
				return slot
	
	# Slots de inventário
	for slot in item_slots_grid.get_children():
		var rect = Rect2(slot.global_position, slot.size)
		if rect.has_point(pos):
			return slot
	
	return null

func find_item_in_slot(slot: Panel) -> Control:
	for child in slot.get_children():
		if child.has_meta("is_item"):
			return child
	return null

func can_place_item(item: Control, slot: Panel) -> bool:
	if not item or not slot:
		return false
	
	if slot.has_meta("is_equipment") and slot.get_meta("is_equipment"):
		var required_type = slot.get_meta("slot_type")
		var item_type = item.get_meta("item_type") if item.has_meta("item_type") else ""
		return item_type == required_type
	
	return true

func place_item_in_slot(item: Control, target_slot: Panel):
	var existing_item = find_item_in_slot(target_slot)
	
	if existing_item and existing_item != item:
		swap_items(item, existing_item, original_slot, target_slot)
	else:
		item.get_parent().remove_child(item)
		target_slot.add_child(item)
		item.position = Vector2.ZERO
		item.size = target_slot.size
		item.modulate.a = 1.0

func swap_items(item1: Control, item2: Control, slot1: Panel, slot2: Panel):
	item1.get_parent().remove_child(item1)
	item2.get_parent().remove_child(item2)
	
	slot2.add_child(item1)
	slot1.add_child(item2)
	
	item1.position = Vector2.ZERO
	item1.size = slot2.size
	item1.modulate.a = 1.0
	
	item2.position = Vector2.ZERO
	item2.size = slot1.size

func is_over_drop_area(pos: Vector2) -> bool:
	if not drop_area:
		return false
	var rect = Rect2(drop_area.global_position, drop_area.size)
	return rect.has_point(pos)

func drop_item():
	if dragged_item:
		print("Item dropado: ", dragged_item.get_meta("item_name") if dragged_item.has_meta("item_name") else "Item")
		dragged_item.queue_free()

func cleanup_drag():
	if drag_preview:
		drag_preview.queue_free()
		drag_preview = null
	dragged_item = null
	original_slot = null

func add_item_to_inventory(item_scene: PackedScene, item_name: String, item_type: String = ""):
	for slot in item_slots_grid.get_children():
		if find_item_in_slot(slot) == null:
			create_item_in_slot(slot, item_scene, item_name, item_type)
			return true
	return false

func create_item_in_slot(slot: Panel, item_scene: PackedScene, item_name: String, item_type: String):
	var item_instance = item_scene.instantiate()
	item_instance.set_meta("is_item", true)
	item_instance.set_meta("item_name", item_name)
	item_instance.set_meta("item_type", item_type)
	item_instance.set_meta("item_scene", item_scene)
	
	item_instance.position = Vector2.ZERO
	
	if item_instance is Control:
		item_instance.custom_minimum_size = slot.size
		item_instance.size = slot.size
	elif item_instance is Node2D:
		var wrapper = Control.new()
		wrapper.custom_minimum_size = slot.size
		wrapper.size = slot.size
		wrapper.set_meta("is_item", true)
		wrapper.set_meta("item_name", item_name)
		wrapper.set_meta("item_type", item_type)
		wrapper.set_meta("item_scene", item_scene)
		wrapper.add_child(item_instance)
		item_instance.position = slot.size / 2
		slot.add_child(wrapper)
		return
	
	slot.add_child(item_instance)

func add_test_items():
	var sword_scene = create_test_item_scene(Color.STEEL_BLUE, "⚔")
	add_item_to_inventory(sword_scene, "Espada", "right_hand")
	
	var shield_scene = create_test_item_scene(Color.DARK_GRAY, "🛡")
	add_item_to_inventory(shield_scene, "Escudo", "left_hand")
	
	var helmet_scene = create_test_item_scene(Color.GOLD, "⛑")
	add_item_to_inventory(helmet_scene, "Capacete", "helmet")
	
	var cape_scene = create_test_item_scene(Color.DARK_RED, "🎽")
	add_item_to_inventory(cape_scene, "Capa", "cape")
	
	var potion_scene = create_test_item_scene(Color.RED, "🧪")
	add_item_to_inventory(potion_scene, "Poção", "")

func create_test_item_scene(color: Color, emoji: String) -> PackedScene:
	var scene = PackedScene.new()
	
	var panel = Panel.new()
	panel.custom_minimum_size = Vector2(50, 50)
	
	var bg = StyleBoxFlat.new()
	bg.bg_color = color
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	panel.add_theme_stylebox_override("panel", bg)
	
	var label = Label.new()
	label.text = emoji
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(50, 50)
	label.add_theme_font_size_override("font_size", 24)
	panel.add_child(label)
	
	scene.pack(panel)
	return scene
