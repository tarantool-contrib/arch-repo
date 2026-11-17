#!/usr/bin/env bash
# Open a pull request for each new build packages/ lacks:
#
#   - each series of Tarantool with a newer release upstream: the newest;
#   - each series upstream newer than every series of packages/: a new
#     package, tarantool-X.Y, made from the newest series (an older series
#     packages/ has not is left out on purpose);
#   - tt, when it has a newer release upstream;
#   - each package served whose dependencies Arch Linux no longer
#     satisfies (scripts/rebuilds.sh): its pkgrel raised.
#
# Usage: scripts/watch.sh [--dry-run]
#
# Releases are those of GitHub, without drafts and pre-releases. A build
# gets a branch, watch/PKGBASE-PKGVER-PKGREL, and a pull request: none is
# opened for a build whose tag is published, or that has a pull request
# already, open or closed (a closed one was declined). Opening one closes
# the open pull requests of the watch for older builds of the package.
#
# --dry-run prints the builds, KIND PKGBASE VERSION a line, and changes
# nothing.
#
# The branches are made from HEAD of the checkout and pushed to the
# remote. A pull request a workflow opens with its GITHUB_TOKEN gets a run
# of the check workflow that waits for approval: watch.sh approves it. It
# needs docker, for scripts/docker.sh.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

dry_run=false
if [ "${1:-}" = --dry-run ]; then
	dry_run=true
	shift
