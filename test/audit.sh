#!/usr/bin/env bash
# The findings of the external audit of 1.1.4 that this repo closed, each against its
# control -- the proof that the instrument can answer the other way.
#
#   F-01 the re-planning helpers set the baseline's search_path with set_config(..., false),
#        which outlives the function despite its SET clause: after verify() the session
#        kept the baseline's path, and its next capture() recorded that path and blessed
#        a plan of the wrong table.
#   F-02 EXPLAIN plans the stored text as whoever runs verify(), and the planner folds an
#        IMMUTABLE function with constant arguments: what that function did, it did as
#        the runner, and kept.
#   F-03 advice_for() parsed EXPLAIN's output with an unqualified || under the baseline's
#        path: an operator in a schema on that path ran as the runner.
#   F-04 LOAD 'pg_plan_advice' needs superuser even when the library is preloaded, so no
#        other role could capture anything.
#   F-05 a baseline that could not be planned wrote a drift_log row on every run.
#   F-06 after pg_dump and restore the identity sequences started again at 1, and the
#        first drift or capture died on a duplicate key.
#   F-07 capture() over an existing name kept the old query_id, and sync_stash() pinned
#        the new advice to the old statement.
#   F-10 an unquoted PG_TEMP was not recognised as pg_temp, and a quoted schema name with
#        a comma in it was split.
#   F-11 a query whose text contained "Generated Plan Advice:" leaked plan lines into the
#        advice.
#   F-13 drift_log, documented as append-only, could be updated and deleted.
#   F-12 CREATE EXTENSION used a plan_guard schema another role owned, which could drop it.
#   F-14 query_id_for() left compute_query_id = on in the caller's transaction.
#   PG-S1 (audit round 4, on 1.1.5) the seal stops writes to the database, not what outlives a
#        rollback: a function the planner folds ran COPY ... TO PROGRAM as the role running
#        verify(), left a session advisory lock behind, and pg_cancel_backend() of its own
#        backend aborted verify() for every baseline. A baseline now plans as its author.
#   and  sync_stash() aborted entirely on one baseline it could not plan.
#
# Run against the throwaway cluster: test/cluster.sh init && test/cluster.sh start.

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$("$PG_CONFIG" --bindir)
PSQL=${PSQL:-$BIN/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5493}
DB=plan_guard_test_audit
RESTORED=plan_guard_test_audit_restored
ROLE=plan_guard_test_audit_role
DUMP=$RAIZ/.testcluster/audit.dump
failures=0

for d in "$DB" "$RESTORED"; do
    if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$d'")" = 1 ]; then
        echo "a database $d already exists: not dropping it, somebody else made it" >&2
        exit 2
    fi
done
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_roles where rolname = '$ROLE'")" = 1 ]; then
    echo "a role $ROLE already exists: not dropping it, somebody else made it" >&2
    exit 2
fi
cleanup() {
    $PSQL -X -d postgres -qc "drop database if exists $DB" -c "drop database if exists $RESTORED" \
        -c "drop role if exists $ROLE" >/dev/null 2>&1 || true
    rm -f "$DUMP"
}
trap cleanup EXIT

q()  { $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }
qr() { PGUSER=$ROLE $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      $got"
        failures=$((failures + 1))
    fi
}

$PSQL -X -d postgres -qc "create database $DB" -c "create role $ROLE login"
$PSQL -X -d "$DB" -q -v ON_ERROR_STOP=1 -v role="$ROLE" >/dev/null <<'SQL'
CREATE EXTENSION pg_plan_guard;
-- app.t has a primary key; atk.t, the same name elsewhere, has none.
CREATE SCHEMA app;
CREATE TABLE app.t (id int PRIMARY KEY, v text);
INSERT INTO app.t SELECT g, 'v' || g FROM generate_series(1, 10000) g;
CREATE SCHEMA atk;
CREATE TABLE atk.t (id int, v text);
INSERT INTO atk.t SELECT g, 'v' || g FROM generate_series(1, 10000) g;
CREATE TABLE public.pwned (what text);
ANALYZE;
SQL

echo "F-01: verify() leaves the session's search_path as it found it"
q -q -c "set search_path = atk" -c "select plan_guard.capture('atkb', 'select v from t where id = 5')" >/dev/null
check "control: the baseline was captured under atk" "atk" \
    "$(q -c "select search_path from plan_guard.baselines where name = 'atkb'")"
check "after verify() the session's path is still app" "ok|app" \
    "$(q -c "set search_path = app" -c "select state from plan_guard.verify('atkb')" -c "show search_path" | grep -v '^SET$' | paste -sd'|')"
