#!/bin/sh
# mkpkg.sh — Unified UXC container packager
#
# Converts Docker images to UXC-compatible APK packages for OpenWrt,
# or packages pre-existing container file trees.
#
# Usage:
#   mkpkg.sh --from-docker <url> [OPTIONS] <name> <version>
#   mkpkg.sh --from-dir <dir>    [OPTIONS] <name> <version>

set -e

# ---- Constants ----

DEFAULT_CAPS='["CAP_AUDIT_WRITE","CAP_KILL","CAP_NET_BIND_SERVICE"]'
DEFAULT_OVERLAY_SIZE="50M"

# ---- Utility Functions ----

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

usage() {
	cat >&2 <<'EOF'
Usage: mkpkg.sh --from-docker <url> [OPTIONS] <name> <version>
       mkpkg.sh --from-dir <dir>    [OPTIONS] <name> <version>

Modes:
  --from-docker <url>     Pull Docker image, convert to squashfs, and package
  --from-dir <dir>        Package from pre-existing file tree

Options:
  --arch <arch>           Target architecture (default: aarch64)
  --sdk-path <path>       OpenWrt SDK path (default: $SDK_PATH or /usr/src/lede)
  --sign-key <path>       Signing key path (default: <sdk-path>/private-key.pem)
  --output-dir <dir>      Output directory for .apk (default: .)
  --build-dir <dir>       Intermediate build directory (default: auto tmpdir)
  --origin <url>          Origin URL for APK metadata
  --caps <c1,c2,...>      Additional capabilities beyond defaults
  --caps-file <file>      JSON file replacing default capability list
  --no-network            Skip UCI network setup in postinst
  --ports <mapping>       Port forwards: host_port:container_port/proto,...
                          Example: 80:80/tcp,53:53/udp
  --overlay-path <path>   Persistent write overlay path
  --overlay-size <size>   Temp overlay size (default: 50M)
  --maintainer <string>   Package maintainer
  -h, --help              Show this help
EOF
	exit 1
}

check_deps() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
	done
}

_tmpdir=""
cleanup() {
	[ -n "$_tmpdir" ] && rm -rf "$_tmpdir"
}

make_tmpdir() {
	if [ -z "$_tmpdir" ]; then
		_tmpdir="$(mktemp -d)"
		trap cleanup EXIT
	fi
}

# ---- Docker Pipeline Functions ----

arch_to_platform() {
	case "$1" in
		aarch64*)  echo "linux/arm64" ;;
		arm*)      echo "linux/arm/v7" ;;
		x86_64*)   echo "linux/amd64" ;;
		*)         echo "linux/amd64" ;;
	esac
}

pull_and_export() {
	_pe_origin="$1"
	_pe_outtar="$2"

	_pe_platform="$(arch_to_platform "$OPT_ARCH")"
	log "Pulling $_pe_origin (platform: $_pe_platform) ..."
	_pe_fimg="$(podman pull --platform "$_pe_platform" "$_pe_origin")"

	log "Exporting filesystem ..."
	_pe_cimg="$(podman create "$_pe_fimg")"
	podman export --output="$_pe_outtar" "$_pe_cimg"
	podman rm "$_pe_cimg" >/dev/null 2>&1 || true

	# Return image ID for later inspection
	PULLED_IMAGE="$_pe_fimg"
}

make_squashfs() {
	_ms_tar="$1"
	_ms_outdir="$2"

	log "Creating squashfs ..."
	_ms_rootfs="$_ms_outdir/rootfs"
	mkdir -p "$_ms_rootfs"
	tar -C "$_ms_rootfs" -xf "$_ms_tar"
	mksquashfs "$_ms_rootfs" "$_ms_outdir/image.squashfs" -comp xz -no-progress

	VOLUME_HASH="$(shasum -a 256 "$_ms_outdir/image.squashfs" | cut -d' ' -f1)"
	SQUASHFS_PATH="$_ms_outdir/image.squashfs"
}

