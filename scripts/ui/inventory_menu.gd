# InventoryUI.gd
extends Control

# Referências da UI
@onready var inventory_root = $Inventory
@onready var background_canvas = $Inventory/CanvasLayer
@onready var center_container = $Inventory/CenterContainer
@onready var main_vbox = $Inventory/CenterContainer/MainVBox

# Referências de grupos
@onready var inventory = $Inventory
@onready var status_bar = $StatusBar

# Barras de status
@onready var health_bar = $StatusBar/BarsHBox/HealthContainer/HealthBar
@onready var stamina_bar = $StatusBar/BarsHBox/StaminaContainer/StaminaBar

# Slots de equipamento
@onready var helmet_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/HelmetContainer/HelmetSlot
@onready var cape_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/CapeContainer/CapeSlot
@onready var right_hand_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/RightHandContainer/RightHandSlot
@onready var left_hand_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/LeftHandContainer/LeftHandSlot

# Slots de itens
@onready var item_slots_grid = $Inventory/CenterContainer/MainVBox/ItemsPanel/MarginContainer/ItemsGrid

# Área de drop
@onready var drop_area = $Inventory/CenterContainer/MainVBox/EquipmentContainer/DropArea

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
	# Configurar estado inicial do inventário
	if inventory_root:
		inventory_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # Iniciar bloqueando cliques
		inventory_root.hide()  # Iniciar escondido
		background_canvas.hide()
	
	update_bars()
	setup_slot_metadata()
	add_test_items()

func _process(_delta):
	if inventory_root and !inventory_root.visible:
		if dragged_item or drag_preview:
			cleanup_drag()
		
		disable_inventory_input()

func show_inventory():
	if inventory_root:
		# ✅ PERMITIR CLIQUES NO INVENTÁRIO
		inventory_root.mouse_filter = Control.MOUSE_FILTER_STOP
		
		# Reativar input recursivo (slots + itens)
		_set_mouse_filter_recursive(inventory_root, Control.MOUSE_FILTER_STOP)
		
		# Mostrar interface
		inventory_root.show()
		background_canvas.show()

func hide_inventory():
	if inventory_root:
		# ✅ BLOQUEAR CLIQUES NO INVENTÁRIO (liberar para o jogo)
		inventory_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		
		# Desativar input recursivo (slots + itens)
		_set_mouse_filter_recursive(inventory_root, Control.MOUSE_FILTER_IGNORE)
		
		# Limpar qualquer drag pendente
		cleanup_drag()
		
		# Esconder interface
		inventory_root.hide()
		background_canvas.hide()

# Desativa input de TOD.O o inventário (slots + itens)
func disable_inventory_input():
	_set_mouse_filter_recursive(inventory_root, Control.MOUSE_FILTER_IGNORE)

# Reativa input de TODO o inventário
func enable_inventory_input():
	_set_mouse_filter_recursive(inventory_root, Control.MOUSE_FILTER_STOP)

# Aplica recursivamente a todos os controles
func _set_mouse_filter_recursive(node: Node, filter: int):
	if node is Control:
		node.mouse_filter = filter
	
	for child in node.get_children():
		_set_mouse_filter_recursive(child, filter)

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
	if !inventory_root or !inventory_root.visible:
		return
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
	if not slot or not slot.visible:
		return
	
	var item = find_item_in_slot(slot)
	if not item:
		return
	
	dragged_item = item
	original_slot = slot
	item.modulate.a = 0.3
	
	# ✅ CRIAR PREVIEW
	drag_preview = Control.new()
	drag_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_preview.z_index = 1000
	drag_preview.visible = false
	
	# Instanciar conteúdo
	var item_scene = item.get_meta("item_scene") if item.has_meta("item_scene") else null
	if item_scene:
		var preview_instance = item_scene.instantiate()
		preview_instance.modulate.a = 0.7
		drag_preview.add_child(preview_instance)
	
	# ✅ DEFINIR TAMANHO EXPLÍCITO (CRUCIAL)
	drag_preview.custom_minimum_size = Vector2(64, 64)  # Tamanho padrão dos slots
	drag_preview.size = Vector2(64, 64)
	
	# ✅ ADICIONAR À RAIZ DA ÁRVORE (FUNCIONA SEMPRE)
	get_tree().root.add_child(drag_preview)
	
	# ✅ POSICIONAR CORRETAMENTE NO PRIMEIRO FRAME
	_position_drag_preview(mouse_pos)
	
	# ✅ TORNAR VISÍVEL APENAS APÓS POSICIONADO
	drag_preview.visible = true

