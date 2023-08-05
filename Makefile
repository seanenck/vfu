TARGET := build/swiftvf

all:	prep $(TARGET) sign

.PHONY: prep
prep:
	mkdir -p build/

$(TARGET): swiftvf/main.swift
	swiftc -o $(TARGET) swiftvf/main.swift

.PHONY: sign
sign: $(TARGET)
	codesign --entitlements swiftvf/swiftvf.entitlements --force -s - $<
	
clean:
	rm -rf build/

