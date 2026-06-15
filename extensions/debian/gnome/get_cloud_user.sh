#!/usr/bin/env bash
# Resolve cloud-init user similarly to code-server extension

set -euo pipefail

get_cloud_user(){
  local ci_user=""
  if ! command -v cloud-init >/dev/null 2>&1; then
    echo "Error: cloud-init not found" >&2
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq not found" >&2
    return 1
  fi
  local userdata
  if ! userdata=$(cloud-init query userdata 2>/dev/null); then
    local user_data_file="/var/lib/cloud/instance/user-data.txt"
    if [[ -f "$user_data_file" ]]; then
      userdata=$(cat "$user_data_file" 2>/dev/null || echo "")
    else
      echo "Error: Failed to query cloud-init userdata and file not found: $user_data_file" >&2
      return 1
    fi
  fi
  if [[ -z "$userdata" ]] || [[ "$userdata" == "null" ]]; then
    echo "Error: No cloud-init userdata found" >&2
    return 1
  fi
  ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.user // empty' 2>/dev/null || true)
  if [[ -z "$ci_user" ]]; then
    ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.users[0].name // empty' 2>/dev/null || true)
  fi
  if [[ -n "$ci_user" ]]; then
    echo "$ci_user"; return 0
  fi
  echo "Error: User not found in cloud-init userdata" >&2
  return 1
}

main(){
  local u
  if u=$(get_cloud_user); then
    echo "$u"; exit 0
  fi
  exit 1
}
main "$@"
