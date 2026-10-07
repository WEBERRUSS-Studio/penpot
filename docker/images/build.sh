#!/usr/bin/env bash
#
# Build a Penpot docker image.
#
# A local build needs no docker account:
#   - the result is loaded into the local docker image store, never pushed
#   - the build targets the architecture of this host, so no QEMU emulation
#     and no helper image (tonistiigi/binfmt, moby/buildkit) is pulled
#   - the base images are the public upstream images. dhi.io answers 401 on
#     anonymous pulls, so the hardened bases cannot be used without an account.
#
# Usage:
#   ./build.sh [image...] [options] [-- extra buildx args]
#
#   image              backend | frontend | exporter | media-processor | mcp
#                      | storybook, repeatable  (default: backend)
#   --all              every image that has a Dockerfile here
#   --local            build and load into the local image store (default)
#   --push             build and push to the registry (needs an account)
#   --from-bundles     stage ../../bundles/<image>/ into ./bundle-<image>/ and
#                      pass it as BUNDLE_PATH (see ./manage.sh build-bundle)
#   --bundles <dir>    directory holding the module bundles
#                      (default: ../../bundles)
#   --public-bases     build with the public base images (default with --local)
#   --hardened         build with the dhi.io base images, as the release
#                      pipeline does (default with --push, needs an account)
#   --platform <list>  comma separated target platforms
#                      (default: the platform of this host)
#   --tags <list>      extra tags, comma separated
#   --namespace <org>  image namespace            (default: penpotapp)
#   --version <tag>    main tag                   (default: latest)
#   --builder <name>   buildx builder to use      (default: the active one)
#   --dry-run          print the build command, change nothing
#   --verbose          print every command
#   -h, --help         this text
#
# Environment: PENPOT_DOCKER_NAMESPACE, PENPOT_BUILD_PLATFORM,
#              PENPOT_BUILD_VERSION, PENPOT_BUILD_TAGS, PENPOT_BUILDX_BUILDER,
#              PENPOT_BUILD_BASES (public | hardened), PENPOT_BUNDLES_DIR
#
# Examples:
#   ./manage.sh build-bundle
#   ./build.sh --all --from-bundles --version fork
#   PENPOT_VERSION=fork docker compose -p penpot -f docker-compose.yaml up -d
#
#   ./build.sh frontend                       # one image, host architecture
#   ./build.sh backend --push --platform linux/amd64,linux/arm64

set -euo pipefail

SELF=$(basename "$0")

usage() {
	awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

IMAGES=()
OUTPUT="type=docker"
PUSH=0
BASES=${PENPOT_BUILD_BASES:-}
PLATFORM=""
EXTRA_TAGS=${PENPOT_BUILD_TAGS:-}
NAMESPACE=${PENPOT_DOCKER_NAMESPACE:-penpotapp}
VERSION=${PENPOT_BUILD_VERSION:-latest}
BUILDER=${PENPOT_BUILDX_BUILDER:-}
FROM_BUNDLES=0
BUNDLES_DIR=${PENPOT_BUNDLES_DIR:-../../bundles}
ALL=0
DRY_RUN=0
TMP_FILES=()

cleanup() {
	if [ ${#TMP_FILES[@]} -gt 0 ]; then
		rm -f "${TMP_FILES[@]}"
	fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--all)
		ALL=1
		;;
	--local)
		OUTPUT="type=docker"
		PUSH=0
		;;
	--push)
		OUTPUT="type=registry"
		PUSH=1
		;;
	--from-bundles)
		FROM_BUNDLES=1
		;;
	--bundles)
		BUNDLES_DIR=${2:?--bundles needs a value}
		shift
		;;
	--public-bases)
		BASES=public
		;;
	--hardened)
		BASES=hardened
		;;
	--platform)
		PLATFORM=${2:?--platform needs a value}
		shift
		;;
	--tags)
		EXTRA_TAGS=${2:?--tags needs a value}
		shift
		;;
	--namespace)
		NAMESPACE=${2:?--namespace needs a value}
		shift
		;;
	--version)
		VERSION=${2:?--version needs a value}
		shift
		;;
	--builder)
		BUILDER=${2:?--builder needs a value}
		shift
		;;
	--dry-run)
		DRY_RUN=1
		;;
	--verbose | -v)
		set -x
		;;
	--)
		shift
		break
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

