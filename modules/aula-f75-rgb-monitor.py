#!/usr/bin/env python3

"""Reactive OpenRGB lighting monitor for the AULA F75 keyboard."""

import colorsys
import errno
import fcntl
import json
import math
import os
import random
import re
import select
import socket
import stat
import struct
import subprocess
import threading
import time
import traceback


HOST = "127.0.0.1"
PORT = 6742
DEVICE_NAME = "AULA F75"
LED_COUNT = 90
FPS = 45
FRAME_INTERVAL_SECONDS = 1.0 / FPS
OPENRGB_MAX_PROTOCOL = 6
OPENRGB_SOCKET_TIMEOUT_SECONDS = 3.0
OPENRGB_NEGOTIATION_TIMEOUT_SECONDS = 0.75
OPENRGB_RECONNECT_SECONDS = 3.0
OPENRGB_MAX_PACKET_BYTES = 64 * 1024 * 1024
SYSTEM_POLL_SECONDS = 0.10
CPU_SMOOTHING = 0.30
RAM_SMOOTHING = 0.18
GAME_MODE_POLL_SECONDS = 0.20
DEBUG_TRACEBACKS = os.environ.get("AULA_RGB_DEBUG", "").lower() in {
    "1",
    "true",
    "yes",
    "on",
}
MASTER_BRIGHTNESS = 0.92
OUTPUT_GAMMA = 1.85
KEY_PULSE_ATTACK_SECONDS = 0.040
KEY_PULSE_HOLD_SECONDS = 0.20
KEY_PULSE_FADE_SECONDS = 0.70
KEY_PULSE_HUE_SHIFT = 0.055
KEY_COLOR_CYCLE_SECONDS = 7.5
KEY_COLOR_POSITION_SPAN = 0.72
KEY_HALO_TRAVEL_SECONDS = 0.065
KEY_SPAM_WINDOW_SECONDS = 0.34
KEY_SPAM_TRIGGER_PRESSES = 3
KEY_HOLD_STROBE_DELAY_SECONDS = 0.38
KEY_WHITE_STROBE_HALF_PERIOD_SECONDS = 0.065
KEY_WHITE_STROBE_LINGER_SECONDS = 0.22
NUMBER_WAVE_STEP_SECONDS = 0.105
NUMBER_WAVE_ATTACK_SECONDS = 0.055
NUMBER_WAVE_HOLD_SECONDS = 0.11
NUMBER_WAVE_FADE_SECONDS = 0.52
KEY_GLOW_OFFSETS = (
    (-12, 0.10),
    (-6, 0.22),
    (-1, 0.14),
    (1, 0.14),
    (6, 0.22),
    (12, 0.10),
)
VOLUME_POLL_SECONDS = 0.2
VOLUME_ERROR_RETRY_SECONDS = 2.0
VOLUME_OVERLAY_SECONDS = 1.0
VOLUME_OVERLAY_FADE_SECONDS = 0.22
VOLUME_MUTE_STEP_SECONDS = 0.070
VOLUME_MUTE_HOLD_SECONDS = 0.28
VOLUME_FILL_MAX = 1.0
BLACK = (0.0, 0.0, 0.0)
KEY_PULSE_COLORS = [
    (0, 235, 255),
    (30, 105, 255),
    (140, 55, 255),
    (255, 35, 190),
    (255, 65, 70),
    (255, 175, 35),
    (70, 255, 155),
]
METER_GREEN = (0, 220, 65)
METER_YELLOW = (255, 210, 0)
METER_RED = (255, 35, 20)
WHITE = (255, 255, 255)
GAMING_RAINBOW_CYCLE_SECONDS = 13.0
GAMING_RAINBOW_SPAN = 0.84
GAMING_RAINBOW_BRIGHTNESS = 0.86

PKT_REQUEST_CONTROLLER_COUNT = 0
PKT_REQUEST_CONTROLLER_DATA = 1
PKT_ACK = 10
PKT_REQUEST_PROTOCOL_VERSION = 40
PKT_UPDATE_LEDS = 1050
PKT_SET_CUSTOM_MODE = 1100

CPU_KEYS = [12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72, 78]  # F1-F12
# Bottom to top: End, Page Down, Page Up, Delete.
RAM_KEYS = [88, 87, 86, 85]
METER_KEYS = set(CPU_KEYS + RAM_KEYS)
CAPS_LOCK_LED = 3
CAPS_LOCK_COLOR = WHITE
EV_KEY = 1
EV_LED = 17
KEY_RELEASE = 0
KEY_PRESS = 1
KEY_REPEAT = 2
LED_CAPSL = 1
INPUT_EVENT = struct.Struct("llHHi")
INPUT_RESCAN_INTERVAL = 5.0
CAPS_REFRESH_INTERVAL = 0.25
MODIFIER_SIDE_HINT_SECONDS = 0.35
MODIFIER_DUPLICATE_WINDOW_SECONDS = 0.055
KEYBOARD_LAYOUT_RETRY_SECONDS = 5.0
LANGUAGE_LETTER_STAGGER_SECONDS = 0.18


def log(message):
    print(f"aula-f75-rgb-monitor: {message}", flush=True)


KEY_CODE_TO_LED = {
    1: 0,
    41: 1,
    15: 2,
    58: 3,
    42: 4,
    29: 5,
    2: 7,
    16: 8,
    30: 9,
    44: 10,
    125: 11,
    59: 12,
    3: 13,
    17: 14,
    31: 15,
    45: 16,
    56: 17,
    60: 18,
    4: 19,
    18: 20,
    32: 21,
    46: 22,
    61: 24,
    5: 25,
    19: 26,
    33: 27,
    47: 28,
    62: 30,
    6: 31,
    20: 32,
    34: 33,
    48: 34,
    57: 35,
    63: 36,
    7: 37,
    21: 38,
    35: 39,
    49: 40,
    64: 42,
    8: 43,
    22: 44,
    36: 45,
    50: 46,
    65: 48,
    9: 49,
    23: 50,
    37: 51,
    51: 52,
    66: 54,
    10: 55,
    24: 56,
    38: 57,
    52: 58,
    97: 59,
    100: 53,
    126: 53,
    127: 53,
    139: 53,
    273: 53,
    67: 60,
    11: 61,
    25: 62,
    39: 63,
    53: 64,
    68: 66,
    12: 67,
    26: 68,
    40: 69,
    54: 70,
    87: 72,
    13: 73,
    27: 74,
    105: 77,
    88: 78,
    14: 79,
    43: 80,
    28: 81,
    103: 82,
    108: 83,
    111: 85,
    104: 86,
    109: 87,
    107: 88,
    106: 89,
}

