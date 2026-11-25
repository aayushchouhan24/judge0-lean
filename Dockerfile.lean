# Lean Judge0 image: only the toolchains our clients use (language 89 projects
# calling node, python3, javac/java, gcc, g++), with JDK 17 and Node 20 baked in
# instead of downloaded at container start.
#
# Ruby is copied from the upstream compilers image, which is built on the same
# buildpack-deps:buster base, so its shared libraries match. The sandbox is isolate
# 2.1.2 (cgroup v2), patched to accept the isolate 1.x timing flags Judge0 passes.
#
#   docker build -f Dockerfile.lean -t judge0-lean:1.13.1 .

FROM judge0/compilers:1.4.0 AS upstream
FROM eclipse-temurin:17.0.10_7-jdk AS jdk
FROM node:20.12.0-bullseye-slim AS nodejs

FROM buildpack-deps:buster AS isolate
ARG ISOLATE_URL=https://github.com/ioi/isolate/archive/refs/tags/v2.1.2.tar.gz
ARG ISOLATE_SHA256=069f3c7849aae7bfed1c697bc81dc26e65dcfcc10c4b30759b3cbaa96a91cbfd
COPY docker/isolate/cg-timing-compat.patch /tmp/
RUN set -eux; \
    printf '%s\n' 'deb http://archive.debian.org/debian buster main' > /etc/apt/sources.list; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install -y --no-install-recommends libcap-dev; \
    for i in 1 2 3 4 5; do curl -fsSL "$ISOLATE_URL" -o /tmp/isolate.tar.gz && break; sleep 3; done; \
    echo "$ISOLATE_SHA256  /tmp/isolate.tar.gz" | sha256sum -c -; \
    mkdir /src && tar -xzf /tmp/isolate.tar.gz -C /src --strip-components=1; \
    cd /src && sed -i 's/\r$//' /tmp/cg-timing-compat.patch && patch -p1 < /tmp/cg-timing-compat.patch; \
    make isolate CONFIG=/usr/local/etc/isolate

FROM buildpack-deps:buster AS production

# UTF-8 locale, as in the stock image: Ruby reads ENV with it, and isolate passes LANG/LC_ALL to programs.
ENV LANG=C.UTF-8 LANGUAGE=C.UTF-8 LC_ALL=C.UTF-8
# Only Multi-file program (89) works with the toolchains in this image.
ENV ENABLED_LANGUAGE_IDS=89

ENV JUDGE0_HOMEPAGE "https://judge0.com"
LABEL homepage=$JUDGE0_HOMEPAGE
ENV JUDGE0_SOURCE_CODE "https://github.com/judge0/judge0"
LABEL source_code=$JUDGE0_SOURCE_CODE
ENV JUDGE0_MAINTAINER "Herman Zvonimir Došilović <hermanz.dosilovic@gmail.com>"
LABEL maintainer=$JUDGE0_MAINTAINER

# Ruby (runs the API and workers) from upstream; isolate 2.1.2 (the sandbox) from the build stage.
COPY --from=upstream /usr/local/ruby-2.7.0 /usr/local/ruby-2.7.0
COPY --from=isolate /src/isolate /usr/local/bin/isolate
COPY docker/isolate/isolate.conf /usr/local/etc/isolate

ENV PATH "/usr/local/ruby-2.7.0/bin:/opt/.gem/bin:$PATH"
ENV GEM_HOME "/opt/.gem/"

# System toolchains: Debian's python3, gcc and g++ (/usr/bin/gcc, /usr/bin/g++), as in the stock image.
# Buster is end-of-life: its packages now live on archive.debian.org.
RUN printf '%s\n' \
      'deb http://archive.debian.org/debian buster main' \
      'deb http://archive.debian.org/debian-security buster/updates main' \
      > /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends \
      cron \
      gcc \
      g++ \
      libcap2 \
      python3 \
      sudo \
      unzip && \
    rm -rf /var/lib/apt/lists/* && \
    chmod 4755 /usr/local/bin/isolate && \
    sed -i 's/\r$//' /usr/local/etc/isolate

# JDK 17 and Node 20 copied from their official images (fast registry pulls, no tarball downloads).
COPY --from=jdk /opt/java/openjdk /usr/local/jdk-17
COPY --from=nodejs /usr/local/bin/node /usr/local/node/bin/node
RUN ln -sf /usr/local/node/bin/node /usr/bin/node && \
    rm -f /usr/local/bin/java /usr/local/bin/javac /usr/local/bin/node

# java/javac wrappers with faster JVM startup (see docker/java-wrappers).
COPY docker/java-wrappers/java docker/java-wrappers/javac /usr/bin/
RUN chmod 755 /usr/bin/java /usr/bin/javac && \
    java -version && javac -version

# Precompiled bits/stdc++.h for exactly the flags our clients use (-std=c++17 -O2).
# g++ picks it up automatically; any other flags fall back to the normal header.
RUN set -eux; \
    hdr="$(find /usr/include -path '*/c++/*/bits/stdc++.h' | head -n 1)"; \
    g++ -std=c++17 -O2 -x c++-header "$hdr" -o "$hdr.gch"; \
    chmod 644 "$hdr.gch"

RUN echo "gem: --no-document" > /root/.gemrc && \
    gem install bundler:2.1.4

EXPOSE 2358

WORKDIR /api

COPY Gemfile* ./
RUN RAILS_ENV=production bundle

COPY cron /etc/cron.d
RUN cat /etc/cron.d/* | crontab -

COPY . .

# Builds from a Windows checkout get CRLF scripts, which break shebangs and cron; normalize text files only.
RUN find /api/scripts /api/bin /api/docker-entrypoint.sh /etc/cron.d -type f -exec grep -Il . {} + \
      | xargs sed -i 's/\r$//' && \
    cat /etc/cron.d/* | crontab -

ENTRYPOINT ["/api/docker-entrypoint.sh"]
CMD ["/api/scripts/server"]

RUN useradd -u 1000 -m -r judge0 && \
    echo "judge0 ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && \
    chown judge0: /api/tmp/ && \
    mkdir -p /tmp/judge0-compile-cache && chown judge0: /tmp/judge0-compile-cache

USER judge0

ENV JUDGE0_VERSION "1.13.1"
LABEL version=$JUDGE0_VERSION
