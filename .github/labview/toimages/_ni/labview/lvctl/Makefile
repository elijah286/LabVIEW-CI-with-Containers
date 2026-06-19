.PHONY: all help build run test test-ci coverage lint format format-check check pr ci clean clean-all generate lint-make

GIT_ROOT := $(shell git rev-parse --show-toplevel)
MAKEFILE_FS := uv run --no-project python $(GIT_ROOT)/tools/scripts/make_fs.py
BINARY_NAME := lvctl
GIT_COMMIT := $(or $(shell git rev-parse --short HEAD),none)

CLEAN_FILES := coverage.out
CLEAN_DIRS := ./bin ./dist
# .src/ directories are created by `make generate` alongside each VI.
# Expand at eval time so new subdirectories are cleaned automatically.
# $(wildcard) does not support **, so list enough depth levels explicitly.
CLEAN_SRC_DIRS := $(wildcard ./vis/.src ./vis/*/.src ./vis/*/*/.src)

all: build

help:
	@uv run python $(GIT_ROOT)/tools/make/help/help.py

build: ## Build lvctl for the current platform
	uv run --no-project python scripts/build.py --binary-name $(BINARY_NAME) --git-commit $(GIT_COMMIT)

run: ## Run lvctl with ARGS
	go run . $(ARGS)

test:
	go test ./...

test-ci:
	go test -race -tags ci ./...

coverage:
	go test -coverprofile=coverage.out ./...

lint:
	go vet ./...

format:
	gofmt -w .

format-check:
	@$(MAKEFILE_FS) assert-empty --label "gofmt -l ." "$(strip $(shell gofmt -l .))"

check: format-check lint lint-make test

pr: check

ci: format-check lint lint-make test-ci

generate: ## Generate vis artifacts and refresh toimages.zip (requires LabVIEW)
	@uv run --no-project python scripts/generate.py --git-root $(GIT_ROOT) --binary-name $(BINARY_NAME) --git-commit $(GIT_COMMIT)

clean:
	go clean
	@$(MAKEFILE_FS) rm $(CLEAN_FILES) $(CLEAN_DIRS) $(CLEAN_SRC_DIRS)

clean-all: clean
	go clean -cache -testcache -modcache

lint-make:
	@uv run --directory $(GIT_ROOT)/tools/make/lint-make python lint_makefile.py $(CURDIR)
