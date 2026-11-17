#!/usr/bin/env bash
# Change a package of packages/ to a new build, and print its pkgbase:
#
#   scripts/bump.sh PKGBASE VERSION     the upstream release VERSION:
#                                       pkgver VERSION, pkgrel 1, the
#                                       sha256 of the upstream archive,
#                                       the first source, and _commit,
#                                       if it has one, the commit of the
#                                       tag upstream
#   scripts/bump.sh --rebuild PKGBASE   the same version built anew: the
#                                       pkgrel raised by one
#   scripts/bump.sh --series SERIES VERSION
#                                       a new series of Tarantool,
#                                       tarantool-SERIES at VERSION, made
#                                       from the newest series of packages/
#
# It edits the PKGBUILD alone: write the .SRCINFO with scripts/srcinfo.sh
# after it.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# set_var FILE NAME VALUE sets the variable NAME of the PKGBUILD FILE.
set_var() {
	grep -q "^$2=" "$1" || die "$1 has no $2="
	sed -i "s|^$2=.*|$2=$3|" "$1"
}

# set_version PKGBASE VERSION makes PKGBASE upstream VERSION, pkgrel 1.
set_version() {
	local pkgbuild=$root/packages/$1/PKGBUILD old url sum
	old=$(field "$1" pkgver)
	[[ $2 =~ ^[A-Za-z0-9._]+$ ]] || die "$2 is not a pkgver"
	# The upstream archive is the first source, its URL of the old pkgver.
	url=$(field "$1" source | head -n 1)
	url=${url#*::}
	[[ $url == *"$old"* ]] || die "the first source of $1, $url, has no $old in it"
	url=${url//"$old"/"$2"}
	say "$1: $url"
	sum=$(curl -fsSL --retry 3 --retry-all-errors "$url" | sha256sum | cut -d' ' -f1)
	set_var "$pkgbuild" pkgver "$2"
	set_var "$pkgbuild" pkgrel 1
	grep -qE "^sha256sums=\('[0-9a-f]{64}'" "$pkgbuild" ||
		die "$pkgbuild: sha256sums=( does not begin with the sum of the archive"
	sed -i -E "0,/^sha256sums=\('[0-9a-f]{64}'/s//sha256sums=('$sum'/" "$pkgbuild"
	# The commit of the upstream tag, vVERSION or VERSION, for a PKGBUILD
	# that names it.
	if grep -q '^_commit=' "$pkgbuild"; then
		local repo commit
		repo=$(field "$1" url | sed -n 's|^https://github.com/\([^/]*/[^/]*\)$|\1|p')
		[ -n "$repo" ] || die "$1: the url is of no repository of GitHub, for _commit"
		commit=$(gh api "repos/$repo/commits/v$2" --jq .sha 2> /dev/null ||
			gh api "repos/$repo/commits/$2" --jq .sha) || die "$1: $repo has no tag v$2 or $2"
		set_var "$pkgbuild" _commit "$commit"
	fi
}

case ${1:-} in
--rebuild)
	[ $# = 2 ] || die "usage: bump.sh --rebuild PKGBASE"
	pkgbase=$2
	pkgrel=$(field "$pkgbase" pkgrel)
	[[ $pkgrel =~ ^[0-9]+$ ]] || die "$pkgbase: pkgrel $pkgrel is not a number"
	set_var "$root/packages/$pkgbase/PKGBUILD" pkgrel $((pkgrel + 1))
	;;
--series)
	[ $# = 3 ] || die "usage: bump.sh --series SERIES VERSION"
	series=$2
	[[ $series =~ ^[0-9]+\.[0-9]+$ ]] || die "$series is not a series, X.Y"
	[[ $3 == "$series".* ]] || die "$3 is not of the series $series"
	pkgbase=tarantool-$series
	[ ! -e "$root/packages/$pkgbase" ] || die "packages/$pkgbase is there already"
	from=$(pkgbases | sed -n 's/^tarantool-\([0-9]*\.[0-9]*\)$/\1/p' | sort -V | tail -n 1)
	[ -n "$from" ] || die "no series of Tarantool to make $pkgbase from"
	cp -r "$root/packages/tarantool-$from" "$root/packages/$pkgbase"
	set_var "$root/packages/$pkgbase/PKGBUILD" _series "$series"
	# The .SRCINFO is still that of the template, which set_version reads.
	set_version "$pkgbase" "$3"
	say "$pkgbase: made from tarantool-$from"
	;;
-*)
	die "usage: bump.sh PKGBASE VERSION | --rebuild PKGBASE | --series SERIES VERSION"
	;;
*)
	[ $# = 2 ] || die "usage: bump.sh PKGBASE VERSION"
	pkgbase=$1
	set_version "$pkgbase" "$2"
	;;
esac
printf '%s\n' "$pkgbase"
