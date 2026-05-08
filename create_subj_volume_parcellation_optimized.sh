#!/usr/bin/env bash

# Experimental optimized entry point. It uses direct annotation mapping instead
# of the slower label-by-label workflow in create_subj_volume_parcellation.sh.
# Validate its output on known subjects before using it for production analyses.

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

printf 'WARNING: create_subj_volume_parcellation_optimized.sh is experimental and not fully validated.\n' >&2
export HCPMMP1_MAPPING_MODE=direct

exec bash "${SCRIPT_DIR}/create_subj_volume_parcellation.sh" "$@"
