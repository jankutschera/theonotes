# Security policy

## Reporting a vulnerability

Report security problems privately:

1. Preferred: open a private advisory on GitHub (**Security ▸ Report a vulnerability** in this repository).
2. Or write to hello@theonotes.app.

Do not open a public issue or pull request for a vulnerability.

Include what you found, the app version or commit, the platform (macOS, iOS or iPadOS version, device), and **steps that reproduce it** on a small test library. Do not send real personal notes or credentials. Reports without a reproduction, and reports that only paste the output of an automated scanner, are read last; a short proof that the problem is reachable in Theo Notes moves a report to the front.

You get an answer within 14 days. Please give us 90 days to ship a fix before you publish details; we credit reporters who want to be named.

## Scope

In scope: the apps (Mac, iPhone, iPad, Apple Watch), the `theonotes` command line tool and MCP server, note encryption, locked notes, backups, and the iCloud sync code in this repository.

Out of scope: problems that need an already unlocked, compromised device; findings in third-party dependencies that do not affect Theo Notes (report those to their maintainers); the website.

## Supported versions

The latest released version of the app receives security fixes.
