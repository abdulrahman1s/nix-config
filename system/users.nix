# Declarative login passwords — REQUIRED under impermanence.
#
# /etc/shadow lives on the ephemeral root subvolume and is wiped to blank on
# every boot, so an imperatively-set password (passwd / mutableUsers) does not
# survive. These hashes are re-applied on every activation; mutableUsers = false
# makes /etc/shadow fully declarative, so no auth files need persisting.
#
# Change a password with: mkpasswd -s   (then replace the hash below). Longer
# term these belong in an agenix-backed hashedPasswordFile rather than inline.
{ username, ... }:
{
  users.mutableUsers = false;
  users.users.${username}.hashedPassword = "$y$j9T$nGhU8X19da1SDdOaw2OUb0$J8MGId0LzMYuxQ0LyLBDjZkarPQPMSiO9ry8Xq2ySk/";
  users.users.root.hashedPassword = "$y$j9T$/MKzR5kzrkQkvzxWkxs.J.$xrzEw8j5PhnTwkjqqs3qotKTFNGenWGkIdZ/FSZd7s6";
}
