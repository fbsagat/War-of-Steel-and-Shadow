# InventoryUI.gd
extends Control
# teste

# Referências da UI
@onready var inventory_root = $Inventory
@onready var background_canvas = $Inventory/CanvasLayer
@onready var center_container = $Inventory/CenterContainer
@onready var main_vbox = $Inventory/CenterContainer/MainVBox

# Referências de grupos
@onready var inventory = $Inventory
@onready var status_bar = $StatusBar

# Barras de status
@onready var health_bar = $StatusBar/VBoxContainer/BarsHBox/HealthContainer/HealthBar
@onready var stamina_bar = $StatusBar/VBoxContainer/BarsHBox/StaminaContainer/StaminaBar

# Slots de equipamento
@onready var helmet_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/HelmetContainer/HelmetSlot
@onready var cape_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/CapeContainer/CapeSlot
@onready var right_hand_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/RightHandContainer/RightHandSlot
@onready var left_hand_slot = $Inventory/CenterContainer/MainVBox/EquipmentContainer/EquipmentGrid/LeftHandContainer/LeftHandSlot

# Slots de itens
@onready var item_slots_grid = $Inventory/CenterContainer/MainVBox/HBoxContainer/ItemsPanel/MarginContainer/ItemsGrid
@onready var item_slots_grid_on = $StatusBar/VBoxContainer/HBoxContainer/ItemsPanel/MarginContainer/ItemsGrid

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

# para item_slots_grid_on
var selected_index: int = 0
var item_slots: Array[Panel] = []

func _ready():
	# Configurar estado inicial do inventário
	if inventory_root:
		inventory_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # Iniciar bloqueando cliques
		inventory_root.hide()  # Iniciar escondido
		background_canvas.hide()
	
	update_bars()
	setup_slot_metadata()
	_sync_quickbar()
	#add_test_items()
	
	# Coleta os 9 filhos do ItemsGrid (espera-se que sejam Panels)
	item_slots = []
	for i in range(9):
		if i < item_slots_grid_on.get_child_count():
			var child = item_slots_grid_on.get_child(i)
			if child is Panel:
				item_slots.append(child)
	
	if item_slots.size() != 9:
		push_error("ItemsGrid deve ter exatamente 9 filhos do tipo Panel!")
		return

	# Seleciona o primeiro slot (índice 0)
	select_slot(0)

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
		item_slots_grid_on.hide()

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
		item_slots_grid_on.show()

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
	helmet_slot.set_meta("slot_type", "head")
	helmet_slot.set_meta("is_equipment", true)
	
	cape_slot.set_meta("slot_type", "back")
	cape_slot.set_meta("is_equipment", true)
	
	right_hand_slot.set_meta("slot_type", "hand-right")
	right_hand_slot.set_meta("is_equipment", true)
	
	left_hand_slot.set_meta("slot_type", "hand-left")
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
		# Teclas 1-9: selecionam slots 0-8
		for digit in range(1, 10):
			if event.is_action_pressed("digit_" + str(digit)):
				print("digit_" + str(digit))
				select_slot(digit - 1)
		
		# Tecla 'q': ativa o item selecionado
		if event.is_action_pressed("drop"):  # Use uma ação do Input Map (ex: "use_item")
			use_selected_item()
		
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
		_sync_quickbar()

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
	
	_sync_quickbar()

func is_over_drop_area(pos: Vector2) -> bool:
	if not drop_area:
		return false
	var rect = Rect2(drop_area.global_position, drop_area.size)
	return rect.has_point(pos)

func drop_item():
	if dragged_item:
		_log_debug("Item dropado: %s" % dragged_item.get_meta("item_name") if dragged_item.has_meta("item_name") else "Item")
		dragged_item.queue_free()
		_sync_quickbar()

func drop_item_by_name(item_name: String) -> bool:
	_log_debug("🔍 Buscando item para dropar: %s" % item_name)
	
	# Inventário
	for i in range(item_slots_grid.get_child_count()):
		var slot = item_slots_grid.get_child(i)
		var item = find_item_in_slot(slot)
		_log_debug("  Slot inventário %d: item = %s" % [i, item.get_meta("item_name", "SEM NOME") if item else "vazio"])
		if item and item.get_meta("item_name", "") == item_name:
			item.queue_free()
			_sync_quickbar()
			_log_debug("Item dropado do inventário: %s" % item_name)
			return true

	# Equipamento
	var eq_names = ["helmet", "cape", "right", "left"]
	var equipment_slots = [helmet_slot, cape_slot, right_hand_slot, left_hand_slot]
	for i in range(equipment_slots.size()):
		var slot = equipment_slots[i]
		if slot:
			var item = find_item_in_slot(slot)
			_log_debug("  Slot equip %s: item = %s" % [eq_names[i], item.get_meta("item_name", "SEM NOME") if item else "vazio"])
			if item and item.get_meta("item_name", "") == item_name:
				item.queue_free()
				_log_debug("Item dropado do equipamento: %s" % item_name)
				return true

	_log_debug("❌ Item não encontrado!")
	_log_debug("Item não encontrado para dropar: %s" % item_name)
	return false

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
	_sync_quickbar()
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

