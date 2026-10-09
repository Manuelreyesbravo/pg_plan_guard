-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_plan_guard 1.1.6 -> 1.1.7
--
-- A baseline is planned as the role that wrote it.
--
-- 1.1.5 sealed every EXPLAIN of stored text: read-only, then rolled back. An external audit
-- of 1.1.5 (round 4, PG-S1) measured what that does not stop, because it is not a write to
-- the database: a function the planner folds ran COPY ... TO PROGRAM -- a file appeared,
-- owned by the server's OS user -- and pg_switch_wal(), pg_create_restore_point() and
-- pg_stat_reset() ran, all as the role running verify(), usually a superuser; a session
-- advisory lock stayed in that session; and pg_cancel_backend() of its own backend aborted
-- verify() and sync_stash() for every baseline. The role that needed nothing but INSERT on
-- baselines.
--
-- The stored text is its author's code, so it now runs with its author's rights:
--
--   * baselines.captured_by records the author. A trigger sets it to whoever writes or
--     rewrites the query (capture(), or an INSERT or UPDATE of the SQL), and accepts another
--     name only from a role that may SET ROLE to it -- a superuser restoring a dump, say. A
--     role with INSERT on baselines cannot sign a baseline as anyone else.
--   * Inside the seal, the EXPLAIN runs after SET ROLE to the author. Whatever needs more
--     than the author has is refused there and reported as that baseline's error; the
--     author cancelling the runner's backend is refused the same way.
--   * A session advisory lock taken inside the seal is released when it ends.
--
-- A baseline captured before 1.1.7 has no recorded author, and is refused by verify() and
-- sync_stash() -- state error, with the reason -- until it is captured again: running it as
-- the caller is the hole this closes, and the default stays closed. This script names them.

\echo Use "ALTER EXTENSION pg_plan_guard UPDATE TO '1.1.7'" to load this file. \quit

-- Added without a default, so the baselines already there stay without an author; the
-- default applies from here on to an INSERT that leaves the column out.
ALTER TABLE plan_guard.baselines ADD COLUMN captured_by text;
ALTER TABLE plan_guard.baselines ALTER COLUMN captured_by SET DEFAULT current_user;

COMMENT ON COLUMN plan_guard.baselines.captured_by IS
    'The role that wrote the query; verify() and sync_stash() plan it as that role. Set by a '
    'trigger to whoever writes or rewrites the SQL. NULL for baselines from before 1.1.7, '
    'which are refused until captured again.';

-- Whoever writes the SQL is its author, and a row may name another author only if the
-- writer may become that role.
CREATE FUNCTION plan_guard._baseline_author()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.captured_by IS NOT DISTINCT FROM OLD.captured_by THEN
        -- The SQL or its path changed and nobody named an author: the writer is it.
        NEW.captured_by := current_user;
    END IF;
    -- An explicit NULL stays NULL: no author, so verify() refuses the baseline. Filling it in
    -- here would turn a baseline without one, restored by a superuser, into the superuser's.

    IF NEW.captured_by IS NOT NULL AND NEW.captured_by IS DISTINCT FROM current_user::text THEN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = NEW.captured_by) THEN
            -- A dump restored where that role does not exist: only a superuser may keep the
            -- name, and the baseline fails until the role exists or it is captured again.
            IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
                RAISE EXCEPTION 'plan_guard: a baseline runs as the role that wrote it, and role % does not exist', NEW.captured_by;
            END IF;
        ELSIF NOT pg_has_role(current_user, NEW.captured_by, 'SET') THEN
            RAISE EXCEPTION 'plan_guard: a baseline runs as the role that wrote it, and % cannot act as %',
                current_user, NEW.captured_by
                USING HINT = 'Leave captured_by out: it is set to the role that writes the query.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER baseline_author_on_insert
    BEFORE INSERT ON plan_guard.baselines
    FOR EACH ROW EXECUTE FUNCTION plan_guard._baseline_author();
CREATE TRIGGER baseline_author_on_rewrite
    BEFORE UPDATE OF query_sql, search_path, captured_by ON plan_guard.baselines
    FOR EACH ROW EXECUTE FUNCTION plan_guard._baseline_author();

