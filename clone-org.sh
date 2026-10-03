#!/usr/bin/env bash
# clone-org.sh — clones every repository of an organization / group,
# repositories that are already cloned get fetched and pulled
#
# Usage:
#   ./clone-org.sh             # asks for the link
#   ./clone-org.sh <link>      # e.g. https://github.com/my-org
#
# Supported hosts:
#   GitHub (+ Enterprise), GitLab (+ self-hosted, incl. subgroups),
#   Gitea / Forgejo / Gogs (e.g. Codeberg), Bitbucket Cloud
#
# Environment variables:
#   DEST_DIR   where to clone (default: ./<organization>)
#   GIT_TOKEN  access token for private repos and higher API limits
#   USE_SSH    1 = clone over SSH instead of HTTPS
#   PROVIDER   github | gitlab | gitea | bitbucket (skips auto-detection)
#
# Note: also works for a user account (e.g. github.com/<user>).

set -euo pipefail

info()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn()  { printf '\e[1;33m!!\e[0m %s\n' "$*" >&2; }
die()   { printf '\e[1;31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

# --- Checks ---------------------------------------------------------------

for cmd in git curl jq; do
    command -v "$cmd" >/dev/null || die "Missing command '$cmd', please install it."
done

# --- Input ----------------------------------------------------------------

LINK="${1:-}"
if [[ -z "$LINK" ]]; then
    read -rp "Link to the organization (e.g. https://github.com/my-org): " LINK
fi

# Split the link into host and path; accepts https://host/org, host/org
# and git@host:org
SCHEME="https"
if [[ "$LINK" == *://* ]]; then
    [[ "$LINK" == http://* ]] && SCHEME="http"
    REST="${LINK#*://}"
    REST="${REST#*@}"
    HOST="${REST%%/*}"
    ORG="${REST#"$HOST"}"
    [[ "$LINK" == ssh://* ]] && HOST="${HOST%%:*}"
elif [[ "$LINK" =~ ^[^/@]+@([^:/]+):(.*)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    ORG="${BASH_REMATCH[2]}"
else
    HOST="${LINK%%/*}"
    ORG="${LINK#"$HOST"}"
fi

ORG="${ORG%%[?#]*}"
ORG="${ORG%%/-/*}"
ORG="${ORG#/}"
ORG="${ORG#orgs/}"
ORG="${ORG#groups/}"
ORG="${ORG%/}"
ORG="${ORG%.git}"

[[ "$HOST" == *.* || "$HOST" == localhost* ]] || die "Cannot read the host from '$LINK'."
[[ "$ORG" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] || die "Cannot read the organization name from '$LINK'."

BASE="$SCHEME://$HOST"

# --- API helpers ----------------------------------------------------------

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

AUTH=()

# Prints the HTTP status code, stores the response body in $TMP
api() { curl -sS -o "$TMP" -w '%{http_code}' "${AUTH[@]}" "$1" || true; }

api_error() { die "API returned $1: $(jq -r '(.message // .error // empty) | tostring' "$TMP" 2>/dev/null)"; }

REPOS=()

# fetch_pages <url ending with "page="> <jq filter printing "path<TAB>url">
# Appends to REPOS, returns 1 when the first page is a 404.
fetch_pages() {
    local page=1 code batch
    while :; do
        code="$(api "$1$page")"
        [[ "$code" == 404 && "$page" == 1 ]] && return 1
        [[ "$code" == 200 ]] || api_error "$code"
        mapfile -t batch < <(jq -r --arg org "$ORG" "$2" "$TMP")
        (( ${#batch[@]} )) || break
        REPOS+=("${batch[@]}")
        page=$((page + 1))
    done
}

not_found() { die "'$ORG' not found on $HOST (private ones need GIT_TOKEN)."; }

# --- Provider detection ---------------------------------------------------

PROVIDER="${PROVIDER:-}"
if [[ -z "$PROVIDER" ]]; then
    case "$HOST" in
        github.com)    PROVIDER="github" ;;
        gitlab.com)    PROVIDER="gitlab" ;;
        bitbucket.org) PROVIDER="bitbucket" ;;
        codeberg.org)  PROVIDER="gitea" ;;
        *)
            info "Detecting what runs on $HOST..."
            if [[ "$(api "$BASE/api/v1/version")" == 200 ]]; then
                PROVIDER="gitea"
            elif [[ "$(api "$BASE/api/v4/version")" =~ ^(200|401)$ ]]; then
                PROVIDER="gitlab"
            elif [[ "$(api "$BASE/api/v3/meta")" =~ ^(200|401)$ ]]; then
                PROVIDER="github"
            else
                die "Cannot detect the git hosting on $HOST, set PROVIDER=github|gitlab|gitea|bitbucket."
            fi
            ;;
    esac
fi

if [[ -n "${GIT_TOKEN:-}" ]]; then
    case "$PROVIDER" in
        gitea) AUTH=(-H "Authorization: token $GIT_TOKEN") ;;
        *)     AUTH=(-H "Authorization: Bearer $GIT_TOKEN") ;;
    esac
fi

[[ "${USE_SSH:-0}" == 1 ]] && SSH=1 || SSH=0

# --- Repository list ------------------------------------------------------

info "Loading the repository list of '$ORG' from $HOST ($PROVIDER)..."

case "$PROVIDER" in
    github)
        [[ "$HOST" == github.com ]] && API="https://api.github.com" || API="$BASE/api/v3"
        ORG="${ORG%%/*}"
        (( SSH )) && FIELD="ssh_url" || FIELD="clone_url"
        FILTER=".[] | \"\(.name)\t\(.$FIELD)\""
        fetch_pages "$API/orgs/$ORG/repos?per_page=100&page=" "$FILTER" \
            || fetch_pages "$API/users/$ORG/repos?per_page=100&page=" "$FILTER" \
            || not_found
        ;;
    gitea)
        API="$BASE/api/v1"
        ORG="${ORG%%/*}"
        (( SSH )) && FIELD="ssh_url" || FIELD="clone_url"
        FILTER=".[] | \"\(.name)\t\(.$FIELD)\""
        fetch_pages "$API/orgs/$ORG/repos?limit=50&page=" "$FILTER" \
            || fetch_pages "$API/users/$ORG/repos?limit=50&page=" "$FILTER" \
            || not_found
        ;;
    gitlab)
        API="$BASE/api/v4"
        (( SSH )) && FIELD="ssh_url_to_repo" || FIELD="http_url_to_repo"
        # Path relative to the group, so subgroups become subdirectories
        FILTER=".[] | \"\(.path_with_namespace[(\$org | length) + 1:])\t\(.$FIELD)\""
        fetch_pages "$API/groups/${ORG//\//%2F}/projects?include_subgroups=true&with_shared=false&per_page=100&page=" "$FILTER" \
            || fetch_pages "$API/users/$ORG/projects?per_page=100&page=" "$FILTER" \
            || not_found
        ;;
    bitbucket)
        ORG="${ORG%%/*}"
        (( SSH )) && FIELD="ssh" || FIELD="https"
        NEXT="https://api.bitbucket.org/2.0/repositories/$ORG?pagelen=100"
        while [[ -n "$NEXT" ]]; do
            CODE="$(api "$NEXT")"
            [[ "$CODE" == 404 ]] && not_found
            [[ "$CODE" == 200 ]] || api_error "$CODE"
            mapfile -t BATCH < <(jq -r ".values[] | \"\(.slug)\t\(.links.clone[] | select(.name == \"$FIELD\") | .href)\"" "$TMP")
            REPOS+=("${BATCH[@]}")
            NEXT="$(jq -r '.next // empty' "$TMP")"
        done
        ;;
    *)
        die "Unknown PROVIDER '$PROVIDER'. Supported: github, gitlab, gitea, bitbucket."
        ;;
esac

DEST_DIR="${DEST_DIR:-$PWD/${ORG##*/}}"

(( ${#REPOS[@]} )) || die "No (visible) repositories in '$ORG'. Private ones need GIT_TOKEN."
info "Repositories found: ${#REPOS[@]}, destination: $DEST_DIR"

# --- Clone / update -------------------------------------------------------

mkdir -p "$DEST_DIR"

CLONED=0; UPDATED=0; FAILED=()

for LINE in "${REPOS[@]}"; do
    NAME="${LINE%%$'\t'*}"
    URL="${LINE#*$'\t'}"
    DIR="$DEST_DIR/$NAME"

    if [[ -d "$DIR/.git" ]]; then
        info "$NAME: fetch + pull"
        if ! git -C "$DIR" fetch --all --prune; then
            warn "$NAME: fetch failed."
            FAILED+=("$NAME")
        elif [[ -z "$(git -C "$DIR" ls-remote --heads origin)" ]]; then
            warn "$NAME: repository is empty, nothing to pull."
            UPDATED=$((UPDATED + 1))
        elif git -C "$DIR" pull --ff-only; then
            UPDATED=$((UPDATED + 1))
        else
            warn "$NAME: pull failed (local changes or diverged history?)."
            FAILED+=("$NAME")
        fi
    elif [[ -e "$DIR" ]]; then
        warn "$NAME: '$DIR' exists but is not a git repository, skipping."
        FAILED+=("$NAME")
    else
        info "$NAME: cloning"
        if git clone "$URL" "$DIR"; then
            CLONED=$((CLONED + 1))
        else
            warn "$NAME: clone failed."
            FAILED+=("$NAME")
        fi
    fi
done

# --- Summary --------------------------------------------------------------

info "Done: $CLONED cloned, $UPDATED updated, ${#FAILED[@]} failed."
if (( ${#FAILED[@]} )); then
    warn "Failed: ${FAILED[*]}"
    exit 1
fi
