extends Node
## Автозагрузка: Firebase Auth через REST (signInWithIdp / refresh). Google ID token → GameState.
## Ключ: сначала `user://firebase_web_config.json`, иначе `res://config/firebase_web_config.json` (файл в репо не коммитить — см. .gitignore). Шаблон: `res://config/firebase_web_config.example.json`.

signal login_succeeded
signal login_failed(message: String)
signal logout_done

const CONFIG_USER: String = "user://firebase_web_config.json"
const CONFIG_RES: String = "res://config/firebase_web_config.json"

var _http: HTTPRequest
var _web_api_key: String = ""
var _rtdb_url: String = "https://endlessrunnerayo-default-rtdb.europe-west1.firebasedatabase.app"
var _request_uri: String = "http://localhost"
var _busy: bool = false

var _dev_window: Window = null


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_load_config()
	call_deferred("_try_restore_session")


func _log(msg: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("write_log"):
		fl.call("write_log", "[AUTHSERVICE] " + msg)
	else:
		print("[AUTHSERVICE] ", msg)


func _load_config() -> void:
	_web_api_key = ""
	var path: String = ""
	if FileAccess.file_exists(CONFIG_USER):
		path = CONFIG_USER
	elif FileAccess.file_exists(CONFIG_RES):
		path = CONFIG_RES
	else:
		_log("config missing: %s or %s (copy from res://config/firebase_web_config.example.json)" % [CONFIG_RES, CONFIG_USER])
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		_log("config open failed: %s" % path)
		return
	var txt: String = f.get_as_text()
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		_log("config invalid JSON: %s" % path)
		return
	var d: Dictionary = data as Dictionary
	_web_api_key = str(d.get("web_api_key", "")).strip_edges()
	_rtdb_url = str(d.get("rtdb_url", _rtdb_url)).strip_edges().trim_suffix("/")
	_request_uri = str(d.get("auth_request_uri", _request_uri)).strip_edges()
	if _web_api_key.is_empty() or _is_placeholder_web_api_key(_web_api_key):
		_web_api_key = ""
		_log("web_api_key missing or placeholder in %s — вставьте ключ из Firebase → Project settings → Web API key" % path)


func is_configured() -> bool:
	return not _web_api_key.is_empty()


func is_signed_in() -> bool:
	return GameState.player_uid.strip_edges() != "" and GameState.auth_token.strip_edges() != ""


func get_auth_status_line() -> String:
	if not is_configured():
		return "Google: config/firebase_web_config.json или user://… (см. firebase_web_config.example.json)"
	if not is_signed_in():
		return "Google: не выполнен вход"
	var em: String = GameState.auth_email.strip_edges()
	if em != "":
		return "Google: %s" % em
	return "Google: uid %s…" % GameState.player_uid.substr(0, mini(8, GameState.player_uid.length()))


## Старт сценария входа: Android — сообщение про плагин; ПК — окно ввода id_token только в debug.
func start_google_sign_in_ui(parent_ui: Control) -> void:
	if not is_configured():
		login_failed.emit("Нет web_api_key. Скопируйте config/firebase_web_config.example.json → config/firebase_web_config.json и вставьте ключ из Firebase (Web API key).")
		return
	if OS.get_name() == "Android":
		login_failed.emit("Android: нужен нативный Google Sign-In → см. addons/android_google_signin/README.md")
		return
	if not OS.is_debug_build():
		login_failed.emit("Вход с ПК: только отладочная сборка или реализуйте OAuth в браузере.")
		return
	_open_dev_id_token_window(parent_ui)


## Вызов из будущего Android-плагина после получения Google id_token.
func sign_in_with_google_id_token(google_id_token: String) -> void:
	var tok: String = google_id_token.strip_edges()
	if tok.is_empty():
		login_failed.emit("Пустой Google id_token")
		return
	if not is_configured():
		login_failed.emit("Нет конфигурации Firebase (web_api_key)")
		return
	if _busy:
		login_failed.emit("Запрос уже выполняется")
		return
	_busy = true
	var url: String = FirebaseGoogleAuth.URL_SIGN_IN_IDP % _web_api_key
	var body: Dictionary = FirebaseGoogleAuth.sign_in_with_idp_body(tok, _request_uri)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_busy = false
		login_failed.emit("HTTP schedule err=%d" % err)
		return
	var args: Array = await _http.request_completed
	_busy = false
	var result: int = args[0]
	var code: int = args[1]
	var body_bytes: PackedByteArray = args[3]
	var text: String = body_bytes.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		login_failed.emit("network result=%d" % result)
		return
	var parsed: Dictionary = FirebaseGoogleAuth.parse_sign_in_response(text)
	if parsed.has("error"):
		login_failed.emit(str(parsed["error"]))
		return
	if code < 200 or code >= 300:
		login_failed.emit("http=%d" % code)
		return
	_apply_firebase_session(parsed)
	_log("login ok uid=%s email=%s" % [GameState.player_uid, GameState.auth_email])
	await _rtdb_auth_heartbeat()
	login_succeeded.emit()


func sign_out() -> void:
	GameState.player_uid = ""
	GameState.auth_provider = ""
	GameState.auth_token = ""
	GameState.auth_email = ""
	GameState.firebase_refresh_token = ""
	GameState.firebase_token_saved_at_unix = 0
	GameState.save_scores()
	_log("signed out")
	logout_done.emit()


func _try_restore_session() -> void:
	if not is_configured():
		return
	var rt: String = GameState.firebase_refresh_token.strip_edges()
	if rt.is_empty():
		return
	if _busy:
		return
	_busy = true
	var url: String = FirebaseGoogleAuth.URL_REFRESH % _web_api_key
	var form: String = FirebaseGoogleAuth.refresh_token_form_body(rt)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/x-www-form-urlencoded"])
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, form)
	if err != OK:
		_busy = false
		return
	var args: Array = await _http.request_completed
	_busy = false
	var result: int = args[0]
	var code: int = args[1]
	var body_bytes: PackedByteArray = args[3]
	var text: String = body_bytes.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return
	var parsed: Dictionary = FirebaseGoogleAuth.parse_refresh_response(text)
	if not parsed.get("ok", false):
		return
	var new_id: String = str(parsed.get("id_token", ""))
	var new_rt: String = str(parsed.get("refresh_token", ""))
	if new_id.is_empty():
		return
	GameState.auth_token = new_id
	if not new_rt.is_empty():
		GameState.firebase_refresh_token = new_rt
	GameState.firebase_token_saved_at_unix = Time.get_unix_time_from_system()
	GameState.save_scores()
	_log("session restored from refresh_token")
	login_succeeded.emit()


