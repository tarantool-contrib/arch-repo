#!/usr/bin/env bash
# Print, as JSON, what the publish workflow has to build and publish: the
# packages of packages/ whose version has no published release yet, and a
# build of each of their archs.
#
# Usage: scripts/plan.sh
#
#   {
#     "publish": [{"pkgbase": "tarantool-3.9", "version": "3.9.0-1",
#                  "tag": "tarantool-3.9-3.9.0-1", "release": "none"}],
#     "builds": [{"pkgbase": "tarantool-3.9", "version": "3.9.0-1",
#                 "arch": "x86_64", "runner": "ubuntu-24.04"}]
#   }
#
# release is the state of the release of the tag: none, or draft, which a
# failed run left (seen only with push access): it is deleted and made
# anew. What is to be done is also reported on stderr.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# = 0 ] || die "usage: plan.sh"

items=()
builds=()
for pkgbase in $(pkgbases); do
	version=$(version "$pkgbase")
	tag=$(tag "$pkgbase" "$version")
	state=$(release_state "$tag")
	case $state in
	published) continue ;;
	draft) say "$tag: a draft: delete it and publish anew" ;;
	*) say "$tag: build and publish it" ;;
	esac
	items+=("$(jq -nc --arg p "$pkgbase" --arg v "$version" --arg t "$tag" --arg s "$state" \
		'{pkgbase: $p, version: $v, tag: $t, release: $s}')")
	for arch in $(archs "$pkgbase"); do
		builds+=("$(jq -nc --arg p "$pkgbase" --arg v "$version" --arg a "$arch" \
			--arg r "$(runner "$arch")" '{pkgbase: $p, version: $v, arch: $a, runner: $r}')")
	done
done

if [ ${#items[@]} = 0 ]; then
	say "every package of packages/ is published"
fi

jq -n --slurpfile publish <(printf '%s\n' "${items[@]}") \
	--slurpfile builds <(printf '%s\n' "${builds[@]}") \
	'{publish: $publish, builds: $builds}'
