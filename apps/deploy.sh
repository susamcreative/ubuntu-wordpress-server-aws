#!/usr/bin/env bash
#
# deploy.sh — push code from the repo to the server (Task P4.1, DESIGN §8.9)
#
# OPTIONAL CONVENIENCE. The documented, required way is a plain
#   scp -r apps/* <alias>:~/apps/   (and the existing  scp -r nginx/* <alias>:/etc/nginx/)
# This wrapper adds the safety rails: it NEVER uses --delete (so server-only
# instance state — sites.d/*.conf, server.conf, redirects.d/*.conf, per-site nginx
# configs — is always preserved) and belt-and-suspenders excludes for any instance
# files that might exist in a local checkout. lib/ and scripts ship as one unit.
#
# USAGE:  ./apps/deploy.sh [--dry-run] <server-alias>
#
set -uo pipefail
SCRIPT_NAME="deploy.sh"

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${_DIR}/.." && pwd -P)"

# Never --delete. Excludes protect instance state if it leaked into the checkout.
DRY=()
deploy_apps()  { rsync -a --no-perms "${DRY[@]}" \
                    --exclude='server.conf' --exclude='sites.d/*.conf' --exclude='.*.state' \
                    "${REPO}/apps/" "$1"; }
deploy_nginx() { rsync -a --no-perms "${DRY[@]}" "${REPO}/nginx/" "$1"; }

main() {
    case "${1:-}" in -h|--help) show_help "${BASH_SOURCE[0]}"; exit 0 ;; esac
    local alias=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY=(--dry-run -v); shift ;;
            -*) echo "unknown option: $1" >&2; exit 1 ;;
            *) alias=$1; shift ;;
        esac
    done
    [ -n "$alias" ] || { echo "Usage: $0 [--dry-run] <server-alias>" >&2; exit 1; }

    echo "Deploying apps/ → ${alias}:~/apps/  (lib + scripts, never --delete)"
    deploy_apps "${alias}:apps/"
    echo "Deploying nginx/ → ${alias}:/etc/nginx/"
    deploy_nginx "${alias}:/etc/nginx/"
    # ensure instance dirs exist on a fresh server (no-op if present)
    [ ${#DRY[@]} -eq 0 ] && ssh "$alias" 'mkdir -p ~/apps/sites.d /etc/nginx/redirects.d' 2>/dev/null || true
    echo "Done. Instance state (sites.d/*.conf, server.conf, redirects, per-site nginx configs) was preserved."
}

[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
