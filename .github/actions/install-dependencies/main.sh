#!/usr/bin/env bash

set -e
set -x

# macOS build dependencies. Canonical list lives in
# docs/dev/build-instructions/build_macos.md.
# cmake is preinstalled on GitHub's macos-15 runners. We deliberately skip
# `brew update` — the runner image ships a recent brew snapshot, and a
# transient formulae.brew.sh outage should not fail the build.
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
