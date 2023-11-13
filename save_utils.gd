# save_utils.gd
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
class_name IVSaveUtils
extends Object

## An object is identified as 'persist' if it has [code]const PERSIST_MODE[/code]
## with any value != NO_PERSIST. An object instance can override its class constant
## using property [code]persist_mode_override[/code]. NO_PERSIST is exactly
## equivilant to the class not having [code]const PERSIST_MODE[/code] or
## [code]var persist_mode_override[/code].
enum PersistMode {
	NO_PERSIST, ## Non-persist object.
	PERSIST_PROPERTIES_ONLY, ## Object will not be freed (Node only; must have stable NodePath).
	PERSIST_PROCEDURAL, ## Object will be freed and rebuilt on game load (Node or RefCounted).
}

const NO_PERSIST := PersistMode.NO_PERSIST
const PERSIST_PROPERTIES_ONLY := PersistMode.PERSIST_PROPERTIES_ONLY
const PERSIST_PROCEDURAL := PersistMode.PERSIST_PROCEDURAL

## Names of property arrays to use in persist objects. It's useful to have
## multiple lists so object subclasses can add properties. These should
## probably be class constants, but code here doesn't care.
static var persist_property_lists: Array[StringName] = [
	&"PERSIST_PROPERTIES",
	&"PERSIST_PROPERTIES2",
]


## Frees all 'procedural' Node and RefCounted instances starting from
## [code]root_node[/code] (which may or may not be procedural). This method
## first nulls all references to procedural objects everywhere, then frees the
## base procedural Nodes.[br][br]
## Call this method before [code]build_tree()[/code].[br][br]
## WARNING: We assume that all references to procedural RefCounteds are listed
## in [code]persist_property_lists[/code] constants in the target objects. Any
## other references must be nulled by some other code.
static func free_all_procedural_objects(root_node: Node) -> void:
	null_procedural_references_recursive(root_node)
	free_procedural_nodes_recursive(root_node)


## Nulls all property and container references to 'procedural' objects
## recursively.
static func null_procedural_references_recursive(object: Object, nulled_objects := {}) -> void:
	
	# Don't process circular references.
	if nulled_objects.has(object):
		return
	nulled_objects[object] = true
	
	# Recursive call to all nodes. All procedural nodes must be in the tree!
	if object is Node:
		var node: Node = object
		for child in node.get_children():
			if is_persist_object(child):
				null_procedural_references_recursive(child, nulled_objects)
	
	# Null all procedural object references with recursive calls to RefCounteds
	for properties_array_name in persist_property_lists:
		if not properties_array_name in object:
			continue
		var properties_array: Array = object.get(properties_array_name)
		for property: StringName in properties_array:
			var value: Variant = object.get(property)
			var type := typeof(value)
			if type == TYPE_OBJECT:
				var property_object: Object = value
				null_procedural_references_recursive(property_object, nulled_objects)
				object.set(property, null)
			elif type == TYPE_ARRAY:
				# test elements if Object-typed only
				var array: Array = value
				if array.get_typed_builtin() == TYPE_OBJECT:
					for i in array.size():
						var array_object: Object = array[i]
						null_procedural_references_recursive(array_object, nulled_objects)
						array[i] = null
			elif type == TYPE_DICTIONARY:
				# test all keys and values
				var dict: Dictionary = value
				for key: Variant in dict.keys():
					var dict_value: Variant = dict[key]
					if typeof(dict_value) == TYPE_OBJECT:
						var value_object: Object = dict_value
						null_procedural_references_recursive(value_object, nulled_objects)
						dict[key] = null
					if typeof(key) == TYPE_OBJECT:
						var key_object: Object = key
						null_procedural_references_recursive(key_object, nulled_objects)
						dict.erase(key)


## Frees all 'procedural' Nodes at or below [code]root_node[/code]. Note: It's
## usually better to call [code]free_all_procedural_objects()[/code] instead! 
static func free_procedural_nodes_recursive(root_node: Node) -> void:
	if is_procedural_object(root_node):
		root_node.queue_free() # children will also be freed!
		return
	for child in root_node.get_children():
		if is_persist_object(child):
			free_procedural_nodes_recursive(child)


