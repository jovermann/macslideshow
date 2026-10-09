SWIFTC ?= swiftc
SWIFTFLAGS ?=

.PHONY: all
all: slideshow

slideshow: slideshow.swift
	mkdir -p .build/module-cache
	$(SWIFTC) -module-cache-path .build/module-cache $(SWIFTFLAGS) $< -o $@
