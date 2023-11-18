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

## Provides functions to: 1) Generate a compact game-save data structure from
## properties specified in object constants in a scene tree. 2) Set properties
## and rebuild procedural parts of the scene tree on game load.
##
## IVTreeSaver can persist Godot built-in types (including [Array] and
## [Dictionary]) and four kinds of 'persist' objects:[br][br]
##    
##    1. 'Non-procedural' [Node] - May have persist data but won't be freed on
##       game load.[br]
##    2. 'Procedural' [Node] - These will be freed and rebuilt on game load.[br]
##    3. 'Procedural' [RefCounted] - These will be freed and rebuilt on game load.[br]
##    4. [WeakRef] to any of above.[br][br]
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
##    [code]const PERSIST_PROPERTIES: Array[StringName] = [&"property1", &"property2"][/code][br]
##    [code]const PERSIST_PROPERTIES2: Array[StringName] = [&"property3", &"property4"][/code]
##         (for sublcassing)[br]
##    (These list names can be modified in [member IVSaveUtils.persist_property_lists].)
##    [br][br]
##
## During tree build, Nodes are generally instantiated as scripts: i.e., using
## [code]Script.new()[/code]. To instantiate a scene instead, the base Node's
## GDScript must have one of:[br][br]
##
##    [code]const SCENE := "<path to .tscn file>"[/code][br]
##    [code]const SCENE_OVERRIDE := "<path to .tscn file>"[/code] (for sublcassing)[br][br]
##
## Special rules for 'persist' objects:[br][br]
##
##    1. Objects cannot be deeply nested in containers. They can only be
##       elements of directly persisted arrays (i.e., the array is listed) or
##       keys or values of directly persisted dictionaries (i.e., the dictionary
##       is listed).[br]
##    2. Arrays containing persist objects must be typed as [code]TYPE_OBJECT[/code].[br]
##    3. For procedural tree deconstruction, [method free_procedural_objects_recursive]
##       nulls all references to objects for properties that are listed. Any other
##       references to these objects must be nulled by some other code
##       (otherwise, old procedural RefCounted objects won't be freed).
##       Objects can be referenced in multiple places and circular references
##       are ok.[br]
##    4. Nodes must be in the tree.[br]
##    5. All ancester nodes up to and including [code]save_root[/code] must also be persist
##       nodes.[br]
##    6. Non-procedural Nodes (i.e., that are [code]PERSIST_PROPERTIES_ONLY[/code]) cannot
##       have any ancestors that are [code]PERSIST_PROCEDURAL[/code].[br]
##    7. Non-procedural Nodes must have stable node paths.[br]
##    8. Inner classes can't be persist objects.[br]
##    9. A persisted RefCounted can only be [code]PERSIST_PROCEDURAL[/code].[br]
##    10. Persist objects cannot have required args in their [code]_init()[/code]
##       method.[br][br]
##
## Warnings:[br][br]
##
##    1. Godot does not allow us to index arrays and dictionaries by reference rather
##       than content (see [url=https://github.com/godotengine/godot-proposals/issues/874]
##       proposal #874[/url] to fix this). Therefore, a single array
##       or dictionary persisted in two places (i.e., listed in [code]PERSIST_PROPERTIES[/code]
##       in two files) will become two separate arrays or dictionaries on load.[br][br]
##
## Forward compatability of game saves:[br][br]
##
## IVTreeSaver provides some [i]very limited[/i] flexibility for updating
## classes while maintaining compatibility with older game saves.
## Specifically, an updated class can have additional persist properties that
## did not exist in the previous game save version. However, all properties in
## the game save must exist in the updated class in the exact same order.

const _DPRINT := false # set true for debug print

const _OBJECT_ID_OFFSET := 10_000_000_000_000 # allows this many different persist values
const _WEAKREF_ID_OFFSET := 2 * _OBJECT_ID_OFFSET
const _WEAKREF_NULL_ID := 3 * _OBJECT_ID_OFFSET

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
var _gamesave_script_paths := []
var _gamesave_indexed_values := []

