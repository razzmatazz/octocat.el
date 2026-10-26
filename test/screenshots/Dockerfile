# The dependencies are those of octocat.el's Package-Requires header.
# Only that line goes on to the next stage, so they are fetched again
# when it changes, not on every edit of octocat.el.
FROM ubuntu:26.04 AS header
COPY octocat.el /src/
RUN printf ';;; octocat.el --- Dependencies  -*- lexical-binding: t -*-\n;; Version: 0\n%s\n;;; octocat.el ends here\n' \
      "$(grep '^;; Package-Requires:' /src/octocat.el)" > /octocat.el

# GUI Emacs under a virtual X display, to save pages as PNG.
FROM ubuntu:26.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      emacs-lucid xvfb xauth fonts-jetbrains-mono fonts-noto-color-emoji \
      curl git ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://raw.githubusercontent.com/emacs-eldev/eldev/master/webinstall/eldev | sh

ENV PATH="/root/.local/bin:$PATH"

# The dependencies, in a layer of their own, so a run fetches nothing.
WORKDIR /deps
COPY Eldev .
COPY --from=header /octocat.el .
RUN eldev prepare
ENV OCTOCAT_DEPS=/deps
