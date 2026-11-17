#!/usr/bin/env bash
# Write DIR/.SRCINFO for the PKGBUILD of each DIR, or, with --check, fail
# for each that is not what makepkg --printsrcinfo prints. With no DIR,
# every package of packages/.
#
# Usage: scripts/srcinfo.sh [--check] [DIR...]
#
# It needs makepkg: on a host that is not Arch Linux, run it under
# scripts/docker.sh.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

check=false
if [ "${1:-}" = --check ]; then
	check=true
	shift
fi
if [ $# = 0 ]; then
	for pkgbase in $(pkgbases); do
		set -- "$@" "$root/packages/$pkgbase"
	done
fi

# makepkg wants BUILDDIR, PKGDEST and SRCDEST writable even to print the
# .SRCINFO.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export BUILDDIR=$scratch PKGDEST=$scratch SRCDEST=$scratch

failed=0
for dir; do
	[ -f "$dir/PKGBUILD" ] || die "$dir has no PKGBUILD"
	new=$(cd "$dir" && makepkg --printsrcinfo)
	if $check; then
		if ! diff -u "$dir/.SRCINFO" - <<<"$new"; then
			say "$dir/.SRCINFO is not that of its PKGBUILD: run scripts/srcinfo.sh $dir"
			failed=1
		fi
	elif [ "$new" != "$(cat "$dir/.SRCINFO" 2> /dev/null)" ]; then
		printf '%s\n' "$new" > "$dir/.SRCINFO"
		say "wrote $dir/.SRCINFO"
	fi
done
exit "$failed"
