/* pg_plan_guard--1.0.sql
 *
 * Watch query plans for drift against known-good baselines.
 *
 * WHY THIS EXISTS
 * ---------------
 * PostgreSQL 19 introduced pg_plan_advice (generate advice for a plan, then
 * force it) and pg_stash_advice (store advice per query_id and apply it
 * automatically). Both are deliberate, manual acts: you decide a plan is good,
 * and you pin it.
 *
 * Neither of them watches. There is no way to ask "is the plan for this query
 * still the plan I approved?" — and that is the question that matters in
 * production, because a plan regression usually does not fail. The query still
 * returns the same rows; it just stops using the index and starts scanning.
 * Nothing errors, nothing logs, nothing alerts. You find out weeks later from a
 * latency graph, if you find out at all.
 *
 * The case this was built for: a vector similarity query backed by a DiskANN
 * index. If the planner stops choosing that index, results are IDENTICAL — the
 * ORDER BY is still correct — but it is now a sequential scan over 39,893
 * vectors. Correct, silent, and slow. That class of failure is the expensive
 * one precisely because it does not announce itself.
 *
 * WHAT IT DOES
 * ------------
 *   plan_guard.capture('name', 'SELECT ...')  -- store today's plan as good
 *   SELECT * FROM plan_guard.verify();        -- has anything drifted?
 *   SELECT * FROM plan_guard.status;          -- current state of every baseline
 *
 * Drift is recorded append-only in plan_guard.drift_log, so "when did this
 * start?" is answerable after the fact — the question you always have and never
 * have the data for.
 *
 * REQUIREMENTS
 * ------------
 * PostgreSQL 19 or later with pg_plan_advice available. Baselines are captured
 * with EXPLAIN (PLAN_ADVICE), which does not execute the query.
 *
 * Copyright (c) 2026, licensed under the PostgreSQL License.
 */

-- Guard against direct psql execution (standard practice for extension scripts)
\echo Use "CREATE EXTENSION pg_plan_guard" to load this file. \quit


-- ---------------------------------------------------------------------------
-- Baselines: the approved plan for a query, as advice text.
--
-- Advice is compared instead of the raw EXPLAIN output on purpose: EXPLAIN text
-- changes with row estimates and costs even when the plan SHAPE is identical,
-- which would make every baseline drift constantly and train everyone to ignore
-- the alerts. Advice describes the shape — which scan on which relation, which
-- join order, which method — so it changes only when the decision changes.
-- ---------------------------------------------------------------------------
CREATE TABLE plan_guard.baselines (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text        NOT NULL UNIQUE,
    description     text,
    query_sql       text        NOT NULL,
    advice          text        NOT NULL,
    plan_text       text,
    query_id        bigint,
    captured_at     timestamptz NOT NULL DEFAULT now(),
    verified_at     timestamptz,
    state           text        NOT NULL DEFAULT 'ok'
                    CHECK (state IN ('ok', 'drifted', 'error'))
);

SELECT pg_catalog.pg_extension_config_dump('plan_guard.baselines', '');

COMMENT ON TABLE plan_guard.baselines IS
    'Approved plans for critical queries, stored as pg_plan_advice text. The unit of comparison is plan SHAPE, not EXPLAIN output.';
COMMENT ON COLUMN plan_guard.baselines.advice IS
    'Advice for the approved plan. Comparing advice (not EXPLAIN text) avoids false drift from changing row estimates.';
COMMENT ON COLUMN plan_guard.baselines.query_id IS
    'query_id used by pg_stash_advice to re-apply this advice automatically. Populated by plan_guard.sync_stash().';


-- ---------------------------------------------------------------------------
-- Drift log: append-only history.
--
-- The state column on baselines answers "is it drifting now". This answers
-- "since when, and what did it change from" — which is the question you have
-- during an incident, when the baseline has already been re-captured and the
-- evidence would otherwise be gone.
-- ---------------------------------------------------------------------------
CREATE TABLE plan_guard.drift_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    baseline_name   text        NOT NULL,
    detected_at     timestamptz NOT NULL DEFAULT now(),
    expected_advice text,
    actual_advice   text,
    note            text
);

CREATE INDEX plan_guard_drift_log_name_idx
    ON plan_guard.drift_log (baseline_name, detected_at DESC);

SELECT pg_catalog.pg_extension_config_dump('plan_guard.drift_log', '');

COMMENT ON TABLE plan_guard.drift_log IS
    'Append-only record of every detected plan drift. Answers "since when", which the current state cannot.';


