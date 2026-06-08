#!/usr/bin/env bash
set -euxo pipefail

mkdir -p "${PREFIX}/bin"

go build \
  -trimpath \
  -ldflags "-s -w -X main.version=${PKG_VERSION}" \
  -o "${PREFIX}/bin/mogo-tester" \
  ./cmd/mogo-tester

go-licenses save ./cmd/mogo-tester --save_path="${SRC_DIR}/license-files" || true
