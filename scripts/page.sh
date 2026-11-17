#!/usr/bin/env bash
# Print index.html of the site: how to use the repository, what it serves,
# and every release of each package, given index.json of the site and the
# published releases (as lib.sh releases prints them).
#
# Usage: scripts/page.sh INDEX RELEASES
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ $# = 2 ] || die "usage: page.sh INDEX RELEASES"
index=$1
releases=$2

keys=()
if [ -d "$root/keys" ]; then
	for file in "$root"/keys/*.asc; do
		[ -e "$file" ] || continue
		file=${file##*/}
		keys+=("${file%.asc}")
	done
fi

repo=${GH_REPO:-}
jq -r --arg repo "$repo" --argjson keys "$(printf '%s\n' "${keys[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
	--slurpfile releases "$releases" --arg pkgbases "$(pkgbases)" '
	def size: if . >= 1048576 then "\(. / 1048576 * 10 | round / 10) MiB"
		else "\(. / 1024 | round) KiB" end;
	.repository as $name | .url as $url
	| ($pkgbases | split("\n") | map(select(. != ""))) as $bases
	| ($releases[0] | map(select(.tag as $t | any($bases[]; . as $b | $t | startswith("\($b)-"))))) as $all
	| (if ($keys | length) > 0 then "" else "SigLevel = Optional TrustAll\n" end) as $level
	| [
	"<!doctype html>",
	"<html lang=\"en\">",
	"<head>",
	"<meta charset=\"utf-8\">",
	"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
	"<title>\($name | @html): Tarantool for Arch Linux</title>",
	"<style>",
	"body { font: 16px/1.5 system-ui, sans-serif; max-width: 60rem; margin: 2rem auto; padding: 0 1rem; color: #1f2328; background: #fff; }",
	"@media (prefers-color-scheme: dark) { body { color: #e6edf3; background: #0d1117; } a { color: #58a6ff; } pre, code { background: #161b22; } td, th { border-color: #30363d; } }",
	"pre { background: #f6f8fa; padding: 0.75rem 1rem; overflow-x: auto; border-radius: 6px; }",
	"code { font: 0.9em ui-monospace, monospace; }",
	"table { border-collapse: collapse; width: 100%; }",
	"td, th { text-align: left; padding: 0.3rem 0.6rem; border-bottom: 1px solid #d0d7de; vertical-align: top; }",
	"</style>",
	"</head>",
	"<body>",
	"<h1>Tarantool for Arch Linux</h1>",
	"<p>The pacman repository <code>[\($name | @html)]</code>: Tarantool, a series a package, and tt.",
	(if $repo != "" then " Built and published by <a href=\"https://github.com/\($repo | @html)\">\($repo | @html)</a>." else "" end),
	"</p>",
	"<h2>Use</h2>",
	(if ($keys | length) > 0 then
		"<p>Trust the key the repository signs with:</p>",
		"<pre><code>" + ([$keys[] | "curl -fsSL \($url)/keys/\(.).asc | sudo pacman-key --add -\nsudo pacman-key --lsign-key \(.)"] | join("\n") | @html) + "</code></pre>"
	else
		"<p>The packages are not signed: pacman takes them on the strength of HTTPS and of the checksums of the database.</p>"
	end),
	"<p>Add the repository to <code>/etc/pacman.conf</code>:</p>",
	"<pre><code>" + ("[\($name)]\n\($level)Server = \($url)/$arch" | @html) + "</code></pre>",
	"<p>and install a series of Tarantool, which stays on its series on upgrades, and tt:</p>",
	"<pre><code>sudo pacman -Sy\nsudo pacman -S " + ([.packages[] | .pkgbase | select(startswith("tarantool-"))] | unique
		| sort_by(ltrimstr("tarantool-") | split(".") | map(tonumber? // 0)) | last // "tarantool-X.Y" | @html) + " tt</code></pre>",
	"<h2>Packages</h2>",
	"<table>",
	"<tr><th>Package</th><th>Version</th><th>Arch</th><th>Size</th><th>Release</th></tr>",
	(.packages | sort_by(.pkgbase, .file)[] |
		"<tr><td><a href=\"\(.arch | @html)/\(.file | @html)\">\(.file | sub("-[^-]+-[^-]+-[^-]+[.]pkg[.]tar[.]zst$"; "") | @html)</a></td><td>\(.version | @html)</td><td>\(.arch | @html)</td><td>\(.size | size)</td><td><a href=\"https://github.com/\($repo | @html)/releases/tag/\(.release | @html)\">\(.release | @html)</a></td></tr>"),
	"</table>",
	"<h2>Every build</h2>",
	"<p>A build once published never changes. Those no longer served stay in their releases; install one with <code>sudo pacman -U URL</code>.</p>",
	"<ul>",
	($all | sort_by(.tag)[] | "<li><a href=\"\(.url | @html)\">\(.tag | @html)</a>: " + ([.assets[] | select(.name | endswith(".pkg.tar.zst")) | "<a href=\"\(.url | @html)\">\(.name | @html)</a>"] | join(", ")) + "</li>"),
	"</ul>",
	"<p><a href=\"index.json\">index.json</a> lists what is served, with the sha256 of each file.</p>",
	"</body>",
	"</html>"
	] | .[]' "$index"
