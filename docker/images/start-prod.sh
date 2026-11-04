#!/usr/bin/env bash
# FORK ONLY (WEBERRUSS-Studio) -- never PR these files to penpot/penpot.
#
# Start the production stack of docker-compose.prod.yaml with the images that
# were built from this repository by ./build.sh.
#
# First run:
#   cp .env.prod.example .env.prod     # fill in domain, secret key, SMTP
#   ./start-prod.sh --build            # bundles, images, then start
#
# Usage:
#   ./start-prod.sh [options]                 start the stack (up -d)
#   ./start-prod.sh <subcommand> [args...]    pass anything else straight to
#                                             docker compose: ps, logs -f,
#                                             restart, stop, down, exec ...
#
#   --build            build the bundles and the images before starting
#                      (delegates to ./build-prod.sh: the four module bundles
#                      and the four images). Not docker compose --build: this
#                      compose file has no build sections.
#   --version <tag>    image tag to start       (default: PENPOT_VERSION, fork)
#   --namespace <org>  image namespace     (default: PENPOT_DOCKER_NAMESPACE
#                      from the env file, else penpotapp)
#   --env-file <file>  env file                (default: .env.prod)
#   --project <name>   compose project name    (default: penpot-prod)
#   --no-check         skip the env file and image checks
#   --dry-run          print the commands, change nothing
#   -h, --help         this text
#
# By default the two data volumes are named after the project, so a different
# --project starts an empty database and an empty assets volume next to the
# running instance instead of reusing them. To start on existing data, name
# those volumes in the env file (PENPOT_POSTGRES_VOLUME, PENPOT_ASSETS_VOLUME);
# then the project name no longer decides where the data is.
#
# Environment: PENPOT_PROD_ENV_FILE, PENPOT_PROD_PROJECT, PENPOT_BUILD_VERSION,
#              PENPOT_DOCKER_NAMESPACE

set -euo pipefail

SELF=$(basename "$0")

usage() {
	awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

COMPOSE_FILE=docker-compose.prod.yaml
ENV_FILE=${PENPOT_PROD_ENV_FILE:-.env.prod}
PROJECT=${PENPOT_PROD_PROJECT:-penpot-prod}
NAMESPACE=${PENPOT_DOCKER_NAMESPACE:-}
VERSION=${PENPOT_BUILD_VERSION:-}
BUILD=0
CHECK=1
DRY_RUN=0
ARGS=()

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--build)
		BUILD=1
		;;
	--version)
		VERSION=${2:?--version needs a value}
		shift
		;;
	--namespace)
		NAMESPACE=${2:?--namespace needs a value}
		shift
		;;
	--env-file)
		ENV_FILE=${2:?--env-file needs a value}
		shift
		;;
	--project)
		PROJECT=${2:?--project needs a value}
		shift
		;;
	--no-check)
		CHECK=0
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
		# A subcommand and everything behind it go to docker compose.
		ARGS=("$@")
		break
		;;
	esac
	shift
done

# Run from this directory: the compose file, the env file and ./build.sh are
# all relative to it, so the script works from any caller's cwd.
cd "$(cd "$(dirname "$0")" && pwd)"

# The env file is what docker compose substitutes into the compose file, and
# the same file holds PENPOT_VERSION. Read single values out of it rather than
# sourcing it: the file is data, not shell code.
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

# Namespace and version arrive from the same place, so the image this script
# checks and the image the compose file starts cannot drift apart.
if [ -z "$NAMESPACE" ]; then
	NAMESPACE=$(env_value PENPOT_DOCKER_NAMESPACE)
fi
NAMESPACE=${NAMESPACE:-penpotapp}

# The data volumes. The env file can name existing ones; without it compose
# falls back to the <project>_<volume> convention, which this script mirrors
# here so it can report and check what the stack is about to start on.
PG_VOLUME=$(env_value PENPOT_POSTGRES_VOLUME)
ASSETS_VOLUME=$(env_value PENPOT_ASSETS_VOLUME)
PG_VOL_SET=${PG_VOLUME:+1}
ASSETS_VOL_SET=${ASSETS_VOLUME:+1}
: "${PG_VOLUME:=${PROJECT}_penpot_postgres_data}"
: "${ASSETS_VOLUME:=${PROJECT}_penpot_assets}"

