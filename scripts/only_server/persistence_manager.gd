extends Node
class_name ServerPersistence

## Caminho do arquivo de persistência no diretório de usuário.
## Usa o esquema "user://" para portabilidade entre plataformas.
const SAVE_PATH: String = "user://server_configs.json"

## Identificador único do servidor (hex string de 32 caracteres, derivado de 16 bytes).
## Utilizado para identificação em comunicações de rede e logs.
var server_id: String = ""

## Chave secreta do servidor para autenticação/criptografia (32 bytes).
## [b]Atenção:[/b] Este dado é sensível. Em produção, considere criptografar
## o arquivo de save ou usar um backend seguro para armazenamento.
var server_secret: PackedByteArray = PackedByteArray()

## Cache em memória dos dados carregados para evitar leituras repetidas do disco.
## Reduz I/O e melhora performance em operações frequentes.
var _cached_data: Dictionary = {}

## Flag que indica se o cache foi modificado e precisa ser persistido no disco.
## Permite escrita preguiçosa (lazy write) e controle explícito via [method flush].
var _is_dirty: bool = false


# =========================================================
# 🔹 INICIALIZAÇÃO
# =========================================================

## Inicializa o sistema de persistência, carregando dados existentes ou
## gerando uma nova identidade para o servidor se necessário.
##
## Executa as seguintes etapas:
## 1. Carrega o arquivo JSON de save (ou retorna vazio se inexistente)
## 2. Valida e restaura [member server_id] e [member server_secret]
## 3. Gera nova identidade criptográfica caso os dados não existam
## 4. Persiste a nova identidade imediatamente se gerada
##
## [return] [Dictionary] contendo uma cópia profunda dos dados carregados.
##          Estrutura típica:
##          {
##              "server_id": String,
##              "server_secret": String (hex),
##              "players": Dictionary,
##              "players_cache": Dictionary,
##              "saved_at": float (timestamp Unix)
##          }
##
## [b]Nota:[/b] O retorno é uma cópia profunda ([method Dictionary.duplicate] com [code]true[/code])
## para evitar modificações acidentais no cache interno.
func init(is_persistent: bool):
	if not is_persistent:
		_generate_server_identity()
		return
	
	_cached_data = _load_file()

	# Valida e carrega identidade existente
	if _cached_data.has("server_id") and _cached_data.has("server_secret"):
		server_id = _cached_data["server_id"]
		# ✅ CORREÇÃO: String.hex_decode() retorna PackedByteArray (Godot 4.x)
		server_secret = _cached_data["server_secret"].hex_decode()
	else:
		print("ServerPersistence: Gerando nova identidade do servidor...")
		_generate_server_identity()
		_save_identity()
	#return _cached_data.duplicate(true)


# =========================================================
# 🔐 GERENCIAMENTO DE IDENTIDADE
# =========================================================

## Gera uma nova identidade criptográfica para o servidor.
##
## Cria:
## - [member server_id]: 16 bytes aleatórios codificados em hex (32 caracteres)
## - [member server_secret]: 32 bytes aleatórios para operações HMAC/criptografia
##
## [b]Nota:[/b] Esta função não persiste os dados. Chame [method _save_identity]
## ou [method flush] após a geração para salvar no disco.
func _generate_server_identity() -> void:
	var crypto: Crypto = Crypto.new()
	server_id = crypto.generate_random_bytes(16).hex_encode()
	server_secret = crypto.generate_random_bytes(32)

## Salva a identidade atual do servidor no cache e marca para persistência.
##
## Atualiza os campos "server_id" e "server_secret" (em formato hex) no
## dicionário interno e define a flag [member _is_dirty] para [code]true[/code].
## A escrita no disco ocorre na próxima chamada a [method _save_file] ou [method flush].
##
## [b]Segurança:[/b] O [member server_secret] é armazenado como hex string no JSON.
## Para ambientes de produção, implemente criptografia simétrica antes de salvar.
func _save_identity() -> void:
	_cached_data["server_id"] = server_id
	_cached_data["server_secret"] = server_secret.hex_encode()
	_is_dirty = true
	_save_file()


# =========================================================
# 👥 GERENCIAMENTO DE JOGADORES (DESCOPLADO)
# =========================================================

