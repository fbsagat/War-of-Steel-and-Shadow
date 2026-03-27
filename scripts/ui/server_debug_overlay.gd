## debug_overlay.gd
##
## Painel de debug overlay para servidor Godot 4.6 (não-headless).
## Exibe informações de Clientes, Salas e Partidas em três abas separadas.
##
## ═══════════════════════════════════════════════════════════════════════
## COMO USAR NO CÓDIGO DO SERVIDOR
## ═══════════════════════════════════════════════════════════════════════
##
##  @onready var debug_overlay: DebugOverlay = $DebugOverlay
##
##  func _ready() -> void:
##      # 1) Passe as referências aos três managers:
##      debug_overlay.setup(client_manager, room_manager, match_manager)
##
##      # 3) Preencha as funções _rebuild_*() e _update_*_realtime()
##      #    com os dados dos seus managers (veja os blocos comentados abaixo).
##
## ═══════════════════════════════════════════════════════════════════════
## TECLAS
## ═══════════════════════════════════════════════════════════════════════
##  F1 — Abre / fecha aba Clientes
##  F2 — Abre / fecha aba Salas
##  F3 — Abre / fecha aba Partidas
##  (Pressionar a tecla da aba aberta fecha o painel)
##
## ═══════════════════════════════════════════════════════════════════════
## ARQUITETURA DE ATUALIZAÇÃO
## ═══════════════════════════════════════════════════════════════════════
##  • Rebuild estrutural  — reconstrói todas as linhas do zero.
##                          Acionado por notify_structure_changed() e
##                          throttled por REBUILD_INTERVAL (padrão 0.5 s).
##                          Use para: itens adicionados / removidos.
##
##  • Update em tempo real — roda TODO frame, mas só altera o .text de
##                           Labels já existentes (sem criar nós novos).
##                           Use para: ping, tempo de partida, contadores.

class_name DebugOverlay
extends Node


# ─────────────────────────────────────────────────────────────────────────────
# ENUMS E CONSTANTES
# ─────────────────────────────────────────────────────────────────────────────

## Índice de cada aba (corresponde a posições nos arrays internos)
enum Tab { NONE = -1, CLIENTS = 0, ROOMS = 1, MATCHES = 2 }

## Rótulos exibidos no título do painel para cada aba
const TAB_LABELS: Array[String] = [
	"[F1]  Clientes",
	"[F2]  Salas",
	"[F3]  Partidas",
]

## Largura mínima padrão de colunas de texto (px)
const COL_MIN_WIDTH: int = 50

## Largura mínima padrão de colunas de botão (px)
const BTN_MIN_WIDTH: int = 75

## Intervalo mínimo entre rebuilds estruturais (segundos).
## Evita reconstruir a lista múltiplas vezes quando vários sinais chegam juntos.
const REBUILD_INTERVAL: float = 0.5

## Tamanho padrão do painel (px)
const PANEL_SIZE: Vector2 = Vector2(1020.0, 680.0)


# ─────────────────────────────────────────────────────────────────────────────
# REFERÊNCIAS EXTERNAS
# ─────────────────────────────────────────────────────────────────────────────

## Referência ao ClientManager — configure via setup()
var client_registry: ClientRegistry = null

## Referência ao RoomManager — configure via setup()
var room_registry: RoomRegistry = null

## Referência ao MatchManager — configure via setup()
var round_registry: RoundRegistry = null

## Referência ao ServerManager - Injetado via initializer
var server_manager: ServerManager = null

## Referência ao NetworkManager - Injetado via initializer
var network_manager: NetworkManager = null

# ─────────────────────────────────────────────────────────────────────────────
# ESTADO INTERNO
# ─────────────────────────────────────────────────────────────────────────────

## Aba atualmente visível
var _active_tab: Tab = Tab.NONE

## Se o painel está visível no momento
var _visible: bool = false

## Indica que a estrutura da lista mudou e um rebuild é necessário
var _needs_rebuild: bool = false

## Acumulador do timer de throttle de rebuild
var _rebuild_timer: float = 0.0


