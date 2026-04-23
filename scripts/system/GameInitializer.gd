extends Node
class_name GameInitializer

# Configurações
## [TESTES] Usa o TestManager para iniciar uma partida logo na execução (localhost)
## (configura server e clients / server cria round e inicia partida com primeiros clientes /
##  clientes recebem localhost_auto_connect = true pr conectr autom.)
@export var test_mode: bool = false
## [TESTES] Define a quantidade de instâcias de clientes conectadas para executar fast_round
@export var simulador_players_qtd: int = 2
## [TESTES] Dropa itens perto dos players e ativa o trainer de cada player
@export var trainer: bool = true
## [TESTES] Ativa/desativa proteção dos botões dos menus (desativar para testes de multiplos RPCs)
@export var disable_protection: bool = false
## [TESTES] Ativa/desativa o debug visual na gameplay
@export var visual_debug: bool = true
## [TESTES] Ativa/desativa debug de RPCs (_log_debug's adicionados acima de cada RPC em todo o código)
@export var rpc_debug: bool = false
## [TESTES] [Clientes] Iniciar com o mouse destrancado
@export var start_unlocked_mouse: bool = true
## Ativa/desativa persistência do servidor (para server_id, server_secret e dados de clientes)
@export var is_persistent: bool = false

# Instruções para debug
## Executa _log_debug apenas nos itens selecionados
var activate_only_selected: bool = false
# Disponíveis: "Server", "NetworkManager", "TestManager", "GameManager", "RoomRegistry"
# "RoundRegistry", "ClientRegistry", "Player_node", "ObjectManager", "MapManager", "MainMenu"
# "ItemDatabase", "InventoryMenu", "DroppedItem"
var selected: Array = []

# Referências
## Manager de rede, gerencia comunicação entre servidor e clientes
var network_manager: NetworkManager = null
## Manager principal do servidor
var server_manager: ServerManager = null
## Manager principal dos clientes
var game_manager: Node = null
## Manager que gerencia lista de servidores salvos em persistência para os clientes
var server_list_manager: ServerListManager = null
## Carrega a base de dados de itens de gameplay, comum entre servidor e clientes
var item_database: ItemDatabase = null
## Gerenciador de mapas e spawns de players
var map_manager: MapManager = null
## Carrega a base de dados de mapas
var map_database: MapDatabase = null
## Gerenciador de persistência do servidor
var persistence_manager: ServerPersistence = null

## Managers auxiliares para o servidor
## Gerenciador autoritativo de objetos no mundo
var object_manager: ObjectManager = null
## Ferramenta de desenvolvimento para testes automatizados
var test_manager: TestManager = null
## Registro do servidor, classe de players, classe de salas e classe de partidas
var client_registry : ClientRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null

## Managers auxiliares para os clienes
## Menu de inicialização
var main_menu: Control = null
## Debug Overlay
var debug_overlay: Node = null
## Warning Overlay
var warning_overlay: CanvasLayer = null

## Inicializa servidor ou cliente baseando-se no argumento de inicialização.
## Se for servidor, pode inicializar com headless ativado ou desativado conforme comando.
## Injeta dependências em todos os scripts de inicialização, nomeia, inicializa e adiciona o seu nó ao root
func _ready():
	var args := OS.get_cmdline_args()
	var is_server := "--server" in args
	var is_headless = DisplayServer.get_name() == "headless"

	if is_server:
		_init_server(is_headless)
	else:
		# Injetar uuid do argumento client_uuid, substituindo a verificação
		# padrão na pasta do usuário (apenas para desenvolvimento)
		var id_file_ = null
		for arg in args:
			if arg.begins_with("--client_id="):
				id_file_ = arg.split("=")[1]
		_init_client(id_file_)
		
