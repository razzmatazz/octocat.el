# EMACS is the GNU release to build, e.g. 29.1, 30.2 or 31.1.  Ubuntu 26.04
# packages only Emacs 30, so every version is built the same way.
ARG EMACS=31.1

FROM ubuntu:26.04 AS build

ARG EMACS

# The libraries are the ones octocat needs: zlib for avatars, SQLite for
# the sync cache, GnuTLS for fetching packages, and Jansson for JSON on
# Emacs 29, which 30 parses itself.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config curl ca-certificates xz-utils \
      libgnutls28-dev libjansson-dev libncurses-dev libsqlite3-dev libxml2-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# GCC 15 defaults to C23, which Emacs before 30 does not build with.
RUN curl -fsSL --retry 5 https://ftp.gnu.org/gnu/emacs/emacs-${EMACS}.tar.xz | tar xJ -C /tmp && \
    cd /tmp/emacs-${EMACS} && \
    ./configure --prefix=/opt/emacs CFLAGS="-O2 -std=gnu17" \
                --without-x --without-native-compilation \
                --without-sound --without-dbus --without-selinux && \
    make -j"$(nproc)" && \
    make install

FROM ubuntu:26.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl git ca-certificates \
      libgnutls30t64 libjansson4 libncurses6 libsqlite3-0 libxml2-16 zlib1g && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/emacs /opt/emacs
ENV PATH="/opt/emacs/bin:/root/.local/bin:$PATH"

# Eldev fetches itself on its first run, so that is done here, not on
# every `docker run'.
RUN curl -fsSL https://raw.githubusercontent.com/emacs-eldev/eldev/master/webinstall/eldev | sh && \
    eldev --version
