# pg_plan_guard — PGXS build
#
# SQL-only extension: there is no C module, so there is nothing to compile.
# Install with:
#     make install            (uses pg_config from PATH)
#     make install PG_CONFIG=/path/to/pg_config
#
# Run the regression tests against a running server:
#     make installcheck

EXTENSION   = pg_plan_guard
DATA        = pg_plan_guard--1.0.sql
PGFILEDESC  = "pg_plan_guard - detect query plan drift against known-good baselines"

REGRESS          = basic
REGRESS_OPTS     = --inputdir=test --outputdir=test

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