func add_item(item_name, item_type):
	var slot_size = Vector2(64, 64)  # Ajuste ao seu UI
	
	var png_root = "res://material/collectibles_icons/%s.png" % item_name
	var item_ = create_item_scene(png_root, slot_size)
	add_item_to_inventory(item_, item_name, item_type)

# Adicionar os itens a partir do item_database, pegar o caminho do png de lá
func add_test_items():
	var slot_size = Vector2(64, 64)  # Ajuste ao seu UI
	
	# Adicionar itens com ícones PNG
	var sword_icon = create_item_scene("res://material/collectibles_icons/sword_1.png", slot_size)
	add_item_to_inventory(sword_icon, "Espada", "right_hand")
	
	var shield_icon = create_item_scene("res://material/collectibles_icons/shield_1.png", slot_size)
	add_item_to_inventory(shield_icon, "Escudo", "left_hand")
	
	var helmet_icon = create_item_scene("res://material/collectibles_icons/steel_helmet.png", slot_size)
	add_item_to_inventory(helmet_icon, "Capacete", "helmet")
	
	var cape_icon = create_item_scene("res://material/collectibles_icons/cape_1.png", slot_size)
	add_item_to_inventory(cape_icon, "Capa", "cape")
	
	var torch_icon = create_item_scene("res://material/collectibles_icons/torch.png", slot_size)
	add_item_to_inventory(torch_icon, "Tocha", "left_hand")
	
	var potion_icon = create_item_scene("res://material/collectibles_icons/torch.png", slot_size)
	add_item_to_inventory(potion_icon, "Poção de Vida", "")

func create_item_scene(icon_path: String, size_: Vector2) -> PackedScene:
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

func equip_item(item_name: String, slot_type: String):
	# Encontrar o item no inventário
	var inventory_item = null
	var _source_slot = null
	
	# Procurar no inventário principal
	for slot in item_slots_grid.get_children():
		var item_in_slot = find_item_in_slot(slot)
		if item_in_slot and item_in_slot.get_meta("item_name") == item_name:
			inventory_item = item_in_slot
			_source_slot = slot
			break
	
	if not inventory_item:
		_log_debug("Item não encontrado no inventário: %s" % item_name)
		return false
	
	# Encontrar o slot de equipamento correspondente
	var equip_slot = _get_equipment_slot_by_type(slot_type)
	if not equip_slot:
		_log_debug("Slot de equipamento não encontrado para: %s" % slot_type)
		return false
	
	# Verificar se o slot aceita este tipo de item
	if not can_place_item(inventory_item, equip_slot):
		_log_debug("Tipo de item incompatível com slot: %s" % slot_type)
		return false
	
	# Remover do inventário e colocar no slot de equipamento
	inventory_item.get_parent().remove_child(inventory_item)
	equip_slot.add_child(inventory_item)
	_position_item_in_slot(inventory_item, equip_slot)
	
	# Notificar o sistema de gameplay (ex: atualizar stats do jogador)
	_on_item_equipped(item_name, slot_type)
	
	_sync_quickbar()
	return true
	
func unequip_item(slot_type: String):
	var equip_slot = _get_equipment_slot_by_type(slot_type)
	if not equip_slot:
		return false
	
	var equipped_item = find_item_in_slot(equip_slot)
	if not equipped_item:
		return false  # Nada equipado
	
	# Encontrar um slot vazio no inventário
	for slot in item_slots_grid.get_children():
		if find_item_in_slot(slot) == null:
			# Mover item de volta para o inventário
			equipped_item.get_parent().remove_child(equipped_item)
			slot.add_child(equipped_item)
			_position_item_in_slot(equipped_item, slot)
			
			# Notificar sistema de gameplay
			_on_item_unequipped(equipped_item.get_meta("item_name"), slot_type)
			
			_sync_quickbar()
			return true
	
	_log_debug("Inventário cheio! Não é possível desequipar item.")
	return false
	
# Mapeia tipos de slot para referências reais
func _get_equipment_slot_by_type(slot_type: String) -> Panel:
	match slot_type:
		"head": return helmet_slot
		"back": return cape_slot
		"hand-right": return right_hand_slot
		"hand-left": return left_hand_slot
		_: 
			_log_debug("Slot type não reconhecido: %s" % slot_type)
			return null

# Callbacks para integração com gameplay (implemente conforme seu jogo)
func _on_item_equipped(item_name: String, slot_type: String):
	_log_debug("Equipado: %s no slot %s" % [item_name, slot_type])
	# Aqui você atualizaria stats, animações, etc.
	# Ex: get_tree().call_group("player", "apply_item_effect", item_name, slot_type)

