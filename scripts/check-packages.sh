#!/usr/bin/env bash
# Check the packages of packages/, and print, as JSON, the builds a pull
# request needs: those of the packages changed since BASE, a git commit of
# this repository, or of every package when what builds and tests them
# changed.
#
# Usage: scripts/check-packages.sh [BASE]
#
#   [{"pkgbase": "tt", "version": "2.15.2-1", "arch": "x86_64",
#     "runner": "ubuntu-24.04"}]
#
# Each package:
#
#   - is the pkgbase of its directory, with a .SRCINFO that is what
#     makepkg --printsrcinfo prints for its PKGBUILD;
#   - has a version a tag and an asset name can hold: no epoch, a pkgver
#     of letters, digits, dots and underscores;
#   - is built for archs of lib.sh, and makes package names no other
#     package makes;
#   - when changed since BASE, has a version that is published by no
#     release (a published release never changes: raise the pkgrel) and
#     is newer than every published one (pacman upgrades to no older one).
#
# It runs as root on Arch Linux, for makepkg and vercmp: under
# scripts/docker.sh --root. Reading the releases needs $GH_REPO.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -le 1 ] || die "usage: check-packages.sh [BASE]"
base=${1:-}
[ "$(id -u)" = 0 ] && [ -f /etc/arch-release ] || die "check-packages.sh runs as root on Arch Linux"
pacman -Syu --noconfirm --needed github-cli jq git >&2
git config --global --add safe.directory "$root"

problems=()
problem() {
	problems+=("$*")
}

id checker > /dev/null 2>&1 || useradd --create-home checker
# makepkg runs on a copy the checker owns: the checkout is another user's,
# perhaps in a directory the checker cannot enter, and makepkg wants the
# directory of the PKGBUILD writable even to print the .SRCINFO.
scratch=$(runuser -u checker -- mktemp -d)
trap 'rm -rf "$scratch"' EXIT
published=$(releases | jq -r '.[].tag')

declare -A owner
for pkgbase in $(pkgbases); do
	dir=$root/packages/$pkgbase
	cp -r "$dir" "$scratch/$pkgbase"
	chown -R checker: "$scratch/$pkgbase"
	if ! new=$(runuser -u checker -- env -C "$scratch/$pkgbase" makepkg --printsrcinfo 2>&1); then
		problem "$pkgbase: makepkg --printsrcinfo fails: $new"
		continue
	fi
	if [ "$new" != "$(cat "$dir/.SRCINFO")" ]; then
		problem "$pkgbase: .SRCINFO is not that of the PKGBUILD: run scripts/srcinfo.sh packages/$pkgbase"
		continue
	fi
	[ "$(sed -n 's/^pkgbase = //p' "$dir/.SRCINFO")" = "$pkgbase" ] ||
		problem "$pkgbase: the pkgbase is not the name of the directory"
	[ -z "$(field "$pkgbase" epoch)" ] || problem "$pkgbase: an epoch, which a tag cannot hold"
	pkgver=$(field "$pkgbase" pkgver)
	[[ $pkgver =~ ^[A-Za-z0-9._]+$ ]] ||
		problem "$pkgbase: pkgver $pkgver is not of letters, digits, dots and underscores"
	for arch in $(archs "$pkgbase"); do
		[ "$arch" = any ] || [[ " ${known_archs[*]} " == *" $arch "* ]] ||
			problem "$pkgbase: no runner builds for $arch (lib.sh known_archs)"
	done
	if grep -qE $'^\tarch = ' <(sed -n '/^pkgname = /,$p' "$dir/.SRCINFO"); then
		problem "$pkgbase: a package of it has archs of its own"
	fi
	for name in $(pkgnames "$pkgbase"); do
		if [ -n "${owner[$name]:-}" ]; then
			problem "$pkgbase: $name is made by ${owner[$name]} too"
		fi
		owner[$name]=$pkgbase
	done
done

# What changed since BASE.
changed=()
everything=false
if [ -n "$base" ]; then
	mapfile -t paths < <(git -C "$root" diff --name-only "$base" HEAD --)
	for path in "${paths[@]}"; do
		case $path in
		packages/*/*)
			pkgbase=${path#packages/}
			pkgbase=${pkgbase%%/*}
			[ -f "$root/packages/$pkgbase/PKGBUILD" ] || continue
			[[ " ${changed[*]} " == *" $pkgbase "* ]] || changed+=("$pkgbase")
			;;
		scripts/makepkg.sh | scripts/install-test.sh | scripts/lib.sh | .github/workflows/check.yml)
			everything=true
			;;
		esac
	done
fi

for pkgbase in "${changed[@]}"; do
	version=$(version "$pkgbase")
	tag=$(tag "$pkgbase" "$version")
	if grep -qxF "$tag" <<<"$published"; then
		problem "$pkgbase: $tag is published already; a published release never changes: raise the pkgrel"
		continue
	fi
	while read -r other; do
		[ -n "$other" ] || continue
		old=${other#"$pkgbase"-}
		[[ $old =~ ^[^-]+-[0-9]+(\.[0-9]+)?$ ]] || continue
		[ "$(vercmp "$version" "$old")" -gt 0 ] ||
			problem "$pkgbase: $version is not newer than $old, which is published: pacman would not upgrade to it"
	done < <(grep "^$pkgbase-" <<<"$published" || true)
done

if [ ${#problems[@]} -gt 0 ]; then
	for item in "${problems[@]}"; do
		error "$item"
	done
	die "${#problems[@]} problems"
fi

if $everything; then
	mapfile -t changed < <(pkgbases)
fi
for pkgbase in "${changed[@]}"; do
	for arch in $(archs "$pkgbase"); do
		jq -nc --arg p "$pkgbase" --arg v "$(version "$pkgbase")" --arg a "$arch" \
			--arg r "$(runner "$arch")" '{pkgbase: $p, version: $v, arch: $a, runner: $r}'
	done
done | jq -sc .
say "the packages are good; to build: ${changed[*]:-none}"
