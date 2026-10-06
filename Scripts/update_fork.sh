#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

verify_fork_app() {
  local app="$1"
  [[ -x "$app/Contents/MacOS/CodexBar" ]] || fail "Missing CodexBar executable in $app."
  [[ -x "$app/Contents/Helpers/CodexBarCLI" ]] || fail "Missing CodexBarCLI in $app."
  [[ -d "$app/Contents/Helpers/CodexBar_CodexBarCore.bundle" ]] || fail "Missing core resources in $app."
  [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "Missing Sparkle framework in $app."
  python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

try:
    plist = plistlib.loads(Path(sys.argv[1]).read_bytes())
except (OSError, ValueError) as error:
    raise SystemExit(f"ERROR: Cannot read the packaged app's Info.plist: {error}")
if plist.get("CFBundleIdentifier") != "com.steipete.codexbar":
    raise SystemExit("ERROR: The packaged app has an unexpected bundle identifier.")
if plist.get("SUFeedURL") != "" or plist.get("SUEnableAutomaticChecks") is not False:
    raise SystemExit("ERROR: The packaged fork must disable the upstream Sparkle update feed.")
PY
  codesign --verify --deep --strict "$app/Contents/Frameworks/Sparkle.framework"
  codesign --verify --deep --strict "$app"
}

install_fork_app() (
  set -euo pipefail
  local source_app="$1"
  local applications="$2"
  # Apple Bash 3.2 discards function locals before an errexit EXIT trap runs.
  # Keep cleanup state in this isolated subshell so it survives that unwind.
  destination="$applications/CodexBar.app"
  staging='' backup=''

  [[ ! -L "$applications" ]] || fail "Refusing a symlinked Applications directory: $applications."
  [[ ! -L "$destination" ]] || fail "Refusing a symlinked app: $destination."
  if [[ -e "$destination" && ! -d "$destination/Contents" ]]; then
    fail "The install destination is not an app bundle: $destination."
  fi
  verify_fork_app "$source_app"
  mkdir -p "$applications"
  staging=$(mktemp -d "$applications/.codexbar-fork-install.XXXXXX")

  cleanup_install() {
    local status=$?
    if [[ -n "$backup" && ! -e "$destination" && ! -L "$destination" && -d "$backup" ]]; then
      if ! mv "$backup" "$destination"; then
        printf 'ERROR: Restore the previous app manually from %s.\n' "$backup" >&2
        status=1
      fi
    fi
    rm -rf "$staging"
    return "$status"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ditto "$source_app" "$staging/CodexBar.app"
  verify_fork_app "$staging/CodexBar.app"
  if [[ -e "$destination" ]]; then
    backup="$applications/CodexBar-previous-$(date -u +%Y%m%dT%H%M%SZ)-$$.app"
    [[ ! -e "$backup" && ! -L "$backup" ]] || fail "Backup path already exists: $backup."
    mv "$destination" "$backup"
  fi
  mv "$staging/CodexBar.app" "$destination"
  printf 'Installed %s\n' "$destination"
  if [[ -n "$backup" ]]; then
    printf 'Previous app saved at %s\n' "$backup"
  fi
  printf 'Quit the running CodexBar, then open the installed app when ready.\n'
)

check_remote() {
  local remote="$1" expected_repo="$2" url urls mode
  for mode in fetch push; do
    if [[ "$mode" == push ]]; then
      urls=$(git remote get-url --push --all "$remote") || fail "Missing $remote remote."
    else
      urls=$(git remote get-url --all "$remote") || fail "Missing $remote remote."
    fi
    while IFS= read -r url; do
      case "$url" in
        "https://github.com/$expected_repo"|"https://github.com/$expected_repo.git"|\
        "git@github.com:$expected_repo"|"git@github.com:$expected_repo.git"|\
        "ssh://git@github.com/$expected_repo"|"ssh://git@github.com/$expected_repo.git") ;;
        *) fail "$remote must point to $expected_repo; check git remote -v." ;;
      esac
    done <<< "$urls"
  done
}

