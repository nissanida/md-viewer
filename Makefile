# MD Viewer: common tasks. Run `make help` for the list.
# Build products and caches live in ~/Library/Caches/md_html_reader, outside
# iCloud Drive, so thousands of build files are not synced.

CACHE   := $(HOME)/Library/Caches/md_html_reader
APPS    ?= /Applications
BINDIR  ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)/bin
ARCHS   ?= arm64 x86_64
VERSION ?= 0.1.0
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: help run app reveal install install-cli uninstall test test-swift test-web vendor icon clean

help: ## Show this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-12s %s\n", $$1, $$2}'

run: ## Run from source without installing (make run FILE=README.md)
	swift run --scratch-path "$(CACHE)/debug" MDViewer $(FILE)

APP := $(CACHE)/dist/MD Viewer.app

app: ## Build the app (universal; ARCHS=arm64 for a faster build)
	ARCHS="$(ARCHS)" VERSION="$(VERSION)" BUILD_DIR="$(CACHE)" scripts/build-app.sh

reveal: ## Show the built app in Finder (to drag it into Applications yourself)
	open -R "$(APP)"

install: app ## Build, then copy the app to /Applications and register it with Finder
	rm -rf "$(APPS)/MD Viewer.app"
	ditto "$(APP)" "$(APPS)/MD Viewer.app"
	$(LSREGISTER) -f "$(APPS)/MD Viewer.app"
	@# Forget the build copy, so Open With lists the app only once.
	$(LSREGISTER) -u "$(APP)" 2>/dev/null || true
	@echo "Installed $(APPS)/MD Viewer.app"

install-cli: ## Add the `mdviewer` command (a link into the installed app)
	ln -sf "$(APPS)/MD Viewer.app/Contents/Resources/mdviewer" "$(BINDIR)/mdviewer"
	@echo "Linked $(BINDIR)/mdviewer"

uninstall: ## Remove the app and the `mdviewer` command
	$(LSREGISTER) -u "$(APPS)/MD Viewer.app" 2>/dev/null || true
	rm -rf "$(APPS)/MD Viewer.app"
	rm -f "$(BINDIR)/mdviewer"

test: test-swift test-web ## Run all tests

test-swift: ## Swift tests: file watching, folder listing, links, shell lookup
	swift test --scratch-path "$(CACHE)/debug"

test-web: $(CACHE)/node/node_modules/jsdom ## Markdown rendering tests (Node)
	NODE_PATH="$(CACHE)/node/node_modules" node --test "Tests/web/*.test.cjs"

$(CACHE)/node/node_modules/jsdom:
	npm install --prefix "$(CACHE)/node" jsdom@29.1.1 --no-audit --no-fund --silent

vendor: ## Re-download the pinned JavaScript libraries into web/vendor
	scripts/update-vendor.sh

icon: ## Redraw packaging/AppIcon.icns
	scripts/make-icon.sh

clean: ## Delete build products and caches
	rm -rf "$(CACHE)/dist" "$(CACHE)/debug" "$(CACHE)"/release*
