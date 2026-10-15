# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-15

First public release.

### Added

- Directory-level read permissions for Subversion repositories, based on svn
  `authz` rules, enabled per repository.
- authz parser and evaluator ported from Subversion 1.14
  (`libsvn_repos/authz*.c`):
  - `[groups]` (nested), `[aliases]`, `~` inversion, `*`, `$anonymous` and
    `$authenticated`
  - `[repository:/path]` sections
  - wildcard sections `[:glob:...]` with `*`, `**`, prefix, suffix and
    fnmatch patterns, where a later section wins at the same depth
  - the same validation as svn: duplicate sections, non-canonical paths,
    write-only entries, undefined groups or aliases, and so on
- Filtering of everything that shows repository content:
  - directory browser
  - file view, download and annotate
  - diffs, with the diff cache separated per set of effective rules
  - revision list and revision details
  - activity, search, and the *Associated revisions* of issues
- Two rule sources:
  - an authz file on the server, reloaded when it changes
  - rules managed in Redmine (raw editor and rule table), with optional
    export to a file for the svn server
- Mapping of the Redmine repository URL to its path inside the svn repository
  (e.g. `/trunk`), detected automatically.
- *Preview as user*: the sections that apply to a login and its access to a
  given path.
- Permissions *Manage directory permissions* and *Bypass directory
  permissions* in the *Repository* module.
- Plugin setting restricting the directories authz files may be read from or
  exported to.
- Precomputed, incrementally updated visibility of commits for rules with
  wildcards.
- English and Simplified Chinese translations.
- Test suite, including a differential test against the real `svnauthz` tool,
  and a Docker based development environment with demo data.

[Unreleased]: https://github.com/xxbbzy/redmine_svn_authz/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/xxbbzy/redmine_svn_authz/releases/tag/v0.1.0
