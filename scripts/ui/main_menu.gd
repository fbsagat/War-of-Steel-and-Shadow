extends Control

# Sinais
#signal join_match_requested()
#signal create_match_requested(room_name: String, password: String)
#signal match_selected(match_id: int, password: String)
#signal manual_join_requested(room_name: String, password: String)
signal quit_game_requested()

# Referências dos nós
@onready var control_pai: Control
@onready var connecting_menu: CenterContainer
@onready var name_input_menu: CenterContainer
@onready var main_menu: CenterContainer
@onready var match_list_menu: CenterContainer
@onready var manual_join_menu: CenterContainer
@onready var create_match_menu: CenterContainer
@onready var room_menu: CenterContainer
@onready var how_to_play_menu: CenterContainer
@onready var options_menu: CenterContainer
@onready var loading_menu: CenterContainer

# Menu de lista de partidas
@onready var match_list: ItemList
@onready var match_password_input: LineEdit
@onready var match_password_container: VBoxContainer
@onready var match_list_error_label: Label

# Menu de conexão
@onready var connecting_label: Label
@onready var connecting_error_label: Label

# Menu de escolha de nome
@onready var player_name_input: LineEdit
@onready var name_input_error_label: Label

# Menu de entrada manual
@onready var manual_room_name_input: LineEdit
@onready var manual_room_password_input: LineEdit
@onready var manual_join_error_label: Label

# Menu de criar partida
@onready var room_name_input: LineEdit
@onready var room_password_input: LineEdit
@onready var create_match_error_label: Label

# Menu de sala (lobby)
@onready var room_name_label: Label
@onready var room_players_list: ItemList
@onready var room_start_button: Button
@onready var room_close_button: Button
@onready var room_leave_button: Button
@onready var room_error_label: Label
@onready var room_status_label: Label

# Menu de opções
@onready var volume_slider: HSlider
@onready var quality_option: OptionButton

# Menu de carregamento
@onready var loading_label: Label
@onready var loading_progress: ProgressBar
@onready var loading_icon: TextureRect

# Menu de opções
@onready var vsync_check: CheckBox
@onready var resolution_option: OptionButton
@onready var window_mode_option: OptionButton
@onready var fps_limit_option: OptionButton

@onready var master_volume_slider: HSlider
@onready var music_volume_slider: HSlider
@onready var sfx_volume_slider: HSlider
@onready var master_volume_label: Label
@onready var music_volume_label: Label
@onready var sfx_volume_label: Label

@onready var mouse_sensitivity_slider: HSlider
@onready var mouse_sensitivity_label: Label
@onready var invert_y_check: CheckBox

@onready var reset_button: Button

@export var debug_mode : bool = true

# Configurações atuais
var current_settings = {
	"video": {
		"vsync": true,
		"resolution": Vector2i(1920, 1080),
		"window_mode": 0,  # 0: Janela, 1: Fullscreen, 2: Sem bordas
		"fps_limit": 1     # 0: 30, 1: 60, 2: 120, 3: 144, 4: Ilimitado
	},
	"audio": {
		"master_volume": 100,
		"music_volume": 100,
		"sfx_volume": 100
	},
	"controls": {
		"mouse_sensitivity": 50,
		"invert_y": false
	}
}

# Resoluções disponíveis
# Resoluções disponíveis
var resolutions = [
	Vector2i(3840, 2160),  # 4K
	Vector2i(2560, 1440),  # 2K / QHD
	Vector2i(1920, 1080),  # Full HD
	Vector2i(1600, 900),   # HD+
	Vector2i(1366, 768),   # HD
	Vector2i(1280, 720),   # HD Ready
	Vector2i(1024, 768),   # XGA
	Vector2i(800, 600)     # SVGA
]

var current_matches = []
var selected_match_id = -1
var previous_menu: CenterContainer = null
var is_loading = false
var player_count = 0

func _ready():
	# Verifica se é servidor
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_log_debug("Sou o servidor - NÃO inicializando MainMenu")
		return
	
	_log_debug("Sou o cliente - Inicializando MainMenu")
		
	# Configura o Control para preencher toda a tela
	set_anchors_preset(Control.PRESET_FULL_RECT)
	
	# Obtém o control pai
	control_pai = $CanvasLayer/CenterContainer/Control
	
	# Obtém referências dos menus
	_setup_menu_references()
	
	# Obtém referências dos elementos
	_setup_element_references()
	
	# Conecta sinais dos botões
	_connect_button_signals()
	
	# Carrega configurações salvas
	load_options()
	
	# Força centralização inicial
	_center_window()
	
	# Registra esta UI no GameManager e conecta sinais
	if GameManager:
		GameManager.set_main_menu(self)
		_connect_game_manager_signals()
		
		# Mostra tela de conexão e conecta automaticamente ao servidor
		show_connecting_menu()
		GameManager.connect_to_server()
	else:
		push_warning("GameManager não encontrado! Certifique-se de que está configurado como Autoload.")
		# Se não há GameManager, mostra o menu principal
		show_main_menu()

