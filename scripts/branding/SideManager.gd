extends Node

const DEFAULT_BRAND_ID: int = 0

func get_brand_id_for_side(side_id: int) -> int:
	return BrandConfig.get_active_brand_for_side(side_id)

func get_material_key_for_side(side_id: int) -> String:
	var brand_id: int = get_brand_id_for_side(side_id)
	match brand_id:
		1:
			return "brand_cocacola"
		2:
			return "brand_pepsi"
		_:
			return "brand_default"
