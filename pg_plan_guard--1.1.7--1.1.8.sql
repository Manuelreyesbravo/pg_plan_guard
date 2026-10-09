-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_plan_guard 1.1.7 -> 1.1.8
--
-- F-12 (external audit of 1.1.4): CREATE EXTENSION used a plan_guard schema that already existed,
-- whoever owned it. The schema's owner -- any role with CREATE on the database -- kept it, and with
-- it the power to DROP SCHEMA plan_guard CASCADE: the extension, every baseline and the drift
-- history went with it (measured). The install, and every upgrade from here, refuses a plan_guard
-- schema owned by a role that is neither the installer nor a superuser. The same check
-- pg_grammar_guard 0.4.7 makes for its own schema.

\echo Use "ALTER EXTENSION pg_plan_guard UPDATE TO '1.1.8'" to load this file. \quit

DO $$
DECLARE
    owner_name  name;
    owner_super boolean;
BEGIN
    SELECT r.rolname, r.rolsuper INTO owner_name, owner_super
      FROM pg_catalog.pg_namespace n JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
     WHERE n.nspname = 'plan_guard';
    IF owner_name IS DISTINCT FROM current_user AND NOT owner_super THEN
        RAISE EXCEPTION 'pg_plan_guard: schema plan_guard is owned by %, not by the installer', owner_name
            USING DETAIL = 'Its owner can drop it, and the extension with every baseline and the drift history.',
                  HINT   = 'Drop that schema, or have a superuser own it, before installing.';
    END IF;
END $$;
