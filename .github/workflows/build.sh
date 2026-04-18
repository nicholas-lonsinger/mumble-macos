#!/usr/bin/env bash

set -e
set -x

arch="${1:-arm64}"

buildDir="${GITHUB_WORKSPACE}/build"

mkdir -p "$buildDir"

cd "$buildDir"

# Tests fan out from -Dtests=ON in $CMAKE_OPTIONS set by the workflow.
cmake -G Ninja \
	  -S "$GITHUB_WORKSPACE" \
	  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
	  -DCMAKE_OSX_ARCHITECTURES="$arch" \
	  $CMAKE_OPTIONS \
	  -DCMAKE_UNITY_BUILD=ON

cmake --build . --config "$BUILD_TYPE"
