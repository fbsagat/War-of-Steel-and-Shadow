extends Node
class_name MapDatabase

# ==============================================================================
#  MapManager.gd — Autoload (Servidor)
#  Responsável por carregar, validar, selecionar e gerenciar mapas do servidor.
#
#  Uso:
#    MapManager.request_map_load(1, 4)          # carrega o mapa ID 1 p/ 4 jogadores
#    MapManager.request_random_map("deathmatch", 8)
#    MapManager.get_maps_by_mode("deathmatch")
# ==============================================================================

# ===== REGISTROS (Injetados pelo initializer.gd) =====

var initializer: GameInitializer = null

# ===== CONFIGURAÇÕES COMUNS =====

@export_group("Debug")
@export var debug_mode: bool = true

# ──────────────────────────────────────────────────────────────────────────────
#  SINAIS
# ──────────────────────────────────────────────────────────────────────────────

## Emitido quando um mapa é instanciado com sucesso.
signal map_loaded(map_id: int)

## Emitido quando o carregamento de um mapa falha.
signal map_load_failed(map_id: int, reason: String)

## Emitido quando a troca de mapa ocorre (há um mapa anterior ativo).
signal map_changed(old_id: int, new_id: int)

## Emitido quando o registro de mapas termina de ser lido e validado.
signal maps_registry_ready()


# ──────────────────────────────────────────────────────────────────────────────
#  CONSTANTES
# ──────────────────────────────────────────────────────────────────────────────

## Caminho do arquivo JSON com a lista de mapas.
const MAP_LIST_PATH: String = "res://scripts/utils/map_database_regs.json"

## Limites aceitáveis para o campo weight.
const WEIGHT_MIN: float = 0.0
const WEIGHT_MAX: float = 10.0


# ──────────────────────────────────────────────────────────────────────────────
#  ENUM — RESULTADO DO CARREGAMENTO
# ──────────────────────────────────────────────────────────────────────────────

enum MapLoadResult {
	OK,               ## Carregamento bem-sucedido.
	NOT_FOUND,        ## ID não existe no registro.
	DISABLED,         ## Mapa está desabilitado (enabled = false).
	SCENE_MISSING,    ## Arquivo .tscn não encontrado ou não carregável.
	INVALID_PLAYERS,  ## Número de jogadores fora do intervalo [min, max].
	CHECKSUM_FAIL,    ## Hash do arquivo de cena diverge do esperado.
}


# ──────────────────────────────────────────────────────────────────────────────
#  CLASSE INTERNA — DADOS DO MAPA
# ──────────────────────────────────────────────────────────────────────────────

class MapData:
	var id: int           = 0
	var scene_path: String = ""
	var name: String       = ""
	var thumb_path: String = ""
	var min_players: int   = 1
	var max_players: int   = 1
	var enabled: bool      = true
	var weight: float      = 1.0
	var modes: Array[String] = []
	var size: String       = ""
	var tags: Array[String]  = []
	var checksum: String   = ""

	## Converte o MapData de volta para Dictionary (útil para logs e RPC).
	func to_dict() -> Dictionary:
		return {
			"id":          id,
			"scene_path":  scene_path,
			"name":        name,
			"thumb_path":  thumb_path,
			"min_players": min_players,
			"max_players": max_players,
			"enabled":     enabled,
			"weight":      weight,
			"modes":       modes,
			"size":        size,
			"tags":        tags,
			"checksum":    checksum,
		}

	## Retorna uma string legível para logs.
	func _to_string() -> String:
		return "[%d] '%s' | modes=%s | players=%d–%d | " % [
			id, name, ", ".join(modes), min_players, max_players,
		]


# ──────────────────────────────────────────────────────────────────────────────
#  ESTADO INTERNO
# ──────────────────────────────────────────────────────────────────────────────

## Referência ao autoload de configurações do servidor (ajuste ao seu projeto).
## Usado internamente por _log_debug para filtrar módulos selecionados.