-- ---------------------------------------------------------------------------
-- plan_guard.advice_for(query) -> advice text
--
-- Runs EXPLAIN (PLAN_ADVICE) and extracts the generated advice block. Does NOT
-- execute the query (no ANALYZE), so it is cheap and safe to run on a schedule.
-- ---------------------------------------------------------------------------
CREATE FUNCTION plan_guard.advice_for(query_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    line        text;
    in_advice   boolean := false;
    parts       text[]  := '{}';
BEGIN
    -- pg_plan_advice can be preloaded or loaded on demand; LOAD is idempotent.
    BEGIN
        LOAD 'pg_plan_advice';
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'pg_plan_guard requires pg_plan_advice (PostgreSQL 19+): %', SQLERRM
            USING HINT = 'Install pg_plan_advice, or add it to shared_preload_libraries.';
    END;

    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF, PLAN_ADVICE) ' || query_sql
    LOOP
        IF line ~ 'Generated Plan Advice:' THEN
            in_advice := true;
            CONTINUE;
        END IF;
        IF in_advice THEN
            parts := parts || btrim(line);
        END IF;
    END LOOP;

    RETURN array_to_string(parts, ' ');
END;
$$;

COMMENT ON FUNCTION plan_guard.advice_for(text) IS
    'Plan advice for a query, via EXPLAIN (PLAN_ADVICE). Does not execute the query.';


