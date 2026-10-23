# EMACS picks the final stage: 30 is Ubuntu's own emacs-nox, 31 is built
# from the GNU release, as Ubuntu 26.04 does not package it.
ARG EMACS=31

FROM ubuntu:26.04 AS base

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl git ca-certificates unzip && \
    rm -rf /var/lib/apt/lists/*

FROM base AS emacs-30

RUN apt-get update && \
    apt-get install -y --no-install-recommends emacs-nox && \
    rm -rf /var/lib/apt/lists/*

FROM base AS emacs-31-build

ARG EMACS_31_VERSION=31.1

# The libraries are the ones octocat needs: zlib for avatars, SQLite for
# the sync cache, GnuTLS for fetching packages.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config xz-utils \
      libgnutls28-dev libncurses-dev libsqlite3-dev libxml2-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://ftpmirror.gnu.org/emacs/emacs-${EMACS_31_VERSION}.tar.xz | tar xJ -C /tmp && \
    cd /tmp/emacs-${EMACS_31_VERSION} && \
    ./configure --prefix=/opt/emacs --without-x --without-native-compilation \
                --without-sound --without-dbus --without-selinux && \
    make -j"$(nproc)" && \
    make install

FROM base AS emacs-31

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libgnutls30t64 libncurses6 libsqlite3-0 libxml2-16 zlib1g && \
    rm -rf /var/lib/apt/lists/*

COPY --from=emacs-31-build /opt/emacs /opt/emacs
ENV PATH="/opt/emacs/bin:$PATH"

FROM emacs-${EMACS}

RUN curl -fsSL https://raw.githubusercontent.com/emacs-eask/cli/master/webinstall/install.sh | sh

ENV PATH="/root/.local/bin:$PATH"