# ─────────────────────────────────────────────────────────────────────────────
# NÓS DE UI  (todos criados programaticamente em _build_ui)
# ─────────────────────────────────────────────────────────────────────────────

## CanvasLayer raiz — layer alto garante render por cima de toda a cena
var _canvas: CanvasLayer

## Container principal do painel
var _panel: PanelContainer

## Label que exibe o nome da aba ativa
var _tab_title: Label

## Um ScrollContainer por aba (index == Tab enum value)
var _tab_panels: Array[ScrollContainer] = []

## VBoxContainer interno de cada ScrollContainer (onde linhas são inseridas)
var _list_containers: Array[VBoxContainer] = []


# ─────────────────────────────────────────────────────────────────────────────
# CACHE DE LABELS PARA ATUALIZAÇÃO EM TEMPO REAL
# ─────────────────────────────────────────────────────────────────────────────
## Estrutura:  _xxx_rows[id] = { "chave": Label, ... }
## O rebuild preenche esses dicts; o update em tempo real lê deles.
## Chave = string passada no parâmetro "key" de _col().

## Linhas da aba Clientes:  peer_id (int)  →  { chave: Label }
var _client_rows: Dictionary = {}

## Linhas da aba Salas:     room_id        →  { chave: Label }
var _room_rows: Dictionary = {}

## Linhas da aba Partidas:  match_id       →  { chave: Label }
var _match_rows: Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
# CICLO DE VIDA
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_build_ui()
	set_process(false)  # _process só roda quando o painel está aberto
	
func _connect_signals():
	client_registry.peer_connected.connect(notify_structure_changed)
	client_registry.peer_disconnected.connect(notify_structure_changed)
	client_registry.player_joined_room.connect(notify_structure_changed)
	client_registry.player_left_room.connect(notify_structure_changed)
	client_registry.peer_state_changed.connect(notify_structure_changed)
	
	room_registry.room_created.connect(notify_structure_changed)
	room_registry.room_removed.connect(notify_structure_changed)
	room_registry.player_joined_room.connect(notify_structure_changed)
	room_registry.player_left_room.connect(notify_structure_changed)
	room_registry.host_changed.connect(notify_structure_changed)
	room_registry.room_state_changed.connect(notify_structure_changed)
	
	round_registry.round_started.connect(notify_structure_changed)
	round_registry.player_connected.connect(notify_structure_changed)
	round_registry.player_disconnected.connect(notify_structure_changed)
	
func _exit_tree() -> void:
	# Solta referências para não segurar objetos na memória após remoção
	client_registry = null
	room_registry   = null
	round_registry  = null


# ─────────────────────────────────────────────────────────────────────────────
# API PÚBLICA
# ─────────────────────────────────────────────────────────────────────────────

## Configura as referências aos três managers.
## Deve ser chamado no _ready() do servidor, antes que qualquer aba seja aberta.
##
## [param p_client_manager]  Referência ao ClientManager
## [param p_room_manager]    Referência ao RoomManager
## [param p_match_manager]   Referência ao MatchManager
func setup(
		p_client_manager: Node,
		p_room_manager:   Node,
		p_match_manager:  Node,
) -> void:
	client_registry = p_client_manager
	room_registry   = p_room_manager
	round_registry  = p_match_manager


## Sinaliza que a estrutura de dados mudou e a lista precisa ser reconstruída.
## Conecte este método aos sinais dos managers (ex: client_connected, room_created).
## O rebuild é throttled — não ocorre mais de uma vez por REBUILD_INTERVAL.
func notify_structure_changed(_1 = null, _2 = null, _3 = null, _4 = null, _5 = null, _6 = null,
 _7 = null, _8 = null, _9 = null, _0 = null, _a = null, _b = null, _c = null) -> void:
	_needs_rebuild = true


# ─────────────────────────────────────────────────────────────────────────────
# INPUT
# ─────────────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F1: _toggle_tab(Tab.CLIENTS)
		KEY_F2: _toggle_tab(Tab.ROOMS)
		KEY_F3: _toggle_tab(Tab.MATCHES)


