#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/orbit-sqlserver-java.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

javac --release 11 -Xlint:all -d "$temporary/classes" \
  "$root/tests/java/net/sourceforge/jtds/jdbc/Driver.java" \
  "$root/tests/java/OrbitSqlServerTest.java"
javac --release 11 -Xlint:all -d "$temporary/helper-classes" \
  "$root/cmd/orbit-sqlserver/OrbitSqlServer.java"
jar cfm "$temporary/jtds-1.3.1.jar" "$root/tests/java/MANIFEST.MF" \
  -C "$temporary/classes" net/sourceforge/jtds

java -cp "$temporary/classes" OrbitSqlServerTest \
  "$root/cmd/orbit-sqlserver/OrbitSqlServer.java" "$temporary/jtds-1.3.1.jar"
