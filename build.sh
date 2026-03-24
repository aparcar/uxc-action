#!/bin/sh
# Orchestrator: build all containers from containers.yaml for all architectures
# Usage: build.sh [containers.yaml]

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$REPO_ROOT/config.env"

list="${1:-$REPO_ROOT/containers.yaml}"

[ -f "$list" ] || {
	echo "Error: container list not found: $list" >&2
	exit 1
}

command -v yq >/dev/null 2>&1 || {
	echo "Error: yq is required (https://github.com/mikefarah/yq)" >&2
	exit 1
}

count=$(yq '.containers | length' "$list")
failed=0
built=0

for arch in $ARCHES; do
	mkdir -p "$BUILD_DIR/out/$arch"

	i=0
	while [ "$i" -lt "$count" ]; do
		name=$(yq ".containers[$i].name" "$list")
		version=$(yq ".containers[$i].version" "$list")
		origin=$(yq ".containers[$i].origin" "$list")
		ports=$(yq ".containers[$i].ports // [] | join(\",\")" "$list")
		caps=$(yq ".containers[$i].caps // [] | join(\",\")" "$list")

		echo ""
		echo "================================================================"
		echo "  Building: $name ($version) for $arch from $origin"
		echo "================================================================"

		_extra_args=""
		[ -n "$ports" ] && _extra_args="$_extra_args --ports $ports"
		[ -n "$caps" ] && _extra_args="$_extra_args --caps $caps"

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