## Alterna a aba. Se a aba solicitada já estiver aberta, fecha o painel.
##
## [param tab]  Aba a ser aberta ou fechada
func _toggle_tab(tab: Tab) -> void:
	if _active_tab == tab:
		_close()
	else:
		_open(tab)


# ─────────────────────────────────────────────────────────────────────────────
# CONTROLE DE VISIBILIDADE
# ─────────────────────────────────────────────────────────────────────────────

## Abre o painel exibindo a aba especificada.
##
## [param tab]  Aba a exibir
func _open(tab: Tab) -> void:
	if _active_tab == -1:
		server_manager._toggle_mouse_mode(true, false)
	_active_tab     = tab
	_visible        = true
	_panel.visible  = true
	_tab_title.text = TAB_LABELS[tab]

	# Mostra apenas o painel da aba ativa
	for i: int in _tab_panels.size():
		_tab_panels[i].visible = (i == tab as int)

	# Força rebuild imediato ao abrir (seta timer no limite para não esperar)
	_needs_rebuild = true
	_rebuild_timer = REBUILD_INTERVAL

	set_process(true)


## Fecha o painel e para o loop de processamento.
func _close() -> void:
	server_manager._toggle_mouse_mode(false, true)
	_active_tab    = Tab.NONE
	_visible       = false
	_panel.visible = false
	set_process(false)


# ─────────────────────────────────────────────────────────────────────────────
# LOOP PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# ── Rebuild estrutural (throttled) ────────────────────────────────────
	# Só reconstrói quando necessário e após o intervalo mínimo
	if _needs_rebuild:
		_rebuild_timer += delta
		if _rebuild_timer >= REBUILD_INTERVAL:
			_rebuild_timer = 0.0
			_needs_rebuild = false
			_do_rebuild()

	# ── Atualização em tempo real (toda frame) ────────────────────────────
	# Apenas escreve em Labels já existentes — sem criar nós novos
	_update_realtime()


## Limpa e reconstrói a lista da aba ativa.
## Usa await de um frame para garantir que queue_free() finalize antes de
## adicionar novos filhos (evita conflito de filhos duplicados).
func _do_rebuild() -> void:
	var list: VBoxContainer = _list_containers[_active_tab]

	for child: Node in list.get_children():
		child.queue_free()

	# Aguarda um frame para que queue_free() processe antes de adicionar filhos
	await get_tree().process_frame

	match _active_tab:
		Tab.CLIENTS: _rebuild_clients(list)
		Tab.ROOMS:   _rebuild_rooms(list)
		Tab.MATCHES: _rebuild_matches(list)


## Despacha a atualização em tempo real para a aba ativa.
func _update_realtime() -> void:
	match _active_tab:
		Tab.CLIENTS: _update_clients_realtime()
		Tab.ROOMS:   _update_rooms_realtime()
		Tab.MATCHES: _update_matches_realtime()


# ─────────────────────────────────────────────────────────────────────────────
# ═══════════════ DADOS DAS ABAS — EDITE AQUI ════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────
#
#  Cada aba tem duas funções:
#    _rebuild_*()         → constrói as linhas do zero (acionado por mudança
#                           estrutural, throttled por REBUILD_INTERVAL)
#    _update_*_realtime() → atualiza labels de dados dinâmicos toda frame
#
#  Use os helpers _col() e _col_btn() para descrever colunas,
#  e _add_row() para inserir a linha no container.
#  O retorno de _add_row() é um dict { "chave": Label } que você guarda
#  em _client_rows / _room_rows / _match_rows para uso no update em tempo real.
#
# ─────────────────────────────────────────────────────────────────────────────

# ── ABA: CLIENTES ─────────────────────────────────────────────────────────────

