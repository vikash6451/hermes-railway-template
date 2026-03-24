FROM python:3.11-slim AS builder

ARG HERMES_GIT_REF=main
ARG HERMES_GIT_SHA=

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 --branch "${HERMES_GIT_REF}" --recurse-submodules https://github.com/NousResearch/hermes-agent.git \
  && if [ -n "${HERMES_GIT_SHA}" ]; then \
       cd /opt/hermes-agent \
       && git fetch --depth 1 origin "${HERMES_GIT_SHA}" \
       && git checkout --detach "${HERMES_GIT_SHA}" \
       && git submodule update --init --recursive; \
     fi

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel
RUN pip install --no-cache-dir -e "/opt/hermes-agent[messaging,cron,cli,pty]"


FROM python:3.11-slim

ARG INSTALL_CODEX_CLI=1
ARG CODEX_CLI_VERSION=0.116.0

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    nodejs \
    npm \
    tini \
  && if [ "${INSTALL_CODEX_CLI}" = "1" ]; then npm install --global "@openai/codex@${CODEX_CLI_VERSION}"; fi \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:${PATH}" \
  PYTHONUNBUFFERED=1 \
  HERMES_HOME=/data/.hermes \
  HOME=/data \
  CODEX_HOME=/data/.codex \
  CODEX_CONFIG_DIR=/data/.codex

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hermes-agent /opt/hermes-agent

WORKDIR /app
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]
