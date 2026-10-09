#!/usr/bin/env bash
# A throwaway cluster for the test scripts, built from the binaries of the PostgreSQL
# this extension will be installed into (PG_CONFIG). Nothing is installed into that
# PostgreSQL: the extension is loaded from this repo through extension_control_path
# (plain SQL, no shared library). Copied from pg_living_assertions, where it exists
# because a suite once ran against a production cluster.
#
#   test/cluster.sh init | start | psql [args...] | stop
set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$("$PG_CONFIG" --bindir)
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
DATA=${PLAN_CLUSTER:-$RAIZ/.testcluster}
PORT=${PGPORT:-5493}

# PostgreSQL looks for control files in the `extension/` SUBDIRECTORY of each
# extension_control_path element, the way $system means SHAREDIR/extension.
# This used to point at the repo root, which has no such subdirectory, so the
# element matched nothing and every suite silently ran against the copy
# installed in SHAREDIR -- whatever version was last `make install`ed, not the
# code in this repo. Found when 0.5.0 was written and the test still reported
# 0.4.1's behaviour. Links, not copies, so an edit is seen without re-init; made
# again on start so a new upgrade script is picked up too.
EXT=$DATA/ext
enlazar() {
    rm -rf "$EXT" && mkdir -p "$EXT/extension"
    ln -s "$RAIZ"/pg_plan_guard.control "$RAIZ"/pg_plan_guard--*.sql "$EXT/extension/"
}

# The harness must be able to say it is testing the wrong thing.
version_del_repo() {
    sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$RAIZ/pg_plan_guard.control"
}

case "${1:-}" in
  init)
    "$BIN/pg_ctl" -D "$DATA" -m immediate -w stop >/dev/null 2>&1 || true
    rm -rf "$DATA"
    "$BIN/initdb" -D "$DATA" --auth=trust -E UTF8 >/dev/null
    enlazar
    cat >>"$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '$DATA'
extension_control_path = '$EXT:\$system'
EOF
    # Preloaded where they exist (PostgreSQL 19+), as a server running pg_plan_guard has
    # them: LOAD needs superuser, and test/audit.sh captures as a role that is not one.
    LIB=$("$PG_CONFIG" --pkglibdir)
    if [ -f "$LIB/pg_plan_advice.so" ] && [ -f "$LIB/pg_stash_advice.so" ]; then
        echo "shared_preload_libraries = 'pg_plan_advice, pg_stash_advice'" >>"$DATA/postgresql.conf"
    fi
    echo "initialised $DATA on port $PORT"
    ;;
  start)
    enlazar
    "$BIN/pg_ctl" -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
    VISTA=$("$BIN/psql" -X -At -h "$DATA" -p "$PORT" -d postgres -c \
        "select default_version from pg_available_extensions where name = 'pg_plan_guard'")
    if [ "$VISTA" != "$(version_del_repo)" ]; then
        echo "the server sees pg_plan_guard $VISTA, the repo is $(version_del_repo): not testing this repo" >&2
        exit 1
    fi
    echo "started on port $PORT, loading pg_plan_guard $VISTA from this repo"
    ;;
  stop)
    "$BIN/pg_ctl" -D "$DATA" -m "${2:-fast}" -w stop >/dev/null
    echo "stopped"
    ;;
  psql)
    shift
    exec "$BIN/psql" -X -h "$DATA" -p "$PORT" "$@"
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 2
    ;;
esac
