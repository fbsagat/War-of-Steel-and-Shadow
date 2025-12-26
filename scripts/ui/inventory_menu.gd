extends Control

# =============================================================================
# SISTEMA DE INVENTÁRIO CLIENTE-SERVIDOR
# =============================================================================
# Este script gerencia APENAS a interface visual do inventário
# Toda lógica de estado é controlada pelo servidor via sinais
# =============================================================================

# =============================================================================
# SINAIS PARA COMUNICAÇÃO COM O SERVIDOR
# =============================================================================

# Sinais enviados AO SERVIDOR (requisições)
signal request_drop_item(item_id: String)
signal request_equip_item(item_id: String, slot_type: String)
signal request_unequip_item(slot_type: String)
signal request_swap_items(item_id_1: String, item_id_2: String, slot_type_1: String, slot_type_2: String)
#signal request_move_item(item_id: String, from_slot: String, to_slot: String)

# =============================================================================
# REFERÊNCIAS DA UI
# =============================================================================

# Grupos principais
@onready var inventory_root = $Inventory
@onready var background_canvas = $Inventory/CanvasLayer
@onready var center_container = $Inventory/CenterContainer
@onready var main_vbox = $Inventory/CenterContainer/MainVBox

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

# Grade de inventário (9 slots - visível quando inventário aberto)
@onready var item_slots_grid = $Inventory/CenterContainer/MainVBox/HBoxContainer/ItemsPanel/MarginContainer/ItemsGrid

# Quickbar (9 slots - sempre visível na HUD)
@onready var item_slots_grid_on = $StatusBar/VBoxContainer/HBoxContainer/ItemsPanel/MarginContainer/ItemsGrid

# Área de drop
@onready var drop_area = $Inventory/CenterContainer/MainVBox/EquipmentContainer/DropArea

# =============================================================================
# ESTADO DO JOGADOR (recebido do servidor)
# =============================================================================

var max_health = 100.0
var current_health = 85.0
var max_stamina = 100.0
var current_stamina = 60.0

# =============================================================================
# SISTEMA DE DRAG & DROP (APENAS VISUAL - NÃO ALTERA ESTADO)
# =============================================================================

var dragged_item = null           # Control sendo arrastado
var dragged_item_id = ""          # ID único do item sendo arrastado
var drag_preview = null           # Preview visual durante drag
var original_slot = null          # Slot de origem
var original_slot_type = ""       # Tipo do slot de origem ("inventory_0", "equipment_head", etc)

# =============================================================================
# SISTEMA DE QUICKBAR (HUD)
# =============================================================================

var selected_index: int = 0       # Índice do slot selecionado (0-8)
var item_slots: Array[Panel] = [] # Referências aos 9 slots do quickbar

# =============================================================================
# GERAÇÃO DE IDs ÚNICOS
# =============================================================================

var next_item_id: int = 0  # Contador para IDs únicos

func _generate_item_id() -> String:
	"""Gera um ID único para cada instância de item"""
	next_item_id += 1
	return "item_%d_%d" % [Time.get_ticks_msec(), next_item_id]

# =============================================================================
# INICIALIZAÇÃO
# =============================================================================

func _ready():
	_setup_initial_state()
	_setup_slot_metadata()
	_setup_quickbar_slots()
	update_bars()
	
	# TESTE: adicionar itens iniciais (remova em produção)
	#add_test_items()

func _setup_initial_state():
	"""Configura estado inicial da interface"""
	if inventory_root:
		inventory_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inventory_root.hide()
		background_canvas.hide()
	
	item_slots_grid_on.show()

func _setup_slot_metadata():
	"""Define metadados para identificar cada slot"""
	# Slots de equipamento
	helmet_slot.set_meta("slot_type", "head")
	helmet_slot.set_meta("slot_id", "equipment_head")
	helmet_slot.set_meta("is_equipment", true)
	
	cape_slot.set_meta("slot_type", "back")
	cape_slot.set_meta("slot_id", "equipment_back")
	cape_slot.set_meta("is_equipment", true)
	
	right_hand_slot.set_meta("slot_type", "hand-right")
	right_hand_slot.set_meta("slot_id", "equipment_right")
	right_hand_slot.set_meta("is_equipment", true)
	
	left_hand_slot.set_meta("slot_type", "hand-left")
	left_hand_slot.set_meta("slot_id", "equipment_left")
	left_hand_slot.set_meta("is_equipment", true)
	
	# Slots de inventário (0-8)
	for i in range(item_slots_grid.get_child_count()):
		var slot = item_slots_grid.get_child(i)
		slot.set_meta("slot_index", i)
		slot.set_meta("slot_id", "inventory_%d" % i)
		slot.set_meta("is_equipment", false)

