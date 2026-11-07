#!/usr/bin/env bash
# Wait for the CI run of a commit and print a compact report (job results + error lines).
#
# Usage: scripts/ci-wait.sh [branch] [sha]
#   defaults: current branch, HEAD
# Also downloads screenshot artifacts to /tmp/prism-ci/<run-id>/ when available.
#
# Background commands on the dev VM are killed after 10 minutes, so this script gives up
# waiting after CI_WAIT_MAX seconds (default 540) and exits 4. Just run it again: it is
# idempotent and picks the same run back up.
#
# Exit status: 0 = green, 1 = failed, 2 = no run found (yet), 3 = cancelled (superseded),
#              4 = still running — run this script again.
# CI_EVENT selects the trigger (default: push; e.g. CI_EVENT=workflow_dispatch for a manual
# release run, CI_EVENT=any for whichever run is newest).
set -uo pipefail
cd "$(dirname "$0")/.."
GH=/opt/antigravity/bin/gh
REPO=goveaaron/StudioLightingMac
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
SHA="${2:-$(git rev-parse HEAD)}"
# `gh run list --commit` only matches full SHAs: expand abbreviations (fetch if unknown locally).
if [[ ${#SHA} -lt 40 ]]; then
  FULL="$(git rev-parse --verify -q "$SHA^{commit}" 2>/dev/null || true)"
  if [[ -z "$FULL" ]]; then
    timeout 60 git fetch -q origin 2>/dev/null || true
    FULL="$(git rev-parse --verify -q "$SHA^{commit}" 2>/dev/null || true)"
  fi
  [[ -n "$FULL" ]] && SHA="$FULL"
fi
MAX_WAIT="${CI_WAIT_MAX:-540}"
EVENT="${CI_EVENT:-push}"
EVENT_ARGS=()
[[ "$EVENT" != "any" ]] && EVENT_ARGS=(--event "$EVENT")
START=$(date +%s)

elapsed() { echo $(( $(date +%s) - START )); }
gh_() { timeout 60 "$GH" "$@"; }

RUN=""
while true; do
  RUN="$(gh_ run list -R "$REPO" --branch "$BRANCH" --commit "$SHA" --workflow ci.yml \
        "${EVENT_ARGS[@]}" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [[ -n "$RUN" ]] && break
  if (( $(elapsed) > 180 )); then
    echo "No CI run found for $BRANCH@$SHA yet (pushed? GitHub can lag) — run this script again."
    exit 2
  fi
  sleep 10
done
echo "CI run $RUN — https://github.com/$REPO/actions/runs/$RUN"

STATUS=unknown
while true; do
  STATUS="$(gh_ run view -R "$REPO" "$RUN" --json status -q .status 2>/dev/null || echo unknown)"
  [[ "$STATUS" == "completed" ]] && break
  if (( $(elapsed) > MAX_WAIT )); then
    gh_ run view -R "$REPO" "$RUN" --json jobs -q '.jobs[] | "  \(.name): \(.status) \(.conclusion)"' 2>/dev/null || true
    echo "CI run $RUN is still ${STATUS} after $(elapsed)s — run scripts/ci-wait.sh $BRANCH $SHA again to keep waiting."
    exit 4
  fi
  sleep 30
done

CONCLUSION="$(gh_ run view -R "$REPO" "$RUN" --json conclusion -q .conclusion 2>/dev/null || echo unknown)"
gh_ run view -R "$REPO" "$RUN" --json jobs -q '.jobs[] | "  \(.name): \(.conclusion)"' 2>/dev/null || true

OUTDIR="/tmp/prism-ci/$RUN"
mkdir -p "$OUTDIR"
timeout 180 "$GH" run download -R "$REPO" "$RUN" -D "$OUTDIR" >/dev/null 2>&1 && echo "Artifacts: $OUTDIR" || true

if [[ "$CONCLUSION" == "cancelled" ]]; then
  echo "Run was cancelled (superseded by a newer push to $BRANCH) — check the newer run."
  exit 3
fi
if [[ "$CONCLUSION" != "success" ]]; then
  echo "---- failure excerpt ----"
  timeout 120 "$GH" run view -R "$REPO" "$RUN" --log-failed 2>/dev/null \
    | sed -E 's/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+ //' \
    | grep -E "error:|error\b.*:|FAIL|Fatal|fatal error|failed|Assertion|TIMEOUT|Crashed|Termination Reason" \
    | grep -vE "^\s*$|warning:" \
    | awk '!seen[$0]++' \
    | head -120
  exit 1
fi
echo "CI green ✓"
