BIN     := build/
CLI     := $(BIN)main
DESTDIR := /usr/local/bin
BUNDLE  := $(BIN)Release/vfu.app
OBJECTS := $(CLI)
SOURCE  := $(shell find vfu/ -type f)

all: $(CLI) $(BUNDLE)

$(CLI): $(SOURCE)
	mkdir -p $(BIN)
	swiftc -O vfu/vm.swift vfu/$(shell basename $@).swift -o $@
	codesign --entitlements vfu/vfu.entitlements --force -s - $@

clean:
	rm -rf $(BIN)

check: $(CLI)
	$(CLI) --help
	@touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img $(BIN)nvme.img
	@for file in examples/*; do \
		echo "testing: $$file"; \
		$(CLI) --config $$file --verify; \
		cat $$file | $(CLI) --config - --verify; \
	done

$(BUNDLE): $(SOURCE)
	xcodebuild archive -archivePath "$(BIN)vfu.app" -scheme "vfu" -sdk "macosx" -configuration Release CODE_SIGNING_ALLOWED=NO
	xcodebuild

install:
	test ! -e $(CLI) || install -m755 $(CLI) $(DESTDIR)/vfu
	test ! -d $(BUNDLE) || cp -r $(BUNDLE) /Applications/