extract_image_metadata() {
	_ei_image="$1"

	log "Extracting image metadata ..."
	# Write inspect output to a file to avoid shell mangling of backslashes
	_ei_inspect_file="$_tmpdir/inspect.json"
	podman inspect "$_ei_image" > "$_ei_inspect_file" 2>/dev/null || echo "[{}]" > "$_ei_inspect_file"

	# Merge Entrypoint + Cmd (Docker execution semantics)
	IMG_ARGS="$(jq -c '
		.[0].Config |
		((.Entrypoint // []) + (.Cmd // [])) |
		if length == 0 then ["sh"] else . end
	' < "$_ei_inspect_file")"

	# Environment variables
	IMG_ENV="$(jq -c '
		.[0].Config.Env //
		["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "TERM=xterm"]
	' < "$_ei_inspect_file")"

	# Working directory
	IMG_CWD="$(jq -r '.[0].Config.WorkingDir // "/"' < "$_ei_inspect_file")"
	[ -z "$IMG_CWD" ] && IMG_CWD="/"

	# User (handle numeric, uid:gid, or default to 0:0)
	_ei_user="$(jq -r '.[0].Config.User // ""' < "$_ei_inspect_file")"
	case "$_ei_user" in
		*:*)
			IMG_UID="$(echo "$_ei_user" | cut -d: -f1)"
			IMG_GID="$(echo "$_ei_user" | cut -d: -f2)"
			;;
		""|0)
			IMG_UID=0
			IMG_GID=0
			;;
		*[!0-9]*)
			log "Warning: non-numeric user '$_ei_user', defaulting to root"
			IMG_UID=0
			IMG_GID=0
			;;
		*)
			IMG_UID="$_ei_user"
			IMG_GID=0
			;;
	esac
}

generate_oci_config() {
	_gc_name="$1"
	_gc_hash="$2"
	_gc_caps="$3"
	_gc_outfile="$4"

	jq -n \
		--argjson args "$IMG_ARGS" \
		--argjson env "$IMG_ENV" \
		--argjson caps "$_gc_caps" \
		--arg hash "$_gc_hash" \
		--arg hostname "$_gc_name" \
		--arg cwd "$IMG_CWD" \
		--argjson uid "$IMG_UID" \
		--argjson gid "$IMG_GID" \
		'{
			ociVersion: "1.0.0",
			process: {
				terminal: true,
				user: { uid: $uid, gid: $gid },
				args: $args,
				env: $env,
				cwd: $cwd,
				capabilities: {
					bounding: $caps,
					effective: $caps,
					inheritable: $caps,
					permitted: $caps,
					ambient: $caps
				},
				rlimits: [{ type: "RLIMIT_NOFILE", hard: 1024, soft: 1024 }],
				noNewPrivileges: true
			},
			root: {
				path: ("/tmp/run/uvol/" + $hash),
				readonly: false
			},
			hostname: $hostname,
			mounts: [{
				destination: "/run",
				type: "tmpfs",
				source: "tmpfs",
				options: ["nosuid", "strictatime", "mode=755", "size=65536k"]
			}],
			linux: {
				resources: {
					devices: [{ allow: false, access: "rwm" }]
				},
				namespaces: [
					{ type: "pid" },
					{ type: "network" },
					{ type: "ipc" },
					{ type: "uts" },
					{ type: "mount" }
				],
				maskedPaths: [
					"/proc/acpi", "/proc/asound", "/proc/kcore", "/proc/keys",
					"/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats",
					"/proc/sched_debug", "/sys/firmware", "/proc/scsi"
				],
				readonlyPaths: [
					"/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys",
					"/proc/sysrq-trigger"
				]
			}
		}' > "$_gc_outfile"
}

