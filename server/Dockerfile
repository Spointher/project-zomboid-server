FROM debian:12-slim

ARG RCON_CLI_URL="https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/rcon-0.10.3-amd64_linux.tar.gz"
ARG STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

# MUST stay 1001. The old ubuntu:24.04 base already shipped a user at uid 1000
# ('ubuntu'), so pzuser landed on 1001 and every file in the existing
# zomboid-data / pzserver-install volumes is owned by 1001. debian-slim has no
# such user, so an unpinned useradd would hand pzuser uid 1000 and the server
# would lose write access to its own world.
ARG PZ_UID=1001
ARG PZ_GID=1001

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV SERVER_NAME=server
ENV STEAMCMD_PATH=/home/pzuser/steamcmd
ENV PZ_PATH=/opt/pzserver
ENV STEAM_APP_ID=380870

# i386 is required by SteamCMD itself (32-bit binary).
# procps provides pgrep, which the compose healthcheck relies on — debian-slim
# does not ship it, Ubuntu did. Do NOT install a JRE: Project Zomboid bundles
# its own under ${PZ_PATH}/jre64 and start-server.sh uses it.
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        libtcmalloc-minimal4 \
        locales \
        procps \
        sqlite3 \
        vim && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && \
    locale-gen && \
    curl -sqL "${RCON_CLI_URL}" | tar zxf - -C /tmp && \
    mv /tmp/rcon-*/rcon /usr/local/bin/rcon && \
    chmod 0755 /usr/local/bin/rcon && \
    rm -rf /tmp/rcon-* && \
    curl -fsSL https://code-server.dev/install.sh | sh && \
    groupadd -g "${PZ_GID}" pzuser && \
    useradd -m -s /bin/bash -u "${PZ_UID}" -g "${PZ_GID}" pzuser && \
    mkdir -p "${PZ_PATH}" && \
    chown pzuser:pzuser "${PZ_PATH}" && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean

# Ship scripts as real files — never generate them inside a RUN. Docker does not
# unescape \$ the way you would expect: the backslashes survive into the file and
# bash then reads "\$" as a literal $, so nothing expands. That is exactly how an
# earlier printf-generated pz-rcon broke.
COPY --chmod=0755 start.sh /start.sh
COPY --chmod=0755 pz-rcon /usr/local/bin/pz-rcon

USER pzuser

# The profile template lives OUTSIDE /home/pzuser/Zomboid on purpose: that path
# is a named volume, and Docker only seeds a volume that is still empty. Kept
# here, start.sh can derive a new ${SERVER_NAME} profile even on a volume that
# has existed for months.
COPY --chown=pzuser:pzuser Server /home/pzuser/profile-template

# SteamCMD only. The ~7 GB game install happens at runtime in start.sh against
# the pzserver-install volume — baking it here is what made the image ~8 GB.
# SteamCMD's very first run self-updates and can exit non-zero; that must not
# fail the build, and start.sh re-stages steamclient.so if this misses it.
RUN mkdir -p "${STEAMCMD_PATH}" "/home/pzuser/.steam/sdk64" && \
    curl -sqL "${STEAMCMD_URL}" | tar zxf - -C "${STEAMCMD_PATH}" && \
    chmod +x "${STEAMCMD_PATH}/steamcmd.sh" && \
    ("${STEAMCMD_PATH}/steamcmd.sh" +quit || true) && \
    (cp "${STEAMCMD_PATH}/linux64/steamclient.so" /home/pzuser/.steam/sdk64/steamclient.so || \
     echo "steamclient.so not staged at build time; start.sh will handle it")

WORKDIR /home/pzuser/Zomboid
CMD ["bash", "/start.sh"]
