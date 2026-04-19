# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

set(MUMBLE_PLIST "${CMAKE_CURRENT_BINARY_DIR}/mumble.plist")

set(MUMBLE_ICNS "${CMAKE_SOURCE_DIR}/icons/mumble.icns")

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/mumble.plist.in" "${MUMBLE_PLIST}")

include(qt-utils)
include(install-library)

option(translations "Include languages other than English." ON)
option(bundle-qt-translations "Bundle Qt's translations as well" ${static}) 

option(bundled-speex "Build the included version of Speex instead of looking for one on the system." ON)
option(rnnoise "Use RNNoise for machine learning noise reduction." ON)
option(bundled-rnnoise "Build the included version of RNNoise instead of looking for one on the system." ${rnnoise})

option(manual-plugin "Include the built-in \"manual\" positional audio plugin." ON)

option(qtspeech "Use Qt's text-to-speech system (part of the Qt Speech module) instead of Mumble's own OS-specific text-to-speech implementations." OFF)

option(plugin-debug "Build Mumble with debug output for plugin developers." OFF)
option(plugin-callback-debug "Build Mumble with debug output for plugin callbacks inside of Mumble." OFF)

option(coreaudio "Build support for CoreAudio." ON)

find_pkg(Qt6
	COMPONENTS
		Concurrent
		Sql
		Svg
		Widgets
	REQUIRED
)