func _process(delta):
	# Rotaciona o ícone de carregamento
	if is_loading and loading_icon:
		loading_icon.rotation += delta * 3.0

# ===== SETUP INICIAL =====

func _setup_menu_references():
	connecting_menu = control_pai.get_node("ConnectingMenu")
	name_input_menu = control_pai.get_node("NameInputMenu")
	main_menu = control_pai.get_node("MainMenu")
	match_list_menu = control_pai.get_node("MatchListMenu")
	manual_join_menu = control_pai.get_node("ManualJoinMenu")
	create_match_menu = control_pai.get_node("CreateMatchMenu")
	room_menu = control_pai.get_node("RoomMenu")
	how_to_play_menu = control_pai.get_node("HowToPlayMenu")
	options_menu = control_pai.get_node("OptionsMenu")
	loading_menu = control_pai.get_node("LoadingMenu")
	
	# Obtém referências das opções de vídeo
	vsync_check = options_menu.find_child("VsyncCheck", true, false)
	resolution_option = options_menu.find_child("ResolutionOption", true, false)
	window_mode_option = options_menu.find_child("WindowModeOption", true, false)
	fps_limit_option = options_menu.find_child("FPSLimitOption", true, false)

	# Obtém referências das opções de áudio
	master_volume_slider = options_menu.find_child("MasterVolumeSlider", true, false)
	music_volume_slider = options_menu.find_child("MusicVolumeSlider", true, false)
	sfx_volume_slider = options_menu.find_child("SFXVolumeSlider", true, false)
	master_volume_label = options_menu.find_child("MasterVolumeLabel", true, false)
	music_volume_label = options_menu.find_child("MusicVolumeLabel", true, false)
	sfx_volume_label = options_menu.find_child("SFXVolumeLabel", true, false)

	# Obtém referências das opções de controles
	mouse_sensitivity_slider = options_menu.find_child("MouseSensitivitySlider", true, false)
	mouse_sensitivity_label = options_menu.find_child("MouseSensitivityLabel", true, false)
	invert_y_check = options_menu.find_child("InvertYCheck", true, false)

	# Obtém referência do botão reset
	reset_button = options_menu.find_child("ResetButton", true, false)

func _setup_element_references():
	# Menu de conexão
	connecting_label = connecting_menu.find_child("ConnectingLabel", true, false)
	connecting_error_label = connecting_menu.find_child("ErrorLabel", true, false)
	
	# Menu de nome
	player_name_input = name_input_menu.find_child("PlayerNameInput", true, false)
	name_input_error_label = name_input_menu.find_child("ErrorLabel", true, false)
	
	# Lista de partidas
	match_list = match_list_menu.find_child("MatchList", true, false)
	match_password_container = match_list_menu.find_child("PasswordContainer", true, false)
	if match_password_container:
		match_password_input = match_password_container.find_child("PasswordInput", true, false)
	match_list_error_label = match_list_menu.find_child("ErrorLabel", true, false)
	
	# Entrada manual
	manual_room_name_input = manual_join_menu.find_child("ManualRoomNameInput", true, false)
	manual_room_password_input = manual_join_menu.find_child("ManualRoomPasswordInput", true, false)
	manual_join_error_label = manual_join_menu.find_child("ErrorLabel", true, false)
	
	# Criar partida
	room_name_input = create_match_menu.find_child("RoomNameInput", true, false)
	room_password_input = create_match_menu.find_child("RoomPasswordInput", true, false)
	create_match_error_label = create_match_menu.find_child("ErrorLabel", true, false)
	
	# Menu de sala (lobby)
	room_name_label = room_menu.find_child("RoomNameLabel", true, false)
	room_players_list = room_menu.find_child("PlayersList", true, false)
	room_start_button = room_menu.find_child("StartButton", true, false)
	room_close_button = room_menu.find_child("CloseButton", true, false)
	room_leave_button = room_menu.find_child("LeaveButton", true, false)
	room_error_label = room_menu.find_child("ErrorLabel", true, false)
	room_status_label = room_menu.find_child("StatusLabel", true, false)
	
	# Opções
	vsync_check = options_menu.find_child("VsyncCheck", true, false)
	volume_slider = options_menu.find_child("VolumeSlider", true, false)
	quality_option = options_menu.find_child("QualityOption", true, false)
	
	# Carregamento
	loading_label = loading_menu.find_child("LoadingLabel", true, false)
	loading_progress = loading_menu.find_child("LoadingProgress", true, false)
	loading_icon = loading_menu.find_child("LoadingIcon", true, false)

