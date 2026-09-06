#!make
SHELL := /bin/bash
.SILENT:
.DEFAULT_GOAL := help

# Global vars
export REGISTRY ?= ghcr.io
export IMAGE_REPO ?= jtprogru/sre-debug-tooling
export IMAGE ?= $(REGISTRY)/$(IMAGE_REPO)

export VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
export VCS_REF ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
export BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
export PLATFORMS ?= linux/amd64,linux/arm64

BUILD_ARGS = --build-arg VERSION=$(VERSION) \
             --build-arg VCS_REF=$(VCS_REF) \
             --build-arg BUILD_DATE=$(BUILD_DATE)

.PHONY: help
## Show this help message
help:
	@printf '%sAvailable rules:%s\n\n' "$$(tput bold 2>/dev/null)" "$$(tput sgr0 2>/dev/null)"
	@awk ' \
		/^## / { sub(/^## /, ""); doc = doc (doc ? " " : "") $$0; next } \
		/^[a-zA-Z0-9][a-zA-Z0-9_.\/-]*:/ { \
			t = $$1; sub(/:.*/, "", t); \
			if (doc != "") printf "  \033[36m%-18s\033[0m %s\n", t, doc; \
			doc = ""; next \
		} \
		{ doc = "" } \
	' $(MAKEFILE_LIST) | sort -f

.PHONY: build
## Build both variants for the local architecture
build: build.slim build.full

.PHONY: build.slim
## Build the slim variant and load it into the local docker
build.slim:
	docker buildx build --load --target slim $(BUILD_ARGS) \
		-t $(IMAGE):slim-$(VERSION) -t sre-debug-tooling:slim-local .

.PHONY: build.full
## Build the full variant and load it into the local docker
build.full:
	docker buildx build --load --target full $(BUILD_ARGS) \
		-t $(IMAGE):full-$(VERSION) -t sre-debug-tooling:full-local .

.PHONY: test
## Run the smoke test against both locally built variants
test: test.slim test.full

.PHONY: test.slim
## Run the smoke test against the slim variant
test.slim:
	docker run --rm -v "$(CURDIR)/hack:/hack:ro" sre-debug-tooling:slim-local bash /hack/smoke-test.sh slim

.PHONY: test.full
## Run the smoke test against the full variant
test.full:
	docker run --rm -v "$(CURDIR)/hack:/hack:ro" sre-debug-tooling:full-local bash /hack/smoke-test.sh full

.PHONY: lint
## Lint the Dockerfile and the shell scripts
lint:
	hadolint Dockerfile
	shellcheck hack/*.sh
	echo "lint ok"

# The gate covers OS packages only, and only what has a fix. Everything else
# in this image is an upstream release binary - a Go stdlib CVE in kubectl is
# fixed by kubernetes rebuilding kubectl, not by us. Those show up in
# `make scan.report`, which informs without blocking.
TRIVY_GATE = trivy image --scanners vuln --pkg-types os --severity HIGH,CRITICAL \
             --ignore-unfixed --exit-code 1 --ignorefile .trivyignore

.PHONY: scan
## Scan both local images for fixable OS vulnerabilities, failing on HIGH and CRITICAL
scan:
	$(TRIVY_GATE) sre-debug-tooling:slim-local
	$(TRIVY_GATE) sre-debug-tooling:full-local
	echo "scan ok"

.PHONY: scan.report
## Full vulnerability report, upstream binaries included; never fails the build
scan.report:
	trivy image --scanners vuln --severity HIGH,CRITICAL --exit-code 0 sre-debug-tooling:slim-local
	trivy image --scanners vuln --severity HIGH,CRITICAL --exit-code 0 sre-debug-tooling:full-local

.PHONY: size
## Print the size of both local images
size:
	docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep '^sre-debug-tooling:' | sort

.PHONY: push
## Build both variants for all platforms and push them to the registry
push:
	docker buildx build --push --platform $(PLATFORMS) --target slim $(BUILD_ARGS) \
		-t $(IMAGE):slim-$(VERSION) -t $(IMAGE):latest .
	docker buildx build --push --platform $(PLATFORMS) --target full $(BUILD_ARGS) \
		-t $(IMAGE):full-$(VERSION) -t $(IMAGE):full-latest .

.PHONY: refresh-checksums
## Re-download every pinned artifact and rewrite hack/tools.sha256
refresh-checksums:
	./hack/refresh-checksums.sh

.PHONY: clean
## Remove the locally built images
clean:
	docker image rm -f sre-debug-tooling:slim-local sre-debug-tooling:full-local 2>/dev/null || true
