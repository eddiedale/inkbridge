# `make` builds ./inkbridge, then offers to add an `inkbridge` command you can
# run from any folder (see bridge/Link.swift). After a `git pull`, run it again.
inkbridge: bridge/*.swift
	swiftc -O $(SWIFTFLAGS) bridge/*.swift -o $@
	@./inkbridge link --from-make || true

inkbridge-ble: tools/bluetooth-l2cap.swift tools/bluetooth-info.plist
	swiftc -O $(SWIFTFLAGS) $< -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker tools/bluetooth-info.plist -o $@

LLD ?= ld.lld
inkbridge-ble-server: tools/bluetooth-l2cap-server.c
inkbridge-ble-pen: tools/bluetooth-pen.c
inkbridge-ble-server inkbridge-ble-pen:
	@set -e; trap 'rm -f "$@.o"' 0; \
		clang --target=aarch64-linux-gnu -Os -ffreestanding -fno-stack-protector -c $< -o $@.o; \
		$(LLD) -m aarch64elf -static $@.o -o $@

.PHONY: bluetooth clean
bluetooth: inkbridge inkbridge-ble inkbridge-ble-server inkbridge-ble-pen

clean:
	rm -f inkbridge inkbridge-ble inkbridge-ble-server inkbridge-ble-pen
