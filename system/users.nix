# Declarative login passwords — REQUIRED under impermanence.
#
# /etc/shadow lives on the ephemeral root subvolume and is wiped to blank on
# every boot, so an imperatively-set password (passwd / mutableUsers) does not
# survive. These hashes are re-applied on every activation; mutableUsers = false
# makes /etc/shadow fully declarative, so no auth files need persisting.
{ config, username, ... }:
{
  age.secrets = {
    user-password-hash.file = ../secrets/user-password-hash.age;
    root-password-hash.file = ../secrets/root-password-hash.age;
  };

  users.mutableUsers = false;
  users.users.${username}.hashedPasswordFile =
    config.age.secrets.user-password-hash.path;
  users.users.root.hashedPasswordFile =
    config.age.secrets.root-password-hash.path;
}