-- Session advisory locks survive the rollback of the subtransaction that took them. Release
-- the ones this backend holds now and did not hold before the seal.
CREATE FUNCTION plan_guard._release_advisory_locks(p_before text[])
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    r    record;
    held boolean;
BEGIN
    FOR r IN
        SELECT l.classid::bigint AS c, l.objid::bigint AS o, l.objsubid, l.mode
          FROM pg_locks l
         WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted
           AND (l.classid || ':' || l.objid || ':' || l.objsubid || ':' || l.mode)
               <> ALL (coalesce(p_before, '{}'))
    LOOP
        LOOP
            IF r.objsubid = 1 THEN
                -- One bigint key: classid holds its high half, objid its low half.
                IF r.mode = 'ExclusiveLock' THEN
                    held := pg_advisory_unlock((r.c << 32) | r.o);
                ELSE
                    held := pg_advisory_unlock_shared((r.c << 32) | r.o);
                END IF;
            ELSE
                -- Two int4 keys, stored as oids.
                IF r.mode = 'ExclusiveLock' THEN
                    held := pg_advisory_unlock((r.c - CASE WHEN r.c > 2147483647 THEN 4294967296 ELSE 0 END)::int,
                                               (r.o - CASE WHEN r.o > 2147483647 THEN 4294967296 ELSE 0 END)::int);
                ELSE
                    held := pg_advisory_unlock_shared((r.c - CASE WHEN r.c > 2147483647 THEN 4294967296 ELSE 0 END)::int,
                                                      (r.o - CASE WHEN r.o > 2147483647 THEN 4294967296 ELSE 0 END)::int);
                END IF;
            END IF;
            EXIT WHEN NOT held;   -- taken more than once: release every hold
        END LOOP;
    END LOOP;
END;
$$;

DROP FUNCTION plan_guard._advice_under(text, text);
DROP FUNCTION plan_guard._plan_text_under(text, text);
DROP FUNCTION plan_guard._query_id_under(text, text);
DROP FUNCTION plan_guard._explain_lines(text, text, text, boolean);

-- Every EXPLAIN of stored text goes through here: read-only, as p_role when given, and
-- rolled back.
CREATE FUNCTION plan_guard._explain_lines(
    p_search_path text, p_options text, p_query_sql text,
    p_compute_query_id boolean DEFAULT false, p_role text DEFAULT NULL)
RETURNS text[]
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lines  text[] := '{}';
    v_line   text;
    v_locks  text[];
    -- plpgsql variables survive the rollback of the block that set them: the plan is
    -- read here, and the rollback throws away only what planning did.
    answered boolean := false;
BEGIN
    SELECT array_agg(classid || ':' || objid || ':' || objsubid || ':' || mode) INTO v_locks
      FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted;
    BEGIN
        PERFORM set_config('transaction_read_only', 'on', true);
        IF p_compute_query_id THEN
            PERFORM set_config('compute_query_id', 'on', true);
        END IF;
        PERFORM set_config('search_path',
            coalesce(plan_guard._with_pg_temp_last(p_search_path), p_search_path), true);
        -- Last, after the settings that need the caller's rights: from here on the stored
        -- text runs with its author's (1.1.7).
        IF p_role IS NOT NULL AND p_role IS DISTINCT FROM current_user::text THEN
            PERFORM set_config('role', p_role, true);
        END IF;

        FOR v_line IN EXECUTE 'EXPLAIN (' || p_options || ') ' || p_query_sql
        LOOP
            v_lines := array_append(v_lines, v_line);
        END LOOP;

        answered := true;
        RAISE EXCEPTION 'undo whatever planning did';
    EXCEPTION WHEN OTHERS THEN
        PERFORM plan_guard._release_advisory_locks(v_locks);
        IF NOT answered THEN
            RAISE;
        END IF;
    END;
    RETURN v_lines;
END;
$$;

