extends Control
# ============================================================================
# Profile.gd — отдельная сцена профиля игрока (nickname + выбор героя + кастом-аватар jump(0/1))
# ----------------------------------------------------------------------------
# ТРЕБОВАНИЕ (твое):
# ✅ Любая картинка, которую загружает ИГРОК (png/jpg/jpeg), должна в игре быть 64x64
#    БЕЗ ОБРЕЗКИ — только уменьшение/вписывание с сохранением пропорций.
#
# КАК ЭТО РЕШЕНО (без ломания твоей логики и без влияния на встроенных героев):
# 1) При выборе файла (jump0/jump1) мы загружаем Image из исходника (png/jpg/jpeg).
# 2) Вписываем в квадрат 64x64 (прозрачный фон), без обрезки.
# 3) Сохраняем в user://avatars/custom_jump_up.png и custom_jump_down.png.
# 4) GameState пути оставляем как у тебя (ничего не ломаем).
#
# ВАЖНО:
# - Встроенные спрайты героев (которые ты задаёшь в инспекторе) НЕ трогаем.
# - Меняем ТОЛЬКО то, что загрузил игрок.
# ============================================================================

@export_file("*.tscn")
var main_menu_scene: String = "res://MainMenu.tscn"

@onready var nickname_edit: LineEdit = $CenterContainer/Panel/VBoxContainer/NicknameEdit
@onready var save_button: Button = $CenterContainer/Panel/VBoxContainer/ButtonsRow/SaveButton
@onready var back_button: Button = $CenterContainer/Panel/VBoxContainer/ButtonsRow/BackButton

@onready var hero_left_button: Button = $CenterContainer/Panel/VBoxContainer/HeroSelector/HeroLeftButton
@onready var hero_right_button: Button = $CenterContainer/Panel/VBoxContainer/HeroSelector/HeroRightButton
@onready var hero_preview: TextureRect = $CenterContainer/Panel/VBoxContainer/HeroSelector/HeroPreview
@onready var hero_name_label: Label = $CenterContainer/Panel/VBoxContainer/HeroSelector/HeroNameLabel

@onready var custom_avatar_check: CheckBox = $CenterContainer/Panel/VBoxContainer/CustomAvatarRow/CustomAvatarCheck
@onready var wall_breathing_check: CheckBox = $CenterContainer/Panel/VBoxContainer/WallBreathingCheck
@onready var upload_jump_up_button: Button = $CenterContainer/Panel/VBoxContainer/CustomAvatarRow/UploadJumpUpButton
@onready var upload_jump_down_button: Button = $CenterContainer/Panel/VBoxContainer/CustomAvatarRow/UploadJumpDownButton

@onready var file_dialog_jump_up: FileDialog = $FileDialogJumpUp
@onready var file_dialog_jump_down: FileDialog = $FileDialogJumpDown

@onready var warn_dialog: AcceptDialog = $WarnDialog

const HEROES: Array = [
	{"id": "default", "name": "Runner AYO", "preview_png": "res://heroes/hero_default.png"},
	{"id": "monster", "name": "Monster",    "preview_png": "res://heroes/hero_monster.png"},
	{"id": "red",     "name": "Red",        "preview_png": "res://heroes/hero_red.png"},
	{"id": "blue", "name": "Blue",   	 	"preview_png": "res://heroes/hero_blue.png"},
	{"id": "orange", "name": "Orange",  	"preview_png": "res://heroes/hero_orange.png"}
]

const AVATAR_DIR: String = "user://avatars"
const AVATAR_UP_PNG: String = "user://avatars/custom_jump_up.png"
const AVATAR_DOWN_PNG: String = "user://avatars/custom_jump_down.png"

# Целевой размер пользовательских аватарок (то, что загрузил игрок)
const AVATAR_TARGET_SIZE_PX: int = 64

var _hero_index: int = 0

