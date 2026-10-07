PREFIX ?= /usr/local

inkbridge: bridge/*.swift
	swiftc -O bridge/*.swift -o inkbridge

.PHONY: run link unlink clean
run: inkbridge
	./inkbridge

# A link rather than a copy, so a later `make` updates the command too.
link: inkbridge
	@mkdir -p $(PREFIX)/bin
	ln -sf "$(CURDIR)/inkbridge" $(PREFIX)/bin/inkbridge
	@echo "Linked: run inkbridge from anywhere."

unlink:
	rm -f $(PREFIX)/bin/inkbridge

clean:
	rm -f inkbridge
