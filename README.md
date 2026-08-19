# project-zomboid-server

A Dockerized [Project Zomboid](https://projectzomboid.com/) **Build 42** dedicated server.

The image is a `debian:12-slim` base carrying SteamCMD, a small RCON client and an optional
web IDE — but **not** the game itself. Project Zomboid (~7 GB) is installed at *runtime*
into a named volume, which keeps the image at ~400–500 MB and makes rebuilds cheap.
Everything else the server needs — the JVM heap, the container's memory and CPU ceilings,
the server profile, the join/admin/RCON passwords, the game version — is driven from a
single `.env` file and applied at boot by `server/start.sh`.

---

## Features

- **Runtime game install.** Only SteamCMD is baked into the image; the game lands in the
  `pzserver-install` volume on first boot. Small image, fast rebuilds.
- **Version pinned on disk, not on the branch.** The installed Steam branch is recorded in
  `/opt/pzserver/.pz-installed-branch`; with `PZ_AUTO_UPDATE=false` a restart can never
  bump the server past players who have not updated their client.
- **Profile templating.** A generic `server.*` profile ships in the repo; on first boot the
  real `${SERVER_NAME}.*` profile is derived from it. An existing profile is never touched.
- **Explicit memory and CPU budgets.** The JVM heap, the container limit and the CPU quota
  are separate knobs, patched into PZ's launcher config at boot and validated against the
  host at startup (see [Memory & CPU sizing](#memory--cpu-sizing)).
- **Ordered shutdown.** `docker stop` sends an RCON `quit`, so the world is warned, saved
  and closed cleanly instead of being cut off mid-write.
- **Admin console.** `docker exec -it project-zomboid-server pz-rcon players`.
- **Optional web IDE.** [code-server](https://github.com/coder/code-server) on `:8443` for
  editing the server config that lives inside the volume. Off by default.
- **Host hardening script.** `server/vm-hardening.sh` prepares the VM (swap, reclaim
  reserve, `earlyoom`, sshd protection, persistent logs) so an overshoot kills a container
  instead of the machine.

---

## Requirements

- Docker Engine with the Compose v2 plugin (`docker compose`, not `docker-compose`).
- **~10 GB free disk** for the game volume, plus room for the world.
- **≥ 6 GB RAM** on the host. The shipped defaults are sized for a 6 GB / 4 vCPU VM.
- Outbound network access at build and first-boot time to: Debian apt mirrors,
  `code-server.dev`, GitHub (the rcon-cli release), and Steam (SteamCMD + app `380870`).

---

## Repository layout

```
.
├── CLAUDE.md               # maintainer notes: the "why" behind every decision here
├── LICENSE
├── README.md
└── server/                 # ← the Docker build context
    ├── Dockerfile
    ├── docker-compose.yml  # the compose file is HERE, not at the repo root
    ├── .env.example        # every tunable, heavily commented
    ├── start.sh            # container entrypoint: install → configure → run
    ├── pz-rcon             # RCON wrapper used via `docker exec`
    ├── vm-hardening.sh     # run once on the host, as root
    └── Server/             # GENERIC profile TEMPLATE — not live config
        ├── server.ini
        ├── server_SandboxVars.lua
        ├── server_spawnpoints.lua
        └── server_spawnregions.lua
```

Two things worth internalising before you touch anything:

- **`server/` is the build context.** `Dockerfile` copies `start.sh` and `Server/` using
  paths relative to `server/`, so a manual build must be invoked as
  `docker build -f server/Dockerfile server` from the repo root.
- **`server/Server/` is a template, not a deployment's live config.** The live profile is
  named after `SERVER_NAME` and lives inside the `zomboid-data` volume. Editing files under
  `server/Server/` only affects servers whose volume does not exist yet.

---

## Quickstart

```bash
cd server
cp .env.example .env
```

Edit `.env` and set at least the required secrets — compose refuses to start without them:

```bash
ADMIN_PASSWORD=...          # in-game admin account
CODE_SERVER_PASSWORD=...    # web IDE login on :8443
RCON_PASSWORD=...           # remote console + the ordered shutdown
SERVER_PASSWORD=...         # what players type to join (leave empty for an open server)
```

Generate each with `openssl rand -base64 24`. They are four **different** secrets — see
[The four passwords](#the-four-passwords).

Then bring it up:

```bash
docker compose up -d --build
docker compose logs -f
```

> **The first boot downloads ~7 GB** from Steam before the game process even exists. That
> is why the healthcheck has a `start_period` of 900s — the container will read as
> `starting` for a long while. Watch the logs, not the health status.

Once you see the server report it is listening, connect from the game client to
`<host>:16261` (UDP). The server also uses `16262/udp`; both are published by compose.

---

## How it works

`server/start.sh` is the container entrypoint. On every boot it:

1. **Logs its own revision** — `[start.sh] revision: /start.sh <mtime> sha <12>`. This is
   how you confirm the container is running the script you think it is (see
   [Deploying to a remote host](#deploying-to-a-remote-host)).
2. **Starts code-server** on `0.0.0.0:8443` if `ENABLE_CODE_SERVER` is truthy, `nice`d so
   the game's boot wins any CPU contention. Skipped otherwise.
3. **Installs or updates Project Zomboid** via SteamCMD (`app_update 380870`), unless the
   on-disk branch marker already matches `PZ_BRANCH` and `PZ_AUTO_UPDATE` is falsey. The
   install is retried up to 3 times because SteamCMD is flaky on a cold cache; genuine
   configuration errors (bad branch, missing license) are reported as `FATAL:` and stop the
   retries instead of looping forever.
4. **Seeds the server profile.** If `Zomboid/Server/${SERVER_NAME}.ini` does not exist, it
   is derived — along with `_SandboxVars.lua`, `_spawnpoints.lua` and `_spawnregions.lua` —
   from the template baked into the image at `/home/pzuser/profile-template`. An existing
   profile is left completely alone.
5. **Patches the JVM flags** in `ProjectZomboid64.json`. PZ's launcher reads its JVM args
   from that file and ignores anything passed on the command line, and it ships with a
   `-Xmx16g` that would OOM-kill the container immediately. `start.sh` sets `-Xmx`, `-Xms`,
   the metaspace and direct-memory ceilings, `-XX:ActiveProcessorCount` and
   `-XX:+ExitOnOutOfMemoryError`, then reads the file back and warns if anything failed to
   land.
6. **Reports the memory and CPU budget** and warns about any host/container mismatch.
7. **Writes the identity keys** (`RCONPassword`, `Password`, `PublicName`,
   `PublicDescription`, `RCONPort`) into the profile `.ini`, plus `UPnP=false`. Empty env
   values are skipped, so an unset variable leaves whatever is already in the volume.
8. **Launches the server in the background** under a `TERM`/`INT` trap. The trap sends an
   RCON `quit` — the ordered shutdown — and the container is held open until the save
   finishes.

Two named volumes hold everything that must survive a rebuild:

| Volume | Mount point | Contents |
|---|---|---|
| `zomboid-data` | `/home/pzuser/Zomboid` | the saved world, the live server profile, logs |
| `pzserver-install` | `/opt/pzserver` | the installed game + the branch marker |

Deleting `zomboid-data` wipes the world. Deleting `pzserver-install` forces a full ~7 GB
re-download.

---

## Configuration reference

Everything lives in `server/.env` (copied from `server/.env.example`, which carries a much
longer version of the commentary below).

| Variable | Default | What it does |
|---|---|---|
| `SERVER_NAME` | `server` | Profile stem **and** saved-world directory. See below. |
| `ADMIN_PASSWORD` | *(required)* | In-game `admin` account (`-adminpassword`). |
| `CODE_SERVER_PASSWORD` | *(required)* | code-server login on `:8443`. Required even when the IDE is off. |
| `SERVER_PASSWORD` | `change-me` | The `.ini` `Password=` key — what players type to join. Empty = open server. |
| `RCON_PASSWORD` | *(required)* | Remote console, and the ordered shutdown on `docker stop`. |
| `RCON_PORT` | `27015` | RCON port inside the container. Deliberately not published. |
| `PZ_HEAP` | `2g` | JVM `-Xmx`. The heap **only**, not the container's ceiling. |
| `PZ_HEAP_MIN` | `512m` | JVM `-Xms`. Deliberately much smaller than `PZ_HEAP`. |
| `PZ_MEM_LIMIT` | `3584m` | Compose `mem_limit` — the ceiling for the *whole* container. |
| `PZ_MEMSWAP_LIMIT` | `4608m` | Compose `memswap_limit`. Kept ~1 GB **above** `PZ_MEM_LIMIT` on purpose. |
| `PZ_CPUS` | `3` | Compose `cpus`, and the JVM's `-XX:ActiveProcessorCount`. |
| `ENABLE_CODE_SERVER` | `false` | Start the web IDE on `:8443`. |
| `PUBLIC_NAME` | *(empty)* | `.ini` `PublicName=`. Empty leaves the volume's value alone. |
| `PUBLIC_DESCRIPTION` | *(empty)* | `.ini` `PublicDescription=`. Same rule. |
| `PZ_BRANCH` | *(empty)* | SteamCMD `-beta` branch. Empty = the public branch. |
| `PZ_AUTO_UPDATE` | `false` in `.env.example` | Run `app_update` on every boot. See [Game version](#game-version). |

Changing any of these only needs `docker compose up -d`. Changing `start.sh` needs
`docker compose up -d --build`.

### `SERVER_NAME`

This one variable selects **both** the config profile (`Zomboid/Server/${SERVER_NAME}.ini`)
and the saved world (`Saves/Multiplayer/${SERVER_NAME}`).

> ⚠️ Changing `SERVER_NAME` on a server that already has a world makes PZ start a **new,
> empty world**. The old one is not deleted, but it will not be loaded either. Change it
> back to get the old world.

### The four passwords

There are four separate secrets here, and only one of them is meant to be shared. Do not
collapse them into one value.

| Variable | Used by | Share with |
|---|---|---|
| `CODE_SERVER_PASSWORD` | the web IDE login on `:8443` | nobody |
| `ADMIN_PASSWORD` | the in-game `admin` account | nobody |
| `SERVER_PASSWORD` | the `.ini` `Password=` key — the join password | **the players** |
| `RCON_PASSWORD` | remote console, and the ordered shutdown | nobody |

`:8443` is published over plain HTTP with no TLS in front of it, which is exactly why the
IDE login must not be the admin secret.

> **Caveat:** identity keys are only written when the env value is non-empty — that is what
> lets an unset variable leave an existing deployment untouched. The side effect is that
> once `SERVER_PASSWORD` has reached the volume you **cannot remove it by blanking the env
> var**. Edit `Password=` in `Zomboid/Server/${SERVER_NAME}.ini` directly instead.

### Game version

The version is `PZ_BRANCH` + `PZ_AUTO_UPDATE`, and the pin lives on disk rather than on the
branch.

- `PZ_BRANCH=` (empty) → the **public** branch. This is the default, because The Indie
  Stone never published a frozen `42.20` branch and a client refuses to join a server on a
  different build — tracking `public` is the only way to stay on the current stable.
- `PZ_BRANCH=42.19` → Build 42.19.1, frozen.
- `PZ_BRANCH=legacy41` → Build 41.78.20, frozen.

List what Steam currently offers:

```bash
curl -s https://api.steamcmd.net/v1/info/380870 | jq '.data["380870"].depots.branches'
```

Because `public` moves on its own, `start.sh` records the installed branch in
`/opt/pzserver/.pz-installed-branch` and skips SteamCMD entirely when that marker matches
`PZ_BRANCH` and `PZ_AUTO_UPDATE` is falsey. `.env.example` therefore ships
`PZ_AUTO_UPDATE=false`, so a restart can never push the server ahead of players who have
not updated their client.

To take an update deliberately:

```bash
# in server/.env
PZ_AUTO_UPDATE=true
```

```bash
docker compose up -d
docker compose logs -f      # confirm the new build installed
```

…then set it back to `false`. Changing `PZ_BRANCH` forces a reinstall regardless of the
flag.

> Note the asymmetry: the compose file defaults `PZ_AUTO_UPDATE` to `true` (so an older
> `.env` that predates the key keeps the previous always-update behaviour), while
> `.env.example` ships `false`. That is intentional — but it means an `.env` missing the key
> auto-updates.

> There is **no way to pin an exact build outside a named branch.** SteamCMD's
> `download_depot` fails under `login anonymous` with
> `Depot download failed : missing license for depot (No subscription)`: an anonymous
> account is licensed for the app but not for its depots.

---

## Memory & CPU sizing

`PZ_HEAP` is the JVM heap. `PZ_MEM_LIMIT` is the whole container: the heap **plus** JVM
non-heap (metaspace, code cache, ~1 thread per player, direct buffers), PZ's native
allocations, and code-server if enabled. Those are different numbers and the difference is
roughly 1.5 GB.

There are **three** conditions, not one:

1. `PZ_MEM_LIMIT ≈ PZ_HEAP + 1.5 GB` — the container's own overhead.
2. `PZ_MEM_LIMIT ≤ host RAM − 2 GB` — the host's reserve.
3. `PZ_CPUS ≤ nproc − 1` — so `sshd` always has a core to be scheduled on.

The two reserves are deliberately **different numbers**: 1.5 GB on the container side, 2 GB
on the host side. Rule 2 is the one that matters most and the one that is easiest to get
wrong — "at most the host's RAM" is not a safety margin. PZ mmaps ~2 GB of assets and map
chunks through the *host's* page cache, which is charged outside the cgroup. With no swap
in the cgroup and none on the host, the kernel has nowhere to evict anonymous pages, so
instead of a clean OOM kill it livelocks reclaiming and the entire machine hangs — SSH
included, with nothing in the logs.

`PZ_MEMSWAP_LIMIT` is kept ~1 GB **above** `PZ_MEM_LIMIT` for the same reason. A container
that spills a gigabyte to disk is slow; a host you cannot SSH into is down. This only means
something if the host actually has swap — see [Host hardening](#host-hardening).

Reference sizing:

| Host RAM | `PZ_HEAP` | `PZ_MEM_LIMIT` | `PZ_MEMSWAP_LIMIT` | `PZ_CPUS` |
|---|---|---|---|---|
| 6 GB | `2g` | `3584m` | `4608m` | `3` |
| 8 GB | `3g` | `4608m` | `5632m` | `3` |
| 12 GB | `5g` | `6656m` | `7680m` | `6` |
| 16 GB | `8g` | `9728m` | `10752m` | `6` |

`PZ_HEAP_MIN` (`-Xms`) is intentionally far below `PZ_HEAP`. Setting them equal makes the
JVM commit the entire heap in the first second of boot — concurrently with everything else
starting — which is precisely the moment a tight host dies. Leave it alone unless you know
why you are changing it.

After any change here, check the boot logs:

```bash
docker compose logs | grep -E 'Memory budget|CPU budget|WARN'
```

`start.sh` prints `heap / container limit / host RAM / host swap` and `PZ_CPUS / nproc`, and
warns on each of the three rules **plus** a host with zero swap. It only warns — it never
clamps or exits, because exiting under `restart: unless-stopped` would just be a restart
loop and clamping silently would hide the misconfiguration.

---

## Host hardening

The compose limits decide how much the server *may* take. `server/vm-hardening.sh` decides
what happens when something takes more anyway. Run it **once on the host, as root**:

```bash
bash server/vm-hardening.sh --dry-run    # preview every change first
sudo bash server/vm-hardening.sh
```

It is idempotent — re-running it after it has been applied is a no-op. It sets up:

- a **swapfile** (4096 MB by default, `--swap-size-mb N` to change it) — which is what makes
  `PZ_MEMSWAP_LIMIT > PZ_MEM_LIMIT` mean anything at all;
- `vm.min_free_kbytes=131072` — the reclaim reserve that prevents the livelock;
- `vm.swappiness=10`;
- **`earlyoom`**, configured to prefer killing `java` and to avoid `sshd` / `dockerd`;
- `OOMScoreAdjust=-900` on the ssh unit, so the process you need to diagnose a problem is
  not fair game;
- **persistent journald**, without which a hard reboot erases all evidence of what happened.

Without this script, none of the container limits give you a safety net: an overshoot takes
the whole machine down and leaves nothing behind to explain it.

---

## Day-2 operations

All commands below run from `server/` unless noted.

### Admin console (RCON)

RCON's port is deliberately **not** published. Reach it through the container:

```bash
docker exec -it project-zomboid-server pz-rcon players
docker exec -it project-zomboid-server pz-rcon save
docker exec -it project-zomboid-server pz-rcon servermsg "restarting in 5 minutes"
docker exec -it project-zomboid-server pz-rcon quit
```

### Status, logs, restart, stop

```bash
docker compose ps                      # health status
docker compose logs -f                 # follow
docker compose restart
docker compose stop                    # ordered shutdown via RCON quit
docker compose up -d                   # apply .env / compose changes
docker compose up -d --build           # apply start.sh / Dockerfile changes
```

`stop_grace_period` is 90s. A `stop` that takes *exactly* 90 seconds means Docker sent
SIGKILL — i.e. the shutdown trap did not work, and the world may not have saved cleanly.
A healthy stop finishes well before that.

### Editing the live server config

The live `.ini` and sandbox settings live inside the `zomboid-data` volume, so **editing
`server/Server/` in this repo does not reach a server whose volume already exists.** Use the
web IDE:

```bash
# in server/.env
ENABLE_CODE_SERVER=true
```

```bash
docker compose up -d
```

Open `http://<host>:8443`, log in with `CODE_SERVER_PASSWORD`, edit
`Zomboid/Server/${SERVER_NAME}.ini`, restart the container, then set `ENABLE_CODE_SERVER`
back to `false` — it shares the game's cgroup and costs ~300–500 MB of the same budget.

The only other way to pick up template changes is `docker compose down -v`, **which wipes
the world**.

### Backups

The world is in the `zomboid-data` volume under `Saves/Multiplayer/${SERVER_NAME}`. Save
first, then copy:

```bash
docker exec -it project-zomboid-server pz-rcon save
docker run --rm -v zomboid-data:/data -v "$PWD:/backup" debian:12-slim \
  tar czf /backup/zomboid-$(date +%F).tar.gz -C /data .
```

---

## Deploying to a remote host

There is no deployment tooling in this repo. The flow is:

1. Copy the `server/` directory to the host.
2. Create `.env` **on the host** — it is gitignored and never travels with the code, so
   version bumps and password changes have to be applied there by hand. A host whose `.env`
   predates a key silently falls back to the compose default.
3. `docker compose up -d --build`.

> **Use `--build`, not a plain `up -d`, whenever `start.sh` changed.** `start.sh` is
> `COPY`ed into the image, so the container runs `/start.sh` *from the image* — not the copy
> you just wrote to disk. Without `--build` the old script keeps running while the new one
> sits there looking deployed. Verify with the `revision:` line at the top of the logs:

```bash
docker compose logs | grep 'revision:'
sha256sum server/start.sh          # compare the first 12 characters
```

Compose and `.env` changes do apply with a plain `docker compose up -d`.

If you keep a personal upload/rsync helper for this, note that `upload_to_server.sh` is
gitignored — it is a local convenience script, not part of the repo.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Container reports `healthy` but nobody can connect | The healthcheck uses `pgrep -f '[P]rojectZomboid64'`. The bracket trick is load-bearing: a plain `pgrep -f ProjectZomboid64` matches the healthcheck's own shell and returns 0 forever. Do not "simplify" it. |
| `Failed to install app '380870' (Missing configuration)` | SteamCMD being flaky on a cold cache. `start.sh` already retries 3 times and clears `appmanifest_380870.acf` between attempts; let it run. |
| `FATAL:` + `Failed to set beta` | Bad `PZ_BRANCH`. Check it against the branch list; retrying will not help. |
| `FATAL:` + `No subscription` / `missing license` | An anonymous Steam account cannot download depots. Do not try to pin an exact build outside a named branch. |
| Server starts an empty world | `SERVER_NAME` changed. Set it back — the old world is still in the volume. |
| Build 41 save will not load | Build 41 saves cannot be read by a Build 42 server, and there is no converter. Use `PZ_BRANCH=legacy41` if you need the old world. |
| Boot hangs at UPnP | `UPnP` is forced to `false` at boot for exactly this reason. If you see it, the container is running an old `start.sh` — rebuild with `--build`. |
| Host freezes solid when the server starts | The three sizing rules, plus a host with no swap. Fix the numbers, then run `vm-hardening.sh`. |
| `libjsig.so cannot be preloaded` | `start.sh` exports the correct `LD_LIBRARY_PATH` before launching. Seeing this means an old script is live — rebuild with `--build`. Do not patch PZ's `start-server.sh`; SteamCMD overwrites it on every update. |

The only static checks available in this repo:

```bash
bash -n server/start.sh
bash -n server/vm-hardening.sh
```

There is no test suite, linter, formatter or CI here.

---

## Notes and non-goals

- The server runs **vanilla Build 42**. `Mods=` and `WorkshopItems=` are deliberately empty
  in the template; if you add mods, update both keys and keep them in sync.
- **RCON `27015/tcp` is intentionally not published.** Use `docker exec … pz-rcon`.
- **`:8443` has no TLS.** Put it behind a reverse proxy or a VPN if it is reachable from
  anywhere you do not control — and keep it disabled by default.
- **No JRE is installed in the image.** Project Zomboid bundles its own at
  `/opt/pzserver/jre64` and the launcher uses it.
- `pzuser` is pinned to uid/gid **1001** via build args. Do not remove the pin: existing
  volumes are owned by 1001, and an unpinned `useradd` on `debian-slim` would hand out 1000
  and lock the server out of its own world.

For the reasoning behind these decisions — including the failure that each one is a fix
for — see [`CLAUDE.md`](CLAUDE.md).

---

## License

See [`LICENSE`](LICENSE).
