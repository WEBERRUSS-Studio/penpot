#!/usr/bin/env bash
# FORK ONLY (WEBERRUSS-Studio) -- never PR these files to penpot/penpot.
#
# Stop and remove the production stack of docker-compose.prod.yaml. The data
# volumes stay: a plain run leaves the database and the uploaded assets on
# disk, so the next ./start-prod.sh comes back to the same instance.
#
# Usage:
#   ./down-prod.sh [options]                 stop and remove the stack (down)
#   ./down-prod.sh <subcommand> [args...]    pass anything else straight to
#                                            docker compose: stop, ps, logs ...
#
#   --volumes          also remove the volumes of this stack, which means the
#                      database and every uploaded asset. Asks first: the
#                      answer has to be the project name.
#   --yes              no prompt (only meaningful with --volumes)
#   --env-file <file>  env file                (default: .env.prod)
#   --project <name>   compose project name    (default: penpot-prod)
#   --dry-run          print the commands, change nothing
#   -h, --help         this text
#
# The two data volumes are named either in the env file
# (PENPOT_POSTGRES_VOLUME, PENPOT_ASSETS_VOLUME) or, when it does not name
# them, by the <project>_<volume> convention. --volumes removes whatever those
# two names resolve to, so check the names this script prints before you
# confirm, especially after a --project that differs from start-prod.sh.
#
# penpot-valkey has no volume in this compose file: its content (session and
# queue state) lives in the container layer and is gone after a down. That is
# expected; nothing of the design data is in there.
#
# Environment: PENPOT_PROD_ENV_FILE, PENPOT_PROD_PROJECT

set -euo pipefail

SELF=$(basename "$0")

usage() {
	awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

COMPOSE_FILE=docker-compose.prod.yaml
ENV_FILE=${PENPOT_PROD_ENV_FILE:-.env.prod}
PROJECT=${PENPOT_PROD_PROJECT:-penpot-prod}
VOLUMES=0
ASSUME_YES=0
DRY_RUN=0
ARGS=()

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--volumes)
		VOLUMES=1
		;;
	--yes)
		ASSUME_YES=1
		;;
	--env-file)
		ENV_FILE=${2:?--env-file needs a value}
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
		# A subcommand and everything behind it go to docker compose.
		ARGS=("$@")
		break
		;;
	esac
	shift
done

# Run from this directory: the compose file and the env file are relative to
# it, so the script works from any caller's cwd.
cd "$(cd "$(dirname "$0")" && pwd)"

# Read single values out of the env file rather than sourcing it: the file is
# data, not shell code. Same helper as start-prod.sh.
env_value() {
	[ -r "$ENV_FILE" ] || return 0
	sed -n "s/^[[:space:]]*${1}=//p" "$ENV_FILE" |
		tail -n 1 |
		sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'
}

PG_VOLUME=$(env_value PENPOT_POSTGRES_VOLUME)
ASSETS_VOLUME=$(env_value PENPOT_ASSETS_VOLUME)
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

if [ ${#ARGS[@]} -eq 0 ]; then
	CMD=(down)
else
	CMD=("${ARGS[@]}")
fi
SUBCMD=${CMD[0]}

# --volumes only ever applies to a down; anywhere else it would be silently
# ignored, so refuse instead.
if [ "$VOLUMES" = 1 ]; then
	if [ "$SUBCMD" != down ]; then
		echo "$SELF: --volumes only applies to 'down', not to '$SUBCMD'" >&2
		exit 1
	fi
	CMD+=(--volumes)

	exists=0
	for volume in "$PG_VOLUME" "$ASSETS_VOLUME"; do
		if docker volume inspect "$volume" >/dev/null 2>&1; then
			exists=1
			echo "$SELF: volume $volume exists" >&2
		else
			echo "$SELF: volume $volume does not exist" >&2
		fi
	done

	# Removing a data volume is not reversible, and the answer that lets it
	# happen has to be typed, not entered blindly.
	if [ "$exists" = 1 ] && [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
		echo "$SELF: this deletes the database and all uploaded assets of project $PROJECT." >&2
		printf '%s' "  type the project name to confirm: " >&2
		read -r answer
		if [ "$answer" != "$PROJECT" ]; then
			echo "$SELF: aborted, nothing removed." >&2
			exit 1
		fi
	fi
fi

dry_run_note=""
[ "$DRY_RUN" = 1 ] && dry_run_note="dry-run "
echo "$SELF: ${dry_run_note}project=$PROJECT env=$ENV_FILE" >&2
if [ "$SUBCMD" = down ]; then
	echo "$SELF: data volumes: postgres=$PG_VOLUME assets=$ASSETS_VOLUME" >&2
	[ "$VOLUMES" = 0 ] &&
		echo "$SELF: they survive this run; ./start-prod.sh reuses them" >&2
fi

compose "${CMD[@]}"
