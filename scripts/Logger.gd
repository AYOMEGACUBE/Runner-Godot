extends Node
# Logger.gd — система логирования в файл для отладки
# Автоматически записывает все логи в файл 3301_LOG.txt

const LOG_FILE_PATH: String = "res://3301_LOG.txt"

var log_file: FileAccess = null
var session_start_time: String = ""

func _ready() -> void:
	_start_new_session()

func _start_new_session() -> void:
	# Закрываем предыдущий файл, если открыт
	if log_file != null:
		log_file.close()
		log_file = null
	
	# Получаем время начала сессии
	var time_dict: Dictionary = Time.get_datetime_dict_from_system()
	session_start_time = "%04d-%02d-%02d %02d:%02d:%02d" % [
		time_dict.year,
		time_dict.month,
		time_dict.day,
		time_dict.hour,
		time_dict.minute,
		time_dict.second
	]
	
	# Пишем лог ТОЛЬКО в корень проекта: res://3301_LOG.txt
	var file_was_existing: bool = false
	var file_exists_res: bool = FileAccess.file_exists(LOG_FILE_PATH)
	
	if file_exists_res:
		# Файл существует - открываем для чтения-записи и переходим в конец
		log_file = FileAccess.open(LOG_FILE_PATH, FileAccess.READ_WRITE)
		file_was_existing = true
	else:
		# Файла нет - создаём новый для записи
		log_file = FileAccess.open(LOG_FILE_PATH, FileAccess.WRITE)
	
	if log_file != null:
		# Если файл существовал, перемещаемся в конец для добавления
		if file_was_existing:
			log_file.seek_end()
		# Добавляем разделитель новой сессии
		log_file.store_string("\n")
		log_file.store_string("=".repeat(80) + "\n")
		log_file.store_string("НОВАЯ СЕССИЯ: " + session_start_time + "\n")
		log_file.store_string("=".repeat(80) + "\n")
		log_file.flush()
	else:
		push_error("[Logger] Не удалось открыть файл лога: " + LOG_FILE_PATH)

func log(message: String) -> void:
	# Выводим в консоль
	print(message)
	
	# Записываем в файл
	if log_file != null and log_file.is_open():
		var time_dict: Dictionary = Time.get_datetime_dict_from_system()
		var time_str: String = "%02d:%02d:%02d.%03d" % [
			time_dict.hour,
			time_dict.minute,
			time_dict.second,
			Time.get_ticks_msec() % 1000
		]
		log_file.store_string("[%s] %s\n" % [time_str, message])
		log_file.flush()  # Сразу записываем на диск

func _exit_tree() -> void:
	# Закрываем файл при выходе
	if log_file != null:
		if log_file.is_open():
			log_file.store_string("\n--- КОНЕЦ СЕССИИ ---\n\n")
			log_file.flush()
		log_file.close()
		log_file = null
