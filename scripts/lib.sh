# shellcheck shell=bash
# What the scripts share; they source it.
#
# A package of the repository is a directory packages/PKGBASE with a
# PKGBUILD and its .SRCINFO. Its build, PKGVER-PKGREL, is published as the
# release PKGBASE-PKGVER-PKGREL, which holds the package files of each
# pkgname and arch, PKGNAME-PKGVER-PKGREL-ARCH.pkg.tar.zst, and, when the
# repository signs, the signature of each, FILE.sig. A published release
# never changes: a new build of a version is a new pkgrel.
#
# The pacman repository $repo_name of each arch is served by GitHub Pages
# at $(site_url)/ARCH: the database and, for each package of packages/,
# the files of its newest published release, copied out of the release.
#
# The scripts run gh against $GH_REPO, and git against $REPO_REMOTE,
# default the repository $GH_REPO on GitHub, authorized with $GH_TOKEN.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The name of the pacman repository: the [section] of pacman.conf and the
# name of its database, $repo_name.db.
# shellcheck disable=SC2034 # The scripts that source this use them.
repo_name=tarantool

# The archs the packages may be built for, and the runner of each.
# shellcheck disable=SC2034
known_archs=(x86_64)

# The image the packages are built and tested in.
# shellcheck disable=SC2034
arch_image=archlinux:base-devel

# The name and the address the commits of the workflows are made by.
# shellcheck disable=SC2034
bot_name='github-actions[bot]'
# shellcheck disable=SC2034
bot_email='41898282+github-actions[bot]@users.noreply.github.com'

# die MESSAGE reports MESSAGE and exits.
die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

# say MESSAGE reports MESSAGE.
say() {
	printf '%s\n' "$*" >&2
}

# error MESSAGE reports a problem, as an annotation on GitHub Actions. To
# stderr, like all that is said: stdout is what a script prints.
error() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error::%s\n' "${*//$'\n'/%0A}" >&2
	else
		printf 'error: %s\n' "$*" >&2
	fi
}

# notice MESSAGE reports what is fine but worth knowing.
notice() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::notice::%s\n' "${*//$'\n'/%0A}" >&2
	else
		printf 'notice: %s\n' "$*" >&2
	fi
}

# runner ARCH prints the runner of GitHub Actions ARCH is built on.
runner() {
	case $1 in
	any | x86_64) echo ubuntu-24.04 ;;
	*) die "no runner for $1" ;;
	esac
}

# pkgbases prints the packages of the repository, one per line: the
# directories of packages/ with a PKGBUILD.
pkgbases() {
	local file
	for file in "$root"/packages/*/PKGBUILD; do
		[ -e "$file" ] || continue
		file=${file%/PKGBUILD}
		printf '%s\n' "${file##*/}"
	done
}

# srcinfo PKGBASE prints the path of the .SRCINFO of PKGBASE.
srcinfo() {
	local file=$root/packages/$1/.SRCINFO
	[ -f "$file" ] || die "unknown package: $1"
	printf '%s\n' "$file"
}

# field PKGBASE KEY prints the values of KEY of the pkgbase section of the
# .SRCINFO of PKGBASE, one per line.
field() {
	awk -v key="$2" '
		/^pkgname = / { exit }
		$1 == key && $2 == "=" { sub(/^[ \t]*[^ ]+ = /, ""); print }
	' "$(srcinfo "$1")"
}

# pkgnames PKGBASE prints the packages PKGBASE makes, one per line.
pkgnames() {
	sed -n 's/^pkgname = //p' "$(srcinfo "$1")"
}

# version PKGBASE prints PKGVER-PKGREL of PKGBASE.
version() {
	local pkgver pkgrel
	pkgver=$(field "$1" pkgver)
	pkgrel=$(field "$1" pkgrel)
	[ -n "$pkgver" ] && [ -n "$pkgrel" ] || die "$1 has no pkgver or pkgrel"
	[ -z "$(field "$1" epoch)" ] || die "$1 has an epoch, which a tag cannot hold"
	printf '%s-%s\n' "$pkgver" "$pkgrel"
}

