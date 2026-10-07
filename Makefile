PREFIX ?= /usr/local

inkbridge: bridge/*.swift
	swiftc -O bridge/*.swift -o inkbridge

.PHONY: run install uninstall clean
run: inkbridge
	./inkbridge

# Links rather than copies, so a later `make` updates the installed command.
install: inkbridge
	@mkdir -p $(PREFIX)/bin
	ln -sf "$(CURDIR)/inkbridge" $(PREFIX)/bin/inkbridge
	@echo "Installed: run inkbridge from anywhere."

uninstall:
	rm -f $(PREFIX)/bin/inkbridge

clean:
	rm -f inkbridge
