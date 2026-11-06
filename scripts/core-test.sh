#!/usr/bin/env bash
# Fast Linux loop for PrismCore only (no swift-nio): build + run the core tests.
# Usage: scripts/core-test.sh                      # all core tests
#        scripts/core-test.sh --filter ColorTests  # a subset
# Uses a separate scratch dir so it never invalidates the full build in .build/.
set -euo pipefail
cd "$(dirname "$0")/.."
export PRISM_CORE_ONLY=1
exec "$(dirname "$0")/linux-swift.sh" test --scratch-path .build-core "$@"
