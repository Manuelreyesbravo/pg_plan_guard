#!/bin/bash
# Checks that upgrading an existing installation gives the same extension as
# installing the current version from scratch, from every earlier version
# the server can install -- after ci/install_releases.sh, every release
# published on PGXN.  Fails if there is none, rather than pass on nothing.
#
#   ci/upgrade_check.sh [FROM_VERSION...]     (default: all of them)
#
# For each FROM_VERSION, two databases on the running server:
#   fresh     CREATE EXTENSION at the default version
#   upgraded  CREATE EXTENSION ... VERSION FROM_VERSION, then
#             ci/upgrade_before.sql if present (data or state the upgrade must
#             carry over), then ALTER EXTENSION ... UPDATE
# Every member of the extension is compared by its identity, definition and
# comment.  An upgrade script that forgets to change a function passes
# "ALTER EXTENSION UPDATE ran without error" and fails here.  Then
# ci/upgrade_after.sql, if present, runs on the upgraded database and must
# not raise an error.
#
# Connection settings come from the usual PG* environment variables.
set -eu
cd "$(dirname "$0")/.."
EXT=$(sed -n "s/^EXTENSION *= *//p" Makefile)
DEFAULT=$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" $EXT.control)
q() { psql -X -qAt -v ON_ERROR_STOP=1 "$@"; }
if [ $# -gt 0 ]; then
  FROMS="$*"
else
  # Every version the server can install, which after ci/install_releases.sh
  # includes every release published on PGXN.
  FROMS=$(q -d postgres -c "SELECT version FROM pg_available_extension_versions
                             WHERE name = '$EXT' AND version <> '$DEFAULT'" | sort -V)
fi
if [ -z "$FROMS" ]; then
  echo "FAIL: no earlier version of $EXT to upgrade from; nothing would be tested"
  exit 1
fi

# One line per extension member: its identity, its definition where it has
# one, and its comment.  Sorted, so the order of creation does not matter.
members="
SELECT pg_describe_object(d.classid, d.objid, 0) || ' | ' ||
       coalesce(CASE d.classid
                  WHEN 'pg_proc'::regclass THEN pg_get_functiondef(d.objid)
                  WHEN 'pg_class'::regclass THEN
                    coalesce(pg_get_viewdef(d.objid),
                             -- by name, not position: ALTER TABLE ADD COLUMN in an
                             -- upgrade script always appends, so an upgraded table
                             -- can only match a fresh one in its set of columns
                             (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attname)
                                FROM pg_attribute a WHERE a.attrelid = d.objid AND a.attnum > 0 AND NOT a.attisdropped))
                END, '') || ' | ' ||
       coalesce(obj_description(d.objid, (SELECT relname FROM pg_class WHERE oid = d.classid)), '')
  FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
 WHERE d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e' AND e.extname = '$EXT'
 ORDER BY 1"
count="SELECT count(*) FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e' AND e.extname = '$EXT'"

q -d postgres -c "DROP DATABASE IF EXISTS ci_fresh" -c "CREATE DATABASE ci_fresh"
q -d ci_fresh -c "CREATE EXTENSION $EXT CASCADE"
q -d ci_fresh -c "$members" > /tmp/fresh.members
echo "$EXT $DEFAULT, fresh install: $(q -d ci_fresh -c "$count") members"

failed=0
for FROM in $FROMS; do
  q -d postgres -c "DROP DATABASE IF EXISTS ci_upgraded" -c "CREATE DATABASE ci_upgraded"
  q -d ci_upgraded -c "CREATE EXTENSION $EXT VERSION '$FROM' CASCADE"
  [ -f ci/upgrade_before.sql ] && q -d ci_upgraded -f ci/upgrade_before.sql > /dev/null
  q -d ci_upgraded -c "ALTER EXTENSION $EXT UPDATE"
  v=$(q -d ci_upgraded -c "SELECT extversion FROM pg_extension WHERE extname = '$EXT'")
  q -d ci_upgraded -c "$members" > /tmp/upgraded.members
  # Objects an upgrade is meant to leave behind (say, a table keeping data
  # from an old version for the user to migrate) are listed in
  # ci/upgrade_allow.txt, one extended regex per line, matched against the
  # start of the member line.  Documented there, not silenced here.
  allowed=0
  if [ -f ci/upgrade_allow.txt ]; then
    grep -v -E '^(#|$)' ci/upgrade_allow.txt | sed 's/^/^/' > /tmp/allow.re
    allowed=$(grep -c -E -f /tmp/allow.re /tmp/upgraded.members || true)
    grep -v -E -f /tmp/allow.re /tmp/upgraded.members > /tmp/upgraded.filtered || true
    mv /tmp/upgraded.filtered /tmp/upgraded.members
  fi
  if [ "$v" != "$DEFAULT" ]; then
    echo "from $FROM: FAIL, ended at $v instead of $DEFAULT"; failed=1
  elif ! diff -u /tmp/fresh.members /tmp/upgraded.members; then
    echo "from $FROM: FAIL, the upgraded extension differs from a fresh install"; failed=1
  elif [ -f ci/upgrade_after.sql ] && ! q -d ci_upgraded -f ci/upgrade_after.sql; then
    echo "from $FROM: FAIL, ci/upgrade_after.sql"; failed=1
  else
    n=$(q -d ci_upgraded -c "$count")
    echo "from $FROM: OK, identical ($n members$([ "$allowed" -gt 0 ] && echo ", $allowed of them expected only after an upgrade, see ci/upgrade_allow.txt"))"
  fi
done
[ $failed = 0 ] && echo "OK" || { echo "FAIL"; exit 1; }
