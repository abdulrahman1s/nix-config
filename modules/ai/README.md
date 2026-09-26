# Personal AI stack

The Vicinae extension offers five text workflows: **Summarize**, **Extract action
items**, **Explain**, **Translate**, and **Rewrite**. They accept clipboard or
entered text, keep the source on the private local model route, and display the
result in Vicinae for copying or pasting. `Mod+A` opens the workflow list.

The Bun runner accepts only the IDs registered in `workflows/registry.ts`.
Each recipe lives in `workflows/`; `workflows/shared.ts` handles clipboard input
and the backend request. The default adapter in `backends/openai.ts` calls the
privacy router at `127.0.0.1:4100`.

Selecting `vision-online` explicitly permits the current image request to reach
the cloud model. The normal `privacy-auto` route checks the whole conversation
and sends private or uncertain requests to the local model.

In GNOME Files, right-click the empty area of a writable local folder and choose
**Sort files**. The local model sees top-level filenames, guessed MIME types, and
sizes, then proposes up to eight topic folders. A checklist previews every move;
uncheck mistakes or cancel. Existing names are never overwritten. Hidden files,
symlinks, directories, and unfinished downloads are skipped. Up to 80 files are
handled per run, so larger folders can be sorted in batches. Folder contents are
not sent to the model.

Cloud credentials remain available only to LiteLLM. No scheduled or notification
workflow services are configured.

The original workflow data under `~/AI/private/` is retained. It is not deleted
by configuration changes; `~/AI` remains persisted across boots.

Builds do not activate the configuration or replace the currently installed
Vicinae extension.
