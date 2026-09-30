#!/usr/bin/env bash
# Fast UI iteration: run the executable directly (debug). Pass --smoke for a headless check.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./versions.env; set +a
. ./Scripts/sdk-env.sh
exec swift run silo "$@"
