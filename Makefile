APP_NAME  := AgentTrafficLight
BUILD_DIR := .build/release
APP_DIR   := $(BUILD_DIR)/$(APP_NAME).app
BIN_DIR   := $(APP_DIR)/Contents/MacOS
RES_DIR   := $(APP_DIR)/Contents/Resources
PLIST     := Resources/Info.plist
HELPER    := bin/agent-light-update
ICON      := Resources/AgentTrafficLight.icns

.PHONY: build clean install run dist help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build release binary and bundle .app
	@echo "🔨 Building release binary..."
	swift build -c release --arch arm64
	@echo "📦 Creating .app bundle..."
	rm -rf "$(APP_DIR)"
	mkdir -p "$(BIN_DIR)" "$(RES_DIR)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(BIN_DIR)/"
	cp "$(PLIST)" "$(APP_DIR)/Contents/"
	cp "$(ICON)" "$(RES_DIR)/"
	cp "$(HELPER)" "$(RES_DIR)/"
	chmod +x "$(RES_DIR)/agent-light-update"
	@echo "✅ Done: $(APP_DIR)"

clean: ## Clean build artifacts
	rm -rf .build
	@echo "Cleaned."

install: build ## Install to /Applications
	@echo "📥 Installing to /Applications..."
	cp -R "$(APP_DIR)" /Applications/
	@echo "✅ Installed: /Applications/$(APP_NAME).app"

run: build ## Build and launch
	open "$(APP_DIR)"

dist: build ## Create a distributable zip
	cd "$(BUILD_DIR)" && zip -r "$(APP_NAME).zip" "$(APP_NAME).app"
	@echo "✅ Distribution: $(BUILD_DIR)/$(APP_NAME).zip"
