#!/usr/bin/env bash
# Format the Swift sources and check that nothing is left to reformat.
# Needs swift-format: it ships with recent Xcode toolchains, or `brew install swift-format`.
set -euo pipefail
cd "$(dirname "$0")/.."
swift-format format -i -r Sources Tests
swift-format lint --strict -r Sources Tests
