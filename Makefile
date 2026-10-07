# `make` builds ./inkbridge and adds an `inkbridge` command (see bridge/Link.swift).
all: inkbridge
	@./inkbridge link || true

inkbridge: bridge/*.swift
	swiftc -O bridge/*.swift -o inkbridge

.PHONY: all clean
clean:
	rm -f inkbridge
