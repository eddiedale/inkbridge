build/inkbridge: bridge/*.swift
	@mkdir -p build
	swiftc -O bridge/*.swift -o build/inkbridge

.PHONY: clean
clean:
	rm -rf build
