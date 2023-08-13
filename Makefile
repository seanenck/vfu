BIN     := build/
TARGET  := $(BIN)vfu
FLAGS   := -O
GEN     := vfu/generated.swift
CODE    := vfu/main.swift
DESTDIR := $(HOME)/.bin/ 
EXAMPLE := examples/*.json

.PHONY: $(EXAMPLE)

all:	prep $(TARGET) sign

prep:
	mkdir -p $(BIN)

$(GEN): $(CODE)
	cat vfu/generated.template | sed 's/{HASH}/$(shell shasum $(CODE) | cut -c 1-7)/g' > $@

$(TARGET): $(GEN) $(CODE)
	swiftc $(FLAGS) -o $(TARGET) $(CODE) $(GEN)

sign: $(TARGET)
	codesign --entitlements vfu/vfu.entitlements --force -s - $<
	
clean:
	rm -rf $(BIN)
	rm -f $(GEN)

check: sign $(EXAMPLE)
	$(TARGET) --version
	$(TARGET) --help

$(EXAMPLE):
	touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img
	$(TARGET) --config $@ --verify


install:
	install -m755 $(TARGET) $(DESTDIR)
