#!/bin/sh
# Generate an APK feed from built packages for serving via GitHub Pages.
# Usage: index.sh
#
# Reads APKs from $BUILD_DIR/out/<arch>/ and produces a feed directory at
# $BUILD_DIR/feed/<arch>/ with packages.adb and all APK files.

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$REPO_ROOT/config.env"

feeddir="$BUILD_DIR/feed"

PATH="$PATH:$SDK_PATH/staging_dir/host/bin:$SDK_PATH/staging_dir/hostpkg/bin"
export PATH

total_pkgs=0

for arch in $ARCHES; do
	srcdir="$BUILD_DIR/out/$arch"

	apk_files="$(ls "$srcdir"/*.apk 2>/dev/null)" || continue

	archdir="$feeddir/$arch"
	mkdir -p "$archdir"

	for apk in $apk_files; do
		cp "$apk" "$archdir/"
		total_pkgs=$((total_pkgs + 1))
	done

	echo "==> Generating index for $arch ..."
	cd "$archdir"
	apk mkndx \
		--allow-untrusted \
		--sign "$SDK_PATH/private-key.pem" \
		--output packages.adb \
		*.apk
	cd "$REPO_ROOT"
done

[ "$total_pkgs" -gt 0 ] || {
	echo "Error: no packages found" >&2
	exit 1
}

# Copy public key into feed root for easy retrieval
cp "$REPO_ROOT/others/public-key.pem" "$feeddir/"

# Generate a simple index.html for browsing
cat > "$feeddir/index.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>UXC Container Packages</title>
<style>
  body { font-family: monospace; max-width: 800px; margin: 2em auto; padding: 0 1em; }
  h1 { border-bottom: 1px solid #ccc; padding-bottom: 0.5em; }
  h2 { margin-top: 1.5em; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 0.4em 0.8em; border-bottom: 1px solid #eee; }
  a { color: #0366d6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  pre { background: #f4f4f4; padding: 1em; border-radius: 5px; overflow-x: auto; }
</style>
</head>
<body>
<h1>UXC Container Packages</h1>
<p>Lightweight OCI containers for OpenWrt, distributed as APK packages with squashfs images.</p>

<h2>Device Setup</h2>
<p>Before installing containers, set up uvol (volume management) on the device.</p>

<h3>1. Install required packages</h3>
<pre>apk add autopart uvol lvm2 partx-utils sfdisk e2fsprogs \\
    kmod-fs-ext4 kmod-fs-squashfs block-mount \\
    uxc procd-ujail kmod-veth</pre>

<h3>2. Initialize storage</h3>
<p>The device needs free disk space for LVM. For VMs, resize the image first
(<code>qemu-img resize image.img +4G</code>), then fix the GPT table on the device:</p>
<pre>sfdisk --relocate gpt-bak-std /dev/vda</pre>
<p>Reboot after installing <code>autopart</code> &mdash; it will create the LVM partition automatically.
Then set up the metadata volume:</p>
<pre>uvol create .meta 4194304 rw
uvol up .meta
mkdir -p /tmp/run/uvol/.meta/apk
ln -sf ../../tmp/run/uvol/.meta/apk /lib/apk/db-uvol
touch /lib/apk/db-uvol/world</pre>

<h3>3. Add the container feed</h3>
<pre># Download the public key
uclient-fetch -O /etc/apk/keys/uxc-public.pem $FEED_URL/public-key.pem

# Add the feed (replace ARCH with your device architecture, e.g. aarch64_generic)
echo "$FEED_URL/ARCH/packages.adb" >> /etc/apk/repositories
apk update</pre>

<h3>4. Install a container</h3>
<pre>apk add container-alpine
uxc list
uxc start alpine</pre>

<h2>Packages</h2>
HTMLEOF

for arch in $ARCHES; do
	archdir="$feeddir/$arch"
	[ -d "$archdir" ] || continue

	cat >> "$feeddir/index.html" <<HTMLEOF
<h3>$arch</h3>
<p>Feed URL: <code>$FEED_URL/$arch/packages.adb</code></p>
<table>
<tr><th>Package</th><th>Size</th></tr>
HTMLEOF

	for apk in "$archdir"/*.apk; do
		fname="$(basename "$apk")"
		fsize="$(ls -lh "$apk" | awk '{print $5}')"
		echo "<tr><td><a href=\"$arch/$fname\">$fname</a></td><td>$fsize</td></tr>" >> "$feeddir/index.html"
	done

	echo "</table>" >> "$feeddir/index.html"
done

cat >> "$feeddir/index.html" <<'HTMLEOF'

<h2>Public Key</h2>
<p><a href="public-key.pem">public-key.pem</a> (ECDSA P-256)</p>
</body>
</html>
HTMLEOF

echo "==> Feed ready: $feeddir/ ($total_pkgs packages across: $ARCHES)"
