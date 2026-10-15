#!/bin/sh
# Runs the plugin test suite inside the Redmine test image.
#
#   docker/run-tests.sh                                  # Redmine 6, SQLite
#   REDMINE_VERSION=5.1 DB=postgresql docker/run-tests.sh
#
# REDMINE_VERSION: tag of the official redmine image (default 6)
# DB: sqlite, postgresql or mysql (default sqlite); a database container is
#     started for postgresql and mysql
set -eu

REDMINE_VERSION="${REDMINE_VERSION:-6}"
DB="${DB:-sqlite}"
IMAGE="redmine-svn-authz-dev:${REDMINE_VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="redmine-svn-authz-test-$$"

docker build -q -t "$IMAGE" --build-arg REDMINE_VERSION="$REDMINE_VERSION" "$ROOT/docker" >/dev/null

NETWORK_ARGS=""
cleanup() {
  docker rm -f "$NAME-db" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

case "$DB" in
  sqlite) ;;
  postgresql)
    docker network create "$NAME" >/dev/null
    docker run -d --name "$NAME-db" --network "$NAME" --network-alias db \
      -e POSTGRES_PASSWORD=postgres postgres:16 >/dev/null
    until docker exec "$NAME-db" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
    NETWORK_ARGS="--network $NAME -e DB_HOST=db"
    ;;
  mysql)
    docker network create "$NAME" >/dev/null
    docker run -d --name "$NAME-db" --network "$NAME" --network-alias db \
      -e MYSQL_ROOT_PASSWORD=root mysql:8.0 >/dev/null
    until docker exec "$NAME-db" mysql -uroot -proot -e 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
    NETWORK_ARGS="--network $NAME -e DB_HOST=db"
    ;;
  *) echo "unknown DB: $DB" >&2; exit 2 ;;
esac

echo "Redmine $REDMINE_VERSION, $DB"
# shellcheck disable=SC2086
docker run --rm $NETWORK_ARGS -e RAILS_ENV=test -e DB="$DB" -e SVN_AUTHZ_FUZZ="${SVN_AUTHZ_FUZZ:-40}" \
  -v "$ROOT":/usr/src/redmine/plugins/redmine_svn_authz "$IMAGE" sh -ec '
    bin/rails db:create db:migrate redmine:plugins:migrate > /tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }
    bin/rails redmine:plugins:test NAME=redmine_svn_authz
  '