resolve_fork_signing_identity() {
  local requested="${APP_IDENTITY:-}" identities line hash name selected_name='' selected_hash='' matches=0
  local advice='Set APP_IDENTITY to the certificate full name or SHA-1 hash, or set CODEXBAR_SIGNING=adhoc explicitly.'
  if ! identities=$(security find-identity -p codesigning -v); then
    fail "Unable to list valid signing identities. $advice"
  fi
  local identity_pattern='^[[:space:]]*[[:digit:]]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
  local requested_hash
  requested_hash=$(printf '%s' "$requested" | tr '[:lower:]' '[:upper:]')
  while IFS= read -r line; do
    [[ "$line" =~ $identity_pattern ]] || continue
    hash="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    if [[ -z "$requested" && "$name" == 'Developer ID Application: '* ]] \
      || [[ -n "$requested" && ( "$hash" == "$requested_hash" || "$name" == *"$requested"* ) ]]; then
      selected_name="$name"
      selected_hash="$hash"
      matches=$((matches + 1))
    fi
  done <<< "$identities"
  [[ "$matches" == 1 ]] || fail "Signing identity must match exactly one valid certificate (found $matches). $advice"
  local team_pattern='^Developer ID Application: .+ \(([A-Z0-9]{10})\)$'
  [[ "$selected_name" =~ $team_pattern ]] || fail "Select a Developer ID Application certificate. $advice"
  local team="${BASH_REMATCH[1]}"
  [[ -z "${APP_TEAM_ID:-}" || "$APP_TEAM_ID" == "$team" ]] \
    || fail 'APP_TEAM_ID does not match the selected signing identity.'
  printf '%s' "$selected_hash"
}

main() {
  local install=0
  [[ $# -le 1 ]] || fail 'Usage: Scripts/update_fork.sh [--install]'
  case "${1:-}" in
    '') ;;
    --install) install=1 ;;
    --help|-h)
      printf 'Usage: Scripts/update_fork.sh [--install]\n\n'
      printf 'Fetch fork main, merge without fast-forwarding, and build a local release app.\n'
      printf '%s\n' '--install also replaces ~/Applications/CodexBar.app and saves the previous app.'
      printf 'Signing uses a Developer ID Application certificate; APP_IDENTITY selects one explicitly.\n'
      printf 'Set CODEXBAR_SIGNING=adhoc to request ad hoc signing explicitly.\n'
      return 0
      ;;
    *) fail 'Usage: Scripts/update_fork.sh [--install]' ;;
  esac
  [[ "$(uname -s)" == Darwin ]] || fail 'Build this macOS app on macOS.'

  local root branch state
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  cd "$root"
  [[ "$(git rev-parse --show-toplevel)" == "$root" ]] || fail 'Run this script from a CodexBar checkout.'
  branch=$(git symbolic-ref --quiet --short HEAD) || fail 'Switch to main before updating the fork.'
  [[ "$branch" == main ]] || fail 'Switch to main before updating the fork.'
  for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_START; do
    [[ ! -e "$(git rev-parse --git-path "$state")" ]] || fail 'Finish the current Git operation before updating.'
  done
  state=$(git status --porcelain --untracked-files=normal) || fail 'Unable to inspect local changes.'
  [[ -z "$state" ]] || fail 'Commit or stash local changes before updating.'
  check_remote origin dr-baker/CodexBar
  check_remote upstream steipete/CodexBar

  if [[ "$install" == 1 ]]; then
    [[ ! -L "$HOME/Applications" && ! -L "$HOME/Applications/CodexBar.app" ]] \
      || fail 'Refusing a symlinked install destination in ~/Applications.'
  fi
  local signing_mode="${CODEXBAR_SIGNING:-identity}" app_identity=''
  case "$signing_mode" in
    identity) app_identity=$(resolve_fork_signing_identity) ;;
    adhoc) ;;
    *) fail "Unsupported CODEXBAR_SIGNING: $signing_mode (expected identity or adhoc)." ;;
  esac
  git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
  if ! git merge --no-ff --no-edit origin/main; then
    if [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
      git merge --abort
    fi
    fail 'Fork update could not merge cleanly. The merge was aborted; resolve it on a separate branch.'
  fi

  if ! CODEXBAR_SIGNING="$signing_mode" APP_IDENTITY="$app_identity" CODEXBAR_DISABLE_UPSTREAM_UPDATES=1 \
    CODEXBAR_SKIP_LAUNCH_SMOKE=1 CODEXBAR_ALLOW_LLDB=0 \
    "$root/Scripts/package_app.sh" release; then
    fail 'Build failed. The source update remains in main; the installed app was not changed.'
  fi
  verify_fork_app "$root/CodexBar.app"
  if [[ "$install" == 1 ]]; then
    install_fork_app "$root/CodexBar.app" "$HOME/Applications"
  else
    printf 'Built %s/CodexBar.app\n' "$root"
    printf 'Run Scripts/update_fork.sh --install to install it in ~/Applications.\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
