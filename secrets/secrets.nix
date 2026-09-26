let
  abdulrahman = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILv5vppwYRT/3ZM2Xl3xZafIb3FCeZdOSalMo/FOybHm";
in
{
  "cloudflare-tunnel-token.age".publicKeys = [ abdulrahman ];
  "nextdns-upstream.age".publicKeys = [ abdulrahman ];
  "rclone.conf.age".publicKeys = [ abdulrahman ];
  "user-password-hash.age".publicKeys = [ abdulrahman ];
  "root-password-hash.age".publicKeys = [ abdulrahman ];
  "personal-ai-cloud-env.age".publicKeys = [ abdulrahman ];
}