func _ready() -> void:
	# --- nickname ---
	if nickname_edit:
		nickname_edit.text = GameState.get_nickname()
		nickname_edit.grab_focus()

	# --- buttons ---
	if save_button and not save_button.pressed.is_connected(_on_save_pressed):
		save_button.pressed.connect(_on_save_pressed)

	if back_button and not back_button.pressed.is_connected(_on_back_pressed):
		back_button.pressed.connect(_on_back_pressed)

	# --- heroes ---
	if hero_left_button and not hero_left_button.pressed.is_connected(_on_hero_left_pressed):
		hero_left_button.pressed.connect(_on_hero_left_pressed)

	if hero_right_button and not hero_right_button.pressed.is_connected(_on_hero_right_pressed):
		hero_right_button.pressed.connect(_on_hero_right_pressed)

	var saved_id: String = str(GameState.get_selected_hero_id())
	_hero_index = _find_hero_index_by_id(saved_id)
	_apply_hero_to_ui()

	# --- custom avatar ---
	if custom_avatar_check:
		custom_avatar_check.button_pressed = bool(GameState.get_use_custom_avatar())
		if not custom_avatar_check.toggled.is_connected(_on_custom_avatar_toggled):
			custom_avatar_check.toggled.connect(_on_custom_avatar_toggled)

	if wall_breathing_check:
		wall_breathing_check.button_pressed = bool(GameState.get_wall_breathing_enabled())
		if not wall_breathing_check.toggled.is_connected(_on_wall_breathing_toggled):
			wall_breathing_check.toggled.connect(_on_wall_breathing_toggled)

	if upload_jump_up_button and not upload_jump_up_button.pressed.is_connected(_on_upload_jump_up_pressed):
		upload_jump_up_button.pressed.connect(_on_upload_jump_up_pressed)

	if upload_jump_down_button and not upload_jump_down_button.pressed.is_connected(_on_upload_jump_down_pressed):
		upload_jump_down_button.pressed.connect(_on_upload_jump_down_pressed)

	# dialogs signals
	if file_dialog_jump_up and not file_dialog_jump_up.file_selected.is_connected(_on_jump_up_file_selected):
		file_dialog_jump_up.file_selected.connect(_on_jump_up_file_selected)

	if file_dialog_jump_down and not file_dialog_jump_down.file_selected.is_connected(_on_jump_down_file_selected):
		file_dialog_jump_down.file_selected.connect(_on_jump_down_file_selected)

	# Desktop: native dialog (Windows/macOS/Linux)
	# Примечание: на Android/iOS может быть не fully-native без плагина — это нормально.
	if file_dialog_jump_up:
		file_dialog_jump_up.use_native_dialog = true
	if file_dialog_jump_down:
		file_dialog_jump_down.use_native_dialog = true

	_update_custom_avatar_buttons_state()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_back_pressed()

# ---------------- HERO SELECTOR ----------------

func _find_hero_index_by_id(id: String) -> int:
	var clean_id: String = id.strip_edges()
	if clean_id == "":
		return 0
	for i in range(HEROES.size()):
		var h = HEROES[i]
		if typeof(h) == TYPE_DICTIONARY and str(h.get("id", "")) == clean_id:
			return int(i)
	return 0

func _apply_hero_to_ui() -> void:
	if HEROES.is_empty():
		return

	if _hero_index < 0:
		_hero_index = HEROES.size() - 1
	if _hero_index >= HEROES.size():
		_hero_index = 0

	var hero = HEROES[_hero_index]
	if typeof(hero) != TYPE_DICTIONARY:
		return

	var hero_display_name: String = str(hero.get("name", "Hero"))
	if hero_name_label:
		hero_name_label.text = hero_display_name

	var preview_path: String = str(hero.get("preview_png", ""))
	if hero_preview:
		if preview_path != "" and ResourceLoader.exists(preview_path):
			var res := ResourceLoader.load(preview_path, "", ResourceLoader.CACHE_MODE_REPLACE)
			if res is Texture2D:
				hero_preview.texture = res

func _save_current_hero_to_gamestate() -> void:
	if HEROES.is_empty():
		return
	var hero = HEROES[_hero_index]
	if typeof(hero) != TYPE_DICTIONARY:
		return

	var hero_id: String = str(hero.get("id", "default")).strip_edges()
	if hero_id == "":
		hero_id = "default"

	GameState.set_selected_hero_id(hero_id)

func _on_hero_left_pressed() -> void:
	_hero_index -= 1
	if _hero_index < 0:
		_hero_index = HEROES.size() - 1
	_apply_hero_to_ui()
	_save_current_hero_to_gamestate()

func _on_hero_right_pressed() -> void:
	_hero_index += 1
	if _hero_index >= HEROES.size():
		_hero_index = 0
	_apply_hero_to_ui()
	_save_current_hero_to_gamestate()

# ---------------- CUSTOM AVATAR ----------------

func _on_custom_avatar_toggled(pressed: bool) -> void:
	GameState.set_use_custom_avatar(pressed)
	_update_custom_avatar_buttons_state()

func _on_wall_breathing_toggled(pressed: bool) -> void:
	GameState.set_wall_breathing_enabled(pressed)

func _update_custom_avatar_buttons_state() -> void:
	var enabled := custom_avatar_check != null and custom_avatar_check.button_pressed

	if upload_jump_up_button:
		upload_jump_up_button.disabled = not enabled
	if upload_jump_down_button:
		upload_jump_down_button.disabled = not enabled

func _on_upload_jump_up_pressed() -> void:
	if file_dialog_jump_up:
		file_dialog_jump_up.popup_centered_ratio(0.85)

func _on_upload_jump_down_pressed() -> void:
	if file_dialog_jump_down:
		file_dialog_jump_down.popup_centered_ratio(0.85)

func _ensure_user_avatar_dir() -> void:
	# Создаём user://avatars если его нет
	if not DirAccess.dir_exists_absolute(AVATAR_DIR):
		var mk_err: int = DirAccess.make_dir_recursive_absolute(AVATAR_DIR)
		if mk_err != OK:
			push_warning("Profile.gd: не удалось создать папку: " + AVATAR_DIR + " err=" + str(mk_err))

