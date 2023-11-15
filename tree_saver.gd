# tree_saver.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2017-2023 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield in the US
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
class_name IVTreeSaver
extends RefCounted

## Generates a compact game-save data structure from properties specified in
## object constants in a scene tree. Sets properties and rebuilds procedural
## parts of the scene tree on game load.
##
## IVTreeSaver can persist Godot built-in types (including arrays and
## dictionaries) and four kinds of 'persist' objects:[br][br]
##    
##    1. 'Non-procedural' Node - May have persist data but won't be freed on
##       game load.[br]
##    2. 'Procedural' Node - These will be freed and rebuilt on game load.[br]
##    3. 'Procedural' RefCounted - These will be freed and rebuilt on game load.[br]
##    4. WeakRef to any of above.[br][br]
##
## Arrays and dictionaries containing non-object data can be nested at any
## level of complexity (array types are also persisted). Arrays and
## dictionaries can contain 'persist' objects but must follow rules below
## under 'Special rules for persist objects'.[br][br]
##
## A Node or RefCounted is identified as a 'persist' object by the presence of
## any one of the following:[br][br]
##
##    [code]const PERSIST_MODE := IVTreeSaver.PERSIST_PROPERTIES_ONLY[/code][br]
##    [code]const PERSIST_MODE := IVTreeSaver.PERSIST_PROCEDURAL[/code][br]
##    [code]var persist_mode_override := [/code] <either of above two values>[br][br]
##
## Lists of properties to persist must be named in object constant arrays:[br][br]
##
##    [code]const PERSIST_PROPERTIES: Array[StringName] = [][/code][br]
##    [code]const PERSIST_PROPERTIES2: Array[StringName] = [][/code][br]
##    (List names can be modified in [IVSaveUtils] static array [code]persist_property_lists[/code].
##    The extra list is used by subclasses to add persist properties.)[br][br]
##
## During tree build, Nodes are generally instantiated as scripts: i.e., using
## [code]Script.new()[/code]. To instantiate a scene instead, the base Node's
## GDScript must have one of:[br][br]
##
##    [code]const SCENE := "<path to .tscn file>"[/code][br]
##    [code]const SCENE_OVERRIDE := "<path to .tscn file>"[/code] (Useful in a sublcass.)[br][br]
##
## Special rules for 'persist' objects:[br][br]
##
##    1. Objects cannot be deeply nested in containers. They can only be
##       elements of directly persisted arrays or keys or values of directly
##       persisted dictionaries. I.e., objects must be elements, keys or values
##       of containers listed in an object's persist constant list.[br]
##    2. Arrays containing persist objects must be typed as TYPE_OBJECT.[br]
##    3. Objects CAN be referenced in multiple places. Even circular references
##       are ok. However, code here can only null object properties listed in
##       'persist' constant arrays during tree deconstruction. Any other
##       references to these objects must be nulled by some other code.[br]
##    4. Nodes must be in the tree.[br]
##    5. All ancester nodes up to and including [code]save_root[/code] must also be persist
##       nodes.[br]
##    6. Non-procedural Nodes (i.e., [code]PERSIST_PROPERTIES_ONLY[/code]) cannot
##       have any ancestors that are [code]PERSIST_PROCEDURAL[/code].[br]
##    7. Non-procedural Nodes must have stable node path.[br]
##    8. Inner classes can't be persist objects.[br]
##    9. A persisted RefCounted can only be [code]PERSIST_PROCEDURAL[/code].[br]
##    10. Persist objects cannot have required args in their [code]_init()[/code]
##       method.[br][br]
##
## Warnings:[br][br]
##
##    1. Godot does not allow us to index arrays and dictionaries by reference rather
##       than content (see proposal #874 to fix this). Therefore, a single array
##       or dictionary persisted in two places (i.e., listed in [code]PERSIST_PROPERTIES[/code]
##       in two files) will become two separate arrays or dictionaries on load.
##       (This does not happen for Objects!)[br]


const DPRINT := false # set true for debug print

const OBJECT_ID_OFFSET := 10_000_000_000_000 # allows this many different persist values
const WEAKREF_ID_OFFSET := 2 * OBJECT_ID_OFFSET
const WEAKREF_NULL_ID := 3 * OBJECT_ID_OFFSET

