#!/usr/bin/env bash
# Posts one comment, read from stdin, on the issue that started the workflow, with a footer that
# marks it as automated.
set -euo pipefail

ISSUE=$(jq -r '.issue.number // empty' "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH not set}")
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: no issue number in the event payload" >&2
  exit 1
fi

BODY=$(cat)
if [[ -z "${BODY//[[:space:]]/}" ]]; then
  echo "Error: empty comment body" >&2
  exit 1
fi
if [[ ${#BODY} -gt 4000 ]]; then
  echo "Error: comment longer than 4000 characters, shorten it" >&2
  exit 1
fi

printf '%s\n\n<sub>Automated triage by Claude. A maintainer reads every issue and will follow up.</sub>\n' "$BODY" \
  | gh issue comment "$ISSUE" --repo "${GITHUB_REPOSITORY:?}" --body-file -