# tag PKGBASE [VERSION] prints the tag of the release of VERSION of
# PKGBASE, default the version of packages/.
tag() {
	printf '%s-%s\n' "$1" "${2:-$(version "$1")}"
}

# archs PKGBASE prints the archs PKGBASE is built for, one per line.
archs() {
	field "$1" arch | sort -u
}

# files PKGBASE ARCH [VERSION] prints the package files of PKGBASE for
# ARCH, one per line, of VERSION, default the version of packages/.
files() {
	local name version=${3:-$(version "$1")}
	for name in $(pkgnames "$1"); do
		printf '%s-%s-%s.pkg.tar.zst\n' "$name" "$version" "$2"
	done
}

# split_tag TAG prints "PKGBASE VERSION" of a release tag, and fails for
# a tag of no package of the repository.
split_tag() {
	local pkgbase version
	for pkgbase in $(pkgbases); do
		version=${1#"$pkgbase"-}
		if [ "$version" != "$1" ] && [[ $version =~ ^[^-]+-[0-9]+(\.[0-9]+)?$ ]]; then
			printf '%s %s\n' "$pkgbase" "$version"
			return 0
		fi
	done
	return 1
}

# release_state TAG prints the state of the release TAG: none, draft or
# published. A token without push access sees no drafts: none.
release_state() {
	local out
	if out=$(gh release view "$1" --json isDraft --jq .isDraft 2>&1); then
		case $out in
		true) echo draft ;;
		false) echo published ;;
		*) die "gh release view $1: $out" ;;
		esac
	elif [[ $out == *"release not found"* ]]; then
		echo none
	else
		die "gh release view $1: $out"
	fi
}