func _connect_button_signals():
	# Menu principal
	_connect_if_exists(main_menu, "JoinMatchButton", _on_join_match_pressed)
	_connect_if_exists(main_menu, "CreateMatchButton", _on_create_match_pressed)
	_connect_if_exists(main_menu, "HowToPlayButton", _on_how_to_play_pressed)
	_connect_if_exists(main_menu, "OptionsButton", _on_options_pressed)
	_connect_if_exists(main_menu, "QuitButton", _on_quit_pressed)
	
	# Menu de nome
	_connect_if_exists(name_input_menu, "ConfirmButton", _on_name_confirm_pressed)
	
	# Lista de partidas
	_connect_if_exists(match_list_menu, "BackButton", _on_match_list_back_pressed)
	_connect_if_exists(match_list_menu, "JoinButton", _on_match_list_join_pressed)
	_connect_if_exists(match_list_menu, "ManualJoinButton", _on_manual_join_button_pressed)
	
	if match_list:
		match_list.item_selected.connect(_on_match_item_selected)
	
	# Entrada manual
	_connect_if_exists(manual_join_menu, "ConfirmButton", _on_manual_join_confirm_pressed)
	_connect_if_exists(manual_join_menu, "BackButton", _on_manual_join_back_pressed)
	
	# Criar partida
	_connect_if_exists(create_match_menu, "ConfirmButton", _on_create_match_confirm_pressed)
	_connect_if_exists(create_match_menu, "BackButton", _on_create_match_back_pressed)
	
	# Como jogar
	_connect_if_exists(how_to_play_menu, "BackButton", _on_how_to_play_back_pressed)
	
	# Opções
	_connect_if_exists(options_menu, "ConfirmButton", _on_options_confirm_pressed)
	_connect_if_exists(options_menu, "BackButton", _on_options_back_pressed)
	
	# Sala (lobby)
	if room_start_button:
		room_start_button.pressed.connect(_on_room_start_pressed)
	if room_close_button:
		room_close_button.pressed.connect(_on_room_close_pressed)
	if room_leave_button:
		room_leave_button.pressed.connect(_on_room_leave_pressed)

func _connect_if_exists(parent: Node, button_name: String, callback: Callable):
	var button = parent.find_child(button_name, true, false)
	if button:
		button.pressed.connect(callback)
	else:
		push_warning("%s não encontrado em %s" % [button_name, parent.name])

func _connect_game_manager_signals():
	GameManager.connected_to_server.connect(_on_game_manager_connected)
	GameManager.connection_failed.connect(_on_game_manager_connection_failed)
	GameManager.disconnected_from_server.connect(_on_game_manager_disconnected)
	GameManager.rooms_list_received.connect(_on_game_manager_rooms_received)
	GameManager.name_accepted.connect(_on_game_manager_name_accepted)
	GameManager.name_rejected.connect(_on_game_manager_name_rejected)
	GameManager.room_created.connect(_on_game_manager_room_created)
	GameManager.joined_room.connect(_on_game_manager_room_joined)
	GameManager.room_updated.connect(_on_game_manager_room_updated)
	#GameManager.match_started.connect(_on_game_manager_match_started)
	GameManager.error_occurred.connect(_on_game_manager_error)
	
	# Conecta sinais das opções de vídeo
	if vsync_check:
		vsync_check.toggled.connect(_on_vsync_toggled)
	if resolution_option:
		resolution_option.item_selected.connect(_on_resolution_selected)
	if window_mode_option:
		window_mode_option.item_selected.connect(_on_window_mode_selected)
	if fps_limit_option:
		fps_limit_option.item_selected.connect(_on_fps_limit_selected)

	# Conecta sinais das opções de áudio
	if master_volume_slider:
		master_volume_slider.value_changed.connect(_on_master_volume_changed)
	if music_volume_slider:
		music_volume_slider.value_changed.connect(_on_music_volume_changed)
	if sfx_volume_slider:
		sfx_volume_slider.value_changed.connect(_on_sfx_volume_changed)

	# Conecta sinais das opções de controles
	if mouse_sensitivity_slider:
		mouse_sensitivity_slider.value_changed.connect(_on_mouse_sensitivity_changed)
	if invert_y_check:
		invert_y_check.toggled.connect(_on_invert_y_toggled)

	# Conecta sinal do botão reset
	if reset_button:
		reset_button.pressed.connect(_on_reset_pressed)