EXTRA_ARGS=("$@")

# Without an explicit choice: local builds take the public bases, a push keeps
# the hardened bases of the release pipeline.
if [ -z "$BASES" ]; then
	if [ "$PUSH" = 1 ]; then BASES=hardened; else BASES=public; fi
fi

if [ "$ALL" = 1 ]; then
	for f in Dockerfile.*; do
		name=${f#Dockerfile.}
		case " ${IMAGES[*]-} " in
		*" $name "*) ;;
		*) IMAGES+=("$name") ;;
		esac
	done
fi

if [ ${#IMAGES[@]} -eq 0 ]; then
	IMAGES=(backend)
fi

# dhi.io is Datadog's hardened image registry and rejects anonymous pulls.
# The public upstream images are the same distributions without the hardening,
# and pull without an account. Version and Debian flavour are kept: the
# -debian13 images map to the -trixie variants, because the plain tags of the
# official images are an older Debian and lack packages these Dockerfiles
# install (libzip5, xfonts-cyrillic, ...). The digest is dropped because the
# public images have different digests.
rewrite_bases() {
	sed -E '
        s#^FROM dhi\.io/node:([0-9.]+)-debian13(-dev)?(@[a-z0-9:.]+)?#FROM node:\1-trixie#
        s#^FROM dhi\.io/nginx:([0-9.]+)-alpine[0-9.]*(@[a-z0-9:.]+)?#FROM nginx:\1-alpine#
        s#^FROM dhi\.io/nginx:([0-9.]+)-debian13(-dev)?(@[a-z0-9:.]+)?#FROM nginx:\1-trixie#
        s#^FROM dhi\.io/debian-base:([a-z0-9]+)-debian13(-dev)?(@[a-z0-9:.]+)?#FROM debian:\1#
    ' "$1"
}

# The architecture of this host. A build for it needs no emulation, so no
# helper image is pulled and no account is needed for that pull either.
host_platform() {
	local arch
	arch=$(docker info --format '{{.Architecture}}' 2>/dev/null || true)
	[ -z "$arch" ] && arch=$(uname -m)
	case "$arch" in
	x86_64 | amd64) echo "linux/amd64" ;;
	aarch64 | arm64) echo "linux/arm64" ;;
	armv7l | arm) echo "linux/arm/v7" ;;
	ppc64le) echo "linux/ppc64le" ;;
	s390x) echo "linux/s390x" ;;
	riscv64) echo "linux/riscv64" ;;
	*) echo "linux/$arch" ;;
	esac
}

NATIVE_PLATFORM=$(host_platform)
PLATFORM=$(printf '%s' "${PLATFORM:-$NATIVE_PLATFORM}" | tr -d '[:space:]')

