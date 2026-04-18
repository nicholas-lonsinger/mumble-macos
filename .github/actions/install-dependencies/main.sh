#!/usr/bin/env bash

set -e
set -x

# macOS build dependencies. Canonical list lives in
# docs/dev/build-instructions/build_macos.md.
# cmake is preinstalled on GitHub's macos-15 runners.
brew update
brew install \
	ninja \
	pkg-config \
	qt6 \
	boost \
	libogg \
	libvorbis \
	flac \
	libsndfile \
	protobuf \
	openssl \
	poco
