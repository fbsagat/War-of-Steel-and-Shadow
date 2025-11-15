extends Node
## InputMapSetup - Garante que todas as ações de input existem
## Adicione como Autoload: Project → Project Settings → Autoload
var actions_config: Dictionary

func _ready():
	print("\n╔════════════════════════════════════════╗")
	print("║    INPUT MAP SETUP                     ║")
	print("╚════════════════════════════════════════╝\n")
	
	_ensure_all_actions()
	_print_summary()

func _ensure_all_actions():
	"""Garante que todas as ações necessárias existem"""
	
	# IMPORTANTE: Remove ações UI padrão que conflitam
	_remove_conflicting_ui_actions()
	
	# Definição completa de todas as ações
	var actions_config = {
		"move_forward": {
			"keys": [KEY_W, KEY_UP],
			"deadzone": 0.2
		},
		"move_backward": {
			"keys": [KEY_S, KEY_DOWN],
			"deadzone": 0.2
		},
		"move_left": {
			"keys": [KEY_A, KEY_LEFT],
			"deadzone": 0.2
		},
		"move_right": {
			"keys": [KEY_D, KEY_RIGHT],
			"deadzone": 0.2
		},
		"jump": {
			"keys": [KEY_SPACE],
			"deadzone": 0.5
		},
		"run": {
			"keys": [KEY_SHIFT, KEY_CTRL],
			"deadzone": 0.5
		},
		"toggle_mouse": {
			"keys": [KEY_ESCAPE],
			"deadzone": 0.5
		}
	}

func _remove_conflicting_ui_actions():
	"""Remove ações UI padrão do Godot que conflitam com movimento"""
	var ui_actions = ["ui_up", "ui_down", "ui_left", "ui_right"]
	
	for action in ui_actions:
		if InputMap.has_action(action):
			# Remove eventos de setas das ações UI
			var events = InputMap.action_get_events(action)
			for event in events:
				if event is InputEventKey:
					var key = event.keycode
					if key in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
						InputMap.action_erase_event(action, event)
						print("  🗑️  Removido conflito: %s não usa mais setas" % action)
	
	for action_name in actions_config:
		var config = actions_config[action_name]
		_ensure_action(action_name, config["keys"], config["deadzone"])
	
	print("\nConflitos resolvidos e ações configuradas!")

func _ensure_action(action_name: String, keys: Array, deadzone: float = 0.5):
	"""Garante que uma ação existe com as teclas especificadas"""
	
	# Se a ação não existe, cria
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name, deadzone)
		print("  ➕ Criando ação: %s" % action_name)
	
	# Verifica eventos existentes
	var existing_events = InputMap.action_get_events(action_name)
	var existing_keys = []
	
	for event in existing_events:
		if event is InputEventKey:
			existing_keys.append(event.keycode)
	
	# Adiciona teclas faltantes
	for key in keys:
		if not key in existing_keys:
			var event = InputEventKey.new()
			event.keycode = key
			InputMap.action_add_event(action_name, event)
			print("     Adicionada tecla: %s → %s" % [action_name, _key_to_string(key)])

func _print_summary():
	"""Imprime resumo das configurações"""
	print("\n📋 Resumo do Input Map:")
	print("─────────────────────────────────────────")
	
	var actions = [
		"move_forward",
		"move_backward", 
		"move_left",
		"move_right",
		"jump",
		"run",
		"toggle_mouse"
	]
	
	var all_ok = true
	
	for action in actions:
		if InputMap.has_action(action):
			var events = InputMap.action_get_events(action)
			var keys_str = ""
			
			for i in range(events.size()):
				var event = events[i]
				if event is InputEventKey:
					keys_str += _key_to_string(event.keycode)
					if i < events.size() - 1:
						keys_str += ", "
			
			print("   %-15s : %s" % [action, keys_str])
		else:
			print("  %-15s : FALTANDO!" % action)
			all_ok = false
	
	print("─────────────────────────────────────────")
	
	if all_ok:
		print("Input Map configurado com sucesso!\n")
	else:
		print("⚠️  Algumas ações estão faltando!\n")

func _key_to_string(keycode: int) -> String:
	"""Converte keycode para string legível"""
	match keycode:
		KEY_W: return "W"
		KEY_A: return "A"
		KEY_S: return "S"
		KEY_D: return "D"
		KEY_SPACE: return "Space"
		KEY_SHIFT: return "Shift"
		KEY_CTRL: return "Ctrl"
		KEY_UP: return "↑"
		KEY_DOWN: return "↓"
		KEY_LEFT: return "←"
		KEY_RIGHT: return "→"
		_: return "Key_%d" % keycode

func test_input():
	"""Função de teste que pode ser chamada de qualquer lugar"""
	print("\n🎮 TESTE DE INPUT:")
	print("Pressione as teclas de movimento...")
	print("(Ctrl+C para sair)")
	
	var test_duration = 10.0  # Testa por 10 segundos
	var start_time = Time.get_ticks_msec() / 1000.0
	
	while Time.get_ticks_msec() / 1000.0 - start_time < test_duration:
		var detected = []
		
		if Input.is_action_pressed("move_forward"):
			detected.append("Frente")
		if Input.is_action_pressed("move_backward"):
			detected.append("Trás")
		if Input.is_action_pressed("move_left"):
			detected.append("Esquerda")
		if Input.is_action_pressed("move_right"):
			detected.append("Direita")
		if Input.is_action_pressed("jump"):
			detected.append("Pulo")
		if Input.is_action_pressed("run"):
			detected.append("Correr")
		
		if not detected.is_empty():
			print("  Detectado: %s" % ", ".join(detected))
		
		await get_tree().process_frame
	
	print(" Teste concluído\n")