# localized for convenience
const PersistMode := IVSaveUtils.PersistMode
const NO_PERSIST := PersistMode.NO_PERSIST
const PERSIST_PROPERTIES_ONLY := PersistMode.PERSIST_PROPERTIES_ONLY
const PERSIST_PROCEDURAL := PersistMode.PERSIST_PROCEDURAL


# localized
var _persist_property_lists: Array[StringName] = IVSaveUtils.persist_property_lists

# gamesave contents
# Note: FileAccess.store_var() & get_var() doesn't save or recover array type
# as of Godot 4.2.dev5. We can't type these arrays yet!
var _gamesave_n_objects := 0
var _gamesave_serialized_nodes := []
var _gamesave_serialized_refs := []
var _gamesave_indexed_values := []
var _gamesave_script_paths := []

# save processing
var _save_root: Node
var _path_ids := {} # indexed by script paths
var _object_ids := {} # indexed by objects
var _indexed_string_ids := {} # indexed by String values
var _indexed_nonstring_ids := {} # indexed by non-String values (incl StringName)

# load processing
var _scripts: Array[Script] = [] # indexed by script_id
var _objects: Array[Object] = [] # indexed by object_id



## Encodes the tree as a data array using object persist constants. 'save_root'
## may or may not be the main scene tree root. It must be a persist node itself
## with [code]const PERSIST_MODE = PERSIST_PROPERTIES_ONLY[/code].[br][br]
func get_gamesave(save_root: Node) -> Array:
	assert(_debug_assert_persist_object(save_root))
	assert(!_is_procedural_object(save_root), "save_root must be PERSIST_PROPERTIES_ONLY")
	_save_root = save_root
	assert(!DPRINT or _dprint("* Registering tree for gamesave *"))
	_index_tree(save_root)
	assert(!DPRINT or _dprint("* Serializing tree for gamesave *"))
	_serialize_tree(save_root)
	var gamesave := [
		_gamesave_n_objects,
		_gamesave_serialized_nodes,
		_gamesave_serialized_refs,
		_gamesave_indexed_values,
		_gamesave_script_paths,
		]
	print("Persist objects saved: ", _gamesave_n_objects, "; nodes in tree: ",
			save_root.get_tree().get_node_count())
	_reset()
	return gamesave


## Rebuilds the tree using using 'gamesave' data starting from 'save_root',
## which must be the same non-procedural persist node specified in
## [code]get_gamesave(save_root)[/code].[br][br]
##
## If building from an existing game, be sure to free the old procedural tree
## using [IVSaveUtils][code].free_all_procedural_objects()[/code] and then delay
## a few frames (we delay 6) before calling this function. Otherwise, old
## procedural objects are still alive and may respond to signals during the
## tree build.
func build_tree_from_gamesave(gamesave: Array, save_root: Node) -> void:
	# TODO: Recode to allow save_root to be a 'detatched' procedural node. In
	# this mode the function takes null for 2nd arg and returns save_root.
	_save_root = save_root
	_gamesave_n_objects = gamesave[0]
	_gamesave_serialized_nodes = gamesave[1]
	_gamesave_serialized_refs = gamesave[2]
	_gamesave_indexed_values = gamesave[3]
	_gamesave_script_paths = gamesave[4]
	_load_scripts()
	_locate_or_instantiate_objects(save_root)
	_deserialize_all_object_data()
	_build_procedural_tree()
	print("Persist objects loaded: ", _gamesave_n_objects)
	_reset()


func _reset() -> void:
	_gamesave_n_objects = 0
	_gamesave_serialized_nodes = []
	_gamesave_serialized_refs = []
	_gamesave_script_paths = []
	_gamesave_indexed_values = []
	_save_root = null
	_path_ids.clear()
	_object_ids.clear()
	_indexed_string_ids.clear()
	_indexed_nonstring_ids.clear()
	_objects.clear()
	_scripts.clear()


# Procedural save

func _index_tree(node: Node) -> void:
	# Make an object_id for all persist nodes by indexing in _object_ids.
	# Initial call is the save_root which must be a persist node itself.
	_object_ids[node] = _gamesave_n_objects
	_gamesave_n_objects += 1
	for child in node.get_children():
		if _is_persist_object(child):
			_index_tree(child)


func _serialize_tree(node: Node) -> void:
	_serialize_node(node)
	for child in node.get_children():
		if _is_persist_object(child):
			_serialize_tree(child)


