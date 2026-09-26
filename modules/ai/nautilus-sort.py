"""Add a local AI sorter to the GNOME Files folder background menu."""

import subprocess

import gi

gi.require_version("Nautilus", "4.0")
from gi.repository import GObject, Nautilus


SORTER = "@SORTER_EXECUTABLE@"


class PersonalAiSortMenu(GObject.GObject, Nautilus.MenuProvider):
    def get_background_items(self, current_folder):
        location = current_folder.get_location()
        folder = location.get_path() if location is not None else None
        if not folder or not current_folder.can_write():
            return []

        item = Nautilus.MenuItem(
            name="PersonalAiSortMenu::SortFiles",
            label="Sort files",
        )
        item.connect("activate", self._activate, folder)
        return [item]

    def _activate(self, _item, folder):
        subprocess.Popen(
            [SORTER, folder],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
