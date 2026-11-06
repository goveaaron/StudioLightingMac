#!/usr/bin/env bash
# Serialized Swift invocations on the low-resource Linux dev VM.
# Usage: scripts/linux-swift.sh build --target PrismCore
#        scripts/linux-swift.sh test --filter PrismCoreTests
# Each worktree gets its own .build; the global lock keeps only one compile
# running at a time (2 CPUs / 8 GB RAM).
set -euo pipefail
export PATH="/home/antigravity/toolchains/swift-6.4.2-RELEASE-debian12/usr/bin:$PATH"
LOCK=/tmp/prism-swift.lock
exec flock "$LOCK" swift "$@" -j 2
