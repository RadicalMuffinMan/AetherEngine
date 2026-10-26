#!/usr/bin/env bash
# Read-only `gh` for the triage bot: four subcommands, a handful of flags, this repository only.
# Adapted from anthropics/claude-code-action scripts/gh.sh (MIT).
set -euo pipefail

export GH_HOST=github.com
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" || "$REPO" == */*/* || "$REPO" != */* ]]; then
  echo "Error: GH_REPO or GITHUB_REPOSITORY must be owner/repo" >&2
  exit 1
fi
export GH_REPO="$REPO"

ALLOWED_FLAGS=(--comments --state --limit --label --include-prs)
FLAGS_WITH_VALUES=(--state --limit --label)

CMD="${1:-} ${2:-}"
case "$CMD" in
  "issue view"|"issue list"|"search issues"|"label list") ;;
  *)
    echo "Error: only 'issue view', 'issue list', 'search issues' and 'label list' are allowed" >&2
    exit 1
    ;;
esac
SUB1="$1"; SUB2="$2"
shift 2

POSITIONAL=()
FLAGS=()
skip_next=false
for arg in "$@"; do
  if [[ "$skip_next" == true ]]; then
    FLAGS+=("$arg")
    skip_next=false
  elif [[ "$arg" == -* ]]; then
    flag="${arg%%=*}"
    matched=false
    for allowed in "${ALLOWED_FLAGS[@]}"; do
      [[ "$flag" == "$allowed" ]] && matched=true && break
    done
    if [[ "$matched" == false ]]; then
      echo "Error: allowed flags are ${ALLOWED_FLAGS[*]}" >&2
      exit 1
    fi
    FLAGS+=("$arg")
    if [[ "$arg" != *=* ]]; then
      for vflag in "${FLAGS_WITH_VALUES[@]}"; do
        [[ "$flag" == "$vflag" ]] && skip_next=true && break
      done
    fi
  else
    POSITIONAL+=("$arg")
  fi
done

if [[ "$CMD" == "search issues" ]]; then
  QUERY="${POSITIONAL[0]:-}"
  QUERY_LOWER=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')
  if [[ ${#POSITIONAL[@]} -ne 1 || "$QUERY_LOWER" == *"repo:"* || "$QUERY_LOWER" == *"org:"* || "$QUERY_LOWER" == *"user:"* ]]; then
    echo "Error: search issues takes one query without repo:, org: or user: qualifiers" >&2
    exit 1
  fi
  gh search issues "$QUERY" --repo "$REPO" "${FLAGS[@]}"
elif [[ "$CMD" == "issue view" ]]; then
  if [[ ${#POSITIONAL[@]} -ne 1 ]] || ! [[ "${POSITIONAL[0]}" =~ ^[0-9]+$ ]]; then
    echo "Error: issue view takes exactly one issue number" >&2
    exit 1
  fi
  gh "$SUB1" "$SUB2" "${POSITIONAL[0]}" "${FLAGS[@]}"
else
  if [[ ${#POSITIONAL[@]} -ne 0 ]]; then
    echo "Error: issue list and label list take no positional arguments" >&2
    exit 1
  fi
  gh "$SUB1" "$SUB2" "${FLAGS[@]}"
fi
