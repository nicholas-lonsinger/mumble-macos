# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

add_custom_target(plugins ALL)

set(AVAILABLE_PLUGINS "link")

if(${CMAKE_BUILD_TYPE} MATCHES Debug)
	# Plugins that exercise the framework itself — loaded only when someone
	# is actively refactoring PluginManager/Plugin/API dispatch.
	list(APPEND AVAILABLE_PLUGINS
		"testPlugin"
		"deadLockPlugin"
	)
endif()

# Note: We are assuming that all plugins follow the convention of naming their sub-directory the same as the
# plugin cmake target. Therefore we can use the CURRENT_PLUGIN variable to reference the dir as well as the
# target.
foreach(CURRENT_PLUGIN IN LISTS AVAILABLE_PLUGINS)
	add_subdirectory(${CURRENT_PLUGIN})

	target_include_directories(${CURRENT_PLUGIN} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

	if(WIN32)
		target_compile_definitions(${CURRENT_PLUGIN} PRIVATE "OS_WINDOWS")
		target_link_libraries(${CURRENT_PLUGIN} PRIVATE user32.lib)

		# Shared library on Windows (e.g. ".dll")
		set_target_properties(${CURRENT_PLUGIN} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/plugins")
		install(TARGETS ${CURRENT_PLUGIN} RUNTIME DESTINATION "${MUMBLE_INSTALL_PLUGINDIR}" COMPONENT mumble_client)
	elseif(APPLE)
		target_compile_definitions(${CURRENT_PLUGIN} PRIVATE "OS_MACOS")

		# Write straight into the .app bundle so PluginManager's
		# Mumble.app/Contents/Plugins search path finds it at runtime;
		# the `mumble` BUNDLE install rule already ships the whole .app.
		set_target_properties(${CURRENT_PLUGIN} PROPERTIES
			LIBRARY_OUTPUT_DIRECTORY "$<TARGET_BUNDLE_CONTENT_DIR:mumble>/Plugins")
	elseif(UNIX)
		target_compile_definitions(${CURRENT_PLUGIN} PRIVATE "OS_LINUX")

		# Shared library on UNIX (e.g. ".so")
		set_target_properties(${CURRENT_PLUGIN} PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/plugins")
		install(TARGETS ${CURRENT_PLUGIN} LIBRARY DESTINATION "${MUMBLE_INSTALL_PLUGINDIR}" COMPONENT mumble_client)
	endif()

	add_dependencies(plugins ${CURRENT_PLUGIN})
endforeach()
