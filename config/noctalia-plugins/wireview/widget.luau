local hwmonRoot = "/sys/class/hwmon"
local devicePath = nil
local pending = false

noctalia.setUpdateInterval(noctalia.getConfig("refresh_ms") or 2000)
barWidget.setGlyph(noctalia.getConfig("bar_glyph") or "bolt")

local attributes = {
  "power1_input", "power1_cap", "power1_alarm", "energy1_input",
  "in6_input", "in7_input", "curr7_input", "curr7_alarm",
  "pwm1", "intrusion0_alarm", "intrusion1_alarm",
  "fault_status_raw", "fault_log_raw",
}
for pin = 1, 6 do
  table.insert(attributes, "in" .. (pin - 1) .. "_input")
  table.insert(attributes, "curr" .. pin .. "_input")
  table.insert(attributes, "curr" .. pin .. "_alarm")
  table.insert(attributes, "power" .. (pin + 1) .. "_input")
end
for channel = 1, 4 do
  table.insert(attributes, "temp" .. channel .. "_input")
  table.insert(attributes, "temp" .. channel .. "_alarm")
end

local function style(severity)
  local color = noctalia.getConfig("bar_color")
  local glyph = noctalia.getConfig("bar_glyph") or "bolt"
  if severity == "fault" then
    if noctalia.getConfig("highlight_faults") then color = "error" end
    if noctalia.getConfig("show_alert_icon") then glyph = "alert-triangle" end
  elseif severity == "warning" then
    if noctalia.getConfig("highlight_warnings") then
      color = noctalia.getConfig("warning_color")
      if color == "amber" or color == nil then
        color = noctalia.isDarkMode() and "#FBBF24" or "#B45309"
      end
    end
    if noctalia.getConfig("show_alert_icon") then glyph = "alert-circle" end
  end
  if color == nil or color == "default" then color = "on_surface" end
  local mode = color == "on_surface" and nil or "script"
  barWidget.setColor(color, mode)
  barWidget.setGlyphColor(color, mode)
  barWidget.setGlyph(glyph)
end

local function unavailable(message)
  devicePath = nil
  barWidget.setText("—")
  barWidget.setTooltip(message)
  style("warning")
end

local function discover()
  local entries = noctalia.listDir(hwmonRoot)
  if entries == nil then return nil end
  table.sort(entries)
  for _, entry in ipairs(entries) do
    if string.match(entry, "^hwmon%d+$") then
      local path = hwmonRoot .. "/" .. entry
      local name = noctalia.readFile(path .. "/name")
      if name ~= nil and noctalia.string.trim(name) == "wireview" then return path end
    end
  end
  return nil
end

local function scaled(value, divisor, format, unit)
  if value == nil then return "—" end
  return string.format(format, value / divisor) .. " " .. unit
end

local function add(rows, label, value)
  table.insert(rows, { label, value })
end

local function section(rows, label)
  add(rows, "", "")
  add(rows, label, "")
end

local function appendSection(rows, label, details)
  if #details == 0 then return end
  if #rows > 0 then section(rows, label) else add(rows, label, "") end
  for _, detail in ipairs(details) do table.insert(rows, detail) end
end

local function barScaled(value, divisor, decimals, unit)
  if value == nil then return "—" end
  local chosen = noctalia.getConfig("bar_decimals")
  if chosen == nil or chosen < 0 then chosen = decimals end
  return string.format("%." .. chosen .. "f", value / divisor) .. " " .. unit
end

local function imbalance(values)
  local lowest, highest, sum = nil, nil, 0
  for pin = 1, 6 do
    local current = values["curr" .. pin .. "_input"]
    if current == nil then return nil end
    lowest = lowest and math.min(lowest, current) or current
    highest = highest and math.max(highest, current) or current
    sum = sum + current
  end
  if sum <= 0 then return nil end
  return (highest - lowest) / (sum / 6) * 100
end

local faultNames = {
  "Chip over-temperature", "Sensor over-temperature", "Over-current",
  "Wire over-current", "Over-power", "Current imbalance",
}

local function faultReasons(mask, alarm)
  local reasons = {}
  if mask ~= nil and mask > 0 then
    for bit = 0, 5 do
      if math.floor(mask / (2 ^ bit)) % 2 == 1 then table.insert(reasons, faultNames[bit + 1]) end
    end
  end
  if #reasons == 0 and ((mask ~= nil and mask > 0) or alarm == 1) then
    table.insert(reasons, "Device fault")
  end
  return reasons
end