NUMBER_ROW_KEY_CODES = (2, 3, 4, 5, 6, 7, 8, 9, 10, 11)  # 1 through 0
NUMBER_ROW_LEDS = tuple(KEY_CODE_TO_LED[code] for code in NUMBER_ROW_KEY_CODES)
NUMBER_ROW_LED_SET = set(NUMBER_ROW_LEDS)
NUMBER_KEY_CODE_TO_INDEX = {
    code: index for index, code in enumerate(NUMBER_ROW_KEY_CODES)
}

LETTER_TO_KEY_CODE = {
    "Q": 16,
    "W": 17,
    "E": 18,
    "R": 19,
    "T": 20,
    "Y": 21,
    "U": 22,
    "I": 23,
    "O": 24,
    "P": 25,
    "A": 30,
    "S": 31,
    "D": 32,
    "F": 33,
    "G": 34,
    "H": 35,
    "J": 36,
    "K": 37,
    "L": 38,
    "Z": 44,
    "X": 45,
    "C": 46,
    "V": 47,
    "B": 48,
    "N": 49,
    "M": 50,
}

LETTER_TO_LED = {
    letter: KEY_CODE_TO_LED[key_code]
    for letter, key_code in LETTER_TO_KEY_CODE.items()
}

GAMING_MODE_LEDS = [
    KEY_CODE_TO_LED[17],
    KEY_CODE_TO_LED[30],
    KEY_CODE_TO_LED[31],
    KEY_CODE_TO_LED[32],
    KEY_CODE_TO_LED[103],
    KEY_CODE_TO_LED[105],
    KEY_CODE_TO_LED[108],
    KEY_CODE_TO_LED[106],
    KEY_CODE_TO_LED[42],
    KEY_CODE_TO_LED[54],
    KEY_CODE_TO_LED[29],
    KEY_CODE_TO_LED[97],
]

MODIFIER_CODE_TO_SIDE_HINT = {
    29: ("control", 5),
    42: ("shift", 4),
    54: ("shift", 70),
    97: ("control", 59),
}
SIDE_AWARE_MODIFIER_CODES = set(MODIFIER_CODE_TO_SIDE_HINT)

LANGUAGE_LAYOUT_LETTERS = [
    ("arab", "Arabic"),
    ("english", "English"),
]

_discovered_niri_socket = None


def clamp(value):
    return max(0, min(255, int(value)))


def clamp_unit(value):
    return max(0.0, min(1.0, float(value)))


def rgb_value(color):
    red, green, blue = (clamp(channel) for channel in color)
    return red | (green << 8) | (blue << 16)


def blend(a, b, amount):
    return tuple(a[i] + (b[i] - a[i]) * amount for i in range(3))


def screen_blend(a, b):
    """Add light without clipping as harshly as ordinary channel addition."""
    return tuple(255.0 - (255.0 - a[i]) * (255.0 - b[i]) / 255.0 for i in range(3))


def simple_meter_color(index, count):
    """Use clear green/yellow/red zones with no animated hue changes."""
    position = (index + 0.5) / max(1, count)
    if position <= 0.50:
        return METER_GREEN
    if position <= 0.75:
        return METER_YELLOW
    return METER_RED


def volume_key_count(volume):
    """Convert PipeWire's scalar volume to a simple whole-key bar."""
    normalized = clamp_unit(volume / VOLUME_FILL_MAX)
    if normalized <= 0.0:
        return 0
    return min(len(CPU_KEYS), max(1, int(math.ceil(normalized * len(CPU_KEYS)))))


def scale_color(color, amount):
    return tuple(channel * max(0.0, amount) for channel in color)


def smoothstep(amount):
    amount = clamp_unit(amount)
    return amount * amount * (3.0 - 2.0 * amount)


def ease_out_cubic(amount):
    amount = clamp_unit(amount)
    return 1.0 - (1.0 - amount) ** 3


def finalize_color(color):
    """Apply a soft shoulder and perceptual gamma before sending to OpenRGB."""
    corrected = []
    for channel in color:
        linear = max(0.0, channel / 255.0) * MASTER_BRIGHTNESS
        # Compress highlights gently so layered effects retain color detail.
        linear = linear / (1.0 + 0.16 * linear)
        corrected.append(255.0 * (min(1.0, linear) ** (1.0 / OUTPUT_GAMMA)))
    return tuple(corrected)


def pipewire_env():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = runtime_dir
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime_dir}/bus")
    return env


def parse_wpctl_volume(output):
    match = re.search(r"Volume:\s*([0-9]+(?:\.[0-9]+)?)", output, re.IGNORECASE)
    if not match:
        return None
    return max(0.0, float(match.group(1))), "[MUTED]" in output.upper()


def read_cpu_times():
    with open("/proc/stat", encoding="ascii") as stat_file:
        fields = stat_file.readline().split()[1:]
    values = [int(field) for field in fields]
    if len(values) < 4:
        raise RuntimeError("/proc/stat did not contain enough CPU fields")
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    total = sum(values)
    return idle, total


def cpu_percent(previous, current):
    idle_delta = current[0] - previous[0]
    total_delta = current[1] - previous[1]
    if total_delta <= 0:
        return 0.0
    return max(0.0, min(100.0, 100.0 * (1.0 - idle_delta / total_delta)))


def ram_percent():
    values = {}
    with open("/proc/meminfo", encoding="ascii") as meminfo:
        for line in meminfo:
            key, value = line.split(":", 1)
            values[key] = int(value.split()[0])
    total = values.get("MemTotal", 0)
    if total <= 0:
        raise RuntimeError("/proc/meminfo did not report MemTotal")
    available = values.get("MemAvailable")
    if available is None:
        available = (
            values.get("MemFree", 0)
            + values.get("Buffers", 0)
            + values.get("Cached", 0)
            + values.get("SReclaimable", 0)
            - values.get("Shmem", 0)
        )
    return max(0.0, min(100.0, 100.0 * (1.0 - available / total)))


