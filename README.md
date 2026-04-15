# UXC — Lightweight Containers for OpenWrt

UXC is a container management system for OpenWrt designed for resource-constrained embedded devices. It uses OCI-compliant container specifications but avoids heavyweight runtimes like Docker. Containers are distributed as APK packages and stored as compressed squashfs images.

## Architecture

Five OpenWrt components work together:

| Component | Role |
|-----------|------|
| **procd-ujail** | Manages namespaces, cgroups, and seccomp filters. Directly launches OCI runtime bundles. |
| **uxc** | OCI container management CLI (like `runc`/`crun`). Communicates with procd over ubus. |
| **uvol** | Storage abstraction layer. Uses LVM2 (eMMC) or UBI (raw NAND) for squashfs volumes and read-write overlays. |
| **netifd** | Manages container network namespaces dynamically using veth pairs, virtual bridges, and DHCP via UCI. |
| **apk** | Extended Alpine Package Keeper that deploys container images directly into uvol storage volumes. |

See `paper` for the full design rationale.

## Device Setup

Before installing containers, the OpenWrt device needs uvol (volume management) set up.

### 1. Ensure free disk space

The device needs unpartitioned space for LVM. For VMs, resize the disk image before booting:

```sh
qemu-img resize openwrt-*.img +4G
```

If the GPT table doesn't reflect the new size, fix it on the device:

```sh
sfdisk --relocate gpt-bak-std /dev/vda
```

### 2. Install required packages

```sh
apk add autopart uvol lvm2 partx-utils sfdisk e2fsprogs \
    kmod-fs-ext4 kmod-fs-squashfs block-mount \
    uxc procd-ujail kmod-veth
```

### 3. Initialize storage

Reboot the device — `autopart` will automatically detect free space and create an LVM partition. After reboot, verify:

```sh
uvol free          # Should show available bytes
```

### 4. Set up the uvol metadata volume

```sh
uvol create .meta 4194304 rw
uvol up .meta
mkdir -p /tmp/run/uvol/.meta/apk
ln -sf ../../tmp/run/uvol/.meta/apk /lib/apk/db-uvol
touch /lib/apk/db-uvol/world
```

### 5. Add the container feed

```sh
uclient-fetch -O /etc/apk/keys/uxc-public.pem https://aparcar.org/uxc-action/public-key.pem
echo "https://aparcar.org/uxc-action/aarch64_generic/packages.adb" >> /etc/apk/repositories
apk update
```

### 6. Install and start a container

```sh
apk add container-alpine
uvol up $(uvol list | grep ' ro ' | awk '{print $1}')
uxc start alpine
```

## Available Containers

| Container | Version | Description |
|-----------|---------|-------------|
| `container-alpine` | 3.21.3 | Alpine Linux minimal base |
| `container-debian` | 12.13 | Debian 12 (bookworm) slim base |
| `container-pihole` | 2026.02.0 | Network-wide ad blocking (DNS) |
| `container-homeassistant` | 2026.3.4 | Home automation platform |

## Quick Start (Building)

### Build a container package from a Docker image

```sh
./mkpkg.sh --from-docker docker.io/library/alpine alpine 3.21
```

This pulls the image via podman, converts the filesystem to squashfs, generates OCI and UXC configs, and produces a signed APK package.

### Package an existing container file tree

```sh
./mkpkg.sh --from-dir aarch64 --arch aarch64_generic pihole 5.3.1
```

### Build all containers from the CI list

```sh
./build.sh
```

Reads `containers.json` and builds each container for all configured architectures.

## mkpkg.sh Usage

```
mkpkg.sh --from-docker <url> [OPTIONS] <name> <version>
mkpkg.sh --from-dir <dir>    [OPTIONS] <name> <version>
```

### Modes

| Flag | Description |
|------|-------------|
| `--from-docker <url>` | Full pipeline: pull Docker image, convert to squashfs, generate configs, package as APK |
| `--from-dir <dir>` | Package from a pre-existing file tree |

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--arch <arch>` | `aarch64_generic` | Target architecture (must match `/etc/apk/arch` on the device) |
| `--sdk-path <path>` | `./sdk` | OpenWrt SDK path (for `apk mkpkg` and signing key) |
| `--sign-key <path>` | `<sdk-path>/private-key.pem` | Package signing key |
| `--output-dir <dir>` | `.` | Output directory for the `.apk` file |
| `--build-dir <dir>` | auto tmpdir | Intermediate build directory |
| `--origin <url>` | Docker URL or `local` | Origin URL for APK metadata |
| `--caps <c1,c2,...>` | — | Additional Linux capabilities beyond the defaults |
| `--caps-file <file>` | — | JSON file replacing the default capability list entirely |
| `--network <mode>` | `dedicated` | Network mode: `dedicated`, `bridged`, `host`, or `none` (see below) |
| `--overlay-path <path>` | — | Persistent write overlay path |
| `--overlay-size <size>` | `50M` | Temp overlay size (ignored if `--overlay-path` is set) |
| `--ports <mapping>` | — | Port forwards (`dedicated` mode only): `host:container/proto,...` |
| `--allow-new-privs` | — | Set `noNewPrivileges` to false in OCI config |
| `--maintainer <string>` | — | Package maintainer |

### Capabilities

By default, containers get a minimal capability set: `CAP_AUDIT_WRITE`, `CAP_KILL`, `CAP_NET_BIND_SERVICE`.

For containers that need more (e.g. pihole needs `CAP_NET_ADMIN`, `CAP_NET_RAW`, etc.), use:

```sh
./mkpkg.sh --from-docker docker.io/pihole/pihole \
    --caps CAP_DAC_OVERRIDE,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SETFCAP,CAP_SETUID,CAP_SETGID,CAP_SYS_NICE,CAP_CHOWN,CAP_FOWNER \
    pihole 5.3.1
