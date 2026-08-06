ARG BASE=php-toolchain:8.5
FROM ${BASE}
ARG CLAUDE_CODE_VERSION=2.1.202

USER root
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force \
    && install -d -o node -g node /home/node/.claude
USER node

# One directory holds settings, .credentials.json, .claude.json, projects/,
# todos/ and shell-snapshots/ — so a single mount persists auth and state.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

RUN php -v && composer --version && claude --version
CMD ["claude", "--dangerously-skip-permissions"]