func _init_server(is_headless):
	# Instancia managers e registros
	var network_manager_scene: PackedScene = preload("res://scenes/system/server_network_manager.tscn")
	var server_manager_scene: PackedScene = preload("res://scenes/system/server_manager.tscn")
	client_registry = preload("res://scripts/only_server/registrars/ServerClientRegistry.gd").new()
	room_registry = preload("res://scripts/only_server/registrars/ServerRoomRegistry.gd").new()
	round_registry = preload("res://scripts/only_server/registrars/ServerRoundRegistry.gd").new()
	map_manager = preload("res://scripts/system/MapManager.gd").new()
	map_database = preload("res://scripts/only_server/MapDatabase.gd").new()
	item_database = preload("res://scripts/gameplay/ItemDatabase.gd").new()
	object_manager = preload("res://scripts/only_server/ServerObjectManager.gd").new()
	test_manager = preload("res://scripts/only_server/ServerTestManager.gd").new()
	
	network_manager = network_manager_scene.instantiate()
	server_manager = server_manager_scene.instantiate()

	# Nomeia para facilitar visualização
	network_manager.name = "NetworkManager"
	server_manager.name = "ServerManager"
	client_registry.name = "ClientRegistry"
	room_registry.name = "RoomRegistry"
	round_registry.name = "RoundRegistry"
	map_manager.name = "MapManager"
	map_database.name = "MapDatabase"
	item_database.name = "ItemDatabase"
	object_manager.name = "ObjectManager"
	test_manager.name = "TestManager"

	# Adiciona à árvore
	get_tree().root.add_child.call_deferred(network_manager)
	get_tree().root.add_child.call_deferred(server_manager)
	get_tree().root.add_child.call_deferred(client_registry)
	get_tree().root.add_child.call_deferred(room_registry)
	get_tree().root.add_child.call_deferred(round_registry)
	get_tree().root.add_child.call_deferred(map_manager)
	map_manager.add_child.call_deferred(map_database)
	get_tree().root.add_child.call_deferred(item_database)
	get_tree().root.add_child.call_deferred(object_manager)
	get_tree().root.add_child.call_deferred(test_manager)
	
	# Injeta dependências cruzadas:
	
	# ServerManager precisa de:
	server_manager.network_manager = network_manager
	server_manager.client_registry = client_registry
	server_manager.room_registry = room_registry
	server_manager.round_registry = round_registry
	server_manager.item_database = item_database
	server_manager.object_manager = object_manager
	server_manager.test_manager = test_manager
	server_manager.map_manager = map_manager
	server_manager.initializer = self
	
	# Networkmanager precisa de:
	network_manager.server_manager = server_manager
	network_manager.client_registry = client_registry
	network_manager.room_registry = room_registry
	network_manager.round_registry = round_registry
	network_manager.object_manager = object_manager
	network_manager.item_database = item_database
	network_manager.initializer = self
	
	# ClientRegistry precisa de:
	client_registry.network_manager = network_manager
	client_registry.server_manager = server_manager
	client_registry.room_registry = room_registry
	client_registry.round_registry = round_registry
	client_registry.object_manager = object_manager
	client_registry.item_database = item_database
	client_registry.initializer = self
	
	# RoomRegistry precisa de:
	room_registry.server_manager = server_manager
	room_registry.client_registry = client_registry
	room_registry.round_registry = round_registry
	room_registry.object_manager = object_manager
	room_registry.initializer = self
	
	# RoundRegistry precisa de:
	round_registry.client_registry = client_registry
	round_registry.server_manager = server_manager
	round_registry.network_manager = network_manager
	round_registry.room_registry = room_registry
	round_registry.object_manager = object_manager
	round_registry.initializer = self
	
	# MapManager precisa de:
	map_manager.initializer = self
	map_manager.map_database = map_database
	
	# MapDatabase precisa de:
	map_database.initializer = self
	
	# ItemDatabase precisa de:
	item_database.initializer = self
	
	# ObjectManager precisa de:
	object_manager.server_manager = server_manager
	object_manager.network_manager = network_manager
	object_manager.client_registry = client_registry
	object_manager.round_registry = round_registry
	object_manager.item_database = item_database
	object_manager.initializer = self
	
	# TestManager precisa de:
	test_manager.server_manager = server_manager
	test_manager.network_manager = network_manager
	test_manager.item_database = item_database
	test_manager.client_registry = client_registry
	test_manager.room_registry = room_registry
	test_manager.round_registry = round_registry
	test_manager.object_manager = object_manager
	test_manager.map_manager = map_manager
	test_manager.initializer = self
	
	# Carrega sistema de persistência se estiver ativado
	if is_persistent:
		persistence_manager = preload("res://scripts/only_server/server_persistence_manager.gd").new()
		persistence_manager.name = "persistence_manager"
		server_manager.add_child.call_deferred(persistence_manager)
		server_manager.persistence_manager = persistence_manager
	
	# Carrega nós que serão usados apenas se não headless
	if not is_headless:
		var server_debug_overlay_scene: PackedScene = preload("res://scenes/ui/server_debug_overlay.tscn")
		var warning_overlay_scene: PackedScene = preload("res://scenes/ui/warning_overlay.tscn")
		
		debug_overlay = server_debug_overlay_scene.instantiate()
		warning_overlay = warning_overlay_scene.instantiate()
		
		debug_overlay.name = "server_debug_overlay"
		warning_overlay.name = "server_warning_overlay"
		
		server_manager.add_child.call_deferred(debug_overlay)
		server_manager.add_child.call_deferred(warning_overlay)
		
		# Injeta dependências cruzadas:
		server_manager.warning_overlay = warning_overlay
		debug_overlay.initializer = self
		client_registry.debug_overlay = debug_overlay
		room_registry.debug_overlay = debug_overlay
		round_registry.debug_overlay = debug_overlay
		
		# Configurações
		server_manager.visual_debug = visual_debug
		debug_overlay.server_manager = server_manager
		server_manager.debug_overlay = debug_overlay
		debug_overlay.network_manager = network_manager
		debug_overlay.setup(client_registry, room_registry, round_registry, object_manager)
		debug_overlay._connect_signals()
	
	# configurações
	server_manager.is_headless = is_headless
	map_manager.is_server = true
	item_database.is_server = true
	
	# Configurar modo de testes
	if test_mode:
		server_manager.fast_round = true
		server_manager.simulador_players_qtd = simulador_players_qtd
	server_manager.test_trainer = trainer
	
	# Aguarda até que os nós tenham sido adicionados à árvore
	await get_tree().process_frame
	
	# Inicializa tudo
	server_manager.initialize()
	network_manager.initialize()
	client_registry.initialize()
	room_registry.initialize()
	round_registry.initialize()
	item_database.load_database()
	map_database.load_map_registry()
	object_manager.initialize()
	test_manager.initialize()
	server_manager.finish_start_server_log()

