BIN     := build/
TARGET  := $(BIN)swiftvf
FLAGS   := -O
GEN     := swiftvf/generated.swift
CODE    := swiftvf/main.swift
DESTDIR := $(HOME)/.bin/ 

all:	prep $(TARGET) sign

.PHONY: prep
prep:
	mkdir -p $(BIN)

$(GEN): $(CODE)
	cat generated.template | sed 's/{HASH}/$(shell shasum $(CODE) | cut -c 1-7)/g' > $@

$(TARGET): $(GEN) $(CODE)
	swiftc $(FLAGS) -o $(TARGET) $(CODE) $(GEN)

.PHONY: sign
sign: $(TARGET)
	codesign --entitlements swiftvf/swiftvf.entitlements --force -s - $<
	
clean:
	rm -rf $(BIN)
	rm -f $(GEN)

check: $(TARGET)
	touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img
	$(TARGET) --config example.json --verify
	$(TARGET) --version
	$(TARGET) --help

install:
	install -m755 $(TARGET) $(DESTDIR)