local function render(values)
  local rows = {}
  local currentImbalance = imbalance(values)
  local lowest, highest = nil, nil
  for pin = 1, 6 do
    local voltage = values["in" .. (pin - 1) .. "_input"]
    if voltage == nil then lowest = nil; break end
    lowest = lowest and math.min(lowest, voltage) or voltage
    highest = highest and math.max(highest, voltage) or voltage
  end
  local voltageSpread = lowest ~= nil and lowest > 0 and (highest - lowest) / lowest * 100 or nil

  local faults = faultReasons(values.fault_status_raw, values.intrusion0_alarm)
  local warnings = {}
  local powerLimit = noctalia.getConfig("power_warning_watts") or 0
  local imbalanceLimit = noctalia.getConfig("imbalance_warning_percent") or 0
  local temperatureLimit = noctalia.getConfig("temperature_warning_c") or 0
  if powerLimit > 0 and values.power1_input / 1000000 >= powerLimit then
    table.insert(warnings, "Power above " .. powerLimit .. " W")
  end
  if imbalanceLimit > 0 and currentImbalance ~= nil and currentImbalance >= imbalanceLimit then
    table.insert(warnings, "Current imbalance above " .. imbalanceLimit .. "%")
  end
  if temperatureLimit > 0 then
    for channel = 1, 4 do
      local temperature = values["temp" .. channel .. "_input"]
      if temperature ~= nil and temperature / 1000 >= temperatureLimit then
        table.insert(warnings, "Temperature " .. channel .. " above " .. temperatureLimit .. "°C")
      end
    end
  end
  local severity = #faults > 0 and "fault" or (#warnings > 0 and "warning" or "normal")
  if noctalia.getConfig("show_status_row") then
    local status = "OK"
    if #faults > 0 then status = "FAULT: " .. table.concat(faults, ", ")
    elseif #warnings > 0 then status = "WARNING: " .. table.concat(warnings, ", ") end
    add(rows, "Status", status)
  end

  if noctalia.getConfig("show_total_power") then
    add(rows, "Total power", scaled(values.power1_input, 1000000, "%.1f", "W"))
  end
  if noctalia.getConfig("show_total_current") then
    add(rows, "Total current", scaled(values.curr7_input, 1000, "%.2f", "A"))
  end
  if noctalia.getConfig("show_avg_voltage") then
    add(rows, "Average voltage", scaled(values.in6_input, 1000, "%.2f", "V"))
  end
  if noctalia.getConfig("show_imbalance") then
    add(rows, "Current imbalance (max−min / mean)", scaled(currentImbalance, 1, "%.1f", "%"))
  end
  if noctalia.getConfig("show_voltage_spread") then
    add(rows, "Voltage spread (max−min / min)", scaled(voltageSpread, 1, "%.2f", "%"))
  end

  if noctalia.getConfig("show_pins") then
    local details = {}
    for pin = 1, 6 do
      if noctalia.getConfig("pin" .. pin) then
        if noctalia.getConfig("pin_voltage") then
          add(details, "Pin " .. pin .. " voltage", scaled(values["in" .. (pin - 1) .. "_input"], 1000, "%.2f", "V"))
        end
        if noctalia.getConfig("pin_current") then
          add(details, "Pin " .. pin .. " current", scaled(values["curr" .. pin .. "_input"], 1000, "%.2f", "A"))
        end
        if noctalia.getConfig("pin_power") then
          add(details, "Pin " .. pin .. " power", scaled(values["power" .. (pin + 1) .. "_input"], 1000000, "%.1f", "W"))
        end
      end
    end
    appendSection(rows, "Pins", details)
  end

  if noctalia.getConfig("show_temperatures") then
    local details = {}
    local labels = { "Onboard in", "Onboard out", "External 1", "External 2" }
    local keys = { "temp_in", "temp_out", "temp_ext1", "temp_ext2" }
    for channel = 1, 4 do
      if noctalia.getConfig(keys[channel]) then
        add(details, labels[channel], scaled(values["temp" .. channel .. "_input"], 1000, "%.1f", "°C"))
      end
    end
    appendSection(rows, "Temperatures", details)
  end

  if noctalia.getConfig("show_other") then
    local details = {}
    if noctalia.getConfig("show_vdd") then
      add(details, "Supply voltage (Vdd)", scaled(values.in7_input, 1000, "%.2f", "V"))
    end
    if noctalia.getConfig("show_energy") then
      add(details, "Energy since daemon start", scaled(values.energy1_input, 1000000, "%.1f", "J"))
    end
    if noctalia.getConfig("show_psu_cap") then
      add(details, "PSU capability", scaled(values.power1_cap, 1000000, "%.0f", "W"))
    end
    if noctalia.getConfig("show_fan") then
      add(details, "Fan duty", scaled(values.pwm1, 255, "%.0f", "%"))
    end
    if noctalia.getConfig("show_psu_load") and values.power1_cap ~= nil and values.power1_cap > 0 then
      add(details, "PSU load", scaled(values.power1_input / values.power1_cap * 100, 1, "%.1f", "%"))
    end
    if noctalia.getConfig("show_power_meter") and values.power1_cap ~= nil and values.power1_cap > 0 then
      local ratio = math.min(1, math.max(0, values.power1_input / values.power1_cap))
      local filled = math.floor(ratio * 10 + 0.5)
      add(details, "PSU meter", string.rep("▰", filled) .. string.rep("▱", 10 - filled))
    end
    appendSection(rows, "Other sensors", details)
  end

  if noctalia.getConfig("show_faults") then
    local details = {}
    local alarms = { { "Fault status", "intrusion0_alarm" }, { "Fault log", "intrusion1_alarm" } }
    if noctalia.getConfig("show_alarm_details") then
      table.insert(alarms, { "Total power", "power1_alarm" })
      table.insert(alarms, { "Total current", "curr7_alarm" })
      for pin = 1, 6 do
        if noctalia.getConfig("pin" .. pin) then
          table.insert(alarms, { "Pin " .. pin .. " current", "curr" .. pin .. "_alarm" })
        end
      end
      for channel = 1, 4 do table.insert(alarms, { "Temperature " .. channel, "temp" .. channel .. "_alarm" }) end
    end
    for _, alarm in ipairs(alarms) do
      local value = values[alarm[2]]
      add(details, alarm[1] .. " alarm", value == nil and "—" or (value == 0 and "OK" or "ALARM"))
    end
    if noctalia.getConfig("show_raw_faults") then
      add(details, "Fault status raw", values.fault_status_raw and string.format("0x%X", values.fault_status_raw) or "—")
      add(details, "Fault log raw", values.fault_log_raw and string.format("0x%X", values.fault_log_raw) or "—")
    end
    appendSection(rows, "Faults and alarms", details)
  end

  local barValues = {
    power = barScaled(values.power1_input, 1000000, 0, "W"),
    current = barScaled(values.curr7_input, 1000, 1, "A"),
    voltage = barScaled(values.in6_input, 1000, 2, "V"),
    imbalance = barScaled(currentImbalance, 1, 1, "%"),
    voltage_spread = barScaled(voltageSpread, 1, 2, "%"),
    temperature = barScaled(values.temp1_input, 1000, 0, "°C"),
    fan = barScaled(values.pwm1, 255, 0, "%"),
  }
  if values.power1_cap ~= nil and values.power1_cap > 0 then
    barValues.psu_load = barScaled(values.power1_input / values.power1_cap * 100, 1, 1, "%")
  end
  for pin = 1, 6 do
    barValues["pin" .. pin .. "_current"] = "P" .. pin .. " " .. barScaled(values["curr" .. pin .. "_input"], 1000, 1, "A")
    barValues["pin" .. pin .. "_power"] = "P" .. pin .. " " .. barScaled(values["power" .. (pin + 1) .. "_input"], 1000000, 0, "W")
    barValues["pin" .. pin .. "_voltage"] = "P" .. pin .. " " .. barScaled(values["in" .. (pin - 1) .. "_input"], 1000, 2, "V")
  end
  local reading = barValues[noctalia.getConfig("bar_metric")] or barValues.power
  local prefix = noctalia.getConfig("bar_prefix") or ""
  local suffix = noctalia.getConfig("bar_suffix") or ""
  barWidget.setText(reading == "—" and reading or prefix .. reading .. suffix)
  style(severity)

  if noctalia.getConfig("show_tooltip") then barWidget.setTooltip(rows) else barWidget.setTooltip(nil) end
end

function update()
  noctalia.setUpdateInterval(noctalia.getConfig("refresh_ms") or 2000)
  if pending then return end
  if devicePath == nil then devicePath = discover() end
  if devicePath == nil then unavailable("WireView hwmon device unavailable"); return end

  pending = true
  local values = {}
  local path = devicePath
  local function readNext(index)
    if index > #attributes then
      pending = false
      if values.power1_input == nil then
        unavailable("WireView sensor data unavailable")
      else
        render(values)
      end
      return
    end
    local attribute = attributes[index]
    local queued = noctalia.readFileAsync(path .. "/" .. attribute, function(contents)
      values[attribute] = contents and tonumber(noctalia.string.trim(contents)) or nil
      readNext(index + 1)
    end)
    if not queued then readNext(index + 1) end
  end
  readNext(1)
end