# Procedural load

func _load_scripts() -> void:
	for script_path: String in _gamesave_script_paths:
		var script: Script = load(script_path)
		_scripts.append(script) # indexed by script_id


func _locate_or_instantiate_objects(save_root: Node) -> void:
	# Instantiates procecural objects (Node and RefCounted) without data.
	# Indexes root and all persist objects (procedural and non-procedural).
	assert(!DPRINT or _dprint("* Registering(/Instancing) Objects for Load *"))
	_objects.resize(_gamesave_n_objects)
	_objects[0] = save_root
	for serialized_node: Array in _gamesave_serialized_nodes:
		var object_id: int = serialized_node[0]
		var script_id: int = serialized_node[1]
		var node: Node
		if script_id == -1: # non-procedural node; find it
			var node_path: NodePath = serialized_node[2] # relative
			node = save_root.get_node(node_path)
			assert(!DPRINT or _dprint(object_id, node, node.name))
		else: # this is a procedural node
			var script: Script = _scripts[script_id]
			node = IVSaveUtils.make_object_or_scene(script)
			assert(!DPRINT or _dprint(object_id, node, script_id, _gamesave_script_paths[script_id]))
		assert(node)
		_objects[object_id] = node
	for serialized_ref: Array in _gamesave_serialized_refs:
		var object_id: int = serialized_ref[0]
		var script_id: int = serialized_ref[1]
		var script: Script = _scripts[script_id]
		@warning_ignore("unsafe_method_access")
		var ref: RefCounted = script.new()
		assert(ref)
		_objects[object_id] = ref
		assert(!DPRINT or _dprint(object_id, ref, script_id, _gamesave_script_paths[script_id]))


func _deserialize_all_object_data() -> void:
	assert(!DPRINT or _dprint("* Deserializing Objects for Load *"))
	for serialized_node: Array in _gamesave_serialized_nodes:
		_deserialize_object_data(serialized_node, true)
	for serialized_ref: Array in _gamesave_serialized_refs:
		_deserialize_object_data(serialized_ref, false)


func _build_procedural_tree() -> void:
	for serialized_node: Array in _gamesave_serialized_nodes:
		var object_id: int = serialized_node[0]
		var node: Node = _objects[object_id]
		if _is_procedural_object(node):
			var parent_save_id: int = serialized_node[2]
			var parent: Node = _objects[parent_save_id]
			parent.add_child(node)


# Serialize/deserialize functions

func _serialize_node(node: Node) -> void:
	var serialized_node := []
	var object_id: int = _object_ids[node]
	serialized_node.append(object_id) # index 0
	var script_id := -1
	var is_procedural := _is_procedural_object(node)
	if is_procedural:
		var script: Script = node.get_script()
		script_id = _get_script_id(script)
		assert(!DPRINT or _dprint(object_id, node, script_id, _gamesave_script_paths[script_id]))
	else:
		assert(!DPRINT or _dprint(object_id, node, node.name))
	serialized_node.append(script_id) # index 1
	# index 2 will be parent_save_id *or* non-procedural node path
	if is_procedural:
		var parent := node.get_parent()
		var parent_save_id: int = _object_ids[parent]
		serialized_node.append(parent_save_id) # index 2
	else:
		var node_path := _save_root.get_path_to(node)
		serialized_node.append(node_path) # index 2
	_serialize_object_data(node, serialized_node)
	_gamesave_serialized_nodes.append(serialized_node)


func _index_and_serialize_ref(ref: RefCounted) -> int:
	assert(_is_procedural_object(ref), "RefCounted must be PERSIST_PROCEDURAL")
	var object_id := _gamesave_n_objects
	_gamesave_n_objects += 1
	_object_ids[ref] = object_id
	var serialized_ref := []
	serialized_ref.append(object_id) # index 0
	var script: Script = ref.get_script()
	var script_id := _get_script_id(script)
	assert(!DPRINT or _dprint(object_id, ref, script_id, _gamesave_script_paths[script_id]))
	serialized_ref.append(script_id) # index 1
	_serialize_object_data(ref, serialized_ref)
	_gamesave_serialized_refs.append(serialized_ref)
	return object_id