func _setup_quickbar_slots():
	"""Coleta referências dos 9 slots do quickbar"""
	item_slots = []
	for i in range(min(9, item_slots_grid_on.get_child_count())):
		var child = item_slots_grid_on.get_child(i)
		if child is Panel:
			item_slots.append(child)
			# Configurar metadados do quickbar
			child.set_meta("slot_index", i)
			child.set_meta("slot_id", "quickbar_%d" % i)
			child.set_meta("is_quickbar", true)
	
	if item_slots.size() > 0:
		select_slot(0)  # Selecionar primeiro slot

func setup_inventory_signals():
	GameManager.item_added.connect(on_server_item_added)
	GameManager.item_removed.connect(on_server_item_removed)
	GameManager.item_equipped.connect(on_server_item_equipped)
	GameManager.item_unequipped.connect(on_server_item_unequipped)
	GameManager.items_swapped.connect(on_server_items_swapped)
	
# =============================================================================
# VISIBILIDADE DO INVENTÁRIO
# =============================================================================

func show_inventory():
	"""Abre o inventário (permite interação)"""
	if inventory_root:
		inventory_root.mouse_filter = Control.MOUSE_FILTER_STOP
		_set_mouse_filter_recursive(inventory_root, Control.MOUSE_FILTER_STOP)
		inventory_root.show()
		background_canvas.show()
		item_slots_grid_on.hide()  # Esconde quickbar quando inventário aberto
		
		# ✅ GARANTIR QUE A ÁREA DE DROP ESTÁ VISÍVEL E ATIVA
		if drop_area:
			drop_area.show()
			drop_area.mouse_filter = Control.MOUSE_FILTER_STOP
			_log_debug("✅ Área de drop ativada")

func hide_inventory():
	"""Fecha o inventário (bloqueia interação)"""
	if inventory_root:
		inventory_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_set_mouse_filter_recursive(inventory_root, Control.MOUSE_FILTER_IGNORE)
		cleanup_drag()
		inventory_root.hide()
		background_canvas.hide()
		item_slots_grid_on.show()  # Mostra quickbar quando inventário fechado
		
		# ✅ DESATIVAR ÁREA DE DROP
		if drop_area:
			drop_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_log_debug("🔒 Área de drop desativada")

func _set_mouse_filter_recursive(node: Node, filter: int):
	"""Aplica mouse_filter recursivamente a todos os controles"""
	if node is Control:
		node.mouse_filter = filter
	for child in node.get_children():
		_set_mouse_filter_recursive(child, filter)

# =============================================================================
# BARRAS DE VIDA E STAMINA
# =============================================================================

func update_bars():
	"""Atualiza barras visuais de vida e stamina"""
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

# =============================================================================
# SISTEMA DE INPUT (DRAG & DROP + QUICKBAR)
# =============================================================================

func _process(_delta):
	"""Limpa drag se inventário fechar durante arraste"""
	if inventory_root and !inventory_root.visible:
		if dragged_item or drag_preview:
			cleanup_drag()

func _input(event):
	"""Processa input de mouse (drag) e teclado (quickbar)"""
	# =========================================================================
	# INPUT DO QUICKBAR (funciona APENAS quando inventário fechado)
	# =========================================================================
	if !inventory_root or !inventory_root.visible:
		# Teclas 1-9: seleciona slots 0-8
		for digit in range(1, 10):
			if event.is_action_pressed("digit_%d" % digit):
				select_slot(digit - 1)
		
		# Tecla Q: dropa o item selecionado no quickbar
		if event.is_action_pressed("drop"):
			drop_selected_quickbar_item()
		return
	
	# =========================================================================
	# INPUT DE DRAG & DROP (funciona APENAS quando inventário aberto)
	# =========================================================================
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			try_start_drag(event.position)
		else:
			try_end_drag(event.position)
	
	elif event is InputEventMouseMotion and dragged_item:
		update_drag_preview(event.position)

# =============================================================================
# DRAG & DROP: INÍCIO
# =============================================================================

