-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_plan_guard 1.1 -> 1.1.1
--
-- No schema change. This release adds project governance and legal files
-- (NOTICE, AUTHORS, SECURITY, CONTRIBUTING, TRADEMARK) and nothing that runs in
-- the database. The upgrade is empty on purpose: the objects a user has after
-- ALTER EXTENSION ... UPDATE TO '1.1.1' are exactly those of 1.1, which is what
-- ci/upgrade_check.sh verifies member by member against a fresh install.
