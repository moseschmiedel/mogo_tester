.PHONY: build run test tidy

GOCACHE ?= $(CURDIR)/.gocache

build:
	GOCACHE=$(GOCACHE) go build -o bin/mogo-tester ./cmd/mogo-tester

run:
	GOCACHE=$(GOCACHE) go run ./cmd/mogo-tester

test:
	GOCACHE=$(GOCACHE) go test ./...

tidy:
	GOCACHE=$(GOCACHE) go mod tidy