func try_start_drag(mouse_pos: Vector2):
	"""Inicia o arraste de um item"""
	var slot = find_slot_at_position(mouse_pos)
	if not slot or not slot.visible:
		return
	
	var item = find_item_in_slot(slot)
	if not item:
		return
	
	# Armazenar informações do drag
	dragged_item = item
	dragged_item_id = item.get_meta("item_id", "")
	original_slot = slot
	original_slot_type = slot.get_meta("slot_id", "")
	
	# Feedback visual: item fica transparente
	item.modulate.a = 0.3
	
	# Criar preview de arraste
	_create_drag_preview(mouse_pos)

func _create_drag_preview(mouse_pos: Vector2):
	"""Cria o preview visual que segue o cursor"""
	drag_preview = Control.new()
	drag_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_preview.z_index = 1000
	drag_preview.visible = false
	
	# Instanciar a cena do item para o preview
	var item_scene = dragged_item.get_meta("item_scene") if dragged_item.has_meta("item_scene") else null
	if item_scene:
		var preview_instance = item_scene.instantiate()
		preview_instance.modulate.a = 0.7
		drag_preview.add_child(preview_instance)
	
	# Configurar tamanho
	drag_preview.custom_minimum_size = Vector2(64, 64)
	drag_preview.size = Vector2(64, 64)
	
	# Adicionar à raiz da árvore (visível em toda a tela)
	get_tree().root.add_child(drag_preview)
	
	# Posicionar e tornar visível
	_update_drag_preview_position(mouse_pos)
	drag_preview.visible = true

func update_drag_preview(mouse_pos: Vector2):
	"""Atualiza posição do preview durante o arraste"""
	if drag_preview and drag_preview.visible:
		_update_drag_preview_position(mouse_pos)
	
	# ✅ FEEDBACK VISUAL: destacar área de drop quando cursor está sobre ela
	if drop_area:
		if is_over_drop_area(mouse_pos):
			# Destacar área de drop (vermelho mais forte)
			if drop_area.modulate != Color(1.5, 0.5, 0.5, 1.0):
				drop_area.modulate = Color(1.5, 0.5, 0.5, 1.0)
		else:
			# Cor normal
			if drop_area.modulate != Color(1.0, 1.0, 1.0, 1.0):
				drop_area.modulate = Color(1.0, 1.0, 1.0, 1.0)

func _update_drag_preview_position(mouse_pos: Vector2):
	"""Centraliza o preview no cursor"""
	if drag_preview:
		var center_offset = drag_preview.size / 2
		drag_preview.global_position = mouse_pos - center_offset

# =============================================================================
# DRAG & DROP: FIM
# =============================================================================

func try_end_drag(mouse_pos: Vector2):
	"""Finaliza o arraste e processa a ação"""
	if not dragged_item:
		return
	
	# CASO 1: Dropou na área de lixeira
	if is_over_drop_area(mouse_pos):
		_log_debug("🗑️ Item dropado na área de lixeira: %s" % dragged_item_id)
		request_drop_item.emit(dragged_item_id)
		cleanup_drag()
		# ✅ Sincronizar após drop
		await get_tree().create_timer(0.05).timeout
		_sync_quickbar()
		return
	
	# CASO 2: Dropou em um slot válido
	var target_slot = find_slot_at_position(mouse_pos)
	if target_slot:
		_handle_drop_in_slot(target_slot)
	else:
		# CASO 3: Dropou fora de qualquer slot (cancela)
		_log_debug("↩️ Drag cancelado - dropou fora dos slots")
		dragged_item.modulate.a = 1.0
	
	cleanup_drag()
	
	# ✅ SEMPRE SINCRONIZAR APÓS QUALQUER DROP
	await get_tree().create_timer(0.05).timeout
	_sync_quickbar()

