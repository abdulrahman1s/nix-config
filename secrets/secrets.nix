let
  abdulrahman = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILv5vppwYRT/3ZM2Xl3xZafIb3FCeZdOSalMo/FOybHm";
in
{
  "cloudflare-tunnel-token.age".publicKeys = [ abdulrahman ];
  "dokploy-auth-secret.age".publicKeys = [ abdulrahman ];
  "dokploy-db-password.age".publicKeys = [ abdulrahman ];
  "nextdns-upstream.age".publicKeys = [ abdulrahman ];
  "rclone.conf.age".publicKeys = [ abdulrahman ];
}