func _position_drag_preview(mouse_pos: Vector2):
	if not drag_preview:
		return
	
	# ✅ CENTRALIZAR NO CURSOR USANDO TAMANHO FIXO
	var center_offset = drag_preview.size / 2
	drag_preview.global_position = mouse_pos - center_offset

func _finalize_drag_preview_position(mouse_pos: Vector2):
	if drag_preview and drag_preview.is_inside_tree():
		# ✅ POSIÇÃO FINAL USANDO TAMANHO REAL (já calculado)
		var center_offset = drag_preview.size / 2
		drag_preview.global_position = mouse_pos - center_offset

func update_drag_preview(mouse_pos: Vector2):
	if drag_preview and drag_preview.visible:
		# ✅ SEMPRE USAR O TAMANHO REAL DO PREVIEW
		var center_offset = drag_preview.size / 2
		drag_preview.global_position = mouse_pos - center_offset

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
		_position_item_in_slot(item, target_slot)  # ✅ USAR FUNÇÃO PADRONIZADA
		item.modulate.a = 1.0

func swap_items(item1: Control, item2: Control, slot1: Panel, slot2: Panel):
	if not item1 or not item2 or not slot1 or not slot2:
		return
	
	# ✅ RESTAURAR OPACIDADE ANTES DE MOVER (evita estados residuais)
	_restore_item_opacity(item1)
	_restore_item_opacity(item2)
	
	# Remover itens das posições atuais
	item1.get_parent().remove_child(item1)
	item2.get_parent().remove_child(item2)
	
	# Adicionar aos novos slots
	slot2.add_child(item1)
	slot1.add_child(item2)
	
	# ✅ POSICIONAR CORRETAMENTE APÓS MOVER
	_position_item_in_slot(item1, slot2)
	_position_item_in_slot(item2, slot1)

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
	# ✅ REMOVER PREVIEW DA ÁRVORE (mesmo que órfão)
	if drag_preview:
		if drag_preview.get_parent():
			drag_preview.get_parent().remove_child(drag_preview)
		drag_preview.queue_free()
		drag_preview = null
	
	# ✅ RESETAR VARIÁVEIS DE ESTADO
	dragged_item = null
	original_slot = null
	
	# ✅ GARANTIR QUE NENHUM ITEM FIQUE SEMI-TRANSPARENTE
	if original_slot:
		var item = find_item_in_slot(original_slot)
		if item:
			item.modulate.a = 1.0

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
	
	if item_instance is Control:
		# Configurar tamanho e adicionar diretamente
		item_instance.custom_minimum_size = slot.size
		item_instance.size = slot.size
		slot.add_child(item_instance)
		_position_item_in_slot(item_instance, slot)
		
	elif item_instance is Node2D:
		# Criar wrapper apenas para Node2D
		var wrapper = Control.new()
		wrapper.custom_minimum_size = slot.size
		wrapper.size = slot.size
		wrapper.set_meta("is_item", true)
		wrapper.set_meta("item_name", item_name)
		wrapper.set_meta("item_type", item_type)
		wrapper.set_meta("item_scene", item_scene)
		wrapper.add_child(item_instance)
		item_instance.position = Vector2.ZERO  # Node2D: posição relativa ao wrapper
		
		slot.add_child(wrapper)
		_position_item_in_slot(wrapper, slot)  # Centralizar o wrapper
		
	else:
		# Caso genérico (pouco comum)
		slot.add_child(item_instance)
		_position_item_in_slot(item_instance, slot)