func _handle_drop_in_slot(target_slot: Panel):
	"""Processa o drop de um item em um slot"""
	var target_slot_id = target_slot.get_meta("slot_id", "")
	var target_is_equipment = target_slot.get_meta("is_equipment", false)
	var target_slot_type = target_slot.get_meta("slot_type", "")
	
	var item_type = dragged_item.get_meta("item_type", "")
	var existing_item = find_item_in_slot(target_slot)
	
	var original_is_equipment = original_slot.get_meta("is_equipment", false)
	
	_log_debug("🎯 Drop detectado:")
	_log_debug("  Item: %s (tipo: %s)" % [dragged_item_id, item_type])
	_log_debug("  Origem: %s (equipamento: %s)" % [original_slot_type, original_is_equipment])
	_log_debug("  Destino: %s (equipamento: %s, tipo: %s)" % [target_slot_id, target_is_equipment, target_slot_type])
	
	# =========================================================================
	# VALIDAÇÃO: Verificar se o item pode ser colocado neste slot
	# =========================================================================
	if target_is_equipment:
		# Slots de equipamento aceitam apenas itens compatíveis
		if item_type != target_slot_type:
			_log_debug("⚠️ Item incompatível: %s ≠ %s" % [item_type, target_slot_type])
			dragged_item.modulate.a = 1.0
			return
	
	# =========================================================================
	# AÇÃO 1: SWAP (trocar com item existente)
	# =========================================================================
	if existing_item and existing_item != dragged_item:
		var existing_item_id = existing_item.get_meta("item_id", "")
		_log_debug("🔄 Swap detectado: %s ↔ %s" % [dragged_item_id, existing_item_id])
		request_swap_items.emit(
			dragged_item_id,
			existing_item_id,
			original_slot_type,
			target_slot_id
		)
		return
	
	# =========================================================================
	# AÇÃO 2: EQUIPAR (mover para slot de equipamento)
	# =========================================================================
	if target_is_equipment and !original_is_equipment:
		_log_debug("⚔️ Equipando: %s → %s" % [dragged_item_id, target_slot_type])
		request_equip_item.emit(dragged_item_id, target_slot_type)
		return
	
	# =========================================================================
	# AÇÃO 3: DESEQUIPAR (mover de equipamento para inventário)
	# =========================================================================
	if !target_is_equipment and original_is_equipment:
		_log_debug("🎒 Desequipando visualmente: %s → slot sob o mouse" % dragged_item_id)
	
		# ✅ MOVER ITEM LOCALMENTE PARA O SLOT ALVO (sem RPC)
		dragged_item.get_parent().remove_child(dragged_item)
		target_slot.add_child(dragged_item)
		_position_item_in_slot(dragged_item, target_slot)
		dragged_item.modulate.a = 1.0
		
		var original_eq_type = original_slot.get_meta("slot_type", "")
		request_unequip_item.emit(original_eq_type)
		
		# ✅ Forçar sincronização imediata do quickbar
		_sync_quickbar()
		
		cleanup_drag()
		return
	
	# =========================================================================
	# AÇÃO 4: MOVER (reorganizar inventário localmente)
	# =========================================================================
	if !target_is_equipment and !original_is_equipment:
		_log_debug("📦 Movendo localmente: %s → %s" % [original_slot_type, target_slot_id])
		# Movimento dentro do inventário = ação local (não envia ao servidor)
		_local_move_item(dragged_item, original_slot, target_slot)
		return
	
	# =========================================================================
	# AÇÃO 5: MOVER ENTRE SLOTS DE EQUIPAMENTO (se tipos compatíveis)
	# =========================================================================
	if target_is_equipment and original_is_equipment:
		_log_debug("⚔️ Movendo entre equipamentos: %s → %s" % [original_slot_type, target_slot_type])
		# Desequipar do slot original primeiro
		var original_eq_type = original_slot.get_meta("slot_type", "")
		request_unequip_item.emit(original_eq_type)
		# Aguardar um frame e então equipar no novo slot
		await get_tree().process_frame
		request_equip_item.emit(dragged_item_id, target_slot_type)
		return
	
	# Caso nenhuma ação seja aplicável, cancela
	_log_debug("❌ Nenhuma ação aplicável")
	dragged_item.modulate.a = 1.0

func _local_move_item(item: Control, from_slot: Panel, to_slot: Panel):
	"""Move item localmente (sem enviar ao servidor)"""
	item.get_parent().remove_child(item)
	to_slot.add_child(item)
	_position_item_in_slot(item, to_slot)
	item.modulate.a = 1.0
	
	# ✅ SINCRONIZAR IMEDIATAMENTE APÓS MOVER
	_sync_quickbar()

# =============================================================================
# DRAG & DROP: UTILIDADES
# =============================================================================