-- ---------------------------------------------------------------------------
-- plan_guard.plan_text_for(query) -> human-readable plan
-- ---------------------------------------------------------------------------
CREATE FUNCTION plan_guard.plan_text_for(query_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    line  text;
    lines text[] := '{}';
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query_sql
    LOOP
        lines := lines || line;
    END LOOP;
    RETURN array_to_string(lines, E'\n');
END;
$$;

COMMENT ON FUNCTION plan_guard.plan_text_for(text) IS
    'Plain EXPLAIN output, stored alongside the baseline so a human can see what was approved without re-explaining by hand.';


-- ---------------------------------------------------------------------------
-- plan_guard.query_id_for(query) -> query_id
--
-- Needed to hand advice to pg_stash_advice. compute_query_id defaults to 'auto',
-- which only computes the id if something asks for it — hence the explicit SET
-- LOCAL, scoped to the transaction so it never leaks to the caller's session.
-- ---------------------------------------------------------------------------
CREATE FUNCTION plan_guard.query_id_for(query_sql text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    line text;
BEGIN
    SET LOCAL compute_query_id = on;

    FOR line IN EXECUTE 'EXPLAIN (VERBOSE, COSTS OFF) ' || query_sql
    LOOP
        IF line ~ 'Query Identifier:' THEN
            RETURN (regexp_match(line, 'Query Identifier:\s*(-?\d+)'))[1]::bigint;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;


-- ---------------------------------------------------------------------------
-- plan_guard.capture(name, query [, description]) -> advice
--
-- Records the CURRENT plan as the approved one. Deliberately an explicit act:
-- a baseline that captured itself automatically would happily bless whatever
-- plan happened to be in effect, including the regression you are hunting.
-- ---------------------------------------------------------------------------
CREATE FUNCTION plan_guard.capture(
    name text, query_sql text, description text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
AS $$
-- Parameters are deliberately named after the columns they populate, because
-- those names are the public API (capture(name => ..., query_sql => ...)).
-- That makes `ON CONFLICT (name)` ambiguous, so column wins on conflict and the
-- parameters are reached explicitly as capture.name / capture.query_sql.
#variable_conflict use_column
DECLARE
    v_advice text;
    v_plan   text;
BEGIN
    v_advice := plan_guard.advice_for(capture.query_sql);

    IF v_advice IS NULL OR v_advice = '' THEN
        RAISE EXCEPTION 'no advice could be extracted for baseline "%"', capture.name
            USING HINT = 'Check that the query is valid and that pg_plan_advice is active.';
    END IF;

    v_plan := plan_guard.plan_text_for(capture.query_sql);

    INSERT INTO plan_guard.baselines AS b
        (name, description, query_sql, advice, plan_text, verified_at)
    VALUES (capture.name, capture.description, capture.query_sql, v_advice, v_plan, now())
    ON CONFLICT (name) DO UPDATE
        SET query_sql   = EXCLUDED.query_sql,
            advice      = EXCLUDED.advice,
            plan_text   = EXCLUDED.plan_text,
            description = coalesce(EXCLUDED.description, b.description),
            captured_at = now(),
            verified_at = now(),
            state       = 'ok';

    RETURN v_advice;
END;
$$;

COMMENT ON FUNCTION plan_guard.capture(text, text, text) IS
    'Approve the current plan for a query as its baseline. Explicit by design: auto-capture would bless a regression.';


-- ---------------------------------------------------------------------------
-- plan_guard.verify([name]) -> one row per baseline
--
-- THE PART THAT DOES NOT EXIST UPSTREAM. Re-plans each stored query and compares
-- today's advice against the approved one.
--
-- A query that no longer plans at all (table dropped, column renamed) is
-- reported as 'error' rather than raising: one broken baseline must not prevent
-- the others from being checked. A monitor that dies on the first problem is a
-- monitor that stops working exactly when something is wrong.
-- ---------------------------------------------------------------------------
CREATE FUNCTION plan_guard.verify(only_name text DEFAULT NULL)
RETURNS TABLE (
    name            text,
    state           text,
    expected_advice text,
    actual_advice   text
)
LANGUAGE plpgsql
AS $$
DECLARE
    r        record;
    v_actual text;
BEGIN
    FOR r IN
        SELECT b.name, b.query_sql, b.advice, b.state
        FROM plan_guard.baselines b
        WHERE only_name IS NULL OR b.name = only_name
        ORDER BY b.name
    LOOP
        BEGIN
            v_actual := plan_guard.advice_for(r.query_sql);
        EXCEPTION WHEN OTHERS THEN
            UPDATE plan_guard.baselines
               SET state = 'error', verified_at = now()
             WHERE baselines.name = r.name;

            INSERT INTO plan_guard.drift_log
                (baseline_name, expected_advice, actual_advice, note)
            VALUES (r.name, r.advice, NULL, 'could not plan: ' || SQLERRM);

            name := r.name; state := 'error';
            expected_advice := r.advice; actual_advice := SQLERRM;
            RETURN NEXT;
            CONTINUE;
        END;

        IF v_actual IS DISTINCT FROM r.advice THEN
            UPDATE plan_guard.baselines
               SET state = 'drifted', verified_at = now()
             WHERE baselines.name = r.name;

            -- Only log the transition, not every check: a baseline that has been
            -- drifting for a week should not produce a row per cron run.
            IF r.state <> 'drifted' THEN
                INSERT INTO plan_guard.drift_log
                    (baseline_name, expected_advice, actual_advice)
                VALUES (r.name, r.advice, v_actual);
            END IF;

            state := 'drifted';
        ELSE
            UPDATE plan_guard.baselines
               SET state = 'ok', verified_at = now()
             WHERE baselines.name = r.name;
            state := 'ok';
        END IF;

        name            := r.name;
        expected_advice := r.advice;
        actual_advice   := v_actual;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION plan_guard.verify(text) IS
    'Re-plan every baseline and report drift. This is the capability pg_plan_advice does not provide.';


-- ---------------------------------------------------------------------------
-- plan_guard.sync_stash(stash_name) -> one row per baseline
--
-- Pushes approved advice into pg_stash_advice so the planner re-applies it
-- without anyone issuing a SET.
--
-- The table is the source of truth, not shared memory. pg_stash_advice.persist
-- survives restarts, but if persistence ever fails or the cluster is recreated,
-- the pinning disappears SILENTLY — queries keep working, just slowly. Same
-- failure mode this extension exists to catch, so the stash is treated as a
-- cache that can always be rebuilt from the table.
-- ---------------------------------------------------------------------------
CREATE FUNCTION plan_guard.sync_stash(stash_name text)
RETURNS TABLE (name text, query_id bigint, action text)
LANGUAGE plpgsql
AS $$
DECLARE
    r     record;
    v_qid bigint;
BEGIN
    BEGIN
        PERFORM pg_create_advice_stash(stash_name);
    EXCEPTION WHEN OTHERS THEN
        NULL;  -- already exists, or not creatable here; set_stashed_advice will tell us
    END;

    FOR r IN SELECT b.id, b.name, b.query_sql, b.advice, b.query_id
             FROM plan_guard.baselines b ORDER BY b.name
    LOOP
        v_qid := coalesce(r.query_id, plan_guard.query_id_for(r.query_sql));

        IF v_qid IS NULL THEN
            name := r.name; query_id := NULL; action := 'no query_id';
            RETURN NEXT;
            CONTINUE;
        END IF;

        UPDATE plan_guard.baselines SET query_id = v_qid WHERE id = r.id;

        BEGIN
            PERFORM pg_set_stashed_advice(stash_name, v_qid, r.advice);
            action := 'stashed';
        EXCEPTION WHEN OTHERS THEN
            action := 'failed: ' || SQLERRM;
        END;

        name := r.name; query_id := v_qid;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION plan_guard.sync_stash(text) IS
    'Rebuild a pg_stash_advice stash from the baselines table. The table is the source of truth; the stash is a cache.';


-- ---------------------------------------------------------------------------
-- plan_guard.status — what a human or a monitor reads.
-- ---------------------------------------------------------------------------
CREATE VIEW plan_guard.status AS
SELECT b.name,
       b.state,
       b.description,
       b.verified_at,
       b.captured_at,
       (SELECT count(*) FROM plan_guard.drift_log d WHERE d.baseline_name = b.name)
           AS drift_events,
       (SELECT max(d.detected_at) FROM plan_guard.drift_log d WHERE d.baseline_name = b.name)
           AS last_drift
FROM plan_guard.baselines b
ORDER BY (b.state <> 'ok') DESC, b.name;

COMMENT ON VIEW plan_guard.status IS
    'Current state of every baseline, worst first. Intended as the single query a monitoring system polls.';


-- ---------------------------------------------------------------------------
-- Read access for non-owners. Capture/verify stay with the extension owner:
-- both run EXPLAIN on stored SQL, so they must not be handed out casually.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION plan_guard.advice_for(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard.plan_text_for(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard.query_id_for(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard.capture(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard.verify(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard.sync_stash(text) FROM PUBLIC;