## Registro principal: id (int) → MapData.
var _map_registry: Dictionary = {}

## ID do mapa atualmente carregado (-1 = nenhum).
var _current_map_id: int = -1

## Referência à cena do mapa instanciada na árvore.
var _current_map_scene: Node = null

## Indica se o registro foi carregado ao menos uma vez.
var _registry_loaded: bool = false

# ══════════════════════════════════════════════════════════════════════════════
#  SEÇÃO 1 — CARREGAMENTO DO REGISTRO
# ══════════════════════════════════════════════════════════════════════════════

## Lê o JSON em MAP_LIST_PATH, parseia e popula _map_registry.
## Retorna true se ao menos um mapa foi registrado com sucesso.
func load_map_registry() -> bool:
	_log_debug("Lendo arquivo de mapas: '%s'" % MAP_LIST_PATH)

	# ── Verifica existência do arquivo ─────────────────────────────────────────
	if not FileAccess.file_exists(MAP_LIST_PATH):
		_log_debug("ERRO: Arquivo não encontrado: '%s'" % MAP_LIST_PATH)
		return false

	# ── Abre e lê o arquivo ────────────────────────────────────────────────────
	var file: FileAccess = FileAccess.open(MAP_LIST_PATH, FileAccess.READ)
	if file == null:
		_log_debug("ERRO: Falha ao abrir arquivo (código: %d)" % FileAccess.get_open_error())
		return false

	var raw: String = file.get_as_text()
	file.close()

	# ── Parseia o JSON ─────────────────────────────────────────────────────────
	var json: JSON = JSON.new()
	var parse_err: Error = json.parse(raw)
	if parse_err != OK:
		_log_debug("ERRO: JSON inválido — linha %d: %s" % [json.get_error_line(), json.get_error_message()])
		return false

	var data: Variant = json.get_data()
	if not data is Array:
		_log_debug("ERRO: JSON deve ser um Array de objetos de mapa.")
		return false

	# ── Processa cada entrada ──────────────────────────────────────────────────
	_map_registry.clear()
	var loaded: int  = 0
	var skipped: int = 0

	for entry: Variant in data:
		if not entry is Dictionary:
			_log_debug("AVISO: Entrada ignorada (não é Dictionary).")
			skipped += 1
			continue

		var map: MapData = _parse_map_entry(entry as Dictionary)
		if map == null:
			skipped += 1
			continue

		var errors: Array[String] = validate_map_data(map)
		if not errors.is_empty():
			_log_debug("AVISO: Mapa ID %d rejeitado — %s" % [map.id, ", ".join(errors)])
			skipped += 1
			continue

		_map_registry[map.id] = map
		loaded += 1
		_log_debug("Registrado: %s" % map._to_string())

	_registry_loaded = true
	_log_debug("Registro concluído — %d válidos | %d ignorados." % [loaded, skipped])

	if loaded > 0:
		maps_registry_ready.emit()

	return loaded > 0


## Recarrega o registro do disco, descartando o estado anterior.
## Use em hotreloads ou após editar o JSON em runtime.
func reload_registry() -> bool:
	_log_debug("Recarregando registro de mapas...")
	_registry_loaded = false
	_map_registry.clear()
	return load_map_registry()


# ──────────────────────────────────────────────────────────────────────────────
#  Parsing interno de uma entrada do JSON
# ──────────────────────────────────────────────────────────────────────────────

