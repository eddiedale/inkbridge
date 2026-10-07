# `make` (or `make build`) builds ./inkbridge, then offers to add an
# `inkbridge` command you can run from any folder (see bridge/Link.swift).
# After a `git pull`, run it again.
inkbridge: bridge/*.swift
	swiftc -O bridge/*.swift -o inkbridge
	@./inkbridge link --from-make || true

.PHONY: build clean
build: inkbridge

clean:
	rm -f inkbridge
