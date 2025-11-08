extends Node
## ServerManager - Gerenciador do servidor dedicado
## Este script só é executado quando o jogo está rodando como servidor
## Todos os RPCs estão em NetworkManager

# ===== CONFIGURAÇÕES (Editáveis no Inspector) =====

## Porta do servidor
@export var server_port: int = 7777

## Número máximo de clientes conectados
@export var max_clients: int = 32

## Ativar logs de debug detalhados
@export var debug_mode: bool = true

# ===== VARIÁVEIS INTERNAS =====

## Flag que indica se este processo é um servidor dedicado
var is_dedicated_server: bool = false

## Próximo ID de sala a ser criado
var next_room_id: int = 1

# ===== FUNÇÕES DE INICIALIZAÇÃO =====

func _ready():
	# Detecta se está rodando como servidor dedicado
	_detect_server_mode()
	
	if is_dedicated_server:
		_start_server()
	else:
		_log_debug("Modo cliente - ServerManager inativo")

## Detecta se deve rodar como servidor dedicado
func _detect_server_mode():
	# Verifica argumentos de linha de comando
	var args = OS.get_cmdline_args()
	is_dedicated_server = "--server" in args or "--dedicated" in args
	
	# Ou verifica variável de ambiente
	if not is_dedicated_server:
		is_dedicated_server = OS.has_environment("DEDICATED_SERVER")
	
	_log_debug("Modo servidor dedicado: " + str(is_dedicated_server))

## Inicia o servidor dedicado
func _start_server():
	_log_debug("========================================")
	_log_debug("INICIANDO SERVIDOR DEDICADO")
	_log_debug("Porta: %d" % server_port)
	_log_debug("Máximo de clientes: %d" % max_clients)
	_log_debug("========================================")
	
	# Cria peer para servidor
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(server_port, max_clients)
	
	if error != OK:
		_log_debug("✗ ERRO ao criar servidor: " + str(error))
		return
	
	multiplayer.multiplayer_peer = peer
	
	# Configura callbacks de rede
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	_log_debug("✓ Servidor iniciado com sucesso!")

# ===== CALLBACKS DE CONEXÃO =====

func _on_peer_connected(peer_id: int):
	_log_debug("✓ Cliente conectado: Peer ID %d" % peer_id)
	
	# Registra o novo peer no PlayerRegistry
	PlayerRegistry.add_peer(peer_id)

func _on_peer_disconnected(peer_id: int):
	_log_debug("✗ Cliente desconectado: Peer ID %d" % peer_id)
	
	# Remove o peer do PlayerRegistry
	var player_data = PlayerRegistry.get_player(peer_id)
	if player_data and player_data.has("name"):
		_log_debug("  Jogador: %s" % player_data["name"])
		
		# Remove o jogador de qualquer sala
		var room = RoomRegistry.get_room_by_player(peer_id)
		if room:
			RoomRegistry.remove_player_from_room(room["id"], peer_id)
			_log_debug("  Removido da sala: %s" % room["name"])
			
			# Notifica outros jogadores da sala
			_notify_room_update(room["id"])
	
	PlayerRegistry.remove_peer(peer_id)

# ===== HANDLERS (Chamados pelo NetworkManager) =====

## Registra um novo jogador
func _handle_register_player(peer_id: int, player_name: String):
	_log_debug("Tentativa de registro: '%s' (Peer ID: %d)" % [player_name, peer_id])
	
	# Valida o nome
	var validation_result = _validate_player_name(player_name)
	if validation_result != "":
		_log_debug("✗ Nome rejeitado: " + validation_result)
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", validation_result)
		return
	
	# Registra o jogador
	var success = PlayerRegistry.register_player(peer_id, player_name)
	
	if success:
		_log_debug("✓ Jogador registrado: %s (Peer ID: %d)" % [player_name, peer_id])
		NetworkManager.rpc_id(peer_id, "_client_name_accepted", player_name)
	else:
		_log_debug("✗ Falha ao registrar jogador")
		NetworkManager.rpc_id(peer_id, "_client_name_rejected", "Erro ao registrar no servidor")

