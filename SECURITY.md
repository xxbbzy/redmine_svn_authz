# Security Policy

Redmine SVN Authz enforces access control. Any way for a user to see
repository content their authz rules do not grant is treated as a security
vulnerability. Examples:

- reading a file
- listing a directory
- seeing a diff, a commit or its changed paths

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | Yes |

## Reporting a vulnerability

Please **do not** open a public issue. Report it privately through
[GitHub private vulnerability reporting](https://github.com/xxbbzy/redmine_svn_authz/security/advisories/new),
with:

- the Redmine and plugin versions
- a minimal authz file and repository layout that reproduce the problem
- the request or page that exposes the content

You should receive a response within a week. Once a fix is released, the
advisory is published and you are credited, unless you prefer otherwise.
