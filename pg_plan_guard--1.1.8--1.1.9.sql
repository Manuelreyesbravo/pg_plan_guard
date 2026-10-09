-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_plan_guard 1.1.8 -> 1.1.9
--
-- SET ROLE is not a boundary, so a baseline is no longer planned under one.
--
-- From 1.1.7 the EXPLAIN of a stored baseline ran after SET ROLE to its author. An external audit
-- of 1.1.8 (round 5) measured what that leaves: SET ROLE changes current_user and nothing else,
-- so a function the planner folds ran RESET ROLE -- or SET SESSION AUTHORIZATION DEFAULT, or
-- set_config('role', ...) -- and was back to whoever ran verify(), usually a superuser; from
-- there COPY ... TO PROGRAM wrote a file as the server's OS user. The direct calls were refused;
-- the way around them was one statement.
--
-- PostgreSQL has a boundary that holds, and it is the one every SECURITY DEFINER function runs
-- in: inside it, role and session_authorization cannot be changed at all ("cannot set parameter
-- ... within security-definer function"), and that holds for everything the function calls. So
-- the seal now builds one:
--
--   * Inside the seal, a temporary SECURITY DEFINER function holding the EXPLAIN is created and
--     handed to the baseline's author; the EXPLAIN runs by calling it. Planning as that role, a
--     folded function can do what that role can do and cannot become anyone else. The function
--     is created inside the seal's subtransaction and rolled back with everything planning did.
--   * The caller must be able to hand it over: a superuser can, another role needs to be able to
--     SET ROLE to the author, and the author needs TEMP on the database (PUBLIC has it by
--     default). What is missing is that baseline's error, with the reason.
--   * The frame is skipped only where it cannot change anything: the author is the current user,
--     and either the call is already inside a SECURITY DEFINER frame or there is no other
--     identity to go back to -- the author is the session user and the role that logged in.
--     capture() of one's own query costs what it cost.

\echo Use "ALTER EXTENSION pg_plan_guard UPDATE TO '1.1.9'" to load this file. \quit

-- Whether code run now as p_author could leave it. Not inside a SECURITY DEFINER frame: there
-- PostgreSQL refuses to change role or session_authorization. Outside one, RESET ROLE goes back
-- to session_user and SET SESSION AUTHORIZATION DEFAULT to the role that logged in, so code
-- gains nothing only when the author is all three.
CREATE FUNCTION plan_guard._needs_a_definer_frame(p_author text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    in_a_frame boolean;
    logged_in  text;
BEGIN
    IF p_author IS DISTINCT FROM current_user::text THEN
        RETURN true;
    END IF;
    -- Setting role to the value it already has changes nothing, and is refused only inside a
    -- frame. The block is rolled back either way.
    BEGIN
        PERFORM set_config('role', current_setting('role'), true);
        RAISE EXCEPTION USING ERRCODE = 'P0001';
    EXCEPTION
        WHEN insufficient_privilege THEN in_a_frame := true;
        WHEN raise_exception THEN in_a_frame := false;
    END;
    IF in_a_frame THEN
        RETURN false;
    END IF;
    -- pg_stat_activity names the role that logged in; SET SESSION AUTHORIZATION does not change it.
    SELECT a.usename INTO logged_in FROM pg_stat_activity a WHERE a.pid = pg_backend_pid();
    RETURN NOT (p_author = session_user::text AND logged_in IS NOT DISTINCT FROM session_user::text);
END;
$$;
REVOKE ALL ON FUNCTION plan_guard._needs_a_definer_frame(text) FROM PUBLIC;

-- Every EXPLAIN of stored text goes through here: read-only, as p_role when given -- in a frame
-- that role owns (1.1.9) -- and rolled back.
CREATE OR REPLACE FUNCTION plan_guard._explain_lines(
    p_search_path text, p_options text, p_query_sql text,
    p_compute_query_id boolean DEFAULT false, p_role text DEFAULT NULL)
RETURNS text[]
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_lines   text[] := '{}';
    v_line    text;
    v_locks   text[];
    v_explain text := 'EXPLAIN (' || p_options || ') ' || p_query_sql;
    v_frame   text;
    v_hand    text;
    -- plpgsql variables survive the rollback of the block that set them: the plan is
    -- read here, and the rollback throws away only what planning did.
    answered  boolean := false;
BEGIN
    IF p_role IS NOT NULL AND plan_guard._needs_a_definer_frame(p_role) THEN
        -- Built here, before the baseline's path applies: from then on an unqualified name in
        -- this function would resolve through the author's schemas (F-03).
        v_frame := format(
            'CREATE FUNCTION pg_temp.plan_guard_sealed_explain() RETURNS pg_catalog.text[] '
            'LANGUAGE plpgsql SECURITY DEFINER SET search_path FROM CURRENT AS %L',
            format($body$DECLARE
    l pg_catalog.text[] := '{}';
    x pg_catalog.text;
BEGIN
    FOR x IN EXECUTE %L LOOP
        l := pg_catalog.array_append(l, x);
    END LOOP;
    RETURN l;
END$body$, v_explain));
        IF p_role IS DISTINCT FROM current_user::text THEN
            v_hand := format('ALTER FUNCTION pg_temp.plan_guard_sealed_explain() OWNER TO %I', p_role);
        END IF;
    END IF;
    SELECT array_agg(classid || ':' || objid || ':' || objsubid || ':' || mode) INTO v_locks
      FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted;
    BEGIN
        IF p_compute_query_id THEN
            PERFORM set_config('compute_query_id', 'on', true);
        END IF;
        PERFORM set_config('search_path',
            coalesce(plan_guard._with_pg_temp_last(p_search_path), p_search_path), true);

        IF v_frame IS NOT NULL THEN
            EXECUTE v_frame;
            IF v_hand IS NOT NULL THEN
                EXECUTE v_hand;
            END IF;
            -- Read-only after the frame exists: creating it is the seal's own write.
            PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
            v_lines := pg_temp.plan_guard_sealed_explain();
        ELSE
            PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
            FOR v_line IN EXECUTE v_explain
            LOOP
                v_lines := pg_catalog.array_append(v_lines, v_line);
            END LOOP;
        END IF;

        answered := true;
        RAISE EXCEPTION 'undo whatever planning did';
    EXCEPTION WHEN OTHERS THEN
        PERFORM plan_guard._release_advisory_locks(v_locks);
        IF NOT answered THEN
            IF SQLSTATE = '42501' AND SQLERRM LIKE 'cannot set parameter %' THEN
                RAISE EXCEPTION 'the baseline tried to change the role it is planned as, and it is planned as %, the role that wrote it: %', p_role, SQLERRM
                    USING ERRCODE = '42501';
            END IF;
            RAISE;
        END IF;
    END;
    RETURN v_lines;
END;
$$;
