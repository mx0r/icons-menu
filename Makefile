PROJECT := IconsMenu.xcodeproj
BUILD   := .build
PRODUCTS := $(BUILD)/Build/Products/Debug
APP     := $(PRODUCTS)/IconsMenu.app
PROBE   := $(PRODUCTS)/axprobe

# The explicit destination stops xcodebuild warning about arm64 vs x86_64 ambiguity.
XCB := xcodebuild -project $(PROJECT) -configuration Debug -derivedDataPath $(BUILD) \
       -destination 'platform=macOS,arch=arm64' -quiet

FORGE := $(BUILD)/iconforge

.PHONY: all gen icon build run stop install probe clean

all: build

## Regenerate the Xcode project from project.yml
gen:
	xcodegen generate

## Redraw Resources/AppIcon.icns from Sources/Core/IconArtwork.swift.
##
## Compiled straight with swiftc rather than as an Xcode target, because the app target
## references the .icns it produces — going through the project would mean the project could
## not be generated until the icon existed, and vice versa.
icon:
	@mkdir -p $(BUILD)
	@swiftc -O -o $(FORGE) Sources/Core/IconArtwork.swift Sources/iconforge/main.swift
	@$(FORGE) Resources

build: gen
	$(XCB) -scheme IconsMenu build
	$(XCB) -scheme axprobe build

## Rebuild and relaunch. Note that an ad-hoc signature changes on every build, so macOS
## treats each one as a new app and the Accessibility grant has to be given again. Wire a
## real signing identity into project.yml to stop that.
run: build stop
	@open $(APP)
	@echo "IconsMenu launched. If the menu says it needs Accessibility access, re-grant it."

stop:
	@pkill -x IconsMenu 2>/dev/null || true

## Copy to /Applications and run from there.
##
## Worth doing for actual use: a build in .build/ is replaced by the next `make run`,
## whereas the installed copy keeps running — and keeps its Accessibility grant — until you
## deliberately reinstall it.
install: build
	@pkill -x IconsMenu 2>/dev/null || true
	@trash /Applications/IconsMenu.app 2>/dev/null || true
	@cp -R $(APP) /Applications/
	@open /Applications/IconsMenu.app
	@echo "Installed to /Applications and launched. Grant Accessibility once, and it sticks."

## Inspect the menu bar through the same AX layer the app uses.
probe: build
	@$(PROBE)

clean: stop
	@trash $(BUILD) 2>/dev/null || true
	@trash $(PROJECT) 2>/dev/null || true
