# php-toolchain — shared base. Everything expensive lives here, built once.
#   docker build -t php-toolchain:8.5 -f php-toolchain/Dockerfile .
ARG PHP_VERSION=8.5
FROM php:${PHP_VERSION}-cli-bookworm

# Pin PECL extensions explicitly: PECL does not check PHP compatibility when
# choosing a version, only when installing, so an unpinned `pecl install redis`
# can resolve to something that will not build against 8.5.
ARG REDIS_EXT_VERSION=6.3.0
ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl fd-find git gpg jq less make patch procps \
    python3 python3-pip python3-venv ripgrep shellcheck sqlite3 tini tree \
    unzip zip \
    libicu-dev libzip-dev libxml2-dev libpng-dev libjpeg62-turbo-dev \
    libfreetype6-dev libwebp-dev libgmp-dev libpq-dev libldap2-dev \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Node is needed to *install* both CLIs; neither invokes it at runtime.
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# gd, gmp, pgsql and ldap link against the -dev libs above; keep this order.
#
# opcache is deliberately NOT in this list. As of PHP 8.5 it is compiled into
# the binary and is no longer a shared extension, so `docker-php-ext-install
# opcache` configures cleanly, builds no .so, and then fails on an empty
# modules/ with `cp: cannot stat 'modules/*'`. Read that error as "this
# extension produced no module", never as "the compile failed".
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir=lib/"$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
    docker-php-ext-install -j"$(nproc)" \
        bcmath calendar exif gd gmp intl ldap mysqli pcntl \
        pdo_mysql pdo_pgsql pgsql soap sockets zip; \
    php -m

# PEAR/PECL use PHP streams and do NOT read HTTP_PROXY from the environment,
# so the proxy has to be set in pear's own config or this step hangs.
RUN if [ -n "${HTTP_PROXY:-}" ]; then \
      pear config-set http_proxy "${HTTP_PROXY}"; \
    fi \
    && pecl install "redis-${REDIS_EXT_VERSION}" \
    && docker-php-ext-enable redis \
    && rm -rf /tmp/pear

COPY --from=composer:2.8 /usr/bin/composer /usr/local/bin/composer

# Chromium for headless screenshots. Here rather than in the two agent images
# because they share this base: installed once it costs ~500 MB of disk once,
# and claude and codex cannot drift onto different versions. Late in the file so
# adding or dropping it does not invalidate the PHP extension layers above.
#
# Deliberately unpinned, unlike everything in "Pinned versions": Debian rotates
# old binaries off the mirror, so a pinned apt version turns into an unbuildable
# image a few months later. It tracks bookworm security updates instead.
#
# fonts-liberation is the fallback for anything the page does not self-host; it
# covers Czech diacritics. Note that `cap_drop: [ALL]` in docker-compose.yml
# leaves Chromium no way to set up its own sandbox, so it must be run with
# --no-sandbox (and --disable-dev-shm-usage, since /dev/shm defaults to 64 MB).
RUN apt-get update \
    && apt-get install -y --no-install-recommends chromium fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -s /bin/bash node \
    && mkdir -p /workspace /home/node/.local/bin /home/node/.composer /home/node/.cache/pip \
    && chown -R node:node /workspace /home/node

ENV HOME=/home/node \
    PATH=/home/node/.local/bin:/usr/local/bin:/usr/bin:/bin \
    COMPOSER_HOME=/home/node/.composer \
    COMPOSER_CACHE_DIR=/home/node/.composer/cache \
    COMPOSER_ALLOW_SUPERUSER=0 \
    PIP_CACHE_DIR=/home/node/.cache/pip \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER node
RUN git config --global --add safe.directory '*'
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--"]
