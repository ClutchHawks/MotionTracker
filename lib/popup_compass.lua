-- Standalone "alert compass" popup for motiontracker -- styled after the
-- M314 motion tracker prop from Aliens: dark phosphor-green CRT screen,
-- concentric range rings, an expanding sonar-style pulse ring, and
-- pulsing blips.
-- Shown while at least one alert is active (M.alert was called within
-- the configured duration for that target), then that target's blip
-- disappears on its own; the window stays up as long as any are left.
--
-- Multiple targets can be up at once (motiontracker's filter can match more
-- than one name/type), so this tracks a whole table of alerts, one per
-- target index, and draws a blip for each plus a stacked list of labels
-- rather than a single marker.
--
-- One deliberate departure from the prop: the real thing only showed a
-- narrow forward cone (you swept it by turning your body). This shows
-- the full 360 degrees around the player instead, still camera-heading
-- relative, because hiding a match outside some cone would make it
-- worse as a "which way do I run" tool, not more authentic.
--
-- Self-contained: motiontracker doesn't depend on FancyCompass being loaded,
-- so this doesn't either.

local imgui    = require('imgui')
local settings = require('settings')
local pi       = math.pi

local M = {}

-- target_index -> { name, idx, dx, dz, until_ }
-- dx/dz are the offset from the player at the moment of the matching
-- 0x0F4 packet or local-scan tick (world-plane deltas, same axis
-- convention as everywhere else in these addons: dz maps to Ashita's
-- local-Y/north-south axis). Keyed by target index since that's unique
-- across whatever's concurrently loaded, so distinct simultaneous
-- targets never clobber each other.
local alerts = {}

