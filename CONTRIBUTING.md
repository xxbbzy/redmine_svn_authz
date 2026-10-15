# Contributing

Thanks for your interest in improving Redmine SVN Authz! Bug reports, ideas
and pull requests are welcome.

## Reporting bugs

Open an [issue](https://github.com/xxbbzy/redmine_svn_authz/issues/new/choose)
with:

- the Redmine, Ruby and database versions
- the authz rules involved (reduced to the smallest example, with names
  replaced by placeholders)
- what you expected and what happened

If the problem lets a user see something they should not, **do not open a
public issue**. Follow [SECURITY.md](SECURITY.md) instead.

## Development setup

Everything runs in Docker. See [Development](README.md#development) in the
README.

```sh
docker/run-tests.sh                                   # Redmine 6, SQLite
REDMINE_VERSION=5.1 DB=postgresql docker/run-tests.sh # other combinations
```

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Add tests for your change:
   - **Rule semantics.** Changes to how rules are parsed or evaluated must
     keep matching Subversion. Add cases to `test/unit/authz_core_test.rb`
     and run the differential test with a high `SVN_AUTHZ_FUZZ` value.
   - **What users can see.** Add a functional test that checks both what is
     shown and what is hidden.
3. Make sure `docker/run-tests.sh` passes. CI also runs Redmine 5.1 and 6 on
   SQLite, PostgreSQL and MySQL.
4. Add an entry under *Unreleased* in [CHANGELOG.md](CHANGELOG.md).
5. Keep translations in sync: `config/locales/en.yml` and
   `config/locales/zh.yml`.

Follow the style of the surrounding code: Redmine's conventions (hash
rockets, `Module#prepend` patches) and short comments that explain why.

## License

By contributing, you agree that your contributions are licensed under the
[GNU General Public License v2.0 or later](LICENSE).
