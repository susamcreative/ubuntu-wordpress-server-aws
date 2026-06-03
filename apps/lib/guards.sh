#!/usr/bin/env bash
#
# guards.sh — the only place destruction is decided/performed (Task P1.3)
# Implements: DESIGN §6.2, §9 (safety model)
#
# Decision functions (can_*) are PURE: they compute allow/refuse from the
# registry + on-disk wp-configs and have NO side effects, so every refusal path
# is unit-testable with zero risk (TASKS §1 testability requirement). The action
# wrappers (safe_*) call the matching can_* and only then perform the real,
# guarded operation — the sole DROP DATABASE / docroot rm in the whole codebase.
#

[ -n "${_GUARDS_SH_LOADED:-}" ] && return 0
_GUARDS_SH_LOADED=1

if [ -z "${_REGISTRY_SH_LOADED:-}" ]; then
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/registry.sh"
fi

GUARD_REASON=''     # set by can_* on refusal, for the caller to surface

# True (0) if a wp-config under WEB_ROOT — other than the one at <exclude-docroot>
# — references <db>. Recursive, so nested staging doc roots are covered.
wpconfig_foreign_ref() {    # <db> <exclude-docroot>
    local db=$1 exclude=$2 wpc dir
    [ -d "$WEB_ROOT" ] || return 1
    while IFS= read -r wpc; do
        dir="$(cd -- "$(dirname -- "$wpc")" && pwd -P)"
        [ "$dir" = "$exclude" ] && continue
        read_wpconfig "$wpc" || continue
        [ "$WPC_DB_NAME" = "$db" ] && return 0
    done < <(find "$WEB_ROOT" -name wp-config.php -type f 2>/dev/null)
    return 1
}

# PURE decision: may <db> be dropped on behalf of <requesting-domain>?
# Refuses unless the registry binds the DB to exactly this (unprotected) site and
# no other registry record or on-disk wp-config also claims it.
can_drop_database() {       # <db> <requesting-domain>
    local db=$1 dom=$2
    GUARD_REASON=''

    if ! registry_read "$dom"; then
        GUARD_REASON="site '$dom' is not in the registry"; return 1
    fi
    if [ "${REG_DB_NAME-}" != "$db" ]; then
        GUARD_REASON="registry binds '$dom' to DB '${REG_DB_NAME-}', not '$db'"; return 1
    fi
    if [ "${REG_PROTECTED-}" = "true" ]; then
        GUARD_REASON="site '$dom' is PROTECTED"; return 1
    fi

    local claimant others=''
    while IFS= read -r claimant; do
        [ "$claimant" = "$dom" ] && continue
        others="${others}${claimant} "
    done < <(registry_db_claimants "$db")
    if [ -n "$others" ]; then
        GUARD_REASON="DB '$db' is also claimed by: ${others% }"; return 1
    fi

    local exclude="${REG_DOC_ROOT-}"
    [ -n "$exclude" ] && exclude="$(cd -- "$exclude" 2>/dev/null && pwd -P || echo "$exclude")"
    if wpconfig_foreign_ref "$db" "$exclude"; then
        GUARD_REASON="another site's wp-config references DB '$db'"; return 1
    fi
    return 0
}

