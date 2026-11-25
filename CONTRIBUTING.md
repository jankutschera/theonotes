# Contributing to Theo Notes

Thank you for helping. Theo Notes is free software under the GNU General Public License, version 3 only (see [LICENSE](LICENSE)). Please read the [Code of Conduct](CODE_OF_CONDUCT.md) first.

Theo Notes has one maintainer, who reads and merges every pull request. An automated reviewer reads outside pull requests first and leaves one comment; a person still decides. The rules below keep that workable.

## Before you open a pull request

| You want to… | Do this |
|---|---|
| Fix a bug or a typo, small and obvious | Open a pull request directly. Link the issue if there is one. |
| Add a feature or change how something behaves | Open a [feature request](../../issues/new/choose) first and wait for a "yes" before you write code. |
| Submit larger work, or work written mostly by an AI agent | Open an issue first that describes the problem and your plan; link it from the pull request. |
| Refactor without a behaviour change, or add only tests | Please don't, unless an issue asks for it. These are hard to review and rarely needed. |
| Report a security problem | Do not open an issue or pull request. See [SECURITY.md](SECURITY.md). |

- Keep at most **5 open pull requests** at a time.
- Tick **"Allow edits by maintainers"** so small fixes can be made on your branch instead of another round trip.
- Fill in the pull request template: the problem, who notices the change, why this way, and what you checked (and what you did not). A pull request without that is labelled `missing-evidence` and waits.
- One topic per pull request. Unrelated changes are split or closed.

## Contributor licence agreement (CLA)

Every outside contribution needs a signed CLA ([CLA.md](CLA.md)). You keep your copyright. The app is also distributed through Apple's stores under Apple's terms, which the GPL alone does not allow for third-party code, so True Brew Birdie Ltd. needs the right to license contributions outside the GPL too. The CLA also promises that every version containing your work stays available under the GPL v3 or another OSI-approved open-source licence.

You sign once, by commenting on your pull request with exactly this sentence:

> I have read the Theo Notes CLA and I agree to it.

A bot records the signature and the "CLA" check turns green. Type `recheck` as a comment if it does not.

## Build and test

Requirements: macOS 26 with Xcode, XcodeGen, Node with pnpm, Python 3.

```sh
scripts/bootstrap.sh   # installs the editor's JS dependencies and the Playwright browser, generates the Xcode project
scripts/build.sh       # builds the editor bundle and the app with the development identity
scripts/test-all.sh    # Swift tests, editor tests, end-to-end tests, Python tests, guards
```

`scripts/build.sh` without a flag builds the development identity, which has its own library folder, so your real notes are never touched. Use it for all tests and checks. The Xcode project is generated from `project.yml` and is never committed.

## Commits and pull requests

- English for code, comments, docs and commit messages.
- Conventional commits: `<type>(<scope>): <subject>` with the types `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`. Subject at most 50 characters, imperative, no trailing period.
- Keep changes small and add or update a test for new behaviour.
- New dependencies are pinned to an exact version and their licence must be compatible with GPL-3.0-only. Ask first if it is GPL, LGPL, AGPL, SSPL, EPL, MPL or unknown.
- Every new first-party source file starts with the SPDX line and the copyright line (`python3 -I scripts/licence-headers.py --write` adds them).
- Every bundled asset (icon, image, palette, font, word list) needs its source, licence and author recorded next to it.

## Clean-room rules

Theo Notes reads the files and formats of other notes apps so people can bring their notes along, and it may match interface facts such as command, flag and field names, URL scheme actions, Markdown syntax, shortcuts and exit codes. It must not contain anything taken from another app itself.

- Do not copy another app's help text, tool descriptions, FAQ, interface wording, release notes, icons, fonts, themes, sounds or images, not even reworded line by line. Write from our own spec.
- Do not decompile, disassemble, class-dump or run `strings` on another app, and do not read its containers or database.
- Another app's name may appear in the interface only to describe an import ("Import from …").

## Forks

If you ship your own build, change the name and icon (see [BRANDING.md](BRANDING.md) and [TRADEMARK.md](TRADEMARK.md)) and the identity: `config/identity.env` holds the bundle root and `config/release.env` holds the Apple team and signing profile names.

## Security problems

Do not open a public issue. See [SECURITY.md](SECURITY.md).