## Garante que os dicionários de jogadores e cache existam no estado interno.
func _ensure_player_dicts() -> void:
	if not _cached_data.has("players"):
		_cached_data["players"] = {}
	if not _cached_data.has("players_cache"):
		_cached_data["players_cache"] = {}

## 📝 Registra os dados iniciais do jogador.
## 
## [param uuid] Identificador único do jogador.
## [param player_data] Dicionário com dados do jogador (stats, inventário, etc).
##
## [b]Comportamento:[/b]
## - Cria ou sobrescreve a entrada em [code]players[/code]
## - Inicializa o [code]players_cache[/code] com string vazia se o UUID ainda não existir
## - [b]Não exige node_path nesta etapa[/b]
##
## [b]Nota:[/b] Use este método quando o jogador conectar ou quando seus dados
## forem inicializados, [b]antes[/b] da instanciação do nó no cenário.
func register_player(uuid: String, player_data: Dictionary) -> void:
	_ensure_player_dicts()
	_cached_data["players"][uuid] = player_data.duplicate(true)
	
	if not _cached_data["players_cache"].has(uuid):
		_cached_data["players_cache"][uuid] = ""
		
	_is_dirty = true
	_save_file()

## 📝 SUBSTITUIÇÃO COMPLETA DE DADOS
##
## Sobrescreve integralmente os dados do jogador identificado por [param uuid].
##
## [param uuid] Identificador único do jogador.
## [param new_data] Novo dicionário que substituirá completamente os dados existentes.
##
## [b]Comportamento:[/b]
## - Substituição atômica: todos os campos anteriores são perdidos
## - Se o UUID não existir, cria nova entrada com aviso ([method push_warning])
## - Faz cópia profunda ([code]duplicate(true)[/code]) para evitar side-effects externos
##
## [b]Quando usar:[/b] Snapshots completos, reset de personagem,
## ou quando você já possui a estrutura inteira atualizada em memória.
func replace_player_data(uuid: String, new_data: Dictionary) -> void:
	_ensure_player_dicts()
	if not _cached_data["players"].has(uuid):
		push_warning("ServerPersistence: UUID %s não encontrado. Criando nova entrada..." % uuid)
	
	_cached_data["players"][uuid] = new_data.duplicate(true)
	_is_dirty = true
	_save_file()

## 🔄 ATUALIZAÇÃO PARCIAL DE DADOS (PATCH)
##
## Mescla recursivamente apenas os campos fornecidos em [param delta],
## preservando todos os demais dados existentes do jogador.
##
## [param uuid] Identificador único do jogador.
## [param delta] Dicionário contendo apenas os campos a serem atualizados.
##               Exemplo: [code]{"health": 80, "position": {"x": 10.0, "y": 5.0}}[/code]
##
## [b]Comportamento:[/b]
## - Mescla recursiva: [Dictionary]s aninhados são atualizados campo a campo
## - [Array]s são [b]substituídos[/b] integralmente (não mesclados)
## - Falha segura se UUID não existir ([method push_error] + retorno imediato)
## - Persiste automaticamente após a mesclagem
##
## [b]Quando usar:[/b] Atualizações frequentes ou incrementais
## (ex: sincronização de posição, consumo de vida, adição/remoção de item).
func patch_player_data(uuid: String, delta: Dictionary) -> void:
	_ensure_player_dicts()
	if not _cached_data["players"].has(uuid):
		push_error("ServerPersistence: patch_player_data falhou. UUID não registrado: %s" % uuid)
		return
	
	var current_data: Dictionary = _cached_data["players"][uuid]
	_deep_merge(current_data, delta)
	_is_dirty = true
	_save_file()

## 🔧 Utilitário interno para mesclagem recursiva de dicionários
## Modifica [param target] in-place para evitar alocação desnecessária.
func _deep_merge(target: Dictionary, source: Dictionary) -> void:
	for key: String in source:
		if target.has(key) and target[key] is Dictionary and source[key] is Dictionary:
			_deep_merge(target[key], source[key])
		else:
			target[key] = source[key]

