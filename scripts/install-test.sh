#!/usr/bin/env bash
# Install the packages of PKGBASE on a clean Arch Linux and test them: the
# package files FILE..., or, with none, the packages of PKGBASE the
# repository serves at $(site_url). Every program they install has to find
# its libraries, and packages/PKGBASE/test.sh, if there is one, has to
# pass: it runs as an unprivileged user in an empty directory, with
# $VERSION the pkgver installed.
#
# Usage: scripts/install-test.sh PKGBASE [FILE...]
#
# It runs as root on a throwaway Arch Linux, which it changes: under
# scripts/docker.sh --root.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: install-test.sh PKGBASE [FILE...]"
pkgbase=$1
shift
[ "$(id -u)" = 0 ] && [ -f /etc/arch-release ] || die "install-test.sh runs as root on Arch Linux"
mapfile -t names < <(pkgnames "$pkgbase")

if [ $# -gt 0 ]; then
	pacman -Syu --noconfirm >&2
	pacman -U --noconfirm "$@" >&2
else
	add_repo
	pacman -S --noconfirm "${names[@]/#/$repo_name/}" >&2
fi

failed=0
for name in "${names[@]}"; do
	pacman -Qi "$name"
	# Every program and library finds the libraries it needs.
	while read -r file; do
		[ -f "$file" ] && [ ! -L "$file" ] || continue
		[ "$(head -c 4 "$file" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] || continue
		if missing=$(ldd "$file" 2>&1 | grep 'not found'); then
			error "$name: $file: $missing"
			failed=1
		fi
	done < <(pacman -Qlq "$name")
done
[ "$failed" = 0 ] || die "$pkgbase: libraries are missing"

test=$root/packages/$pkgbase/test.sh
if [ -f "$test" ]; then
	id tester > /dev/null 2>&1 || useradd --create-home tester
	dir=$(runuser -u tester -- mktemp -d)
	# A copy: the checkout may be in a directory the tester cannot enter.
	install -m 644 -o tester "$test" "$dir/.test.sh"
	version=$(pacman -Q "${names[0]}" | cut -d' ' -f2)
	version=${version%-*}
	say "running $test as tester in $dir"
	runuser -u tester -- env -C "$dir" VERSION="$version" bash .test.sh ||
		die "$pkgbase: packages/$pkgbase/test.sh failed"
fi
say "$pkgbase is good"
