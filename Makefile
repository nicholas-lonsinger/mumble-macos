DERIVED_DATA := ./DerivedData
PROJECT      := mumble-macos.xcodeproj
SCHEME       := mumble-macos

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA)

.PHONY: build release test clean

build:
	$(XCODEBUILD) -configuration Debug build

release:
	$(XCODEBUILD) -configuration Release build

test:
	$(XCODEBUILD) test

clean:
	rm -rf $(DERIVED_DATA)