# Adicionar os itens a partir do item_database, pegar o caminho do png de lá
func add_test_items():
	var slot_size = Vector2(64, 64)  # Ajuste ao seu UI
	
	# Adicionar itens com ícones PNG
	var sword_icon = create_test_item_scene("res://material/collectibles_icons/sword_1.png", slot_size)
	add_item_to_inventory(sword_icon, "Espada", "right_hand")
	
	var shield_icon = create_test_item_scene("res://material/collectibles_icons/shield_1.png", slot_size)
	add_item_to_inventory(shield_icon, "Escudo", "left_hand")
	
	var helmet_icon = create_test_item_scene("res://material/collectibles_icons/steel_helmet.png", slot_size)
	add_item_to_inventory(helmet_icon, "Capacete", "helmet")
	
	var cape_icon = create_test_item_scene("res://material/collectibles_icons/cape_1.png", slot_size)
	add_item_to_inventory(cape_icon, "Capa", "cape")
	
	var torch_icon = create_test_item_scene("res://material/collectibles_icons/torch.png", slot_size)
	add_item_to_inventory(torch_icon, "Tocha", "left_hand")

func create_test_item_scene(icon_path: String, size_: Vector2) -> PackedScene:
	var scene = PackedScene.new()
	
	# ✅ TEXTURERECT DIRETO (sem Panel intermediário - mais confiável)
	var icon = TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	icon.custom_minimum_size = size_
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# ✅ CARREGAMENTO SEGURO DA TEXTURA
	var texture = load(icon_path)
	if texture:
		icon.texture = texture
	else:
		# ⚠️ DEBUG VISUAL SE A TEXTURA NÃO CARREGAR
		printerr("❌ ERRO: Textura não encontrada em: ", icon_path)
		icon.texture = _create_missing_texture(size)
		icon.self_modulate = Color.RED  # Vermelho = erro
	
	# ✅ EMPACOTAR CENA
	scene.pack(icon)
	return scene

func _create_missing_texture(size_: Vector2) -> Texture2D:
	# Cria um quadro vermelho com "X" para identificar itens faltantes
	var image = Image.create(int(size_.x), int(size_.y), false, Image.FORMAT_RGBA8)
	image.fill(Color(0.599, 0.0, 0.0, 0.3))  # Fundo vermelho translúcido
	
	# Desenhar um "X" branco
	var line_thickness = max(2, int(min(size_.x, size_.y) / 10))
	for i in range(line_thickness):
		# Diagonal principal
		image.draw_line(Vector2(i, i), Vector2(size_.x - i, size_.y - i), Color.WHITE)
		# Diagonal secundária
		image.draw_line(Vector2(i, size_.y - i), Vector2(size_.x - i, i), Color.WHITE)
	
	return ImageTexture.create_from_image(image)

func _position_item_in_slot(item: Control, slot: Panel):
	if not item or not slot:
		return
	
	# Forçar tamanho do slot
	item.custom_minimum_size = slot.size
	item.size = slot.size
	
	# ✅ CENTRALIZAÇÃO UNIVERSAL (funciona para 99% dos casos)
	item.anchor_left = 0.0
	item.anchor_top = 0.0
	item.anchor_right = 0.0
	item.anchor_bottom = 0.0
	item.offset_left = 0
	item.offset_top = 0
	item.offset_right = slot.size.x
	item.offset_bottom = slot.size.y
	
	# Se for TextureRect (ícones PNG), centralizar pixel-perfect
	if item is TextureRect:
		item.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		item.expand_mode = TextureRect.EXPAND_IGNORE_SIZE

func _restore_item_opacity(item: Control):
	if item and item.is_inside_tree():
		item.modulate.a = 1.0