## Converte um Dictionary bruto do JSON em um MapData.
## Retorna null se algum campo obrigatório estiver ausente.
func _parse_map_entry(entry: Dictionary) -> MapData:
	const REQUIRED: Array = ["id", "scene_path", "name", "min_players",
							 "max_players", "enabled", "weight", "modes", "size", "tags"]

	for field: String in REQUIRED:
		if not entry.has(field):
			_log_debug("AVISO: Campo obrigatório ausente: '%s'" % field)
			return null

	var map: MapData = MapData.new()
	map.id          = int(entry["id"])
	map.scene_path  = str(entry["scene_path"])
	map.name        = str(entry["name"])
	map.thumb_path  = str(entry.get("thumb_path", ""))
	map.min_players = int(entry["min_players"])
	map.max_players = int(entry["max_players"])
	map.enabled     = bool(entry["enabled"])
	map.weight      = float(entry["weight"])
	map.size        = str(entry["size"])
	map.checksum    = str(entry.get("checksum", ""))

	for m: Variant in entry["modes"]:
		map.modes.append(str(m))

	for t: Variant in entry["tags"]:
		map.tags.append(str(t))

	return map


# ══════════════════════════════════════════════════════════════════════════════
#  SEÇÃO 2 — VALIDAÇÕES
# ══════════════════════════════════════════════════════════════════════════════

## Valida a integridade lógica de um MapData.
## Retorna Array com mensagens de erro. Array vazio = válido.
func validate_map_data(map: MapData) -> Array[String]:
	var errors: Array[String] = []

	if map.id <= 0:
		errors.append("id inválido (%d)" % map.id)

	if map.name.strip_edges().is_empty():
		errors.append("name vazio")

	if map.scene_path.strip_edges().is_empty():
		errors.append("scene_path vazio")

	if map.min_players < 1:
		errors.append("min_players < 1 (%d)" % map.min_players)

	if map.max_players < map.min_players:
		errors.append("max_players (%d) < min_players (%d)" % [map.max_players, map.min_players])

	if map.weight < WEIGHT_MIN or map.weight > WEIGHT_MAX:
		errors.append("weight %.2f fora de [%.1f, %.1f]" % [map.weight, WEIGHT_MIN, WEIGHT_MAX])

	if map.modes.is_empty():
		errors.append("modes vazio")

	if map.size.strip_edges().is_empty():
		errors.append("size vazio")

	if _map_registry.has(map.id):
		errors.append("ID %d duplicado no registro" % map.id)

	return errors


## Verifica se o arquivo .tscn do mapa existe e pode ser carregado.
func validate_scene_exists(map: MapData) -> bool:
	if not ResourceLoader.exists(map.scene_path, "PackedScene"):
		_log_debug("AVISO: Cena ausente para '%s': %s" % [map.name, map.scene_path])
		return false
	return true


## Verifica se player_count está dentro do intervalo permitido pelo mapa.
func validate_player_count(map: MapData, player_count: int) -> bool:
	if player_count < map.min_players or player_count > map.max_players:
		_log_debug("AVISO: %d jogador(es) inválido(s) para '%s' [%d–%d]." % [
			player_count, map.name, map.min_players, map.max_players])
		return false
	return true


## Verifica o checksum MD5 do arquivo de cena contra o valor armazenado no JSON.
## Se o campo checksum estiver vazio, a verificação é pulada (retorna true).
func validate_checksum(map: MapData) -> bool:
	if map.checksum.is_empty():
		_log_debug("Checksum ausente para '%s' — verificação ignorada." % map.name)
		return true

	if not FileAccess.file_exists(map.scene_path):
		_log_debug("ERRO (checksum): Arquivo não encontrado: %s" % map.scene_path)
		return false

	var file: FileAccess = FileAccess.open(map.scene_path, FileAccess.READ)
	if file == null:
		_log_debug("ERRO (checksum): Falha ao abrir: %s" % map.scene_path)
		return false

	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	# Usa MD5 para compatibilidade simples; substitua por sha256_text() se preferir.
	var computed: String = bytes.get_string_from_utf8().md5_text()

	if computed != map.checksum:
		_log_debug("ERRO (checksum): Divergência em '%s'. Esperado: %s | Obtido: %s" % [
			map.name, map.checksum, computed])
		return false

	_log_debug("Checksum OK para '%s'." % map.name)
	return true


