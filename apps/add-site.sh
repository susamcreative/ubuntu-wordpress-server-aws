#!/usr/bin/env bash
#
# add-site.sh — DEPRECATED alias for create-site.sh (kept for one release).
#
# Site creation moved to create-site.sh, which is registry-driven and supports
# blueprint cloning. This shim forwards to it so existing muscle memory / docs
# keep working. Will be removed in a future release.
#
_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
echo "note: add-site.sh is deprecated — use create-site.sh (forwarding now)." >&2
exec "${_DIR}/create-site.sh" "$@"
