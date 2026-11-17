#!/usr/bin/env bash
# Print the packages the repository serves that need a rebuild: those with
# a dependency that the repositories of Arch Linux (and this one) no
# longer satisfy, as when a library they link to moved to another soname.
# A line a package: PKGBASE DEPENDENCY...
#
# Usage: scripts/rebuilds.sh
#
# It runs as root on a throwaway Arch Linux, which it changes: under
# scripts/docker.sh --root.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# = 0 ] || die "usage: rebuilds.sh"
[ "$(id -u)" = 0 ] && [ -f /etc/arch-release ] || die "rebuilds.sh runs as root on Arch Linux"

add_repo

db=/var/lib/pacman/sync/$repo_name.db
[ -f "$db" ] || die "no database of $repo_name at $(site_url)"

# The pkgbase and the dependencies of each package of the database: its
# desc files, of sections %NAME% and their values, a line each.
entries=$(tar -xzOf "$db" --wildcards '*/desc' | awk '
	/^%.*%$/ { section = $0; next }
	/^$/ { section = ""; next }
	section == "%NAME%" { if (name != "") print base, deps; name = $0; base = ""; deps = "" }
	section == "%BASE%" { base = $0 }
	section == "%DEPENDS%" { deps = deps " " $0 }
	END { if (name != "") print base, deps }
')

while read -r base deps; do
	[ -n "$base" ] || continue
	missing=()
	for dep in $deps; do
		pacman -Sp --print-format %n -- "$dep" > /dev/null 2>&1 || missing+=("$dep")
	done
	if [ ${#missing[@]} -gt 0 ]; then
		say "$base: nothing satisfies ${missing[*]}"
		printf '%s %s\n' "$base" "${missing[*]}"
	fi
done <<<"$entries" | sort -u -k1,1