check "  ...inside BEGIN ... COMMIT too" "app|ok|app" \
    "$(q -c "begin" -c "set search_path = app" -c "show search_path" -c "select state from plan_guard.verify('atkb')" -c "show search_path" -c "commit" | grep -v '^BEGIN$\|^SET$\|^COMMIT$' | paste -sd'|')"
q -q -c "set search_path = app" -c "select plan_guard.verify('atkb')" -c "select plan_guard.capture('mine', 'select v from t where id = 5')" >/dev/null
check "a capture() after verify() records the session's own path" "app" \
    "$(q -c "select search_path from plan_guard.baselines where name = 'mine'")"
check "  ...and plans the session's own table" "INDEX_SCAN" \
    "$(q -c "select advice from plan_guard.baselines where name = 'mine'")"

echo "F-14: query_id_for() does not leave compute_query_id behind"
check "compute_query_id after query_id_for(), in the same transaction" "auto" \
    "$(q -c "begin" -c "select plan_guard.query_id_for('select 1') is not null" -c "show compute_query_id" -c "commit" | grep -v '^BEGIN$\|^COMMIT$' | tail -1)"

echo "F-07: re-capturing a name forgets the old statement's query_id"
q -c "select * from plan_guard.sync_stash('audit_stash')" >/dev/null
check "control: sync_stash() cached a query_id" "cached=true" \
    "$(q -c "select 'cached=' || (query_id is not null) from plan_guard.baselines where name = 'mine'")"
q -q -c "set search_path = app" -c "select plan_guard.capture('mine', 'select v from t where v = ''x5''')" >/dev/null
check "after capture() of another statement, sync_stash() pins the new one" "same=true" \
    "$(q -c "select * from plan_guard.sync_stash('audit_stash')" >/dev/null; q -c "set search_path = app" -c "select 'same=' || (b.query_id = plan_guard.query_id_for('select v from t where v = ''x5''')) from plan_guard.baselines b where name = 'mine'" | tail -1)"

echo "F-02: a function the planner folds cannot write as the runner"
q -q -c "create function public.evil_vol() returns void language plpgsql volatile as \$\$ begin insert into public.pwned values ('folded'); end \$\$" \
     -c "create function public.evil() returns int language plpgsql immutable as \$\$ begin perform public.evil_vol(); return 1; end \$\$" >/dev/null
check "control: calling it writes" "pwned=1" \
    "$(q -c "select public.evil()" -c "select 'pwned=' || count(*) from public.pwned" | tail -1)"
q -c "truncate public.pwned" >/dev/null
q -c "insert into plan_guard.baselines (name, query_sql, advice) values ('trojan', 'select v from app.t where id = public.evil()', 'x')" >/dev/null
q -c "select state from plan_guard.verify('trojan')" >/dev/null
check "verify() of a baseline that folds it writes nothing" "pwned=0" \
    "$(q -c "select 'pwned=' || count(*) from public.pwned")"

echo "F-03: the parse of EXPLAIN's output does not run the baseline's operators"
q -q -c "create schema op" \
     -c "create function op.hij(text[], text) returns text[] language plpgsql as \$\$ begin insert into public.pwned values ('operator'); return pg_catalog.array_append(\$1, \$2); end \$\$" \
     -c "create operator op.|| (leftarg = text[], rightarg = text, function = op.hij)" >/dev/null
q -c "truncate public.pwned" >/dev/null
check "control: under that path, || on text[] is the planted one" "pwned=1" \
    "$(q -c "set search_path = op, public" -c "select '{}'::text[] || 'x'::text" -c "select 'pwned=' || count(*) from public.pwned" | tail -1)"
q -c "truncate public.pwned" >/dev/null
q -q -c "set search_path = op, public" -c "select plan_guard.capture('qop', 'select v from app.t where id = 3')" >/dev/null
check "capture() under that path runs none of it" "pwned=0" \
    "$(q -c "select 'pwned=' || count(*) from public.pwned")"
check "verify() from a fresh session runs none of it" "pwned=0" \
    "$(q -c "select state from plan_guard.verify('qop')" -c "select 'pwned=' || count(*) from public.pwned" | tail -1)"

echo "F-04: a role that is not a superuser can capture, with pg_plan_advice preloaded"
check "control: pg_plan_advice is preloaded in this cluster" "pg_plan_advice" \
    "$(q -c "show shared_preload_libraries")"
q -q -c "grant usage on schema plan_guard, app to $ROLE" \
     -c "grant execute on all functions in schema plan_guard to $ROLE" \
     -c "grant select, insert, update on plan_guard.baselines to $ROLE" \
     -c "grant select on app.t to $ROLE" >/dev/null
