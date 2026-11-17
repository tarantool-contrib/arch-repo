# arch-repo

A pacman repository of [Tarantool](https://github.com/tarantool/tarantool)
and [tt](https://github.com/tarantool/tt) for Arch Linux, served by GitHub
Pages:

```
https://tarantool-contrib.github.io/arch-repo/$arch
```

| Package | What it is |
| --- | --- |
| `tarantool-2.11` | Tarantool 2.11, with `tarantoolctl` and its systemd unit `tarantool@.service` |
| `tarantool-3.2`, `-3.3`, `-3.5`, `-3.6`, `-3.7`, `-3.8`, `-3.9` | Tarantool of each series 3.x that has releases still |
| `tt` | The command-line utility to manage Tarantool applications |

A series is a package of its own: `pacman -Syu` upgrades it to the newest
release of its series, never to another series, whose data a database may
have to be upgraded for. The series conflict with each other, and each
provides `tarantool`, so there is no package `tarantool` as such:
`pacman -S tarantool` asks which series.

## Using the repository

The packages and the databases are signed by the key
`1D54FA5DFAE459015258B6875F9AA83FFFF24B0F`, which
[`keys/`](keys/) holds. Trust it:

```sh
curl -fsSL https://tarantool-contrib.github.io/arch-repo/keys/1D54FA5DFAE459015258B6875F9AA83FFFF24B0F.asc |
  sudo pacman-key --add -
sudo pacman-key --lsign-key 1D54FA5DFAE459015258B6875F9AA83FFFF24B0F
```

add the repository to `/etc/pacman.conf`:

```ini
[tarantool]
Server = https://tarantool-contrib.github.io/arch-repo/$arch
```

and install a series and tt:

```sh
sudo pacman -Sy
sudo pacman -S tarantool-3.9 tt
```

[The site](https://tarantool-contrib.github.io/arch-repo/) lists what is
served and every build ever published; `index.json` there lists the files
served with their sha256. A build no longer served stays in its release:
`sudo pacman -U URL` installs it.

## Layout

```
 master: packages/PKGBASE/{PKGBUILD,.SRCINFO,test.sh}     metadata only
   │
   │  publish workflow, for each version with no release
   ▼
 build: makepkg in archlinux:base-devel ─► install and test on a clean system
   │                                         (no secrets, read-only)
   ▼
 release PKGBASE-PKGVER-PKGREL                              immutable
   PKGNAME-PKGVER-PKGREL-ARCH.pkg.tar.zst [.sig]
   │
   │  the newest release of each package of master, its sha256 checked
   ▼
 GitHub Pages: ARCH/tarantool.db, the package files, index.json, index.html
   ▲
   └─ pacman: Server = https://tarantool-contrib.github.io/arch-repo/$arch
```

- **`master`**: the packages, `packages/PKGBASE/`, each a `PKGBUILD`, its
  `.SRCINFO`, the files it installs and `test.sh`, the test of the
  installed package; the keys the repository signs with, `keys/`; the
  scripts and the workflows. No package files: the tree is the metadata.
- **Releases**: one per build, tagged `PKGBASE-PKGVER-PKGREL`
  (`tarantool-3.9-3.9.0-1`), with the package file of each arch,
  `PKGNAME-PKGVER-PKGREL-ARCH.pkg.tar.zst` (and its `.sig` when the
  repository signs). A release is made as a draft, its assets uploaded and
  checked against the sha256 GitHub computes for them, then published.
  Releases are immutable: a published build never changes. A new build of
  a version is a new `pkgrel`.
- **GitHub Pages**: the repository of each arch, `ARCH/`: for each package
  of `packages/`, the files of its newest published release, copied out of
  the release and checked against its sha256, and the database
  `repo-add` makes of them. It is made anew from the releases on each run
  of the publish workflow, and deployed as an artifact: no branch holds it.
  pacman reads the database and the packages from one URL, and GitHub
  Pages cannot redirect to the releases, so the packages are copied.

A package whose build fails keeps its previous release served.

## Adding a version

The watch workflow opens the pull requests every day:

- a new release of a series of `packages/`, or of tt: its `pkgver`, `pkgrel`
  1 and the sha256 of the source archive;
- a new series of Tarantool, newer than every series of `packages/`: a new
  `packages/tarantool-X.Y`, made from the newest series (an older series
  left out of `packages/` stays out);
- a rebuild, its `pkgrel` raised, of a package served whose dependencies
  Arch Linux no longer satisfies: a library it links to moved to another
  soname.

It opens none for a build that is published, or that has a pull request
already, open or closed (a closed one was declined), and closes its own
older pull requests for the same package. The check workflow builds each
of them and installs it on a clean Arch Linux; once one is merged, the
publish workflow builds, publishes and serves it.

By hand:

```sh
scripts/bump.sh tarantool-3.9 3.9.1         # a release of a series
scripts/bump.sh --series 3.10 3.10.0        # a new series
scripts/bump.sh --rebuild tt                # the same version built anew
scripts/docker.sh scripts/srcinfo.sh packages/tarantool-3.9
```

The sha256 of an upstream archive is that of what it downloads: review the
release upstream before merging. A series is dropped by removing its
directory: the site serves it no longer, its releases stay.

## Building locally

On a host that is not Arch Linux, `scripts/docker.sh` runs a script in the
`archlinux:base-devel` container:

```sh
scripts/docker.sh --root scripts/makepkg.sh packages/tt out
scripts/docker.sh --root scripts/install-test.sh tt out/*.pkg.tar.zst
```

(`out/` and `site/` are ignored by git.) `PACMAN_CACHE=DIR` keeps the
packages pacman downloads between the runs.

`scripts/makepkg.sh` upgrades the system, installs the dependencies of the
`.SRCINFO`, checks that the `.SRCINFO` is that of the `PKGBUILD`, and runs
makepkg as an unprivileged user; `scripts/install-test.sh` installs the
packages on a clean system, checks that every program finds its
libraries, and runs `test.sh`.

## How the packages are built

- Against the Arch Linux of the day: the system is upgraded before each
  build. The libraries are depended on by soname as well
  (`libicuuc.so=78-64`), so pacman holds back an upgrade of a library that
  would break a package until it is rebuilt.
- Against OpenSSL 3, the `openssl-3` package: Tarantool, its bundled curl
  and the go-openssl of tt do not build with OpenSSL 4.
- Tarantool without the feedback daemon, which would report the instances
  to tarantool.io, and with `ENABLE_DIST` as its own packages are (in 3.x
  it only builds the EmmyLua stubs it installs). The bundled projects of
  the older series predate CMake 4: `CMAKE_POLICY_VERSION_MINIMUM=3.5`.
- tt as its releases are (`goreleaser/.goreleaser_linux.yml` of tt), but
  with the OpenSSL of the system rather than a static one, and with the
  system environment of `tt -S` laid out the way of Arch Linux: the user
  `tarantool` by `sysusers.d`, its directories by `tmpfiles.d`.

## Workflows

- **publish** (push to `master` changing the packages, the keys, the
  scripts or the workflow; by hand): each package whose version has no
  published release is built, installed and tested on a clean Arch Linux,
  and published as its release; then the site is made of the releases and
  deployed. The builds have no secrets and no write access; the jobs after
  them publish what they made.
- **check** (pull requests; nightly): on a pull request, the packages
  (`.SRCINFO` up to date; a changed package not published already and newer
  than every build published; names, archs, versions a tag can hold), the
  scripts (shellcheck), the workflows (actionlint), and a build of each
  package changed, installed and tested. Nightly, the site against the
  releases (it serves what it should, every file is the asset of its
  release, the databases list them, the releases are immutable, the
  signatures are good), and each package installed from it and tested.
- **watch** (daily): the pull requests above.

## For the administrators

- Enable immutable releases (Settings, General, Releases).
- Serve GitHub Pages from GitHub Actions (Settings, Pages, Source).
- Let GitHub Actions create pull requests (Settings, Actions, General,
  Workflow permissions), for the watch workflow.
- Require the check `Check result` of the check workflow on `master`: it
  fails when the packages, the scripts or a build fail. The run of the
  check workflow on a pull request the watch workflow opens with the
  `GITHUB_TOKEN` waits for approval, and the watch workflow approves it;
  with a secret `WATCH_TOKEN`, a token of a user or of a GitHub App that
  may push and open pull requests, the run starts by itself.
- Put the armored secret key of `keys/` into the secret `SIGNING_KEY` of
  the repository: the publish workflow signs the packages and the
  databases with it, and fails without it. The key has no passphrase and
  does not expire; the secret is all that protects it.
- A signature is an asset of its release, and a release is immutable: a
  package is never signed anew, it is built anew. The site serves only
  packages with a good signature by a key of `keys/`, and fails to deploy
  otherwise, leaving the site as it was. To change the key:
  - by plan: add the new key to `keys/` beside the old one, and once the
    users trust it, put it into `SIGNING_KEY`. The databases and the new
    builds are signed by it; the builds signed by the old one stay good.
    Remove the old key when no package served is signed by it any more,
    rebuilding what still is (`scripts/bump.sh --rebuild`) in the same
    pull request;
  - when the key is compromised: replace it in `keys/` and in
    `SIGNING_KEY`, and rebuild every package in the same pull request. A
    stolen secret means the workflows were too, so the builds are made
    anew anyway. Publish the revocation certificate of the old key.
- The repository has to be public: GitHub Pages serves no private
  repository on the free plan, and pacman downloads no asset of a private
  release.
