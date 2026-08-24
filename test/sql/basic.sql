-- pg_plan_guard regression tests
--
-- The point of these tests is not that the functions run: it is that drift is
-- actually DETECTED, and that the failure modes behave. A plan guard that
-- reports "ok" no matter what is worse than none, because it is trusted.

CREATE EXTENSION pg_plan_guard;

CREATE SCHEMA guard_test;
CREATE TABLE guard_test.t (id int, val text);
INSERT INTO guard_test.t SELECT g, 'v' || g FROM generate_series(1, 20000) g;
CREATE INDEX t_id_idx ON guard_test.t (id);
ANALYZE guard_test.t;

-- Capture the good plan (index scan on a selective lookup).
SELECT plan_guard.capture(
    'lookup',
    'SELECT val FROM guard_test.t WHERE id = 42',
    'point lookup that must use the index') LIKE '%INDEX_SCAN%' AS captured_index_scan;

-- Nothing changed: must be ok.
SELECT name, state FROM plan_guard.verify('lookup');

-- Take the index away from the planner. The query still returns the same row —
-- this is the silent regression the extension exists to catch.
SET enable_indexscan = off;
SET enable_bitmapscan = off;

SELECT name, state FROM plan_guard.verify('lookup');

-- The drift must be recorded with both sides of the change.
SELECT baseline_name,
       expected_advice LIKE '%INDEX_SCAN%' AS expected_was_index,
       actual_advice   LIKE '%SEQ_SCAN%'   AS actual_is_seqscan
FROM plan_guard.drift_log WHERE baseline_name = 'lookup';

-- Re-verifying while still drifted must NOT append another log row: a baseline
-- that has been broken for a week should not produce one row per cron run.
SELECT name, state FROM plan_guard.verify('lookup');
SELECT count(*) AS drift_rows FROM plan_guard.drift_log WHERE baseline_name = 'lookup';

-- Restore the planner: state must go back to ok on its own.
RESET enable_indexscan;
RESET enable_bitmapscan;
SELECT name, state FROM plan_guard.verify('lookup');

-- The view a monitor would poll.
SELECT name, state, drift_events FROM plan_guard.status WHERE name = 'lookup';

-- A baseline whose query no longer plans must be reported as 'error' WITHOUT
-- aborting the run: one broken baseline must not stop the others from being
-- checked. A monitor that dies on the first problem stops working exactly when
-- something is wrong.
SELECT plan_guard.capture('broken', 'SELECT * FROM guard_test.t WHERE id = 1') IS NOT NULL AS ok;
DROP TABLE guard_test.t CASCADE;
SELECT name, state FROM plan_guard.verify() ORDER BY name;

-- Capturing a query that cannot be planned must fail loudly, not store garbage.
SELECT plan_guard.capture('nope', 'SELECT * FROM guard_test.does_not_exist');

DROP SCHEMA guard_test CASCADE;
DROP EXTENSION pg_plan_guard CASCADE;