check "capture() as that role" "INDEX_SCAN" \
    "$(qr -c "select plan_guard.capture('by_role', 'select v from app.t where id = 9')")"

echo "F-05: a baseline that cannot be planned is logged once, not per run"
q -q -c "create table public.gone (id int primary key)" -c "select plan_guard.capture('q_gone', 'select * from public.gone where id = 1')" -c "drop table public.gone" >/dev/null
q -c "select plan_guard.verify('q_gone')" -c "select plan_guard.verify('q_gone')" -c "select plan_guard.verify('q_gone')" >/dev/null
check "control: it is in error" "error" "$(q -c "select state from plan_guard.baselines where name = 'q_gone'")"
check "three runs, one drift_log row" "rows=1" \
    "$(q -c "select 'rows=' || count(*) from plan_guard.drift_log where baseline_name = 'q_gone'")"

echo "sync_stash() goes on past a baseline it cannot plan"
check "the broken baseline is reported, the others are still handled" "q_gone|no query_id" \
    "$(q -c "select name || '|' || action from plan_guard.sync_stash('audit_stash') where name = 'q_gone'")"

echo "F-10: the recorded path is read the way PostgreSQL reads it"
q -q -c "select set_config('search_path', 'PG_TEMP, app', false)" -c "select plan_guard.capture('upper', 'select v from t where id = 5')" >/dev/null
check "control: the path was recorded as written" "PG_TEMP, app" \
    "$(q -c "select search_path from plan_guard.baselines where name = 'upper'")"
check "an unquoted PG_TEMP first does not let a temporary t answer" "ok" \
    "$(q -c "create temp table t (id int, v text)" -c "select state from plan_guard.verify('upper')" | tail -1)"
q -q -c 'create schema "we,ird"' -c 'create table "we,ird".w (id int primary key)' -c 'insert into "we,ird".w select generate_series(1, 10000)' -c 'analyze "we,ird".w' >/dev/null
check "a quoted schema name with a comma in it" '"we,ird".w_pkey' \
    "$(q -c 'set search_path = "we,ird"' -c "select plan_guard.capture('comma', 'select * from w where id = 1')" | tail -1)"

echo "F-11: only the advice section is the advice"
check "a query that mentions the header yields no plan lines" "clean=true" \
    "$(q -c "select 'clean=' || (plan_guard.advice_for('select id from app.t where v = ''Generated Plan Advice:'' union all select id from app.t where id = 2') !~ '(->|Index Cond|Filter)')")"

echo "F-13: drift_log is append-only"
check "control: it has rows" "rows=true" "$(q -c "select 'rows=' || (count(*) > 0) from plan_guard.drift_log")"
check "UPDATE is refused" "ERROR" "$(q -c "update plan_guard.drift_log set expected_advice = 'forged'")"
check "DELETE is refused" "ERROR" "$(q -c "delete from plan_guard.drift_log")"
check "TRUNCATE is refused" "ERROR" "$(q -c "truncate plan_guard.drift_log")"

echo "PG-S1: a baseline plans as the role that wrote it, not as the one running verify()"
PWN=$RAIZ/.testcluster/plan_guard_pwn
rm -f "$PWN"
q -q -c "grant create on schema public to $ROLE" -c "grant insert on plan_guard.baselines to $ROLE" >/dev/null
qr -q -c "create function public.cp_vol() returns void language plpgsql volatile as \$\$ begin copy (select 1) to program 'touch $PWN'; end \$\$" \
      -c "create function public.cp_imm() returns int language plpgsql immutable as \$\$ begin perform public.cp_vol(); return 1; end \$\$" \
      -c "create function public.lock_vol() returns void language plpgsql volatile as \$\$ begin perform pg_advisory_lock(424242); end \$\$" \
      -c "create function public.lock_imm() returns int language plpgsql immutable as \$\$ begin perform public.lock_vol(); return 1; end \$\$" \
      -c "create function public.cancel_vol() returns void language plpgsql volatile as \$\$ begin perform pg_cancel_backend(pg_backend_pid()); perform pg_sleep(1); end \$\$" \
      -c "create function public.cancel_imm() returns int language plpgsql immutable as \$\$ begin perform public.cancel_vol(); return 1; end \$\$" >/dev/null
check "control: as the superuser, the folded function runs a program" "ran=t" \
    "$(q -c "select public.cp_imm()" >/dev/null; [ -f "$PWN" ] && echo ran=t || echo ran=f)"
