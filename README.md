# Redmine SVN Authz

[![CI](https://github.com/xxbbzy/redmine_svn_authz/actions/workflows/ci.yml/badge.svg)](https://github.com/xxbbzy/redmine_svn_authz/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/xxbbzy/redmine_svn_authz)](https://github.com/xxbbzy/redmine_svn_authz/releases)
[![Redmine](https://img.shields.io/badge/Redmine-5.1%20%7C%206.x-B32024)](https://www.redmine.org/)
[![License: GPL v2+](https://img.shields.io/badge/License-GPL%20v2%2B-blue.svg)](LICENSE)

English | [简体中文](README.zh-CN.md)

Directory-level read permissions for Subversion repositories in Redmine,
using the same **svn `authz` rules** as your svn server.

Out of the box, Redmine grants access to a repository as a whole: anyone with
*Browse repository* sees every path. With this plugin, in **one** repository,
user A only sees `/dirA` and user B only sees `/dirB`, everywhere Redmine shows
repository content.

## Features

- **Same rules as svn.** The authz parser and lookup are ported from
  Subversion 1.14 (`libsvn_repos/authz*.c`) and are tested against the real
  `svnauthz` tool. That covers `[groups]`, `[aliases]`, `~` inversion,
  `$anonymous` / `$authenticated`, `[repository:/path]` sections, and
  **wildcard sections** (`[:glob:/trunk/src/*]`, `**`, `*.c`, ...).
- **Covers everything that shows content.** Directory browser, file view,
  download, annotate, diffs, revision list and details, activity, search, and
  the *Associated revisions* of issues.
- **Two rule sources.**
  - Read the authz file your svn server already uses (e.g. Apache's
    `AuthzSVNAccessFile`). Changes are picked up automatically.
  - Or manage the rules in Redmine (raw editor or rule table), optionally
    exported to a file for the svn server.
- **Users are matched by login.** An svn user name is the Redmine login.
- **Fails closed.** Invalid or unreadable rules hide everything from
  restricted users. Administrators and roles with *Bypass directory
  permissions* are never restricted.
- **Preview as user.** Check which sections apply to a login and what access
  it has on a given path.

## Requirements

- Redmine 5.1 or 6.x (tested on 5.1 and 6.1 in CI)
- Subversion repositories (other SCMs are not affected)
- SQLite, MySQL / MariaDB, or PostgreSQL

## Installation

Download `redmine_svn_authz-<version>.tar.gz` (or `.zip`) from the
[releases page](https://github.com/xxbbzy/redmine_svn_authz/releases) and
extract it into the plugins directory:

```sh
cd $REDMINE_ROOT/plugins
tar xzf redmine_svn_authz-v0.1.0.tar.gz   # creates redmine_svn_authz/
cd ..
bin/rails redmine:plugins:migrate RAILS_ENV=production
# restart Redmine
```

Or clone the repository instead of downloading the archive:

```sh
cd $REDMINE_ROOT/plugins
git clone https://github.com/xxbbzy/redmine_svn_authz.git
cd ..
bin/rails redmine:plugins:migrate RAILS_ENV=production
# restart Redmine
```

The plugin directory must be named `redmine_svn_authz`.

To uninstall, run
`bin/rails redmine:plugins:migrate NAME=redmine_svn_authz VERSION=0 RAILS_ENV=production`,
then delete the directory and restart Redmine.

## Configuration

1. **Administration → Plugins → Redmine SVN Authz → Configure.**
   List the directories that authz files may be read from or exported to
   (one per line, e.g. `/etc/svn`). Any other path is refused.
2. **Administration → Roles and permissions** (*Repository* module):
   - *Manage directory permissions*: edit the rules of a repository.
   - *Bypass directory permissions*: see everything (administrators always
     do).
3. Open the repository and click **Directory permissions**:

   | Setting | Description |
   |---|---|
   | Rules source | *Managed in Redmine*, or *Read authz file on the server* |
   | authz repository name | Name matched by `[name:/path]` sections. Defaults to the last part of the repository root URL. |
   | Path of the repository URL | Where the Redmine repository URL points inside the svn repository, e.g. `/trunk`. Detected automatically. |
   | Export to file | Optional. Managed rules are written to this file on save, so svn and Redmine share one set of rules. |

authz paths are relative to the **svn repository root**. If the Redmine
repository URL is `svn://host/repo/trunk`, rules are still written as
`[/trunk/dirA]`.

### Example: sparse checkouts

Every group can read the parent directories, no module is readable by default,
and each group gets its own modules back:

```ini
[groups]
team_a = alice
team_b = bob

[/trunk]
@team_a = r
@team_b = r
[/trunk/src]
@team_a = r
@team_b = r

# No module is readable by default
[:glob:/trunk/src/*]
@team_a =
@team_b =

[/trunk/src/module_a]
@team_a = rw
[/trunk/src/module_b]
@team_b = rw
```

Results:

- alice browsing `/trunk/src` only sees `module_a`. `module_b` and
  `/trunk/src/Makefile` are hidden.
- Commits that only touch `module_b` do not show up in her revision list, activity,
  or search results.

As in svn, **order matters** between rules that match at the same depth: the
later section wins. `[/trunk/src/module_a]` must come after
`[:glob:/trunk/src/*]`.

## Rule semantics

The plugin follows Subversion 1.10+:

- The path is matched level by level. The deepest level with a matching
  section decides. Several wildcard sections can match at the same level; the
  one appearing **last** in the file wins. Without a match, a level inherits
  from its parent. With no match at all, access is denied.
- A section only counts for users it has an entry for. A user's access in a
  section is the union of the matching entries.
- For the same path, a `[repository:/path]` section takes precedence over
  `[/path]`.
- Anonymous users only match `*`, `$anonymous` and `~$authenticated`.
- Files that svn refuses to load are rejected with the same checks. Examples:
  - duplicate sections
  - non-canonical paths (`/a/`, `/a//b`)
  - write-only `w` entries
  - `~*`
  - undefined groups or aliases
- Only read access (`r`) matters in Redmine.

## What is filtered

| Where | Behaviour |
|---|---|
| Directory browser | Lists readable entries, plus directories leading to readable content. Those intermediate directories do not show their last revision or size. |
| File view, download, annotate | `403` when not readable |
| Diffs | Unreadable files are removed. The diff cache is separated per set of effective rules. |
| Revision list, history | Only commits touching at least one readable path |
| Revision details | Only readable changes. `403` when there are none. |
| Activity, search, issue revisions | Same as the revision list, through `Changeset.visible` |
| Statistics | `403` for restricted users (they cover the whole repository) |

## Known limitations

- A commit message is shown in full as soon as the commit touches one
  readable path, like `svn log`.
- `refs #123` / `fixes #123` in commit messages add notes such as *Applied in
  changeset rN* to issues. The plugin does not control those.
- The *Previous / Next* links on a revision page may point to revisions the
  user cannot see. They only reveal the revision number, and the page itself
  returns 403.
- Like svn, the plugin does not check which paths exist when deciding whether
  a directory leads to readable content. A rule such as
  `[:glob:/**/public]` can make empty directories appear in the tree.
- With a case-insensitive MySQL collation, matching on `changes.path` is
  case-insensitive.

## Performance

- **Rules without wildcards.** Commit visibility is a plain SQL prefix
  condition, with no extra cost.
- **Wildcard rules.** These cannot be expressed in portable SQL. Visible
  commits are computed once per set of effective rules (users with identical
  access share one set) and stored in a table:
  - New commits are processed incrementally.
  - Saving the rules clears the data.
  - Data unused for 30 days is deleted.
  - The first computation on a large repository can take a few seconds.

## Development

Everything runs in Docker. No local Ruby is needed.

```sh
# Test suite (Redmine 6, SQLite). REDMINE_VERSION=5.1 tests Redmine 5.1,
# DB=postgresql or DB=mysql another database (started in a container)
docker/run-tests.sh

# Core parser/evaluator tests, without Redmine (Ruby >= 2.6)
ruby test/unit/authz_core_test.rb

# Compare with real svn on random authz files (needs `svnauthz`)
docker run --rm -v "$PWD":/plugin:ro -e SVN_AUTHZ_FUZZ=300 redmine-svn-authz-dev:6 \
  ruby /plugin/test/unit/svnauthz_differential_test.rb

# Try it at http://localhost:3000
docker compose up -d --build
docker compose exec redmine bin/rails runner plugins/redmine_svn_authz/docker/seed_demo.rb
```

The demo creates the users `alice` and `bob` (password `password123`) and a
project with two repositories:

- `demo`: alice sees `/trunk/dirA`, bob sees `/trunk/dirB`
- `sparse`: the sparse checkout example above

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute and
[CHANGELOG.md](CHANGELOG.md) for the release history.

## Security

This plugin enforces access control. Please report vulnerabilities privately
as described in [SECURITY.md](SECURITY.md), not in public issues.

## License

Copyright (C) 2026 xxbbzy

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).
