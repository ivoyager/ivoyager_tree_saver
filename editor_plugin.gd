# editor_plugin.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2017-2024 Charlie Whitfield
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
@tool
extends EditorPlugin


func _enter_tree() -> void:
	print_plugin_name_and_version("ivoyager_tree_saver"," - https://ivoyager.dev")


func _exit_tree() -> void:
	print("Removing I, Voyager - Tree Saver (plugin)")


# Copied from 'master' plugin utility functions at:
# https://github.com/ivoyager/ivoyager_core/blob/master/editor_plugin/plugin_utils.gd
static func print_plugin_name_and_version(plugin: String, append := "") -> void:
	var path := "res://addons/" + plugin + "/plugin.cfg"
	var plugin_cfg := ConfigFile.new()
	var err := plugin_cfg.load(path)
	if err != OK:
		assert(false, "Failed to load config '%s'" % path)
		return
	var plugin_name: String = plugin_cfg.get_value("plugin", "name")
	var version: String = plugin_cfg.get_value("plugin", "version")
	print("%s (plugin) %s%s" % [plugin_name, version, append])