# ===== NAVEGAÇÃO DE MENUS =====

func show_connecting_menu():
	hide_all_menus()
	connecting_menu.visible = true
	if connecting_label:
		connecting_label.text = "Conectando ao servidor..."
	if connecting_error_label:
		connecting_error_label.text = ""
		connecting_error_label.visible = false

func show_main_menu():
	hide_all_menus()
	main_menu.visible = true

func show_name_input_menu():
	hide_all_menus()
	name_input_menu.visible = true
	if player_name_input:
		player_name_input.text = ""
		player_name_input.grab_focus()
	if name_input_error_label:
		name_input_error_label.text = ""
		name_input_error_label.visible = false

func show_match_list_menu():
	hide_all_menus()
	match_list_menu.visible = true
	if match_password_container:
		match_password_container.visible = false
	if match_password_input:
		match_password_input.text = ""
	if match_list_error_label:
		match_list_error_label.text = ""
		match_list_error_label.visible = false

func show_manual_join_menu():
	hide_all_menus()
	manual_join_menu.visible = true
	if manual_room_name_input:
		manual_room_name_input.text = ""
	if manual_room_password_input:
		manual_room_password_input.text = ""
	if manual_join_error_label:
		manual_join_error_label.text = ""
		manual_join_error_label.visible = false

func show_create_match_menu():
	hide_all_menus()
	create_match_menu.visible = true
	if room_name_input:
		room_name_input.text = ""
	if room_password_input:
		room_password_input.text = ""
	if create_match_error_label:
		create_match_error_label.text = ""
		create_match_error_label.visible = false

func show_how_to_play_menu():
	hide_all_menus()
	how_to_play_menu.visible = true

func show_options_menu():
	hide_all_menus()
	options_menu.visible = true
	_center_window()  # Força centralização ao abrir

func show_room_menu(room_data: Dictionary):
	hide_all_menus()
	room_menu.visible = true
	_update_room_display(room_data)

func show_loading_menu(message: String = "Carregando..."):
	previous_menu = get_current_visible_menu()
	hide_all_menus()
	loading_menu.visible = true
	is_loading = true
	if loading_label:
		loading_label.text = message
	if loading_progress:
		loading_progress.value = 0
	if loading_icon:
		loading_icon.rotation = 0

func hide_loading_menu(return_to_previous: bool = false):
	loading_menu.visible = false
	is_loading = false
	if return_to_previous and previous_menu:
		previous_menu.visible = true
	elif not return_to_previous:
		show_main_menu()

func hide_all_menus():
	connecting_menu.visible = false
	main_menu.visible = false
	name_input_menu.visible = false
	match_list_menu.visible = false
	manual_join_menu.visible = false
	create_match_menu.visible = false
	room_menu.visible = false
	how_to_play_menu.visible = false
	options_menu.visible = false
	loading_menu.visible = false

func get_current_visible_menu() -> CenterContainer:
	if connecting_menu.visible: return connecting_menu
	if main_menu.visible: return main_menu
	if name_input_menu.visible: return name_input_menu
	if match_list_menu.visible: return match_list_menu
	if manual_join_menu.visible: return manual_join_menu
	if create_match_menu.visible: return create_match_menu
	if room_menu.visible: return room_menu
	if how_to_play_menu.visible: return how_to_play_menu
	if options_menu.visible: return options_menu
	return null

# ===== CALLBACKS DO MENU DE ESCOLHA DE NOME =====

func _on_name_confirm_pressed():
	if not player_name_input:
		return
	
	var p_name = player_name_input.text.strip_edges()
	
	if p_name.is_empty():
		show_error_name_input("O nome não pode estar vazio")
		return
	
	if p_name.length() < 3:
		show_error_name_input("O nome deve ter pelo menos 3 caracteres")
		return
	
	if p_name.length() > 20:
		show_error_name_input("O nome deve ter no máximo 20 caracteres")
		return
	
	GameManager.set_player_name(p_name)

# ===== CALLBACKS DO MENU PRINCIPAL =====

func _on_join_match_pressed():
	show_match_list_menu()
	GameManager.request_rooms_list()

func _on_create_match_pressed():
	show_create_match_menu()

func _on_how_to_play_pressed():
	show_how_to_play_menu()

func _on_options_pressed():
	show_options_menu()

func _on_quit_pressed():
	quit_game_requested.emit()
	get_tree().quit()

# ===== CALLBACKS DO MENU DE LISTA DE PARTIDAS =====

