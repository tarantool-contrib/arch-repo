#!/usr/bin/env bash
# Run a script of this repository in an Arch Linux container, for a host
# that is not Arch Linux: the repository is mounted at the same path, the
# working directory is the current one.
#
# Usage: scripts/docker.sh [--root] SCRIPT [ARG...]
#
#   scripts/docker.sh scripts/srcinfo.sh packages/tarantool-3.9
#   scripts/docker.sh --root scripts/makepkg.sh packages/tarantool-3.9 out
#
# The script runs as the user of the host, or as root with --root (what
# scripts/makepkg.sh needs; what it puts into OUT is then given to the user
# of the host). $ARCH_IMAGE is the image, default archlinux:base-devel;
# $PACMAN_CACHE, when set, is a directory of the host to keep the packages
# pacman downloads in.
set -euo pipefail

root=false
if [ "${1:-}" = --root ]; then
	root=true
	shift
fi
[ $# -ge 1 ] || {
	echo "usage: docker.sh [--root] SCRIPT [ARG...]" >&2
	exit 1
}

repo=$(cd "$(dirname "$0")/.." && pwd)
args=(--rm -i -v "$repo:$repo" -w "$PWD")
# What the scripts read of the environment, when it is set.
for name in PACKAGER GH_TOKEN GH_REPO SITE_URL SIGNING_KEY GITHUB_ACTIONS GITHUB_SHA \
	GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_REPOSITORY; do
	args+=(-e "$name")
done
if $root; then
	args+=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")
else
	args+=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
fi
if [ -n "${PACMAN_CACHE:-}" ]; then
	mkdir -p "$PACMAN_CACHE"
	args+=(-v "$(realpath "$PACMAN_CACHE"):/var/cache/pacman/pkg")
fi
# The current directory and the directories of the arguments that are
# paths, at the same paths, so that the script finds them and what it
# writes there stays.
mounts=("$PWD")
for arg in "${@:2}"; do
	[[ $arg == */* ]] || [ -e "$arg" ] || continue
	path=$(realpath -m -- "$arg")
	[ -d "$path" ] || path=$(dirname "$path")
	[ -d "$path" ] && mounts+=("$path")
done
mounted=("$repo")
for path in "${mounts[@]}"; do
	[ "$path" != / ] || continue
	for prefix in "${mounted[@]}"; do
		[[ $path/ == "$prefix"/* ]] && continue 2
	done
	args+=(-v "$path:$path")
	mounted+=("$path")
done

exec docker run "${args[@]}" "${ARCH_IMAGE:-archlinux:base-devel}" "$@"
