extends Node
## Подписка на EconomyManager: показ цены в тултипе. Autoload: UIManager

var _tooltip_root: CanvasLayer = null
var _tooltip_label: Label = null


func _ready() -> void:
	if not EconomyManager.economy_price_calculated.is_connected(_on_economy_price):
		EconomyManager.economy_price_calculated.connect(_on_economy_price)
	var ps: PackedScene = load("res://assets/ui/price_tooltip.tscn") as PackedScene
	if ps == null:
		push_warning("UIManager: price_tooltip.tscn missing")
		return
	_tooltip_root = ps.instantiate() as CanvasLayer
	if _tooltip_root == null:
		return
	get_tree().root.add_child(_tooltip_root)
	_tooltip_root.hide()
	_tooltip_label = _tooltip_root.find_child("PriceLabel", true, false) as Label


func _on_economy_price(price: int, side_external: int, is_owned: bool, _face_id: int, _segment_id: String) -> void:
	if _tooltip_label == null:
		_tooltip_label = _tooltip_root.find_child("PriceLabel", true, false) as Label if _tooltip_root else null
	if _tooltip_label == null:
		return
	## [FIX] Явный текст для Free-сторон (перекупка из economy.json)
	var buyout: int = EconomyManager.get_buyout_free_coin()
	if is_owned and price == 0:
		_tooltip_label.text = "Сторона #%d — ваш регион / куплено (0 coin)" % side_external
	elif price == 0 and EconomyManager.is_side_external_free(side_external):
		_tooltip_label.text = "Сторона #%d — FREE (перекупка %d coin)" % [side_external, buyout]
	elif price == 0:
		_tooltip_label.text = "Сторона #%d — 0 coin" % side_external
	else:
		var usd: float = float(price) * EconomyManager.get_coin_to_usd()
		_tooltip_label.text = "Сторона #%d — %d coin (~$%.2f)" % [side_external, price, usd]
	if _tooltip_root:
		_tooltip_root.show()
		call_deferred("_move_tooltip_to_mouse")


func _move_tooltip_to_mouse() -> void:
	if _tooltip_root == null:
		return
	var panel: Control = _tooltip_root.get_child(0) as Control
	if panel == null:
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var p: Vector2 = vp.get_mouse_position()
	panel.global_position = p + Vector2(12, 12)