-- Shift+click-drag repositioning. edit_mode keeps the popup on screen
-- indefinitely (with a placeholder marker if nothing's actively tracked)
-- so there's something to grab; was_dragging detects the drag-release
-- edge so the new position is only saved once, not every frame.
local edit_mode    = false
local was_dragging = false

function M.set_edit_mode(on)
    edit_mode = on
end

function M.is_edit_mode()
    return edit_mode
end

-- Called when a filtered entity is seen (Wide Scan pulse or local scan
-- tick). Safe to call every tick for something still in view -- it just
-- refreshes that target's own timer without touching any other target's.
function M.alert(name, idx, dx, dz, duration)
    alerts[idx] = {
        name   = name,
        idx    = idx,
        dx     = dx,
        dz     = dz,
        until_ = os.clock() + duration,
    }
end

-- Extends one target's timer without resetting its position -- not
-- currently called (M.alert already refreshes on every re-sighting) but
-- kept for callers that want to bump the timer without a fresh dx/dz.
function M.extend(idx, duration)
    if alerts[idx] ~= nil then
        alerts[idx].until_ = os.clock() + duration
    end
end

function M.clear()
    alerts = {}
end

-- Clears the popup only if it's currently showing this specific target
-- index -- used when that target is confirmed dead, so its blip drops
-- immediately instead of sitting there pointing at a corpse for the
-- rest of its normal duration. A no-op if nothing is showing for that
-- index.
function M.clear_if_idx(idx)
    alerts[idx] = nil
end

-- Drops any alert whose timer has expired. Called once per render/check
-- rather than scattered through the file.
local function prune_expired()
    local now = os.clock()
    for idx, a in pairs(alerts) do
        if now >= a.until_ then
            alerts[idx] = nil
        end
    end
end

function M.is_active()
    prune_expired()
    return next(alerts) ~= nil
end

-- Tries to read a LIVE offset for the tracked index (works once the
-- entity is close enough to be in the local entity table). Returns nil
-- if the entity isn't currently loaded, in which case the caller should
-- fall back to the frozen scan-time offset.
local function live_offset(a)
    local ok, dx, dz = pcall(function()
        local mm  = AshitaCore:GetMemoryManager()
        local em  = mm:GetEntity()
        local p_idx = mm:GetParty():GetMemberTargetIndex(0)
        if p_idx == 0 or a.idx == 0 or em:GetServerId(a.idx) == 0 then
            return nil
        end
        local px, py = em:GetLocalPositionX(p_idx), em:GetLocalPositionY(p_idx)
        local ex, ey = em:GetLocalPositionX(a.idx), em:GetLocalPositionY(a.idx)
        return ex - px, ey - py
    end)
    if ok and dx ~= nil then return dx, dz end
    return nil
end

-- Returns the LIVE distance (yalms) to the closest currently-active
-- target, or nil if there are none right now. This is what motiontracker.lua
-- uses to decide which alert sound is appropriate at any given moment --
-- computed independently of M.render, so it stays correct even on a
-- frame render() doesn't run, and so there's exactly one distance-based
-- decision made per tick rather than one per target (which is what used
-- to make several simultaneous targets each loop their own sound
-- independently, turning into an overlapping mess as soon as more than
-- one was around at once).
function M.get_nearest_distance()
    prune_expired()
    local nearest = nil
    for _, a in pairs(alerts) do
        local ldx, ldz = live_offset(a)
        local dx = ldx or a.dx
        local dz = ldz or a.dz
        local dist = math.sqrt(dx * dx + dz * dz)
        if nearest == nil or dist < nearest then
            nearest = dist
        end
    end
    return nearest
end

-- Fills the heading-relative ellipse (radius r, vertical squash `tilt`)
-- centered at (cx, cy) with `color`, using stacked horizontal strips --
-- same trick FancyCompass's own disc uses, since ImGui has no native
-- ellipse fill. `step` trades smoothness for draw-call count.
local function fill_ellipse(dl, cx, cy, r, tilt, color, step)
    local ry = r * tilt
    local y = -ry
    while y <= ry do
        local frac = y / ry
        local hw = r * math.sqrt(math.max(0, 1 - frac * frac))
        if hw > 0 then
            dl:AddRectFilled({ cx - hw, cy + y }, { cx + hw, cy + y + step }, color)
        end
        y = y + step
    end
end

-- Call every frame. cfg needs: popup_x, popup_y, popup_radius, popup_tilt,
-- color_ring, color_n, color_target, color_target_far, color_bg,
-- color_grid, color_sweep. heading is camera.get_heading().
function M.render(cfg, heading)
    prune_expired()
    local has_alerts = next(alerts) ~= nil
    if not has_alerts and not edit_mode and not cfg.compass_idle then return end

    -- What to point at: the real alerts, or (edit mode with nothing
    -- tracked) a single fixed sample point so there's something to
    -- align by while repositioning. With nothing tracked and edit mode
    -- off, this stays empty -- compass_idle keeps the window (grid +
    -- sweep) up with no blips or labels, just idling.
    local targets = {}
    if has_alerts then
        for _, a in pairs(alerts) do
            targets[#targets + 1] = a
        end
        -- Stable order (by name) so the stacked label list doesn't
        -- reshuffle line order from frame to frame as timers tick.
        table.sort(targets, function (a, b) return a.name < b.name end)
    elseif edit_mode then
        targets[1] = { idx = 0, dx = 10, dz = -10, name = 'Sample (shift+drag me)', sample = true }
    end

    -- Resolve each target's live (or frozen-fallback) offset once here,
    -- and note whether any of them are within the "near" sound's
    -- distance -- reused below both to pick the sweep's spin speed and
    -- by the blip-drawing loop, so live_offset only runs once per target
    -- per frame rather than twice.
    local near_distance = cfg.alert_distance_near or 10
    local near_active   = false
    for _, t in ipairs(targets) do
        local ldx, ldz
        if not t.sample then
            ldx, ldz = live_offset(t)
        end
        t._live = ldx ~= nil
        t._dx   = t._live and ldx or t.dx
        t._dz   = t._live and ldz or t.dz
        t._dist = math.sqrt(t._dx * t._dx + t._dz * t._dz)
        if not t.sample and t._dist <= near_distance then
            near_active = true
        end
    end

    -- Every target still gets a blip -- the label LIST is what gets
    -- capped, to the 5 closest by current live distance. Re-sorted fresh
    -- every frame (distances above are recomputed every frame too), so
    -- as you move around, a target that was in the top 5 but is now
    -- further off drops out and whichever one just became closer takes
    -- its place -- this isn't a frozen snapshot from whenever they were
    -- first spotted.
    local MAX_LABELS = 5
    local label_order = {}
    for i, t in ipairs(targets) do label_order[i] = t end
    table.sort(label_order, function (a, b) return a._dist < b._dist end)
    local overflow = math.max(0, #label_order - MAX_LABELS)
    while #label_order > MAX_LABELS do table.remove(label_order) end

    -- Membership test for "is this target one of the labeled ones" --
    -- used below to give the rest a dimmer, scanner-green blip instead
    -- of the bright highlight color, so the ring doesn't read as "6
    -- equally important contacts" when only 5 have room in the list.
    local in_top = {}
    for _, t in ipairs(label_order) do in_top[t] = true end

    local r    = cfg.popup_radius
    local pad  = 26
    local sz   = (r + pad) * 2
    local tilt = cfg.popup_tilt
    local label_h  = 14
    local list_h   = (#label_order + (overflow > 0 and 1 or 0)) * label_h + 4

    -- Label text (built here, before the window's size is set, so the
    -- window can be sized to actually fit the widest one -- a long mob
    -- name plus its distance easily runs past the radar's own diameter,
    -- which is what was clipping names off the edge of the frame).
    local labels = {}
    for _, t in ipairs(label_order) do
        labels[#labels + 1] = t.sample and t.name
            or (t._live and ('%s  %dy'):format(t.name, math.floor(t._dist + 0.5))
                         or  ('%s  (last seen)'):format(t.name))
    end
    if overflow > 0 then
        labels[#labels + 1] = ('+ %d more'):format(overflow)
    end

    -- Labels are drawn a bit smaller than the rest of the popup (see
    -- LABEL_FONT_SCALE below) so a longer name has a better chance of
    -- fitting without widening the frame too much. CalcTextSize here
    -- runs at the un-scaled font (no window is current yet to apply a
    -- font scale to), so the estimate is scaled down to match by hand.
    local LABEL_FONT_SCALE = 0.85
    local widest = 0
    for _, label in ipairs(labels) do
        local lw = imgui.CalcTextSize(label)
        if lw > widest then widest = lw end
    end
    local sz_w = math.max(sz, widest * LABEL_FONT_SCALE + pad)

    -- Hold Shift to click-drag the popup. Normally it ignores the mouse
    -- entirely (NoInputs) so it never steals clicks meant for the game;
    -- holding Shift removes that for as long as it's held, and the new
    -- position is read back from ImGui's own window position each frame
    -- so a body-drag (no title bar needed) works exactly like FancyCompass's
    -- own window does.
    local shift_held = imgui.GetIO().KeyShift

    imgui.SetNextWindowPos({ cfg.popup_x, cfg.popup_y },
        shift_held and ImGuiCond_FirstUseEver or ImGuiCond_Always)
    imgui.SetNextWindowSize({ sz_w, sz + list_h }, ImGuiCond_Always)
    imgui.SetNextWindowBgAlpha(shift_held and 0.15 or 0.0)
    local wflags = ImGuiWindowFlags_NoDecoration
                 + ImGuiWindowFlags_NoNav
                 + ImGuiWindowFlags_NoBringToFrontOnFocus
    if not shift_held then
        wflags = wflags + ImGuiWindowFlags_NoInputs
    end

    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, shift_held and 1.0 or 0.0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    local open = { true }
    if imgui.Begin('##motiontracker_alert_compass', open, wflags) then
        local dl       = imgui.GetWindowDrawList()
        local wpx, wpy = imgui.GetWindowPos()

        if shift_held then
            cfg.popup_x, cfg.popup_y = math.floor(wpx), math.floor(wpy)
            was_dragging = true
        elseif was_dragging then
            was_dragging = false
            pcall(settings.save)
        end

        local cx, cy = wpx + sz_w * 0.5, wpy + sz * 0.5

        -- CRT screen backing.
        fill_ellipse(dl, cx, cy, r, tilt, cfg.color_bg, 3)

        -- Concentric range rings (inner two, the outer one is the bezel
        -- drawn last so it sits crisp on top of everything else).
        for _, frac in ipairs({ 0.34, 0.67 }) do
            local rr = r * frac
            local px2, py2 = cx + rr, cy
            for i = 1, 48 do
                local th = (i / 48) * 2 * pi
                local nx = cx + rr * math.cos(th)
                local ny = cy + rr * math.sin(th) * tilt
                dl:AddLine({ px2, py2 }, { nx, ny }, cfg.color_grid, 1.0)
                px2, py2 = nx, ny
            end
        end

        -- Radial spokes, 8-way, purely decorative grid (not tied to any
        -- compass direction -- the target angle below already accounts
        -- for camera heading).
        for i = 0, 7 do
            local th = (i / 8) * 2 * pi
            dl:AddLine(
                { cx, cy },
                { cx + r * math.cos(th), cy + r * math.sin(th) * tilt },
                cfg.color_grid, 1.0)
        end

        -- Pulsing ping ring: expands outward from the player dot, at full
        -- brightness the whole way, reaching the outer ring exactly at
        -- the end of its cycle before looping -- a sonar-style pulse
        -- instead of a continuously spinning sweep line. A single pulse
        -- at a time (a brief gap while it resets is fine -- reads as one
        -- clean ping rather than overlapping rings). Speeds up the same
        -- way the old sweep did: faster while any target is within the
        -- near sound's range, matching the alert sounds' own urgency
        -- change -- 1s per pulse when near, 2s otherwise (including
        -- idle/clear).
        --
        -- The leading edge itself never fades (full alpha, full width)
        -- -- but it drags a short blurred afterglow behind it, a few
        -- thinner/dimmer rings at slightly smaller radii, the way the
        -- reference prop's sweep leaves a soft trail rather than a hard
        -- edge. The trail is drawn first so the crisp leading edge always
        -- sits on top of it.
        local pulse_period = near_active and 1.0 or 2.0
        local sweep_a      = math.floor(cfg.color_sweep / 0x1000000) % 0x100
        local sweep_rgb    = cfg.color_sweep % 0x1000000
        local PULSE_WIDTH  = 3.0
        local t  = (os.clock() % pulse_period) / pulse_period

        local function ring_at(tt, alpha, width)
            local pr = r * tt
            if pr <= 1 or alpha <= 0 then return end
            local col = math.floor(alpha) * 0x1000000 + sweep_rgb
            local px2, py2 = cx + pr, cy
            for i = 1, 48 do
                local th = (i / 48) * 2 * pi
                local nx = cx + pr * math.cos(th)
                local ny = cy + pr * math.sin(th) * tilt
                dl:AddLine({ px2, py2 }, { nx, ny }, col, width)
                px2, py2 = nx, ny
            end
        end

        local TRAIL_STEPS = 6
        local TRAIL_GAP   = 0.035  -- fraction of the full path, per trailing step
        for i = TRAIL_STEPS, 1, -1 do
            local tt = t - i * TRAIL_GAP
            if tt > 0 then
                local fade = 1 - (i / TRAIL_STEPS)
                ring_at(tt, sweep_a * fade * fade, PULSE_WIDTH * 0.7)
            end
        end
        ring_at(t, sweep_a, PULSE_WIDTH)

        -- N reference tick, so the display's rotation makes sense at a
        -- glance (this is heading-relative, not north-up).
        local n_a = pi - heading - (pi / 2)
        local nlx = cx + (r + 10) * math.cos(n_a)
        local nly = cy + (r + 10) * math.sin(n_a) * tilt
        local ntsw, ntsh = imgui.CalcTextSize('N')
        dl:AddText({ nlx - ntsw * 0.5, nly - ntsh * 0.5 }, cfg.color_grid, 'N')

        -- Player dot, dead center.
        dl:AddCircleFilled({ cx, cy }, 3, cfg.color_n, 12)

        -- Bezel: crisp outer ring, drawn before the blips so they sit on
        -- top of it rather than under it.
        local px2, py2 = cx + r, cy
        for i = 1, 64 do
            local th = (i / 64) * 2 * pi
            local nx = cx + r * math.cos(th)
            local ny = cy + r * math.sin(th) * tilt
            dl:AddLine({ px2, py2 }, { nx, ny }, cfg.color_ring, 1.5)
            px2, py2 = nx, ny
        end

        -- One blip per active target -- a pulsing dot plus an expanding
        -- "ping" ring. Radial position now tracks actual distance (close
        -- = near the center dot, far = out toward the ring edge), scaled
        -- against cfg.radar_range (yalms at which a blip sits right on
        -- the edge); anything farther than that just clamps to the edge
        -- rather than going off-screen. Their labels are collected here
        -- and drawn as a stacked list below the circle, since several
        -- overlapping name+distance labels right at the edge would be
        -- unreadable.
        local outline     = 0xCC000000
        local radar_range = cfg.radar_range or 50
        for _, t in ipairs(targets) do
            local live = t._live
            local dx   = t._dx
            local dz   = t._dz
            local dist = t._dist

            local frac   = math.max(0, math.min(1, dist / radar_range))
            local br     = r * frac
            local sa     = math.atan2(-dx, -dz) - heading - (pi / 2)
            local ca, sn = math.cos(sa), math.sin(sa)
            local mkx    = cx + br * ca
            local mky    = cy + br * sn * tilt

            local base_color = (t.sample or in_top[t]) and cfg.color_target or cfg.color_target_far
            local alpha = math.floor(base_color / 0x1000000) % 0x100
            if not live then alpha = math.floor(alpha * 0.55) end
            local rgb = base_color % 0x1000000

            local pulse = 1.0 + 0.5 * math.abs(math.sin(os.clock() * 6 + t.idx))
            local mr    = 5 * pulse
            dl:AddCircleFilled({ mkx, mky }, mr, alpha * 0x1000000 + rgb, 16)

            local ping_period = 1.2
            local ping_t = ((os.clock() + t.idx * 0.1) % ping_period) / ping_period
            local ping_r = mr + ping_t * 22
            local ping_a = math.floor(alpha * (1 - ping_t))
            if ping_a > 0 then
                dl:AddCircle({ mkx, mky }, ping_r, ping_a * 0x1000000 + rgb, 20, 1.5)
            end
        end

        -- Stacked label list -- just the closest MAX_LABELS (label_order,
        -- built above), centered under the circle. Every target still
        -- got a blip above regardless of this cap. `labels` was built
        -- earlier (before the window's size was set) so it could also be
        -- used to size the frame to fit; drawn a bit smaller than the
        -- rest of the popup so a long name has more room before it needs
        -- the frame widened further.
        imgui.SetWindowFontScale(LABEL_FONT_SCALE)
        local list_top = cy + r * tilt + 14
        for i, label in ipairs(labels) do
            local is_overflow = overflow > 0 and i == #labels
            local lsw   = imgui.CalcTextSize(label)
            local lx    = cx - lsw * 0.5
            local ly    = list_top + (i - 1) * label_h
            for ox = -1, 1 do
                for oy = -1, 1 do
                    if ox ~= 0 or oy ~= 0 then
                        dl:AddText({ lx + ox, ly + oy }, outline, label)
                    end
                end
            end
            if is_overflow then
                local alpha = math.floor(math.floor(cfg.color_target / 0x1000000) % 0x100 * 0.6)
                dl:AddText({ lx, ly }, alpha * 0x1000000 + (cfg.color_target % 0x1000000), label)
            else
                dl:AddText({ lx, ly }, cfg.color_target, label)
            end
        end
        imgui.SetWindowFontScale(1.0)

        if shift_held then
            local hint = 'drag to move'
            local hsw, hsh = imgui.CalcTextSize(hint)
            local hx, hy = cx - hsw * 0.5, cy - hsh * 0.5
            for ox = -1, 1 do
                for oy = -1, 1 do
                    if ox ~= 0 or oy ~= 0 then
                        dl:AddText({ hx + ox, hy + oy }, 0xCC000000, hint)
                    end
                end
            end
            dl:AddText({ hx, hy }, 0xFFFFFFFF, hint)
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
end

return M
