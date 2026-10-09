-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_plan_guard 1.1.4 -> 1.1.5
--
-- From an external audit of 1.1.4, each finding measured on 1.1.4 first (test/audit.sh:
-- every tooth red there with its control green).
--
--   * The baseline's search_path leaked into the caller's session (F-01). 1.1.4 set it
--     with set_config(..., false) inside helpers with a SET clause and said the clause
--     would restore the caller's path. It does not: a plain SET inside such a function
--     overrides the clause and outlives it. After verify() the session kept the
--     baseline's path, and its next capture() recorded that path and blessed a plan of
--     another schema's table.
--   * advice_for() parsed EXPLAIN's output with an unqualified || under that path, so an
--     operator in a schema on it ran as whoever ran verify() (F-03).
--   * EXPLAIN plans the stored text as whoever runs verify(), and the planner folds an
--     IMMUTABLE function with constant arguments: what it did, it did as the runner, and
--     it was kept (F-02).
--   * query_id_for() left compute_query_id = on in the caller's transaction (F-14).
--
--   All four closed in one place, _explain_lines(): the path is pinned to pg_catalog,
--   pg_temp, and the EXPLAIN runs in a subtransaction that switches the transaction to
--   read-only, applies the baseline's path (and compute_query_id) with set_config(...,
--   true), and is always rolled back -- the seal pg_living_assertions puts around a
--   check. What planning does, it does read-only and then undone; the caller's path and
--   settings are never touched; the parse runs under pg_catalog. advice_for(),
--   plan_text_for() and query_id_for() keep their signatures and plan under the caller's
--   path, through the same seal.
--
--   * LOAD 'pg_plan_advice' needs superuser even when the library is preloaded, so no
--     other role could capture (F-04). A refused LOAD is now ignored: if the library is
--     loaded, EXPLAIN (PLAN_ADVICE) works; if not, EXPLAIN says so.
--   * A baseline that could not be planned wrote a drift_log row on every run (F-05);
--     now on the transition, like a drift.
--   * After pg_dump and restore the identity sequences started again at 1 (F-06). They
--     are dumped now, and this script moves them past the highest id an earlier restore
--     may have left.
--   * capture() over an existing name kept the old query_id, and sync_stash() pinned the
--     new advice to the old statement (F-07). capture() forgets it and sync_stash()
--     always recomputes it -- and goes on past a baseline it cannot plan instead of
--     aborting, with everything it had done, on the first one.
--   * An unquoted PG_TEMP was not recognised as pg_temp, and a quoted schema name with a
--     comma in it was split (F-10): the path is split the way PostgreSQL splits it.
--   * A query whose text contained "Generated Plan Advice:" leaked plan lines into the
--     advice (F-11): only the lines after the last header line are the advice.
--   * drift_log was documented as append-only and was not (F-13): UPDATE, DELETE and
--     TRUNCATE are refused by triggers.

\echo Use "ALTER EXTENSION pg_plan_guard UPDATE TO '1.1.5'" to load this file. \quit