```

### Dependencies

`--from-docker` mode requires: `podman`, `mksquashfs`, `fakeroot`, `apk` (from OpenWrt SDK), `jq`, `shasum`

`--from-dir` mode requires: `fakeroot`, `apk` (from OpenWrt SDK)

## CI Pipeline

- `build.sh` — Orchestrator: builds all containers for all architectures
- `index.sh` — Generates APK feed with `packages.adb` for GitHub Pages
- `config.env` — Shared configuration (SDK path, arches, feed URL)
- `containers.json` — Container definitions (name, version, origin, ports, caps)

### GitHub Actions

Pushes to `main`/`master` automatically build all containers for all architectures and deploy the APK feed to GitHub Pages.

**Setup required:**

1. Add your APK signing private key as a repository secret named `APK_SIGNING_KEY`
2. Enable GitHub Pages (Settings > Pages > Source: GitHub Actions)
3. Set the `FEED_URL` variable in GitHub Actions settings

### Container Definitions

```json
{
  "containers": [
    {
      "name": "alpine",
      "version": "3.21.3",
      "origin": "docker.io/library/alpine:3.21"
    },
    {
      "name": "pihole",
      "version": "2026.02.0",
      "origin": "docker.io/pihole/pihole",
      "network": "dedicated",
      "allow_new_privs": true,
      "ports": ["80:80/tcp", "53:53/udp", "53:53/tcp"],
      "caps": ["CAP_NET_ADMIN", "CAP_NET_RAW", "CAP_CHOWN", "..."]
    }
  ]
}
```

Supported fields per container: `name`, `version`, `origin`, `network`, `ports`, `caps`, `allow_new_privs`.

## APK Package Layout

Each built APK contains:

```
etc/uxc/<name>.json                         # UXC container metadata
usr/share/containers/<name>/config.json     # OCI v1.0.0 runtime config
uvol/<sha256-hash>                          # Compressed squashfs filesystem
```

Plus post-install and pre-remove scripts that configure UCI networking (virtual bridge, veth pair, DHCP) and firewall rules.

## Networking

Containers support four network modes via `--network <mode>`:

### `dedicated` (default)

Each container gets its own isolated network with a dedicated veth pair on a separate bridge.

- Creates a `br-virt` bridge on `10.0.0.0/24` with a DHCP server (shared infrastructure, created once)
- Per-container veth pair: `h-<name>` (host side, bridged to `br-virt`) and `v-<name>` (container side, DHCP)
- Per-container firewall zone (`container_<name>`) with forwarding to `wan` and from `lan`
- Per-container port redirects (DNAT) when `--ports` is specified

All UCI sections use the `container_` prefix for easy identification and are fully cleaned up on package removal. Port forwarding rules are editable in `/etc/config/firewall`.

### `bridged`

The container's veth pair is added directly to `br-lan`. The container gets an IP via the LAN's DHCP server and appears as a regular device on the local network.

- No separate bridge or firewall zone
- No port forwarding needed — the container is directly reachable on the LAN

### `host`

The container shares the host's network namespace. No network isolation — the container sees and can bind to all host interfaces.

- No `network` namespace in the OCI config
- No veth pair or bridge setup
- Useful for containers that need full access to the host's network stack

### `none`

The container has its own network namespace but no interfaces are created. Only the loopback interface is available.

- Useful for containers that manage their own networking or don't need network access
- An external tool or script can attach interfaces to the container's namespace later

## Supported Architectures

`aarch64_generic`, `x86_64`

## Repository Structure

```
mkpkg.sh                  # Unified container packager (Docker → APK or dir → APK)
.github/workflows/        # GitHub Actions CI (build + deploy to Pages)
build.sh                  # Container build orchestrator
index.sh                  # APK feed generator
config.env                # Build configuration
containers.json           # Container definitions
others/public-key.pem     # ECDSA public key for APK verification
network                   # Sample UCI network config
paper                     # Project whitepaper
```
