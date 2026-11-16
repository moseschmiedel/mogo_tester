.PHONY: build run test format clean

PIXI ?= pixi
MOJO ?= $(PIXI) run mojo

VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

MOJO_DEFINES = -D MOGO_VERSION=$(VERSION) -D MOGO_COMMIT=$(COMMIT) -D MOGO_DATE=$(DATE)

build:
	mkdir -p bin
	$(MOJO) build -I src $(MOJO_DEFINES) -o bin/mogo-tester src/main.mojo

run: build
	./bin/mogo-tester $(ARGS)

# The test suite is run by the freshly built binary itself.
test: build
	MOGO_TESTER_BIN=$(CURDIR)/bin/mogo-tester $(PIXI) run ./bin/mogo-tester \
		--mojo-build-arg -I --mojo-build-arg $(CURDIR)/src tests

format:
	$(MOJO) format src tests

clean:
	rm -rf bin
