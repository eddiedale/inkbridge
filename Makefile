inkbridge: bridge/*.swift
	swiftc -O bridge/*.swift -o inkbridge

.PHONY: run clean
run: inkbridge
	./inkbridge

clean:
	rm -f inkbridge