func _on_match_list_back_pressed():
	show_main_menu()

func _on_match_list_join_pressed():
	if selected_match_id == -1:
		show_error_match_list("Nenhuma partida selecionada")
		return
	
	var password = match_password_input.text if match_password_input else ""
	GameManager.join_room(selected_match_id, password)

func _on_manual_join_button_pressed():
	show_manual_join_menu()

func _on_match_item_selected(index: int):
	if index < 0 or index >= current_matches.size():
		push_warning("Índice de partida inválido: " + str(index))
		selected_match_id = -1
		return
	
	selected_match_id = current_matches[index]["id"]
	var has_password = current_matches[index]["has_password"]
	
	if match_password_container:
		match_password_container.visible = has_password
	if match_list_error_label:
		match_list_error_label.visible = false

func populate_match_list(matches: Array):
	if not match_list:
		push_warning("MatchList não está inicializado")
		return
	
	current_matches = matches
	match_list.clear()
	selected_match_id = -1
	
	if match_password_container:
		match_password_container.visible = false
	
	if match_list_error_label:
		match_list_error_label.visible = false
	
	if matches.is_empty():
		if match_list_error_label:
			match_list_error_label.text = "Nenhuma partida disponível no momento"
			match_list_error_label.visible = true
		return
	
	for match_data in matches:
		var text = match_data.get("name", "Sala sem nome")  # Usa valor padrão se "name" não existir
		if match_data.get("has_password", false):
			text += " 🔒"
		
		# Converte valores para inteiros com segurança
		var players = match_data.get("players", 0)
		var max_players = match_data.get("max_players", 0)
		
		# Garante que são inteiros (trata strings, floats, nulls)
		players = _safe_to_int(players)
		max_players = _safe_to_int(max_players)
		
		# Formatação segura
		text += " (%d/%d)" % [players, max_players]
		match_list.add_item(text)

# Função auxiliar para conversão segura para inteiro
func _safe_to_int(value) -> int:
	match typeof(value):
		TYPE_INT:
			return value
		TYPE_FLOAT:
			return int(value)  # Trunca decimais
		TYPE_STRING:
			return value.to_int() if value.is_valid_integer() else 0
		_:
			push_warning("Valor inválido para conversão: ", value)
			return 0

# ===== CALLBACKS DO MENU DE ENTRADA MANUAL =====

func _on_manual_join_confirm_pressed():
	if not manual_room_name_input:
		return
	
	var room_name = manual_room_name_input.text.strip_edges()
	var password = manual_room_password_input.text if manual_room_password_input else ""
	
	if room_name.is_empty():
		show_error_manual_join("Nome da sala não pode estar vazio")
		return
	
	GameManager.join_room_by_name(room_name, password)

func _on_manual_join_back_pressed():
	show_match_list_menu()

# ===== CALLBACKS DO MENU DE CRIAR PARTIDA =====

func _on_create_match_confirm_pressed():
	if not room_name_input:
		return
	
	var room_name = room_name_input.text.strip_edges()
	var password = room_password_input.text if room_password_input else ""
	
	if room_name.is_empty():
		show_error_create_match("Nome da sala não pode estar vazio")
		return
	
	GameManager.create_room(room_name, password)

func _on_create_match_back_pressed():
	show_main_menu()

# ===== CALLBACKS DO MENU COMO JOGAR =====

func _on_how_to_play_back_pressed():
	show_main_menu()

# ===== CALLBACKS DO MENU DE OPÇÕES =====

func _on_options_confirm_pressed():
	save_options()
	show_main_menu()

func _on_options_back_pressed():
	load_options()
	show_main_menu()

func save_options():
	_log_debug("Salvando configurações...")
	
	# Aplica configurações de vídeo (agora é async)
	await _apply_video_settings()
	
	# Salva em arquivo
	var config = ConfigFile.new()
	
	# Vídeo
	config.set_value("video", "vsync", current_settings["video"]["vsync"])
	config.set_value("video", "resolution", current_settings["video"]["resolution"])
	config.set_value("video", "window_mode", current_settings["video"]["window_mode"])
	config.set_value("video", "fps_limit", current_settings["video"]["fps_limit"])
	
	# Áudio
	config.set_value("audio", "master_volume", current_settings["audio"]["master_volume"])
	config.set_value("audio", "music_volume", current_settings["audio"]["music_volume"])
	config.set_value("audio", "sfx_volume", current_settings["audio"]["sfx_volume"])
	
	# Controles
	config.set_value("controls", "mouse_sensitivity", current_settings["controls"]["mouse_sensitivity"])
	config.set_value("controls", "invert_y", current_settings["controls"]["invert_y"])
	
	var err = config.save("user://settings.cfg")
	if err == OK:
		_log_debug(" Configurações salvas com sucesso")
	else:
		_log_debug("Erro ao salvar configurações: " + err)