generate_uxc_metadata() {
	_gm_name="$1"
	_gm_hash="$2"
	_gm_overlay_path="$3"
	_gm_overlay_size="$4"
	_gm_outfile="$5"

	if [ -n "$_gm_overlay_path" ]; then
		jq -n \
			--arg name "$_gm_name" \
			--arg path "/usr/share/containers/$_gm_name/" \
			--arg hash "$_gm_hash" \
			--arg overlay "$_gm_overlay_path" \
			'{
				name: $name,
				path: $path,
				autostart: true,
				"write-overlay-path": $overlay,
				volumes: [$hash],
				network: {
					host0: { type: "bridged", bridge: "br-virt" }
				}
			}' > "$_gm_outfile"
	else
		jq -n \
			--arg name "$_gm_name" \
			--arg path "/usr/share/containers/$_gm_name/" \
			--arg hash "$_gm_hash" \
			--arg size "$_gm_overlay_size" \
			'{
				name: $name,
				path: $path,
				autostart: true,
				"temp-overlay-size": $size,
				volumes: [$hash],
				network: {
					host0: { type: "bridged", bridge: "br-virt" }
				}
			}' > "$_gm_outfile"
	fi
}

generate_postinst() {
	_gp_name="$1"
	_gp_no_network="$2"
	_gp_outfile="$3"
	_gp_ports="$4"

	if [ "$_gp_no_network" = "1" ]; then
		cat > "$_gp_outfile" <<'EOF'
#!/bin/sh
reload_config
EOF
		return
	fi

	# Static bridge + DHCP setup (no variable expansion)
	cat > "$_gp_outfile" <<'STATIC'
#!/bin/sh

if [ "$(uci -q get network.dev_virt)" != "device" ]; then
uci batch <<EOB
set network.dev_virt='device'
set network.dev_virt.type='bridge'
set network.dev_virt.name='br-virt'
set network.virt='interface'
set network.virt.device='br-virt'
set network.virt.proto='static'
set network.virt.ipaddr='10.0.0.1'
set network.virt.netmask='255.255.255.0'
commit network
EOB
fi

if [ "$(uci -q get dhcp.virt)" != "dhcp" ]; then
uci batch <<EOB
set dhcp.virt='dhcp'
set dhcp.virt.interface='virt'
set dhcp.virt.start='8'
set dhcp.virt.limit='240'
set dhcp.virt.leasetime='12h'
set dhcp.virt.domain='virt'
set dhcp.virt.dhcpv4='server'
set dhcp.virt.dhcpv6='server'
set dhcp.virt.ra='server'
set dhcp.virt.ra_slaac='1'
add_list dhcp.virt.ra_flags='managed-config'
add_list dhcp.virt.ra_flags='other-config'
commit dhcp
EOB
fi
STATIC

	# Per-container veth setup (name is substituted)
	cat >> "$_gp_outfile" <<EOF

if [ "\$(uci -q get network.dev_$_gp_name)" != "device" ]; then
uci batch <<EOB
set network.dev_$_gp_name='device'
set network.dev_$_gp_name.type='veth'
set network.dev_$_gp_name.name="h-$_gp_name"
set network.dev_$_gp_name.peer_name="v-$_gp_name"
set network.virt_$_gp_name='interface'
set network.virt_$_gp_name.device="v-$_gp_name"
set network.virt_$_gp_name.proto='dhcp'
set network.virt_$_gp_name.jail="$_gp_name"
set network.virt_$_gp_name.jail_device='eth0'
add_list network.dev_virt.ports="h-$_gp_name"
commit network
EOB
fi

if [ "\$(uci -q get firewall.virt_zone)" != "zone" ]; then
uci batch <<EOB
set firewall.virt_zone='zone'
set firewall.virt_zone.name='virt'
set firewall.virt_zone.network='virt'
set firewall.virt_zone.input='ACCEPT'
set firewall.virt_zone.output='ACCEPT'
set firewall.virt_zone.forward='ACCEPT'
set firewall.virt_fwd_wan='forwarding'
set firewall.virt_fwd_wan.src='virt'
set firewall.virt_fwd_wan.dest='wan'
set firewall.virt_fwd_lan='forwarding'
set firewall.virt_fwd_lan.src='lan'
set firewall.virt_fwd_lan.dest='virt'
commit firewall
EOB
fi

reload_config
EOF

	# Append per-container port redirects if --ports was specified
	if [ -n "$_gp_ports" ]; then
		_gp_idx=0
		echo "$_gp_ports" | tr ',' '\n' | while IFS='/' read -r _portmap _proto; do
			_host_port="${_portmap%%:*}"
			_cont_port="${_portmap##*:}"
			_proto="${_proto:-tcp}"
			_redir_name="${_gp_name}_p${_gp_idx}"
			_gp_idx=$((_gp_idx + 1))
			cat >> "$_gp_outfile" <<REDIR
uci batch <<EOB
set firewall.${_redir_name}='redirect'
set firewall.${_redir_name}.name='${_gp_name} port ${_host_port}'
set firewall.${_redir_name}.src='lan'
set firewall.${_redir_name}.src_dport='${_host_port}'
set firewall.${_redir_name}.dest='virt'
set firewall.${_redir_name}.dest_port='${_cont_port}'
set firewall.${_redir_name}.proto='${_proto}'
set firewall.${_redir_name}.target='DNAT'
commit firewall
EOB
REDIR
		done
		echo "reload_config" >> "$_gp_outfile"
	fi
}

