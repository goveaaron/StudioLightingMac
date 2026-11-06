#!/usr/bin/env bash
# Wait for the CI run of a commit and print a compact report (job results + error lines).
#
# Usage: scripts/ci-wait.sh [branch] [sha]
#   defaults: current branch, HEAD
# Also downloads screenshot artifacts to /tmp/prism-ci/<run-id>/ when available.
# Exit status: 0 = green, 1 = failed, 2 = no run found.
set -uo pipefail
cd "$(dirname "$0")/.."
GH=/opt/antigravity/bin/gh
REPO=goveaaron/StudioLightingMac
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
SHA="${2:-$(git rev-parse HEAD)}"

RUN=""
for _ in $(seq 1 60); do
  RUN="$($GH run list -R "$REPO" --branch "$BRANCH" --commit "$SHA" --workflow ci.yml \
        --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [[ -n "$RUN" ]] && break
  sleep 10
done
if [[ -z "$RUN" ]]; then
  echo "No CI run found for $BRANCH@$SHA"
  exit 2
fi
echo "CI run $RUN — https://github.com/$REPO/actions/runs/$RUN"

while true; do
  STATUS="$($GH run view -R "$REPO" "$RUN" --json status -q .status 2>/dev/null || echo unknown)"
  [[ "$STATUS" == "completed" ]] && break
  sleep 45
done

CONCLUSION="$($GH run view -R "$REPO" "$RUN" --json conclusion -q .conclusion)"
$GH run view -R "$REPO" "$RUN" --json jobs -q '.jobs[] | "  \(.name): \(.conclusion)"'

OUTDIR="/tmp/prism-ci/$RUN"
mkdir -p "$OUTDIR"
$GH run download -R "$REPO" "$RUN" -D "$OUTDIR" >/dev/null 2>&1 && echo "Artifacts: $OUTDIR" || true

if [[ "$CONCLUSION" != "success" ]]; then
  echo "---- failure excerpt ----"
  $GH run view -R "$REPO" "$RUN" --log-failed 2>/dev/null \
    | sed -E 's/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+ //' \
    | grep -E "error:|error\b.*:|FAIL|Fatal|fatal error|failed|Assertion|TIMEOUT|Crashed|Termination Reason" \
    | grep -vE "^\s*$|warning:" \
    | awk '!seen[$0]++' \
    | head -120
  exit 1
fi
echo "CI green ✓"
