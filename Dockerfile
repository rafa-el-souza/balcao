# check=error=true

# No `# syntax=` line: it would hand the build to a frontend image fetched by
# tag on every build, outside the digest pins below; the builder's own
# frontend reads this file and the check directive above (review finding R2,
# pull request #4).

# The production image (design §6.2, ADR-0006): the Rails API with the web
# app's static build, served by Puma behind Thruster. Kamal builds it from a
# clean git clone of HEAD; it is part of the deploy-path review (SR-38).
# Every runtime secret arrives as environment at run time, from Kamal; no
# ARG or ENV here carries one (threat model SR-25).
#
# The base images carry the versions of .tool-versions and are pinned by
# digest; Dependabot proposes new digests (spec/deploy/image_spec.rb keeps
# the versions in step).

# The web app (ADR-0001): type-checked and built by Vite into web/dist.
FROM docker.io/library/node:26.13.0-slim@sha256:5adad64f9a1fca2d51972caa65983634c8a774eb300d72b20f7f2a0f60368072 AS web
WORKDIR /web
COPY web/package.json web/package-lock.json web/.npmrc ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build

FROM docker.io/library/ruby:4.0.9-slim@sha256:d8cb2c0714bdaba0f318af897a01d2dbde3cfa8e62d47e99cea55feb13c0e90d AS base

WORKDIR /rails

# Runtime packages: curl for health probes by hand, jemalloc for memory, the
# Postgres client for the console.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Bootsnap's cache lives outside tmp/, which is a tmpfs at run time over a
# read-only root filesystem (config/deploy.yml, SR-24).
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    BOOTSNAP_CACHE_DIR="/rails/cache" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 avoids a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .

# The web sources were built in their own stage; the Rails image keeps only
# the build (below).
RUN rm -rf web && \
    bundle exec bootsnap precompile -j 1 app/ lib/

FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# The web app's shells, one per page and language, go where SpaController
# sends them from, with no-cache; their hashed assets are static files under
# public/, cached for a year (design §6.7).
COPY --chown=rails:rails --from=web /web/dist/shells /rails/web/dist/shells
COPY --chown=rails:rails --from=web /web/dist/assets /rails/public/assets

# The root filesystem is read-only at run time (config/deploy.yml): Bootsnap
# reads its precompiled cache without writing, and Bundler's home is in /tmp.
ENV BOOTSNAP_READONLY="1" \
    BUNDLE_USER_HOME="/tmp/bundle"

# Prepares the databases before the web server starts (bin/docker-entrypoint).
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Thruster in front of Puma compresses responses and caches the static assets
# (the 300 KB first-visit budget of NFR-10). The job role overrides the command
# with bin/jobs (config/deploy.yml). Its own request line would write a trace
# page's path whole, token included (SR-30); Rails logs each request with the
# token masked, and kamal-proxy keeps the host's request log.
ENV THRUSTER_LOG_REQUESTS="false"
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