## Reconstrói a lista de clientes.
## Chamado quando a estrutura muda (cliente conectou/desconectou etc.).
##
## Exemplo completo (adapte para a API do seu ClientManager):
##
##   func _rebuild_clients(list: VBoxContainer) -> void:
##       _client_rows.clear()
##       _add_header(list, ["Peer ID", "Nome", "Ping", "Estado", "Sala", "Ações"])
##       if client_manager == null:
##           _add_placeholder(list, "ClientManager não configurado.")
##           return
##       for peer_id: int in client_manager.get_all_peer_ids():
##           var c = client_manager.get_client(peer_id)
##           var refs: Dictionary = _add_row(list, [
##               _col(str(peer_id),   "id",    80),
##               _col(c.username,     "name",  150),
##               _col("...",          "ping",  70),   # atualizado em tempo real
##               _col(c.state,        "state", 100),
##               _col(str(c.room_id), "room",  80),
##               _col_btn("Kick",  func(): client_manager.kick(peer_id)),
##               _col_btn("Info",  func(): print(client_manager.get_client(peer_id))),
##           ])
##           _client_rows[peer_id] = _refs
func _rebuild_clients(list: VBoxContainer) -> void:
	_client_rows.clear()
	var col_names: Array[String] = ["Pos.", "Conect.", "Estado", "Nome", "UUID", "Sala", "Round", "Ping", "", ""]
	var column_sizes: Array[int] = [60, 60, 80, 100, 120, 50, 50, 80, 75, 75]
	_add_header(list, col_names, column_sizes)

	if client_registry == null:
		_add_placeholder(list, "ClientManager não configurado — chame setup() primeiro.")
		return

	for client_uuid in client_registry.get_all_players_uuid():
		var c = client_registry.get_player(client_uuid)
		var state_name = client_registry.get_player_state_name(client_uuid)
		var short_uuid = client_registry.get_short_uuid(client_uuid)
		var _refs: Dictionary = _add_row(list, [
			_col(str(c["entry_position"]),                   "", 60),
			_col(str("🟢" if c["connected"] else "🔴"),     "", 60),
			_col(state_name,                                 "state",  80),
			_col(c["name"],                                  "", 100),
			_col(short_uuid,                                 "", 120),
			_col(str(c["room_id"]),                          "", 50),
			_col(str(c["round_id"]),                         "", 50),
			_col("...",                                      "ping",  80),
			
			_col_btn("Kick",  func(): server_manager._kick_player(c["peer_id"], "O servidor quis"), 75),
			_col_btn("Print",  func(): print(c), 75)
		])
		_client_rows[client_uuid] = _refs
	
	#_add_placeholder(list, "Implemente _rebuild_clients() com os dados do seu ClientManager.")


## Atualiza em tempo real os campos dinâmicos dos clientes (ex: ping).
## Chamado toda frame. Apenas escreve em Labels — não cria nós novos.
##
## Exemplo:
##   for peer_id: int in _client_rows:
##       var c = client_manager.get_client(peer_id)
##       if c == null: continue
##       var refs: Dictionary = _client_rows[peer_id]
##       if refs.has("ping"):  refs["ping"].text  = "%d ms" % c.ping
##       if refs.has("state"): refs["state"].text = c.state
func _update_clients_realtime() -> void:
	if client_registry == null or _client_rows.is_empty():
		return
		
	for client_uuid in _client_rows:
		var c = client_registry.get_player(client_uuid)
		if c == null: continue
		var refs: Dictionary = _client_rows[client_uuid]
		if refs.has("ping"):  refs["ping"].text  = "%d ms" % network_manager.client_latency_map.get(c["uuid_base"], 0)

# ── ABA: SALAS ────────────────────────────────────────────────────────────────