generate_prerm() {
	_gr_name="$1"
	_gr_outfile="$2"

	cat > "$_gr_outfile" <<EOF
#!/bin/sh
uxc kill $_gr_name 9
EOF
}

assemble_file_tree() {
	_af_name="$1"
	_af_hash="$2"
	_af_squashfs="$3"
	_af_oci_config="$4"
	_af_uxc_meta="$5"
	_af_stagedir="$6"

	mkdir -p "$_af_stagedir/etc/uxc"
	mkdir -p "$_af_stagedir/usr/share/containers/$_af_name"
	mkdir -p "$_af_stagedir/uvol"

	cp "$_af_uxc_meta" "$_af_stagedir/etc/uxc/$_af_name.json"
	cp "$_af_oci_config" "$_af_stagedir/usr/share/containers/$_af_name/config.json"
	cp "$_af_squashfs" "$_af_stagedir/uvol/$_af_hash"
}

build_apk() {
	_ba_name="$1"
	_ba_version="$2"
	_ba_arch="$3"
	_ba_filesdir="$4"
	_ba_postinst="$5"
	_ba_prerm="$6"
	_ba_outfile="$7"
	_ba_sdk_path="$8"
	_ba_sign_key="$9"
	shift 9
	_ba_origin="$1"
	_ba_maintainer="$2"

	log "Building APK: $_ba_outfile"

	fakeroot -- apk mkpkg \
		--info "name:container-$_ba_name" \
		--info "version:$_ba_version" \
		--info "description:$_ba_name container" \
		--info "arch:$_ba_arch" \
		--info "license:GPL" \
		--info "origin:$_ba_origin" \
		${_ba_maintainer:+--info "maintainer:$_ba_maintainer"} \
		--info "layer:1" \
		--files "$_ba_filesdir" \
		--output "$_ba_outfile" \
		--script "post-install:$_ba_postinst" \
		--script "pre-deinstall:$_ba_prerm" \
		--script "pre-upgrade:$_ba_prerm" \
		--sign "$_ba_sign_key"
}

# ---- Build Capabilities JSON ----

resolve_caps() {
	_rc_extra="$1"
	_rc_file="$2"

	if [ -n "$_rc_file" ]; then
		# --caps-file replaces defaults entirely
		cat "$_rc_file"
		return
	fi

	if [ -z "$_rc_extra" ]; then
		echo "$DEFAULT_CAPS"
		return
	fi

	# Merge defaults with --caps additions
	_rc_extra_json="$(echo "$_rc_extra" | tr ',' '\n' | jq -R . | jq -sc .)"
	echo "$DEFAULT_CAPS" | jq --argjson extra "$_rc_extra_json" '. + $extra | unique'
}

