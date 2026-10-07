# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_plan_guard/). Each
upgrade script (`pg_plan_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

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