func _get_script_id(script: Script) -> int:
	var script_path := script.resource_path
	assert(script_path)
	var script_id: int = _path_ids.get(script_path, -1)
	if script_id == -1:
		script_id = _gamesave_script_paths.size()
		_gamesave_script_paths.append(script_path)
		_path_ids[script_path] = script_id
	return script_id


func _serialize_object_data(object: Object, serialized_object: Array) -> void:
	assert(object is Node or object is RefCounted)
	# serialized_object already has 3 elements (if Node) or 2 (if RefCounted).
	# We now append the size of each persist array followed by data.
	for properties_array in _persist_property_lists:
		var properties: Array[StringName]
		var n_properties: int
		if properties_array in object:
			properties = object.get(properties_array)
			n_properties = properties.size()
		else:
			n_properties = 0
		serialized_object.append(n_properties)
		for property in properties:
			var value: Variant = object.get(property)
			assert(_debug_is_valid_persist_value(value))
			serialized_object.append(_get_encoded_value(value))


func _deserialize_object_data(serialized_object: Array, is_node: bool) -> void:
	# The order of persist properties must be exactly the same from game save
	# to game load. However, if a newer version (loading an older save) has
	# added more persist properties at the end of a persist array const, these
	# will not be touched and will not cause "data out of frame" mistakes.
	# There is some opportunity here for backward compatibility if the newer
	# version knows to init-on-load its added persist properties when loading
	# an older version save file.
	var index: int = 3 if is_node else 2
	var object_id: int = serialized_object[0]
	var object: Object = _objects[object_id]
	for properties_array in _persist_property_lists:
		var n_properties: int = serialized_object[index]
		index += 1
		if n_properties == 0:
			continue
		var properties: Array = object.get(properties_array)
		var property_index := 0
		while property_index < n_properties:
			var property: String = properties[property_index]
			var encoded_value: Variant = serialized_object[index]
			index += 1
			object.set(property, _get_decoded_value(encoded_value))
			property_index += 1


func _get_encoded_value(value: Variant) -> Variant:
	# Return is an int, Array or Dictionary.
	var type := typeof(value)
	if type == TYPE_ARRAY:
		var array: Array = value
		return _get_encoded_array(array) # array
	if type == TYPE_DICTIONARY:
		var dict: Dictionary = value
		return _get_encoded_dict(dict) # dict
	if type == TYPE_OBJECT:
		var object: Object = value
		return _get_encoded_object(object) # int >= OBJECT_ID_OFFSET
	# Anything else is built-in type that we index. String/StringName are
	# interchangeable as dictionary keys, so we index String using a separate
	# dictionary.
	var index: int
	if type == TYPE_STRING:
		index = _indexed_string_ids.get(value, -1)
		if index == -1:
			index = _gamesave_indexed_values.size()
			_gamesave_indexed_values.append(value)
			_indexed_string_ids[value] = index
		return index
	index = _indexed_nonstring_ids.get(value, -1)
	if index == -1:
		index = _gamesave_indexed_values.size()
		_gamesave_indexed_values.append(value)
		_indexed_nonstring_ids[value] = index
	return index


func _get_decoded_value(encoded_value: Variant) -> Variant:
	# 'encoded_value' is an int, Array or Dictionary.
	var encoded_type := typeof(encoded_value)
	if encoded_type == TYPE_INT:
		var index: int = encoded_value
		if index >= OBJECT_ID_OFFSET:
			return _get_decoded_object(index)
		return _gamesave_indexed_values[index] # indexed built-in type
	if encoded_type == TYPE_ARRAY:
		var encoded_array: Array = encoded_value
		return _get_decoded_array(encoded_array)
	var encoded_dict: Dictionary = encoded_value
	return _get_decoded_dict(encoded_dict)


func _get_encoded_array(array: Array) -> Array:
	# Encodes array type if applicable.
	#
	# As of Godot 4.2.beta5, godot file storage does not persist array types:
	# https://github.com/godotengine/godot/issues/76841
	# Therefore, we append type info so we can pop it in the decode method.
	#
	# TODO: When above issue is fixed, we can optimize here by duplicating
	# non-object arrays. (We have many typed data arrays!)
	
	var encoded_array := []
	var array_type := array.get_typed_builtin()
	var size := array.size()
	encoded_array.resize(size)
	var index := 0
	while index < size:
		encoded_array[index] = _get_encoded_value(array[index])
		index += 1
	
	# Append array type info to the encoded array.
	if array.is_typed():
		var script: Script = array.get_typed_script()
		var script_id := _get_script_id(script) if script else -1
		encoded_array.append(script_id)
		encoded_array.append(array.get_typed_class_name()) # StringName
		encoded_array.append(array_type) # last element
	else:
		encoded_array.append(-1) # last element
	
	return encoded_array


