#!/usr/bin/env bash
#
# db.sh — throwaway, isolated database for L3-local tests (Tier A).
#
# Starts a private server (MySQL or MariaDB, auto-detected) on its own datadir +
# socket with --skip-networking, so it NEVER touches the machine's default DB.
# Tests override mysql_root / mysqldump_root to point at this socket. Call db_start
# at the top and db_stop at the end.
#

DB_DIR="/tmp/wptestdb.$$"
DB_DATA="$DB_DIR/data"
DB_SOCK="$DB_DIR/m.sock"
DB_ERR="$DB_DIR/m.err"
DB_SERVER_PID=""
DB_FLAVOR=""
DB_DUMPFLAGS=""

db_start() {
    mkdir -p "$DB_DATA"
    local server=""
    if command -v mariadbd >/dev/null 2>&1; then server=mariadbd
    elif command -v mysqld >/dev/null 2>&1; then server=mysqld
    else echo "no mysqld/mariadbd found"; return 1; fi

    if "$server" --version 2>/dev/null | grep -qi mariadb; then
        DB_FLAVOR=mariadb
        mariadb-install-db --datadir="$DB_DATA" --auth-root-authentication-method=normal \
            --skip-test-db --skip-name-resolve >/dev/null 2>&1 \
            || { echo "mariadb-install-db failed"; return 1; }
        "$server" --datadir="$DB_DATA" --socket="$DB_SOCK" --skip-networking \
            --pid-file="$DB_DIR/pid" --log-error="$DB_ERR" >/dev/null 2>&1 &
    else
        DB_FLAVOR=mysql
        "$server" --initialize-insecure --datadir="$DB_DATA" --log-error="$DB_ERR" >/dev/null 2>&1 \
            || { echo "mysqld init failed:"; tail -5 "$DB_ERR" 2>/dev/null; return 1; }
        "$server" --datadir="$DB_DATA" --socket="$DB_SOCK" --skip-networking --mysqlx=0 \
            --log-error="$DB_ERR" >/dev/null 2>&1 &
    fi
    DB_SERVER_PID=$!

    local i
    for i in $(seq 1 60); do
        mysqladmin --socket="$DB_SOCK" -u root ping >/dev/null 2>&1 && return 0
        kill -0 "$DB_SERVER_PID" 2>/dev/null || { echo "server exited early:"; tail -8 "$DB_ERR" 2>/dev/null; return 1; }
        sleep 0.5
    done
    echo "server did not become ready"; tail -8 "$DB_ERR" 2>/dev/null; return 1
}

db_stop() {
    mysqladmin --socket="$DB_SOCK" -u root shutdown >/dev/null 2>&1
    [ -n "$DB_SERVER_PID" ] && wait "$DB_SERVER_PID" 2>/dev/null
    rm -rf "$DB_DIR"
}

db()        { mysql --socket="$DB_SOCK" -u root "$@"; }
db_exists() { mysql --socket="$DB_SOCK" -u root -e "USE \`$1\`;" >/dev/null 2>&1; }

# Point the library's MySQL wrappers at the isolated instance.
# --set-gtid-purged=OFF is a MySQL-only flag (strips GTID statements that can't
# re-import on the same server); MariaDB neither needs nor accepts it.
db_use_in_lib() {
    DB_DUMPFLAGS=""
    [ "$DB_FLAVOR" = mysql ] && DB_DUMPFLAGS="--set-gtid-purged=OFF"
    mysql_root()     { mysql     --socket="$DB_SOCK" -u root "$@"; }
    mysqldump_root() { mysqldump --socket="$DB_SOCK" -u root $DB_DUMPFLAGS "$@"; }
    mysql_as()       { shift 2; mysql     --socket="$DB_SOCK" -u root "$@"; }
    mysqldump_as()   { shift 2; mysqldump --socket="$DB_SOCK" -u root $DB_DUMPFLAGS "$@"; }
}
