# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_plan_guard/). Each
upgrade script (`pg_plan_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

## 1.1.8 -- 2026-10-09

* **F-12: a `plan_guard` schema created by someone else is refused.** `CREATE EXTENSION` used it,
  and its owner -- any role with CREATE on the database -- could drop it, and the extension with
  every baseline and the drift history (external audit of 1.1.4). The install and every upgrade
  refuse a `plan_guard` schema owned by a role that is neither the installer nor a superuser
  (`test/audit.sh`, red on 1.1.7).

## 1.1.7 -- 2026-10-09

* **A baseline is planned as the role that wrote it (PG-S1, external audit round 4).**
  The 1.1.5 seal (read-only, rolled back) stops writes to the database, not what is not
  one: a function the planner folds ran `COPY ... TO PROGRAM` (measured: a file created
  by the server's OS user), `pg_switch_wal()`, `pg_create_restore_point()` and
  `pg_stat_reset()` as the role running `verify()`; a session advisory lock stayed in
  that session; and `pg_cancel_backend()` of its own backend aborted `verify()` and
  `sync_stash()` for every baseline. A role needed only INSERT on `baselines`.
  `baselines.captured_by` now records the author -- set by a trigger to whoever writes or
  rewrites the query, another name accepted only from a role that may `SET ROLE` to it --
  and the sealed `EXPLAIN` runs after `SET ROLE` to that author. What needs more than the
  author has is that baseline's `error`; advisory locks taken in the seal are released.
* **A baseline captured before 1.1.7 is refused until captured again** (state `error`,
  "no recorded author"); the upgrade names them. Running it as the caller is the hole
  this closes, so the default stays closed.
* `test/audit.sh`: the PG-S1 teeth, red on 1.1.6 with their controls green.

## 1.1.6 -- 2026-10-08

* **Metadata only.** The PGXN description is two sentences now; the longer
  explanation it carried is in this README. No code changed: the upgrade
  script 1.1.5 -> 1.1.6 changes no object.

## 1.1.5 -- 2026-10-08

From an external audit of 1.1.4, each finding measured on 1.1.4 before it was changed
(`test/audit.sh`, `make check-audit`, in `make check-suites`: every tooth red on 1.1.4
with its control green).

* **The baseline's `search_path` no longer leaks into the caller's session (F-01).**
  1.1.4 applied it with `set_config(..., false)` inside helpers with a `SET` clause and
  said the clause would restore the caller's path; a plain `SET` overrides the clause
  and outlives it. After `verify()` the session kept the baseline's path, and its next
  `capture()` recorded that path and blessed a plan of another schema's table.
* **Every `EXPLAIN` of stored text runs sealed (F-02, F-03, F-14).** The planner folds
  an `IMMUTABLE` function with constant arguments, so a stored query ran code as whoever
  ran `verify()`, and kept what it did; and the advice was parsed with an unqualified
  `||` under the baseline's path, so an operator in a schema on it ran too. One function,
  `_explain_lines()`, now runs every `EXPLAIN` in a subtransaction switched to read-only
  and always rolled back, applies the baseline's path and `compute_query_id` inside it
  with `set_config(..., true)`, and parses under `pg_catalog, pg_temp`. `query_id_for()`
  no longer leaves `compute_query_id = on` in the caller's transaction.
* **A role that is not a superuser can capture (F-04)** when `pg_plan_advice` is
  preloaded: a refused `LOAD` of a loaded library is not an error any more.
* **A baseline that cannot be planned is logged on the transition (F-05),** like a
  drift, not on every run.
* **The identity sequences travel with `pg_dump` (F-06).** After a restore they
  started again at 1, and the first drift or capture died on a duplicate key. The
  upgrade also moves them past the ids an earlier restore left.
* **Re-capturing a name forgets the old statement's query_id (F-07),** and
  `sync_stash()` always computes it again -- and goes on past a baseline it cannot
  plan, instead of aborting on the first one with everything it had done.
* **The recorded path is read the way PostgreSQL reads it (F-10):** an unquoted
  `PG_TEMP` is `pg_temp` (a path from `set_config()` or `ALTER ROLE ... SET` is
  recorded as written), and a quoted schema name with a comma in it is one name.
* **Only the lines after the last "Generated Plan Advice:" header are the advice
  (F-11):** a query whose text contained the header leaked plan lines into it.
* **`drift_log` is append-only (F-13),** as documented: `UPDATE`, `DELETE` and
  `TRUNCATE` are refused by triggers.
* `test/cluster.sh` preloads `pg_plan_advice` and `pg_stash_advice` where they exist,
  as a server running this extension has them.

## 1.1.4 -- 2026-10-08

* **A baseline is re-planned against the tables its author meant.** Up to 1.1.3
  `verify()` and `sync_stash()` planned the stored query under the search_path of
  whoever ran them, where PostgreSQL searches `pg_temp` first. A temporary table
  named like a watched one was planned instead: a stable plan came back `drifted`
  and wrote a false drift into `drift_log`, and a real drift (an index under an
  approved seq scan) came back `ok`. A baseline captured with its schema on the
  path came back `error` from pg_cron's session, a `drift_log` row per run.
* `capture()` records the caller's path in the new column
  `baselines.search_path`; every re-plan applies it with `pg_temp` last, scoped
  to the call. Baselines captured before 1.1.4 keep the caller's path, also with
  `pg_temp` last, and the upgrade says how many there are.
* `META.json` requires pg_living_assertions 0.5.5 for `watch()`: the first
  release that runs a check with `pg_temp` last.
* `test/pg_temp.sh` and `test/cluster.sh` (`make check-pgtemp`): 4 FAIL on 1.1.3
  with their controls green, 12/12 on 1.1.4 including the upgrade, PostgreSQL
  19beta2.

## 1.1.3 -- 2026-10-06

* **License: Apache License 2.0**, replacing the PostgreSQL License, from this
  release on. Every version up to and including 1.1.2, already published,
  stays under the PostgreSQL License it was released with. No code changed.

## 1.1.2

Completes the copyright and licensing files: the copyright holder's full legal
name in LICENSE and README, and a per-file SPDX header on every SQL source
file. No schema change.

## 1.1.1

No schema change. Adds project governance and legal files (NOTICE, AUTHORS,
SECURITY, CONTRIBUTING, TRADEMARK). The database objects are byte-for-byte those
of 1.1; the `1.1--1.1.1` upgrade is empty on purpose.

## 1.1.0 and earlier

See the header of each `pg_plan_guard--*--*.sql` upgrade script and the release
notes on PGXN.