func load_options():
	_log_debug("Carregando configurações...")
	
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	
	if err != OK:
		_log_debug("Arquivo de configuração não encontrado, usando padrões")
		_reset_to_default()
	else:
		# Carrega vídeo
		current_settings["video"]["vsync"] = config.get_value("video", "vsync", true)
		current_settings["video"]["resolution"] = config.get_value("video", "resolution", Vector2i(1920, 1080))
		current_settings["video"]["window_mode"] = config.get_value("video", "window_mode", 0)
		current_settings["video"]["fps_limit"] = config.get_value("video", "fps_limit", 1)
		
		# Carrega áudio
		current_settings["audio"]["master_volume"] = config.get_value("audio", "master_volume", 100)
		current_settings["audio"]["music_volume"] = config.get_value("audio", "music_volume", 100)
		current_settings["audio"]["sfx_volume"] = config.get_value("audio", "sfx_volume", 100)
		
		# Carrega controles
		current_settings["controls"]["mouse_sensitivity"] = config.get_value("controls", "mouse_sensitivity", 50)
		current_settings["controls"]["invert_y"] = config.get_value("controls", "invert_y", false)
		
		_log_debug(" Configurações carregadas com sucesso")
	
	# Aplica configurações carregadas
	_apply_video_settings()
	_apply_audio_settings()
	_load_ui_from_settings()

func _reset_to_default():
	current_settings = {
		"video": {
			"vsync": true,
			"resolution": Vector2i(1920, 1080),
			"window_mode": 0,
			"fps_limit": 1
		},
		"audio": {
			"master_volume": 100,
			"music_volume": 100,
			"sfx_volume": 100
		},
		"controls": {
			"mouse_sensitivity": 50,
			"invert_y": false
		}
	}
	_log_debug("Configurações resetadas para padrão")

func _load_ui_from_settings():
	# Atualiza UI de vídeo
	if vsync_check:
		vsync_check.button_pressed = current_settings["video"]["vsync"]
	if resolution_option:
		var res_index = resolutions.find(current_settings["video"]["resolution"])
		if res_index != -1:
			resolution_option.selected = res_index
	if window_mode_option:
		window_mode_option.selected = current_settings["video"]["window_mode"]
	if fps_limit_option:
		fps_limit_option.selected = current_settings["video"]["fps_limit"]
	
	# Atualiza UI de áudio
	if master_volume_slider:
		master_volume_slider.value = current_settings["audio"]["master_volume"]
	if music_volume_slider:
		music_volume_slider.value = current_settings["audio"]["music_volume"]
	if sfx_volume_slider:
		sfx_volume_slider.value = current_settings["audio"]["sfx_volume"]
	
	# Atualiza UI de controles
	if mouse_sensitivity_slider:
		mouse_sensitivity_slider.value = current_settings["controls"]["mouse_sensitivity"]
	if invert_y_check:
		invert_y_check.button_pressed = current_settings["controls"]["invert_y"]

func _apply_video_settings():
	# Modo de janela
	match current_settings["video"]["window_mode"]:
		0:  # Janela
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		1:  # Tela cheia
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		2:  # Sem bordas
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	
	# Aguarda modo de janela ser aplicado
	await get_tree().process_frame
	
	# Resolução (apenas em modo janela ou sem bordas)
	if current_settings["video"]["window_mode"] != 1:  # Se não for fullscreen
		get_window().size = current_settings["video"]["resolution"]
		_center_window()
	
	# VSync
	if current_settings["video"]["vsync"]:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	
	# FPS Limit
	match current_settings["video"]["fps_limit"]:
		0:  Engine.max_fps = 30
		1:  Engine.max_fps = 60
		2:  Engine.max_fps = 120
		3:  Engine.max_fps = 144
		4:  Engine.max_fps = 0  # Ilimitado

func _center_window():
	"""Centraliza a janela na tela"""
	await get_tree().process_frame  # Aguarda 1 frame para aplicar
	var screen_size = DisplayServer.screen_get_size()
	var window_size = get_window().size
	get_window().position = (screen_size - window_size) / 2

func _apply_audio_settings():
	_apply_volume_realtime("Master", current_settings["audio"]["master_volume"])
	_apply_volume_realtime("Music", current_settings["audio"]["music_volume"])
	_apply_volume_realtime("SFX", current_settings["audio"]["sfx_volume"])

