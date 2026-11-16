{ pkgs, ... }:
{
  # go2rtc belongs to the persisted Local/ai-camera Compose project. Keep its
  # listeners private without putting mutable camera configuration in the store.
  system.userActivationScripts.go2rtc-local-listeners.text = ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    from pathlib import Path
    import re

    path = Path.home() / "Local/ai-camera/go2rtc.yaml"
    if path.is_symlink():
        raise RuntimeError("Refusing symlinked go2rtc configuration")
    if path.exists():
        original = path.read_text()
        lines = original.splitlines(keepends=True)
        ports = {"api": 1984, "rtsp": 8554}
        counts = dict.fromkeys(ports, 0)
        section = None
        for index, line in enumerate(lines):
            match = re.match(r"^([A-Za-z_]+):", line)
            if match:
                section = match[1]
            elif line.strip() and not line[0].isspace() and not line.startswith("#"):
                section = None
            if section in ports and re.match(r"^  listen:", line):
                comment = (" #" + line.split("#", 1)[1].rstrip()) if "#" in line else ""
                lines[index] = f'  listen: "127.0.0.1:{ports[section]}"{comment}\n'
                counts[section] += 1
        if any(count != 1 for count in counts.values()):
            raise RuntimeError("Unexpected go2rtc listener layout; configuration was preserved")
        updated = "".join(lines)
        if updated != original:
            # Preserve the inode used by Docker's existing read-only file bind.
            path.write_text(updated)
    PY
  '';
}