func _on_item_unequipped(item_name: String, slot_type: String):
	_log_debug("Desequipado: %s do slot %s" % [item_name, slot_type])
	# Aqui você removeria efeitos do item
	# Ex: get_tree().call_group("player", "remove_item_effect", item_name, slot_type)

func _sync_quickbar():
	# Limpar todos os slots do quickbar
	for i in range(item_slots_grid_on.get_child_count()):
		var slot = item_slots_grid_on.get_child(i)
		if slot is Panel:
			# Remove pelo nome (mais seguro)
			var existing_copy = slot.find_child("QuickbarItemCopy", true, false)
			if existing_copy:
				existing_copy.queue_free()

	# Preencher com base no inventário
	var inventory_slots = item_slots_grid.get_children()
	for i in range(min(9, inventory_slots.size())):
		var source_slot = inventory_slots[i]
		var target_slot = item_slots_grid_on.get_child(i) if i < item_slots_grid_on.get_child_count() else null
		
		if !target_slot or !(target_slot is Panel):
			continue

		var item_in_inventory = find_item_in_slot(source_slot)
		if item_in_inventory:
			var quickbar_item = _create_quickbar_item_copy(item_in_inventory)
			target_slot.add_child(quickbar_item)
			_position_item_in_slot(quickbar_item, target_slot)

func _create_quickbar_item_copy(original_item: Control) -> Control:
	if !original_item:
		return null

	# Criar uma cópia visual leve (não é o mesmo nó!)
	var copy: Control = null

	# Caso 1: é um TextureRect (ícone comum)
	if original_item is TextureRect:
		copy = TextureRect.new()
		copy.name = "QuickbarItemCopy"  # ← NOME ÚNICO
		copy.set_meta("is_quickbar_copy", true)  # mantém por compatibilidade
		copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		copy.custom_minimum_size = Vector2(64, 64)
		copy.size = Vector2(64, 64)
		copy.texture = original_item.texture
		copy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		copy.expand_mode = TextureRect.EXPAND_FIT_WIDTH

	# Caso 2: é um wrapper com um TextureRect ou Node2D dentro
	else:
		# Procurar o TextureRect ou ícone dentro
		var icon_node = _find_icon_in_item(original_item)
		if icon_node and icon_node is TextureRect:
			copy = TextureRect.new()
			copy.texture = icon_node.texture
			copy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			copy.expand_mode = TextureRect.EXPAND_FIT_WIDTH
		else:
			# Fallback: criar um ícone genérico (opcional)
			copy = TextureRect.new()
			copy.texture = _create_missing_texture(Vector2(64, 64))
			copy.self_modulate = Color(0.7, 0.7, 0.7)

	if copy:
		copy.set_meta("is_quickbar_copy", true)
		copy.mouse_filter = Control.MOUSE_FILTER_IGNORE  # Não deve ser clicável no quickbar
		copy.custom_minimum_size = Vector2(64, 64)
		copy.size = Vector2(64, 64)

	return copy

func _find_icon_in_item(item_node: Node) -> TextureRect:
	if item_node is TextureRect:
		return item_node
	for child in item_node.get_children():
		if child is TextureRect:
			return child
		# Recursivo (caso raro, mas seguro)
		var nested = _find_icon_in_item(child)
		if nested:
			return nested
	return null

func select_slot(index: int):
	if index < 0 or index >= item_slots.size() or item_slots.size() == 0:
		return

	# Remove destaque de TODOS os slots
	for panel in item_slots:
		panel.remove_theme_stylebox_override("panel")  # Remove qualquer override de estilo

	# Cria um novo estilo de seleção (borda amarela)
	var highlight_style = StyleBoxFlat.new()
	highlight_style.bg_color = Color(0.1, 0.1, 0.1, 0.8)  # Cor de fundo sutil (opcional)
	highlight_style.border_color = Color.YELLOW
	highlight_style.border_width_left = 2
	highlight_style.border_width_right = 2
	highlight_style.border_width_top = 2
	highlight_style.border_width_bottom = 2
	highlight_style.content_margin_left = 2  # Ajuste fino para alinhar borda
	highlight_style.content_margin_right = 2
	highlight_style.content_margin_top = 2
	highlight_style.content_margin_bottom = 2
	highlight_style.draw_center = true  # Mantém o preenchimento do fundo

	# Aplica o estilo APENAS ao slot selecionado
	item_slots[index].add_theme_stylebox_override("panel", highlight_style)
	selected_index = index

func use_selected_item():
	print("Item usado no slot: ", selected_index)
	# Aqui você integra com seu sistema de inventário
	# Exemplo: emitir um sinal ou chamar uma função do jogador
	# get_parent().use_inventory_item(selected_index)

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	print("[CLIENT][INVENTORY_MENU]%s" % message)
