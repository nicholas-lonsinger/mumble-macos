# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

include(delayed_configure_files)
include(pkg-utils)

if(NOT BUILD_RELEASE_DATE)
	# If BUILD_RELEASE_DATE has not been set, default to time of build
	if(use-timestamps)
		string(TIMESTAMP BUILD_RELEASE_DATE "%Y-%m-%d" UTC)
	else()
		set(BUILD_RELEASE_DATE "1970-01-01")
	endif()
endif()

if(overlay)
	if(UNIX AND NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm|aarch64")
		delayed_configure_files(
			TARGET overlay_gl
			FILES
				"${CMAKE_CURRENT_SOURCE_DIR}/run_scripts/mumble-overlay.in=${CMAKE_CURRENT_BINARY_DIR}/mumble-overlay"
			PASSTHROUGH_VARIABLES
				MUMBLE_BUILD_YEAR
				MUMBLE_INSTALL_ABS_LIBDIR
			VARIABLES
				"MUMBLE_OVERLAY_BINARY_BASENAME=$<TARGET_FILE_BASE_NAME:overlay_gl>"
				PYTHON_INTERPRETER Python::Interpreter
			@ONLY
		)

		# install overlay script
		install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/mumble-overlay" DESTINATION "${MUMBLE_INSTALL_SCRIPTDIR}")

		# install overlay man-files
		install(FILES "man_files/mumble-overlay.1" DESTINATION "${MUMBLE_INSTALL_MANDIR}" COMPONENT doc)
	endif()
endif()

if(client AND UNIX AND NOT APPLE)
	delayed_configure_files(
		TARGET mumble
		FILES
		"${CMAKE_CURRENT_SOURCE_DIR}/config_files/info.mumble.Mumble.appdata.xml.in=${CMAKE_CURRENT_BINARY_DIR}/info.mumble.Mumble.appdata.xml"
		"${CMAKE_CURRENT_SOURCE_DIR}/config_files/info.mumble.Mumble.desktop.in=${CMAKE_CURRENT_BINARY_DIR}/info.mumble.Mumble.desktop"
		PASSTHROUGH_VARIABLES
			MUMBLE_BUILD_YEAR
			CMAKE_PROJECT_VERSION
			BUILD_RELEASE_DATE
			CMAKE_PROJECT_HOMEPAGE_URL
			CMAKE_PROJECT_DESCRIPTION
		VARIABLES
			"MUMBLE_CLIENT_BINARY_NAME=$<TARGET_FILE_NAME:mumble>"
		PYTHON_INTERPRETER Python::Interpreter
		@ONLY
	)

	install(FILES "${CMAKE_CURRENT_BINARY_DIR}/info.mumble.Mumble.appdata.xml" DESTINATION "${MUMBLE_INSTALL_METADATADIR}")
	install(FILES "${CMAKE_CURRENT_BINARY_DIR}/info.mumble.Mumble.desktop" DESTINATION "${MUMBLE_INSTALL_APPLICATIONSDIR}")

	# Install Mumble client man files
	install(FILES "man_files/mumble.1" DESTINATION "${MUMBLE_INSTALL_MANDIR}" COMPONENT doc)
endif()


