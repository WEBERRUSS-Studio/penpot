#!/usr/bin/env bash
#
# Build the images of docker-compose.prod.yaml from this working tree: first
# the module bundles (../../manage.sh build-<image>-bundle), then the images
# (./build.sh --from-bundles --version <tag>). It builds and tags, it starts
# nothing: the running stack keeps its old images until ./start-prod.sh
# recreates the containers.
#
# Usage:
#   ./build-prod.sh [image...] [options]
#
#   image              frontend | backend | exporter | mcp, repeatable
#                      (default: all four)
#   --no-bundles       skip the bundle step and take the bundles that are
#                      already in ../../bundles (the script says which version
#                      those bundles carry)
#   --version <tag>    image tag, the one compose picks by default
#                      (default: PENPOT_VERSION from the env file, else fork)
#   --env-file <file>  env file to read PENPOT_VERSION from (default: .env.prod)
#   --namespace <org>  image namespace           (default: penpotapp)
#   --project <name>   compose project, used only to name the running
#                      containers still on the previous image (penpot-prod)
#   --dry-run          print the commands, change nothing
#   -h, --help         this text
#
# A bundle carries the version of the tree it came from (git describe), and
# this script prints that version for every image it builds, so a bundle of an
# older tree is visible before it becomes an image. A build is not a rollout:
# an image tag is replaced under the running container, so the new code reaches
# the browser only after ./start-prod.sh, which is what the closing note says.
#
# Environment: PENPOT_PROD_ENV_FILE, PENPOT_PROD_PROJECT,
#              PENPOT_DOCKER_NAMESPACE, PENPOT_BUILD_VERSION
#
# Examples:
#   ./build-prod.sh                      # four images from the current tree
#   ./build-prod.sh backend --version rc1
#   ./build-prod.sh --no-bundles         # images from the existing bundles

set -euo pipefail

SELF=$(basename "$0")

usage() {
	awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# The images of the production stack, in the order the compose file names them.
DEFAULT_IMAGES=(frontend backend exporter mcp)

IMAGES=()
NAMESPACE=${PENPOT_DOCKER_NAMESPACE:-penpotapp}
VERSION=${PENPOT_BUILD_VERSION:-}
ENV_FILE=${PENPOT_PROD_ENV_FILE:-.env.prod}
PROJECT=${PENPOT_PROD_PROJECT:-penpot-prod}
BUNDLES=1
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--no-bundles)
		BUNDLES=0
		;;
	--version)
		VERSION=${2:?--version needs a value}
		shift
		;;
	--env-file)
		ENV_FILE=${2:?--env-file needs a value}
		shift
		;;
	--namespace)
		NAMESPACE=${2:?--namespace needs a value}
		shift
		;;
	--project)
		PROJECT=${2:?--project needs a value}
		shift
		;;
	--dry-run)
		DRY_RUN=1
		;;
	-*)
		echo "$SELF: unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		IMAGES+=("$1")
		;;
	esac
	shift
done

[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("${DEFAULT_IMAGES[@]}")

# Run from this directory: ./build.sh and the env file are relative to it, so
# the script works from any caller's cwd.
cd "$(cd "$(dirname "$0")" && pwd)"
REPO=$(cd ../.. && pwd)
BUNDLES_DIR=$REPO/bundles

# Read single values out of the env file rather than sourcing it: the file is
# data, not shell code. Same helper as start-prod.sh and down-prod.sh.
env_value() {
	[ -r "$ENV_FILE" ] || return 0
	sed -n "s/^[[:space:]]*${1}=//p" "$ENV_FILE" |
		tail -n 1 |
		sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'
}

if [ -z "$VERSION" ]; then
	VERSION=$(env_value PENPOT_VERSION)
fi
VERSION=${VERSION:-fork}

# The version manage.sh writes into every bundle, so the tree this build reads
# and the bundle that results from it are comparable.
source_version() {
	git -C "$REPO" describe --tags --match '*.*.*' 2>/dev/null || echo unknown
}

manage() {
	printf '%s: (cd %s && ./manage.sh %s)\n' "$SELF" "$REPO" "$*" >&2
	[ "$DRY_RUN" = 1 ] && return 0
	(cd "$REPO" && ./manage.sh "$@")
}

SOURCE=$(source_version)
DIRTY=$(git -C "$REPO" status --porcelain)

echo "$SELF: building from $SOURCE ($(git -C "$REPO" branch --show-current))" >&2
[ -n "$DIRTY" ] && echo "$SELF: note: the working tree has uncommitted changes" >&2
tags=()
for image in "${IMAGES[@]}"; do tags+=("$NAMESPACE/$image:$VERSION"); done
echo "$SELF: images: ${tags[*]}" >&2
echo "$SELF: the running stack is untouched by this build" >&2

if [ "$BUNDLES" = 1 ]; then
	for image in "${IMAGES[@]}"; do
		manage "build-$image-bundle" || {
			echo "$SELF: bundle $image failed, no image built" >&2
			exit 1
		}
	done
fi

# The version each bundle carries. With --no-bundles this is the whole point:
# a bundle from an older tree builds an image of that older tree, and the tag
# says nothing about it.
STALE=0
for image in "${IMAGES[@]}"; do
	if [ ! -f "$BUNDLES_DIR/$image/version.txt" ]; then
		echo "$SELF: no bundle for $image in $BUNDLES_DIR" >&2
		echo "  drop --no-bundles, or run: ./manage.sh build-$image-bundle" >&2
		exit 1
	fi

	bundle_version=$(cat "$BUNDLES_DIR/$image/version.txt")
	if [ "$bundle_version" = "$SOURCE" ]; then
		echo "$SELF: bundle $image = $bundle_version" >&2
	else
		echo "$SELF: bundle $image = $bundle_version, this tree is $SOURCE" >&2
		STALE=1
	fi
done

if [ "$STALE" = 1 ]; then
	echo "$SELF: warning: those images will carry the bundle versions above," >&2
	echo "  not $SOURCE. Build from this tree: ./build-prod.sh ${IMAGES[*]}" >&2
fi

build_args=("${IMAGES[@]}" --from-bundles --version "$VERSION"
	--namespace "$NAMESPACE")
if [ "$DRY_RUN" = 1 ]; then
	build_args+=(--dry-run)
fi

./build.sh "${build_args[@]}" || {
	echo "$SELF: image build failed" >&2
	exit 1
}

if [ "$DRY_RUN" = 1 ]; then
	echo "$SELF: dry-run, nothing built" >&2
	exit 0
fi

# Built versus running. The tag is replaced under the running container, so a
# container that already names this tag still serves the previous image.
echo "$SELF: built:" >&2
for image in "${IMAGES[@]}"; do
	tag=$NAMESPACE/$image:$VERSION
	created=$(docker image inspect --format '{{.Created}}' "$tag" 2>/dev/null ||
		echo unknown)
	echo "  $tag  $created" >&2
done

running=$(docker ps --filter "name=${PROJECT}-" --format '{{.Image}}' |
	sort -u |
	tr '\n' ' ')
if [ -n "${running// /}" ]; then
	echo "$SELF: running now: $running" >&2
	echo "$SELF: those containers run the image of that tag from before this" >&2
	echo "  build; ./start-prod.sh recreates them" >&2
fi
