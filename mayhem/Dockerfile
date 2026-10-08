# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). The base provides debian + clang/llvm + libFuzzer/afl++
# + the identities + the build-contract ENV; this only adds the per-commit moddable build.

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH

ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# The `tools` target links glib/gio (upstream tools.mk: `pkg-config --libs gio-2.0`).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends libglib2.0-dev \
 && rm -rf /var/lib/apt/lists/*

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
