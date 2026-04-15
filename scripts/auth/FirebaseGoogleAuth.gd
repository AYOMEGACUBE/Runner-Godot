extends RefCounted
class_name FirebaseGoogleAuth
## REST-вызовы Firebase Auth (Identity Toolkit / securetoken). Google ID token → Firebase session.

const URL_SIGN_IN_IDP: String = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=%s"
const URL_REFRESH: String = "https://securetoken.googleapis.com/v1/token?key=%s"


static func sign_in_with_idp_body(google_id_token: String, request_uri: String) -> Dictionary:
	var enc: String = _uri_component_encode(google_id_token)
	return {
		"postBody": "id_token=%s&providerId=google.com" % enc,
		"requestUri": request_uri,
		"returnSecureToken": true,
		"returnIdpCredential": true,
	}


static func refresh_token_form_body(refresh_token: String) -> String:
	return "grant_type=refresh_token&refresh_token=%s" % _uri_component_encode(refresh_token)


static func parse_sign_in_response(json_text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"error": "invalid_json"}
	var d: Dictionary = data as Dictionary
	if d.has("error"):
		var err: Dictionary = d["error"] as Dictionary if typeof(d["error"]) == TYPE_DICTIONARY else {}
		var msg: String = str(err.get("message", str(d["error"])))
		return {"error": msg}
	return {
		"ok": true,
		"local_id": str(d.get("localId", "")),
		"id_token": str(d.get("idToken", "")),
		"refresh_token": str(d.get("refreshToken", "")),
		"email": str(d.get("email", "")),
		# Identity Toolkit / Google: имя (displayName или fullName)
		"display_name": _extract_display_name(d),
		"expires_in": str(d.get("expiresIn", "")),
	}


static func parse_refresh_response(json_text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"error": "invalid_json"}
	var d: Dictionary = data as Dictionary
	if d.has("error"):
		var er: Variant = d["error"]
		if typeof(er) == TYPE_DICTIONARY:
			var ed: Dictionary = er as Dictionary
			return {"error": str(ed.get("message", "refresh_failed"))}
		return {"error": str(er)}
	return {
		"ok": true,
		"id_token": str(d.get("id_token", "")),
		"refresh_token": str(d.get("refresh_token", "")),
		"expires_in": str(d.get("expires_in", "")),
	}


static func _extract_display_name(d: Dictionary) -> String:
	var dn: String = str(d.get("displayName", d.get("display_name", ""))).strip_edges()
	if dn.is_empty():
		dn = str(d.get("fullName", d.get("full_name", ""))).strip_edges()
	return dn


static func _uri_component_encode(s: String) -> String:
	return s.uri_encode()