func find_slot_at_position(pos: Vector2) -> Panel:
	"""Encontra o slot na posição do cursor"""
	# Verificar slots de equipamento
	var equipment_slots = [helmet_slot, cape_slot, right_hand_slot, left_hand_slot]
	for slot in equipment_slots:
		if slot and _is_point_in_slot(slot, pos):
			return slot
	
	# Verificar slots de inventário
	for slot in item_slots_grid.get_children():
		if _is_point_in_slot(slot, pos):
			return slot
	
	return null

func _is_point_in_slot(slot: Panel, pos: Vector2) -> bool:
	"""Verifica se um ponto está dentro de um slot"""
	var rect = Rect2(slot.global_position, slot.size)
	return rect.has_point(pos)

func find_item_in_slot(slot: Panel) -> Control:
	"""Encontra o item dentro de um slot (ignora cópias do quickbar)"""
	for child in slot.get_children():
		if child.has_meta("is_item") and !child.get_meta("is_quickbar_copy", false):
			return child
	return null

func is_over_drop_area(pos: Vector2) -> bool:
	"""Verifica se o cursor está sobre a área de drop"""
	if not drop_area:
		_log_debug("⚠️ drop_area não existe!")
		return false
	
	if not drop_area.visible:
		_log_debug("⚠️ drop_area não está visível!")
		return false
	
	var rect = Rect2(drop_area.global_position, drop_area.size)
	var is_over = rect.has_point(pos)
	
	if is_over:
		_log_debug("✅ Cursor sobre área de drop!")
	
	return is_over

func cleanup_drag():
	"""Limpa o estado de drag"""
	if drag_preview:
		if drag_preview.get_parent():
			drag_preview.get_parent().remove_child(drag_preview)
		drag_preview.queue_free()
		drag_preview = null
	
	if dragged_item and is_instance_valid(dragged_item):
		dragged_item.modulate.a = 1.0
	
	# ✅ RESETAR COR DA ÁREA DE DROP
	if drop_area:
		drop_area.modulate = Color(1.0, 1.0, 1.0, 1.0)
	
	dragged_item = null
	dragged_item_id = ""
	original_slot = null
	original_slot_type = ""

# =============================================================================
# QUICKBAR: SELEÇÃO E USO
# =============================================================================

func select_slot(index: int):
	"""Seleciona um slot do quickbar"""
	if index < 0 or index >= item_slots.size() or item_slots.size() == 0:
		return
	
	# Remove destaque de todos os slots
	for panel in item_slots:
		panel.remove_theme_stylebox_override("panel")
	
	# Criar estilo de seleção (borda amarela)
	var highlight_style = StyleBoxFlat.new()
	highlight_style.bg_color = Color(0.1, 0.1, 0.1, 0.8)
	highlight_style.border_color = Color.YELLOW
	highlight_style.border_width_left = 3
	highlight_style.border_width_right = 3
	highlight_style.border_width_top = 3
	highlight_style.border_width_bottom = 3
	highlight_style.draw_center = true
	
	# Aplicar ao slot selecionado
	item_slots[index].add_theme_stylebox_override("panel", highlight_style)
	selected_index = index

func drop_selected_quickbar_item():
	"""Dropa o item do slot selecionado no quickbar"""
	if selected_index < 0 or selected_index >= item_slots.size():
		return
	
	# Encontrar o item REAL no inventário (não a cópia do quickbar)
	var inventory_slot = item_slots_grid.get_child(selected_index)
	var item = find_item_in_slot(inventory_slot)
	
	if item:
		var item_id = item.get_meta("item_id", "")
		if item_id != "":
			_log_debug("🗑️ Dropando item do quickbar: %s" % item_id)
			request_drop_item.emit(item_id)

func use_selected_item():
	"""Usa o item selecionado no quickbar (implementar lógica de uso)"""
	_log_debug("🎯 Item usado no slot: %d" % selected_index)
	# TODO: Implementar lógica de uso de itens
	# Exemplo: consumir poção, ativar tocha, etc.

# =============================================================================
# FUNÇÕES CHAMADAS PELO SERVIDOR (ATUALIZAÇÃO VISUAL)
# =============================================================================

func on_server_item_added(item_id: String, item_name: String, item_type: String, icon_path: String):
	"""Resposta do servidor: adiciona item visualmente"""
	_log_debug("✅ Servidor confirmou adição: %s no primeiro slot vazio" % item_name)
	
	# Encontrar primeiro slot vazio
	for slot in item_slots_grid.get_children():
		if find_item_in_slot(slot) == null:
			# Criar item visual
			var item_scene = create_item_scene(icon_path, Vector2(64, 64))
			_create_item_in_slot(slot, item_scene, item_id, item_name, item_type)
			_sync_quickbar()
			break
			