## Agrega todas as verificações necessárias antes de carregar um mapa.
## Retorna o primeiro MapLoadResult diferente de OK, ou OK se tudo passar.
func can_load_map(map_id: int, player_count: int) -> MapLoadResult:
	if not _map_registry.has(map_id):
		_log_debug("can_load_map: ID %d não encontrado no registro." % map_id)
		return MapLoadResult.NOT_FOUND

	var map: MapData = _map_registry[map_id]

	if not map.enabled:
		_log_debug("can_load_map: Mapa '%s' está desabilitado." % map.name)
		return MapLoadResult.DISABLED

	if not validate_scene_exists(map):
		return MapLoadResult.SCENE_MISSING

	if not validate_player_count(map, player_count):
		return MapLoadResult.INVALID_PLAYERS

	if not validate_checksum(map):
		return MapLoadResult.CHECKSUM_FAIL

	return MapLoadResult.OK


# ══════════════════════════════════════════════════════════════════════════════
#  SEÇÃO 3 — CONSULTAS / QUERIES
# ══════════════════════════════════════════════════════════════════════════════

## Retorna um MapData pelo ID, ou null se inexistente.
func get_map_by_id(map_id: int) -> MapData:
	return _map_registry.get(map_id, null) as MapData


## Retorna todos os mapas habilitados.
func get_enabled_maps() -> Array[MapData]:
	var result: Array[MapData] = []
	for map: MapData in _map_registry.values():
		if map.enabled:
			result.append(map)
	return result


## Retorna mapas habilitados e compatíveis com o modo de jogo informado.
func get_maps_by_mode(mode: String) -> Array[MapData]:
	var result: Array[MapData] = []
	for map: MapData in _map_registry.values():
		if map.enabled and mode in map.modes:
			result.append(map)
	return result


## Retorna mapas habilitados que possuem a tag informada.
func get_maps_by_tag(tag: String) -> Array[MapData]:
	var result: Array[MapData] = []
	for map: MapData in _map_registry.values():
		if map.enabled and tag in map.tags:
			result.append(map)
	return result


## Retorna mapas habilitados compatíveis com o número de jogadores.
func get_maps_for_players(player_count: int) -> Array[MapData]:
	var result: Array[MapData] = []
	for map: MapData in _map_registry.values():
		if map.enabled and validate_player_count(map, player_count):
			result.append(map)
	return result


## Retorna mapas habilitados de um determinado tamanho ("small", "large", etc.).
func get_maps_by_size(size: String) -> Array[MapData]:
	var result: Array[MapData] = []
	for map: MapData in _map_registry.values():
		if map.enabled and map.size == size:
			result.append(map)
	return result


## Retorna todos os IDs registrados (habilitados ou não).
func get_all_map_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: Variant in _map_registry.keys():
		ids.append(id as int)
	return ids


## Retorna o MapData do mapa atualmente ativo, ou null.
func get_current_map() -> MapData:
	return get_map_by_id(_current_map_id)


## Retorna o ID do mapa atual (-1 se nenhum).
func get_current_map_id() -> int:
	return _current_map_id


## Verifica se o registro já foi carregado ao menos uma vez.
func is_registry_loaded() -> bool:
	return _registry_loaded


## Verifica se o mapa indicado está atualmente ativo.
func is_map_active(map_id: int) -> bool:
	return _current_map_id == map_id


## Verifica se um mapa existe e está habilitado.
func is_map_available(map_id: int) -> bool:
	return _map_registry.has(map_id) and (_map_registry[map_id] as MapData).enabled


# ══════════════════════════════════════════════════════════════════════════════
#  SEÇÃO 4 — SELEÇÃO PONDERADA
# ══════════════════════════════════════════════════════════════════════════════

