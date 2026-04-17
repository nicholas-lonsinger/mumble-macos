add_library(utfcpp INTERFACE)

target_include_directories(utfcpp SYSTEM INTERFACE
	"$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/source>"
)