# PURE decision: may <path> be removed on behalf of <requesting-domain>?
# Refuses if any OTHER registered site's DOC_ROOT lies inside <path> (a parent's
# removal must not silently delete a nested staging site).
can_remove_docroot() {      # <path> <requesting-domain>
    local path=$1 dom=$2 d child
    GUARD_REASON=''
    path="${path%/}"
    while IFS= read -r d; do
        [ "$d" = "$dom" ] && continue
        registry_read "$d" || continue
        child="${REG_DOC_ROOT%/}"
        [ -z "$child" ] && continue
        case "$child/" in
            "$path"/*) GUARD_REASON="nested site '$d' lives inside $path"; return 1 ;;
        esac
    done < <(registry_list)
    return 0
}

# PURE: is a plugin-created staging install safe to ADOPT? (DESIGN §8.4)
# Reads WPC_* from the staging wp-config as a side effect. The gate: the staging
# database must NOT already belong to a registered (live) site — a staging clone
# still pointing at its parent's/blueprint's DB is the §2.1 incident, caught here
# at adoption instead of detonating at removal. 0 = safe, 1 = reject (reason set).
can_adopt_staging() {       # <staging-domain> <docroot>
    local sdom=$1 docroot=$2 wpc="${2}/wp-config.php"
    GUARD_REASON=''
    read_wpconfig "$wpc" || { GUARD_REASON="wp-config unreadable: $wpc"; return 1; }
    [ -n "$WPC_DB_NAME" ] || { GUARD_REASON="no DB_NAME in $wpc"; return 1; }
    local claimants; claimants="$(registry_db_claimants "$WPC_DB_NAME")"
    if [ -n "$claimants" ]; then
        GUARD_REASON="staging DB '${WPC_DB_NAME}' is the LIVE database of: $(echo $claimants) — broken clone, refusing to adopt"
        return 1
    fi
    return 0
}

# PURE: does the registry record agree with the on-disk wp-config?
# 0 = match, 1 = mismatch (GUARD_REASON set), 2 = wp-config unreadable.
verify_binding() {          # <domain>
    local dom=$1
    GUARD_REASON=''
    registry_read "$dom" || { GUARD_REASON="no registry record"; return 1; }
    local wpc="${REG_DOC_ROOT}/wp-config.php"
    read_wpconfig "$wpc" || { GUARD_REASON="wp-config unreadable: $wpc"; return 2; }
    if [ "$WPC_DB_NAME" != "${REG_DB_NAME-}" ]; then
        GUARD_REASON="DB_NAME registry='${REG_DB_NAME-}' wp-config='${WPC_DB_NAME}'"; return 1
    fi
    if [ "$WPC_DB_USER" != "${REG_DB_USER-}" ]; then
        GUARD_REASON="DB_USER registry='${REG_DB_USER-}' wp-config='${WPC_DB_USER}'"; return 1
    fi
    if [ -n "${REG_TABLE_PREFIX-}" ] && [ "$WPC_TABLE_PREFIX" != "${REG_TABLE_PREFIX-}" ]; then
        GUARD_REASON="TABLE_PREFIX registry='${REG_TABLE_PREFIX-}' wp-config='${WPC_TABLE_PREFIX}'"; return 1
    fi
    return 0
}

# Filesystem⇄registry orphan diff (the no-server portion of find_orphans).
# Prints "orphan-dir <docroot>" for WP installs with no registry record, and
# "missing <domain>" for registry records whose DOC_ROOT is gone. (The MySQL /
# nginx / certbot diffs are added at L3.)
find_orphans_fs() {
    local wpc dir d found rec_root
    # WP dirs not described by any record
    while IFS= read -r wpc; do
        dir="$(cd -- "$(dirname -- "$wpc")" && pwd -P)"
        found=0
        while IFS= read -r d; do
            registry_read "$d" || continue
            rec_root="$(cd -- "${REG_DOC_ROOT}" 2>/dev/null && pwd -P || echo "${REG_DOC_ROOT}")"
            [ "$rec_root" = "$dir" ] && { found=1; break; }
        done < <(registry_list)
        [ "$found" -eq 0 ] && printf 'orphan-dir %s\n' "$dir"
    done < <(find "$WEB_ROOT" -name wp-config.php -type f 2>/dev/null)
    # records whose docroot vanished
    while IFS= read -r d; do
        registry_read "$d" || continue
        [ -n "${REG_DOC_ROOT-}" ] && [ ! -d "${REG_DOC_ROOT}" ] && printf 'missing %s\n' "$d"
    done < <(registry_list)
}

# PURE: resolve the promotion crash-window (DESIGN §8.2 step 10). If a new record
# X has PROMOTED_FROM=Y, Y is still registered, and both claim the same DB, then Y
# is the stale pre-promotion record. Echoes each stale domain (safe to delete).
resolve_promotion_dupes() {
    local x y
    while IFS= read -r x; do
        registry_read "$x" || continue
        y="${REG_PROMOTED_FROM-}"
        [ -z "$y" ] && continue
        local x_db="${REG_DB_NAME-}"
        registry_exists "$y" || continue
        if [ "$(registry_field "$y" DB_NAME)" = "$x_db" ]; then
            printf '%s\n' "$y"
        fi
    done < <(registry_list)
}

# Sites stuck in a transient status (creating/promoting/removing) longer than
# <max_age_seconds> (default 24h). STATUS_SINCE is epoch seconds (portable).
find_stuck_operations() {   # [max_age_seconds]
    local max=${1:-86400} now d since
    now="$(date +%s)"
    while IFS= read -r d; do
        registry_read "$d" || continue
        case "${REG_STATUS-}" in creating|promoting|removing) ;; *) continue ;; esac
        since="${REG_STATUS_SINCE-}"
        if [ -z "$since" ]; then printf '%s unknown-age\n' "$d"
        elif [ "$((now - since))" -gt "$max" ]; then printf '%s %ss\n' "$d" "$((now - since))"; fi
    done < <(registry_list)
}

# Aggregate registry convergence checks into "SEVERITY|CATEGORY|subject|message"
# lines (DESIGN §8.7). The full health-check.sh composes this with its existing
# disk/service/SSL/webhook checks; this is the registry-driven, no-server portion.
registry_health_report() {
    local d
    # binding mismatch on active sites (the incident's precondition) — CRITICAL
    while IFS= read -r d; do
        registry_read "$d" || continue
        [ "${REG_STATUS-}" = active ] || continue
        [ -f "${REG_DOC_ROOT}/wp-config.php" ] || continue
        verify_binding "$d" || printf 'CRITICAL|binding|%s|%s\n' "$d" "$GUARD_REASON"
    done < <(registry_list)
    # orphans / missing resources
    find_orphans_fs | while IFS=' ' read -r kind subject; do
        printf 'WARNING|orphan|%s|%s\n' "$subject" "$kind"
    done
    # stale pre-promotion records (handover crash window)
    resolve_promotion_dupes | while IFS= read -r d; do
        printf 'WARNING|dupe|%s|stale pre-promotion record (safe to delete)\n' "$d"
    done
    # operations stuck in a transient status
    find_stuck_operations | while IFS=' ' read -r d age; do
        printf 'WARNING|stuck|%s|transient status for %s\n' "$d" "$age"
    done
}

# --- action wrappers (real destruction; L3) -----------------------------------

# The ONLY DROP DATABASE in the codebase. Decides via can_drop_database, takes a
# pre-drop dump, and only then drops. Needs MYSQL_ROOT_PASS (or user/pass).
safe_drop_database() {      # <db> <requesting-domain>
    local db=$1 dom=$2
    if ! can_drop_database "$db" "$dom"; then
        warning "Refusing to drop '$db': ${GUARD_REASON}"
        return 1
    fi
    local dumpdir="${BACKUP_ROOT}/${dom}/pre-removal"
    mkdir -p "$dumpdir" || { warning "cannot create pre-drop dump dir"; return 1; }
    local base="${dumpdir}/${db}_$(date '+%y.%m.%d_%H.%M').sql"
    # Pre-drop dump — only if the DB actually exists (an orphan clone DB may not).
    # mysqldump exit is checked directly (a pipe to gzip would mask its failure).
    if mysql_root -e "USE \`${db}\`;" >/dev/null 2>&1; then
        if ! mysqldump_root "$db" > "$base" 2>/dev/null; then
            warning "pre-drop dump failed — NOT dropping '$db'"; rm -f "$base"; return 1
        fi
        gzip -f "$base"
    fi
    mysql_root -e "DROP DATABASE IF EXISTS \`${db}\`;" || return 1
    log_operation "drop-database" "$db (for $dom)"
    return 0
}

# Restore a database from a dump: safety-dump the current DB, then DROP+CREATE and
# import. Registry-verified (the target must belong to the domain). Contains the
# only restore-side DROP — keeps T.4's "DROP DATABASE only in guards" invariant.
safe_recreate_and_import() {    # <db> <domain> <sqlgz>
    local db=$1 dom=$2 sqlgz=$3
    registry_read "$dom" || { warning "restore target '$dom' not registered"; return 1; }
    if [ "${REG_DB_NAME-}" != "$db" ]; then
        warning "registry binds '$dom' to '${REG_DB_NAME-}', not '$db' — refusing restore"; return 1
    fi
    local sdir="${BACKUP_ROOT}/${dom}/pre-restore"; mkdir -p "$sdir"
    if mysql_root -e "USE \`${db}\`;" >/dev/null 2>&1; then     # safety dump of current
        mysqldump_root "$db" 2>/dev/null | gzip > "${sdir}/${db}_$(date '+%y.%m.%d_%H.%M').sql.gz" || true
    fi
    mysql_root -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;" || return 1
    gunzip -c "$sqlgz" | mysql_root "$db" || return 1
    log_operation "restore-database" "$db (for $dom)"
}

# Guarded docroot removal. Decides via can_remove_docroot, then rm -rf.
safe_remove_docroot() {     # <path> <requesting-domain>
    local path=$1 dom=$2
    if ! can_remove_docroot "$path" "$dom"; then
        warning "Refusing to remove '$path': ${GUARD_REASON}"
        return 1
    fi
    case "$path" in ''|/|/home|/home/*/|"$WEB_ROOT") warning "unsafe path: $path"; return 1 ;; esac
    rm -rf "$path"
    log_operation "remove-docroot" "$path (for $dom)"
    return 0
}

# Remove a site's own certificate, preserving shared wildcards. No-ops cleanly
# when the cert or certbot is absent (so it passes through in tests).
safe_remove_certificate() { # <domain>
    local domain=$1 live="/etc/letsencrypt/live/${domain}"
    [ -d "$live" ] || return 0
    command -v certbot >/dev/null 2>&1 || return 0
    # never delete a wildcard cert shared by sibling sites
    if readlink -f "${live}/fullchain.pem" 2>/dev/null | grep -q '\*\.'; then
        info "preserving wildcard certificate for ${domain}"; return 0
    fi
    sudo certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
    log_operation "remove-certificate" "$domain"
}

# Write an nginx config and roll it back if it breaks `nginx -t`.
safe_write_nginx_config() { # <path> <<<content (stdin)
    local path=$1 tmp
    tmp="$(mktemp)" || return 1
    cat > "$tmp"
    sudo cp "$tmp" "$path"; rm -f "$tmp"
    if sudo nginx -t >/dev/null 2>&1; then
        return 0
    fi
    sudo rm -f "$path"
    warning "nginx -t failed — removed $path and aborted"
    return 1
}