# save processing
var _nonprocedural_path_root: Node
var _object_ids := {} # indexed by objects
var _script_ids := {} # indexed by script paths
var _indexed_string_ids := {} # indexed by String values
var _indexed_nonstring_ids := {} # indexed by non-String values (incl StringName)

# load processing
var _is_detached: bool
var _scripts: Array[Script] = [] # indexed by script_id
var _objects: Array[Object] = [] # indexed by object_id


## Encodes the tree as a data array suitable for file storage, persisting only
## properties listed in object constant lists defined in
## [member IVSaveUtils.persist_property_lists]. [param save_root] must
## be a persist node. It may or may not be procedural (this will determine
## which 'build...' method to call later).
func get_gamesave(save_root: Node) -> Array:
	assert(_debug_assert_persist_object(save_root))
	_nonprocedural_path_root = save_root
	assert(!_DPRINT or _dprint("* Registering tree for gamesave *"))
	_index_tree(save_root)
	assert(!_DPRINT or _dprint("* Serializing tree for gamesave *"))
	_serialize_tree(save_root)
	var gamesave := [
		_gamesave_n_objects,
		_gamesave_serialized_nodes,
		_gamesave_serialized_refs,
		_gamesave_script_paths,
		_gamesave_indexed_values,
		]
	print("Persist objects saved: ", _gamesave_n_objects, "; nodes in tree: ",
			save_root.get_tree().get_node_count())
	_reset()
	return gamesave


## Frees all 'procedural' [Node] and [RefCounted] instances starting from
## [param root_node] (which may or may not be procedural). This method
## first nulls all references to objects for all properties that are listed,
## then frees the base procedural nodes.[br][br]
##
## WARNING: This method cannot remove references to objects for properties that
## are not listed in object constants defined in [member IVSaveUtils.persist_property_lists]. 
## Any such references must be removed by some other code.[br][br]
##
## Call this method before [method build_attached_tree] or
## [method build_detached_tree] if there is an existing tree that needs to be
## removed. It is recommended to delay a few frames (we delay 6) before
## building the new tree. Otherwise, freeing procedural objects are still alive
## and may respond to signals during the tree build.[br][br]
##
## You can also call this method before quit or exit to remove circular
## references to procedural objects.
func free_procedural_objects_recursive(root_node: Node) -> void:
	IVSaveUtils.free_procedural_objects_recursive(root_node)


## Rebuilds the tree from [param gamesave] data attached to an existing scene tree.
## Call this method if [param save_root] specified in [method get_gamesave] was a
## non-procedural node (using the same [param save_root] supplied in that method).
func build_attached_tree(gamesave: Array, save_root: Node) -> void:
	assert(save_root)
	assert(_debug_assert_persist_object(save_root))
	assert(!_is_procedural_object(save_root), "'save_root' must be non-procedural")
	_is_detached = false
	_build_tree(gamesave, save_root)


## Rebuilds the tree from [param gamesave] data in a detatched state. Call this
## method if [param save_root] specified in [method get_gamesave] was a
## procedural node. The method will return the new, procedurally instantiated
## [param save_root].
## @experimental
func build_detached_tree(gamesave: Array) -> Node:
	_is_detached = true
	return _build_tree(gamesave)


func _build_tree(gamesave: Array, save_root: Node = null) -> Node:
	_gamesave_n_objects = gamesave[0]
	_gamesave_serialized_nodes = gamesave[1]
	_gamesave_serialized_refs = gamesave[2]
	_gamesave_script_paths = gamesave[3]
	_gamesave_indexed_values = gamesave[4]
	_load_scripts()
	_locate_or_instantiate_objects(save_root) # null ok if all procedural
	_deserialize_all_object_data()
	_build_procedural_tree()
	var detatched_root: Node
	if _is_detached:
		detatched_root = _objects[0]
	print("Persist objects loaded: ", _gamesave_n_objects)
	_reset()
	return detatched_root