class SystemMonitor:
    """Sample /proc at a sane cadence and smooth meter movement."""

    def __init__(self):
        self.previous_cpu = read_cpu_times()
        self.cpu_usage = 0.0
        self.memory_usage = ram_percent()
        self.next_poll = 0.0

    def poll(self, now):
        if now < self.next_poll:
            return

        self.next_poll = now + SYSTEM_POLL_SECONDS
        current_cpu = read_cpu_times()
        measured_cpu = cpu_percent(self.previous_cpu, current_cpu)
        self.previous_cpu = current_cpu
        self.cpu_usage += (measured_cpu - self.cpu_usage) * CPU_SMOOTHING

        measured_ram = ram_percent()
        self.memory_usage += (measured_ram - self.memory_usage) * RAM_SMOOTHING


class GameModeMonitor:
    def __init__(self):
        self.enabled = False
        self.next_poll = 0.0

    def poll(self, now):
        if now >= self.next_poll:
            self.enabled = niri_game_mode_enabled()
            self.next_poll = now + GAME_MODE_POLL_SECONDS
        return self.enabled


class OpenRGBClient:
    def __init__(self):
        self.sock = socket.create_connection(
            (HOST, PORT),
            timeout=OPENRGB_SOCKET_TIMEOUT_SECONDS,
        )
        self.sock.settimeout(OPENRGB_SOCKET_TIMEOUT_SECONDS)
        try:
            self.protocol = self.request_protocol()
        except Exception:
            self.close()
            raise

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send_packet(self, device_id, packet_id, data=b""):
        header = struct.pack("<4sIII", b"ORGB", device_id, packet_id, len(data))
        self.sock.sendall(header + data)

    def recv_exact(self, size):
        chunks = []
        remaining = size
        while remaining:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise ConnectionError("OpenRGB closed the SDK connection")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def recv_packet(self):
        magic, device_id, packet_id, size = struct.unpack("<4sIII", self.recv_exact(16))
        if magic != b"ORGB":
            raise ValueError("invalid OpenRGB SDK packet")
        if size > OPENRGB_MAX_PACKET_BYTES:
            raise ValueError(f"OpenRGB packet is unreasonably large: {size} bytes")
        return device_id, packet_id, self.recv_exact(size)

    def recv_until(self, packet_id):
        while True:
            device_id, received_id, data = self.recv_packet()
            if received_id == packet_id:
                return device_id, data

    def request_protocol(self):
        self.send_packet(
            0,
            PKT_REQUEST_PROTOCOL_VERSION,
            struct.pack("<I", OPENRGB_MAX_PROTOCOL),
        )
        previous_timeout = self.sock.gettimeout()
        self.sock.settimeout(OPENRGB_NEGOTIATION_TIMEOUT_SECONDS)
        try:
            _, data = self.recv_until(PKT_REQUEST_PROTOCOL_VERSION)
        except socket.timeout:
            # Protocol 0 servers intentionally do not answer this request.
            return 0
        finally:
            self.sock.settimeout(previous_timeout)

        if len(data) < 4:
            raise ValueError("short OpenRGB protocol-version response")
        server_protocol = struct.unpack_from("<I", data, 0)[0]
        return min(server_protocol, OPENRGB_MAX_PROTOCOL)

    def controller_ids(self):
        self.send_packet(0, PKT_REQUEST_CONTROLLER_COUNT)
        _, data = self.recv_until(PKT_REQUEST_CONTROLLER_COUNT)
        if len(data) < 4:
            raise ValueError("short OpenRGB controller-count response")
        count = struct.unpack_from("<I", data, 0)[0]
        if self.protocol >= 6 and len(data) >= 4 + count * 4:
            return list(struct.unpack_from(f"<{count}I", data, 4))
        if self.protocol >= 6:
            raise ValueError("short OpenRGB controller-ID list")
        return list(range(count))

    def controller_name(self, controller_id):
        request_data = struct.pack("<I", self.protocol) if self.protocol >= 1 else b""
        self.send_packet(controller_id, PKT_REQUEST_CONTROLLER_DATA, request_data)
        _, data = self.recv_until(PKT_REQUEST_CONTROLLER_DATA)
        offset = 4 + 4
        if len(data) < offset + 2:
            raise ValueError(f"short OpenRGB controller-data response for {controller_id}")
        name_len = struct.unpack_from("<H", data, offset)[0]
        offset += 2
        if name_len == 0 or offset + name_len > len(data):
            raise ValueError(f"invalid OpenRGB controller name for {controller_id}")
        return data[offset:offset + name_len].rstrip(b"\0").decode("utf-8", "replace")

    def find_controller(self):
        for controller_id in self.controller_ids():
            if self.controller_name(controller_id) == DEVICE_NAME:
                return controller_id
        raise RuntimeError(f"{DEVICE_NAME} was not reported by OpenRGB")

    def update_leds(self, controller_id, colors):
        if len(colors) != LED_COUNT:
            raise ValueError(f"expected {LED_COUNT} LED colors, received {len(colors)}")
        color_data = b"".join(struct.pack("<I", rgb_value(color)) for color in colors)
        payload = struct.pack("<IH", 4 + 2 + len(color_data), len(colors)) + color_data
        self.send_packet(controller_id, PKT_UPDATE_LEDS, payload)
        if self.protocol >= 6:
            self.wait_for_ack(PKT_UPDATE_LEDS)

    def set_custom_mode(self, controller_id):
        self.send_packet(controller_id, PKT_SET_CUSTOM_MODE)
        if self.protocol >= 6:
            self.wait_for_ack(PKT_SET_CUSTOM_MODE)

    def wait_for_ack(self, packet_id):
        while True:
            _, received_packet_id, data = self.recv_packet()
            if received_packet_id != PKT_ACK:
                continue
            if len(data) != 8:
                raise ValueError("invalid OpenRGB ACK packet")
            acked_packet, status = struct.unpack("<II", data)
            if acked_packet == packet_id:
                if status != 0:
                    raise RuntimeError(f"OpenRGB rejected packet {packet_id} with status {status}")
                return


