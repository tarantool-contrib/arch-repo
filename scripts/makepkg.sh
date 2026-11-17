#!/usr/bin/env bash
# Build the package of the directory DIR with makepkg and put the package
# files it makes into OUT.
#
# Usage: scripts/makepkg.sh DIR OUT
#
# It runs as root on Arch Linux: in the archlinux:base-devel container of a
# build job, or under scripts/docker.sh --root. It upgrades the system,
# installs the depends, makedepends and checkdepends of DIR/.SRCINFO, and
# runs makepkg as the user builder on a copy of DIR. The .SRCINFO has to be
# what makepkg --printsrcinfo prints for the PKGBUILD, and the files made
# those makepkg --packagelist names.
#
# $PACKAGER, when set, is the packager the packages name. $HOST_UID and
# $HOST_GID, when set, are made the owner of what is put into OUT.
set -euo pipefail

die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

[ $# = 2 ] || die "usage: makepkg.sh DIR OUT"
dir=$(realpath "$1")
out=$(realpath -m "$2")
[ -f "$dir/PKGBUILD" ] || die "$dir has no PKGBUILD"
[ -f "$dir/.SRCINFO" ] || die "$dir has no .SRCINFO"
[ "$(id -u)" = 0 ] || die "makepkg.sh runs as root"

pacman -Syu --noconfirm --needed base-devel >&2

id builder > /dev/null 2>&1 || useradd --create-home --user-group builder
work=$(mktemp -d /var/tmp/makepkg.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp -r "$dir" "$work/pkg"
mkdir -p "$work/out" "$work/src" "$work/build"
chown -R builder:builder "$work"

# as_builder COMMAND... runs COMMAND as builder in the copy of DIR.
as_builder() {
	runuser -u builder -- env -C "$work/pkg" \
		PKGDEST="$work/out" SRCDEST="$work/src" BUILDDIR="$work/build" \
		MAKEFLAGS="-j$(nproc)" ${PACKAGER:+PACKAGER="$PACKAGER"} "$@"
}

as_builder makepkg --printsrcinfo > "$work/srcinfo"
diff -u "$dir/.SRCINFO" "$work/srcinfo" >&2 ||
	die "$dir/.SRCINFO is not what makepkg --printsrcinfo prints: run scripts/srcinfo.sh"

# The dependencies, installed here so that makepkg needs no sudo. Versions
# are left to pacman -Syu: a rolling release has one of each.
mapfile -t deps < <(sed -nE 's/^\t(make|check)?depends = //p' "$work/srcinfo" |
	sed -E 's/[<>=].*//' | sort -u)
if [ ${#deps[@]} -gt 0 ]; then
	pacman -S --noconfirm --needed --asdeps "${deps[@]}" >&2
fi

as_builder makepkg --noconfirm --cleanbuild >&2

# Exactly the packages of the PKGBUILD.
want=$(as_builder makepkg --packagelist | xargs -rn1 basename | sort)
have=$(find "$work/out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[ "$have" = "$want" ] ||
	die "makepkg made"$'\n'"$have"$'\n'"rather than"$'\n'"$want"

mkdir -p "$out"
while read -r file; do
	cp "$work/out/$file" "$out/"
	pacman -Qip "$out/$file" >&2
done <<<"$want"
if [ -n "${HOST_UID:-}" ]; then
	chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out"
fi
printf '%s\n' "$want"