## Valida o nome do jogador
func _validate_player_name(player_name: String) -> String:
	# Remove espaços extras
	var trimmed_name = player_name.strip_edges()
	
	# Verifica se está vazio
	if trimmed_name.is_empty():
		return "O nome não pode estar vazio"
	
	# Verifica tamanho mínimo
	if trimmed_name.length() < 3:
		return "O nome deve ter pelo menos 3 caracteres"
	
	# Verifica tamanho máximo
	if trimmed_name.length() > 20:
		return "O nome deve ter no máximo 20 caracteres"
	
	# Verifica caracteres permitidos (apenas letras, números, espaços e underscores)
	var regex = RegEx.new()
	regex.compile("^[a-zA-Z0-9_ ]+$")
	if not regex.search(trimmed_name):
		return "O nome só pode conter letras, números, espaços e underscores"
	
	# Verifica se o nome já está em uso
	if PlayerRegistry.is_name_taken(trimmed_name):
		return "Este nome já está sendo usado"
	
	return ""  # Nome válido

## Solicita lista de salas
func _handle_request_rooms_list(peer_id: int):
	_log_debug("Cliente %d solicitou lista de salas" % peer_id)
	
	# Verifica se o jogador está registrado
	if not PlayerRegistry.is_player_registered(peer_id):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	var rooms = RoomRegistry.get_rooms_list()
	_log_debug("Enviando %d salas para o cliente" % rooms.size())
	
	# Envia a lista de salas de volta para o cliente
	NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list", rooms)

## Cria uma nova sala
func _handle_create_room(peer_id: int, room_name: String, password: String):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Criando sala '%s' para jogador %s (ID: %d)" % [room_name, player["name"], peer_id])
	
	# Valida o nome da sala
	var validation = _validate_room_name(room_name)
	if validation != "":
		_send_error(peer_id, validation)
		return
	
	# Verifica se já existe uma sala com este nome
	if RoomRegistry.room_name_exists(room_name):
		_send_error(peer_id, "Já existe uma sala com este nome")
		return
	
	# Verifica se o jogador já está em outra sala
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala")
		return
	
	# Cria a sala
	var room_id = next_room_id
	next_room_id += 1
	
	var room_data = RoomRegistry.create_room(room_id, room_name, password, peer_id)
	
	_log_debug("✓ Sala criada: %s (ID: %d, Host: %s)" % [room_name, room_id, player["name"]])
	_send_rooms_list_to_all()
	
	# Notifica o cliente que criou a sala
	NetworkManager.rpc_id(peer_id, "_client_room_created", room_data)

func _send_rooms_list_to_all():
	var all_rooms = RoomRegistry.get_rooms_list()  # deve retornar um Array
	for peer_id in multiplayer.get_peers():
		# Ignora o próprio servidor (peer_id 1)
		if peer_id != 1:
			# FUTURAMENTE VERIFICAR DE O PLAYER ESTÁ FORA DE UMA SALA E
			# FILTRAR ELE(MANTER ELE E TIRAR OS OUTROS) PARA NÃO ATUALIZAR OS QUE ESTÃO EM PARTIDAS
			NetworkManager.rpc_id(peer_id, "_client_receive_rooms_list_update", all_rooms)

## Valida o nome da sala
func _validate_room_name(room_name: String) -> String:
	var trimmed = room_name.strip_edges()
	
	if trimmed.is_empty():
		return "O nome da sala não pode estar vazio"
	
	if trimmed.length() < 3:
		return "O nome da sala deve ter pelo menos 3 caracteres"
	
	if trimmed.length() > 30:
		return "O nome da sala deve ter no máximo 30 caracteres"
	
	return ""