compose() {
	local -a cmd=(docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE")

	if [ "$DRY_RUN" = 1 ]; then
		printf '%s ' "${cmd[@]}"
		printf '%s\n' "$*"
		return 0
	fi

	"${cmd[@]}" "$@"
}

# The keys the compose file marks with ":?", so compose would abort on an
# empty value. Checked here because the compose message names only the key.
check_env() {
	if [ ! -r "$ENV_FILE" ]; then
		echo "$SELF: cannot read $ENV_FILE" >&2
		echo "  cp .env.prod.example $ENV_FILE, then fill in the values" >&2
		return 1
	fi

	local -a missing=()
	local key
	for key in PENPOT_PUBLIC_URI PENPOT_SECRET_KEY DB_PASSWORD SMTP_FROM SMTP_HOST; do
		if [ -z "$(env_value "$key")" ]; then
			missing+=("$key")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		echo "$SELF: $ENV_FILE holds no value for: ${missing[*]}" >&2
		return 1
	fi

	if grep -qiE '^[[:space:]]*(PENPOT_SECRET_KEY|DB_PASSWORD)=replace-me' "$ENV_FILE"; then
		echo "$SELF: $ENV_FILE still holds the placeholder values from the example." >&2
		echo "  Set a real key and password: python3 -c \"import secrets; print(secrets.token_urlsafe(64))\"" >&2
		return 1
	fi
}

# A named data volume that does not exist yet means compose creates an empty
# one: the instance starts with no accounts and no files. A name from the env
# file is a deliberate choice, so a miss there is an error; the default name of
# a first run is only a warning.
check_volume() {
	local volume=$1 explicit=$2

	if docker volume inspect "$volume" >/dev/null 2>&1; then
		return 0
	fi

	if [ "$explicit" = 1 ]; then
		echo "$SELF: volume $volume does not exist, $ENV_FILE names it anyway." >&2
		echo "  existing data:  docker volume ls | grep -i penpot" >&2
		echo "  fix the name, or start empty with --no-check" >&2
		return 1
	fi

	echo "$SELF: warning: volume $volume does not exist yet." >&2
	echo "  The stack starts empty: no accounts to log in with." >&2
	echo "  Existing data:  docker volume ls | grep -i penpot" >&2
	echo "  Reuse it: set PENPOT_POSTGRES_VOLUME / PENPOT_ASSETS_VOLUME in $ENV_FILE" >&2
}

check_volumes() {
	check_volume "$PG_VOLUME" "$PG_VOL_SET" || return 1
	check_volume "$ASSETS_VOLUME" "$ASSETS_VOL_SET" || return 1
}

# The images this stack expects, and which of them are built locally. The admin
# console has no Dockerfile here and comes from the registry.
check_images() {
	local -a missing=()
	local image
	for image in frontend backend exporter mcp; do
		if ! docker image inspect "$NAMESPACE/$image:$VERSION" >/dev/null 2>&1; then
			missing+=("$NAMESPACE/$image:$VERSION")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		echo "$SELF: no local image for: ${missing[*]}" >&2
		echo "  build them:  ./start-prod.sh --build"
		echo "  or by hand:  ./build-prod.sh --version $VERSION" >&2
		return 1
	fi
}

build_images() {
	if [ "$DRY_RUN" = 1 ]; then
		echo "./build-prod.sh --version $VERSION --namespace $NAMESPACE --env-file $ENV_FILE --project $PROJECT"
		return 0
	fi

	./build-prod.sh --version "$VERSION" --namespace "$NAMESPACE" \
		--env-file "$ENV_FILE" --project "$PROJECT"
}

if [ ${#ARGS[@]} -eq 0 ]; then
	CMD=(up -d)
else
	CMD=("${ARGS[@]}")
fi
SUBCMD=${CMD[0]}

if [ "$CHECK" = 1 ]; then
	check_env
	if [ "$SUBCMD" = up ]; then
		check_images
		check_volumes
	fi
fi

if [ "$PG_VOL_SET" = 0 ] && [ "$PROJECT" != penpot-prod ]; then
	echo "$SELF: note: --project $PROJECT uses the $PROJECT_* volumes, not the data of penpot-prod." >&2
fi

if [ "$BUILD" = 1 ]; then
	if [ "$SUBCMD" != up ]; then
		echo "$SELF: --build only applies to 'up', ignoring it" >&2
	else
		build_images
	fi
fi

dry_run_note=""
[ "$DRY_RUN" = 1 ] && dry_run_note="dry-run "
echo "$SELF: ${dry_run_note}project=$PROJECT images=$NAMESPACE/$VERSION env=$ENV_FILE" >&2
echo "$SELF: data: postgres=$PG_VOLUME assets=$ASSETS_VOLUME" >&2

# An http public URI is fine, but only with the flag that drops the
# Secure flag of the session cookie. The compose file sets that flag by default.
if [ "$SUBCMD" = up ] && [ "$CHECK" = 1 ]; then
	public_uri=$(env_value PENPOT_PUBLIC_URI)
	case "$public_uri" in
	http://*)
		case "$(env_value PENPOT_FLAGS)" in
		*disable-secure-session-cookies*) ;;
		*)
			echo "$SELF: warning: PENPOT_PUBLIC_URI is http and secure session cookies are on." >&2
			echo "  The browser will not send the session cookie back, so login loops." >&2
			echo "  Serve https, or add disable-secure-session-cookies to PENPOT_FLAGS." >&2
			;;
		esac
		;;
	esac
fi

if [ "$SUBCMD" = up ] && [ "$DRY_RUN" = 0 ]; then
	compose "${CMD[@]}"

	# State the two addresses the operator has to keep apart: the one the
	# browser uses and the loopback port the reverse proxy forwards to.
	public_uri=$(env_value PENPOT_PUBLIC_URI)
	http_port=$(env_value PENPOT_HTTP_PORT)
	http_port=${http_port:-8080}

	echo "$SELF: browsers:  $public_uri" >&2
	echo "$SELF: proxy to:  http://127.0.0.1:$http_port" >&2
	echo "$SELF: logs:      ./start-prod.sh logs -f" >&2
else
	compose "${CMD[@]}"
fi
