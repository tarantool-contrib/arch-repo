#!/usr/bin/env bash
# Check the repository GitHub Pages serves at $(site_url) against the
# releases and packages/:
#
#   - it serves what lib.sh served picks of the published releases now, as
#     index.json lists it: else the site is stale;
#   - the database of each arch lists those files, with their sha256;
#   - each file it serves is, byte for byte, the asset of its release;
#   - with keys in keys/, the databases and the packages are signed by
#     them;
#   - every published release of a package is immutable and has the
#     digests of its assets.
#
# Usage: scripts/check.sh
#
# The versions of packages/ that are not published yet are reported, not
# failed: the publish workflow publishes them. It downloads every file the
# site serves. It runs as root on Arch Linux, for vercmp: under
# scripts/docker.sh --root.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# = 0 ] || die "usage: check.sh"
if [ "$(id -u)" = 0 ] && [ -f /etc/arch-release ]; then
	pacman -Syu --noconfirm --needed github-cli jq >&2
fi

url=$(site_url)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
errors=0
fail() {
	errors=$((errors + 1))
	error "$*"
}
download() {
	curl -fsSL --retry 3 --retry-all-errors --connect-timeout 30 -o "$2" "$1"
}

releases > "$work/releases.json"
served "$(cat "$work/releases.json")" > "$work/served.json"
download "$url/index.json" "$work/index.json" || die "$url/index.json does not answer"

# What is served is what should be.
want=$(jq -r '.[] | .files[] | "\(.name) \(.sha256)"' "$work/served.json" | sort)
have=$(jq -r '.packages[] | "\(.file) \(.sha256)"' "$work/index.json" | sort -u)
if [ "$want" != "$have" ]; then
	fail "$url serves"$'\n'"$have"$'\n'"rather than"$'\n'"$want"$'\n'"Run the publish workflow to make the site anew."
fi

signed=false
if signing; then
	signed=true
	keyring "$work/keyring"
fi
# verify FILE says whether FILE.sig is a good signature of FILE by a key of
# keys/.
verify() {
	good_sig "$work/keyring" "$1" "$1.sig"
}

checked=0
for arch in $(jq -r '.packages[].arch' "$work/index.json" | sort -u); do
	dirs=("$arch")
	[ "$arch" != any ] || dirs=("${known_archs[@]}")
	for dir in "${dirs[@]}"; do
		db=$work/$dir.db
		if ! download "$url/$dir/$repo_name.db" "$db"; then
			fail "$url/$dir/$repo_name.db does not answer"
			continue
		fi
		if $signed; then
			if ! download "$url/$dir/$repo_name.db.sig" "$db.sig" || ! verify "$db"; then
				fail "$url/$dir/$repo_name.db has no good signature by a key of keys/"
			fi
		fi
		# FILENAME SHA256SUM of each entry of the database.
		listed=$(tar -xzOf "$db" --wildcards '*/desc' | awk '
			/^%.*%$/ { section = $0; next }
			/^$/ { section = ""; next }
			section == "%FILENAME%" { file = $0 }
			section == "%SHA256SUM%" { print file, $0 }
		' | sort)
		served_here=$(jq -r --arg a "$dir" '.packages[] | select(.arch == $a or .arch == "any")
			| "\(.file) \(.sha256)"' "$work/index.json" | sort)
		[ "$listed" = "$served_here" ] ||
			fail "$url/$dir/$repo_name.db lists"$'\n'"$listed"$'\n'"but index.json"$'\n'"$served_here"
	done
done

while read -r arch file sha256 release; do
	dir=$arch
	[ "$dir" != any ] || dir=${known_archs[0]}
	if ! download "$url/$dir/$file" "$work/$file"; then
		fail "$url/$dir/$file does not answer"
		continue
	fi
	[ "$(sha256sum < "$work/$file" | cut -d' ' -f1)" = "$sha256" ] ||
		fail "$url/$dir/$file is not what index.json says it is"
	asset=$(jq -r --arg t "$release" --arg n "$file" \
		'.[] | select(.tag == $t) | .assets[] | select(.name == $n) | .sha256' "$work/releases.json")
	[ "$asset" = "$sha256" ] || fail "$url/$dir/$file is not the asset of the release $release"
	if $signed; then
		if ! download "$url/$dir/$file.sig" "$work/$file.sig" || ! verify "$work/$file"; then
			fail "$url/$dir/$file has no good signature by a key of keys/"
		fi
	fi
	rm -f "$work/$file" "$work/$file.sig"
	checked=$((checked + 1))
done < <(jq -r '.packages[] | "\(.arch) \(.file) \(.sha256) \(.release)"' "$work/index.json")

# The releases.
while read -r tag immutable digests; do
	split_tag "$tag" > /dev/null || continue
	[ "$immutable" = true ] || notice "$tag is not immutable: enable immutable releases"
	[ "$digests" = true ] || fail "$tag has assets with no sha256 digest"
done < <(jq -r '.[] | "\(.tag) \(.immutable) \(all(.assets[]; .sha256 | test("^[0-9a-f]{64}$")))"' \
	"$work/releases.json")

# What the publish workflow has yet to publish.
while read -r pkgbase current tag; do
	[ "$current" = true ] || notice "$pkgbase: $tag is served, $(tag "$pkgbase") is not published yet"
done < <(jq -r '.[] | "\(.pkgbase) \(.current) \(.tag)"' "$work/served.json")
for pkgbase in $(pkgbases); do
	jq -e --arg p "$pkgbase" 'any(.[]; .pkgbase == $p)' "$work/served.json" > /dev/null ||
		notice "$pkgbase: nothing is published yet"
done

if [ "$errors" -gt 0 ]; then
	die "$errors problems"
fi
say "$url is good: $checked package files"
