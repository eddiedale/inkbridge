PREFIX ?= /usr/local
# Where `make link` notes each link it made, so `make unlink` finds them all,
# whatever PREFIX was used and wherever this folder has moved since.
LINKS = $(HOME)/.config/inkbridge/links

inkbridge: bridge/*.swift
	swiftc -O bridge/*.swift -o inkbridge

.PHONY: run link unlink clean
run: inkbridge
	./inkbridge

# A link rather than a copy, so a later `make` updates the command too.
link: inkbridge
	@mkdir -p $(PREFIX)/bin $(dir $(LINKS))
	ln -sf "$(CURDIR)/inkbridge" $(PREFIX)/bin/inkbridge
	@grep -qxF "$(PREFIX)/bin/inkbridge" $(LINKS) 2>/dev/null || echo "$(PREFIX)/bin/inkbridge" >> $(LINKS)
	@echo "Linked: run inkbridge from anywhere."

# Removes only links that point to an inkbridge program.
unlink:
	@for f in $$(cat $(LINKS) 2>/dev/null) $(PREFIX)/bin/inkbridge; do \
		case "$$(readlink "$$f" 2>/dev/null)" in \
			*/inkbridge) rm -f "$$f" && echo "Removed $$f" ;; \
		esac; \
	done; rm -f $(LINKS)

clean:
	rm -f inkbridge