## Entra em uma sala por ID
func _handle_join_room(peer_id: int, room_id: int, password: String):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala ID: %d" % [player["name"], peer_id, room_id])
	
	# Verifica se o jogador já está em outra sala
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	var room = RoomRegistry.get_room(room_id)
	if room.is_empty():
		_send_error(peer_id, "Sala não encontrada")
		return
	
	# Verifica senha
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	# Adiciona jogador à sala
	var success = RoomRegistry.add_player_to_room(room_id, peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	# Notifica o cliente
	var room_data = RoomRegistry.get_room(room_id)
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	# Notifica outros jogadores na sala sobre o novo membro
	_notify_room_update(room_id)

## Entra em uma sala por nome
func _handle_join_room_by_name(peer_id: int, room_name: String, password: String):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	_log_debug("Jogador %s (ID: %d) tentando entrar na sala: '%s'" % [player["name"], peer_id, room_name])
	
	# Verifica se o jogador já está em outra sala
	var current_room = RoomRegistry.get_room_by_player(peer_id)
	if not current_room.is_empty():
		_send_error(peer_id, "Você já está em uma sala. Saia primeiro.")
		return
	
	var room = RoomRegistry.get_room_by_name(room_name)
	if room.is_empty():
		NetworkManager.rpc_id(peer_id, "_client_room_not_found")
		return
	
	# Verifica senha
	if room["has_password"] and room["password"] != password:
		NetworkManager.rpc_id(peer_id, "_client_wrong_password")
		return
	
	# Adiciona jogador à sala
	var success = RoomRegistry.add_player_to_room(room["id"], peer_id)
	if not success:
		_send_error(peer_id, "Não foi possível entrar na sala (pode estar cheia)")
		return
	
	_log_debug("✓ Jogador %s entrou na sala: %s" % [player["name"], room["name"]])
	
	# Notifica o cliente
	var room_data = RoomRegistry.get_room(room["id"])
	NetworkManager.rpc_id(peer_id, "_client_joined_room", room_data)
	
	# Notifica outros jogadores na sala sobre o novo membro
	_notify_room_update(room["id"])

## Sai de uma sala
func _handle_leave_room(peer_id: int):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		return
	
	_log_debug("Jogador %s saiu da sala: %s" % [player["name"], room["name"]])
	RoomRegistry.remove_player_from_room(room["id"], peer_id)
	
	# Notifica outros jogadores da sala
	_notify_room_update(room["id"])

## Fecha a sala (apenas host)
func _handle_close_room(peer_id: int):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		return
	
	# Verifica se é o host
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode fechar a sala")
		return
	
	_log_debug("Host %s fechou a sala: %s" % [player["name"], room["name"]])
	
	# Notifica todos os jogadores da sala
	for room_player in room["players"]:
		if room_player["id"] != peer_id:
			NetworkManager.rpc_id(room_player["id"], "_client_room_closed", "O host fechou a sala")
	
	# Remove a sala
	RoomRegistry.remove_room(room["id"])
	_send_rooms_list_to_all()

## Inicia a partida (apenas host)
func _handle_start_match(peer_id: int, match_settings: Dictionary):
	var player = PlayerRegistry.get_player(peer_id)
	
	if not player or not player.has("name"):
		_send_error(peer_id, "Jogador não registrado")
		return
	
	var room = RoomRegistry.get_room_by_player(peer_id)
	if room.is_empty():
		_send_error(peer_id, "Você não está em nenhuma sala")
		return
	
	# Verifica se é o host
	if room["host_id"] != peer_id:
		_send_error(peer_id, "Apenas o host pode iniciar a partida")
		return
	
	# Verifica requisitos mínimos
	if not RoomRegistry.can_start_match(room["id"]):
		var reqs = RoomRegistry.get_match_requirements(room["id"])
		_send_error(peer_id, "Requisitos não atendidos: %d/%d jogadores (mínimo: %d)" % [
			reqs["current_players"],
			reqs["max_players"],
			reqs["min_players"]
		])
		return
	
	_log_debug("========================================")
	_log_debug("HOST INICIANDO PARTIDA")
	_log_debug("Sala: %s (ID: %d)" % [room["name"], room["id"]])
	_log_debug("Jogadores participantes:")
	
	for room_player in room["players"]:
		var is_host_mark = " [HOST]" if room_player["is_host"] else ""
		_log_debug("  - %s (ID: %d)%s" % [room_player["name"], room_player["id"], is_host_mark])
	
	_log_debug("Configurações: %s" % str(match_settings))
	_log_debug("========================================")
	
	# Notifica todos os jogadores que a partida vai iniciar
	var match_data = {
		"room": room,
		"settings": match_settings
	}
	
	for room_player in room["players"]:
		NetworkManager.rpc_id(room_player["id"], "_client_match_started", match_data)

## Notifica todos os jogadores de uma sala sobre atualização
func _notify_room_update(room_id: int):
	var room = RoomRegistry.get_room(room_id)
	if room.is_empty():
		return
	
	_log_debug("Notificando atualização da sala: %s" % room["name"])
	
	for player in room["players"]:
		NetworkManager.rpc_id(player["id"], "_client_room_updated", room)

# ===== UTILITÁRIOS =====

## Envia mensagem de erro para um cliente
func _send_error(peer_id: int, message: String):
	_log_debug("Enviando erro para cliente %d: %s" % [peer_id, message])
	NetworkManager.rpc_id(peer_id, "_client_error", message)

## Registra mensagens de debug (apenas se debug_mode estiver ativo)
func _log_debug(message: String):
	if debug_mode:
		print("[ServerManager] " + message)
