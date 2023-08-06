BIN    := build/
TARGET := $(BIN)swiftvf
FLAGS  := -O
CODE   := swiftvf/main.swift

all:	prep $(TARGET) sign

.PHONY: prep
prep:
	mkdir -p $(BIN)

$(TARGET): $(CODE)
	swiftc $(FLAGS) -o $(TARGET) $(CODE)

.PHONY: sign
sign: $(TARGET)
	codesign --entitlements swiftvf/swiftvf.entitlements --force -s - $<
	
clean:
	rm -rf $(BIN)

check: $(TARGET)
	$(TARGET) --config example.json --verify
