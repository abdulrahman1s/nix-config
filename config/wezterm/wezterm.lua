local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- Faster startup
config.check_for_updates = false

config.max_fps = 240
config.scrollback_lines = 10000

-- No title bar
config.window_decorations = "NONE"

config.hide_tab_bar_if_only_one_tab = true


-- Opacity
config.window_background_opacity = 0.7

-- Font
config.font_size = 20
config.font = wezterm.font_with_fallback({
  "FiraCode Nerd Font",
  "DejaVu Sans",
  "Noto Naskh Arabic",
})


-- Arabic / RTL support
config.bidi_enabled = true
config.bidi_direction = "LeftToRight"
config.allow_square_glyphs_to_overflow_width = "Always"

-- Disable close confirmation

config.skip_close_confirmation_for_processes_named = {
  'zsh',
  'bash',
  'fish',
  'sh',
}

config.window_close_confirmation = "AlwaysPrompt" -- "NeverPrompt"

return config
