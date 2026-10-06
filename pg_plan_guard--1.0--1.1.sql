-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: PostgreSQL

-- pg_plan_guard 1.0 -> 1.1
--
-- watch(): the approved plan becomes a living assertion.
--
-- WHAT verify() WAS DOING BY HAND. Read whole, it does five things this
-- extension had to invent for itself:
--
--   * keeps the approved advice                -> the assertion
--   * keeps a state (ok|drifted|error)         -> holds|broken|erroring
--   * keeps verified_at                        -> checks.checked_at
--   * logs only the TRANSITIONS to drift_log   -> a query over an append-only log
--   * tells "could not plan" from "plan moved" -> erroring vs broken
--
-- That last one is the same distinction pg_grammar_guard called
-- never_approved-vs-drift and pg_promise_guard called gap-vs-breach: invented a
-- third time, under a third pair of names.
--
-- NOTHING IS REMOVED. capture(), verify(), baselines and drift_log keep working
-- exactly as they did in 1.0, and sync_stash() still reads baselines. This is
-- additive on purpose: plan_guard is the only guard whose baseline table holds
-- something the piece cannot -- the QUERY TEXT, which sync_stash needs to push
-- advice into pg_stash_advice. A baseline that is only a fingerprint could be
-- dropped; one that is also the source of truth for another feature cannot.

\echo Use "ALTER EXTENSION pg_plan_guard UPDATE TO '1.1'" to load this file. \quit

CREATE FUNCTION plan_guard.watch(p_name text, p_query_sql text, p_note text DEFAULT NULL)
RETURNS bigint
-- plpgsql and a dynamic call, NOT a plain SQL body, and that is the difference
-- between an optional dependency and a mandatory one. This extension is already
-- published; `requires` in a control file is not per-version, so declaring it
-- would force pg_living_assertions on somebody installing 1.0. A SQL body would
-- have the same effect through the back door: SQL functions are validated when
-- created, so CREATE EXTENSION would fail on a host without it. plpgsql bodies
-- are not, so the extension installs and only watch() needs the companion.
--
-- NO `SET search_path` either, and that is not an oversight: living_assertions
-- records the CALLER's path so the check keeps resolving names the way the
-- query's author meant. A SET clause here would run first and record OURS, and
-- the watched query would be checked against tables its author never named.
-- Any wrapper in front of declare() carries the same obligation.
LANGUAGE plpgsql
AS $$
DECLARE
    id bigint;
BEGIN
    IF to_regnamespace('living_assertions') IS NULL THEN
        RAISE EXCEPTION 'watch() needs pg_living_assertions'
            USING HINT = 'CREATE EXTENSION pg_living_assertions; -- capture(), '
                         'verify() and sync_stash() work without it.';
    END IF;

    -- The EXPRESSION, not the advice. advice_for() re-plans against today's
    -- catalog and today's statistics every time the check runs, which is the
    -- whole point: a stored advice string compared against itself would be a
    -- check that can never fail.
    EXECUTE format(
        'select living_assertions.declare_unchanged(%L, %L, %L)',
        'plan:' || p_name,
        coalesce(p_note || ' -- ', '') ||
            'this query still plans the way it was approved',
        format('select plan_guard.advice_for(%L)', p_query_sql))
    INTO id;
    RETURN id;
END;
$$;

COMMENT ON FUNCTION plan_guard.watch(text, text, text) IS
    'Approves how this query plans right now and registers it as a living '
    'assertion, so the verdict carries the date it was taken. Unlike verify(), '
    'a query that no longer plans at all comes back as erroring rather than as '
    'a drift -- a broken query is a defect to fix, not a plan that moved.';
