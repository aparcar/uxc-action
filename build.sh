#!/bin/sh
# Orchestrator: build all containers from containers.json for all architectures
# Usage: build.sh [containers.json]

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$REPO_ROOT/config.env"

list="${1:-$REPO_ROOT/containers.json}"

[ -f "$list" ] || {
	echo "Error: container list not found: $list" >&2
	exit 1
}

count=$(jq '.containers | length' "$list")
failed=0
built=0

for arch in $ARCHES; do
	mkdir -p "$BUILD_DIR/out/$arch"

	i=0
	while [ "$i" -lt "$count" ]; do
		name=$(jq -r ".containers[$i].name" "$list")
		version=$(jq -r ".containers[$i].version" "$list")
		origin=$(jq -r ".containers[$i].origin" "$list")
		ports=$(jq -r ".containers[$i].ports // [] | join(\",\")" "$list")
		caps=$(jq -r ".containers[$i].caps // [] | join(\",\")" "$list")
		allow_new_privs=$(jq -r ".containers[$i].allow_new_privs // false" "$list")
		network=$(jq -r ".containers[$i].network // \"dedicated\"" "$list")

		echo ""
		echo "================================================================"
		echo "  Building: $name ($version) for $arch from $origin"
		echo "================================================================"

		_extra_args=""
		[ -n "$ports" ] && _extra_args="$_extra_args --ports $ports"
		[ -n "$caps" ] && _extra_args="$_extra_args --caps $caps"
		[ "$allow_new_privs" = "true" ] && _extra_args="$_extra_args --allow-new-privs"
		[ "$network" != "dedicated" ] && _extra_args="$_extra_args --network $network"

		if "$REPO_ROOT/mkpkg.sh" \
			--from-docker "$origin" \
			--arch "$arch" \
			--sdk-path "$SDK_PATH" \
			--output-dir "$BUILD_DIR/out/$arch" \
			--build-dir "$BUILD_DIR/$arch/$name" \
			$_extra_args \
			"$name" "$version"; then
			built=$((built + 1))
		else
			echo "ERROR: build failed for $name ($arch)" >&2
			failed=$((failed + 1))
		fi

		i=$((i + 1))
	done
done

echo ""
echo "================================================================"
echo "  Build complete: $built succeeded, $failed failed"
echo "================================================================"

if [ "$built" -gt 0 ]; then
	echo ""
	echo "Packages:"
	ls -lh "$BUILD_DIR/out/"*/*.apk 2>/dev/null || true
fi

[ "$failed" -eq 0 ]
