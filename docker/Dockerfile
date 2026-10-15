# Redmine with test gems, for developing and testing the plugin.
#   docker build -t redmine-svn-authz-dev:6 docker
#   docker build -t redmine-svn-authz-dev:5.1 --build-arg REDMINE_VERSION=5.1 docker
ARG REDMINE_VERSION=6
FROM redmine:${REDMINE_VERSION}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libyaml-dev \
 && rm -rf /var/lib/apt/lists/*
COPY database.yml config/database.yml
RUN bundle config unset --local without && bundle config set --local without 'development' \
 && bundle install --jobs 4
