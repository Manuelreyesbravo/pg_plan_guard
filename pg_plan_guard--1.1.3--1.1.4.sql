-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_plan_guard 1.1.3 -> 1.1.4
--
-- A baseline is re-planned against the tables its author meant.
--
-- capture() stores the query TEXT, and up to 1.1.3 verify() and sync_stash()
-- planned it under the search_path of whoever ran them. PostgreSQL searches pg_temp
-- first for relations when the path does not name it. Measured in test/pg_temp.sh
-- against 1.1.3:
--
--   * a temporary table named like a watched one was planned instead. With a
--     temporary `p` in the session, a baseline whose real plan had not moved came
--     back `drifted` and wrote a false drift into the append-only drift_log; and a
--     baseline whose real plan HAD moved -- an index appeared under an approved seq
--     scan -- came back `ok`, because the temporary copy still had no index;
--   * a baseline captured with its schema on the path could not be planned from a
--     session without it -- pg_cron's, typically -- and came back `error`, with a
--     drift_log row per run.
--
-- capture() now records the caller's search_path in baselines.search_path, and
-- every re-plan applies it with pg_temp moved to the END: the way
-- pg_living_assertions 0.5.5 runs a check, and with the same code. The path is set
-- with set_config() inside helpers whose own SET clause restores the caller's on
-- exit, error included, so it never leaks into the calling session.
--
-- Not pinned to an extension path, on purpose: the query is the author's and names
-- the author's tables, so the author's path is the one that must resolve it. What
-- changes is that it is the CAPTURING session's path, kept with the baseline, and
-- that no session's temporary tables can answer for it.
--
-- A baseline captured before 1.1.4 has no recorded path: it keeps being planned
-- under the caller's, also with pg_temp last, and this script names how many there
-- are. Capture it again to pin its path.

\echo Use "ALTER EXTENSION pg_plan_guard UPDATE TO '1.1.4'" to load this file. \quit

ALTER TABLE plan_guard.baselines ADD COLUMN search_path text;

COMMENT ON COLUMN plan_guard.baselines.search_path IS
    'search_path of the session that captured the baseline. verify() and sync_stash() '
    're-plan the query under it, with pg_temp last. NULL for baselines captured before '
    '1.1.4: those are planned under the caller''s path.';

-- A search_path with pg_temp moved to the end. Unnamed, PostgreSQL searches it
-- first; named elsewhere, a temporary table could still come before the author's.
-- Same expression as living_assertions.run() in pg_living_assertions 0.5.5.
CREATE FUNCTION plan_guard._with_pg_temp_last(p_search_path text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE WHEN p IS NULL THEN 'pg_temp' ELSE p || ', pg_temp' END
      FROM (SELECT string_agg(e, ', ' ORDER BY o) AS p
              FROM unnest(string_to_array(p_search_path, ',')) WITH ORDINALITY AS u(e, o)
             WHERE btrim(e) <> ''
               AND btrim(btrim(e), '"') <> 'pg_temp') s;
$$;

-- The three re-planning entry points, each under a given path. The SET clause is
-- what restores the caller's search_path when they return; set_config(..., false)
-- inside it is therefore scoped to the call, not to the session.
CREATE FUNCTION plan_guard._advice_under(p_search_path text, p_query_sql text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_catalog.set_config('search_path',
        plan_guard._with_pg_temp_last(p_search_path), false);
    RETURN plan_guard.advice_for(p_query_sql);
END;
$$;

CREATE FUNCTION plan_guard._plan_text_under(p_search_path text, p_query_sql text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_catalog.set_config('search_path',
        plan_guard._with_pg_temp_last(p_search_path), false);
    RETURN plan_guard.plan_text_for(p_query_sql);
END;
$$;

CREATE FUNCTION plan_guard._query_id_under(p_search_path text, p_query_sql text)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_catalog.set_config('search_path',
        plan_guard._with_pg_temp_last(p_search_path), false);
    RETURN plan_guard.query_id_for(p_query_sql);
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard.capture(
    name text, query_sql text, description text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
AS $$
-- Parameters are deliberately named after the columns they populate, because
-- those names are the public API (capture(name => ..., query_sql => ...)).
-- That makes `ON CONFLICT (name)` ambiguous, so column wins on conflict and the
-- parameters are reached explicitly as capture.name / capture.query_sql.
--
-- No SET clause, and that is the point: the path recorded is the CALLER's, the
-- one the query's author wrote it against.
#variable_conflict use_column
DECLARE
    v_path   text := pg_catalog.current_setting('search_path');
    v_advice text;
    v_plan   text;
BEGIN
    v_advice := plan_guard._advice_under(v_path, capture.query_sql);

    IF v_advice IS NULL OR v_advice = '' THEN
        RAISE EXCEPTION 'no advice could be extracted for baseline "%"', capture.name
            USING HINT = 'Check that the query is valid and that pg_plan_advice is active.';
    END IF;

    v_plan := plan_guard._plan_text_under(v_path, capture.query_sql);

    INSERT INTO plan_guard.baselines AS b
        (name, description, query_sql, search_path, advice, plan_text, verified_at)
    VALUES (capture.name, capture.description, capture.query_sql, v_path, v_advice, v_plan, now())
    ON CONFLICT (name) DO UPDATE
        SET query_sql   = EXCLUDED.query_sql,
            search_path = EXCLUDED.search_path,
            advice      = EXCLUDED.advice,
            plan_text   = EXCLUDED.plan_text,
            description = coalesce(EXCLUDED.description, b.description),
            captured_at = now(),
            verified_at = now(),
            state       = 'ok';

    RETURN v_advice;
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard.verify(only_name text DEFAULT NULL)
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
        SELECT b.name, b.query_sql, b.advice, b.state,
               -- No SET clause on this function, so this is the caller's path:
               -- the fallback for a baseline captured before 1.1.4.
               coalesce(b.search_path, pg_catalog.current_setting('search_path')) AS search_path
        FROM plan_guard.baselines b
        WHERE only_name IS NULL OR b.name = only_name
        ORDER BY b.name
    LOOP
        BEGIN
            v_actual := plan_guard._advice_under(r.search_path, r.query_sql);
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

CREATE OR REPLACE FUNCTION plan_guard.sync_stash(stash_name text)
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

    FOR r IN SELECT b.id, b.name, b.query_sql, b.advice, b.query_id,
                    coalesce(b.search_path, pg_catalog.current_setting('search_path')) AS search_path
             FROM plan_guard.baselines b ORDER BY b.name
    LOOP
        -- The query_id hashes the relations the query resolves to, so it is computed
        -- under the path the baseline was captured with: the one the application's
        -- own executions resolve it under.
        v_qid := coalesce(r.query_id, plan_guard._query_id_under(r.search_path, r.query_sql));

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

-- The helpers run EXPLAIN on stored SQL, like the functions they serve: owner only.
REVOKE ALL ON FUNCTION plan_guard._advice_under(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._plan_text_under(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._query_id_under(text, text) FROM PUBLIC;

DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM plan_guard.baselines WHERE search_path IS NULL;
    IF n > 0 THEN
        RAISE WARNING 'pg_plan_guard: % baseline(s) captured before 1.1.4 have no recorded search_path', n
            USING DETAIL = 'verify() and sync_stash() plan them under the caller''s search_path, with pg_temp last.',
                  HINT   = 'Capture them again from the session they were written for to pin their path.';
    END IF;
END;
$$;
