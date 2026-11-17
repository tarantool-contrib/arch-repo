#!/usr/bin/env bash
# Make the site GitHub Pages serves in OUT: the pacman repository of each
# arch, ARCH/, with the package files of what lib.sh served picks, copied
# out of the releases and checked against the sha256 GitHub holds them to,
# and the database repo-add makes of them; index.json, what is served;
# index.html, how to use it; keys/, the keys the repository signs with.
#
# Usage: scripts/site.sh OUT
#
# It needs repo-add and vercmp: on a host that is not Arch Linux, run it
# under scripts/docker.sh --root. As root on Arch Linux, it installs what
# else it needs.
#
# $SIGNING_KEY, when set, is the armored secret key, with no passphrase,
# the databases are signed with. With
# no key, a repository whose packages are signed is refused: pacman would
# then fail to check the databases.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# = 1 ] || die "usage: site.sh OUT"
out=$1
[ ! -e "$out" ] || [ -z "$(ls -A "$out")" ] || die "$out is not empty"

if [ "$(id -u)" = 0 ] && [ -f /etc/arch-release ]; then
	pacman -Syu --noconfirm --needed github-cli jq >&2
fi
command -v repo-add > /dev/null || die "no repo-add: run site.sh on Arch Linux"

work=$(mktemp -d)
# What is in OUT is given to the user of the host, even when it fails.
cleanup() {
	rm -rf "$work"
	if [ -n "${HOST_UID:-}" ] && [ -e "$out" ]; then
		chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out"
	fi
}
trap cleanup EXIT

releases > "$work/releases.json"
served "$(cat "$work/releases.json")" > "$work/served.json"

mkdir -p "$out"
signed=false
# The repository signs when keys/ has keys: every package it serves is
# signed by one of them then, and so are the databases. A signature by a
# key no longer in keys/ is refused like none: pacman, trusting the keys of
# keys/, would refuse the package.
bad=()
if signing; then
	keyring "$work/keyring"
fi
while read -r pkgbase tag current; do
	if [ "$current" != true ]; then
		notice "$pkgbase: $tag is served, as $(tag "$pkgbase") is not published"
	fi
	while read -r name arch url sha256 sig; do
		[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || die "$tag: $name has no sha256 digest"
		dirs=("$arch")
		if [ "$arch" = any ]; then
			dirs=("${known_archs[@]}")
		fi
		mkdir -p "$work/dl"
		curl -fsSL --retry 3 --retry-all-errors -o "$work/dl/$name" "$url"
		[ "$(sha256sum < "$work/dl/$name" | cut -d' ' -f1)" = "$sha256" ] ||
			die "$tag: $name is not what its sha256 says"
		if [ "$sig" != null ]; then
			curl -fsSL --retry 3 --retry-all-errors -o "$work/dl/$name.sig" "$sig"
			signed=true
			if signing && ! good_sig "$work/keyring" "$work/dl/$name" "$work/dl/$name.sig"; then
				bad+=("$name")
			fi
		fi
		for dir in "${dirs[@]}"; do
			mkdir -p "$out/$dir"
			cp "$work/dl/$name"* "$out/$dir/"
		done
		rm -f "$work/dl/$name"*
		say "serve $name"
	done < <(jq -r --arg t "$tag" '.[] | select(.tag == $t) | .files[]
		| "\(.name) \(.arch) \(.url) \(.sha256) \(.sig.url // "null")"' "$work/served.json")
done < <(jq -r '.[] | "\(.pkgbase) \(.tag) \(.current)"' "$work/served.json")

sign=()
if signing; then
	unsigned=$(jq -r '.[] | .files[] | select(.sig == null) | .name' "$work/served.json")
	[ -z "$unsigned" ] ||
		die "keys/ has keys, but these are not signed; rebuild them:"$'\n'"$unsigned"
	[ ${#bad[@]} = 0 ] ||
		die "these are not signed by a key of keys/; rebuild them:$(printf '\n%s' "${bad[@]}")"
	signing_key "$work/gnupg"
	sign=(--sign --key "$signing_fpr")
elif $signed; then
	die "packages are signed, but keys/ has no key to check them with"
fi

# The databases. GitHub Pages serves no symbolic links: the names pacman
# reads, REPO.db and REPO.files, are copies.
for dir in "$out"/*/; do
	dir=${dir%/}
	[ -d "$dir" ] || continue
	repo-add --quiet "${sign[@]}" "$dir/$repo_name.db.tar.gz" "$dir"/*.pkg.tar.zst
	for db in db files; do
		for suffix in "" .sig; do
			link=$dir/$repo_name.$db$suffix
			[ -L "$link" ] || continue
			rm "$link"
			cp "$dir/$repo_name.$db.tar.gz$suffix" "$link"
		done
	done
	rm -f "$dir"/*.old "$dir"/*.old.sig
done

if [ -d "$root/keys" ] && [ -n "$(ls "$root/keys")" ]; then
	cp -r "$root/keys" "$out/keys"
fi

# What is served.
url=$(site_url)
jq --arg name "$repo_name" --arg url "$url" '{
	repository: $name, url: $url,
	packages: [.[] | .pkgbase as $p | .tag as $t | .version as $v | .files[]
		| {pkgbase: $p, version: $v, arch, file: .name, sha256, size,
		   signed: (.sig != null), release: $t, url}]
}' "$work/served.json" > "$out/index.json"

"$root/scripts/page.sh" "$out/index.json" "$work/releases.json" > "$out/index.html"
say "the site is in $out: $(jq '.packages | length' "$out/index.json") package files"