func _import_image_as_png_to_user(source_path: String, target_user_png_path: String) -> bool:
	# Ключевая логика:
	# 1) грузим картинку (png/jpg/jpeg)
	# 2) вписываем в квадрат 64x64 без обрезки
	# 3) сохраняем как PNG в user://avatars/...
	_ensure_user_avatar_dir()

	var img: Image = Image.new()
	var err_load: int = img.load(source_path)
	if err_load != OK:
		push_warning("Profile.gd: не удалось загрузить изображение: " + source_path + " err=" + str(err_load))
		return false

	# Приводим к RGBA8 (для корректной работы с прозрачностью/ресайзом)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)

	# Вписываем в 64x64 (прозрачные поля по бокам/сверху если нужно)
	var fitted: Image = _fit_image_into_square(img, AVATAR_TARGET_SIZE_PX)

	# Сохраняем уже НОРМАЛЬНЫЙ PNG (и всегда 64x64)
	var err_save: int = fitted.save_png(target_user_png_path)
	if err_save != OK:
		push_warning("Profile.gd: не удалось сохранить PNG в: " + target_user_png_path + " err=" + str(err_save))
		return false

	return true

func _on_jump_up_file_selected(path: String) -> void:
	var ok := _import_image_as_png_to_user(path, AVATAR_UP_PNG)
	if ok:
		GameState.set_custom_avatar_paths(AVATAR_UP_PNG, GameState.get_custom_avatar_down_path())
	else:
		_show_warn("Не удалось загрузить jump(0). Попробуй PNG/JPG/JPEG без повреждений.")

func _on_jump_down_file_selected(path: String) -> void:
	var ok := _import_image_as_png_to_user(path, AVATAR_DOWN_PNG)
	if ok:
		GameState.set_custom_avatar_paths(GameState.get_custom_avatar_up_path(), AVATAR_DOWN_PNG)
	else:
		_show_warn("Не удалось загрузить jump(1). Попробуй PNG/JPG/JPEG без повреждений.")

# ---------------- SAVE / BACK ----------------

func _on_save_pressed() -> void:
	var nick := ""
	if nickname_edit:
		nick = nickname_edit.text.strip_edges()

	if nick == "":
		_show_warn("Нужно заполнить никнейм!")
		return

	GameState.set_nickname(nick)
	_save_current_hero_to_gamestate()

	# сохраняем переключатель «дыхание мира»
	if wall_breathing_check:
		GameState.set_wall_breathing_enabled(wall_breathing_check.button_pressed)

	# если пользователь включил кастом-аватар — проверим что файлы существуют
	if GameState.get_use_custom_avatar():
		var up_ok := FileAccess.file_exists(GameState.get_custom_avatar_up_path())
		var dn_ok := FileAccess.file_exists(GameState.get_custom_avatar_down_path())
		if not up_ok or not dn_ok:
			_show_warn("Кастом-аватар включён, но jump(0) или jump(1) не загружены.")
			return

	_on_back_pressed()

func _on_back_pressed() -> void:
	var err := get_tree().change_scene_to_file(main_menu_scene)
	if err != OK:
		push_error("Profile.gd: не удалось вернуться в меню: " + main_menu_scene)

func _show_warn(text: String) -> void:
	if warn_dialog:
		warn_dialog.dialog_text = text
		warn_dialog.popup_centered()
	else:
		push_warning("WARN: " + text)

# ---------------- IMAGE HELPERS ----------------

func _fit_image_into_square(src: Image, target_size: int) -> Image:
	# Вписываем изображение в квадрат target_size x target_size БЕЗ ОБРЕЗКИ.
	# - сохраняем пропорции
	# - добавляем прозрачные поля где нужно
	# - итог всегда ровно target_size x target_size
	var src_w: int = src.get_width()
	var src_h: int = src.get_height()

	if src_w <= 0 or src_h <= 0:
		return src

	var dst: Image = Image.create(target_size, target_size, false, Image.FORMAT_RGBA8)
	dst.fill(Color(0, 0, 0, 0))

	# Работаем с копией, чтобы не портить исходный Image
	var resized: Image = src.duplicate()
	if resized.get_format() != Image.FORMAT_RGBA8:
		resized.convert(Image.FORMAT_RGBA8)

	# Масштаб "вписать"
	var scale: float = minf(float(target_size) / float(src_w), float(target_size) / float(src_h))

	# Даже если картинка маленькая — всё равно приведём к предсказуемому размеру (64x64)
	var new_w: int = maxi(1, int(round(float(src_w) * scale)))
	var new_h: int = maxi(1, int(round(float(src_h) * scale)))

	resized.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)

	# Центрируем
	var x: int = int((target_size - new_w) / 2)
	var y: int = int((target_size - new_h) / 2)

	dst.blit_rect(resized, Rect2i(0, 0, new_w, new_h), Vector2i(x, y))
	return dst
