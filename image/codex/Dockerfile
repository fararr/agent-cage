ARG BASE=php-toolchain:8.5
FROM ${BASE}
ARG CODEX_VERSION=0.145.0

USER root
RUN npm install -g @openai/codex@${CODEX_VERSION} \
    && npm cache clean --force \
    && install -d -o node -g node /home/node/.codex
USER node

ENV CODEX_HOME=/home/node/.codex

RUN php -v && composer --version && codex --version
CMD ["codex"]