func on_server_item_removed(item_id: String):
	"""Resposta do servidor: remove item visualmente"""
	_log_debug("🗑️ Servidor confirmou remoção: %s" % item_id)
	
	var item = _find_item_by_id(item_id)
	if item:
		item.queue_free()
		await get_tree().process_frame
		_sync_quickbar()

func on_server_item_equipped(item_id: String, slot_type: String):
	"""Resposta do servidor: equipa item visualmente"""
	_log_debug("⚔️ Servidor confirmou equipamento: %s em %s" % [item_id, slot_type])
	
	var item = _find_item_by_id(item_id)
	var equip_slot = _get_equipment_slot_by_type(slot_type)
	
	if not item:
		_log_debug("❌ Item não encontrado: %s" % item_id)
		return
	
	if not equip_slot:
		_log_debug("❌ Slot de equipamento não encontrado: %s" % slot_type)
		return
	
	# ✅ MOVER ITEM PARA O SLOT DE EQUIPAMENTO
	item.get_parent().remove_child(item)
	equip_slot.add_child(item)
	_position_item_in_slot(item, equip_slot)
	item.modulate.a = 1.0
	
	# ✅ SINCRONIZAR QUICKBAR
	_sync_quickbar()
	
	_log_debug("✅ Item equipado visualmente: %s" % item_id)

func on_server_item_unequipped(item_id: String):
	"""Resposta do servidor: desequipa item visualmente"""
	_log_debug("🎒 Servidor confirmou desequipamento: %s para slot %d" % item_id)
	
	var item = _find_item_by_id(item_id)
	var inv_slot = null
	
	if item and inv_slot:
		item.get_parent().remove_child(item)
		inv_slot.add_child(item)
		_position_item_in_slot(item, inv_slot)
		item.modulate.a = 1.0
		_sync_quickbar()

func on_server_items_swapped(item_id_1: String, item_id_2: String):
	"""Resposta do servidor: troca dois itens visualmente"""
	_log_debug("🔄 Servidor confirmou swap: %s <-> %s" % [item_id_1, item_id_2])
	
	var item1 = _find_item_by_id(item_id_1)
	var item2 = _find_item_by_id(item_id_2)
	
	if not item1 or not item2:
		return
	
	var slot1 = item1.get_parent()
	var slot2 = item2.get_parent()
	
	# Remover itens
	item1.get_parent().remove_child(item1)
	item2.get_parent().remove_child(item2)
	
	# Adicionar nos slots trocados
	slot2.add_child(item1)
	slot1.add_child(item2)
	
	# Posicionar corretamente
	_position_item_in_slot(item1, slot2)
	_position_item_in_slot(item2, slot1)
	
	# Restaurar opacidade
	item1.modulate.a = 1.0
	item2.modulate.a = 1.0
	
	_sync_quickbar()

# =============================================================================
# UTILITÁRIOS DE BUSCA
# =============================================================================

func _find_slot_by_id(slot_id: String) -> Panel:
	"""Encontra um slot pelo seu ID"""
	# Slots de inventário
	for slot in item_slots_grid.get_children():
		if slot.get_meta("slot_id", "") == slot_id:
			return slot
	
	# Slots de equipamento
	var equipment_slots = [helmet_slot, cape_slot, right_hand_slot, left_hand_slot]
	for slot in equipment_slots:
		if slot and slot.get_meta("slot_id", "") == slot_id:
			return slot
	
	return null

func _find_item_by_id(item_id: String) -> Control:
	"""Encontra um item pelo seu ID único"""
	# Buscar no inventário
	for slot in item_slots_grid.get_children():
		var item = find_item_in_slot(slot)
		if item and item.get_meta("item_id", "") == item_id:
			return item
	
	# Buscar nos slots de equipamento
	var equipment_slots = [helmet_slot, cape_slot, right_hand_slot, left_hand_slot]
	for slot in equipment_slots:
		if slot:
			var item = find_item_in_slot(slot)
			if item and item.get_meta("item_id", "") == item_id:
				return item
	
	return null

func _get_equipment_slot_by_type(slot_type: String) -> Panel:
	"""Retorna o slot de equipamento pelo tipo"""
	match slot_type:
		"head": return helmet_slot
		"back": return cape_slot
		"hand-right": return right_hand_slot
		"hand-left": return left_hand_slot
		_: return null