set(MUMBLE_SOURCES
	"About.cpp"
	"About.h"
	"Accessibility.cpp"
	"Accessibility.h"
	"ACLEditor.cpp"
	"ACLEditor.h"
	"ACLEditor.ui"
	"API_v_1_x_x.cpp"
	"API.h"
	"AudioConfigDialog.cpp"
	"AudioConfigDialog.h"
	"Audio.cpp"
	"Audio.h"
	"AudioOutputCache.cpp"
	"AudioOutputCache.h"
	"AudioInput.cpp"
	"AudioInput.h"
	"AudioInput.ui"
	"AudioOutput.cpp"
	"AudioOutput.h"
	"AudioOutputSample.cpp"
	"AudioOutputSample.h"
	"AudioOutputSpeech.cpp"
	"AudioOutputSpeech.h"
	"AudioOutput.ui"
	"AudioOutputBuffer.cpp"
	"AudioOutputBuffer.h"
	"AudioOutputToken.h"
	"AudioPreprocessor.cpp"
	"AudioPreprocessor.h"
	"AudioStats.cpp"
	"AudioStats.h"
	"AudioStats.ui"
	"AudioWizard.cpp"
	"AudioWizard.h"
	"AudioWizard.ui"
	"BanEditor.cpp"
	"BanEditor.h"
	"BanEditor.ui"
	"Cert.cpp"
	"Cert.h"
	"Cert.ui"
	"ChannelFilterMode.h"
	"ClientUser.cpp"
	"ClientUser.h"
	"ConfigDialog.cpp"
	"ConfigDialog.h"
	"ConfigDialog.ui"
	"ConfigWidget.cpp"
	"ConfigWidget.h"
	"ConnectDialog.cpp"
	"ConnectDialogEdit.ui"
	"ConnectDialog.h"
	"ConnectDialog.ui"
	"QuitBehavior.h"
	"CustomElements.cpp"
	"CustomElements.h"
	"Database.cpp"
	"Database.h"
	"DeveloperConsole.cpp"
	"DeveloperConsole.h"
	"EchoCancelOption.cpp"
	"EchoCancelOption.h"
	"EnumStringConversions.cpp"
	"EnumStringConversions.h"
	"Global.cpp"
	"Global.h"
	"GlobalShortcut.cpp"
	"GlobalShortcut.h"
	"GlobalShortcut.ui"
	"GlobalShortcutButtons.cpp"
	"GlobalShortcutButtons.h"
	"GlobalShortcutButtons.ui"
	"GlobalShortcutTarget.ui"
	"GlobalShortcutTypes.h"
	"JSONSerialization.cpp"
	"JSONSerialization.h"
	"LegacyPlugin.cpp"
	"LegacyPlugin.h"
	"ListenerVolumeSlider.cpp"
	"ListenerVolumeSlider.h"
	"Log.cpp"
	"Log.h"
	"Log.ui"
	"LookConfig.cpp"
	"LookConfig.h"
	"LookConfig.ui"
	"MainWindow.cpp"
	"MainWindow.h"
	"MainWindow.ui"
	"Markdown.cpp"
	"Markdown.h"
	"MenuLabel.cpp"
	"MenuLabel.h"
	"Messages.cpp"
	"MumbleApplication.cpp"
	"MumbleApplication.h"
	"NetworkConfig.cpp"
	"NetworkConfig.h"
	"NetworkConfig.ui"
	"PluginConfig.cpp"
	"PluginConfig.h"
	"PluginConfig.ui"
	"Plugin.cpp"
	"Plugin.h"
	"PluginInstaller.cpp"
	"PluginInstaller.h"
	"PluginInstaller.ui"
	"PluginManager.cpp"
	"PluginManager.h"
	"PluginManifest.cpp"
	"PluginManifest.h"
	"PluginUpdater.cpp"
	"PluginUpdater.h"
	"PluginUpdater.ui"
	"PositionalAudioViewer.cpp"
	"PositionalAudioViewer.h"
	"PositionalAudioViewer.ui"
	"PositionalData.cpp"
	"PositionalData.h"
	"PTTButtonWidget.cpp"
	"PTTButtonWidget.h"
	"PTTButtonWidget.ui"
	"QtWidgetUtils.cpp"
	"QtWidgetUtils.h"
	"RichTextEditor.cpp"
	"RichTextEditor.h"
	"RichTextEditorLink.ui"
	"RichTextEditor.ui"
	"Screen.cpp"
	"Screen.h"
	"SearchDialog.cpp"
	"SearchDialog.h"
	"SearchDialog.ui"
	"ServerHandler.cpp"
	"ServerHandler.h"
	"ServerInformation.cpp"
	"ServerInformation.h"
	"ServerInformation.ui"
	"SettingsKeys.cpp"
	"SettingsKeys.h"
	"Settings.cpp"
	"Settings.h"
	"SharedMemory.cpp"
	"SharedMemory.h"
	"SocketRPC.cpp"
	"SocketRPC.h"
	"SvgIcon.cpp"
	"SvgIcon.h"
	"TalkingUI.cpp"
	"TalkingUI.h"
	"TalkingUIContainer.cpp"
	"TalkingUIContainer.h"
	"TalkingUIEntry.cpp"
	"TalkingUIEntry.h"
	"TalkingUISelection.cpp"
	"TalkingUISelection.h"
	"TextMessage.cpp"
	"TextMessage.h"
	"TextMessage.ui"
	"TextToSpeech.h"
	"ThemeInfo.cpp"
	"ThemeInfo.h"
	"Themes.cpp"
	"Themes.h"
	"Tokens.cpp"
	"Tokens.h"
	"Tokens.ui"
	"Translations.cpp"
	"Translations.h"
	"UserEdit.cpp"
	"UserEdit.h"
	"UserEdit.ui"
	"UserInformation.cpp"
	"UserInformation.h"
	"UserInformation.ui"
	"UserListModel.cpp"
	"UserListModel.h"
	"UserLocalNicknameDialog.cpp"
	"UserLocalNicknameDialog.h"
	"UserLocalNicknameDialog.ui"
	"UserLocalVolumeSlider.cpp"
	"UserLocalVolumeSlider.h"
	"UserModel.cpp"
	"UserModel.h"
	"UserView.cpp"
	"UserView.h"
	"ViewCert.cpp"
	"ViewCert.h"
	"VoiceRecorder.cpp"
	"VoiceRecorderDialog.cpp"
	"VoiceRecorderDialog.h"
	"VoiceRecorderDialog.ui"
	"VoiceRecorder.h"
	"VolumeSliderWidgetAction.cpp"
	"VolumeSliderWidgetAction.h"
	"WebFetch.cpp"
	"WebFetch.h"
	"XMLTools.cpp"
	"XMLTools.h"

	"widgets/AccessibleQGroupBox.cpp"
	"widgets/AccessibleQGroupBox.h"
	"widgets/BanDialog.cpp"
	"widgets/BanDialog.h"
	"widgets/BanDialog.ui"
	"widgets/ClickableLabel.h"
	"widgets/CompletablePage.cpp"
	"widgets/CompletablePage.h"
	"widgets/EventFilters.cpp"
	"widgets/EventFilters.h"
	"widgets/FailedConnectionDialog.cpp"
	"widgets/FailedConnectionDialog.h"
	"widgets/FailedConnectionDialog.ui"
	"widgets/MUComboBox.cpp"
	"widgets/MUComboBox.h"
	"widgets/MultiStyleWidgetWrapper.cpp"
	"widgets/MultiStyleWidgetWrapper.h"
	"widgets/MultiColumnTreeWidget.cpp"
	"widgets/MultiColumnTreeWidget.h"
	"widgets/RichTextItemDelegate.cpp"
	"widgets/RichTextItemDelegate.h"
	"widgets/SearchDialogItemDelegate.cpp"
	"widgets/SearchDialogItemDelegate.h"
	"widgets/SearchDialogTree.cpp"
	"widgets/SearchDialogTree.h"
	"widgets/SemanticSlider.cpp"
	"widgets/SemanticSlider.h"
	"widgets/TrayIcon.cpp"
	"widgets/TrayIcon.h"
	"widgets/ResponsiveImageDialog.cpp"
	"widgets/ResponsiveImageDialog.h"


	"${SHARED_SOURCE_DIR}/ACL.cpp"
	"${SHARED_SOURCE_DIR}/ACL.h"
	"${SHARED_SOURCE_DIR}/Channel.cpp"
	"${SHARED_SOURCE_DIR}/Channel.h"
	"${SHARED_SOURCE_DIR}/ChannelListenerManager.cpp"
	"${SHARED_SOURCE_DIR}/ChannelListenerManager.h"
	"${SHARED_SOURCE_DIR}/Connection.cpp"
	"${SHARED_SOURCE_DIR}/Connection.h"
	"${SHARED_SOURCE_DIR}/Group.cpp"
	"${SHARED_SOURCE_DIR}/Group.h"
	"${SHARED_SOURCE_DIR}/SignalCurry.h"
	"${SHARED_SOURCE_DIR}/User.cpp"
	"${SHARED_SOURCE_DIR}/User.h"

	"mumble.qrc"
	"${CMAKE_SOURCE_DIR}/themes/DefaultTheme.qrc"
)