## Reconstrói a lista de salas.
##
## Exemplo:
##   func _rebuild_rooms(list: VBoxContainer) -> void:
##       _room_rows.clear()
##       _add_header(list, ["ID", "Nome", "Jogadores", "Cap.", "Estado", "Ações"])
##       for room_id in room_manager.get_all_room_ids():
##           var r = room_manager.get_room(room_id)
##           var refs: Dictionary = _add_row(list, [
##               _col(str(room_id),          "id",      80),
##               _col(r.name,                "name",    160),
##               _col(str(r.player_count),   "players", 80),  # tempo real
##               _col(str(r.max_players),    "cap",     60),
##               _col(r.state,               "state",   100),
##               _col_btn("Fechar", func(): room_manager.close_room(room_id)),
##               _col_btn("Dump",   func(): print(r)),
##           ])
##           _room_rows[room_id] = _refs
func _rebuild_rooms(list: VBoxContainer) -> void:
	_room_rows.clear()
	var col_names: Array[String] = ["ID", "Nome", "Host", "Jogad.", "Kicked", "InGame", "TT de part.", "TT playt.", "", ""]
	var col_sizes: Array[int] = [60, 100, 100, 100, 100, 75, 75, 75, 75, 75]
	_add_header(list, col_names, col_sizes)

	if room_registry == null:
		_add_placeholder(list, "RoomManager não configurado — chame setup() primeiro.")
		return

	for room_id in room_registry.get_all_rooms_ids():
		var r = room_registry.get_room(room_id)
		var host_ = client_registry.get_player(r["host_id"])
		var players_pos = room_registry.get_all_room_players_positions(room_id)
		var kicked = room_registry.get_all_kicked_players(room_id, true)
		var _refs: Dictionary = _add_row(list, [
			_col(str(r["id"]),                                    "", 60),
			_col(r["name"],                                       "", 100),
			_col(str(host_["name"]),                              "", 100),
			_col(str(players_pos),                                "", 100),
			_col(str(kicked),                                     "", 100),
			_col(str("🟢" if r["in_game"] else "🔴"),             "", 75),
			_col(str(r["total_rounds_played"]),                   "", 75),
			_col(_fmt_time(r["total_playtime"]),                  "", 75),
			_col_btn("Print Settings",  func(): print(r["settings"]), 75),
			_col_btn("Print",  func(): print(r), 75)
		])
		_room_rows[room_id] = _refs
	#_add_placeholder(list, "Implemente _rebuild_rooms() com os dados do seu RoomManager.")


## Atualiza em tempo real os campos dinâmicos das salas.
##
## Exemplo:
##   for room_id in _room_rows:
##       var r = room_manager.get_room(room_id)
##       if r == null: continue
##       var refs: Dictionary = _room_rows[room_id]
##       if refs.has("players"): refs["players"].text = str(r.player_count)
##       if refs.has("state"):   refs["state"].text   = r.state
func _update_rooms_realtime() -> void:
	if room_registry == null or _room_rows.is_empty():
		return
	# ┌─────────────────────────────────────────────────────────────────────┐
	# │  SUBSTITUA ESTE BLOCO COM SUA LÓGICA REAL                          │
	# └─────────────────────────────────────────────────────────────────────┘


# ── ABA: PARTIDAS ─────────────────────────────────────────────────────────────

## Reconstrói a lista de partidas.
##
## Exemplo:
##   func _rebuild_matches(list: VBoxContainer) -> void:
##       _match_rows.clear()
##       _add_header(list, ["ID", "Sala", "Jogadores", "Tempo", "Estado", "Ações"])
##       for match_id in match_manager.get_all_match_ids():
##           var m = match_manager.get_match(match_id)
##           var refs: Dictionary = _add_row(list, [
##               _col(str(match_id),       "id",      80),
##               _col(str(m.room_id),      "room",    80),
##               _col(str(m.player_count), "players", 80),
##               _col("00:00",             "time",    80),  # tempo real
##               _col(m.state,             "state",   100),
##               _col_btn("Encerrar", func(): match_manager.end_match(match_id)),
##               _col_btn("Dump",     func(): print(m)),
##           ])
##           _match_rows[match_id] = refs
func _rebuild_matches(list: VBoxContainer) -> void:
	_match_rows.clear()
	var col_names: Array[String] = ["ID", "Sala N", "Sala ID", "Jogad.", "T inicio", "", "", ""]
	var col_sizes: Array[int] = [40, 110, 60, 100, 100, 75, 75, 75]
	_add_header(list, col_names, col_sizes)

	if round_registry == null:
		_add_placeholder(list, "MatchManager não configurado — chame setup() primeiro.")
		return

	for round_id in round_registry.get_all_rounds_ids():
		var m = round_registry.get_round(round_id)
		var players_pos = round_registry.get_all_round_players_positions(m["round_id"])
		var _refs: Dictionary = _add_row(list, [
			_col(str(m["round_id"]),                                "", 40),
			_col(str(m["room_name"]),                               "", 110),
			_col(str(m["room_id"]),                                 "", 60),
			_col(str(players_pos),                                  "", 100),
			_col(_fmt_time(m["start_time"]),                        "", 100),
			_col_btn("Print Settings",  func(): print(m["settings"]), 75),
			_col_btn("Print Spawned",  func(): print(str(m["spawned_players"])), 75),
			_col_btn("Print",  func(): print(m), 75)
		   ])
		_match_rows[round_id] = _refs
	#_add_placeholder(list, "Implemente _rebuild_matches() com os dados do seu MatchManager.")