# ---- Mode: --from-docker ----

package_from_docker() {
	check_deps jq podman mksquashfs fakeroot apk shasum

	make_tmpdir
	_pd_workdir="$_tmpdir/work"
	mkdir -p "$_pd_workdir"

	# If a persistent build dir was requested, use it for final artifacts
	if [ -n "$OPT_BUILD_DIR" ]; then
		_pd_artifactdir="$OPT_BUILD_DIR"
		mkdir -p "$_pd_artifactdir"
	else
		_pd_artifactdir="$_pd_workdir"
	fi

	pull_and_export "$OPT_DOCKER_URL" "$_pd_workdir/rootfs.tar"
	make_squashfs "$_pd_workdir/rootfs.tar" "$_pd_workdir"

	extract_image_metadata "$PULLED_IMAGE"

	_pd_caps="$(resolve_caps "$OPT_CAPS" "$OPT_CAPS_FILE")"

	generate_oci_config "$ARG_NAME" "$VOLUME_HASH" "$_pd_caps" "$_pd_artifactdir/config.json"
	generate_uxc_metadata "$ARG_NAME" "$VOLUME_HASH" "$OPT_OVERLAY_PATH" "$OPT_OVERLAY_SIZE" "$_pd_artifactdir/$ARG_NAME.json"

	_pd_stagedir="$_pd_workdir/staging"
	assemble_file_tree "$ARG_NAME" "$VOLUME_HASH" "$SQUASHFS_PATH" \
		"$_pd_artifactdir/config.json" "$_pd_artifactdir/$ARG_NAME.json" "$_pd_stagedir"

	generate_postinst "$ARG_NAME" "$OPT_NO_NETWORK" "$_pd_workdir/postinst.sh" "$OPT_PORTS"
	generate_prerm "$ARG_NAME" "$_pd_workdir/prerm.sh"

	_pd_apk="$OPT_OUTPUT_DIR/container-${ARG_NAME}-${ARG_VERSION}.apk"
	build_apk "$ARG_NAME" "$ARG_VERSION" "$OPT_ARCH" "$_pd_stagedir" \
		"$_pd_workdir/postinst.sh" "$_pd_workdir/prerm.sh" "$_pd_apk" \
		"$OPT_SDK_PATH" "$OPT_SIGN_KEY" "$OPT_ORIGIN" "$OPT_MAINTAINER"

	log "Done: $_pd_apk (hash: $VOLUME_HASH)"
}

# ---- Mode: --from-dir ----

package_from_dir() {
	check_deps fakeroot apk

	_pf_dir="$OPT_FROM_DIR"

	# Verify expected files exist
	[ -d "$_pf_dir" ] || die "directory not found: $_pf_dir"

	# Check for at least a UXC metadata or OCI config
	_pf_found=0
	[ -f "$_pf_dir/etc/uxc/$ARG_NAME.json" ] && _pf_found=1
	[ -f "$_pf_dir/usr/share/containers/$ARG_NAME/config.json" ] && _pf_found=1
	[ "$_pf_found" = "0" ] && die "directory $_pf_dir does not contain expected UXC/OCI files for '$ARG_NAME'"

	make_tmpdir

	generate_postinst "$ARG_NAME" "$OPT_NO_NETWORK" "$_tmpdir/postinst.sh" "$OPT_PORTS"
	generate_prerm "$ARG_NAME" "$_tmpdir/prerm.sh"

	_pf_apk="$OPT_OUTPUT_DIR/container-${ARG_NAME}-${ARG_VERSION}.apk"
	build_apk "$ARG_NAME" "$ARG_VERSION" "$OPT_ARCH" "$_pf_dir" \
		"$_tmpdir/postinst.sh" "$_tmpdir/prerm.sh" "$_pf_apk" \
		"$OPT_SDK_PATH" "$OPT_SIGN_KEY" "$OPT_ORIGIN" "$OPT_MAINTAINER"

	log "Done: $_pf_apk"
}

