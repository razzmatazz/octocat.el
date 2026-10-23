# GUI Emacs under a virtual X display, to save pages as PNG.
FROM ubuntu:26.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      emacs-lucid xvfb xauth fonts-jetbrains-mono fonts-noto-color-emoji \
      curl git ca-certificates unzip && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://raw.githubusercontent.com/emacs-eask/cli/master/webinstall/install.sh | sh

ENV PATH="/root/.local/bin:$PATH"

# The dependencies, in a layer of their own, so a run fetches nothing
# and they are fetched again only when Eask changes.  Without its
# package-file, which changes far more often and they don't need.
WORKDIR /deps
COPY Eask .
RUN sed -i '/package-file/d' Eask && eask install-deps
ENV OCTOCAT_DEPS=/deps
