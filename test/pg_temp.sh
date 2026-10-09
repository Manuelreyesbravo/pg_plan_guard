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
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$REPO_ROOT/.testcluster} PGPORT=${PGPORT:-5493}
DB=plan_guard_test_pgtemp
VERSION=${PLAN_VERSION:-}
failures=0

if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$DB'")" = 1 ]; then
    echo "a database $DB already exists: not dropping it, somebody else made it" >&2
    exit 2
fi
trap '$PSQL -X -d postgres -qc "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT

q() { $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }

check() {
    local what="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      $got"
        failures=$((failures + 1))
    fi
}

create_db() {
    $PSQL -X -d postgres -qc "drop database if exists $DB" >/dev/null
    $PSQL -X -d postgres -qc "create database $DB"
    $PSQL -X -d "$DB" -q -v ON_ERROR_STOP=1 >/dev/null <<SQL
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

state_of() { echo "select state from plan_guard.verify('$1')"; }
TEMP_P="create temp table p (id int, v int)"
TEMP_S="create temp table s (id int, v int)"
FALSE_DRIFTS="select count(*) from plan_guard.drift_log where baseline_name = 'q_p'"

echo "== ${VERSION:-repo} =="
create_db "$VERSION"

check "control: q_p, nothing changed, is ok" "ok" "$(q -c "$(state_of q_p)")"
check "a temporary p does not make q_p drift" "ok" \
    "$(q -c "$TEMP_P" -c "$(state_of q_p)" | tail -1)"
check "  ...and writes no drift into drift_log" "0" "$(q -c "$FALSE_DRIFTS")"

q -q -c "create index s_v_idx on s (v)" -c "analyze s" >/dev/null
check "control: an index under the approved seq scan is a drift" "drifted" \
    "$(q -c "$(state_of q_s)")"
check "a temporary s without the index does not hide that drift" "drifted" \
    "$(q -c "$TEMP_S" -c "$(state_of q_s)" | tail -1)"

check "control: q_app from the capturing path is ok" "ok" \
    "$(q -c "set search_path = app" -c "$(state_of q_app)" | tail -1)"
check "q_app is planned from a session without app on its path" "ok" \
    "$(q -c "$(state_of q_app)")"

# The upgrade: baselines captured by 1.1.3 recorded no path.
if [ -z "$VERSION" ]; then
    create_db 1.1.3
    check "the upgrade warns about the baselines it cannot pin" "3 baseline(s)" \
        "$(q -c "ALTER EXTENSION pg_plan_guard UPDATE" | grep -o '[0-9]* baseline(s)')"
    # From 1.1.7 a baseline is planned as its author, and one from before has none: it is
    # refused until captured again, so its path can no longer be measured before that.
    check "a baseline from 1.1.3 is refused until captured again (no recorded author)" "no recorded author" \
        "$(q -c "select actual_advice from plan_guard.verify('q_p')" | grep -o 'no recorded author')"
    q -q -c "select plan_guard.capture('q_p', 'SELECT * FROM p WHERE id = 42')" >/dev/null
    check "re-captured, a temporary p does not make it drift" "ok" \
        "$(q -c "$TEMP_P" -c "$(state_of q_p)" | tail -1)"
    q -q -c "set search_path = app" -c "select plan_guard.capture('q_app', 'SELECT * FROM t WHERE id = 42')" >/dev/null
    check "re-captured, it records its path" "app" \
        "$(q -c "select search_path from plan_guard.baselines where name = 'q_app'")"
    check "re-captured, it is planned from the default path" "ok" \
        "$(q -c "$(state_of q_app)")"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "verify() re-plans each baseline against the tables its author meant"
