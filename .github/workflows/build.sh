#!/usr/bin/env bash

set -e
set -x

arch="${1:-arm64}"

buildDir="${GITHUB_WORKSPACE}/build"

mkdir -p "$buildDir"

cd "$buildDir"

# Run cmake with all necessary options. Server is off per the project's
# macOS-native scope (see CLAUDE.md); tests fan out from -Dtests=ON in
# $CMAKE_OPTIONS set by the workflow.
cmake -G Ninja \
	  -S "$GITHUB_WORKSPACE" \
	  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
	  -DCMAKE_OSX_ARCHITECTURES="$arch" \
	  -Dserver=OFF \
	  $CMAKE_OPTIONS \
	  -DCMAKE_UNITY_BUILD=ON

cmake --build . --config "$BUILD_TYPE"