func _get_decoded_array(encoded_array: Array) -> Array:
	# Return array may or may not be content-typed.
	var array := []
	
	# Pop array content-type info from the back of the encoded array, then
	# type the return array if applicable.
	var array_type: int = encoded_array.pop_back()
	if array_type != -1:
		var typed_class_name: StringName = encoded_array.pop_back()
		var script_id: int = encoded_array.pop_back()
		var script: Script
		if script_id != -1:
			script = _scripts[script_id]
		array = Array(array, array_type, typed_class_name, script) # last two often &"", null
	
	var size := encoded_array.size()
	array.resize(size)
	var index := 0
	while index < size:
		array[index] = _get_decoded_value(encoded_array[index])
		index += 1
	return array


func _get_encoded_dict(dict: Dictionary) -> Dictionary:
	var encoded_dict := {}
	for key: Variant in dict:
		var encoded_key: Variant = _get_encoded_value(key)
		encoded_dict[encoded_key] = _get_encoded_value(dict[key])
	return encoded_dict


func _get_decoded_dict(encoded_dict: Dictionary) -> Dictionary:
	var dict := {}
	for encoded_key: Variant in encoded_dict:
		var key: Variant = _get_decoded_value(encoded_key)
		dict[key] = _get_decoded_value(encoded_dict[encoded_key])
	return dict


func _get_encoded_object(object: Object) -> int:
	var is_weak_ref := false
	if object is WeakRef:
		var wr: WeakRef = object
		object = wr.get_ref()
		if object == null:
			return WEAKREF_NULL_ID # WeakRef to a dead object
		is_weak_ref = true
	assert(_debug_assert_persist_object(object))
	var object_id: int = _object_ids.get(object, -1)
	if object_id == -1:
		assert(object is RefCounted, "Possible reference to Node that is not in the tree")
		var ref: RefCounted = object
		object_id = _index_and_serialize_ref(ref)
	if is_weak_ref:
		return object_id + WEAKREF_ID_OFFSET # WeakRef
	return object_id + OBJECT_ID_OFFSET # Object


func _get_decoded_object(encoded_object: int) -> Object:
	if encoded_object < WEAKREF_ID_OFFSET:
		return _objects[encoded_object - OBJECT_ID_OFFSET]
	if encoded_object < WEAKREF_NULL_ID:
		var object: Object = _objects[encoded_object - WEAKREF_ID_OFFSET]
		return weakref(object)
	return WeakRef.new() # weak ref to dead object


func _is_persist_object(object: Object) -> bool:
	# Duplicated from IVSaveUtils for speed.
	if &"persist_mode_override" in object:
		return object.get(&"persist_mode_override") != NO_PERSIST
	if &"PERSIST_MODE" in object:
		return object.get(&"PERSIST_MODE") != NO_PERSIST
	return false


func _is_procedural_object(object: Object) -> bool:
	# Duplicated from IVSaveUtils for speed.
	if &"persist_mode_override" in object:
		return object.get(&"persist_mode_override") == PERSIST_PROCEDURAL
	if &"PERSIST_MODE" in object:
		return object.get(&"PERSIST_MODE") == PERSIST_PROCEDURAL
	return false


