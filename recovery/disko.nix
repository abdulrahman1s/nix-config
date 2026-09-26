{
  disko.rootMountPoint = "/mnt/recovery-install";

  disko.devices.disk.recovery = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4056230e";
    content = {
      type = "gpt";
      partitions = {
        recovery-efi = {
          priority = 1;
          label = "nixos-recovery-efi";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [
              "-n"
              "RECOVERYEFI"
            ];
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };

        recovery-root = {
          priority = 2;
          label = "nixos-recovery";
          size = "24G";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-L"
              "NIXOS-RECOVERY"
            ];
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };

        data = {
          priority = 3;
          label = "sn350-data";
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-L"
              "SN350"
            ];
            mountpoint = "/mnt/SN350";
            mountOptions = [
              "defaults"
              "noatime"
              "nofail"
            ];
          };
        };
      };
    };
  };
}