def eviocgled(length):
    return (2 << 30) | (length << 16) | (ord("E") << 8) | 0x19


def caps_lock_enabled(fd):
    led_state = bytearray(8)
    try:
        fcntl.ioctl(fd, eviocgled(len(led_state)), led_state, True)
    except OSError:
        return None
    return bool(led_state[LED_CAPSL // 8] & (1 << (LED_CAPSL % 8)))


def key_pulse_color(led, now=None):
    """Choose a vivid, spatially coherent color for a key press."""
    if now is None:
        now = time.monotonic()
    phase = (
        now / KEY_COLOR_CYCLE_SECONDS
        + (led / max(1, LED_COUNT - 1)) * KEY_COLOR_POSITION_SPAN
        + random.uniform(-0.045, 0.045)
    ) % 1.0
    position = phase * len(KEY_PULSE_COLORS)
    index = int(position)
    return blend(
        KEY_PULSE_COLORS[index % len(KEY_PULSE_COLORS)],
        KEY_PULSE_COLORS[(index + 1) % len(KEY_PULSE_COLORS)],
        smoothstep(position - index),
    )


def random_number_wave_color():
    """Return a saturated random hue for one number-row wave."""
    hue = random.random()
    saturation = random.uniform(0.88, 1.0)
    value = random.uniform(0.90, 1.0)
    red, green, blue = colorsys.hsv_to_rgb(hue, saturation, value)
    return red * 255.0, green * 255.0, blue * 255.0


def gaming_rainbow_color(index, count, now):
    """Create a slowly drifting rainbow distributed over gaming keys."""
    position = index / max(1, count)
    hue = (
        now / GAMING_RAINBOW_CYCLE_SECONDS
        + position * GAMING_RAINBOW_SPAN
    ) % 1.0
    red, green, blue = colorsys.hsv_to_rgb(hue, 0.96, GAMING_RAINBOW_BRIGHTNESS)
    return red * 255.0, green * 255.0, blue * 255.0


def niri_game_mode_enabled():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    return os.path.exists(os.path.join(runtime_dir, "niri-game-mode", "enabled"))


def niri_socket_path():
    configured_path = os.environ.get("NIRI_SOCKET")
    if configured_path:
        try:
            if stat.S_ISSOCK(os.stat(configured_path).st_mode):
                return configured_path
        except OSError:
            pass

    global _discovered_niri_socket
    if _discovered_niri_socket:
        try:
            if stat.S_ISSOCK(os.stat(_discovered_niri_socket).st_mode):
                return _discovered_niri_socket
        except OSError:
            _discovered_niri_socket = None

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    sockets = []
    try:
        for name in os.listdir(runtime_dir):
            if not name.startswith("niri.") or not name.endswith(".sock"):
                continue
            path = os.path.join(runtime_dir, name)
            try:
                path_stat = os.stat(path)
            except OSError:
                continue
            if stat.S_ISSOCK(path_stat.st_mode):
                sockets.append((path_stat.st_mtime_ns, path))
    except OSError:
        return None

    if not sockets:
        return None

    _discovered_niri_socket = max(sockets)[1]
    return _discovered_niri_socket


def invalidate_niri_socket(path):
    global _discovered_niri_socket
    if path and path == _discovered_niri_socket:
        _discovered_niri_socket = None


def read_json_line(file):
    line = file.readline()
    if not line:
        raise ConnectionError("niri socket closed")
    return json.loads(line)


def niri_request(request):
    path = niri_socket_path()
    if path is None:
        return None

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as niri_socket:
            niri_socket.connect(path)
            niri_socket.sendall(json.dumps(request).encode() + b"\n")
            with niri_socket.makefile("r", encoding="utf-8") as socket_file:
                reply = read_json_line(socket_file)
    except OSError:
        invalidate_niri_socket(path)
        raise

    if "Ok" in reply:
        return reply["Ok"]
    if "Err" in reply:
        raise RuntimeError(reply["Err"])
    raise RuntimeError(f"unexpected niri reply: {reply}")


def language_letters_for_layout(name):
    normalized = name.lower()
    for needle, letters in LANGUAGE_LAYOUT_LETTERS:
        if needle in normalized:
            return letters

    letters = "".join(character for character in name.upper() if "A" <= character <= "Z")
    return letters


def discover_keyboard_event_paths():
    try:
        with open("/proc/bus/input/devices", encoding="utf-8", errors="replace") as devices:
            blocks = devices.read().split("\n\n")
    except OSError:
        return {}

    paths = {}
    for block in blocks:
        name_match = re.search(r'^N: Name="([^"]+)"$', block, re.MULTILINE)
        name = name_match.group(1) if name_match else ""

        is_aula = "Vendor=258a" in block and "Product=010c" in block
        is_keyd_virtual_keyboard = name.casefold() == "keyd virtual keyboard"
        if not is_aula and not is_keyd_virtual_keyboard:
            continue

        if "Mouse" in name:
            continue

        handlers_match = re.search(r"^H: Handlers=(.*)$", block, re.MULTILINE)
        if not handlers_match:
            continue
        handlers = handlers_match.group(1).split()
        if "kbd" not in handlers:
            continue

        source = "keyd" if is_keyd_virtual_keyboard else "aula"
        for event_name in re.findall(r"\bevent\d+\b", handlers_match.group(1)):
            paths[f"/dev/input/{event_name}"] = source

    return dict(sorted(paths.items()))


class PressedKeys:
    def __init__(self):
        self.fds = {}
        self.sources = {}
        self.buffers = {}
        self.colors = {}
        self.held_since = {}
        self.recent_presses = {}
        self.white_strobes = {}
        self.caps_lock = False
        self.modifier_side_hints = {}
        self.last_modifier_events = {}
        self.scheduled_pulses = []
        self.number_waves = []
        self.next_scan = 0.0
        self.next_caps_refresh = 0.0
        self.reported_empty = False
        self.rescan(force=True)

    @property
    def paths(self):
        return sorted(self.fds.values())

    def has_keyd_keyboard(self):
        return "keyd" in self.sources.values()

    def has_aula_keyboard(self):
        return "aula" in self.sources.values()

    def rescan(self, force=False):
        now = time.monotonic()
        if not force and now < self.next_scan:
            return

        self.next_scan = now + INPUT_RESCAN_INTERVAL
        known_paths = set(self.fds.values())
        opened = []

        for path, source in discover_keyboard_event_paths().items():
            if path in known_paths:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except PermissionError as exc:
                log(f"cannot read {path}: {exc}")
            except OSError as exc:
                log(f"cannot open {path}: {exc}")
            else:
                self.fds[fd] = path
                self.sources[fd] = source
                self.buffers[fd] = bytearray()
                opened.append(path)

        if opened:
            self.reported_empty = False
            log("watching keyboard input " + ", ".join(opened))
            self.refresh_caps_lock(force=True)
        elif not self.fds and not self.reported_empty:
            log("no readable AULA keyboard input device yet")
            self.reported_empty = True

    def drop_fd(self, fd):
        self.fds.pop(fd, None)
        self.sources.pop(fd, None)
        self.buffers.pop(fd, None)
        try:
            os.close(fd)
        except OSError:
            pass
        if not self.fds:
            self.colors.clear()
            self.held_since.clear()
            self.recent_presses.clear()
            self.white_strobes.clear()
            self.scheduled_pulses.clear()
            self.number_waves.clear()

    def set_key_pulse(self, led, color=None, now=None):
        if now is None:
            now = time.monotonic()
        previous = self.colors.get(led)
        self.colors[led] = (
            color if color is not None else (
                previous[0] if previous else key_pulse_color(led, now)
            ),
            now,
            now + KEY_PULSE_HOLD_SECONDS + KEY_PULSE_FADE_SECONDS,
        )

    def queue_key_sequence(self, letters):
        now = time.monotonic()
        self.scheduled_pulses.clear()
        for index, letter in enumerate(letters.upper()):
            led = LETTER_TO_LED.get(letter)
            if led is not None and led not in METER_KEYS:
                self.scheduled_pulses.append((
                    now + index * LANGUAGE_LETTER_STAGGER_SECONDS,
                    led,
                    key_pulse_color(
                        led,
                        now + index * LANGUAGE_LETTER_STAGGER_SECONDS,
                    ),
                ))

    def run_scheduled_pulses(self, now):
        pending = []
        for starts_at, led, color in self.scheduled_pulses:
            if starts_at <= now:
                self.set_key_pulse(led, color, now=now)
            else:
                pending.append((starts_at, led, color))
        self.scheduled_pulses = pending

    def start_number_wave(self, code, color=None, now=None):
        center = NUMBER_KEY_CODE_TO_INDEX.get(code)
        if center is None:
            return None
        if now is None:
            now = time.monotonic()
        if color is None:
            color = random_number_wave_color()

        self.number_waves.append((center, now, color))
        # Keep rapid typing bounded without cutting off the newest waves.
        if len(self.number_waves) > 12:
            del self.number_waves[:-12]
        return color

    def apply_number_waves(self, active, now):
        pending = []
        for center, started_at, color in self.number_waves:
            age = now - started_at
            farthest = max(center, len(NUMBER_ROW_LEDS) - 1 - center)
            expires_after = (
                farthest * NUMBER_WAVE_STEP_SECONDS
                + NUMBER_WAVE_ATTACK_SECONDS
                + NUMBER_WAVE_HOLD_SECONDS
                + NUMBER_WAVE_FADE_SECONDS
            )
            if age > expires_after:
                continue

            pending.append((center, started_at, color))
            for index, led in enumerate(NUMBER_ROW_LEDS):
                local_age = age - abs(index - center) * NUMBER_WAVE_STEP_SECONDS
                if local_age < 0.0:
                    continue

                if local_age < NUMBER_WAVE_ATTACK_SECONDS:
                    brightness = ease_out_cubic(
                        local_age / NUMBER_WAVE_ATTACK_SECONDS
                    )
                elif local_age < NUMBER_WAVE_ATTACK_SECONDS + NUMBER_WAVE_HOLD_SECONDS:
                    brightness = 1.0
                else:
                    fade_age = (
                        local_age
                        - NUMBER_WAVE_ATTACK_SECONDS
                        - NUMBER_WAVE_HOLD_SECONDS
                    )
                    brightness = 1.0 - smoothstep(
                        fade_age / NUMBER_WAVE_FADE_SECONDS
                    )

                distance_falloff = 1.0 - 0.045 * abs(index - center)
                wave_color = scale_color(color, brightness * distance_falloff)
                active[led] = screen_blend(active.get(led, BLACK), wave_color)

        self.number_waves = pending

    def start_white_strobe(self, led, now):
        previous = self.white_strobes.get(led)
        started_at = previous[0] if previous is not None else now
        expires_at = max(
            previous[1] if previous is not None else now,
            now + KEY_WHITE_STROBE_LINGER_SECONDS,
        )
        self.white_strobes[led] = (started_at, expires_at)

    def note_key_press(self, led, now):
        self.held_since.setdefault(led, now)
        history = [
            pressed_at
            for pressed_at in self.recent_presses.get(led, ())
            if now - pressed_at <= KEY_SPAM_WINDOW_SECONDS
        ]
        history.append(now)
        self.recent_presses[led] = history
        if len(history) >= KEY_SPAM_TRIGGER_PRESSES:
            self.start_white_strobe(led, now)

    def note_key_repeat(self, led, now):
        self.held_since.setdefault(led, now)
        self.start_white_strobe(led, now)

    def note_key_release(self, led, now):
        self.held_since.pop(led, None)
        previous = self.white_strobes.get(led)
        if previous is not None:
            self.white_strobes[led] = (
                previous[0],
                min(previous[1], now + KEY_WHITE_STROBE_LINGER_SECONDS),
            )

    def active_white_strobes(self, now):
        # A held key starts strobing even on systems that do not emit repeat
        # events, while repeat events keep extending the effect naturally.
        for led, pressed_at in list(self.held_since.items()):
            if now - pressed_at >= KEY_HOLD_STROBE_DELAY_SECONDS:
                self.start_white_strobe(led, now)

        states = {}
        for led, (started_at, expires_at) in list(self.white_strobes.items()):
            if now >= expires_at and led not in self.held_since:
                self.white_strobes.pop(led, None)
                continue
            phase = int(
                max(0.0, now - started_at)
                / KEY_WHITE_STROBE_HALF_PERIOD_SECONDS
            )
            states[led] = phase % 2 == 0
        return states

    def active_colors(self, now):
        self.run_scheduled_pulses(now)
        strobe_states = self.active_white_strobes(now)
        active = {}
        for led, (color, started_at, expires_at) in list(self.colors.items()):
            remaining = expires_at - now
            if remaining <= 0:
                self.colors.pop(led, None)
                continue

            if led in strobe_states:
                continue

            age = now - started_at
            brightness = ease_out_cubic(age / KEY_PULSE_ATTACK_SECONDS)
            if remaining < KEY_PULSE_FADE_SECONDS:
                brightness *= smoothstep(remaining / KEY_PULSE_FADE_SECONDS)

            # A brief white-hot core gives every press a crisp leading edge.
            highlight = smoothstep(1.0 - age / (KEY_PULSE_ATTACK_SECONDS * 2.4)) * 0.58
            hue, saturation, value = colorsys.rgb_to_hsv(
                color[0] / 255.0,
                color[1] / 255.0,
                color[2] / 255.0,
            )
            hue = (hue + KEY_PULSE_HUE_SHIFT * smoothstep(age / KEY_PULSE_FADE_SECONDS)) % 1.0
            shifted = colorsys.hsv_to_rgb(hue, saturation, value)
            shifted = tuple(channel * 255.0 for channel in shifted)
            core = scale_color(blend(shifted, (255, 255, 255), highlight), brightness)
            active[led] = screen_blend(active.get(led, BLACK), core)

            # Number keys get a dedicated left/right row wave instead of the
            # generic six-key-column halo.
            if led in NUMBER_ROW_LED_SET:
                continue

            # The controller orders most keys in six-key columns, so these
            # offsets form a compact vertical/horizontal halo around a press.
            for offset, strength in KEY_GLOW_OFFSETS:
                halo_led = led + offset
                if not 0 <= halo_led < LED_COUNT or halo_led in METER_KEYS:
                    continue

                distance = min(1.0, abs(offset) / 12.0)
                halo_age = age - distance * KEY_HALO_TRAVEL_SECONDS
                if halo_age <= 0.0:
                    continue
                halo_rise = smoothstep(halo_age / 0.10)
                halo_tail = smoothstep(remaining / KEY_PULSE_FADE_SECONDS)
                halo_envelope = brightness * halo_rise * halo_tail
                halo = scale_color(shifted, strength * halo_envelope)
                active[halo_led] = screen_blend(active.get(halo_led, BLACK), halo)

        self.apply_number_waves(active, now)

        # The strobe is an override: its dark phase must stay completely off,
        # even if another halo or number-row wave would otherwise light the key.
        for led, is_on in strobe_states.items():
            if is_on:
                active[led] = WHITE
            else:
                active.pop(led, None)
        return active

    def remember_modifier_side(self, code, value):
        hint = MODIFIER_CODE_TO_SIDE_HINT.get(code)
        if hint is None or value not in (KEY_PRESS, KEY_REPEAT):
            return
        family, led = hint
        self.modifier_side_hints[family] = (
            led,
            time.monotonic() + MODIFIER_SIDE_HINT_SECONDS,
        )

    def modifier_led_override(self, code):
        hint = MODIFIER_CODE_TO_SIDE_HINT.get(code)
        if hint is None:
            return None

        family, _ = hint
        side_hint = self.modifier_side_hints.get(family)
        if side_hint is None:
            return None

        led, expires_at = side_hint
        if time.monotonic() > expires_at:
            self.modifier_side_hints.pop(family, None)
            return None
        return led

    def modifier_event_is_duplicate(self, led, code, value, now):
        if code not in SIDE_AWARE_MODIFIER_CODES or value not in (KEY_PRESS, KEY_REPEAT):
            return False

        event = (led, value)
        previous = self.last_modifier_events.get(event)
        self.last_modifier_events[event] = now
        return previous is not None and now - previous < MODIFIER_DUPLICATE_WINDOW_SECONDS

    def apply_key_event(self, led, code, value):
        if led is None or led in METER_KEYS:
            return

        now = time.monotonic()
        if self.modifier_event_is_duplicate(led, code, value, now):
            return

        if value == KEY_PRESS:
            self.note_key_press(led, now)
            if code in NUMBER_KEY_CODE_TO_INDEX:
                color = random_number_wave_color()
                self.set_key_pulse(led, color, now=now)
                self.start_number_wave(code, color=color, now=now)
            else:
                self.set_key_pulse(led, key_pulse_color(led, now), now=now)
        elif value == KEY_REPEAT:
            self.note_key_repeat(led, now)
            self.set_key_pulse(led, now=now)
        elif value == KEY_RELEASE:
            self.note_key_release(led, now)
        else:
            log(f"unexpected key event code={code} value={value}")

    def refresh_caps_lock(self, force=False):
        now = time.monotonic()
        if not force and now < self.next_caps_refresh:
            return

        self.next_caps_refresh = now + CAPS_REFRESH_INTERVAL
        queried = False
        enabled = False
        for fd in self.fds:
            state = caps_lock_enabled(fd)
            if state is None:
                continue
            queried = True
            enabled = enabled or state
        if queried:
            self.caps_lock = enabled

    def handle_event(self, source, event_type, code, value):
        if event_type == EV_LED and code == LED_CAPSL:
            self.caps_lock = bool(value)
            return

        if event_type != EV_KEY:
            return

        if source == "aula" and self.has_keyd_keyboard():
            self.remember_modifier_side(code, value)
            if code in SIDE_AWARE_MODIFIER_CODES:
                self.apply_key_event(KEY_CODE_TO_LED.get(code), code, value)
            return

        if source != "keyd":
            self.remember_modifier_side(code, value)
            self.apply_key_event(KEY_CODE_TO_LED.get(code), code, value)
            return

        led = self.modifier_led_override(code) if source == "keyd" and code in (29, 42) else None
        if led is None:
            led = KEY_CODE_TO_LED.get(code)
        self.apply_key_event(led, code, value)

    def poll(self):
        self.rescan()
        self.refresh_caps_lock()

        while self.fds:
            try:
                readable, _, _ = select.select(list(self.fds), [], [], 0)
            except InterruptedError:
                return
            except OSError:
                for fd in list(self.fds):
                    self.drop_fd(fd)
                return

            if not readable:
                return

            for fd in readable:
                try:
                    data = os.read(fd, INPUT_EVENT.size * 64)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    if exc.errno in (errno.ENODEV, errno.EIO):
                        self.drop_fd(fd)
                        continue
                    raise

                if not data:
                    self.drop_fd(fd)
                    continue

                buffer = self.buffers.setdefault(fd, bytearray())
                buffer.extend(data)
                complete_size = len(buffer) - (len(buffer) % INPUT_EVENT.size)
                complete = bytes(buffer[:complete_size])
                del buffer[:complete_size]

                for offset in range(0, len(complete), INPUT_EVENT.size):
                    _, _, event_type, code, value = INPUT_EVENT.unpack_from(complete, offset)
                    self.handle_event(self.sources.get(fd), event_type, code, value)


class VolumeMonitor:
    def __init__(self):
        self.volume = 0.0
        self.muted = False
        self.previous_state = None
        self.env = pipewire_env()
        self.next_poll = 0.0
        self.overlay_started = 0.0
        self.overlay_until = 0.0
        self.transition_from_count = 0
        self.transition_to_count = 0
        self.transition_duration = 0.0

    def start_level_overlay(self, now, key_count):
        self.overlay_started = now
        self.overlay_until = now + VOLUME_OVERLAY_SECONDS
        self.transition_from_count = key_count
        self.transition_to_count = key_count
        self.transition_duration = 0.0

    def start_mute_transition(self, now, from_count, to_count):
        self.overlay_started = now
        self.transition_from_count = from_count
        self.transition_to_count = to_count
        self.transition_duration = max(
            VOLUME_MUTE_STEP_SECONDS,
            abs(to_count - from_count) * VOLUME_MUTE_STEP_SECONDS,
        )
        self.overlay_until = (
            now
            + self.transition_duration
            + VOLUME_MUTE_HOLD_SECONDS
            + VOLUME_OVERLAY_FADE_SECONDS
        )

    def poll(self, now):
        if now < self.next_poll:
            return

        self.next_poll = now + VOLUME_POLL_SECONDS
        try:
            result = subprocess.run(
                ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
                check=False,
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=0.35,
            )
        except (OSError, subprocess.SubprocessError):
            self.next_poll = now + VOLUME_ERROR_RETRY_SECONDS
            return

        if result.returncode != 0:
            self.next_poll = now + VOLUME_ERROR_RETRY_SECONDS
            return

        state = parse_wpctl_volume(result.stdout)
        if state is None:
            return

        volume, muted = state
        if self.previous_state is not None:
            previous_volume, previous_muted = self.previous_state
            if muted != previous_muted:
                if muted:
                    self.start_mute_transition(
                        now,
                        volume_key_count(previous_volume),
                        0,
                    )
                else:
                    self.start_mute_transition(
                        now,
                        0,
                        volume_key_count(volume),
                    )
            elif not muted and abs(volume - previous_volume) > 0.002:
                self.start_level_overlay(now, volume_key_count(volume))

        self.volume = volume
        self.muted = muted
        self.previous_state = state

    def active(self, now):
        return now < self.overlay_until

    def displayed_key_count(self, now):
        if self.transition_duration <= 0.0:
            return self.transition_to_count

        progress = clamp_unit((now - self.overlay_started) / self.transition_duration)
        value = self.transition_from_count + (
            self.transition_to_count - self.transition_from_count
        ) * progress

        if self.transition_to_count < self.transition_from_count:
            return max(self.transition_to_count, int(math.ceil(value - 1e-9)))
        return min(self.transition_to_count, int(math.floor(value + 1e-9)))

    def opacity(self, now):
        remaining = self.overlay_until - now
        if remaining <= 0.0:
            return 0.0
        if remaining >= VOLUME_OVERLAY_FADE_SECONDS:
            return 1.0
        return smoothstep(remaining / VOLUME_OVERLAY_FADE_SECONDS)


class KeyboardLayoutMonitor:
    def __init__(self):
        self.current_idx = None
        self.current_name = None
        self.layout_names = []
        self.pending_letters = None
        self.reported_error = None
        self.lock = threading.Lock()
        self.refresh_current_layout(force=True)
        self.thread = threading.Thread(
            target=self.event_loop,
            name="niri-layout-monitor",
            daemon=True,
        )
        self.thread.start()

    def event_loop(self):
        while True:
            path = None
            try:
                self.refresh_current_layout(force=True)
                path = niri_socket_path()
                if path is None:
                    raise RuntimeError("no niri socket found")

                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as niri_socket:
                    niri_socket.connect(path)
                    niri_socket.sendall(json.dumps("EventStream").encode() + b"\n")
                    with niri_socket.makefile("r", encoding="utf-8") as socket_file:
                        self.reported_error = None
                        for line in socket_file:
                            self.handle_event(json.loads(line))
            except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
                invalidate_niri_socket(path)
                message = str(exc)
                if message != self.reported_error:
                    log(f"niri layout monitor: {message}")
                    self.reported_error = message
            time.sleep(KEYBOARD_LAYOUT_RETRY_SECONDS)

    def refresh_current_layout(self, force=False):
        if self.current_idx is not None and not force:
            return

        try:
            response = niri_request("KeyboardLayouts")
        except (OSError, RuntimeError, json.JSONDecodeError):
            return

        if not isinstance(response, dict):
            return

        keyboard_layouts = response.get("KeyboardLayouts")
        if not isinstance(keyboard_layouts, dict):
            return

        self.handle_keyboard_layouts(
            keyboard_layouts,
            queue_on_change=self.current_idx is not None,
        )

    def handle_keyboard_layouts(self, keyboard_layouts, queue_on_change):
        try:
            current_idx = keyboard_layouts["current_idx"]
            names = keyboard_layouts["names"]
            if not isinstance(names, (list, tuple)):
                return
            name = names[current_idx]
        except (KeyError, TypeError, ValueError, IndexError):
            return
        if not isinstance(name, str):
            return

        previous_idx = self.current_idx
        previous_name = self.current_name
        self.layout_names = list(names)
        self.current_idx = current_idx
        self.current_name = name

        if previous_idx is None or (
            current_idx == previous_idx and name == previous_name
        ):
            return

        if queue_on_change:
            self.queue_layout_letters(name)

    def handle_layout_switch(self, idx):
        try:
            idx = int(idx)
        except (TypeError, ValueError):
            return

        if idx < 0 or idx >= len(self.layout_names):
            return

        name = self.layout_names[idx]
        if not isinstance(name, str):
            return
        if idx == self.current_idx and name == self.current_name:
            return

        self.current_idx = idx
        self.current_name = name
        self.queue_layout_letters(self.current_name)

    def queue_layout_letters(self, name):
        letters = language_letters_for_layout(name)
        if not letters:
            return

        log(f"keyboard layout {name} -> {letters}")
        with self.lock:
            # Only the latest layout matters if several switches happen while
            # OpenRGB is reconnecting or the render loop is busy.
            self.pending_letters = letters

    def handle_event(self, event):
        if not isinstance(event, dict):
            return

        keyboard_layouts_changed = event.get("KeyboardLayoutsChanged")
        if isinstance(keyboard_layouts_changed, dict):
            keyboard_layouts = keyboard_layouts_changed.get("keyboard_layouts")
            if isinstance(keyboard_layouts, dict):
                self.handle_keyboard_layouts(keyboard_layouts, queue_on_change=True)
            return

        keyboard_layout_switched = event.get("KeyboardLayoutSwitched")
        if isinstance(keyboard_layout_switched, dict):
            self.handle_layout_switch(keyboard_layout_switched.get("idx"))

    def poll(self, pressed_keys):
        with self.lock:
            if self.pending_letters is None:
                return
            letters = self.pending_letters
            self.pending_letters = None

        pressed_keys.queue_key_sequence(letters)


def apply_simple_bar(colors, keys, usage, minimum_fill=0.0):
    filled = max(
        minimum_fill,
        max(0.0, min(float(len(keys)), (usage / 100.0) * len(keys))),
    )
    for index, led in enumerate(keys):
        fill = smoothstep(clamp_unit(filled - index))
        colors[led] = scale_color(simple_meter_color(index, len(keys)), fill)


def apply_cpu_bar(colors, usage, now):
    del now
    apply_simple_bar(colors, CPU_KEYS, usage)


def apply_ram_bar(colors, usage, now):
    del now
    # RAM is always visible on End -> PgDn -> PgUp -> Delete. Even very low
    # usage keeps the End key lit so the meter never disappears.
    apply_simple_bar(colors, RAM_KEYS, usage, minimum_fill=1.0)


def apply_volume_bar(colors, volume_monitor, now):
    opacity = volume_monitor.opacity(now)
    # Volume owns the whole F-key row while its overlay is active. Empty keys
    # are fully black; there is deliberately no dim background glow.
    for led in CPU_KEYS:
        colors[led] = BLACK

    if opacity <= 0.0:
        return

    lit_count = volume_monitor.displayed_key_count(now)
    for index, led in enumerate(CPU_KEYS[:lit_count]):
        colors[led] = scale_color(simple_meter_color(index, len(CPU_KEYS)), opacity)


def render_frame(
    pressed_keys,
    volume_monitor,
    layout_monitor,
    game_mode_monitor,
    cpu_usage,
    memory_usage,
    now,
):
    pressed_keys.poll()
    volume_monitor.poll(now)
    layout_monitor.poll(pressed_keys)

    # Start from absolute black. Only meaningful state and reactive effects light
    # a key; there is no idle wash or background animation.
    colors = [BLACK for _ in range(LED_COUNT)]
    for led, color in pressed_keys.active_colors(now).items():
        if led not in METER_KEYS:
            colors[led] = screen_blend(colors[led], color)

    if game_mode_monitor.poll(now):
        for index, led in enumerate(GAMING_MODE_LEDS):
            colors[led] = screen_blend(
                colors[led],
                gaming_rainbow_color(index, len(GAMING_MODE_LEDS), now),
            )

    if pressed_keys.caps_lock:
        caps_pulse = 0.62 + 0.32 * (0.5 + 0.5 * math.sin(now * math.tau / 1.8))
        colors[CAPS_LOCK_LED] = screen_blend(
            colors[CAPS_LOCK_LED],
            scale_color(CAPS_LOCK_COLOR, caps_pulse),
        )

    if volume_monitor.active(now):
        apply_volume_bar(colors, volume_monitor, now)
    else:
        apply_cpu_bar(colors, cpu_usage, now)
    apply_ram_bar(colors, memory_usage, now)
    return [finalize_color(color) for color in colors]


def run_monitor():
    pressed_keys = PressedKeys()
    volume_monitor = VolumeMonitor()
    layout_monitor = KeyboardLayoutMonitor()
    system_monitor = SystemMonitor()
    game_mode_monitor = GameModeMonitor()

    while True:
        client = None
        try:
            client = OpenRGBClient()
            controller_id = client.find_controller()
            client.set_custom_mode(controller_id)
            log(
                "connected to OpenRGB controller "
                f"{controller_id}; CPU keys={CPU_KEYS}; RAM keys={RAM_KEYS}; "
                f"keypress input={pressed_keys.paths}; protocol={client.protocol}"
            )

            next_frame = time.monotonic()
            while True:
                now = time.monotonic()
                system_monitor.poll(now)

                frame = render_frame(
                    pressed_keys,
                    volume_monitor,
                    layout_monitor,
                    game_mode_monitor,
                    system_monitor.cpu_usage,
                    system_monitor.memory_usage,
                    now,
                )
                client.update_leds(controller_id, frame)

                next_frame += FRAME_INTERVAL_SECONDS
                sleep_for = next_frame - time.monotonic()
                if sleep_for > 0.0:
                    time.sleep(sleep_for)
                else:
                    # Do not accumulate an ever-growing lag after a slow frame.
                    next_frame = time.monotonic()
        except Exception as exc:
            log(f"{exc}; retrying")
            if DEBUG_TRACEBACKS:
                traceback.print_exc()
            time.sleep(OPENRGB_RECONNECT_SECONDS)
        finally:
            if client is not None:
                client.close()


if __name__ == "__main__":
    run_monitor()