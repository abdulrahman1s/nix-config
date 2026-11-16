#!/usr/bin/env python3
"""Keep a normal X11 arrow in S4MP while Wine cannot share WebView2 cursors."""
import ctypes as c
from pathlib import Path
import os
import sys
import time


def main():
    x = c.CDLL(os.environ["S4MP_LIBX11"])
    window = c.c_ulong
    display = c.c_void_p
    x.XOpenDisplay.argtypes = [c.c_char_p]
    x.XOpenDisplay.restype = display
    x.XDefaultRootWindow.argtypes = [display]
    x.XDefaultRootWindow.restype = window
    x.XQueryTree.argtypes = [display, window, c.POINTER(window),
                            c.POINTER(window), c.POINTER(c.POINTER(window)),
                            c.POINTER(c.c_uint)]
    x.XFetchName.argtypes = [display, window, c.POINTER(c.c_void_p)]
    x.XFree.argtypes = [c.c_void_p]
    x.XCreateFontCursor.argtypes = [display, c.c_uint]
    x.XCreateFontCursor.restype = c.c_ulong
    x.XDefineCursor.argtypes = [display, window, c.c_ulong]
    x.XFlush.argtypes = [display]
    x.XFreeCursor.argtypes = [display, c.c_ulong]
    x.XCloseDisplay.argtypes = [display]
    # A window can close between querying the tree and defining its cursor.
    error_handler_type = c.CFUNCTYPE(c.c_int, display, c.c_void_p)
    error_handler = error_handler_type(lambda *_: 0)
    x.XSetErrorHandler.argtypes = [error_handler_type]
    x.XSetErrorHandler(error_handler)
    d = x.XOpenDisplay(None)
    if not d:
        raise RuntimeError("Cannot open the X11 display")
    root = x.XDefaultRootWindow(d)
    arrow = x.XCreateFontCursor(d, 68)  # XC_left_ptr

    def children(w):
        r, parent, count = window(), window(), c.c_uint()
        items = c.POINTER(window)()
        if not x.XQueryTree(d, w, c.byref(r), c.byref(parent),
                            c.byref(items), c.byref(count)):
            return []
        result = list(items[:count.value])
        if items:
            x.XFree(items)
        return result

    def title(w):
        value = c.c_void_p()
        if not x.XFetchName(d, w, c.byref(value)) or not value:
            return b""
        name = c.string_at(value)
        x.XFree(value)
        return name

    def set_arrow(w):
        x.XDefineCursor(d, w, arrow)
        for child in children(w):
            set_arrow(child)

    parent_pid = int(sys.argv[1]) if len(sys.argv) > 1 else None
    try:
        while parent_pid is None or Path(f"/proc/{parent_pid}").exists():
            targets = [w for w in children(root)
                       if title(w) == b"S4MP Online Launcher"]
            for w in targets:
                set_arrow(w)
            x.XFlush(d)
            if parent_pid is None:
                print(f"Applied arrow to {len(targets)} S4MP window(s)")
                break
            time.sleep(0.15)
    finally:
        x.XFreeCursor(d, arrow)
        x.XCloseDisplay(d)


if __name__ == "__main__":
    main()