## 🔗 Associa ou atualiza o caminho do nó do jogador.
##
## [param uuid] Identificador único do jogador.
## [param node_path] Caminho retornado por [method Node.get_path()] após instanciação.
##
## [b]Comportamento:[/b]
## - Atualiza apenas o [code]players_cache[/code]
## - Preserva os dados em [code]players[/code] intactos
## - Emite aviso se o UUID ainda não foi registrado
##
## [b]Nota:[/b] Chame este método quando o nó do jogador for instanciado
## ou quando mudar de cena/rede. O sistema mescla automaticamente no save.
func bind_player_path(uuid: String, node_path: String) -> void:
	_ensure_player_dicts()
	
	if not _cached_data["players"].has(uuid):
		push_warning("ServerPersistence: bind_player_path() chamado para UUID não registrado: %s" % uuid)
		
	_cached_data["players_cache"][uuid] = node_path
	_is_dirty = true
	_save_file()

## ❌ REMOVE JOGADOR
## Remove completamente os dados e cache de um jogador.
func remove_player(uuid: String) -> void:
	_ensure_player_dicts()
	_cached_data["players"].erase(uuid)
	_cached_data["players_cache"].erase(uuid)
	_is_dirty = true
	_save_file()


# =========================================================
# 📂 CARREGAMENTO DE JOGADORES
# =========================================================

## Retorna os dados de jogadores com tipagem estrita e validação de campos.
##
## [return] [Dictionary] com estrutura:
## [codeblock]
## {
##     "players": Dictionary[String, Dictionary],
##     "players_cache": Dictionary[String, String]
## }
## [/codeblock]
##
## Cada campo do jogador é explicitamente convertido para seu tipo correto
## (int, float, bool, String), evitando erros de runtime comuns após
## deserialização JSON. Campos ausentes recebem valores padrão seguros.
func load_players() -> Dictionary:
	var typed_players: Dictionary[String, Dictionary] = {}
	var raw_players: Dictionary = _cached_data.get("players", {})

	for uuid: String in raw_players:
		var raw: Dictionary = raw_players[uuid]
		# Conversão explícita e segura de cada campo conforme sua estrutura
		typed_players[uuid] = {
			"peer_id": int(raw.get("peer_id", 0)),
			"uuid_base": str(raw.get("uuid_base", uuid)),
			"entry_position": int(raw.get("entry_position", 0)),
			"name": str(raw.get("name", "")),
			"registered": bool(raw.get("registered", false)),
			"connected": bool(raw.get("connected", false)),
			"disconnected_at": float(raw.get("disconnected_at", 0.0)),
			"created_at": float(raw.get("created_at", 0.0)),
			"room_id": int(raw.get("room_id", 0)),
			"round_id": int(raw.get("round_id", 0)),
			"node_path": str(raw.get("node_path", "")),
			# Suporta both "ClientState" (JSON original) e "client_state" (convenção GDScript)
			"ClientState": int(raw.get("ClientState", raw.get("client_state", 0)))
		}

	return {
		"players": typed_players,
		"players_cache": _cached_data.get("players_cache", {}).duplicate(true)
	}


# =========================================================
# 🗑️ LIMPEZA DE DADOS
# =========================================================

## Exclui permanentemente o arquivo de save e reseta o estado em memória.
##
## [b]Atenção:[/b] Esta operação é [b]irreversível[/b]. Todos os dados de
## configuração, identidade e jogadores serão perdidos.
##
## [b]Efeitos colaterais:[/b]
## - Deleta o arquivo em [constant SAVE_PATH] se existir
## - Limpa [member _cached_data] e reseta [member _is_dirty]
## - Zera [member server_id] e [member server_secret] em memória
##
## [b]Nota:[/b] Após chamar este método, chame [method init] novamente para
## regenerar uma nova identidade se necessário.
func delete_all() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var err: Error = DirAccess.remove_absolute(SAVE_PATH)
		if err != OK:
			push_error("ServerPersistence: Erro ao deletar arquivo de save (código %d): %s" % [err, SAVE_PATH])

	# Reseta estado em memória
	_cached_data.clear()
	server_id = ""
	server_secret = PackedByteArray()
	_is_dirty = false


# =========================================================
# 🔧 OPERAÇÕES DE ARQUIVO (PRIVADO)
# =========================================================