func _debug_is_valid_persist_value(value: Variant) -> bool:
	# Enforce persist property rules on save so we don't have more difficult
	# debugging on load. Wrap the function call in assert so it is only called
	# in editor and debug builds.
	var type := typeof(value)
	if type == TYPE_ARRAY:
		var array: Array = value
		var array_type := array.get_typed_builtin()
		if array_type == TYPE_NIL:
			# no objects in untyped arrays!
			return _debug_assert_data_only_array(array)
		if array_type == TYPE_ARRAY:
			# no nested objects allowed!
			for nested_array: Array in array:
				if !_debug_assert_data_only_array(nested_array):
					return false
			return true
		if array_type == TYPE_DICTIONARY:
			# no nested objects allowed!
			for nested_dict: Dictionary in array:
				if !_debug_assert_data_only_dictionary(nested_dict):
					return false
			return true
		if array_type == TYPE_OBJECT:
			return true # array object elements tested in _get_encoded_object()
		if array_type == TYPE_RID or array_type == TYPE_CALLABLE or array_type == TYPE_SIGNAL:
			assert(false, "Disallowed array type can't be persisted")
			return false
		return true # safe data-typed array
	if type == TYPE_DICTIONARY:
		var dict: Dictionary = value
		for key: Variant in dict:
			if !_debug_assert_persist_dictionary_element(key):
				return false
			var dict_value: Variant = dict[key]
			if !_debug_assert_persist_dictionary_element(dict_value):
				return false
		return true
	if type == TYPE_OBJECT:
		var object: Object = value
		return _debug_assert_persist_object(object)
	if type == TYPE_RID or type == TYPE_CALLABLE or type == TYPE_SIGNAL:
		assert(false, "Disallowed type can't be persisted")
		return false
	return true


func _debug_assert_persist_object(object: Object) -> bool:
	if !_is_persist_object(object):
		assert(false, "Can't persist a non-persist object; see IVTreeSaver doc")
		return false
	return true


func _debug_assert_persist_dictionary_element(key_or_value: Variant) -> bool:
	# Object ok as key or value, but objects can't be nested.
	var type := typeof(key_or_value)
	if type == TYPE_OBJECT:
		var object: Object = key_or_value
		return _debug_assert_persist_object(object)
	if type == TYPE_ARRAY:
		var array: Array = key_or_value
		return _debug_assert_data_only_array(array)
	if type == TYPE_DICTIONARY:
		var dict: Dictionary = key_or_value
		return _debug_assert_data_only_dictionary(dict)
	if type == TYPE_RID or type == TYPE_CALLABLE or type == TYPE_SIGNAL:
		assert(false, "Disallowed type can't be persisted")
		return false
	return true


func _debug_assert_data_only_array(array: Array) -> bool:
	# Untyped or nested arrays can't contain objects.
	for value: Variant in array:
		var type := typeof(value)
		if type == TYPE_OBJECT:
			assert(false, "Disallowed object in untyped or nested array; see IVTreeSaver doc")
			return false
		if type == TYPE_RID or type == TYPE_CALLABLE or type == TYPE_SIGNAL:
			assert(false, "Disallowed type can't be persisted")
			return false
		elif type == TYPE_ARRAY:
			var array_value: Array = value
			if !_debug_assert_data_only_array(array_value):
				return false
		elif type == TYPE_DICTIONARY:
			var dict_value: Dictionary = value
			if !_debug_assert_data_only_dictionary(dict_value):
				return false
	return true


func _debug_assert_data_only_dictionary(dict: Dictionary) -> bool:
	# Nested dictionaries can't contain objects.
	for key: Variant in dict:
		var type := typeof(key)
		if type == TYPE_OBJECT:
			assert(false, "Disallowed object in nested dictionary; see IVTreeSaver doc")
			return false
		if type == TYPE_RID or type == TYPE_CALLABLE or type == TYPE_SIGNAL:
			assert(false, "Disallowed type can't be persisted")
			return false
		elif type == TYPE_ARRAY:
			var array_key: Array = key
			if !_debug_assert_data_only_array(array_key):
				return false
		elif type == TYPE_DICTIONARY:
			var dict_key: Dictionary = key
			if !_debug_assert_data_only_dictionary(dict_key):
				return false
		var value: Variant = dict[key]
		type = typeof(value)
		if type == TYPE_OBJECT:
			assert(false, "Disallowed object in nested dictionary; see IVTreeSaver doc")
			return false
		if type == TYPE_RID or type == TYPE_CALLABLE or type == TYPE_SIGNAL:
			assert(false, "Disallowed type can't be persisted")
			return false
		elif type == TYPE_ARRAY:
			var array_value: Array = value
			if !_debug_assert_data_only_array(array_value):
				return false
		elif type == TYPE_DICTIONARY:
			var dict_value: Dictionary = value
			if !_debug_assert_data_only_dictionary(dict_value):
				return false
	return true


func _dprint(arg: Variant, arg2: Variant = "", arg3: Variant = "", arg4: Variant = "") -> bool:
	prints(arg, arg2, arg3, arg4)
	return true

