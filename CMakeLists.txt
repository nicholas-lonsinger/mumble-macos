# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.


cmake_minimum_required(VERSION 3.23...4.2)

set(BUILD_NUMBER CACHE STRING "The build number of the current build. Will be used in Mumble's version to make sure newer builds upgrade older installations properly.")
set(BUILD_RELEASE_DATE CACHE STRING "The release date to be used in the generated appstream metadata.")

if ("${BUILD_NUMBER}" STREQUAL "")
	if(packaging)
		message(FATAL_ERROR "Tried to create a Mumble package, without specifying BUILD_NUMBER!")
	else()
		set(BUILD_NUMBER "0")
	endif()
endif()

project(mumble
	VERSION "1.7.${BUILD_NUMBER}"
	DESCRIPTION "Open source, low-latency, high quality voice chat."
	HOMEPAGE_URL "https://www.mumble.info"
	LANGUAGES "C" "CXX"
)

set(3RDPARTY_DIR "${CMAKE_SOURCE_DIR}/3rdparty")
set(PLUGINS_DIR "${CMAKE_SOURCE_DIR}/plugins")

list(APPEND CMAKE_MODULE_PATH
	"${CMAKE_SOURCE_DIR}/cmake"
	"${CMAKE_SOURCE_DIR}/cmake/FindModules"
	"${3RDPARTY_DIR}/cmake-compiler-flags"
)

if(NOT DEFINED CMAKE_CXX_STANDARD OR CMAKE_CXX_STANDARD LESS 20)
	set(CMAKE_CXX_STANDARD 20)
endif()
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)


include(pkg-utils)
include(project-utils)
include(TargetArch)
include(CheckIPOSupported)

find_package(Python 3 COMPONENTS Interpreter REQUIRED)


check_ipo_supported(RESULT LTO_DEFAULT)



option(optimize "Build a heavily optimized version, specific to the machine it's being compiled on." OFF)
option(static "Build static binaries." OFF)
option(symbols "Build binaries in a way that allows easier debugging." OFF)
option(warnings-as-errors "All warnings are treated as errors." ON)
option(use-timestamps "Allow using compile-time timestamps" ON)

option(client "Build the client (Mumble)" ON)
option(packaging "Build package." OFF)
option(tests "Build tests." ${packaging})
option(plugins "Build plugins." ON)

option(debug-dependency-search "Prints extended information during the search for the needed dependencies" OFF)

if(NOT CMAKE_BUILD_TYPE)
	set_property(CACHE CMAKE_BUILD_TYPE PROPERTY VALUE "Release")
elseif(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_definitions(
        "-DDEBUG"
        "-DSNAPSHOT_BUILD"
    )
endif()

if (NOT DEFINED CMAKE_CXX_SCAN_FOR_MODULES)
	# For now, we don't use C++ modules, so we can save ourselves the overhead
	# of scanning every source file (and excluding them from unity buils)
	set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
endif()

option(lto "Enables link-time optimizations for release builds" ${LTO_DEFAULT})

option(bundled-utfcpp "Use the bundled utf8cpp version instead of looking for one on the system" ON)

include(compiler)
include(os)

target_architecture(MUMBLE_TARGET_ARCH)
string(TOLOWER "${MUMBLE_TARGET_ARCH}" MUMBLE_TARGET_ARCH)

# On macOS universal builds, CMAKE_OSX_ARCHITECTURES (and thus target_architecture())
# can result in a CMake list (e.g. "arm64;x86_64"). Using that list directly in
# compile definitions breaks quoting for some generators (notably Unix Makefiles).
# For those cases, expose a stable, single-string arch identifier.
if(APPLE AND MUMBLE_TARGET_ARCH MATCHES ";")
	set(MUMBLE_TARGET_ARCH "universal")
endif()

message(STATUS "##################################################")
message(STATUS "Mumble version:              ${PROJECT_VERSION}")
message(STATUS "Architecture:                ${MUMBLE_TARGET_ARCH}")
if(NOT IS_MULTI_CONFIG)
    message(STATUS "Build type:                  ${CMAKE_BUILD_TYPE}")
else()
    message(STATUS "Using multi-config generator that will determine build type on-the-fly")
endif()
message(STATUS "Using LTO in release builds: ${lto}")
message(STATUS "##################################################")

include(install-paths)

# We have to check for BUILD_TESTING before including CTest as CTest defines this variable
if(DEFINED BUILD_TESTING AND NOT BUILD_TESTING_CHECKED)
	message(WARNING "Use of option \"BUILD_TESTING\" is deprecated. Use \"tests\" instead.")

	if(NOT tests)
		# Allow deprecated option to enable tests if they had been disabled otherwise
		set(tests "${BUILD_TESTING}")
	endif()
endif()

set(BUILD_TESTING_CHECKED ON INTERNAL CACHE BOOL "Persistent helper variable" FORCE)

if(tests)
	include(CTest)
endif()

if(NOT APPLE)
	message(FATAL_ERROR "This fork only targets macOS")
endif()
set(MUMBLE_TARGET_OS "macos")

# Get compilation year
if (use-timestamps)
	string(TIMESTAMP MUMBLE_BUILD_YEAR "%Y")
else()
	set(MUMBLE_BUILD_YEAR "now")
endif()

# Make the build year accessible as a macro
add_compile_definitions(MUMBLE_BUILD_YEAR=${MUMBLE_BUILD_YEAR})

# Make sure that math constants are always defined
add_compile_definitions(_USE_MATH_DEFINES)


# Provide the information about the target architecture to all Mumble source files in form of a macro
add_compile_definitions(MUMBLE_TARGET_ARCH="${MUMBLE_TARGET_ARCH}")

# Also provide information about the target OS
add_compile_definitions(MUMBLE_TARGET_OS="${MUMBLE_TARGET_OS}")


set(CMAKE_UNITY_BUILD_BATCH_SIZE 40)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ${lto})
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_DEBUG OFF)

if(bundled-utfcpp)
	add_subdirectory(${3RDPARTY_DIR}/utfcpp)
else()
	find_pkg("utf8cpp" REQUIRED)
	add_library(utfcpp ALIAS utf8cpp::utf8cpp)
endif()

if(plugins AND client)
	add_subdirectory(plugins)
endif()

if(client)
	add_subdirectory(src)
endif()

add_subdirectory(auxiliary_files)

