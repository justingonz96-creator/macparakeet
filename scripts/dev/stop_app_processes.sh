#!/usr/bin/env bash

# Source this helper before replacing a running app's executable or resources.
# Signal only the current user's matching PIDs, then require observed exit.
# A timeout aborts the build; it never force-kills an app holding user data.
stop_app_processes() {
  local timeout_seconds="$1"
  shift
  local process_ids="" matches pattern process_id status
  local current_uid
  current_uid="$(id -u)" || return 1

  for pattern in "$@"; do
    if matches="$(pgrep -u "$current_uid" -f "$pattern")"; then
      while IFS= read -r process_id; do
        [[ "$process_id" =~ ^[0-9]+$ ]] || continue
        [[ "$process_id" != "$$" ]] || continue
        case " $process_ids " in
          *" $process_id "*) ;;
          *) process_ids="${process_ids:+$process_ids }$process_id" ;;
        esac
      done <<<"$matches"
    else
      status=$?
      if [[ "$status" -ne 1 ]]; then
        printf 'Cannot inspect running MacParakeet processes (pgrep exit %s). Build aborted.\n' "$status" >&2
        return 1
      fi
    fi
  done

  # IDs are validated decimal values above, so word splitting is intentional.
  for process_id in $process_ids; do
    if ! kill -TERM "$process_id" 2>/dev/null; then
      if kill -0 "$process_id" 2>/dev/null; then
        printf 'Cannot stop MacParakeet process %s. Build aborted.\n' "$process_id" >&2
        return 1
      fi
    fi
  done

  local deadline=$((SECONDS + timeout_seconds))
  local remaining_ids
  while :; do
    remaining_ids=""
    for process_id in $process_ids; do
      if kill -0 "$process_id" 2>/dev/null; then
        remaining_ids="${remaining_ids:+$remaining_ids }$process_id"
      fi
    done
    [[ -n "$remaining_ids" ]] || return 0
    if (( SECONDS >= deadline )); then
      printf 'MacParakeet did not exit within %ss (PIDs: %s). Build aborted before modifying the bundle.\n' \
        "$timeout_seconds" "$remaining_ids" >&2
      return 1
    fi
    sleep 0.1
  done
}
