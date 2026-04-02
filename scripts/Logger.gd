extends Node
## Autoload: узел `FileLogger`. По умолчанию пишет в `res://3301_LOG.txt` (файл в корне проекта).
## В экспортированной сборке запись в res:// недоступна — тогда используется user://3301_LOG.txt.

const ENABLE_LOGGER := true
const LOG_FILE_PATH_PROJECT: String = "res://3301_LOG.txt"
const LOG_FILE_PATH_FALLBACK: String = "user://3301_LOG.txt"

var _file: FileAccess = null
var _flush_accumulator := 0.0
var _using_fallback: bool = false

func _ready() -> void:
	if not ENABLE_LOGGER:
		set_process(false)
		return
	_open_file()
	if _file == null:
		push_error("FileLogger: cannot open log file")
		return
	_file.store_string("\n=== NEW SESSION ===\n")
	_file.flush()
	var path_shown: String = LOG_FILE_PATH_FALLBACK if _using_fallback else LOG_FILE_PATH_PROJECT
	var abs_path: String = ProjectSettings.globalize_path(path_shown)
	write_log("[FILELOGGER] active_path=%s" % abs_path)
	_file.flush()

func write_log(message: String) -> void:
	if not ENABLE_LOGGER:
		return
	if _file == null:
		_open_file()
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

func _process(delta: float) -> void:
	if not ENABLE_LOGGER or _file == null:
		return
	_flush_accumulator += delta
	if _flush_accumulator >= 2.0:
		_file.flush()
		_flush_accumulator = 0.0

func _exit_tree() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null

func _try_open_append(path: String) -> bool:
	if FileAccess.file_exists(path):
		_file = FileAccess.open(path, FileAccess.READ_WRITE)
		if _file == null:
			return false
		_file.seek_end()
		return true
	var created: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if created == null:
		return false
	created.close()
	_file = FileAccess.open(path, FileAccess.READ_WRITE)
	if _file == null:
		return false
	_file.seek_end()
	return true

func _open_file() -> void:
	_file = null
	_using_fallback = false
	if _try_open_append(LOG_FILE_PATH_PROJECT):
		return
	_using_fallback = true
	push_warning(
		"FileLogger: cannot write to %s (expected in exported builds); using %s"
		% [LOG_FILE_PATH_PROJECT, LOG_FILE_PATH_FALLBACK]
	)
	if not _try_open_append(LOG_FILE_PATH_FALLBACK):
		_file = null
		_using_fallback = false
