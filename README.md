# I, Voyager - Tree Saver (plugin)

Provides functions to:
1. Generate a compact game-save data structure from properties specified in object constants in a scene tree.
2. Set properties and rebuild procedural parts of a scene tree on game load.


## Installation

Find more detailed instructions at our [Developers Page](https://www.ivoyager.dev/developers/).

The plugin directory `ivoyager_tree_saver` should be added _directly to your addons directory_. You can do this one of two ways:

1. Download and extract the plugin, then add it (in its entirety) to your addons directory, creating an 'addons' directory in your project if needed.
2. (Recommended) Add as a git submodule. From your project directory, use git command:  
 `git submodule add https://github.com/ivoyager/ivoyager_tree_saver addons/ivoyager_tree_saver`  
 This method will allow you to version-control the plugin from within your project rather than moving directories manually. You'll be able to pull updates, checkout any commit, or submit pull requests back to us. This does require some learning to use git submodules. (We use [GitKraken](https://www.gitkraken.com/) to make this easier!)

Then enable 'I, Voyager - Tree Saver' from the Godot Editor project menu.

## Description

IVTreeSaver can persist Godot built-in types (including arrays and
dictionaries) and four kinds of 'persist' objects:

1. 'Non-procedural' Node - May have persist data but won't be freed on
game load.
2. 'Procedural' Node - These will be freed and rebuilt on game load.
3. 'Procedural' RefCounted - These will be freed and rebuilt on game load.
4. WeakRef to any of above.

Arrays and dictionaries containing non-object data can be nested at any
level of complexity (array types are also persisted). Arrays and
dictionaries can contain 'persist' objects but must follow rules below
under 'Special rules for persist objects'.

A Node or RefCounted is identified as a 'persist' object by the presence of
any one of the following:
```
const PERSIST_MODE := IVTreeSaver.PERSIST_PROPERTIES_ONLY
const PERSIST_MODE := IVTreeSaver.PERSIST_PROCEDURAL
var persist_mode_override :=  <either of above two values>
```
Lists of properties to persist must be named in object constant arrays:
```
const PERSIST_PROPERTIES: Array[StringName] = []
const PERSIST_PROPERTIES2: Array[StringName] = []
(List names can be modified in IVSaveUtils static array persist_property_lists.
The extra list is used by subclasses to add persist properties.)
```
During tree build, Nodes are generally instantiated as scripts: i.e., using
Script.new(). To instantiate a scene instead, the base Node's
GDScript must have one of:
```
const SCENE := "<path to .tscn file>"
const SCENE_OVERRIDE := "<path to .tscn file>" (Useful in a sublcass.)
```
Special rules for 'persist' objects:
1. Objects cannot be deeply nested in containers. They can only be
elements of directly persisted arrays or keys or values of directly
persisted dictionaries. I.e., objects must be elements, keys or values
of containers listed in an object's persist constant list.
2. Arrays containing persist objects must be typed as TYPE_OBJECT.
3. Objects CAN be referenced in multiple places. Even circular references
are ok. However, code here can only null object properties listed in
'persist' constant arrays during tree deconstruction. Any other
references to these objects must be nulled by some other code.
4. Nodes must be in the tree.
5. All ancester nodes up to and including save_root must also be persist
nodes.
6. Non-procedural Nodes (i.e., PERSIST_PROPERTIES_ONLY) cannot
have any ancestors that are PERSIST_PROCEDURAL.
7. Non-procedural Nodes must have stable node path.
8. Inner classes can't be persist objects.
9. A persisted RefCounted can only be PERSIST_PROCEDURAL.
10. Persist objects cannot have required args in their _init()
method.

Warnings:
1. Godot does not allow us to index arrays and dictionaries by reference rather
than content (see proposal #874 to fix this). Therefore, a single array
or dictionary persisted in two places (i.e., listed in PERSIST_PROPERTIES
in two files) will become two separate arrays or dictionaries on load.
(This does not happen for Objects!)