func _apply_firebase_session(parsed: Dictionary) -> void:
	GameState.player_uid = str(parsed.get("local_id", ""))
	GameState.auth_token = str(parsed.get("id_token", ""))
	GameState.firebase_refresh_token = str(parsed.get("refresh_token", ""))
	GameState.auth_email = str(parsed.get("email", ""))
	GameState.auth_provider = "google"
	GameState.firebase_token_saved_at_unix = Time.get_unix_time_from_system()
	GameState.save_scores()


func _rtdb_auth_heartbeat() -> void:
	var uid: String = GameState.player_uid.strip_edges()
	var id_tok: String = GameState.auth_token.strip_edges()
	if uid.is_empty() or id_tok.is_empty():
		return
	if _busy:
		return
	_busy = true
	var base: String = _rtdb_url.trim_suffix("/")
	var path: String = "%s/users/%s/auth_heartbeat.json?auth=%s" % [base, uid.uri_encode(), id_tok.uri_encode()]
	var payload: String = JSON.stringify({"t": Time.get_unix_time_from_system()})
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var err: int = _http.request(path, headers, HTTPClient.METHOD_PUT, payload)
	if err != OK:
		_busy = false
		_log("rtdb heartbeat schedule err=%d" % err)
		return
	var args: Array = await _http.request_completed
	_busy = false
	var result: int = args[0]
	var code: int = args[1]
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		_log("rtdb heartbeat failed http=%d" % code)
	else:
		_log("rtdb heartbeat ok")


func _open_dev_id_token_window(parent_ui: Control) -> void:
	if _dev_window != null and is_instance_valid(_dev_window):
		_dev_window.show()
		_dev_window.grab_focus()
		return
	var w: Window = Window.new()
	w.title = "Google ID token (dev only)"
	w.size = Vector2i(520, 200)
	w.unresizable = true
	w.close_requested.connect(func() -> void: w.hide())
	var vb: VBoxContainer = VBoxContainer.new()
	w.add_child(vb)
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 8
	vb.offset_top = 8
	vb.offset_right = -8
	vb.offset_bottom = -8
	var hint: Label = Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = "Вставьте Google id_token (JWT) из отладочного OAuth. Не для релиза. Токен не логируется целиком."
	vb.add_child(hint)
	var le: LineEdit = LineEdit.new()
	le.secret = true
	le.placeholder_text = "id_token…"
	vb.add_child(le)
	var hb: HBoxContainer = HBoxContainer.new()
	vb.add_child(hb)
	var btn_ok: Button = Button.new()
	btn_ok.text = "Войти"
	btn_ok.pressed.connect(func() -> void:
		var raw: String = le.text.strip_edges()
		if raw.is_empty():
			return
		w.hide()
		sign_in_with_google_id_token(raw)
	)
	hb.add_child(btn_ok)
	var btn_x: Button = Button.new()
	btn_x.text = "Отмена"
	btn_x.pressed.connect(func() -> void: w.hide())
	hb.add_child(btn_x)
	parent_ui.add_child(w)
	w.popup_centered()
	_dev_window = w


func _is_placeholder_web_api_key(k: String) -> bool:
	var s: String = k.strip_edges()
	if s.is_empty():
		return true
	if s.begins_with("PASTE_"):
		return true
	if s.findn("FROM_FIREBASE_PROJECT_SETTINGS") != -1:
		return true
	return false
