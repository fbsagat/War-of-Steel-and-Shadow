extends Node
class_name TestManager

## TestManager - Ferramenta de desenvolvimento para testes automatizados
## 
## RESPONSABILIDADES:
## - Criar partidas de teste automaticamente
## - Registrar jogadores fictícios
## - Iniciar rodadas sem interação manual
## - Facilitar testes de funcionalidades
##
## ⚠️ IMPORTANTE: Deve ser DESATIVADO em produção!


# ===== CONFIGURAÇÕES =====

@export_category("Debug")
@export var debug_mode: bool = true


# ===== REGISTROS (Injetados pelo initializer.gd) =====

var server_manager: ServerManager = null
var network_manager: NetworkManager = null
var item_database :ItemDatabase = null
var map_manager: MapManager = null
var client_registry: ClientRegistry = null
var room_registry: RoomRegistry = null
var round_registry: RoundRegistry = null
var object_manager: ObjectManager = null
var initializer: Initializer_ = null


# ===== VARIÁVEIS INTERNAS =====

## Referência à câmera livre para visualização no servidor
var free_camera: Camera3D = null

# Estado de inicialização
var _initialized: bool = false

var actual_camera: Camera3D = null
var dummy_camera: Camera3D


# ===== INICIALIZAÇÃO =====

## Inicializa o TestManager (chamado pelo ServerManager).
func initialize():
	if _initialized:
		_log_debug("⚠ TestManager já inicializado")
		return
	
	_initialized = true
	_log_debug("▶️ TestManager inicializado com sucesso!")


# ===== CRIAÇÃO DE PARTIDA DE TESTE =====
	
## Cria uma partida de teste usando os peers conectados reais.
func create_test_round(nome_sala_: String = "Sala de Teste"):
	if not _initialized:
		_log_debug("❌ TestManager não inicializado!")
		return
	
	# Valida registries
	if not client_registry or not room_registry or not round_registry:
		_log_debug("❌ Registries não disponíveis!")
		return
	
	# Obtém peers conectados (exclui servidor - ID 1)
	var all_peers = multiplayer.get_peers()
	var connected_peers = multiplayer.get_peers()
	connected_peers.remove_at(0)  # Remove servidor

	if all_peers.is_empty():
		_log_debug("⚠ Nenhum cliente conectado para criar partida de teste")
		return
	
	print("")
	_log_debug("========================================")
	_log_debug("🎮 CRIANDO PARTIDA DE TESTE")
	_log_debug("Sala: '%s'" % nome_sala_)
	_log_debug("Jogadores: %d" % server_manager.simulador_players_qtd)
	_log_debug("========================================")
	print("")
	await get_tree().process_frame
	
	# Registra jogadores no ClientRegistry
	var host_peer_id: int = all_peers[0]
	var host_uuid = client_registry.get_uuid_by_peer_id(host_peer_id)

	var players: Array = []
	for i in range(server_manager.simulador_players_qtd):
		var peer_id = all_peers[i]
		var _uuid_base = client_registry.get_uuid_by_peer_id(peer_id)
		
		# Verifica se peer já está registrado
		var player_data = client_registry.get_player(_uuid_base)
			
		# Registra com nome padrão
		var player_name = "TestPlayer%d" % [i + 1]
		client_registry.register_player_name(_uuid_base, player_name)
		
		# Atualiza o cliente
		_log_debug("_client_name_accepted", true)
		network_manager.rpc_id(peer_id, "_client_name_accepted", player_name)
		
		player_data = client_registry.get_player(_uuid_base)
		
		# Adiciona à lista de jogadores
		players.append({
			"peer_id": peer_id,
			"uuid_base": _uuid_base,
			"name": player_data["name"],
			"is_host": (i == 0)  # Primeiro é o host
		})
		
		_log_debug("  ✓ Jogador registrado: %s (ID: %d)" % [player_data["name"], peer_id])

	if players.is_empty():
		_log_debug("❌ Nenhum jogador válido para criar partida")
		return
	
	await get_tree().process_frame
	
	# Remove jogadores de qualquer round ou partida que possam estar
	#for i in range(server_manager.simulador_players_qtd - 1):
		#client_registry.
	
	# Cria sala no RoomRegistry
	server_manager._handle_create_room(host_peer_id, "Sala de testes", "")
	
	var host = client_registry.get_player_by_uuid(host_uuid)
	var room_data = room_registry.get_room(host["room_id"])
	
	# For para entrarem na sala
	for i in range(server_manager.simulador_players_qtd - 1):
		var peer_id = connected_peers[i]
		var _uuid_base = client_registry.get_uuid_by_peer_id(peer_id)
		server_manager._handle_join_room(peer_id, host["room_id"], "")
	
	# Valida requisitos para iniciar (teste de função)
	var response = room_registry.can_start_match(room_data["id"], host_uuid)
	if not response[0]:
		_log_debug(response[1])
		return
	
	await get_tree().create_timer(0.2).timeout
	
	# Cria rodada no RoundRegistry
	_log_debug("  ✓ Iniciando rodada de teste...")
	
	server_manager._handle_start_round(players[0]["peer_id"], {}, true)
	
	
# ===== UTILITÁRIOS =====

## Função padrão de debug.
func _log_debug(message: String, rpc_debug: bool = false):
	if not debug_mode:
		return
	
	# Configurações do initializer
	if initializer.activate_only_selected and not "TestManager" in initializer.selected:
		return
	if rpc_debug and not initializer.rpc_debug:
		return
	print("[SERVER][TestManager] %s%s" % ["[RPC]" if rpc_debug else "", message])
