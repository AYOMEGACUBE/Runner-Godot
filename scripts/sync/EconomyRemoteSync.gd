extends Node
## Синхронизация кошелька `GameState.wallet_coins` с Firebase RTDB под `users/<uid>/wallet`.
## Децентрализация: локальный `user://` остаётся источником офлайн; при входе — merge по timestamp `t`
## (более новая версия с сервера заменяет локальную, иначе отправляем локальную).
## Ownership (сегменты/платформы) синхронизируется через RTDB (`OwnershipRemoteSync`).

var _http: HTTPRequest
var _op: String = ""
var _push_t: int = 0


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	if not AuthService.login_succeeded.is_connected(_on_login_succeeded):
		AuthService.login_succeeded.connect(_on_login_succeeded)


func _on_login_succeeded() -> void:
	call_deferred("pull_wallet_then_merge")


func request_push_wallet() -> void:
	if not AuthService.is_signed_in():
		return
	if _op != "":
		return
	_start_push()


func pull_wallet_then_merge() -> void:
	if not AuthService.is_signed_in():
		return
	if _op != "":
		return
	var uid: String = GameState.player_uid.strip_edges()
	var tok: String = GameState.auth_token.strip_edges()
	if uid.is_empty() or tok.is_empty():
		return
	var base: String = AuthService.get_rtdb_base_url()
	if base.is_empty():
		return
	_op = "pull"
	var url: String = "%s/users/%s/wallet.json?auth=%s" % [base, uid.uri_encode(), tok.uri_encode()]
	var err: int = _http.request(url, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		_log("pull schedule err=%d" % err)
		_op = ""


func _start_push() -> void:
	var uid: String = GameState.player_uid.strip_edges()
	var tok: String = GameState.auth_token.strip_edges()
	if uid.is_empty() or tok.is_empty():
		return
	var base: String = AuthService.get_rtdb_base_url()
	if base.is_empty():
		return
	_push_t = int(Time.get_unix_time_from_system())
	var payload: String = JSON.stringify({"coins": GameState.wallet_coins, "t": _push_t})
	var url: String = "%s/users/%s/wallet.json?auth=%s" % [base, uid.uri_encode(), tok.uri_encode()]
	var hdrs: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	_op = "push"
	var err: int = _http.request(url, hdrs, HTTPClient.METHOD_PUT, payload)
	if err != OK:
		_log("push schedule err=%d" % err)
		_op = ""


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var op: String = _op
	_op = ""
	var text: String = body.get_string_from_utf8().strip_edges()
	if result != HTTPRequest.RESULT_SUCCESS:
		_log("%s failed result=%d" % [op, result])
		return
	if response_code < 200 or response_code >= 300:
		_log("%s bad http=%d body=%s" % [op, response_code, text.substr(0, mini(120, text.length()))])
		return
	if op == "pull":
		_apply_pull_body(text)
	elif op == "push":
		if response_code >= 200 and response_code < 300:
			GameState.wallet_remote_mtime = _push_t
			GameState.save_scores()
			_log("push ok wallet=%d t=%d" % [GameState.wallet_coins, _push_t])


func _apply_pull_body(text: String) -> void:
	if text.is_empty() or text == "null":
		_log("pull: no remote wallet, pushing local")
		_start_push()
		return
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		_start_push()
		return
	var d: Dictionary = data as Dictionary
	var rcoins: int = int(d.get("coins", 0))
	var rt: int = int(d.get("t", 0))
	var local_mt: int = int(GameState.wallet_remote_mtime)
	if rt > local_mt:
		GameState.wallet_coins = rcoins
		GameState.wallet_remote_mtime = rt
		GameState.save_scores()
		_log("pull applied remote coins=%d t=%d" % [rcoins, rt])
	else:
		_log("pull: local newer or same (local_mt=%d rt=%d), push" % [local_mt, rt])
		_start_push()


func _log(msg: String) -> void:
	var fl: Node = get_node_or_null("/root/FileLogger")
	if fl != null and fl.has_method("write_log"):
		fl.call("write_log", "[EconomyRemoteSync] " + msg)
	else:
		print("[EconomyRemoteSync] ", msg)