# ===== CALLBACKS DO MENU DE SALA (LOBBY) =====

func _on_room_start_pressed():
	GameManager.start_match()

func _on_room_close_pressed():
	GameManager.close_room()

func _on_room_leave_pressed():
	GameManager.leave_room()

# ===== ATUALIZAÇÃO DO MENU DE SALA =====

func _update_room_display(room_data: Dictionary):
	if not room_data:
		push_warning("Dados da sala vazios")
		return
	
	var _player_count = room_data.get("players", []).size()
	
	# Atualiza nome da sala
	if room_name_label and room_data.has("name"):
		var host_name = ""
		
		# Busca o nome do host
		for player in room_data.get("players", []):
			if typeof(player) == TYPE_DICTIONARY and player.get("is_host", false):
				host_name = player.get("name", "Host")
				break  # Encontrou, pode parar
		
		# Monta o texto final
		var room_name = room_data["name"]
		if host_name:
			room_name_label.text = "%s (Host: %s)" % [room_name, host_name]
		else:
			room_name_label.text = room_name
	
	# Atualiza lista de jogadores
	if room_players_list and room_data.has("players"):
		room_players_list.clear()
		for player in room_data["players"]:
			if typeof(player) == TYPE_DICTIONARY:
				var display_name = player.get("name", "Jogador")
				if player.get("is_host", false):
					display_name += " 🎚️"
				room_players_list.add_item(display_name)
			else:
				room_players_list.add_item(str(player))  # fallback seguro

	# Atualiza status
	if room_status_label:
		var max_players = room_data.get("max_players", 4)
		room_status_label.text = "Jogadores: %d/%d" % [_player_count, max_players]
	
	# 🔑 Detecta se O JOGADOR LOCAL é o host
	var meu_peer_id = multiplayer.get_unique_id()
	var host_id = room_data.get("host_id", -1)
	var is_host = (meu_peer_id == host_id)
	
	# Controla visibilidade dos botões baseado se é host
	if room_start_button:
		room_start_button.visible = is_host
		room_start_button.disabled = _player_count < room_data.get("min_players", 1)
	if room_close_button:
		room_close_button.visible = is_host
	if room_leave_button:
		room_leave_button.visible = not is_host
	
	# Limpa mensagens de erro
	if room_error_label:
		room_error_label.text = ""
		room_error_label.visible = false

func update_room_info(room_data: Dictionary):
	"""Atualiza informações da sala (chamado quando há mudanças)"""
	if room_menu.visible:
		_update_room_display(room_data)

func update_name_e_connected(player_name: String):
	if main_menu:
		var label = main_menu.get_node_or_null("VBoxContainer/ConnecteName")
		if label:
			label.text = "%s  -  Conectado 🌐" % player_name
		
# ===== FUNÇÕES DE MENSAGENS DE ERRO =====

func show_error_match_list(message: String):
	if match_list_error_label:
		match_list_error_label.text = message
		match_list_error_label.visible = true
		match_list_error_label.modulate = Color(1.0, 0.3, 0.3)
	push_warning("Lista de partidas: " + message)

func show_error_manual_join(message: String):
	if manual_join_error_label:
		manual_join_error_label.text = message
		manual_join_error_label.visible = true
		manual_join_error_label.modulate = Color(1.0, 0.3, 0.3)
	push_warning("Entrada manual: " + message)

func show_error_create_match(message: String):
	if create_match_error_label:
		create_match_error_label.text = message
		create_match_error_label.visible = true
		create_match_error_label.modulate = Color(1.0, 0.3, 0.3)
	push_warning("Criar partida: " + message)

func show_error_name_input(message: String):
	if name_input_error_label:
		name_input_error_label.text = message
		name_input_error_label.visible = true
		name_input_error_label.modulate = Color(1.0, 0.3, 0.3)
	push_warning("Escolha de nome: " + message)

func show_error_connecting(message: String):
	if connecting_error_label:
		connecting_error_label.text = message
		connecting_error_label.visible = true
		connecting_error_label.modulate = Color(1.0, 0.3, 0.3)
	push_warning("Conexão: " + message)

func show_error_room(message: String):
	if room_error_label:
		room_error_label.text = message
		room_error_label.visible = true
		room_error_label.modulate = Color(1.0, 0.3, 0.3)
	push_warning("Sala: " + message)

# ===== FUNÇÕES DE CONTROLE DE CARREGAMENTO =====

func update_loading_progress(progress: float):
	"""Atualiza o progresso do carregamento (0.0 a 1.0 ou 0 a 100)"""
	if loading_progress:
		if progress <= 1.0:
			loading_progress.value = progress * 100.0
		else:
			loading_progress.value = progress

