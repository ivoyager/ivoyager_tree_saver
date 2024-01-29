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

# This EditorPlugin doesn't really do anything. In ivoyager_core we do
# different things depending on whether this plugin is present and enabled.
# To detect that we use:
#
# var plugins: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled")
# var tree_saver_enabled := plugins.has("res://addons/ivoyager_tree_saver/plugin.cfg")

const plugin_utils := preload("plugin_utils.gd")


func _enter_tree() -> void:
	plugin_utils.print_plugin_name_and_version("res://addons/ivoyager_tree_saver/plugin.cfg",
			" - https://ivoyager.dev")


func _exit_tree() -> void:
	print("Removing I, Voyager - Tree Saver (plugin)")

