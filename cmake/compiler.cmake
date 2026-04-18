# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

include(CompilerFlags)
include(CheckCXXCompilerFlag)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(WANTED_FEATURES "ENABLE_MOST_WARNINGS" "ENSURE_DEFAULT_CHAR_IS_SIGNED")

if(CMAKE_BUILD_TYPE STREQUAL "Release")
	list(APPEND WANTED_FEATURES "OPTIMIZE_FOR_SPEED")
endif()

if(warnings-as-errors)
	list(APPEND WANTED_FEATURES "ENABLE_WARNINGS_AS_ERRORS")
endif()

get_compiler_flags(
	${WANTED_FEATURES}
	OUTPUT_VARIABLE MUMBLE_COMPILER_FLAGS
)

message(STATUS "Using (among others) the following compiler flags: ${MUMBLE_COMPILER_FLAGS}")

add_compile_options(
	"-fvisibility=hidden"
)

if(optimize)
	add_compile_options(
		"-march=native"
	)
endif()

add_link_options("-Wl,-dead_strip")

if(symbols)
	add_compile_options(
		"-gfull"
		"-gdwarf-2"
	)
endif()

function(target_disable_warnings TARGET)
	get_compiler_flags(
		DISABLE_ALL_WARNINGS
		DISABLE_DEFAULT_FLAGS
		OUTPUT_VARIABLE NO_WARNING_FLAGS
	)

	target_compile_options(${TARGET} PRIVATE ${NO_WARNING_FLAGS})
endfunction()