add_library(smallft STATIC "${3RDPARTY_DIR}/smallft/smallft.cpp")
target_include_directories(smallft PUBLIC "${3RDPARTY_DIR}/smallft")
target_disable_warnings(smallft)

add_custom_command(
	OUTPUT "${CMAKE_BINARY_DIR}/mumble_flags.qrc"
	COMMAND Python::Interpreter
	ARGS "${CMAKE_SOURCE_DIR}/scripts/generate_flag_qrc.py" --flag-dir "${CMAKE_SOURCE_DIR}/3rdparty/flag-icons/flags/4x3" --output "${CMAKE_BINARY_DIR}/mumble_flags.qrc"
	COMMENT "Generating mumble_flags.qrc"
)
list(APPEND MUMBLE_SOURCES "${CMAKE_BINARY_DIR}/mumble_flags.qrc")

add_library(mumble_client_object_lib OBJECT ${MUMBLE_SOURCES})
target_link_libraries(mumble_client_object_lib PUBLIC smallft)

add_executable(mumble "main.cpp")

set_source_files_properties("${MUMBLE_ICNS}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
target_sources(mumble PRIVATE "${MUMBLE_ICNS}")

set_target_properties(mumble
	PROPERTIES
		OUTPUT_NAME "Mumble"
		MACOSX_BUNDLE TRUE
		MACOSX_BUNDLE_INFO_PLIST ${MUMBLE_PLIST}
)

add_custom_command(
	OUTPUT "ApplicationPalette.h"
	COMMAND Python::Interpreter
	ARGS ${CMAKE_SOURCE_DIR}/scripts/generate-ApplicationPalette-class.py --template ${CMAKE_CURRENT_SOURCE_DIR}/ApplicationPaletteTemplate.h
		--output ApplicationPalette.h
	COMMENT "Generating ApplicationPalette.h"
	DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ApplicationPaletteTemplate.h"
)
target_sources(mumble PRIVATE "ApplicationPalette.h")
target_include_directories(mumble PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

target_link_libraries(mumble PRIVATE mumble_client_object_lib shared spdlog::spdlog)
target_link_libraries(mumble PRIVATE CLI11::CLI11)

target_compile_definitions(mumble_client_object_lib
	PUBLIC
	"MUMBLE_LIBRARY_PATH=${MUMBLE_INSTALL_ABS_LIBDIR}"
	"MUMBLE_PLUGIN_PATH=${MUMBLE_INSTALL_ABS_PLUGINDIR}"
)

set_target_properties(mumble PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

set_target_properties(mumble_client_object_lib
	PROPERTIES
		AUTOMOC ON
		AUTORCC ON
		AUTOUIC ON
)

set_target_properties(mumble
	PROPERTIES
		AUTOMOC ON
		AUTORCC ON
		AUTOUIC ON
)

install(TARGETS mumble BUNDLE DESTINATION "${MUMBLE_INSTALL_EXECUTABLEDIR}" COMPONENT mumble_client)

# This is used to invalidate the saved widget state if a change in the source is detected.
get_numerical_file_hash("${CMAKE_CURRENT_SOURCE_DIR}/MainWindow.ui" MAINWINDOW_UI_HASH)

message(STATUS "MAINWINDOW_UI_HASH: ${MAINWINDOW_UI_HASH}")

target_compile_definitions(mumble_client_object_lib
	PUBLIC
		"MUMBLE"
		"MUMBLE_MAINWINDOW_UI_HASH=${MAINWINDOW_UI_HASH}"
		"QT_RESTRICTED_CAST_FROM_ASCII"
)

target_include_directories(mumble_client_object_lib
	PUBLIC
		${CMAKE_CURRENT_SOURCE_DIR} # This is required for includes in current folder to be found by files from the shared directory.
		"widgets"
		${SHARED_SOURCE_DIR}
		"${PLUGINS_DIR}"
)

find_pkg(Poco
	COMPONENTS
		XML
		Zip
)

if(TARGET Poco::Zip)
	target_link_libraries(mumble_client_object_lib
		PUBLIC
			Poco::XML
			Poco::Zip
	)
else()
	message(STATUS "Regular Poco search failed - looking for Poco include dir manually...")

	set(POCO_INCLUDE_DIR_HINT "/usr/include")

	find_path(POCO_INCLUDE_DIR "Poco/Poco.h" HINTS ${POCO_INCLUDE_DIR_HINT})

	if(POCO_INCLUDE_DIR)
		message(STATUS "Found Poco include dir at \"${POCO_INCLUDE_DIR}\"")
	else()
		message(FATAL_ERROR "Unable to locate Poco include directory")
	endif()

	find_library(POCO_LIB_FOUNDATION NAMES PocoFoundation PocoFoundationmd REQUIRED)
	find_library(POCO_LIB_UTIL NAMES PocoUtil PocoUtilmd REQUIRED)
	find_library(POCO_LIB_XML NAMES PocoXML PocoXMLmd REQUIRED)
	find_library(POCO_LIB_ZIP NAMES PocoZip PocoZipmd REQUIRED)

	if(POCO_LIB_ZIP)
		message(STATUS "Found Poco Zip library at \"${POCO_LIB_ZIP}\"")
	else()
		message(FATAL_ERROR "Unable to find Poco Zip library")
	endif()


	# Now use the found include dir and libraries by linking it to the target
	target_include_directories(mumble_client_object_lib
		PUBLIC
			${POCO_INCLUDE_DIR}
	)

	target_link_libraries(mumble_client_object_lib
		PUBLIC
			${POCO_LIB_ZIP}
			${POCO_LIB_XML}
			${POCO_LIB_UTIL}
			${POCO_LIB_FOUNDATION}
	)

	if(static)
		target_compile_definitions(mumble_client_object_lib
			PUBLIC
				POCO_STATIC
		)
	endif()
endif()


if (NOT TARGET nlohmann_json)
	if(bundled-json)
		set(JSON_BuildTests OFF CACHE INTERNAL "")
		set(JSON_ImplicitConversions ON CACHE INTERNAL "")
		set(JSON_SystemInclude ON CACHE INTERNAL "")
		add_subdirectory("${3RDPARTY_DIR}/nlohmann_json/" "${CMAKE_CURRENT_BINARY_DIR}/nlohmann_json/" EXCLUDE_FROM_ALL)
	else()
		find_pkg("nlohmann_json" REQUIRED)
	endif()
endif()

target_link_libraries(mumble_client_object_lib PUBLIC nlohmann_json::nlohmann_json)

find_pkg("SndFile;LibSndFile;sndfile" REQUIRED)

# Check if sndfile version supports opus
if("${sndfile_VERSION}" VERSION_GREATER_EQUAL "1.0.29")
	target_compile_definitions(mumble_client_object_lib PUBLIC USE_SNDFILE_OPUS)
else()
	message(WARNING "libsndfile is missing Opus-support -> No Opus-format recording")
endif()

# Check if sndfile version supports mp3
if("${sndfile_VERSION}" VERSION_GREATER_EQUAL "1.1.0")
	target_compile_definitions(mumble_client_object_lib PUBLIC USE_SNDFILE_MP3)
else()
	message(WARNING "libsndfile is missing Mp3-support -> No Mp3-format recording")
endif()

# Look for various targets as they are named differently on different platforms
if(static AND TARGET sndfile-static)
	target_link_libraries(mumble_client_object_lib PUBLIC sndfile-static)
elseif(TARGET SndFile::sndfile)
	target_link_libraries(mumble_client_object_lib PUBLIC SndFile::sndfile)
elseif(TARGET sndfile)
	target_link_libraries(mumble_client_object_lib PUBLIC sndfile)
else()
	target_link_libraries(mumble_client_object_lib PUBLIC ${sndfile_LIBRARIES})
endif()

target_link_libraries(mumble_client_object_lib
	PUBLIC
		shared
		utfcpp
		Qt6::Concurrent
		Qt6::Sql
		Qt6::Svg
		Qt6::Widgets
)

if(static)
	if(TARGET Qt6::QSQLiteDriverPlugin)
		include_qt_plugin(mumble_client_object_lib PRIVATE "QSQLiteDriverPlugin")
		target_link_libraries(mumble_client_object_lib PUBLIC Qt6::QSQLiteDriverPlugin)
	endif()
	if(TARGET Qt6::QSvgIconPlugin)
		include_qt_plugin(mumble_client_object_lib PRIVATE "QSvgIconPlugin")
		target_link_libraries(mumble_client_object_lib PUBLIC Qt6::QSvgIconPlugin)
	endif()
	if(TARGET Qt6::QSvgPlugin)
		include_qt_plugin(mumble_client_object_lib PRIVATE "QSvgPlugin")
		target_link_libraries(mumble_client_object_lib PUBLIC Qt6::QSvgPlugin)
	endif()
endif()

target_compile_definitions(mumble_client_object_lib PUBLIC "RESTRICT=__restrict__")

target_sources(mumble_client_object_lib PRIVATE "SharedMemory_unix.cpp")

find_library(LIB_APPKIT "AppKit")
find_library(LIB_APPLICATIONSERVICES "ApplicationServices")
find_library(LIB_CARBON "Carbon")
find_library(LIB_SECURITY "Security")

target_sources(mumble_client_object_lib
	PRIVATE
		"AppNap.h"
		"AppNap.mm"
		"ThemeSwitch_macx.mm"
		"GlobalShortcut_macx.h"
		"GlobalShortcut_macx.mm"
		"os_macx.mm"
)

if(static AND TARGET Qt6::QCocoaIntegrationPlugin)
	include_qt_plugin(mumble_client_object_lib PRIVATE QCocoaIntegrationPlugin)
	target_link_libraries(mumble_client_object_lib PUBLIC Qt6::QCocoaIntegrationPlugin)
endif()

target_link_libraries(mumble_client_object_lib
	PUBLIC
		${LIB_APPKIT}
		${LIB_APPLICATIONSERVICES}
		${LIB_CARBON}
		${LIB_SECURITY}
)

find_pkg("opus;Opus" REQUIRED)
target_include_directories(mumble_client_object_lib PUBLIC ${opus_INCLUDE_DIRS})
target_link_libraries(mumble_client_object_lib PUBLIC ${opus_LIBRARIES})
if(TARGET opus)
	target_link_libraries(mumble_client_object_lib PUBLIC opus)
elseif(TARGET Opus)
	target_link_libraries(mumble_client_object_lib PUBLIC Opus)
elseif(TARGET Opus::opus)
	target_link_libraries(mumble_client_object_lib PUBLIC Opus::opus)
endif()

if(bundled-speex)
	add_subdirectory("${3RDPARTY_DIR}/speexdsp-build" "${CMAKE_CURRENT_BINARY_DIR}/speexdsp" EXCLUDE_FROM_ALL)

	# Disable all warnings that the speexdsp code may emit
	disable_warnings_for_all_targets_in("${3RDPARTY_DIR}/speexdsp-build")

	target_link_libraries(mumble_client_object_lib PUBLIC speexdsp)

	set_target_properties(speexdsp PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

	install_library(speexdsp mumble_client)
else()
	find_pkg(speexdsp REQUIRED)

	target_link_libraries(mumble_client_object_lib
		PUBLIC
			${speexdsp_LIBRARIES}
	)
endif()

if(rnnoise)
	target_compile_definitions(mumble_client_object_lib PRIVATE "USE_RNNOISE")

	if(bundled-rnnoise)
		add_subdirectory("${3RDPARTY_DIR}/rnnoise-build" "${CMAKE_CURRENT_BINARY_DIR}/rnnoise" EXCLUDE_FROM_ALL)

		# Disable all warnings that the RNNoise code may emit
		disable_warnings_for_all_targets_in("${3RDPARTY_DIR}/rnnoise-build")

		target_link_libraries(mumble_client_object_lib PRIVATE rnnoise)

		set_target_properties(rnnoise PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

		install_library(rnnoise mumble_client)
	else()
		find_pkg(rnnoise REQUIRED)

		target_link_libraries(mumble_client_object_lib PRIVATE ${rnnoise_LIBRARIES})
	endif()
endif()

if(qtspeech)
	find_pkg(Qt6 COMPONENTS TextToSpeech REQUIRED)
	target_sources(mumble_client_object_lib PRIVATE "TextToSpeech.cpp")
	target_link_libraries(mumble_client_object_lib PUBLIC Qt6::TextToSpeech)
else()
	target_sources(mumble_client_object_lib PRIVATE "TextToSpeech_macx.mm")
	# NSSpeechSynthesizer was deprecated in macOS 14 in favor of AVSpeechSynthesizer.
	# Tracked for replacement in https://github.com/nicholas-lonsinger/mumble-macos/issues/1;
	# suppress the deprecation warning locally until that port lands so the build
	# stays green at our min deployment target (macOS 15).
	set_source_files_properties("TextToSpeech_macx.mm"
		PROPERTIES COMPILE_OPTIONS "-Wno-deprecated-declarations")
endif()

if(manual-plugin)
	target_sources(mumble_client_object_lib
		PRIVATE
			"ManualPlugin.cpp"
			"ManualPlugin.h"
			"ManualPlugin.ui"
	)

target_compile_definitions(mumble_client_object_lib PUBLIC "USE_MANUAL_PLUGIN")
endif()

if(translations)
	# Glob for all translation files in the source dir
	file(GLOB TS_FILES "${CMAKE_CURRENT_SOURCE_DIR}/*.ts")

	include_translations(QRC_FILE ${CMAKE_CURRENT_BINARY_DIR} "${TS_FILES}")
	target_sources(mumble_client_object_lib PRIVATE "${QRC_FILE}")

	if(bundle-qt-translations)
		bundle_qt_translations(mumble_client_object_lib)
	endif()
elseif(bundle-qt-translations)
	message(WARNING "Can't bundle Qt translations if translations are disabled!")
endif()

if(plugins)
	add_dependencies(mumble plugins)
endif()

if(zeroconf)
	target_sources(mumble_client_object_lib
		PRIVATE
			"Zeroconf.cpp"
			"Zeroconf.h"
			# Unlike what the name implies, this 3rdparty helper is not actually related to Bonjour.
			# It just uses the API provided by mDNSResponder, making it compatible with Avahi too.
			"${3RDPARTY_DIR}/qqbonjour/BonjourRecord.h"
			"${3RDPARTY_DIR}/qqbonjour/BonjourServiceBrowser.cpp"
			"${3RDPARTY_DIR}/qqbonjour/BonjourServiceBrowser.h"
			"${3RDPARTY_DIR}/qqbonjour/BonjourServiceResolver.cpp"
			"${3RDPARTY_DIR}/qqbonjour/BonjourServiceResolver.h"
	)

	target_compile_definitions(mumble_client_object_lib PUBLIC "USE_ZEROCONF")
	target_include_directories(mumble_client_object_lib PUBLIC "${3RDPARTY_DIR}/qqbonjour")
endif()

if(coreaudio)
	find_library(LIB_AUDIOUNIT "AudioUnit")
	find_library(LIB_COREAUDIO "CoreAudio")

	target_sources(mumble_client_object_lib
		PRIVATE
			"CoreAudio.mm"
			"CoreAudio.h"
	)

	target_link_libraries(mumble_client_object_lib
		PUBLIC
			${LIB_AUDIOUNIT}
			${LIB_COREAUDIO}
			"-framework AVFoundation"
	)
endif()

if(${CMAKE_VERSION} VERSION_GREATER_EQUAL "3.16.0")
	# Prevent objective C files from being included in unity builds as that causes issues
	set_source_files_properties(
		"AppNap.mm"
		"ThemeSwitch_macx.mm"
		"GlobalShortcut_macx.mm"
		"os_macx.mm"
		"TextToSpeech_macx.mm"
		"CoreAudio.mm"
		PROPERTIES
			SKIP_UNITY_BUILD_INCLUSION TRUE
	)
endif()

if(plugin-debug)
	target_compile_definitions(mumble_client_object_lib PUBLIC "MUMBLE_PLUGIN_DEBUG")
endif()

if(plugin-callback-debug)
	target_compile_definitions(mumble_client_object_lib PUBLIC "MUMBLE_PLUGIN_CALLBACK_DEBUG")
endif()

# Workaround for a cmake bug that causes the auto-generated UI files (AutoUIC) to not be added
# to the target's interface include directories. This can cause missing include errors in targets
# linking to mumble_client_object_lib.
# cmake bug report: https://gitlab.kitware.com/cmake/cmake/-/issues/17456
set(TARGET_NAME "mumble_client_object_lib")
get_property(_isMultiConfig GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(_isMultiConfig)
  set(AUTOGEN_INCLUDE_DIR ${CMAKE_CURRENT_BINARY_DIR}/${TARGET_NAME}_autogen/include_$<CONFIG>)
else()
  set(AUTOGEN_INCLUDE_DIR ${CMAKE_CURRENT_BINARY_DIR}/${TARGET_NAME}_autogen/include)
endif()

target_include_directories(${TARGET_NAME} INTERFACE
  $<BUILD_INTERFACE:${AUTOGEN_INCLUDE_DIR}>
)

# ------------------------------------------------------------------
# MumbleUI.framework (macOS)
#
# Build the native-UI framework at macos/MumbleUI/MumbleUI.xcodeproj
# via xcodebuild and embed it into Mumble.app/Contents/Frameworks/.
# CMake writes Local.xcconfig so the Xcode project resolves Qt from
# the same prefix find_pkg(Qt6) discovered.
# See docs/dev/migration-qt-to-native.md.
# ------------------------------------------------------------------
if(APPLE)
	option(MUMBLE_NATIVE_SHELL
		"Enable the --native CLI flag that bypasses Qt and launches the AppKit shell hosting SwiftUI content"
		OFF
	)
	if(MUMBLE_NATIVE_SHELL)
		target_compile_definitions(mumble PRIVATE MUMBLE_NATIVE_SHELL=1)
	endif()

	get_target_property(_mumbleui_qmake Qt6::qmake IMPORTED_LOCATION)
	execute_process(
		COMMAND "${_mumbleui_qmake}" -query QT_INSTALL_PREFIX
		OUTPUT_VARIABLE _mumbleui_qt_prefix
		OUTPUT_STRIP_TRAILING_WHITESPACE
	)

	set(_mumbleui_root "${CMAKE_SOURCE_DIR}/macos/MumbleUI")
	set(_mumbleui_derived "${CMAKE_BINARY_DIR}/MumbleUI-build")
	set(_mumbleui_config "$<IF:$<CONFIG:Debug>,Debug,Release>")

	file(CONFIGURE
		OUTPUT "${_mumbleui_root}/MumbleUI/Local.xcconfig"
		CONTENT
"// Generated by CMake; do not edit by hand. Re-run cmake to refresh.
// Source template: macos/MumbleUI/MumbleUI/Local.xcconfig.example.

QT6_PREFIX = ${_mumbleui_qt_prefix}

CLANG_CXX_LANGUAGE_STANDARD = gnu++20
FRAMEWORK_SEARCH_PATHS = $(inherited) $(QT6_PREFIX)/lib
OTHER_LDFLAGS = $(inherited) -framework QtCore
"
	)

	file(GLOB_RECURSE _mumbleui_sources CONFIGURE_DEPENDS
		"${_mumbleui_root}/MumbleUI/*.swift"
		"${_mumbleui_root}/MumbleUI/*.h"
		"${_mumbleui_root}/MumbleUI/*.mm"
	)

	set(_mumbleui_stamp "${_mumbleui_derived}/build.stamp")

	add_custom_command(
		OUTPUT "${_mumbleui_stamp}"
		COMMAND "${CMAKE_COMMAND}" -E make_directory "${_mumbleui_derived}"
		COMMAND xcodebuild
			-project "${_mumbleui_root}/MumbleUI.xcodeproj"
			-scheme MumbleUI
			-configuration "${_mumbleui_config}"
			-derivedDataPath "${_mumbleui_derived}"
			CODE_SIGNING_ALLOWED=NO
		COMMAND "${CMAKE_COMMAND}" -E touch "${_mumbleui_stamp}"
		DEPENDS ${_mumbleui_sources}
				"${_mumbleui_root}/MumbleUI/Local.xcconfig"
				"${_mumbleui_root}/MumbleUI/Info.plist"
				"${_mumbleui_root}/MumbleUI.xcodeproj/project.pbxproj"
		COMMENT "Building MumbleUI.framework (xcodebuild)"
		VERBATIM
	)

	add_custom_target(MumbleUI_build DEPENDS "${_mumbleui_stamp}")
	add_dependencies(mumble MumbleUI_build)

	target_compile_options(mumble PRIVATE
		"-F${_mumbleui_derived}/Build/Products/${_mumbleui_config}"
	)
	target_link_options(mumble PRIVATE
		"-F${_mumbleui_derived}/Build/Products/${_mumbleui_config}"
	)
	target_link_libraries(mumble PRIVATE "-framework MumbleUI")
	set_target_properties(mumble PROPERTIES
		INSTALL_RPATH "@loader_path/../Frameworks"
		BUILD_WITH_INSTALL_RPATH TRUE
		LINK_DEPENDS "${_mumbleui_stamp}"
	)

	add_custom_command(TARGET mumble POST_BUILD
		COMMAND "${CMAKE_COMMAND}" -E rm -rf
			"$<TARGET_BUNDLE_DIR:mumble>/Contents/Frameworks/MumbleUI.framework"
		COMMAND ditto --noextattr
			"${_mumbleui_derived}/Build/Products/${_mumbleui_config}/MumbleUI.framework"
			"$<TARGET_BUNDLE_DIR:mumble>/Contents/Frameworks/MumbleUI.framework"
		COMMENT "Embedding MumbleUI.framework into Mumble.app"
		VERBATIM
	)
endif()