## Atualiza em tempo real os campos dinâmicos das partidas (ex: tempo decorrido).
##
## Exemplo:
##   for match_id in _match_rows:
##       var m = match_manager.get_match(match_id)
##       if m == null: continue
##       var refs: Dictionary = _match_rows[match_id]
##       if refs.has("time"):    refs["time"].text    = _fmt_time(m.elapsed)
##       if refs.has("players"): refs["players"].text = str(m.player_count)
func _update_matches_realtime() -> void:
	if round_registry == null or _match_rows.is_empty():
		return
	# ┌─────────────────────────────────────────────────────────────────────┐
	# │  SUBSTITUA ESTE BLOCO COM SUA LÓGICA REAL                          │
	# └─────────────────────────────────────────────────────────────────────┘


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS DE LINHA — use estes para construir as listas nos _rebuild_*()
# ─────────────────────────────────────────────────────────────────────────────

## Cria um descritor de coluna de TEXTO.
## O Label criado ficará acessível em refs[key] para atualização em tempo real.
## Passe key = "" (padrão) se não precisar atualizar este campo depois.
##
## [param text]       Texto inicial exibido
## [param key]        Chave para recuperar o Label no dict de refs (vazio = não armazena)
## [param min_width]  Largura mínima da coluna em pixels
func _col(text: String, key: String = "", min_width: int = COL_MIN_WIDTH) -> Dictionary:
	return { "type": "label", "text": text, "key": key, "min_width": min_width }


## Cria um descritor de coluna de BOTÃO.
##
## [param label]      Texto exibido no botão
## [param callback]   Callable chamado ao pressionar (use lambda: func(): ...)
## [param min_width]  Largura mínima da coluna em pixels
func _col_btn(label: String, callback: Callable, min_width: int = BTN_MIN_WIDTH) -> Dictionary:
	return { "type": "button", "text": label, "callback": callback, "min_width": min_width }


## Adiciona uma linha de CABEÇALHO com os nomes das colunas.
## As larguras dos cabeçalhos usam COL_MIN_WIDTH como padrão.
## Se precisar de larguras diferentes, ajuste manualmente após a chamada.
##
## [param parent]        VBoxContainer de destino
## [param column_names]  Nomes de cada coluna, na mesma ordem usada em _add_row()
func _add_header(parent: VBoxContainer, column_names: Array[String], column_sizes: Array[int]) -> void:
	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	
	for i in range(column_names.size()):
		var col_name: String = column_names[i]
		var lbl: Label = Label.new()
		lbl.text = col_name
		var final_col = column_sizes[i] if i >= 0 and i < column_sizes.size() else COL_MIN_WIDTH
		lbl.custom_minimum_size.x = final_col
		lbl.clip_text = true
		# Cor amarelada para diferenciar o cabeçalho visualmente
		lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
		hbox.add_child(lbl)

	parent.add_child(hbox)
	parent.add_child(HSeparator.new())


## Adiciona uma linha de DADOS ao container.
## Retorna um Dictionary { "chave": Label } para atualização em tempo real.
## Armazene o retorno em _client_rows / _room_rows / _match_rows indexado pelo ID do item.
##
## [param parent]   VBoxContainer de destino
## [param columns]  Array de descritores criados com _col() ou _col_btn()
func _add_row(parent: VBoxContainer, columns: Array[Dictionary]) -> Dictionary:
	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)

	var refs: Dictionary = {}

	for col: Dictionary in columns:
		match col.get("type", "label"):

			"label":
				var lbl: Label = Label.new()
				lbl.text = col.get("text", "")
				lbl.custom_minimum_size.x = col.get("min_width", COL_MIN_WIDTH)
				lbl.clip_text = true
				hbox.add_child(lbl)
				# Armazena referência apenas se a chave foi definida
				var key: String = col.get("key", "")
				if not key.is_empty():
					refs[key] = lbl

			"button":
				var btn: Button = Button.new()
				btn.text = col.get("text", "Botão")
				btn.custom_minimum_size.x = col.get("min_width", BTN_MIN_WIDTH)
				var cb: Callable = col.get("callback", Callable())
				if cb.is_valid():
					btn.pressed.connect(cb)
				hbox.add_child(btn)

	parent.add_child(hbox)
	return refs