CREATE FUNCTION plan_guard._advice_under(p_search_path text, p_query_sql text, p_role text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lines  text[];
    v_header int := 0;
BEGIN
    PERFORM plan_guard._load_plan_advice();
    v_lines := plan_guard._explain_lines(p_search_path, 'COSTS OFF, PLAN_ADVICE', p_query_sql, false, p_role);
    -- The advice is what follows the LAST line that is exactly the header.
    FOR i IN 1 .. coalesce(array_length(v_lines, 1), 0) LOOP
        IF v_lines[i] ~ '^\s*Generated Plan Advice:\s*$' THEN
            v_header := i;
        END IF;
    END LOOP;
    IF v_header = 0 THEN
        RETURN '';
    END IF;
    RETURN array_to_string(ARRAY(SELECT btrim(l) FROM unnest(v_lines[v_header + 1 :]) AS l), ' ');
END;
$$;

CREATE FUNCTION plan_guard._plan_text_under(p_search_path text, p_query_sql text, p_role text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN array_to_string(
        plan_guard._explain_lines(p_search_path, 'COSTS OFF', p_query_sql, false, p_role), E'\n');
END;
$$;

CREATE FUNCTION plan_guard._query_id_under(p_search_path text, p_query_sql text, p_role text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_line text;
BEGIN
    FOREACH v_line IN ARRAY plan_guard._explain_lines(p_search_path, 'VERBOSE, COSTS OFF', p_query_sql, true, p_role)
    LOOP
        IF v_line ~ 'Query Identifier:' THEN
            RETURN (regexp_match(v_line, 'Query Identifier:\s*(-?\d+)'))[1]::bigint;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

-- A baseline with no recorded author is not planned as anyone (1.1.7).
CREATE FUNCTION plan_guard._author_or_refuse(p_name text, p_author text)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_author IS NULL THEN
        RAISE EXCEPTION 'baseline "%" was captured before 1.1.7 and has no recorded author, so it is not planned', p_name
            USING HINT = 'Capture it again: from 1.1.7 a baseline is planned as the role that wrote it.';
    END IF;
    RETURN p_author;
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
-- one the query's author wrote it against -- and the caller is its author.
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
        (name, description, query_sql, search_path, captured_by, advice, plan_text, verified_at)
    VALUES (capture.name, capture.description, capture.query_sql, v_path, current_user, v_advice, v_plan,
            pg_catalog.now())
    ON CONFLICT (name) DO UPDATE
        SET query_sql   = EXCLUDED.query_sql,
            search_path = EXCLUDED.search_path,
            captured_by = EXCLUDED.captured_by,
            advice      = EXCLUDED.advice,
            plan_text   = EXCLUDED.plan_text,
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
        SELECT b.name, b.query_sql, b.advice, b.state, b.captured_by,
               -- No SET clause on this function, so this is the caller's path:
               -- the fallback for a baseline captured before 1.1.4.
               coalesce(b.search_path, pg_catalog.current_setting('search_path')) AS search_path
        FROM plan_guard.baselines b
        WHERE only_name IS NULL OR b.name = only_name
        ORDER BY b.name
    LOOP
        BEGIN
            v_actual := plan_guard._advice_under(r.search_path, r.query_sql,
                                                 plan_guard._author_or_refuse(r.name, r.captured_by));
        EXCEPTION WHEN OTHERS THEN
            UPDATE plan_guard.baselines
               SET state = 'error', verified_at = pg_catalog.now()
             WHERE baselines.name = r.name;

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

    FOR r IN SELECT b.id, b.name, b.query_sql, b.advice, b.captured_by,
                    coalesce(b.search_path, pg_catalog.current_setting('search_path')) AS search_path
             FROM plan_guard.baselines b ORDER BY b.name
    LOOP
        BEGIN
            v_qid := plan_guard._query_id_under(r.search_path, r.query_sql,
                                                plan_guard._author_or_refuse(r.name, r.captured_by));
        EXCEPTION WHEN OTHERS THEN
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

REVOKE ALL ON FUNCTION plan_guard._explain_lines(text, text, text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._advice_under(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._plan_text_under(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._query_id_under(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._release_advisory_locks(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._author_or_refuse(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION plan_guard._baseline_author() FROM PUBLIC;

DO $$
DECLARE
    names text;
BEGIN
    SELECT string_agg(name, ', ' ORDER BY name) INTO names
      FROM plan_guard.baselines WHERE captured_by IS NULL;
    IF names IS NOT NULL THEN
        RAISE WARNING 'pg_plan_guard: these baselines were captured before 1.1.7 and have no recorded author: %', names
            USING DETAIL = 'verify() and sync_stash() refuse them (state error) until they are captured again.',
                  HINT   = 'Capture each one again, as the role that should own its query.';
    END IF;
END;
$$;