func _reset() -> void:
	_gamesave_n_objects = 0
	_gamesave_serialized_nodes = []
	_gamesave_serialized_refs = []
	_gamesave_script_paths = []
	_gamesave_indexed_values = []
	_nonprocedural_path_root = null
	_object_ids.clear()
	_script_ids.clear()
	_indexed_string_ids.clear()
	_indexed_nonstring_ids.clear()
	_objects.clear()
	_scripts.clear()


# Procedural save

func _index_tree(node: Node) -> void:
	# Make an object_id for all persist nodes by indexing in _object_ids.
	# object_id = 0 is the 'save_root'.
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
	# 'save_root' can be null if all nodes are procedural.
	assert(!_DPRINT or _dprint("* Registering(/Instancing) Objects for Load *"))
	_objects.resize(_gamesave_n_objects)
	for serialized_node: Array in _gamesave_serialized_nodes:
		var object_id: int = serialized_node[0]
		var script_id: int = serialized_node[1]
		# Assert user called the right build function
		assert(object_id > 0 or !_is_detached or script_id > -1,
				"Call to 'build_detached...()' but the root node is non-procedural")
		assert(object_id > 0 or _is_detached or script_id == -1,
				"Call to 'build_attached...()' but the root node is procedural")
		var node: Node
		if script_id == -1: # non-procedural node; find it
			var node_path: NodePath = serialized_node[2] # relative
			node = save_root.get_node(node_path)
			assert(!_DPRINT or _dprint(object_id, node, node.name))
		else: # this is a procedural node
			var script: Script = _scripts[script_id]
			node = IVSaveUtils.make_object_or_scene(script)
			assert(!_DPRINT or _dprint(object_id, node, script_id, _gamesave_script_paths[script_id]))
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
		assert(!_DPRINT or _dprint(object_id, ref, script_id, _gamesave_script_paths[script_id]))


func _deserialize_all_object_data() -> void:
	assert(!_DPRINT or _dprint("* Deserializing Objects for Load *"))
	for serialized_node: Array in _gamesave_serialized_nodes:
		_deserialize_object_data(serialized_node, true)
	for serialized_ref: Array in _gamesave_serialized_refs:
		_deserialize_object_data(serialized_ref, false)


func _build_procedural_tree() -> void:
	for serialized_node: Array in _gamesave_serialized_nodes:
		var object_id: int = serialized_node[0]
		if object_id == 0: # 'save_root' has no parent in the save
			continue
		var node: Node = _objects[object_id]
		if _is_procedural_object(node):
			var parent_id: int = serialized_node[2]
			var parent: Node = _objects[parent_id]
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
		assert(!_DPRINT or _dprint(object_id, node, script_id, _gamesave_script_paths[script_id]))
	else:
		assert(!_DPRINT or _dprint(object_id, node, node.name))
	serialized_node.append(script_id) # index 1
	# index 2 will be node path or parent_id or -1
	if !is_procedural: # non-procedural
		var node_path := _nonprocedural_path_root.get_path_to(node)
		serialized_node.append(node_path) # index 2
	elif object_id > 0: # procedural with parent in the tree
		var parent := node.get_parent()
		var parent_id: int = _object_ids[parent]
		serialized_node.append(parent_id) # index 2
	else: # detatched procedural root node
		serialized_node.append(-1) # index 2
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
	assert(!_DPRINT or _dprint(object_id, ref, script_id, _gamesave_script_paths[script_id]))
	serialized_ref.append(script_id) # index 1
	_serialize_object_data(ref, serialized_ref)
	_gamesave_serialized_refs.append(serialized_ref)
	return object_id


