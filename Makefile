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
DATA         = pg_plan_guard--1.0.sql \
               pg_plan_guard--1.1.sql \
               pg_plan_guard--1.0--1.1.sql \
               pg_plan_guard--1.1--1.1.1.sql \
               pg_plan_guard--1.1.1--1.1.2.sql \
               pg_plan_guard--1.1.2--1.1.3.sql \
               pg_plan_guard--1.1.3--1.1.4.sql \
               pg_plan_guard--1.1.4--1.1.5.sql
PGFILEDESC  = "pg_plan_guard - detect query plan drift against known-good baselines"

REGRESS          = basic
REGRESS_OPTS     = --inputdir=test --outputdir=test

# Does verify() re-plan each baseline against the tables its author meant, with
# no temporary table of the verifying session standing in? Run against the
# throwaway cluster: test/cluster.sh init && test/cluster.sh start.
.PHONY: check-pgtemp
check-pgtemp:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/pg_temp.sh

# The findings of the external audit of 1.1.4, each against its control.
.PHONY: check-audit
check-audit:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/audit.sh

PG_CONFIG ?= pg_config
# Every suite in SUITES, in a throwaway cluster built from PG_CONFIG's binaries and
# stopped afterwards, whatever the suites answered. PostgreSQL 18 or later: the
# cluster loads this checkout through extension_control_path. CI runs exactly
# this on 18 and 19.
SUITES = check-pgtemp check-audit
.PHONY: check-suites
check-suites:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh init
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh start
	@st=0; for s in $(SUITES); do echo "== $$s"; \
	    $(MAKE) --no-print-directory $$s PG_CONFIG=$(PG_CONFIG) || st=1; done; \
	 PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh stop; exit $$st

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
