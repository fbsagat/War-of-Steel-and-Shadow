extends Node

var item_scenes: Dictionary = {}
var debug_mode : bool = true

func _ready():
	var args = OS.get_cmdline_args()
	var is_server = "--server" in args or "--dedicated" in args
	
	if is_server:
		_log_debug("Sou o servidor - NÃO inicializando ItemPreloader")
		return
		
	load_all_items()

func load_all_items():
	# Carrega todas as cenas de itens na inicialização
	var item_paths = {
		"cape_1": "res://scenes/collectibles/cape_1.tscn",
		"cape_2": "res://scenes/collectibles/cape_2.tscn",
		"iron_helmet": "res://scenes/collectibles/iron_helmet.tscn",
		"shield_1":"res://scenes/collectibles/shield_1.tscn",
		"shield_2":"res://scenes/collectibles/shield_2.tscn",
		"shield_3":"res://scenes/collectibles/shield_3.tscn",
		"steel_helmet":"res://scenes/collectibles/steel_helmet.tscn",
		"sword_1":"res://scenes/collectibles/sword_1.tscn",
		"sword_2":"res://scenes/collectibles/sword_2.tscn",
		"torch":"res://scenes/collectibles/torch.tscn"
	}
	
	for item_name in item_paths:
		var path = item_paths[item_name]
		var scene = load(path)
		if scene:
			item_scenes[item_name] = scene
		else:
			push_error("Falha ao carregar item: %s" % path)
	
	print("✓ %d itens carregados na memória" % item_paths.size())

func get_item_scene(item_name: String) -> PackedScene:
	return item_scenes.get(item_name, null)

func _log_debug(message: String):
	"""Imprime mensagem de debug se habilitado"""
	if debug_mode:
		print("[GameManager]: " + message)
