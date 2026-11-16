# Shared by recovery-update and recovery-usb.
#
# Copies the Claude Code and Codex logins from the main system's home into the
# recovery installed at $1, so both start signed in there. The files hold
# tokens: they are copied with mode 0600, never printed, and never placed in
# the Nix store.
copy_logins() {
  local mount_root="$1"
  local user_home="/home/$RECOVERY_USERNAME"
  local recovery_home="$mount_root$user_home"
  local login account path
  local -a copied=()

  # nixos-install's activation creates the home on a new installation.
  if [[ ! -d $recovery_home ]]; then
    echo "Skipped the Claude Code and Codex logins: the recovery has no $user_home yet."
    return 0
  fi

  for login in .claude/.credentials.json .codex/auth.json; do
    if [[ -f $user_home/$login ]]; then
      install -D -m 0600 "$user_home/$login" "$recovery_home/$login"
      echo "Copied the login in ~/$login."
    else
      echo "Skipped ~/$login: not signed in on this system."
    fi
  done

  # Claude Code also keeps the account in ~/.claude.json, next to settings
  # and history that only make sense on the main system. Merge just the
  # account into whatever the recovery's own copy holds.
  if [[ -f $user_home/.claude.json ]]; then
    # shellcheck disable=SC2016 # $main is a jq variable, not a shell one.
    account='$main[0] | {oauthAccount, userID, hasCompletedOnboarding} | with_entries(select(.value != null))'
    (
      umask 077
      if [[ -f $recovery_home/.claude.json ]]; then
        jq --slurpfile main "$user_home/.claude.json" ". * ($account)" "$recovery_home/.claude.json"
      else
        jq --null-input --slurpfile main "$user_home/.claude.json" "$account"
      fi >"$recovery_home/.claude.json.new"
    )
    mv -f "$recovery_home/.claude.json.new" "$recovery_home/.claude.json"
    echo "Copied the Claude Code account from ~/.claude.json."
  fi

  # Ownership is set inside the recovery, where the user's ID is defined.
  # Root-owned copies would leave both tools signed out.
  for path in .claude .codex .claude.json; do
    [[ ! -e $recovery_home/$path ]] || copied+=("$user_home/$path")
  done
  if ((${#copied[@]} > 0)); then
    nixos-enter --root "$mount_root" --command "chown -R $RECOVERY_USERNAME: ${copied[*]}"
  fi
}
