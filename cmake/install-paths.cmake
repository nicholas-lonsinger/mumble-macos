# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

include(GNUInstallDirs)

# Turns a path into an absolute path if it isn't absolute already
function(make_absolute out_path in_path)
	get_filename_component(abs_path "${in_path}" ABSOLUTE BASE_DIR "${CMAKE_INSTALL_PREFIX}")
	set(${out_path} "${abs_path}" PARENT_SCOPE)
endfunction()

set(MUMBLE_INSTALL_EXECUTABLEDIR "." CACHE PATH "The directory to install the main executable(s) into")
set(MUMBLE_INSTALL_LIBDIR "${CMAKE_INSTALL_LIBDIR}/mumble" CACHE PATH "The directory to install the built libraries into")
set(MUMBLE_INSTALL_PLUGINDIR "${CMAKE_INSTALL_LIBDIR}/mumble/plugins" CACHE PATH "The directory to install the built plugins into")

make_absolute(MUMBLE_INSTALL_ABS_EXECUTABLEDIR "${MUMBLE_INSTALL_EXECUTABLEDIR}")
make_absolute(MUMBLE_INSTALL_ABS_LIBDIR "${MUMBLE_INSTALL_LIBDIR}")
make_absolute(MUMBLE_INSTALL_ABS_PLUGINDIR "${MUMBLE_INSTALL_PLUGINDIR}")

option(display-install-paths "Print out base install paths during project configuration" OFF)

if(display-install-paths)
	message(STATUS "")
	message(STATUS "These are the paths the different components will be installed to:")
	message(STATUS "Executables: \"${MUMBLE_INSTALL_ABS_EXECUTABLEDIR}\"")
	message(STATUS "Libraries:   \"${MUMBLE_INSTALL_ABS_LIBDIR}\"")
	message(STATUS "Plugins:     \"${MUMBLE_INSTALL_ABS_PLUGINDIR}\"")
	message(STATUS "")
endif()
