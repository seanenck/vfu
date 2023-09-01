BIN     := build/
CLI     := $(BIN)vfu
GUI     := $(BIN)vfu-gui
GEN     := vfu/generated.swift
COMPILE := swiftc -O $(GEN)
COMMON  := vfu/vm.swift
CLICODE := vfu/main.swift $(COMMON)
GUICODE := vfu/AppDelegate.swift $(COMMON)
EXAMPLE := examples/*.json
SIGN    := codesign --entitlements vfu/vfu.entitlements --force -s -
VMPY    := $(BIN)vm
DESTDIR := /usr/local/bin

.PHONY: $(EXAMPLE)

all: build

build: prep $(CLI) $(GUI)

prep:
	mkdir -p $(BIN)

$(GEN): $(CLICODE) $(GUICODE)
	cat vfu/generated.template | sed 's/{HASH}/$(shell shasum $(CLICODE) | shasum | cut -c 1-7)/g' > $@

$(CLI): $(GEN) $(CLICODE)
	$(COMPILE) $(CLICODE) -o $@ 
	$(SIGN) $@

$(GUI): $(GEN) $(GUICODE)
	$(COMPILE) $(GUICODE) -o $@ 
	$(SIGN) $@
	
clean:
	rm -rf $(BIN)
	rm -f $(GEN)

check: build $(EXAMPLE)
	$(CLI) --version
	$(CLI) --help

$(EXAMPLE):
	touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img
	$(CLI) --config $@ --verify

contrib: $(VMPY)

$(VMPY): $(CLI)
	cat contrib/vm.py | sed "s/{{VERSION}}/$(shell $(CLI) --version)/" > $(VMPY)

bundle: $(GUICODE) $(GEN)
	xcodebuild archive -archivePath "$(BIN)vfu.app" -scheme "vfu" -sdk "macosx" -configuration Release CODE_SIGNING_ALLOWED=NO
	xcodebuild

install:
	mkdir -p $(DESTDIR)
	install -m755 $(CLI) $(DESTDIR)/vfu
	install -m755 $(VMPY) $(DESTDIR)/vm
	cp -r $(BIN)Release/vfu.app /Applications
