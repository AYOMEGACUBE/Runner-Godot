extends RefCounted
class_name BrandConfig

# One-line switching per side:
# 0 = default, 1 = CocaCola, 2 = Pepsi, 3+ = reserved
const ACTIVE_SIDE_1_BRAND: int = 0
const ACTIVE_SIDE_2_BRAND: int = 0
const ACTIVE_SIDE_3_BRAND: int = 0
const ACTIVE_SIDE_4_BRAND: int = 0
const ACTIVE_SIDE_5_BRAND: int = 0
const ACTIVE_SIDE_6_BRAND: int = 0

static func get_active_brand_for_side(side_id: int) -> int:
	match side_id:
		1: return ACTIVE_SIDE_1_BRAND
		2: return ACTIVE_SIDE_2_BRAND
		3: return ACTIVE_SIDE_3_BRAND
		4: return ACTIVE_SIDE_4_BRAND
		5: return ACTIVE_SIDE_5_BRAND
		6: return ACTIVE_SIDE_6_BRAND
		_: return 0