func _get_script_id(script: Script) -> int:
	var script_path := script.resource_path
	assert(script_path)
	var script_id: int = _script_ids.get(script_path, -1)
	if script_id == -1:
		script_id = _gamesave_script_paths.size()
		_gamesave_script_paths.append(script_path)
		_script_ids[script_path] = script_id
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
	# Returns Array, Dictionary, int (object_id or index), or non-string
	# built-in type.
	var type := typeof(value)
	if type == TYPE_ARRAY:
		var array: Array = value
		return _get_encoded_array(array) # array
	if type == TYPE_DICTIONARY:
		var dict: Dictionary = value
		return _get_encoded_dict(dict) # dict
	if type == TYPE_OBJECT:
		var object: Object = value
		return _get_encoded_object(object) # int >= _OBJECT_ID_OFFSET
	
	# Index string types to avoid duplicated strings (e.g., many dict keys).
	# String/StringName are interchangeable as dictionary keys, so we index
	# Strings in their own dictionary. We have to index int for the decode.
	if type == TYPE_INT or type == TYPE_STRING_NAME:
		var index: int = _indexed_nonstring_ids.get(value, -1)
		if index == -1:
			index = _gamesave_indexed_values.size()
			_gamesave_indexed_values.append(value)
			_indexed_nonstring_ids[value] = index
		return index
	if type == TYPE_STRING:
		var index: int = _indexed_string_ids.get(value, -1)
		if index == -1:
			index = _gamesave_indexed_values.size()
			_gamesave_indexed_values.append(value)
			_indexed_string_ids[value] = index
		return index
	
	# Built-in saved as-is
	return value


func _get_decoded_value(encoded_value: Variant) -> Variant:
	# Decode int, Array or Dictionary; otherwise return as is.
	var encoded_type := typeof(encoded_value)
	if encoded_type == TYPE_INT: # object or indexed value
		var index: int = encoded_value
		if index >= _OBJECT_ID_OFFSET:
			return _get_decoded_object(index)
		return _gamesave_indexed_values[index]
	if encoded_type == TYPE_ARRAY:
		var encoded_array: Array = encoded_value
		return _get_decoded_array(encoded_array)
	if encoded_type == TYPE_DICTIONARY:
		var encoded_dict: Dictionary = encoded_value
		return _get_decoded_dict(encoded_dict)
	return encoded_value


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
	var is_typed := array_type != TYPE_NIL
	var size := array.size()
	encoded_array.resize(size + (3 if is_typed else 1))
	var index := 0
	while index < size:
		encoded_array[index] = _get_encoded_value(array[index])
		index += 1
	
	# Append array type info to the encoded array.
	if is_typed:
		var script: Script = array.get_typed_script()
		var script_id := _get_script_id(script) if script else -1
		encoded_array[-3] = script_id
		encoded_array[-2] = array.get_typed_class_name() # StringName
		encoded_array[-1] = array_type # last element
	else:
		encoded_array[-1] = -1 # last element
	
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
			return _WEAKREF_NULL_ID # WeakRef to a dead object
		is_weak_ref = true
	assert(_debug_assert_persist_object(object))
	var object_id: int = _object_ids.get(object, -1)
	if object_id == -1:
		assert(object is RefCounted, "Possible reference to Node that is not in the tree")
		var ref: RefCounted = object
		object_id = _index_and_serialize_ref(ref)
	if is_weak_ref:
		return object_id + _WEAKREF_ID_OFFSET # WeakRef
	return object_id + _OBJECT_ID_OFFSET # Object


func _get_decoded_object(encoded_object: int) -> Object:
	if encoded_object < _WEAKREF_ID_OFFSET:
		return _objects[encoded_object - _OBJECT_ID_OFFSET]
	if encoded_object < _WEAKREF_NULL_ID:
		var object: Object = _objects[encoded_object - _WEAKREF_ID_OFFSET]
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
	# debugging on load. Wrap this function call in assert so it is only called
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
			return true # assert objects valid in _get_encoded_object()
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
		return true # assert valid object in _get_encoded_object()
	if type == TYPE_RID or type == TYPE_CALLABLE or type == TYPE_SIGNAL:
		assert(false, "Disallowed type can't be persisted")
		return false
	return true


func _debug_assert_persist_object(object: Object) -> bool:
	if not object is RefCounted and not object is Node:
		assert(false, "Persist objects must be Node or RefCounted")
		return false
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