## Adiciona um label de mensagem vazia ou de erro, centralizado na lista.
## Útil quando não há dados ou quando o manager não foi configurado.
##
## [param parent]   VBoxContainer de destino
## [param message]  Mensagem a exibir
func _add_placeholder(parent: VBoxContainer, message: String) -> void:
	var lbl: Label = Label.new()
	lbl.text = message
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	parent.add_child(lbl)


# ─────────────────────────────────────────────────────────────────────────────
# UTILITÁRIOS
# ─────────────────────────────────────────────────────────────────────────────

## Formata um valor em segundos para o padrão mm:ss.
## Útil em _update_matches_realtime() para o campo de tempo de partida.
##
## [param seconds]  Tempo em segundos (float)
func _fmt_time(seconds: float) -> String:
	var m: int = floor(seconds / 60.0)
	var s: int = int(seconds) % 60
	return "%02d:%02d" % [m, s]


# ─────────────────────────────────────────────────────────────────────────────
# CONSTRUÇÃO DA UI  (chamado uma única vez em _ready)
# ─────────────────────────────────────────────────────────────────────────────

## Constrói toda a hierarquia de UI programaticamente.
## Não chame manualmente — é invocado automaticamente por _ready().
func _build_ui() -> void:

	# ── CanvasLayer ────────────────────────────────────────────────────────
	# Layer 128 garante que o painel fique sobre qualquer nó de cena
	_canvas = CanvasLayer.new()
	_canvas.layer = 128
	add_child(_canvas)

	# ── Control de tela cheia (base para centralização) ────────────────────
	var root_ctrl: Control = Control.new()
	root_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(root_ctrl)

	# ── CenterContainer — centraliza o PanelContainer na tela ─────────────
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(center)

	# ── PanelContainer principal ───────────────────────────────────────────
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = PANEL_SIZE
	_panel.visible = false
	center.add_child(_panel)

	# ── VBoxContainer interno do painel ────────────────────────────────────
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_panel.add_child(vbox)

	# ── Barra de cabeçalho (título + dica de teclas) ───────────────────────
	var header_hbox: HBoxContainer = HBoxContainer.new()
	vbox.add_child(header_hbox)

	_tab_title = Label.new()
	_tab_title.text = ""
	_tab_title.add_theme_font_size_override("font_size", 16)
	_tab_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(_tab_title)

	var hint: Label = Label.new()
	hint.text = "F1 Clientes | F2 Salas | F3 Partidas  (mesma tecla ou esc = fechar)"
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint.add_theme_font_size_override("font_size", 12)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_hbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	# ── ScrollContainers das abas (um por aba) ─────────────────────────────
	_tab_panels.clear()
	_list_containers.clear()

	for _i: int in 3:
		var scroll: ScrollContainer = ScrollContainer.new()
		scroll.visible = false
		scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
		vbox.add_child(scroll)

		var list: VBoxContainer = VBoxContainer.new()
		list.add_theme_constant_override("separation", 3)
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list)

		_tab_panels.append(scroll)
		_list_containers.append(list)

	# ── Barra de status inferior ───────────────────────────────────────────
	vbox.add_child(HSeparator.new())

	var status: Label = Label.new()
	status.text = (
		"Rebuild estrutural throttled (%.1f s)  |  Campos dinâmicos atualizados todo frame" % REBUILD_INTERVAL
	)
	status.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	status.add_theme_font_size_override("font_size", 10)
	vbox.add_child(status)
