extends Node
## Autoload: узел `FileLogger`. По умолчанию пишет в `res://3301_LOG.txt` (файл в корне проекта).
## В экспортированной сборке запись в res:// недоступна — тогда используется user://3301_LOG.txt.
## При каждом запуске игры файл **очищается** (новая сессия); дальше записи идут подряд в тот же открытый файл.

const ENABLE_LOGGER := true
const LOG_FILE_PATH_PROJECT: String = "res://3301_LOG.txt"
const LOG_FILE_PATH_FALLBACK: String = "user://3301_LOG.txt"

var _file: FileAccess = null
var _flush_accumulator := 0.0
var _using_fallback: bool = false
## Путь активного лог-файла (после успешного старта сессии).
var _active_log_path: String = ""
## Одна очистка + заголовок на запуск приложения.
var _session_started: bool = false

func _ready() -> void:
	if not ENABLE_LOGGER:
		set_process(false)
		return
	_start_new_session()
	if _file == null:
		push_error("FileLogger: cannot open log file")
		return
	write_log("[FILELOGGER] active_path=%s" % ProjectSettings.globalize_path(_active_log_path))
	_file.flush()

func _start_new_session() -> void:
	if _session_started:
		return
	_close_file_safely()
	_using_fallback = false
	_active_log_path = ""
	_file = FileAccess.open(LOG_FILE_PATH_PROJECT, FileAccess.WRITE)
	if _file != null:
		_active_log_path = LOG_FILE_PATH_PROJECT
	else:
		_using_fallback = true
		_ensure_parent_dir(LOG_FILE_PATH_FALLBACK)
		_file = FileAccess.open(LOG_FILE_PATH_FALLBACK, FileAccess.WRITE)
		if _file != null:
			_active_log_path = LOG_FILE_PATH_FALLBACK
		else:
			_using_fallback = false
			return
	# Файл открыт в режиме WRITE — старое содержимое удалено; пишем заголовок сессии
	_file.store_string("\n=== NEW SESSION ===\n")
	_file.flush()
	_session_started = true

func _ensure_parent_dir(path: String) -> void:
	var dir_path: String = path.get_base_dir()
	if dir_path.is_empty() or dir_path == ".":
		return
	if DirAccess.dir_exists_absolute(dir_path):
		return
	var err: Error = DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK:
		push_warning("FileLogger: cannot create dir %s err=%s" % [dir_path, str(err)])

func _close_file_safely() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null

func _reopen_for_append_if_needed() -> void:
	if _file != null or _active_log_path.is_empty():
		return
	_file = FileAccess.open(_active_log_path, FileAccess.READ_WRITE)
	if _file == null:
		return
	_file.seek_end()

func write_log(message: String) -> void:
	if not ENABLE_LOGGER:
		return
	if _file == null:
		_reopen_for_append_if_needed()
	if _file == null:
		return
	var t := Time.get_datetime_dict_from_system()
	var stamp: String = "%02d:%02d:%02d" % [t.hour, t.minute, t.second]
	var line: String = "[%s] %s\n" % [stamp, message]
	_file.store_string(line)

func info(message: String) -> void:
	write_log("[INFO] %s" % message)

func warn(message: String) -> void:
	write_log("[WARN] %s" % message)

func error(message: String) -> void:
	write_log("[ERROR] %s" % message)

func _process(_delta: float) -> void:
	if not ENABLE_LOGGER or _file == null:
		return
	_flush_accumulator += _delta
	if _flush_accumulator >= 2.0:
		_file.flush()
		_flush_accumulator = 0.0

func _exit_tree() -> void:
	_close_file_safely()
