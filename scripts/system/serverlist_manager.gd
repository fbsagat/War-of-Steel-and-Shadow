# ServerListManager.gd
# Gerencia uma lista persistente de servidores com id (int), nome (String), ip (String) e porta (int).
# Salva/Carrega em JSON no diretório user://
extends Node
class_name ServerListManager

const SAVE_PATH = "user://servers_database.json"

var _next_id: int = 1
var items: Array = []  # Array de Dictionary

func _init():
	load_items()

# Gera um ID único incremental
func _generate_unique_id() -> int:
	var id = _next_id
	_next_id += 1
	return id

# Carrega os itens do arquivo JSON
func load_items() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		items.clear()
		_next_id = 1
		return

	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("Falha ao abrir arquivo para leitura: " + str(FileAccess.get_open_error()))
		items.clear()
		_next_id = 1
		return

	var content = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_result = json.parse(content)
	if parse_result != OK:
		push_error("Erro ao fazer parse do JSON: " + json.get_error_message())
		items.clear()
		_next_id = 1
		return

	var raw_data = json.data
	if typeof(raw_data) != TYPE_ARRAY:
		push_error("JSON inválido: raiz deve ser um array")
		items.clear()
		_next_id = 1
		return

	items.clear()
	var max_id: int = 0

	for entry in raw_data:
		if typeof(entry) != TYPE_DICTIONARY:
			push_warning("Entrada inválida no array JSON: ", entry)
			continue

		# Validar campos obrigatórios
		if not (entry.has("id") and entry.has("nome") and entry.has("ip") and entry.has("porta")):
			push_warning("Item ignorado: campos ausentes", entry)
			continue

		# Converter e validar tipos
		var id_value = int(entry.id)
		var nome_value = str(entry.nome)
		var ip_value = str(entry.ip)
		var porta_value = int(entry.porta)

		# Atualizar próximo ID com base no maior existente
		if id_value > max_id:
			max_id = id_value

		var item = {
			"id": id_value,
			"nome": nome_value,
			"ip": ip_value,
			"porta": porta_value
		}
		items.append(item)

	_next_id = max_id + 1

# Salva os itens atuais no arquivo JSON
func save_items() -> void:
	var json_string = JSON.stringify(items, "\t")
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("Falha ao abrir arquivo para escrita: " + str(FileAccess.get_open_error()))
		return

	file.store_string(json_string)
	file.close()

# Adiciona um novo servidor à lista (id gerado automaticamente)
# Retorna o id gerado (int)
func add_item(nome: String, ip: String, porta: int) -> int:
	var new_id = _generate_unique_id()

	var new_item = {
		"id": new_id,
		"nome": nome,
		"ip": ip,
		"porta": porta
	}
	items.append(new_item)
	save_items()
	return new_id

# Verifica se um ID já existe
func _id_exists(id: int) -> bool:
	for item in items:
		if item.id == id:
			return true
	return false

# Remove um servidor da lista pelo id (int)
# Retorna true se removido, false se não encontrado
func remove_item(id: int) -> bool:
	for i in range(items.size()):
		if items[i].id == id:
			items.remove_at(i)
			save_items()
			return true
	return false

# Retorna uma cópia da lista atual de servidores
func get_items() -> Array:
	return items.duplicate(true)

# Retorna uma cópia do servidor com o ID fornecido, ou {} se não encontrado
func get_item_by_id(id: int) -> Dictionary:
	for item in items:
		if item.id == id:
			return item.duplicate(true)
	return {}

# (Opcional) Limpa todos os servidores
func clear_all() -> void:
	items.clear()
	_next_id = 1
	save_items()