func _init_client(id_file_):
	# Instancia managers e registros
	var network_manager_scene: PackedScene = preload("res://scenes/system/client_network_manager.tscn")
	var game_manager_scene: PackedScene = preload("res://scenes/system/game_manager.tscn")
	var main_menu_scene: PackedScene = preload("res://scenes/ui/main_menu.tscn")
	var debug_overlay_scene: PackedScene = preload("res://scenes/ui/client_debug_overlay.tscn")
	var warning_overlay_scene: PackedScene = preload("res://scenes/ui/warning_overlay.tscn")
	
	item_database = preload("res://scripts/gameplay/ItemDatabase.gd").new()
	map_manager = preload("res://scripts/system/MapManager.gd").new()
	server_list_manager = preload("res://scripts/only_server/serverlist_manager.gd").new()

	network_manager = network_manager_scene.instantiate()
	game_manager = game_manager_scene.instantiate()
	main_menu = main_menu_scene.instantiate()
	debug_overlay = debug_overlay_scene.instantiate()
	warning_overlay = warning_overlay_scene.instantiate()

	# Nomeia para facilitar visualização
	network_manager.name = "NetworkManager"
	game_manager.name = "GameManager"
	item_database.name = "ItemDatabase"
	main_menu.name = "MainMenu"
	debug_overlay.name = "DebugOverlay"
	warning_overlay.name = "WarningOverlay"
	map_manager.name = "MapManager"
	server_list_manager.name = "ServerListManager"
	
	# Adiciona à árvore
	get_tree().root.add_child.call_deferred(network_manager)
	get_tree().root.add_child.call_deferred(game_manager)
	get_tree().root.add_child.call_deferred(item_database)
	get_tree().root.add_child.call_deferred(main_menu)
	get_tree().root.add_child.call_deferred(debug_overlay)
	get_tree().root.add_child.call_deferred(warning_overlay)
	get_tree().root.add_child.call_deferred(map_manager)
	get_tree().root.add_child.call_deferred(server_list_manager)
	
	# Injeta dependências cruzadas:
	
	# NetworkManager precisa de:
	network_manager.game_manager = game_manager
	network_manager.item_database = item_database
	network_manager.initializer = self
	
	# GameManager precisa de:
	game_manager.item_database = item_database
	game_manager.network_manager = network_manager
	game_manager.map_manager = map_manager
	game_manager.main_menu_node = main_menu
	game_manager.warning_overlay_node = warning_overlay
	game_manager.initializer = self
	
	# MainMenu precisa de:
	main_menu.game_manager = game_manager
	main_menu.server_list_manager = server_list_manager
	main_menu.initializer = self
	
	# Client debug overlay precisa de:
	debug_overlay.initializer = self
	debug_overlay.game_manager = game_manager
		
	# MapManager precisa de:
	map_manager.initializer = self
	
	# ItemDatabase precisa de:
	item_database.initializer = self
	
	# Configurações
	main_menu._connect_game_manager_signals()
	
	# Se definido argumento de diferenciação para testes em múltiplas intâncias
	if id_file_:
		game_manager.load_position = id_file_
		var UUID_string = "user://identity_%s.json" % id_file_
		var TOKEN_string = "user://server_tokens_%s.json" % id_file_
		game_manager.UUID_FILE = UUID_string
		game_manager.TOKEN_FILE = TOKEN_string
		# Altera o primeiro jogador para o localhost (desenvolvimento)
		if test_mode and id_file_ == "1":
			game_manager.server_address = "127.0.0.1"
		
	# Configurar modo de testes
	if test_mode:
		game_manager.localhost_auto_connect = true
		game_manager.is_loading = true
	if visual_debug:
		game_manager.debug_overlay_node = debug_overlay
		game_manager.debug_menu_visible = true
		
	main_menu.start_unlocked_mouse = start_unlocked_mouse
	game_manager.visual_debug = visual_debug
	main_menu.disable_protection = disable_protection
		
	item_database.is_server = false
	
	# Aguarda até que os nós tenham sido adicionados à árvore
	await get_tree().process_frame
	
	# Inicializa tudo
	network_manager.initialize()
	item_database.load_database()
	game_manager.initialize()

