#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: release-notes.sh <markdown|html> <to-ref> [<from-ref>]" >&2
  exit 1
}

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  usage
fi
format=$1
to=$2
from=${3:-}
case $format in
  markdown | html) ;;
  *) usage ;;
esac

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

if ! git rev-parse --quiet --verify "$to^{commit}" > /dev/null; then
  echo "unknown ref: $to" >&2
  exit 1
fi
if [ -n "$from" ] && ! git rev-parse --quiet --verify "$from^{commit}" > /dev/null; then
  echo "unknown ref: $from" >&2
  exit 1
fi

range=$to
if [ -n "$from" ]; then
  range="$from..$to"
fi

restic_entry="Update the bundled restic"

bumps=$(git log --no-merges --format='%H' -G'^ARG RESTIC_IMAGE=' "$range" -- packages/standalone-app/Dockerfile |
  tr '\n' ' ')

commits=$(
  {
    git log --no-merges --format='%H' "$range" -- packages/macos-app packages/restic-proxy
    git log --no-merges --format='%H' -G'^ARG RESTIC_IMAGE=' "$range" -- packages/standalone-app/Dockerfile
  } | sort -u | git rev-list --no-walk=sorted --stdin |
    while IFS= read -r hash; do
      git show -s --format='%H%x09%s' "$hash"
    done
)

subject_pattern='^([a-z]+)(\([^)]*\))?!?: (.*)$'
features=""
fixes=""
performance=""
restic_added=0

if [ -n "$commits" ]; then
  while IFS=$'\t' read -r hash subject; do
    if [[ $subject =~ $subject_pattern ]]; then
      type=${BASH_REMATCH[1]}
      desc=${BASH_REMATCH[3]}
    else
      continue
    fi
    case $type in
      feat | fix | perf)
        if [ -z "$desc" ]; then
          continue
        fi
        desc=$(printf '%s%s' "$(printf '%s' "${desc:0:1}" | LC_ALL=C tr '[:lower:]' '[:upper:]')" "${desc:1}")
        ;;
      chore | build | deps)
        case " $bumps " in
          *" $hash "*)
            if [ "$restic_added" = 0 ]; then
              restic_added=1
              fixes="$fixes$restic_entry"$'\n'
            fi
            ;;
        esac
        continue
        ;;
      *) continue ;;
    esac
    case $type in
      feat) features="$features$desc"$'\n' ;;
      fix) fixes="$fixes$desc"$'\n' ;;
      perf) performance="$performance$desc"$'\n' ;;
    esac
  done <<< "$commits"
fi

found=0
blank=0

md_section() {
  heading=$1
  body=$2
  if [ -z "$body" ]; then
    return 0
  fi
  found=1
  if [ "$blank" = 1 ]; then
    printf '\n'
  fi
  printf '## %s\n' "$heading"
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      printf -- '- %s\n' "$line"
    fi
  done <<< "$body"
  blank=1
}

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

html_section() {
  heading=$1
  body=$2
  if [ -z "$body" ]; then
    return 0
  fi
  found=1
  if [ "$blank" = 1 ]; then
    printf '\n'
  fi
  printf '<h3>%s</h3>\n' "$(html_escape "$heading")"
  printf '<ul>\n'
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      printf '<li>%s</li>\n' "$(html_escape "$line")"
    fi
  done <<< "$body"
  printf '</ul>\n'
  blank=1
}

case $format in
  markdown)
    md_section Features "$features"
    md_section "Bug Fixes" "$fixes"
    md_section Performance "$performance"
    ;;
  html)
    html_section Features "$features"
    html_section "Bug Fixes" "$fixes"
    html_section Performance "$performance"
    ;;
esac

if [ "$found" = 0 ]; then
  printf 'Maintenance release.\n'
fi