PLATFORM_COUNT=0
NEEDS_EMULATION=0
for platform in ${PLATFORM//,/ }; do
	PLATFORM_COUNT=$((PLATFORM_COUNT + 1))
	[ "$platform" = "$NATIVE_PLATFORM" ] || NEEDS_EMULATION=1
done

# The local image store holds one architecture per tag. Only a registry
# export can carry a multi-architecture image.
if [ "$OUTPUT" = "type=docker" ] && [ "$PLATFORM_COUNT" -gt 1 ]; then
	echo "$SELF: cannot load a multi-architecture image locally." >&2
	echo "  use --push for $PLATFORM, or build one platform at a time" >&2
	echo "  (the platform of this host is $NATIVE_PLATFORM)" >&2
	exit 1
fi

# Cross-architecture builds need the docker-container driver and QEMU
# handlers. Both are pulled only when they are really needed, and never on a
# dry run.
if [ "$NEEDS_EMULATION" = 1 ]; then
	if [ -z "$BUILDER" ]; then
		BUILDER=penpot
		if [ "$DRY_RUN" = 0 ] && ! docker buildx inspect penpot >/dev/null 2>&1; then
			docker buildx create --name penpot --driver docker-container >/dev/null
		fi
	fi

	if [ "$DRY_RUN" = 0 ]; then
		if ! docker run --privileged --rm tonistiigi/binfmt --install all >/dev/null; then
			echo "$SELF: warning: could not install the QEMU handlers." >&2
			echo "  Pulling tonistiigi/binfmt needs network access, and an anonymous" >&2
			echo "  pull can be rate limited. Run 'docker login', or build for" >&2
			echo "  $NATIVE_PLATFORM only." >&2
		fi
	fi
fi

if [ "$PUSH" = 1 ]; then
	echo "$SELF: pushing to $NAMESPACE/<image> requires an account: docker login ${NAMESPACE%%/*}" >&2
fi

# Stage a module bundle into the build context, the same way manage.sh does
# before it builds a release image.
stage_bundle() {
	local image=$1
	local src=$BUNDLES_DIR/$image

	if [ ! -d "$src" ]; then
		echo "$SELF: no bundle for $image at $src" >&2
		{
			if [ -d "$BUNDLES_DIR" ]; then
				for d in "$BUNDLES_DIR"/*; do printf '%s ' "${d##*/}"; done
				printf '\n' >&2
			fi
		}
		echo "  build one first: ./manage.sh build-bundle  or  ./manage.sh build-${image}-bundle" >&2
		return 1
	fi

	local bundle_dir="bundle-$image"

	if [ "$DRY_RUN" = 0 ]; then
		rsync -a --delete "$src/" "$bundle_dir/"
	fi

	if [ -f "$src/version.txt" ]; then
		echo "$SELF: bundle $src -> $bundle_dir (version $(cat "$src/version.txt"))" >&2
	else
		echo "$SELF: bundle $src -> $bundle_dir" >&2
	fi
}

build_one() {
	local image=$1
	local dockerfile="Dockerfile.$image"

	if [ ! -f "$dockerfile" ]; then
		echo "$SELF: no $dockerfile in $(pwd)" >&2
		return 1
	fi

	local -a cmd_extra=()
	if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
		cmd_extra=("${EXTRA_ARGS[@]}")
	fi

	if [ "$FROM_BUNDLES" = 1 ]; then
		stage_bundle "$image" || return 1
		cmd_extra+=(--build-arg "BUNDLE_PATH=./bundle-$image/")
	fi

	if [ "$BASES" = public ]; then
		local tmp
		tmp=$(mktemp "${TMPDIR:-/tmp}/Dockerfile.$image.public.XXXXXX")
		TMP_FILES+=("$tmp")
		rewrite_bases "$dockerfile" >"$tmp"

		if grep -q '^FROM dhi\.io/' "$tmp"; then
			echo "$SELF: no public equivalent for these base images:" >&2
			grep '^FROM dhi\.io/' "$tmp" >&2
			echo "  add a rule to rewrite_bases() in $SELF, or build with --hardened" >&2
			return 1
		fi

		dockerfile=$tmp
	fi

	local docker_image="$NAMESPACE/$image"

	if [ "$OUTPUT" = "type=docker" ] &&
		docker image inspect "$docker_image:$VERSION" >/dev/null 2>&1; then
		echo "$SELF: note: $docker_image:$VERSION exists locally and will be replaced" >&2
	fi

	local -a cmd=(docker buildx build --output "$OUTPUT" --platform "$PLATFORM")
	cmd+=(-t "$docker_image:$VERSION")

	if [ -n "$EXTRA_TAGS" ]; then
		for tag in ${EXTRA_TAGS//,/ }; do
			[ -n "$tag" ] && cmd+=(-t "$docker_image:$tag")
		done
	fi

	if [ -n "$BUILDER" ]; then
		cmd+=(--builder "$BUILDER")
	fi

	cmd+=(-f "$dockerfile" .)

	if [ ${#cmd_extra[@]} -gt 0 ]; then
		cmd+=("${cmd_extra[@]}")
	fi

	echo "$SELF: $image -> $docker_image:$VERSION" >&2
	echo "$SELF: output=$OUTPUT platform=$PLATFORM bases=$BASES" >&2
	grep '^FROM' "$dockerfile" | sed 's/^/  /' >&2

	if [ "$DRY_RUN" = 1 ]; then
		printf '%s\n' "${cmd[@]}"
		return 0
	fi

	"${cmd[@]}"
}

STATUS=0

for image in "${IMAGES[@]}"; do
	build_one "$image" || STATUS=1
done

exit "$STATUS"
