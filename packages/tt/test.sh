#!/usr/bin/env bash
# The test of the installed package, run by scripts/install-test.sh as an
# unprivileged user in an empty directory, with $VERSION its pkgver.
set -euo pipefail

tt version
[[ $(tt version --short) == "$VERSION" ]]
tt help > /dev/null

# An environment of tt, and the system one the package makes.
tt init
test -f tt.yaml
getent passwd tarantool
test -f /etc/tarantool/tt.yaml