# =============================================================================
# SINCRONIZAÇÃO QUICKBAR
# =============================================================================

func _sync_quickbar():
	"""Sincroniza o quickbar com o inventário principal"""
	_log_debug("🔄 Sincronizando quickbar...")
	
	# Limpar todos os slots do quickbar
	for i in range(item_slots_grid_on.get_child_count()):
		var quickbar_slot = item_slots_grid_on.get_child(i)
		if quickbar_slot is Panel:
			# Remover TODAS as cópias antigas (segurança extra)
			for child in quickbar_slot.get_children():
				if child.get_meta("is_quickbar_copy", false) or child.name == "QuickbarItemCopy":
					child.queue_free()
	
	# ✅ AGUARDAR REMOÇÃO DOS NÓS (CRÍTICO!)
	await get_tree().process_frame
	
	# Preencher quickbar com base no inventário
	var inventory_slots = item_slots_grid.get_children()
	var sync_count = 0
	
	for i in range(min(9, inventory_slots.size())):
		var inventory_slot = inventory_slots[i]
		var quickbar_slot = item_slots_grid_on.get_child(i) if i < item_slots_grid_on.get_child_count() else null
		
		if not quickbar_slot or not (quickbar_slot is Panel):
			continue
		
		var item_in_inventory = find_item_in_slot(inventory_slot)
		if item_in_inventory:
			var quickbar_copy = _create_quickbar_copy(item_in_inventory)
			if quickbar_copy:
				quickbar_slot.add_child(quickbar_copy)
				_position_item_in_slot(quickbar_copy, quickbar_slot)
				sync_count += 1
				_log_debug("  ✅ Slot %d sincronizado: %s" % [i, item_in_inventory.get_meta("item_name", "?")])
		else:
			_log_debug("  ⚪ Slot %d vazio" % i)
	
	_log_debug("✅ Quickbar sincronizado: %d itens" % sync_count)

func _create_quickbar_copy(original_item: Control) -> Control:
	"""Cria uma cópia visual do item para o quickbar"""
	if not original_item:
		return null
	
	var copy: TextureRect = null
	
	# Caso 1: Item é um TextureRect
	if original_item is TextureRect:
		copy = TextureRect.new()
		copy.texture = original_item.texture
	
	# Caso 2: Item tem um TextureRect filho
	else:
		var icon = _find_icon_in_item(original_item)
		if icon and icon is TextureRect:
			copy = TextureRect.new()
			copy.texture = icon.texture
		else:
			# Fallback: criar ícone genérico
			copy = TextureRect.new()
			copy.texture = _create_missing_texture(Vector2(64, 64))
			copy.self_modulate = Color(0.7, 0.7, 0.7)
	
	if copy:
		copy.name = "QuickbarItemCopy"
		copy.set_meta("is_quickbar_copy", true)
		copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		copy.custom_minimum_size = Vector2(64, 64)
		copy.size = Vector2(64, 64)
		copy.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		copy.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	
	return copy

func _find_icon_in_item(item_node: Node) -> TextureRect:
	"""Busca recursivamente por um TextureRect dentro de um item"""
	if item_node is TextureRect:
		return item_node
	for child in item_node.get_children():
		if child is TextureRect:
			return child
		var nested = _find_icon_in_item(child)
		if nested:
			return nested
	return null

# =============================================================================
# CRIAÇÃO DE ITENS
# =============================================================================

func _create_item_in_slot(slot: Panel, item_scene: PackedScene, item_id: String, item_name: String, item_type: String):
	"""Cria uma instância de item em um slot"""
	var item_instance = item_scene.instantiate()
	
	# Configurar metadados
	item_instance.set_meta("is_item", true)
	item_instance.set_meta("item_id", item_id)
	item_instance.set_meta("item_name", item_name)
	item_instance.set_meta("item_type", item_type)
	item_instance.set_meta("item_scene", item_scene)
	
	# Configurar visual
	if item_instance is Control:
		item_instance.custom_minimum_size = slot.size
		item_instance.size = slot.size
		slot.add_child(item_instance)
		_position_item_in_slot(item_instance, slot)
	
	elif item_instance is Node2D:
		# Criar wrapper para Node2D
		var wrapper = Control.new()
		wrapper.custom_minimum_size = slot.size
		wrapper.size = slot.size
		wrapper.set_meta("is_item", true)
		wrapper.set_meta("item_id", item_id)
		wrapper.set_meta("item_name", item_name)
		wrapper.set_meta("item_type", item_type)
		wrapper.set_meta("item_scene", item_scene)
		wrapper.add_child(item_instance)
		item_instance.position = Vector2.ZERO
		slot.add_child(wrapper)
		_position_item_in_slot(wrapper, slot)
	
	else:
		slot.add_child(item_instance)
		_position_item_in_slot(item_instance, slot)