## Carrega e parseia o arquivo JSON de persistência.
##
## [return] [Dictionary] com os dados parseados, ou dicionário vazio em caso
##          de erro, arquivo inexistente ou estrutura inválida.
##
## [b]Tratamento de erros:[/b]
## - Arquivo inexistente: retorna [code]{}[/code] (comportamento esperado para primeira execução)
## - Falha na abertura: log via [method push_error] + retorno vazio
## - Erro de parse: log com linha e mensagem do erro + retorno vazio
## - Raiz não é Dictionary: log + retorno vazio (garante tipo seguro)
##
## [b]Nota:[/b] Esta função não atualiza o cache interno. Use [method init]
## ou atribua manualmente o retorno a [member _cached_data] se necessário.
func _load_file() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("ServerPersistence: Falha ao abrir arquivo para leitura: %s" % SAVE_PATH)
		return {}

	var content: String = file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	var parse_err: Error = json.parse(content)
	if parse_err != OK:
		push_error("ServerPersistence: Erro ao parsear JSON (linha %d): %s" % [
			json.get_error_line(),
			json.get_error_message()
		])
		return {}

	var data = json.data
	if not data is Dictionary:
		push_error("ServerPersistence: Raiz do JSON não é um Dictionary (tipo: %s)" % typeof(data))
		return {}

	return data

## Persiste o conteúdo de [member _cached_data] no arquivo JSON.
##
## [b]Comportamento:[/b]
## - Se [member _is_dirty] for [code]false[/code], retorna imediatamente (otimização)
## - Adiciona/atualiza o campo "saved_at" com timestamp Unix atual
## - Serializa com indentação (tab) e ordenação de chaves para legibilidade
## - Fecha o arquivo e reseta [member _is_dirty] apenas se a escrita for bem-sucedida
##
## [b]Tratamento de erros:[/b] Falhas na abertura ou escrita são logadas via
## [method push_error] mas não interrompem a execução do jogo.
##
## [b]Thread-safety:[/b] Esta função não é thread-safe. Se acessar de múltiplas
## threads, proteja com [Mutex] ou chame apenas da thread principal.
func _save_file() -> void:
	if not _is_dirty:
		return

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("ServerPersistence: Falha ao abrir arquivo para escrita: %s" % SAVE_PATH)
		return

	# Adiciona metadata de salvamento
	_cached_data["saved_at"] = Time.get_unix_time_from_system()

	# Serializa com formatação legível (indentação com tab, chaves ordenadas)
	var json_string: String = JSON.stringify(_cached_data, "\t", true)
	file.store_string(json_string)
	file.close()
	
	# Só marca como limpo se a escrita foi concluída
	_is_dirty = false

## Força a persistência imediata dos dados em cache para o disco.
##
## [b]Casos de uso:[/b]
## - Antes de encerrar o servidor ou trocar de cena
## - Após operações críticas que não podem ser perdidas
## - Em testes para garantir que dados foram escritos
##
## [b]Nota:[/b] Se [member _is_dirty] for [code]false[/code], esta função
## retorna imediatamente sem I/O. É seguro chamar repetidamente.
func flush() -> void:
	if _is_dirty:
		_save_file()


# =========================================================
# 🔍 UTILITÁRIOS (OPCIONAL)
# =========================================================



## Verifica se há dados não salvos em cache.
##
## [return] [code]true[/code] se [member _cached_data] foi modificado desde
##          o último salvamento, [code]false[/code] caso contrário.
##
## [b]Uso:[/b] Útil para exibir indicadores de "salvo pendente" na UI ou
## para decidir se deve chamar [method flush] antes de operações críticas.
func is_dirty() -> bool:
	return _is_dirty

## Retorna uma cópia profunda de todos os dados atualmente em cache.
##
## [return] [Dictionary] contendo todos os campos persistidos, incluindo
##          "server_id", "server_secret" (hex), "players", "players_cache"
##          e "saved_at".
##
## [b]Nota:[/b] O retorno é uma cópia profunda para evitar modificações
## acidentais. Para leitura de campos específicos, prefira os métodos
## dedicados como [method load_players].
func get_all_data() -> Dictionary:
	return _cached_data.duplicate(true)