## Clones object properties using [code]persist_property_lists[/code] constants
## in the origin class. Arrays and Dictionaries are duplicated (deep == true).
## However, Objects will be set without duplication.[br][br]
##
## In expected usage 'origin' and 'clone' are the same class. However, the
## only requirement here is that they have the exact same persist properties.
##
## This method is not used by [IVTreeSaver]. It uses the same persist property
## lists however, so may be useful.
static func clone_persist_properties(origin: Object, clone: Object) -> void:
	for properties_array in persist_property_lists:
		if not properties_array in origin:
			continue
		var properties: Array[StringName] = origin.get(properties_array)
		for property in properties:
			var value: Variant = origin.get(property)
			var type := typeof(value)
			if type == TYPE_ARRAY:
				var origin_array: Array = value
				value = origin_array.duplicate(true)
			elif type == TYPE_DICTIONARY:
				var origin_dict: Dictionary = value
				value = origin_dict.duplicate(true)
			clone.set(property, value)


## Generates an array of object properties using [code]persist_property_lists[/code]
## constants in the origin class. Getting the result from this function and
## passing it with a 'clone' object to [code]set_persist_properties()[/code] is
## equivilent to [code]clone_persist_properties()[/code]
static func get_persist_properties(origin: Object) -> Array:
	var array := []
	for properties_array in persist_property_lists:
		if not properties_array in origin:
			continue
		var properties: Array[StringName] = origin.get(properties_array)
		for property in properties:
			var value: Variant = origin.get(property)
			var type := typeof(value)
			if type == TYPE_ARRAY:
				var origin_array: Array = value
				value = origin_array.duplicate(true)
			elif type == TYPE_DICTIONARY:
				var origin_dict: Dictionary = value
				value = origin_dict.duplicate(true)
			array.append(value)
	return array


## Sets properties from array generated by [code]get_persist_properties()[/code].
static func set_persist_properties(clone: Object, array: Array) -> void:
	var i := 0
	for properties_array in persist_property_lists:
		if not properties_array in clone:
			continue
		var properties: Array[StringName] = clone.get(properties_array)
		for property in properties:
			clone.set(property, array[i])
			i += 1


static func get_persist_mode(object: Object) -> int:
	if &"persist_mode_override" in object:
		return object.get(&"persist_mode_override")
	if &"PERSIST_MODE" in object:
		return object.get(&"PERSIST_MODE")
	return NO_PERSIST


static func is_persist_object(object: Object) -> bool:
	if &"persist_mode_override" in object:
		return object.get(&"persist_mode_override") != NO_PERSIST
	if &"PERSIST_MODE" in object:
		return object.get(&"PERSIST_MODE") != NO_PERSIST
	return false


static func is_procedural_object(object: Object) -> bool:
	if &"persist_mode_override" in object:
		return object.get(&"persist_mode_override") == PERSIST_PROCEDURAL
	if &"PERSIST_MODE" in object:
		return object.get(&"PERSIST_MODE") == PERSIST_PROCEDURAL
	return false