rm -f "$PWN"
qr -q -c "insert into plan_guard.baselines (name, query_sql, advice) values ('s1_copy', 'select v from app.t where id = public.cp_imm()', 'x')" \
      -c "insert into plan_guard.baselines (name, query_sql, advice) values ('s1_lock', 'select v from app.t where id = public.lock_imm()', 'x')" >/dev/null
check "a role with INSERT on baselines cannot sign a baseline as the superuser" "cannot act as" \
    "$(qr -c "insert into plan_guard.baselines (name, query_sql, advice, captured_by) select 's1_forged', 'select 1', 'x', rolname from pg_roles where rolsuper limit 1" 2>&1)"
check "  ...and an explicit NULL author is refused by verify()" "no recorded author" \
    "$(qr -c "insert into plan_guard.baselines (name, query_sql, advice, captured_by) values ('s1_null', 'select 1', 'x', NULL)" >/dev/null; q -c "select actual_advice from plan_guard.verify('s1_null')")"
check "verify() by the superuser of that role's baseline runs no program" "ran=f" \
    "$(q -c "select state from plan_guard.verify('s1_copy')" >/dev/null; [ -f "$PWN" ] && echo ran=t || echo ran=f)"
check "  ...and the baseline says why" "error" "$(q -c "select state from plan_guard.baselines where name = 's1_copy'")"
check "verify() leaves no advisory lock behind in the runner's session" "locks=0" \
    "$(q -c "select state from plan_guard.verify('s1_lock')" -c "select 'locks=' || count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()" | tail -1)"
qr -c "insert into plan_guard.baselines (name, query_sql, advice) values ('s1_cancel', 'select v from app.t where id = public.cancel_imm()', 'x')" >/dev/null
check "a baseline that cancels its own backend does not abort verify() for the others" "s1_cancel|error" \
    "$(q -c "select name || '|' || state from plan_guard.verify() where name in ('s1_cancel', 'atkb')" 2>&1 | sort | paste -sd' ')"
check "  ...and the others are still verified" "atkb|" \
    "$(q -c "select name || '|' || state from plan_guard.verify() where name = 'atkb'" 2>&1)"
check "rewriting a baseline's SQL makes the writer its author" "$ROLE" \
    "$(q -c "grant update on plan_guard.baselines to $ROLE" >/dev/null; qr -c "update plan_guard.baselines set query_sql = 'select v from app.t where id = 1' where name = 'atkb'" >/dev/null; q -c "select captured_by from plan_guard.baselines where name = 'atkb'")"
q -q -c "delete from plan_guard.baselines where name like 's1_%'" -c "set search_path = atk" -c "select plan_guard.capture('atkb', 'select v from t where id = 5')" >/dev/null

echo "F-12: a plan_guard schema created by someone else is refused"
SQUAT=${DB}_squat
$PSQL -X -d postgres -qc "create database $SQUAT" -c "grant create on database $SQUAT to $ROLE" >/dev/null
PGUSER=$ROLE $PSQL -X -d "$SQUAT" -qc "create schema plan_guard" >/dev/null
check "control: the role owns the schema" "$ROLE" "$($PSQL -X -d "$SQUAT" -tAc "select nspowner::regrole from pg_namespace where nspname = 'plan_guard'")"
check "CREATE EXTENSION refuses it" "owned by $ROLE, not by the installer" "$($PSQL -X -d "$SQUAT" -tAc "create extension pg_plan_guard" 2>&1)"
$PSQL -X -d postgres -qc "drop database if exists $SQUAT" >/dev/null 2>&1 || true

echo "F-06: after pg_dump and restore, new rows still get new ids"
"$BIN/pg_dump" -Fc -d "$DB" -f "$DUMP"
$PSQL -X -d postgres -qc "create database $RESTORED"
"$BIN/pg_restore" -d "$RESTORED" "$DUMP" >/dev/null 2>&1 || true
check "control: the baselines came back" "back=true" \
    "$($PSQL -X -d "$RESTORED" -tAc "select 'back=' || (count(*) > 3) from plan_guard.baselines" 2>&1)"
check "a capture() after the restore" "INDEX_SCAN" \
    "$($PSQL -X -d "$RESTORED" -tA -c "select plan_guard.capture('after_restore', 'select v from app.t where id = 77')" 2>&1)"
check "a drift after the restore is logged" "drifted" \
    "$($PSQL -X -d "$RESTORED" -tA -c "set enable_indexscan = off" -c "set enable_bitmapscan = off" -c "select state from plan_guard.verify('after_restore')" 2>&1 | tail -1)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the findings of the 1.1.4 audit are closed, each against its control"
