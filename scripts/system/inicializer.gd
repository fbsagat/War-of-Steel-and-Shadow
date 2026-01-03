extends Node

## Manager de rede, gerencia comunicação entre servidor e clientes
var network_manager: NetworkManager = null

## Manager principal do servidor
var server_manager: ServerManager = null

## Manager principal dos clientes
var game_manager: Node = null

## Carrega a base de dados de itens de gameplay, comum entre servidor e clientes
var item_database: ItemDatabase = null

## Registro do servidor, classe de players, classe de salas e classe de partidas
var player_registry : PlayerRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null

## Managers auxiliares para o servidor
var object_manager: ObjectManager = null
var test_manager: TestManager = null
var map_manager: Node = null

# Menu de inicialização para os clientes
var main_menu: Control = null

func _ready():
	"""Inicializa servidor ou cliente baseando-se no argumento de inicialização
	Se for servidor, pode inicializar com headless ativado ou desativado conforme comando"""
	
	var args := OS.get_cmdline_args()
	var is_server := "--server" in args
	var is_headless = DisplayServer.get_name() == "headless"

	if is_server:
		_init_server(is_headless)
	else:
		_init_client()
		
func _init_server(is_headless):
	# Instancia managers e registros
	var network_manager_scene: PackedScene = load("res://scenes/system/network_manager.tscn")
	var server_manager_scene: PackedScene = load("res://scenes/system/server_manager.tscn")
	player_registry = load("res://scripts/only_server/registrars/PlayerRegistry.gd").new()
	room_registry = load("res://scripts/only_server/registrars/RoomRegistry.gd").new()
	round_registry = load("res://scripts/only_server/registrars/RoundRegistry.gd").new()
	map_manager = load("res://scripts/gameplay/MapManager.gd").new()
	item_database = load("res://scripts/gameplay/ItemDatabase.gd").new()
	object_manager = load("res://scripts/only_server/ObjectManager.gd").new()
	test_manager = load("res://scripts/only_server/TestManager.gd").new()
	
	network_manager = network_manager_scene.instantiate()
	server_manager = server_manager_scene.instantiate()

	# Nomeia para facilitar visualização
	network_manager.name = "NetworkManager"
	server_manager.name = "ServerManager"
	player_registry.name = "PlayerRegistry"
	room_registry.name = "RoomRegistry"
	round_registry.name = "RoundRegistry"
	map_manager.name = "MapManager"
	item_database.name = "ItemDatabase"
	object_manager.name = "ObjectManager"
	test_manager.name = "TestManager"

	# Adiciona à árvore
	get_tree().root.add_child.call_deferred(network_manager)
	get_tree().root.add_child.call_deferred(server_manager)
	get_tree().root.add_child.call_deferred(player_registry)
	get_tree().root.add_child.call_deferred(room_registry)
	get_tree().root.add_child.call_deferred(round_registry)
	get_tree().root.add_child.call_deferred(map_manager)
	get_tree().root.add_child.call_deferred(item_database)
	get_tree().root.add_child.call_deferred(object_manager)
	get_tree().root.add_child.call_deferred(test_manager)
	
	# Injeta dependências cruzadas:
	
	# ServerManager precisa de:
	server_manager.network_manager = network_manager
	server_manager.player_registry = player_registry
	server_manager.room_registry = room_registry
	server_manager.round_registry = round_registry
	server_manager.item_database = item_database
	server_manager.object_manager = object_manager
	server_manager.test_manager = test_manager
	server_manager.map_manager = map_manager
	
	# Networkmanager precisa de:
	network_manager.server_manager = server_manager
	network_manager.player_registry = player_registry
	network_manager.room_registry = room_registry
	network_manager.round_registry = round_registry
	network_manager.object_manager = object_manager
	
	# PlayerRegistry precisa de:
	player_registry.network_manager = network_manager
	player_registry.room_registry = room_registry
	player_registry.round_registry = round_registry
	player_registry.object_manager = object_manager
	player_registry.item_database = item_database
	
	# RoomRegistry precisa de:
	room_registry.player_registry = player_registry
	room_registry.round_registry = round_registry
	room_registry.object_manager = object_manager
	
	# RoundRegistry precisa de:
	round_registry.player_registry = player_registry
	round_registry.room_registry = room_registry
	round_registry.object_manager = object_manager
	
	# ObjectManager precisa de:
	object_manager.server_manager = server_manager
	object_manager.network_manager = network_manager
	object_manager.player_registry = player_registry
	object_manager.round_registry = round_registry
	object_manager.item_database = item_database
	
	# TestManager precisa de:
	test_manager.server_manager = server_manager
	test_manager.network_manager = network_manager
	test_manager.item_database = item_database
	test_manager.player_registry = player_registry
	test_manager.room_registry = room_registry
	test_manager.round_registry = round_registry
	test_manager.object_manager = object_manager
	test_manager.map_manager = map_manager
	
	# configurações
	network_manager._is_server = true
	network_manager.server_is_headless = is_headless
	
	# Aguarda até que os nós tenham sido adicionados à árvore
	await get_tree().process_frame
	
	# Inicializa tudo
	server_manager.initialize()
	network_manager.initialize()
	player_registry.initialize()
	room_registry.initialize()
	round_registry.initialize()
	test_manager.initialize()
	item_database.load_database()
	object_manager.initialize()

func _init_client():
	# Instancia managers e registros
	var network_manager_scene: PackedScene = load("res://scenes/system/network_manager.tscn")
	var game_manager_scene: PackedScene = load("res://scenes/system/game_manager.tscn")
	var main_menu_scene: PackedScene = load("res://scenes/ui/main_menu.tscn")
	item_database = load("res://scripts/gameplay/ItemDatabase.gd").new()

	network_manager = network_manager_scene.instantiate()
	game_manager = game_manager_scene.instantiate()
	main_menu = main_menu_scene.instantiate()

	# Nomeia para facilitar visualização
	network_manager.name = "NetworkManager"
	game_manager.name = "GameManager"
	item_database.name = "ItemDatabase"
	main_menu.name = "MainMenu"
	
	# Adiciona à árvore
	get_tree().root.add_child.call_deferred(network_manager)
	get_tree().root.add_child.call_deferred(game_manager)
	get_tree().root.add_child.call_deferred(item_database)
	get_tree().root.add_child.call_deferred(main_menu)
	
	# Injeta dependências cruzadas:
	
	# NetworkManager precisa de:
	network_manager.game_manager = game_manager
	network_manager.item_database = item_database
	
	# GameManager precisa de:
	game_manager.item_database = item_database
	game_manager.network_manager = network_manager
	
	# MainMenu precisa de:
	main_menu.game_manager = game_manager
	
	# Configurações
	
	# Aguarda até que os nós tenham sido adicionados à árvore
	await get_tree().process_frame
	
	# Inicializa tudo
	network_manager.initialize()
	game_manager.initialize()
	item_database.load_database()
	