# ============== FUNÇÕES AUXILIARES GLOBAIS ==============

func _zip_uuid(client_uuid) -> String:
	var uuid_minor: String = ""
	if client_uuid != "": 
		var dif1 = client_uuid.substr(0, 4)
		var dif2 = client_uuid.substr(client_uuid.length() - 4, 4)
		uuid_minor = "%s[...]%s" % [dif1, dif2]
	return uuid_minor

func pretty_print_dict(data, indent: int = 0) -> void:
	var spacing = "  ".repeat(indent)
	
	if typeof(data) == TYPE_DICTIONARY:
		for key in data.keys():
			var value = data[key]
			
			if typeof(value) == TYPE_DICTIONARY:
				print("[pp]  %s%s: {" % [spacing, str(key)])
				pretty_print_dict(value, indent + 1)
				print("[pp]  %s}" % spacing)
			
			elif typeof(value) == TYPE_ARRAY:
				print("[pp]  %s%s: [" % [spacing, str(key)])
				pretty_print_dict(value, indent + 1)
				print("[pp]  %s]" % spacing)
			
			else:
				print("[pp]  %s%s: %s" % [spacing, str(key), str(value)])
	
	elif typeof(data) == TYPE_ARRAY:
		for i in data.size():
			var value = data[i]
			
			if typeof(value) == TYPE_DICTIONARY or typeof(value) == TYPE_ARRAY:
				print("[pp]  %s[%d]: {" % [spacing, i])
				pretty_print_dict(value, indent + 1)
				print("[pp]  %s}" % spacing)
			else:
				print("[pp]  %s[%d]: %s" % [spacing, i, str(value)])
