# pg_plan_guard

**Detect when a query plan drifts away from the plan you approved.**

PostgreSQL 19 added [`pg_plan_advice`](https://www.postgresql.org/docs/19/pgplanadvice.html)
(generate advice for a plan, then force it) and
[`pg_stash_advice`](https://www.postgresql.org/docs/19/pgstashadvice.html) (store
advice per `query_id` and apply it automatically). Both are deliberate, manual
acts: you decide a plan is good, and you pin it.

Neither of them **watches**. There is no way to ask:

> Is the plan for this query still the plan I approved?

`pg_plan_guard` answers that question.

## Why it matters

A plan regression usually does not fail. The query still returns the same rows —
it just stops using the index and starts scanning. Nothing errors, nothing logs,
nothing alerts.

The case this was built for: a vector similarity search backed by a DiskANN
index over ~40,000 embeddings. If the planner stops choosing that index, the
results are **identical** and still correctly ordered. It is simply a sequential
scan now. Correct, silent, and slow.

That class of failure is the expensive one precisely because it does not
announce itself. You find out weeks later from a latency graph, if at all.

## Usage

```sql
CREATE EXTENSION pg_plan_guard;

-- Approve today's plan for a critical query.
SELECT plan_guard.capture(
    'semantic_search',
    'SELECT id FROM docs ORDER BY embedding <=> ''[...]'' LIMIT 10',
    'must use the diskann index');

-- Later, on a schedule: has anything drifted?
SELECT * FROM plan_guard.verify();

--       name       |  state  |        expected_advice        |    actual_advice
-- -----------------+---------+-------------------------------+---------------------
--  semantic_search | drifted | INDEX_SCAN(docs docs_emb_idx) | SEQ_SCAN(docs) ...
```

Run it from `pg_cron`, or from whatever already runs your checks:

```sql
SELECT cron.schedule('plan-guard', '37 */6 * * *',
    $$SELECT * FROM plan_guard.verify()$$);
```

And point your monitoring at one view:

```sql
SELECT * FROM plan_guard.status WHERE state <> 'ok';
```

## API

| Function | Purpose |
|---|---|
| `plan_guard.capture(name, query_sql [, description])` | Approve the current plan as the baseline |
| `plan_guard.verify([name])` | Re-plan every baseline and report drift |
| `plan_guard.sync_stash(stash_name)` | Push approved advice into a `pg_stash_advice` stash |
| `plan_guard.advice_for(query_sql)` | Plan advice for an arbitrary query |
| `plan_guard.query_id_for(query_sql)` | `query_id` of a query, for stash operations |

| Relation | Contents |
|---|---|
| `plan_guard.baselines` | The approved plan for each query |
| `plan_guard.drift_log` | Append-only history of every detected drift |
| `plan_guard.status` | Current state, worst first — the view a monitor polls |

## Design decisions

These are the choices that make it usable rather than annoying, and the reasons
behind them:

**Advice is compared, not `EXPLAIN` output.** `EXPLAIN` text changes with row
estimates and costs even when the plan shape is identical. Comparing it would
make baselines drift constantly and train everyone to ignore the alerts. Advice
describes the *shape* — which scan on which relation, which join order, which
method — so it changes only when the planner's decision changes.

**Capture is explicit, never automatic.** A baseline that captured itself would
happily bless whatever plan happened to be in effect, including the regression
you are hunting.

**Drift is logged once per transition, not once per check.** A baseline that has
been drifting for a week should not produce a row per cron run.

**A broken baseline does not abort the run.** If a query no longer plans (table
dropped, column renamed) it is reported as `error` and the remaining baselines
are still checked. A monitor that dies on the first problem stops working
exactly when something is wrong.

**The table is the source of truth, not shared memory.** `pg_stash_advice`
persists across restarts, but if persistence ever fails or the cluster is
recreated, the pinning disappears silently — queries keep working, just slowly.
That is the same failure mode this extension exists to catch, so the stash is
treated as a cache that can always be rebuilt from `plan_guard.baselines` via
`sync_stash()`.

## Requirements

- PostgreSQL 19 or later, with `pg_plan_advice` available.
- `sync_stash()` additionally requires `pg_stash_advice`, which needs **two**
  things to actually apply advice — and if either is missing, nothing is applied
  and nothing warns you:
  1. `shared_preload_libraries` includes `pg_plan_advice` and `pg_stash_advice`
  2. `pg_stash_advice.stash_name` is set (the default is empty)

  Diagnose with:
  ```sql
  SELECT name, setting FROM pg_settings WHERE name LIKE 'pg_stash%';
  ```

Baselines are captured with `EXPLAIN (PLAN_ADVICE)`, which **does not execute**
the query. Verification is therefore cheap and safe to schedule.

## Install

From [PGXN](https://pgxn.org/dist/pg_plan_guard/):

```sh
pgxn install pg_plan_guard
psql -c 'CREATE EXTENSION pg_plan_guard'
```

From source:

```sh
make install PG_CONFIG=/path/to/pg_config
psql -c 'CREATE EXTENSION pg_plan_guard'
```

Run the tests against a live server:

```sh
make installcheck PG_CONFIG=/path/to/pg_config
```

## Limitations

- Queries are stored as text and re-planned as written. Parameterized queries
  must be captured in an executable form (literal values), since `EXPLAIN`
  needs a complete statement.
- Drift detection is only as good as the baseline: capturing a bad plan pins a
  bad plan. Review what `capture()` returns.
- `capture()` and `verify()` run `EXPLAIN` on stored SQL, so execute rights are
  not granted to `PUBLIC`.

## License

PostgreSQL License. See [LICENSE](LICENSE).
