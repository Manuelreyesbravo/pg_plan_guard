#!/bin/bash
# Puts the SQL scripts of every release of this extension published on PGXN
# into the extension directory of the running PostgreSQL, oldest first.
# Runs before `make install`, so the scripts in the repository overwrite any
# of the same name and the control file is the current one.
#
# This is what makes ci/upgrade_check.sh test the upgrade from every version
# a user can actually have installed, including versions whose install
# script is no longer kept in the repository.  The releases are fetched from
# the PGXN API directly, whatever their release status (stable, testing).
set -eu
cd "$(dirname "$0")/.."
EXT=$(sed -n "s/^EXTENSION *= *//p" Makefile)
DIR=$(pg_config --sharedir)/extension
versions=$(curl -fsS "https://api.pgxn.org/dist/$EXT.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
vs = {r["version"] for status in d["releases"].values() for r in status}
print("\n".join(sorted(vs, key=lambda v: [int(x) for x in v.split(".")])))')
tmp=$(mktemp -d)
for v in $versions; do
  curl -fsS -o "$tmp/$v.zip" "https://api.pgxn.org/dist/$EXT/$v/$EXT-$v.zip"
  unzip -q -o "$tmp/$v.zip" -d "$tmp"
  cp "$tmp/$EXT-$v/$EXT"--*.sql "$DIR/"
  echo "release $v: $(cd "$tmp/$EXT-$v" && ls "$EXT"--*.sql | tr '\n' ' ')"
done