-- The path with every entry naming the session's temporary schema removed and pg_temp
-- put last. A double-quoted name is kept whole, commas and doubled quotes included; an
-- unquoted one is matched without regard to case, as PostgreSQL folds it (set_config()
-- and ALTER ROLE ... SET store a path as written). NULL for a path that is not a
-- well-formed list: the caller then applies it as recorded, and PostgreSQL refuses it.
CREATE OR REPLACE FUNCTION plan_guard._with_pg_temp_last(p_search_path text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH entries AS (
        SELECT pg_catalog.btrim(m[1]) AS e, o
          FROM pg_catalog.regexp_matches(p_search_path, '((?:"(?:[^"]|"")*"|[^,"])+)', 'g')
               WITH ORDINALITY AS r(m, o)
    )
    SELECT CASE
        WHEN pg_catalog.regexp_replace(p_search_path, '(?:"(?:[^"]|"")*"|[^,"])+|,', '', 'g') <> '' THEN NULL
        ELSE pg_catalog.concat_ws(', ',
            (SELECT pg_catalog.string_agg(e, ', ' ORDER BY o) FROM entries
              WHERE e <> ''
                AND e !~* '^pg_temp(_[0-9]+)?$'
                AND e !~ '^"pg_temp(_[0-9]+)?"$'),
            'pg_temp')
    END
$$;

-- Every EXPLAIN of stored text goes through here. Sealed: read-only, then rolled back.
CREATE FUNCTION plan_guard._explain_lines(
    p_search_path text, p_options text, p_query_sql text,
    p_compute_query_id boolean DEFAULT false)
RETURNS text[]
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lines  text[] := '{}';
    v_line   text;
    -- plpgsql variables survive the rollback of the block that set them: the plan is
    -- read here, and the rollback throws away only what planning did.
    answered boolean := false;
BEGIN
    BEGIN
        PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
        IF p_compute_query_id THEN
            PERFORM pg_catalog.set_config('compute_query_id', 'on', true);
        END IF;
        PERFORM pg_catalog.set_config('search_path',
            coalesce(plan_guard._with_pg_temp_last(p_search_path), p_search_path), true);

        FOR v_line IN EXECUTE 'EXPLAIN (' || p_options || ') ' || p_query_sql
        LOOP
            v_lines := pg_catalog.array_append(v_lines, v_line);
        END LOOP;

        answered := true;
        RAISE EXCEPTION 'undo whatever planning did';
    EXCEPTION WHEN OTHERS THEN
        IF NOT answered THEN
            RAISE;
        END IF;
    END;
    RETURN v_lines;
END;
$$;

-- LOAD needs superuser even when the library is already preloaded. Refused, it is not
-- needed if the library is loaded, and EXPLAIN (PLAN_ADVICE) says so if it is not.
CREATE FUNCTION plan_guard._load_plan_advice()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    LOAD 'pg_plan_advice';
EXCEPTION
    WHEN insufficient_privilege THEN
        NULL;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'pg_plan_guard requires pg_plan_advice (PostgreSQL 19+): %', SQLERRM
            USING HINT = 'Install pg_plan_advice, or add it to shared_preload_libraries.';
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard._advice_under(p_search_path text, p_query_sql text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lines  text[];
    v_header int := 0;
BEGIN
    PERFORM plan_guard._load_plan_advice();
    v_lines := plan_guard._explain_lines(p_search_path, 'COSTS OFF, PLAN_ADVICE', p_query_sql);
    -- The advice is what follows the LAST line that is exactly the header: the section
    -- comes after every plan node, and the header's text inside a node -- a filter on a
    -- literal that says it -- is not the header.
    FOR i IN 1 .. coalesce(pg_catalog.array_length(v_lines, 1), 0) LOOP
        IF v_lines[i] ~ '^\s*Generated Plan Advice:\s*$' THEN
            v_header := i;
        END IF;
    END LOOP;
    IF v_header = 0 THEN
        RETURN '';
    END IF;
    RETURN pg_catalog.array_to_string(
        ARRAY(SELECT pg_catalog.btrim(l) FROM pg_catalog.unnest(v_lines[v_header + 1 :]) AS l), ' ');
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard._plan_text_under(p_search_path text, p_query_sql text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN pg_catalog.array_to_string(
        plan_guard._explain_lines(p_search_path, 'COSTS OFF', p_query_sql), E'\n');
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard._query_id_under(p_search_path text, p_query_sql text)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_line text;
BEGIN
    -- compute_query_id is set inside the seal, so it is gone when the seal is.
    FOREACH v_line IN ARRAY plan_guard._explain_lines(p_search_path, 'VERBOSE, COSTS OFF', p_query_sql, true)
    LOOP
        IF v_line ~ 'Query Identifier:' THEN
            RETURN (pg_catalog.regexp_match(v_line, 'Query Identifier:\s*(-?\d+)'))[1]::bigint;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

-- The public entry points keep their signatures, and plan under the caller's path --
-- through the same seal, with pg_temp last.
CREATE OR REPLACE FUNCTION plan_guard.advice_for(query_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN plan_guard._advice_under(pg_catalog.current_setting('search_path'), query_sql);
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard.plan_text_for(query_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN plan_guard._plan_text_under(pg_catalog.current_setting('search_path'), query_sql);
END;
$$;

CREATE OR REPLACE FUNCTION plan_guard.query_id_for(query_sql text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN plan_guard._query_id_under(pg_catalog.current_setting('search_path'), query_sql);
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
    VALUES (capture.name, capture.description, capture.query_sql, v_path, v_advice, v_plan,
            pg_catalog.now())
    ON CONFLICT (name) DO UPDATE
        SET query_sql   = EXCLUDED.query_sql,
            search_path = EXCLUDED.search_path,
            advice      = EXCLUDED.advice,
            plan_text   = EXCLUDED.plan_text,
            -- Another statement, maybe: the old one's query_id would pin this advice to
            -- it (1.1.5). sync_stash() computes it again.
            query_id    = NULL,
            description = coalesce(EXCLUDED.description, b.description),
            captured_at = pg_catalog.now(),
            verified_at = pg_catalog.now(),
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
               SET state = 'error', verified_at = pg_catalog.now()
             WHERE baselines.name = r.name;

            -- The transition, like a drift (1.1.5): a baseline that has not planned for
            -- a week is one row, not one per run.
            IF r.state IS DISTINCT FROM 'error' THEN
                INSERT INTO plan_guard.drift_log
                    (baseline_name, expected_advice, actual_advice, note)
                VALUES (r.name, r.advice, NULL, 'could not plan: ' || SQLERRM);
            END IF;

            name := r.name; state := 'error';
            expected_advice := r.advice; actual_advice := SQLERRM;
            RETURN NEXT;
            CONTINUE;
        END;

        IF v_actual IS DISTINCT FROM r.advice THEN
            UPDATE plan_guard.baselines
               SET state = 'drifted', verified_at = pg_catalog.now()
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
               SET state = 'ok', verified_at = pg_catalog.now()
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

    FOR r IN SELECT b.id, b.name, b.query_sql, b.advice,
                    coalesce(b.search_path, pg_catalog.current_setting('search_path')) AS search_path
             FROM plan_guard.baselines b ORDER BY b.name
    LOOP
        -- Computed every time (1.1.5): a cached id outlives a capture() of another
        -- statement under the same name. Under the path the baseline was captured
        -- with, the one the application's own executions resolve it under.
        BEGIN
            v_qid := plan_guard._query_id_under(r.search_path, r.query_sql);
        EXCEPTION WHEN OTHERS THEN
            -- One baseline that no longer plans does not take the others with it.
            name := r.name; query_id := NULL; action := 'no query_id: ' || SQLERRM;
            RETURN NEXT;
            CONTINUE;
        END;

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

-- drift_log is append-only, as documented since 1.0.
CREATE FUNCTION plan_guard._drift_log_is_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'plan_guard.drift_log is append-only: % is refused', TG_OP
        USING HINT = 'The drift history is the evidence an incident needs after the baseline was re-captured.';
END;
$$;

CREATE TRIGGER drift_log_is_append_only
    BEFORE UPDATE OR DELETE ON plan_guard.drift_log
    FOR EACH ROW EXECUTE FUNCTION plan_guard._drift_log_is_append_only();
CREATE TRIGGER drift_log_is_not_truncated
    BEFORE TRUNCATE ON plan_guard.drift_log
    FOR EACH STATEMENT EXECUTE FUNCTION plan_guard._drift_log_is_append_only();

-- The identity sequences travel with pg_dump from now on, and an installation that was
-- already restored once gets its sequences past the ids it holds.
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('plan_guard.baselines', 'id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('plan_guard.drift_log', 'id')::regclass, '');
SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence('plan_guard.baselines', 'id'),
                         m, true)
  FROM (SELECT max(id) AS m FROM plan_guard.baselines) s WHERE m IS NOT NULL
   AND m >= (SELECT last_value FROM plan_guard.baselines_id_seq);
SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence('plan_guard.drift_log', 'id'),
                         m, true)
  FROM (SELECT max(id) AS m FROM plan_guard.drift_log) s WHERE m IS NOT NULL
   AND m >= (SELECT last_value FROM plan_guard.drift_log_id_seq);

-- Internal helpers: owner only, like the functions they serve.
REVOKE ALL ON FUNCTION plan_guard._explain_lines(text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._load_plan_advice() FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._with_pg_temp_last(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._drift_log_is_append_only() FROM PUBLIC;
