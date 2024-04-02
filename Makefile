BIN     := build/
CLI     := $(BIN)vfu
GUI     := $(BIN)vfu-gui
COMPILE := mkdir -p $(BIN) && swiftc -O vfu/vm.swift
SIGN    := codesign --entitlements vfu/vfu.entitlements --force -s -
SOURCE  := $(shell find vfu/ -type f)

all: build

build: $(CLI) $(GUI)

$(CLI): $(SOURCE)
	$(COMPILE) vfu/main.swift -o $@ 
	$(SIGN) $@

$(GUI): $(SOURCE)
	$(COMPILE) vfu/AppDelegate.swift -o $@ 
	$(SIGN) $@
	
clean:
	rm -rf $(BIN)

check: build
	$(CLI) --help
	@touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img
	@for file in examples/*; do \
		echo "testing: $$file"; \
		$(CLI) --config $$file --verify; \
		cat $$file | $(CLI) --config - --verify; \
	done

bundle:
	xcodebuild archive -archivePath "$(BIN)vfu.app" -scheme "vfu" -sdk "macosx" -configuration Release CODE_SIGNING_ALLOWED=NO
	xcodebuild
