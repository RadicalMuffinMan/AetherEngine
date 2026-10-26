#!/usr/bin/env bash
# Adds triage labels to the issue that started the workflow, and only labels from this allowlist,
# so a prompt-injected run cannot label another issue or set a label that drives automation
# (`approved` opens a used-by pull request).
set -euo pipefail

ALLOWED=(
  "bug" "enhancement" "question" "documentation" "needs-info" "host-app"
  "area: audio" "area: video" "area: hdr-dv" "area: subtitles" "area: live" "area: io" "area: api"
)

ISSUE=$(jq -r '.issue.number // empty' "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH not set}")
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: no issue number in the event payload" >&2
  exit 1
fi

ADD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --add-label)
      label="${2:-}"
      ok=false
      for allowed in "${ALLOWED[@]}"; do
        [[ "$label" == "$allowed" ]] && ok=true && break
      done
      if [[ "$ok" == true ]]; then
        ADD+=(--add-label "$label")
      else
        echo "Skipped label not in the allowlist: $label" >&2
      fi
      shift 2
      ;;
    *)
      echo "Error: only --add-label <name> is accepted" >&2
      exit 1
      ;;
  esac
done

if [[ ${#ADD[@]} -eq 0 ]]; then
  echo "No labels to add."
  exit 0
fi

gh issue edit "$ISSUE" --repo "${GITHUB_REPOSITORY:?}" "${ADD[@]}"
echo "Labelled #$ISSUE."
