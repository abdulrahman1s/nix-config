set -Eeuo pipefail

# Boots the recovery in QEMU, signed in to Claude Code and Codex with copies of
# this system's logins. The copies leave out the refresh tokens: a refresh in
# the VM could use up the one this system relies on and sign it out here. The
# VM's sign-ins therefore last until the copied access tokens expire; using
# Claude Code or Codex on this system renews them for the next run.
logins="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/recovery-vm-logins.XXXXXX")"
trap 'rm -rf -- "$logins"' EXIT
umask 077
mkdir -p "$logins/.claude" "$logins/.codex"

claude_credentials="$HOME/.claude/.credentials.json"
if [[ -f $claude_credentials ]]; then
  jq '.claudeAiOauth |= del(.refreshToken, .refreshTokenExpiresAt)' "$claude_credentials" >"$logins/.claude/.credentials.json"
  expires_ms="$(jq -r '.claudeAiOauth.expiresAt' "$claude_credentials")"
  echo "Claude Code: signed in until $(date -d "@$((expires_ms / 1000))" '+%a %d %b %H:%M')."
else
  echo "Claude Code: not signed in on this system; use /login in the VM."
fi
# The account part of ~/.claude.json, as recovery-update copies it.
if [[ -f $HOME/.claude.json ]]; then
  jq '{oauthAccount, userID, hasCompletedOnboarding} | with_entries(select(.value != null))' "$HOME/.claude.json" >"$logins/.claude.json"
fi

codex_auth="$HOME/.codex/auth.json"
if [[ -f $codex_auth ]]; then
  # Codex requires the refresh token field. A last refresh of now keeps it from
  # attempting a refresh it can't complete before the access token expires.
  jq 'if .tokens then .tokens.refresh_token = "" | .last_refresh = (now | todate) else . end' "$codex_auth" >"$logins/.codex/auth.json"
  expires="$(jq -r '.tokens.expires_at // empty' "$codex_auth")"
  if [[ -n $expires ]]; then
    echo "Codex: signed in until $(date -d "$expires" '+%a %d %b %H:%M')."
  else
    echo "Codex: signed in with an API key."
  fi
else
  echo "Codex: not signed in on this system; run codex login in the VM."
fi

# The VM module shares SHARED_DIR at /tmp/shared; vm.nix copies the logins into
# the VM's home from there. QEMU runs as a child so the copies are removed when
# it exits.
SHARED_DIR="$logins" "$RECOVERY_VM" "$@"