## Seleciona aleatoriamente um mapa usando roleta de peso (weighted random).
## Filtros opcionais: modo de jogo e número de jogadores.
## Retorna null se nenhum candidato for encontrado.
func pick_random_map(mode: String = "", player_count: int = -1) -> MapData:
	# Monta a lista de candidatos aplicando filtros opcionais
	var candidates: Array[MapData] = get_enabled_maps()

	if not mode.is_empty():
		var filtered: Array[MapData] = []
		for m: MapData in candidates:
			if mode in m.modes:
				filtered.append(m)
		candidates = filtered

	if player_count > 0:
		var filtered: Array[MapData] = []
		for m: MapData in candidates:
			if validate_player_count(m, player_count):
				filtered.append(m)
		candidates = filtered

	if candidates.is_empty():
		_log_debug("pick_random_map: Nenhum candidato para mode='%s' | players=%d." % [mode, player_count])
		return null

	# Soma total dos pesos
	var total_weight: float = 0.0
	for m: MapData in candidates:
		total_weight += m.weight

	# Roleta de peso
	var roll: float = randf() * total_weight
	var accumulated: float = 0.0

	for m: MapData in candidates:
		accumulated += m.weight
		if roll <= accumulated:
			_log_debug("pick_random_map: Selecionado '%s' (weight=%.2f | roll=%.4f/%.4f)." % [
				m.name, m.weight, roll, total_weight])
			return m

	# Fallback (não deve ocorrer com pesos válidos)
	return candidates.back()


# ══════════════════════════════════════════════════════════════════════════════
#  SEÇÃO 5 — CARREGAMENTO E GERENCIAMENTO DE MAPAS
# ══════════════════════════════════════════════════════════════════════════════

## Solicita o carregamento de um mapa pelo ID.
## Executa todas as validações antes de instanciar a cena.
## Retorna MapLoadResult indicando o resultado.
func request_map_load(map_id: int, player_count: int = 1) -> MapLoadResult:
	_log_debug("request_map_load: ID=%d | jogadores=%d" % [map_id, player_count])
	
	if not _registry_loaded:
		_log_debug("ERRO: Registro não carregado. Chame load_map_registry() primeiro.")
		map_load_failed.emit(map_id, "REGISTRY_NOT_LOADED")
		return MapLoadResult.NOT_FOUND

	# ── Checagem agregada ──────────────────────────────────────────────────────
	var check: MapLoadResult = can_load_map(map_id, player_count)
	if check != MapLoadResult.OK:
		var reason: String = MapLoadResult.keys()[check]
		_log_debug("Carregamento negado para ID %d — motivo: %s" % [map_id, reason])
		map_load_failed.emit(map_id, reason)
		return check

	var map: MapData = _map_registry[map_id]

	# ── Carrega a PackedScene ──────────────────────────────────────────────────
	_log_debug("Carregando PackedScene: %s" % map.scene_path)
	var scene: PackedScene = load(map.scene_path) as PackedScene

	if scene == null:
		_log_debug("ERRO: load() retornou null para: %s" % map.scene_path)
		map_load_failed.emit(map_id, "SCENE_LOAD_FAILED")
		return MapLoadResult.SCENE_MISSING

	# ── Remove mapa anterior ───────────────────────────────────────────────────
	var old_id: int = _current_map_id
	_unload_current_map_internal()

	# ── Instancia e adiciona à árvore ──────────────────────────────────────────
	_current_map_scene = scene.instantiate()
	_current_map_id    = map_id
	get_tree().root.add_child(_current_map_scene)

	_log_debug("Mapa ativo: %s" % map._to_string())
	map_loaded.emit(map_id)

	if old_id != -1:
		map_changed.emit(old_id, map_id)

	return MapLoadResult.OK


## Seleciona e carrega um mapa aleatório ponderado.
## Retorna MapLoadResult do carregamento ou NOT_FOUND se sem candidatos.
func request_random_map(mode: String = "", player_count: int = 1) -> MapLoadResult:
	_log_debug("request_random_map: mode='%s' | jogadores=%d" % [mode, player_count])

	var map: MapData = pick_random_map(mode, player_count)
	if map == null:
		_log_debug("Nenhum mapa disponível para seleção aleatória.")
		map_load_failed.emit(-1, "NO_CANDIDATES")
		return MapLoadResult.NOT_FOUND

	return request_map_load(map.id, player_count)