fi
[ $# = 0 ] || die "usage: watch.sh [--dry-run]"

# start_check SHA makes sure the check workflow runs on the pull request of
# the commit SHA: it approves the run that waits for approval, as that of a
# pull request opened by the GITHUB_TOKEN of a workflow does; that of one
# opened by the token of a user or of an app starts by itself.
start_check() {
	local run
	for _ in $(seq 24); do
		run=$(gh api "repos/$GH_REPO/actions/workflows/check.yml/runs?event=pull_request&head_sha=$1" \
			--jq '.workflow_runs[0] // empty | "\(.id) \(.conclusion)"')
		if [ -n "$run" ]; then
			if [ "${run#* }" = action_required ]; then
				gh api -X POST "repos/$GH_REPO/actions/runs/${run%% *}/approve" > /dev/null || return 1
			fi
			return 0
		fi
		sleep 5
	done
	return 1
}

# upstream REPO PREFIX prints the versions X.Y.Z of the releases of REPO,
# whose tags are PREFIX X.Y.Z, sorted.
upstream() {
	gh release list -R "$1" --exclude-drafts --exclude-pre-releases --limit 200 \
		--json tagName --jq '.[].tagName' |
		sed -n "s/^$2\([0-9]\{1,\}[.][0-9]\{1,\}[.][0-9]\{1,\}\)$/\1/p" | sort -V
}

# newer A B succeeds when the version A is newer than B.
newer() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

published=$(gh release list --exclude-drafts --limit 1000 --json tagName --jq '.[].tagName')

builds=()
tarantool=$(upstream tarantool/tarantool '')
series=$(pkgbases | sed -n 's/^tarantool-\([0-9]*\.[0-9]*\)$/\1/p' | sort -V)
for s in $series; do
	have=$(field "tarantool-$s" pkgver)
	latest=$(grep "^${s//./\\.}\." <<<"$tarantool" | tail -n 1 || true)
	if [ -n "$latest" ] && newer "$latest" "$have"; then
		builds+=("update tarantool-$s $latest")
	fi
done
top=$(tail -n 1 <<<"$series")
if [ -n "$top" ]; then
	# shellcheck disable=SC2001 # A line a version.
	while read -r s; do
		if [ -z "$s" ] || ! newer "$s" "$top"; then
			continue
		fi
		builds+=("series tarantool-$s $(grep "^${s//./\\.}\." <<<"$tarantool" | tail -n 1)")
	done < <(sed 's/\.[0-9]*$//' <<<"$tarantool" | sort -uV)
fi
if [ -d "$root/packages/tt" ]; then
	latest=$(upstream tarantool/tt v | tail -n 1)
	if [ -n "$latest" ] && newer "$latest" "$(field tt pkgver)"; then
		builds+=("update tt $latest")
	fi
fi
failed=0
rebuilds=
if ! curl -fsSL -o /dev/null "$(site_url)/index.json"; then
	say "nothing is served at $(site_url) yet: no rebuilds to propose"
elif ! rebuilds=$("$root/scripts/docker.sh" --root "$root/scripts/rebuilds.sh"); then
	say "warning: scripts/rebuilds.sh failed: no rebuilds are proposed"
	rebuilds=
	failed=1
fi
while read -r pkgbase deps; do
	[ -n "$pkgbase" ] || continue
	[ -d "$root/packages/$pkgbase" ] || continue
	# Only the build packages/ has: a newer one on its way is the rebuild.
	if ! grep -qxF "$(tag "$pkgbase")" <<<"$published"; then
		say "$pkgbase: $deps unsatisfied, but $(tag "$pkgbase") is to be published"
		continue
	fi
	builds+=("rebuild $pkgbase $deps")
done <<<"$rebuilds"

if $dry_run; then
	[ ${#builds[@]} = 0 ] || printf '%s\n' "${builds[@]}"
	exit "$failed"
fi
if [ ${#builds[@]} = 0 ]; then
	say "packages/ has every build"
	exit "$failed"
fi

base=$(git -C "$root" rev-parse HEAD)
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/tree" 2> /dev/null || true; rm -rf "$work"' EXIT

# proposed PKGBASE prints the open pull requests of the watch for builds of
# PKGBASE, NUMBER VERSION a line.
proposed() {
	gh pr list --state open --json number,headRefName --jq ".[] | .headRefName as \$h
		| (\$h | ltrimstr(\"watch/$1-\")) as \$v
		| select(\$v != \$h and (\$v | test(\"^[^-/]+-[0-9]+\$\"))) | \"\(.number) \(\$v)\""
}

for item in "${builds[@]}"; do
	read -r kind pkgbase rest <<<"$item"
	case $kind in
	update | series)
		version=$rest-1
		args=("$pkgbase" "$rest")
		[ "$kind" = update ] || args=(--series "${pkgbase#tarantool-}" "$rest")
		case $pkgbase in
		tt) url=https://github.com/tarantool/tt/releases/tag/v$rest ;;
		*) url=https://github.com/tarantool/tarantool/releases/tag/$rest ;;
		esac
		;;
	rebuild)
		version=$(field "$pkgbase" pkgver)-$(($(field "$pkgbase" pkgrel) + 1))
		args=(--rebuild "$pkgbase")
		url=
		;;
	esac
	tag=$pkgbase-$version
	branch=watch/$tag

	# No duplicates: a build published, proposed already, or older than
	# one proposed.
	if grep -qxF "$tag" <<<"$published"; then
		say "$tag is published already"
		continue
	fi
	if [ -n "$(gh pr list --head "$branch" --state all --json number --jq '.[].number')" ]; then
		say "$tag: $branch has a pull request already"
		continue
	fi
	older=()
	ahead=
	while read -r number other; do
		[ -n "$number" ] || continue
		if newer "$version" "$other"; then
			older+=("$number")
		else
			ahead=$number
		fi
	done < <(proposed "$pkgbase")
	if [ -n "$ahead" ]; then
		say "$tag: #$ahead proposes a build as new already"
		continue
	fi

	git -C "$root" worktree add -q --detach "$work/tree" "$base"
	tree=$work/tree
	if ! "$tree/scripts/bump.sh" "${args[@]}" > /dev/null ||
		! "$tree/scripts/docker.sh" "$tree/scripts/srcinfo.sh" "$tree/packages/$pkgbase"; then
		say "warning: $item: the package cannot be changed; trying again on the next run"
		git -C "$root" worktree remove --force "$tree"
		failed=1
		continue
	fi
	made=$(sed -n 's/^\tpkgver = //p' "$tree/packages/$pkgbase/.SRCINFO")-$(sed -n 's/^\tpkgrel = //p' "$tree/packages/$pkgbase/.SRCINFO")
	[ "$made" = "$version" ] || die "$item: bump.sh made $made, not $version"

	case $kind in
	update)
		title="$pkgbase: update to $rest"
		body="Updates \`packages/$pkgbase\` to $rest, $url: the sha256 of the source archive is that of what it downloads now."
		;;
	series)
		title="$pkgbase: add the series, at $rest"
		body="Adds \`packages/$pkgbase\`, the series ${pkgbase#tarantool-} of Tarantool at $rest, $url, made from the newest series of \`packages/\`: check that it needs nothing of its own."
		;;
	rebuild)
		title="$pkgbase: rebuild $version"
		body="Rebuilds \`packages/$pkgbase\`: nothing in Arch Linux satisfies \`${rest// /\`, \`}\` any longer, which the build it serves depends on."
		;;
	esac

	git -C "$tree" add -A "packages/$pkgbase"
	git -C "$tree" -c user.name="$bot_name" -c user.email="$bot_email" \
		commit -q -m "$title" ${url:+-m "$url"}
	# The branch is the workflow's: a run whose pull request failed left it.
	rgit -C "$tree" push -q --force "$(remote)" "HEAD:refs/heads/$branch"
	sha=$(git -C "$tree" rev-parse HEAD)
	git -C "$root" worktree remove --force "$tree"

	cat > "$work/body" <<-EOF
		$body

		The check workflow builds it and installs it on a clean Arch Linux. Once this is merged, the publish workflow publishes the release \`$tag\` and serves it.

		Opened by the watch workflow.
	EOF
	if ! pr=$(gh pr create --base master --head "$branch" --title "$title" --body-file "$work/body"); then
		say "warning: $tag: no pull request; trying again on the next run"
		failed=1
		continue
	fi
	say "$tag: $pr"
	if ! start_check "$sha"; then
		say "warning: $tag: the check workflow did not start on $pr: approve its run there"
		failed=1
	fi
	for number in "${older[@]}"; do
		gh pr close "$number" --delete-branch --comment "Superseded by $pr." || failed=1
	done
done
exit "$failed"