# ---- Argument Parsing ----

OPT_DOCKER_URL=""
OPT_FROM_DIR=""
OPT_ARCH="${ARCH:-aarch64_generic}"
OPT_SDK_PATH="${SDK_PATH:-$(cd "$(dirname "$0")" && pwd)/sdk}"
OPT_SIGN_KEY=""
OPT_OUTPUT_DIR="."
OPT_BUILD_DIR=""
OPT_ORIGIN=""
OPT_CAPS=""
OPT_CAPS_FILE=""
OPT_NO_NETWORK="0"
OPT_PORTS=""
OPT_OVERLAY_PATH=""
OPT_OVERLAY_SIZE="$DEFAULT_OVERLAY_SIZE"
OPT_MAINTAINER=""
ARG_NAME=""
ARG_VERSION=""

while [ $# -gt 0 ]; do
	case "$1" in
		--from-docker)  OPT_DOCKER_URL="$2"; shift 2 ;;
		--from-dir)     OPT_FROM_DIR="$2"; shift 2 ;;
		--arch)         OPT_ARCH="$2"; shift 2 ;;
		--sdk-path)     OPT_SDK_PATH="$2"; shift 2 ;;
		--sign-key)     OPT_SIGN_KEY="$2"; shift 2 ;;
		--output-dir)   OPT_OUTPUT_DIR="$2"; shift 2 ;;
		--build-dir)    OPT_BUILD_DIR="$2"; shift 2 ;;
		--origin)       OPT_ORIGIN="$2"; shift 2 ;;
		--caps)         OPT_CAPS="$2"; shift 2 ;;
		--caps-file)    OPT_CAPS_FILE="$2"; shift 2 ;;
		--no-network)   OPT_NO_NETWORK="1"; shift ;;
		--ports)        OPT_PORTS="$2"; shift 2 ;;
		--overlay-path) OPT_OVERLAY_PATH="$2"; shift 2 ;;
		--overlay-size) OPT_OVERLAY_SIZE="$2"; shift 2 ;;
		--maintainer)   OPT_MAINTAINER="$2"; shift 2 ;;
		-h|--help)      usage ;;
		-*)             die "unknown option: $1" ;;
		*)
			if [ -z "$ARG_NAME" ]; then
				ARG_NAME="$1"
			elif [ -z "$ARG_VERSION" ]; then
				ARG_VERSION="$1"
			else
				die "unexpected argument: $1"
			fi
			shift
			;;
	esac
done

# Validate required args
[ -n "$ARG_NAME" ] || usage
[ -n "$ARG_VERSION" ] || usage
[ -n "$OPT_DOCKER_URL" ] || [ -n "$OPT_FROM_DIR" ] || die "one of --from-docker or --from-dir is required"
[ -n "$OPT_DOCKER_URL" ] && [ -n "$OPT_FROM_DIR" ] && die "--from-docker and --from-dir are mutually exclusive"

# Defaults that depend on other options
[ -z "$OPT_SIGN_KEY" ] && OPT_SIGN_KEY="$OPT_SDK_PATH/private-key.pem"
[ -z "$OPT_ORIGIN" ] && OPT_ORIGIN="${OPT_DOCKER_URL:-local}"

# Add SDK tools to PATH so check_deps can find apk, etc.
# Append (not prepend) so system tools like fakeroot are not shadowed by SDK versions.
PATH="$PATH:$OPT_SDK_PATH/staging_dir/host/bin:$OPT_SDK_PATH/staging_dir/hostpkg/bin"
export PATH

mkdir -p "$OPT_OUTPUT_DIR"

# ---- Main ----

if [ -n "$OPT_DOCKER_URL" ]; then
	package_from_docker
else
	package_from_dir
fi