## Returns an instantiated Object or the root Node of an instantiated scene.[br][br]
##
## [code]arg[/code] can be a Script, PackedScene, or String. If it is a String,
## it must be a valid path to a Script or PackedScene file resource.[br][br]
##
## If Script has const [code]SCENE[/code] or [code]SCENE_OVERRIDE[/code], then
## that constant value is used as path to intantiate a scene. 
static func make_object_or_scene(arg: Variant) -> Object:
	var arg_type := typeof(arg)
	var packedscene: PackedScene
	var script: Script
	if arg_type == TYPE_OBJECT:
		if arg is Script:
			script = arg
		elif arg is PackedScene:
			packedscene = arg
		else:
			assert(false, "Unknown object class %s" % arg)
			return null
	else:
		assert(arg is String)
		var path: String = arg
		var script_or_packedscene := get_script_or_packedscene(path)
		if !script_or_packedscene:
			assert(false, "Could not load '%s' as Script or PackedScene" % path)
			return null
		if script_or_packedscene is Script:
			script = script_or_packedscene
		else:
			packedscene = script_or_packedscene
	
	if script:
		var scene_path: String
		if &"SCENE_OVERRIDE" in script:
			scene_path = script.get("SCENE_OVERRIDE")
		elif &"SCENE" in script:
			scene_path = script.get("SCENE")
		if scene_path:
			packedscene = load(scene_path)
			if !packedscene:
				assert(false, "Failed to load scene at '%s'" % scene_path)
				return null
		else:
			@warning_ignore("unsafe_method_access")
			return script.new()
	
	var root_node: Node = packedscene.instantiate()
	if root_node.get_script() != script: # root_node.script may be parent class!
		root_node.set_script(script)
	return root_node


static func get_script_or_packedscene(path: String) -> Resource:
	if !path:
		assert(false, "Requires path")
		return null
	if path.ends_with(".tscn") or path.ends_with(".scn"):
		var packedscene: PackedScene = load(path)
		assert(packedscene, "Failed to load PackedScene at '%s'" % path)
		return packedscene
	var script: Script = load(path)
	assert(script, "Failed to load Script at '%s'" % path)
	return script



# logging
static var _log_count_by_class := {}

static func get_tree_debugging_log(save_root: Node, compare_class_count: bool,
		log_persist_nodes := true, log_all_nodes := false,
		print_stray_nodes := false, print_tree := false) -> PackedStringArray:
	# Call before and after all external save/load stuff completed.
	var debug_log := PackedStringArray()
	var count := 0
	
	debug_log.append("Number tree nodes: %s" % save_root.get_tree().get_node_count())
	
	if print_stray_nodes:
		print("Stray Nodes:")
		save_root.print_orphan_nodes()
		print("***********************")
	if print_tree:
		print("Tree:")
		save_root.print_tree_pretty()
		print("***********************")
	
	if log_all_nodes or log_persist_nodes:
		var last_log_count_by_class: Dictionary
		if _log_count_by_class and compare_class_count:
			last_log_count_by_class = _log_count_by_class.duplicate()
		_log_count_by_class.clear()
		count = _log_nodes(save_root, log_all_nodes, debug_log, count)
		if last_log_count_by_class:
			debug_log.append("Class counts difference from last count:")
			for class_: String in _log_count_by_class:
				if last_log_count_by_class.has(class_):
					debug_log.append("%s %s" % [class_, _log_count_by_class[class_] - last_log_count_by_class[class_]])
				else:
					debug_log.append("%s %s" % [class_, _log_count_by_class[class_]])
			for class_: String in last_log_count_by_class:
				if !_log_count_by_class.has(class_):
					debug_log.append("%s %s" % [class_, -last_log_count_by_class[class_]])
		else:
			debug_log.append("Class counts:")
			for class_: String in _log_count_by_class:
				debug_log.append("%s %s" % [class_, _log_count_by_class[class_]])
	
	return debug_log


static func _log_nodes(node: Node, log_all_nodes: bool, debug_log: PackedStringArray, count: int) -> int:
	count += 1
	var class_ := node.get_class()
	if _log_count_by_class.has(class_):
		_log_count_by_class[class_] += 1
	else:
		_log_count_by_class[class_] = 1
	var script_identifier := ""
	if node.get_script():
		@warning_ignore("unsafe_method_access")
		var source_code: String = node.get_script().get_source_code()
		if source_code:
			var split := source_code.split("\n", false, 1)
			script_identifier = split[0]
	debug_log.append("%s %s %s %s" % [count, node, node.name, script_identifier])
	for child in node.get_children():
		if log_all_nodes or is_procedural_object(child):
			count = _log_nodes(child, log_all_nodes, debug_log, count)
	
	return count