func update_loading_message(message: String):
	"""Atualiza a mensagem de carregamento"""
	if loading_label:
		loading_label.text = message

# ===== CALLBACKS DO GAMEMANAGER =====

func _on_game_manager_connected():
	_log_debug("Conectado ao servidor com sucesso!")
	# Não faz nada aqui, aguarda nome ser aceito

func _on_game_manager_connection_failed(reason: String):
	_log_debug("Falha na conexão: " + reason)
	show_error_connecting("Falha ao conectar: " + reason)

func _on_game_manager_disconnected():
	_log_debug("Desconectado do servidor")
	show_main_menu()

func _on_game_manager_rooms_received(rooms: Array):
	_log_debug("Lista de salas recebida: %d salas" % rooms.size())
	populate_match_list(rooms)

func _on_game_manager_name_accepted():
	_log_debug("Nome aceito pelo servidor")
	show_main_menu()

func _on_game_manager_name_rejected(reason: String):
	_log_debug("Nome rejeitado: " + reason)

func _on_game_manager_room_created(room_data: Dictionary):
	_log_debug("Sala criada com sucesso")
	show_room_menu(room_data)

func _on_game_manager_room_joined(room_data: Dictionary):
	_log_debug("Entrou na sala com sucesso")
	show_room_menu(room_data)

func _on_game_manager_room_updated(room_data: Dictionary):
	_log_debug("Sala atualizada: %d jogadores" % room_data.get("players", []).size())
	update_room_info(room_data)

func _on_game_manager_match_started():
	_log_debug("Partida iniciada!")
	# A troca de cena é feita pelo GameManager
	# Aqui você pode mostrar uma tela de transição se quiser

func _on_game_manager_error(error_message: String):
	_log_debug("Erro: " + error_message)
	# Mostra erro no contexto apropriado
	if room_menu.visible:
		show_error_room(error_message)
	elif match_list_menu.visible:
		show_error_match_list(error_message)
	elif create_match_menu.visible:
		show_error_create_match(error_message)
	elif manual_join_menu.visible:
		show_error_manual_join(error_message)

# ===== CALLBACKS DE VÍDEO =====

func _on_vsync_toggled(enabled: bool):
	current_settings["video"]["vsync"] = enabled

func _on_resolution_selected(index: int):
	if index >= 0 and index < resolutions.size():
		current_settings["video"]["resolution"] = resolutions[index]
		_log_debug("Resolução selecionada: %s" % str(resolutions[index]))

func _on_window_mode_selected(index: int):
	current_settings["video"]["window_mode"] = index
	_log_debug("Modo de janela selecionado: %d" % index)

func _on_fps_limit_selected(index: int):
	current_settings["video"]["fps_limit"] = index

# ===== CALLBACKS DE ÁUDIO =====

func _on_master_volume_changed(value: float):
	current_settings["audio"]["master_volume"] = int(value)
	if master_volume_label:
		master_volume_label.text = "%d%%" % int(value)
	_apply_volume_realtime("Master", value)

func _on_music_volume_changed(value: float):
	current_settings["audio"]["music_volume"] = int(value)
	if music_volume_label:
		music_volume_label.text = "%d%%" % int(value)
	_apply_volume_realtime("Music", value)

func _on_sfx_volume_changed(value: float):
	current_settings["audio"]["sfx_volume"] = int(value)
	if sfx_volume_label:
		sfx_volume_label.text = "%d%%" % int(value)
	_apply_volume_realtime("SFX", value)

func _apply_volume_realtime(bus_name: String, value: float):
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx != -1:
		if value == 0:
			AudioServer.set_bus_mute(bus_idx, true)
		else:
			AudioServer.set_bus_mute(bus_idx, false)
			var volume_db = linear_to_db(value / 100.0)
			AudioServer.set_bus_volume_db(bus_idx, volume_db)

# ===== CALLBACKS DE CONTROLES =====

func _on_mouse_sensitivity_changed(value: float):
	current_settings["controls"]["mouse_sensitivity"] = int(value)
	if mouse_sensitivity_label:
		mouse_sensitivity_label.text = "%d%%" % int(value)

func _on_invert_y_toggled(enabled: bool):
	current_settings["controls"]["invert_y"] = enabled

# ===== BOTÃO RESET =====

func _on_reset_pressed():
	_log_debug("Resetando configurações para padrão")
	_reset_to_default()
	_load_ui_from_settings()
	
# ===== UTILITÁRIOS =====

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		print("[MainMenu]: " + message)