# releases prints, as a JSON array, the published releases of the
# repository: {tag, immutable, url, assets: [{name, url, sha256, size}]}.
releases() {
	gh api --paginate "repos/${GH_REPO:?GH_REPO names the repository}/releases?per_page=100" \
		--jq '.[] | select(.draft | not) | {tag: .tag_name, immutable: (.immutable // false),
			url: .html_url, assets: [.assets[] | {name, url: .browser_download_url,
			sha256: ((.digest // "") | sub("^sha256:"; "")), size}]}' |
		jq -s .
}

# served RELEASES prints, as a JSON array, what the repository is to
# serve, given the published releases RELEASES (as releases prints them):
# for each package of packages/, its newest release not newer than the
# version of packages/, with its package files and their signatures.
#
#   [{"pkgbase": "tt", "version": "2.15.2-1", "tag": "tt-2.15.2-1",
#     "current": true, "immutable": true,
#     "files": [{"name": "tt-2.15.2-1-x86_64.pkg.tar.zst", "arch": "x86_64",
#                "url": "…", "sha256": "…", "size": 1, "sig": null}]}]
#
# current is whether it is the version of packages/: a release whose
# publication failed leaves the previous one served. A package with no
# release is left out.
served() {
	local pkgbase want best tag version all=()
	for pkgbase in $(pkgbases); do
		want=$(version "$pkgbase")
		best=
		while read -r tag; do
			[ -n "$tag" ] || continue
			version=${tag#"$pkgbase"-}
			[[ $version =~ ^[^-]+-[0-9]+(\.[0-9]+)?$ ]] || continue
			[ "$(vercmp "$version" "$want")" -le 0 ] || continue
			if [ -z "$best" ] || [ "$(vercmp "$version" "$best")" -gt 0 ]; then
				best=$version
			fi
		done < <(jq -r --arg p "$pkgbase-" '.[].tag | select(startswith($p))' <<<"$1")
		[ -n "$best" ] || continue
		all+=("$(jq -c --arg p "$pkgbase" --arg v "$best" --arg want "$want" '
			.[] | select(.tag == "\($p)-\($v)")
			| (.assets | map({key: .name, value: .}) | from_entries) as $by
			| {pkgbase: $p, version: $v, tag, current: ($v == $want), immutable,
			   files: [.assets[] | select(.name | endswith(".pkg.tar.zst"))
				| . + {arch: (.name | capture("-(?<a>[^-]+)[.]pkg[.]tar[.]zst$").a),
				       sig: ($by["\(.name).sig"] // null)}]}' <<<"$1")")
	done
	printf '%s\n' "${all[@]}" | jq -s .
}

# vercmp A B prints <0, 0 or >0 as A is older than B, the same or newer,
# by the rules of pacman.
vercmp() {
	command vercmp "$1" "$2"
}

# site_url prints the URL GitHub Pages serves the repository at.
site_url() {
	if [ -n "${SITE_URL:-}" ]; then
		printf '%s\n' "${SITE_URL%/}"
		return
	fi
	local repo=${GH_REPO:?GH_REPO names the repository}
	local owner=${repo%%/*} name=${repo#*/}
	owner=${owner,,}
	if [ "${name,,}" = "$owner.github.io" ]; then
		printf 'https://%s.github.io\n' "$owner"
	else
		printf 'https://%s.github.io/%s\n' "$owner" "$name"
	fi
}

# add_repo adds the repository served at $(site_url) to the pacman.conf
# of this system, trusting the keys of keys/ if there are any, and syncs
# the databases. It runs as root on Arch Linux.
add_repo() {
	local keys key fpr level='SigLevel = Optional TrustAll'
	keys=("$root"/keys/*.asc)
	if [ -e "${keys[0]}" ]; then
		pacman-key --init > /dev/null 2>&1
		for key in "${keys[@]}"; do
			fpr=${key##*/}
			pacman-key --add "$key" >&2
			pacman-key --lsign-key "${fpr%.asc}" >&2
		done
		level=
	fi
	# shellcheck disable=SC2016 # $arch is pacman's.
	printf '\n[%s]\n%s\nServer = %s/$arch\n' "$repo_name" "$level" "$(site_url)" >> /etc/pacman.conf
	pacman -Syu --noconfirm >&2
}

# signing succeeds when the repository signs: when keys/ has keys,
# keys/FINGERPRINT.asc.
signing() {
	local keys=("$root"/keys/*.asc)
	[ -e "${keys[0]}" ]
}

# signing_key HOME imports $SIGNING_KEY into the new GnuPG home HOME,
# exports GNUPGHOME=HOME, and sets signing_fpr to the fingerprint of the
# key, which has to be one of keys/. Not in a subshell: it sets them for
# the gpg after it.
signing_key() {
	[ -n "${SIGNING_KEY:-}" ] || die "keys/ has keys, but SIGNING_KEY, the secret key to sign with, is not set"
	export GNUPGHOME=$1
	mkdir -m 700 "$GNUPGHOME"
	gpg --batch --quiet --import <<<"$SIGNING_KEY"
	signing_fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
	[ -n "$signing_fpr" ] || die "SIGNING_KEY holds no secret key"
	[ -f "$root/keys/$signing_fpr.asc" ] || die "the key $signing_fpr of SIGNING_KEY is not in keys/"
}

# keyring HOME imports the keys of keys/ into the new GnuPG home HOME, for
# good_sig.
keyring() {
	mkdir -m 700 "$1"
	gpg --homedir "$1" --batch --quiet --import "$root"/keys/*.asc
}

# good_sig HOME FILE SIG succeeds when SIG is a good signature of FILE by a
# key of the keyring HOME that is neither expired nor revoked: gpg says
# GOODSIG of no other.
good_sig() {
	local status
	status=$(gpg --homedir "$1" --batch --status-fd 1 --verify "$3" "$2" 2> /dev/null) || return 1
	[[ $status == *"[GNUPG:] GOODSIG "* ]]
}

# remote prints the git remote of the repository.
remote() {
	printf '%s\n' "${REPO_REMOTE:-https://github.com/${GH_REPO:?GH_REPO names the repository}.git}"
}

# rgit runs git with the remote authorized by $GH_TOKEN, the way
# actions/checkout does it, without writing the token anywhere.
rgit() {
	if [ -n "${GH_TOKEN:-}" ] && [[ $(remote) == https://github.com/* ]]; then
		local auth
		auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
		GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
			GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" git "$@"
	else
		git "$@"
	fi
}