## Descarrega o mapa atual da árvore de cenas.
## Seguro para chamar mesmo sem mapa ativo.
func unload_current_map() -> void:
	if _current_map_id == -1:
		_log_debug("unload_current_map: Nenhum mapa ativo.")
		return
	_log_debug("Descarregando mapa ID %d." % _current_map_id)
	_unload_current_map_internal()


## Reinicia o mapa atualmente ativo (descarrega e recarrega).
func restart_current_map(player_count: int = 1) -> MapLoadResult:
	var id: int = _current_map_id
	if id == -1:
		_log_debug("restart_current_map: Nenhum mapa ativo.")
		return MapLoadResult.NOT_FOUND
	_log_debug("Reiniciando mapa ID %d." % id)
	return request_map_load(id, player_count)


# ──────────────────────────────────────────────────────────────────────────────
#  Descarregamento interno (sem log de guarda)
# ──────────────────────────────────────────────────────────────────────────────

func _unload_current_map_internal() -> void:
	if _current_map_scene != null and is_instance_valid(_current_map_scene):
		_current_map_scene.queue_free()
	_current_map_scene = null
	_current_map_id    = -1


# ══════════════════════════════════════════════════════════════════════════════
#  SEÇÃO 6 — UTILITÁRIOS E DEBUG
# ══════════════════════════════════════════════════════════════════════════════

## Imprime um resumo formatado de todos os mapas no registro.
func print_registry_summary() -> void:
	if _map_registry.is_empty():
		_log_debug("Registro vazio.")
		return
	_log_debug("─── REGISTRO DE MAPAS (%d) ───────────────────────" % _map_registry.size())
	for map: MapData in _map_registry.values():
		_log_debug("  %s" % map._to_string())
	_log_debug("──────────────────────────────────────────────────")


## Converte um MapLoadResult em mensagem legível.
func result_to_string(result: MapLoadResult) -> String:
	match result:
		MapLoadResult.OK:             return "Sucesso"
		MapLoadResult.NOT_FOUND:      return "Mapa não encontrado"
		MapLoadResult.DISABLED:       return "Mapa desabilitado"
		MapLoadResult.SCENE_MISSING:  return "Arquivo de cena ausente"
		MapLoadResult.INVALID_PLAYERS:return "Número de jogadores inválido"
		MapLoadResult.CHECKSUM_FAIL:  return "Falha na verificação de integridade"
	return "Resultado desconhecido"


## Gera um relatório de todos os mapas disponíveis para um determinado contexto.
func get_availability_report(player_count: int, mode: String = "") -> Array[Dictionary]:
	var report: Array[Dictionary] = []

	for map: MapData in _map_registry.values():
		var issues: Array[String] = []

		if not map.enabled:
			issues.append("desabilitado")
		if not validate_scene_exists(map):
			issues.append("cena ausente")
		if not validate_player_count(map, player_count):
			issues.append("player count %d fora de [%d, %d]" % [player_count, map.min_players, map.max_players])
		if not mode.is_empty() and not mode in map.modes:
			issues.append("modo '%s' não suportado" % mode)

		report.append({
			"id":        map.id,
			"name":      map.name,
			"available": issues.is_empty(),
			"issues":    issues,
		})

	return report


# ===== DEBUG =====

## Imprime mensagem de debug se habilitado
func _log_debug(message: String, rpc_debug: bool = false):
	if not debug_mode:
		return
	if initializer.activate_only_selected and not "MapDatabase" in initializer.selected:
		return
	if rpc_debug and not initializer.rpc_debug:
		return
	print("[SERVER]%s[MapDatabase] %s" % ["[RPC]" if rpc_debug else "", message])
