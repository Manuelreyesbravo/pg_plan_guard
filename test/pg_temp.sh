#!/usr/bin/env bash
# Does verify() re-plan a baseline against the tables its author meant?
#
# capture() stores the query TEXT, and up to 1.1.3 verify() re-planned it under the
# search_path of whoever ran verify(). PostgreSQL searches pg_temp first for
# relations when the path does not name it. Measured here against 1.1.3:
#
#   * a temporary table with the name of a watched one made verify() plan against
#     it. With a temporary `p` in the session, a baseline whose real plan had not
#     moved came back `drifted` and wrote a false drift into the append-only
#     drift_log; and a baseline whose real plan HAD moved (an index appeared under
#     an approved seq scan) came back `ok`, because the temporary copy still had no
#     index;
#   * a baseline captured with its schema on the path could not be planned from a
#     session without it -- pg_cron's, typically -- and came back `error`, one
#     drift_log row per run.
#
# From 1.1.4 capture() records the author's search_path and verify() and
# sync_stash() re-plan under it, with pg_temp moved to the end -- the way
# pg_living_assertions 0.5.5 runs a check. A baseline captured before 1.1.4 has no
# recorded path and keeps being planned under the caller's, also with pg_temp last.
#
# Each tooth has its control: the same verify() without the temporary table, or
# from the capturing path, so a red here means the defect and not the setup.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init && test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/pg_temp.sh
#   PLAN_VERSION=1.1.3 test/pg_temp.sh    # the same teeth against an older release

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5493}
BASE=plan_guard_test_pgtemp
VERSION=${PLAN_VERSION:-}
fallos=0

if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$BASE'")" = 1 ]; then
    echo "a database $BASE already exists: not dropping it, somebody else made it" >&2
    exit 2
fi
trap '$PSQL -X -d postgres -qc "drop database if exists $BASE" >/dev/null 2>&1 || true' EXIT

q() { $PSQL -X -d "$BASE" -tA "$@" 2>&1 || true; }

comprobar() {
    local que="$1" esperado="$2" obtenido="$3"
    if [ "$obtenido" = "$esperado" ]; then
        echo "  ok   $que"
    else
        echo "  FAIL $que"
        echo "       expected: $esperado"
        echo "       got:      $obtenido"
        fallos=$((fallos + 1))
    fi
}

crear() {
    $PSQL -X -d postgres -qc "drop database if exists $BASE" >/dev/null
    $PSQL -X -d postgres -qc "create database $BASE"
    $PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE EXTENSION pg_plan_guard ${1:+VERSION '$1'};
-- p: a point lookup that uses its primary key.
CREATE TABLE p (id int PRIMARY KEY, v int);
INSERT INTO p SELECT g, g FROM generate_series(1, 10000) g;
-- s: a lookup on a column with no index, approved as a seq scan.
CREATE TABLE s (id int, v int);
INSERT INTO s SELECT g, g FROM generate_series(1, 10000) g;
-- app.t: a table outside public, captured with app on the path.
CREATE SCHEMA app;
CREATE TABLE app.t (id int PRIMARY KEY, v int);
INSERT INTO app.t SELECT g, g FROM generate_series(1, 10000) g;
ANALYZE;
SELECT plan_guard.capture('q_p', 'SELECT * FROM p WHERE id = 42');
SELECT plan_guard.capture('q_s', 'SELECT * FROM s WHERE v = 42');
SET search_path = app;
SELECT plan_guard.capture('q_app', 'SELECT * FROM t WHERE id = 42');
SQL
}

estado() { echo "select state from plan_guard.verify('$1')"; }
TEMP_P="create temp table p (id int, v int)"
TEMP_S="create temp table s (id int, v int)"
FALSAS="select count(*) from plan_guard.drift_log where baseline_name = 'q_p'"

echo "== ${VERSION:-repo} =="
crear "$VERSION"

comprobar "control: q_p, nothing changed, is ok" "ok" "$(q -c "$(estado q_p)")"
comprobar "a temporary p does not make q_p drift" "ok" \
    "$(q -c "$TEMP_P" -c "$(estado q_p)" | tail -1)"
comprobar "  ...and writes no drift into drift_log" "0" "$(q -c "$FALSAS")"

q -q -c "create index s_v_idx on s (v)" -c "analyze s" >/dev/null
comprobar "control: an index under the approved seq scan is a drift" "drifted" \
    "$(q -c "$(estado q_s)")"
comprobar "a temporary s without the index does not hide that drift" "drifted" \
    "$(q -c "$TEMP_S" -c "$(estado q_s)" | tail -1)"

comprobar "control: q_app from the capturing path is ok" "ok" \
    "$(q -c "set search_path = app" -c "$(estado q_app)" | tail -1)"
comprobar "q_app is planned from a session without app on its path" "ok" \
    "$(q -c "$(estado q_app)")"

# The upgrade: baselines captured by 1.1.3 recorded no path.
if [ -z "$VERSION" ]; then
    crear 1.1.3
    comprobar "the upgrade warns about the baselines it cannot pin" "3 baseline(s)" \
        "$(q -c "ALTER EXTENSION pg_plan_guard UPDATE" | grep -o '[0-9]* baseline(s)')"
    comprobar "a baseline from 1.1.3: a temporary p still does not make it drift" "ok" \
        "$(q -c "$TEMP_P" -c "$(estado q_p)" | tail -1)"
    comprobar "control: a 1.1.3 baseline outside public needs its path until re-captured" "error" \
        "$(q -c "$(estado q_app)")"
    q -q -c "set search_path = app" -c "select plan_guard.capture('q_app', 'SELECT * FROM t WHERE id = 42')" >/dev/null
    comprobar "re-captured, it records its path" "app" \
        "$(q -c "select search_path from plan_guard.baselines where name = 'q_app'")"
    comprobar "re-captured, it is planned from the default path" "ok" \
        "$(q -c "$(estado q_app)")"
fi

if [ "$fallos" -ne 0 ]; then
    echo "$fallos check(s) failed"
    exit 1
fi
echo "verify() re-plans each baseline against the tables its author meant"