func create_item_scene(icon_path: String, size_: Vector2) -> PackedScene:
	"""Cria uma cena de item a partir de um ícone PNG"""
	var scene = PackedScene.new()
	
	var icon = TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	icon.custom_minimum_size = size_
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Carregar textura
	var texture = load(icon_path)
	if texture:
		icon.texture = texture
	else:
		printerr("❌ Textura não encontrada: %s" % icon_path)
		icon.texture = _create_missing_texture(size_)
		icon.self_modulate = Color.RED
	
	scene.pack(icon)
	return scene

func _create_missing_texture(size_: Vector2) -> Texture2D:
	"""Cria uma textura de placeholder para itens faltantes"""
	var image = Image.create(int(size_.x), int(size_.y), false, Image.FORMAT_RGBA8)
	image.fill(Color(0.6, 0.0, 0.0, 0.3))
	
	# Desenhar um "X" branco
	var thickness = max(2, int(min(size_.x, size_.y) / 10))
	for i in range(thickness):
		# Diagonal principal
		for j in range(int(size_.x)):
			var y = int((j / size_.x) * size_.y)
			if y + i < size_.y:
				image.set_pixel(j, y + i, Color.WHITE)
		
		# Diagonal secundária
		for j in range(int(size_.x)):
			var y = int(size_.y - (j / size_.x) * size_.y)
			if y - i >= 0:
				image.set_pixel(j, y - i, Color.WHITE)
	
	return ImageTexture.create_from_image(image)

func _position_item_in_slot(item: Control, slot: Panel):
	"""Posiciona e redimensiona um item dentro de um slot"""
	if not item or not slot:
		return
	
	# Forçar tamanho do slot
	item.custom_minimum_size = slot.size
	item.size = slot.size
	
	# Centralização universal
	item.anchor_left = 0.0
	item.anchor_top = 0.0
	item.anchor_right = 0.0
	item.anchor_bottom = 0.0
	item.offset_left = 0
	item.offset_top = 0
	item.offset_right = slot.size.x
	item.offset_bottom = slot.size.y
	
	# Centralizar TextureRect
	if item is TextureRect:
		item.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		item.expand_mode = TextureRect.EXPAND_IGNORE_SIZE

# =============================================================================
# FUNÇÕES DE TESTE (REMOVER EM PRODUÇÃO)
# =============================================================================

func add_test_items():
	"""Adiciona itens de teste ao inventário"""
	var slot_size = Vector2(64, 64)
	
	# Adicionar itens com ícones PNG
	var test_items = [
		{"name": "Espada", "type": "hand-right", "icon": "res://material/collectibles_icons/sword_1.png"},
		{"name": "Escudo", "type": "hand-left", "icon": "res://material/collectibles_icons/shield_1.png"},
		{"name": "Capacete", "type": "head", "icon": "res://material/collectibles_icons/steel_helmet.png"},
		{"name": "Capa", "type": "back", "icon": "res://material/collectibles_icons/cape_1.png"},
		{"name": "Tocha", "type": "hand-left", "icon": "res://material/collectibles_icons/torch.png"},
		#{"name": "Poção", "type": "", "icon": "res://material/collectibles_icons/torch.png"}
	]
	
	for item_data in test_items:
		var item_id = _generate_item_id()
		var item_scene = create_item_scene(item_data["icon"], slot_size)
		
		# Encontrar primeiro slot vazio
		for slot in item_slots_grid.get_children():
			if find_item_in_slot(slot) == null:
				_create_item_in_slot(slot, item_scene, item_id, item_data["name"], item_data["type"])
				break
	
	_sync_quickbar()

# =============================================================================
# UTILITÁRIO DE DEBUG
# =============================================================================

func _log_debug(message: String):
	"""Imprime mensagem de debug"""
	print("[CLIENT][INVENTORY] %s" % message)
