# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_plan_guard/). Each
upgrade script (`pg_plan_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

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
