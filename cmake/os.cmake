# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>. 

# Qt-related performance tweaks.
add_definitions(
	"-DQT_USE_FAST_CONCATENATION"
	"-DQT_USE_FAST_OPERATOR_PLUS"
)

find_pkg(OpenSSL QUIET)

if(NOT OpenSSL_FOUND)
	# Homebrew
	set(OPENSSL_ROOT_DIR "/usr/local/opt/openssl")
endif()
