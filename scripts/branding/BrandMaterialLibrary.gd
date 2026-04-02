extends RefCounted
class_name BrandMaterialLibrary

static func get_color(material_key: String, fallback: Color = Color(0.0, 0.8, 0.7)) -> Color:
	match material_key:
		"brand_cocacola":
			return Color(0.82, 0.10, 0.12)
		"brand_pepsi":
			return Color(0.12, 0.22, 0.82)
		"brand_default":
			return Color(0.0, 0.8, 0.7)
		_:
			return fallback
