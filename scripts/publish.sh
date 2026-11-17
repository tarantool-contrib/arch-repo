#!/usr/bin/env bash
# Publish the build of PKGBASE of packages/ as its release: check that
# BUILDS holds its package files, sign them when the repository signs,
# create the release as a draft, upload them, check what GitHub holds,
# publish.
#
# Usage: scripts/publish.sh PKGBASE BUILDS
#
# BUILDS holds the package files the build jobs made, of each arch, as
# scripts/makepkg.sh names them.
#
# A published release is never changed: if it is there, it is only checked
# to have the assets it should. A draft is what a failed run left: it is
# deleted and the release made anew.
#
# When keys/ has keys, the packages are signed with $SIGNING_KEY, the
# armored secret key of one of them, with no passphrase.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# = 2 ] || die "usage: publish.sh PKGBASE BUILDS"
pkgbase=$1
builds=$2

version=$(version "$pkgbase")
tag=$(tag "$pkgbase" "$version")
sign=false
if signing; then
	sign=true
fi

# The assets, sorted: the package files of each arch, and their signatures.
mapfile -t packages < <(for arch in $(archs "$pkgbase"); do files "$pkgbase" "$arch"; done | sort)
[ ${#packages[@]} -gt 0 ] || die "$pkgbase makes no packages"
expected=$(
	printf '%s\n' "${packages[@]}"
	if $sign; then
		printf '%s.sig\n' "${packages[@]}"
	fi
)
expected=$(sort <<<"$expected")

state=$(release_state "$tag")
if [ "$state" = published ]; then
	have=$(gh release view "$tag" --json assets --jq '.assets[].name' | sort)
	if [ "$have" != "$expected" ]; then
		die "$tag is published with the assets"$'\n'"$have"$'\n'"rather than"$'\n'"$expected"$'\n'"A published release never changes: raise the pkgrel of $pkgbase."
	fi
	say "$tag is published"
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dist=$work/dist
mkdir -p "$dist"

for file in "${packages[@]}"; do
	[ -f "$builds/$file" ] || die "no $file in $builds"
	cp "$builds/$file" "$dist/"
	# The package is the one of the PKGBUILD.
	info=$(tar -xOf "$dist/$file" .PKGINFO)
	grep -qxF "pkgbase = $pkgbase" <<<"$info" || die "$file is not of the pkgbase $pkgbase"
	grep -qxF "pkgver = $version" <<<"$info" || die "$file is not of the version $version"
done

if $sign; then
	signing_key "$work/gnupg"
	for file in "${packages[@]}"; do
		gpg --batch --yes --local-user "$signing_fpr" --detach-sign --no-armor \
			-o "$dist/$file.sig" "$dist/$file"
	done
	say "signed with $signing_fpr"
fi

(cd "$dist" && sha256sum -- *) | sort -k2 > "$work/sha256"

# A draft is left by a failed run, which may have uploaded only some of the
# assets: start again. There may be several drafts of a tag.
for _ in 1 2 3 4 5; do
	[ "$state" = draft ] || break
	say "$tag: deleting the draft a failed run left"
	gh release delete "$tag" --yes
	sleep 2
	state=$(release_state "$tag")
done
case $state in
none) ;;
draft) die "$tag: the drafts do not go away" ;;
*) die "$tag got $state while this run built it" ;;
esac

# The notes: where the packages come from, what they were built with.
repo=${GH_REPO:-}
commit=${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD 2> /dev/null || true)}
first=$dist/${packages[0]}
buildinfo=$(tar -xOf "$first" .BUILDINFO)
built=$(sed -n 's/^builddate = //p' <<<"$buildinfo")
notes=$work/notes
{
	echo "\`$pkgbase\` $version for the pacman repository \`[$repo_name]\`."
	echo
	if [ -n "$repo" ] && [ -n "$commit" ]; then
		echo "Built from [\`packages/$pkgbase\`](https://github.com/$repo/tree/$commit/packages/$pkgbase)"
		echo "on the Arch Linux of $(date -u -d "@$built" +%F) by the publish workflow."
	fi
	if [ -n "${GITHUB_RUN_ID:-}" ]; then
		echo "Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$repo}/actions/runs/$GITHUB_RUN_ID"
	fi
	echo
	echo "Install it from the repository (see the [README](https://github.com/$repo#readme)),"
	echo "or this very build:"
	echo
	echo '```sh'
	for file in "${packages[@]}"; do
		echo "sudo pacman -U https://github.com/$repo/releases/download/$tag/$file"
	done
	echo '```'
	echo
	echo "| Asset | sha256 |"
	echo "| --- | --- |"
	awk '{ print "| `" $2 "` | `" $1 "` |" }' "$work/sha256"
	echo
	echo "<details><summary>Built with</summary>"
	echo
	echo '```'
	# The packages of the build environment it depends on, and was made
	# with, at the versions it was built against: NAME-PKGVER-PKGREL of
	# each "installed = NAME-PKGVER-PKGREL-ARCH" of .BUILDINFO.
	tar -xOf "$first" .PKGINFO | sed -nE 's/^(make)?depend = //p' | sed -E 's/[<>=].*//' |
		sort -u > "$work/deps"
	awk 'NR == FNR { want[$0]; next }
		$1 == "installed" && $2 == "=" {
			name = $3; sub(/-[^-]+-[^-]+-[^-]+$/, "", name)
			if (name in want) { sub(/-[^-]+$/, "", $3); print $3 }
		}' "$work/deps" - <<<"$buildinfo" | sort -u
	echo '```'
	echo
	echo "</details>"
} > "$notes"

target=()
if [ -n "$commit" ]; then
	target=(--target "$commit")
fi

gh release create "$tag" --draft --latest=false --title "$pkgbase $version" \
	--notes-file "$notes" "${target[@]}" > /dev/null
gh release upload "$tag" "$dist"/*

# The draft holds what was built, byte for byte, by the digests of GitHub.
have=$(gh release view "$tag" --json assets \
	--jq '.assets[] | "\(.digest // "none" | sub("^sha256:"; ""))  \(.name)"' | sort -k2)
if [ "$have" != "$(cat "$work/sha256")" ]; then
	die "the draft $tag holds"$'\n'"$have"$'\n'"rather than"$'\n'"$(cat "$work/sha256")"
fi

gh release edit "$tag" --draft=false --latest=false > /dev/null

view=$(gh release view "$tag" --json isDraft,isImmutable)
[ "$(jq -r .isDraft <<<"$view")" = false ] || die "$tag is still a draft"
if [ "$(jq -r .isImmutable <<<"$view")" != true ]; then
	notice "$tag is published, but not immutable: enable immutable releases"
fi
say "$tag is published"
