BIN     := build/
CLI     := $(BIN)vfu
GEN     := vfu/generated.swift
COMPILE := swiftc -O $(GEN)
COMMON  := vfu/vm.swift
CLICODE := vfu/main.swift $(COMMON)
DESTDIR := $(HOME)/.bin/ 
EXAMPLE := examples/*.json

.PHONY: $(EXAMPLE)

all: build

build: prep $(CLI) sign

prep:
	mkdir -p $(BIN)

$(GEN): $(CLICODE)
	cat vfu/generated.template | sed 's/{HASH}/$(shell shasum $(CLICODE) | shasum | cut -c 1-7)/g' > $@

$(CLI): $(GEN) $(CLICODE)
	$(COMPILE) $(CLICODE) -o $@ 

sign: $(CLI)
	codesign --entitlements vfu/vfu.entitlements --force -s - $<
	
clean:
	rm -rf $(BIN)
	rm -f $(GEN)

check: build $(EXAMPLE)
	$(CLI) --version
	$(CLI) --help

$(EXAMPLE):
	touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img
	$(CLI) --config $@ --verify

install:
	install -m755 $(CLI) $(DESTDIR)
