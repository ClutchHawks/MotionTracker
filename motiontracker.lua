--[[
* MotionTracker for Ashita v4
*
* An Aliens (1986)-inspired motion-tracker hunting compass -- a fan
* adaptation built on top of atom0s's original "filterscan" addon.
* filterscan's Wide Scan name/id filtering is still the core of how
* targets get matched here; none of this would exist without that base
* to build on, so full credit to atom0s for it.
*
* Everything layered on top of that base is new: continuous scanning of
* the client's own nearby-entity memory (so mobs/NMs alert too, not just
* static Wide Scan NPCs), the animated "motion tracker"-style radar
* popup with distance-based sound and spin-speed cues, and the
* diagnostic tooling built out to chase down false positives caused by
* lottery-style NM pop mechanics.
*
* This is an unofficial fan project made for personal/community use --
* not affiliated with, endorsed by, or sponsored by 20th Century Studios
* or the Alien/Aliens franchise. "Motion tracker" and the display
* styling here are just an homage.
--]]

addon.name      = 'motiontracker';
addon.author    = 'Aliens-fan adaptation of atom0s\'s original "filterscan" addon';
addon.version   = '2.1';
addon.desc      = 'An Aliens-inspired motion-tracker hunting compass: tracks filtered mobs/NMs/NPCs via Wide Scan and the client\'s own nearby-entity memory, with a multi-target animated popup compass and distance-based sound alerts. Built on atom0s\'s "filterscan".';
addon.link      = '';

require('common');
local chat     = require('chat');
local dats     = require('ffxi.dats');
local settings = require('settings');

-- Alert helpers (self-contained -- do not require FancyCompass).
local camera        = require('lib.camera');
local popup_compass = require('lib.popup_compass');
local local_scan    = require('lib.local_scan');

-- MotionTracker Variables
local motiontracker = T{
    filter = T{ },
    npcs = T{ },
};

-- Alert settings, persisted via Ashita's settings library.
local default_settings = T{
    alert_sound    = true,               -- play a sound when a filtered entity is found
    alert_popup    = true,               -- show the directional popup compass when found
    alert_duration = 15,                 -- seconds the popup stays up
    local_scan     = true,               -- also scan the client's own nearby-entity memory
    sound_file      = 'motiontracker_alert.wav',  -- relative to this addon's \sounds\ folder -- played on a normal (non-close) find
    sound_file_near = 'motiontracker_near.wav',   -- played instead, once, when a target is within alert_distance_near
    sound_file_idle = 'motiontracker_clear.wav',  -- played once when the last target drops off (nothing left tracked)
    alert_distance_near = 10,            -- yalms -- "close" threshold for the near sound
    radar_range     = 50,                -- yalms -- distance at which a blip sits right on the ring edge; closer targets draw nearer the center dot
    compass_idle    = true,              -- keep the compass window up (grid + sweep, no blips) even with nothing tracked
    popup_x        = 500,
    popup_y        = 80,
    popup_radius   = 70,
    popup_tilt     = 0.45,
    color_ring       = 0xCCFFF096,       -- ABGR -- bright cyan-white outer bezel
    color_n          = 0xFFFFFFE6,       -- player center dot (near-white, slight cyan)
    color_target     = 0xFF00CCFF,       -- closest 5 (labeled) blips -- amber/yellow
    color_target_far = 0xFFFFAA50,       -- everything past the top 5 -- blue
    color_bg         = 0xB0120A05,       -- CRT screen backing (dark blue-black, prop-style)
    color_grid       = 0x70DCB428,       -- range rings + spokes -- dim cyan
    color_sweep      = 0xFFFFE68C,       -- pulse ring -- bright cyan (no fade along its path)
};

local settings_obj = settings.load(default_settings);

-- Defensive default for a key that may be missing from an older saved
-- settings file (settings.load doesn't always merge new defaults in).
if (settings_obj.local_scan == nil) then
    settings_obj.local_scan = true;
end
-- Colors aren't exposed through any /mtalert command, so there's no way
-- for a saved settings file to hold an intentional user customization --
-- unconditionally re-applying the current palette here (rather than only
-- filling in a missing/nil key) is what actually rolls a color-scheme
-- change like this one out to a settings file saved under an older
-- version, since settings.load merges the OLD saved values back in over
-- these defaults otherwise.
settings_obj.color_ring       = default_settings.color_ring;
settings_obj.color_n          = default_settings.color_n;
settings_obj.color_target     = default_settings.color_target;
settings_obj.color_target_far = default_settings.color_target_far;
settings_obj.color_bg         = default_settings.color_bg;
settings_obj.color_grid       = default_settings.color_grid;
settings_obj.color_sweep      = default_settings.color_sweep;
if (settings_obj.sound_file_near == nil) then
    settings_obj.sound_file_near = 'motiontracker_near.wav';
end
if (settings_obj.sound_file_idle == nil) then
    settings_obj.sound_file_idle = 'motiontracker_clear.wav';
end
if (settings_obj.alert_distance_near == nil) then
    settings_obj.alert_distance_near = 10;
end
if (settings_obj.radar_range == nil) then
    settings_obj.radar_range = 50;
end
if (settings_obj.compass_idle == nil) then
    settings_obj.compass_idle = true;
end

settings.register('settings', 'motiontracker_settings_update', function (s)
    if (s ~= nil) then
        settings_obj = s;
    end
    settings.save();
end);

local sound_warned     = T{ };   -- kind ('far'/'near'/'idle') -> true once a missing-file warning has printed
local death_debug      = false;  -- prints every parsed defeat message when on
local scan_debug       = false;  -- prints raw fields for name-matching local-scan slots when on

-- Sound state is a SINGLE global timer per band (near/far/idle), not one
-- per target -- see update_alert_sound below for why.
local last_sound_time = nil;     -- os.clock() of the last alert sound played, any band
local last_sound_band = nil;     -- 'near' / 'far' / nil -- which band that was, for the switch-reset rule
local last_idle_sound  = nil;    -- os.clock() of last "all clear" sound played, nil when not currently looping

-- Fixed (not user-configurable) min gap between replays of each sound,
-- in seconds. Near is fastest since it's the "pay attention right now"
-- one; found and all-clear are a bit more relaxed.
local COOLDOWN_NEAR = 1;
local COOLDOWN_FAR  = 2;
local COOLDOWN_IDLE = 2;

--[[
* Plays a configured alert .wav (addon\sounds\<file>) via Ashita's built-in
* sound playback. Warns once per distinct missing file (not every call)
* since the user has to supply their own audio.
*
* @param {string} file - Filename under this addon's \sounds\ folder.
* @param {string} kind - Which missing-file warning slot to use/dedupe on.
--]]
local function play_sound_file(file, kind)
    if (not settings_obj.alert_sound) then
        return;
    end

    local play_fn = ashita and ashita.misc and ashita.misc.play_sound;
    if (play_fn == nil) then
        return;
    end

    local path = ('%s\\sounds\\%s'):format(addon.path, file);
    local f = io.open(path, 'rb');
    if (f == nil) then
        if (not sound_warned[kind]) then
            sound_warned[kind] = true;
            print(chat.header(addon.name):append(chat.error(('Alert sound not found: %s'):format(path))));
            print(chat.header(addon.name):append(chat.message('Drop a .wav there, or point elsewhere with /mtalert sound/soundnear/soundidle <file>')));
        end
        return;
    end
    f:close();

    pcall(ashita.misc.play_sound, path);
end

--[[
* Fires when a matching entity is found (either a Wide Scan entry or a
* local-memory scan hit): shows/refreshes its popup blip. Sound is NOT
* decided here -- see update_alert_sound, called once per frame -- since
* deciding it per-match meant every simultaneous target looped its own
* sound independently, which with several matches around at once (a
* field full of Berry Grubs, say) turned into an overlapping mess. Each
* individual sound was "correct" for that one target, there were just
* too many of them talking over each other.
*
* @param {string} name - The matched entity's name.
* @param {number} idx - Its target index (for live position tracking).
* @param {number} dx - World-plane X offset from the player.
* @param {number} dz - World-plane Z offset from the player.
* @param {boolean} [announce=true] - Print the "found" chat line. Passed
*   false by the local scan for a target still in view from a prior
*   tick, so it only prints once per appearance rather than every
*   ~50ms while it sits there.
--]]
local function fire_alert(name, idx, dx, dz, announce)
    if (announce == nil) then
        announce = true;
    end

    if (settings_obj.alert_popup) then
        popup_compass.alert(name, idx, dx, dz, settings_obj.alert_duration);
    end

    if (announce) then
        print(chat.header(addon.name):append(chat.success(('%s found!'):format(name))));
    end
end

--[[
* Decides and plays (at most) one alert sound for this frame, based on
* the CLOSEST currently-active target overall -- not one sound per
* target. Near beats far: if anything is within alert_distance_near, the
* near sound loops on its cooldown regardless of how many other targets
* are further out; otherwise the found sound loops for as long as
* anything at all is matched. Crossing between bands resets the timer so
* the switch is immediate rather than waiting out the other band's
* cooldown. Called once per d3d_present tick, after popup_compass.render
* so the distance it reads is this frame's, not last frame's.
--]]
local function update_alert_sound()
    if (not settings_obj.alert_sound) then
        return;
    end

    local dist = popup_compass.get_nearest_distance();
    if (dist == nil) then
        return;
    end

    local near  = dist <= settings_obj.alert_distance_near;
    local band  = near and 'near' or 'far';
    local now   = os.clock();

    if (band ~= last_sound_band) then
        last_sound_band = band;
        last_sound_time = nil;
    end

    local cooldown = near and COOLDOWN_NEAR or COOLDOWN_FAR;
    if (last_sound_time == nil or (now - last_sound_time) >= cooldown) then
        last_sound_time = now;
        play_sound_file(near and settings_obj.sound_file_near or settings_obj.sound_file, band);
    end
end

--[[
* Filter-matching, shared by Wide Scan and the local scan (name
* substring OR target index, hex or decimal).
*
* The ID branch matches against a target index / pop slot number, not
* a per-monster-instance id. For Wide Scan's static NPCs that slot is
* permanently theirs, so it's a safe, stable id. For a lottery-pop NM
* it's still meaningful *by this server's design* -- the NM spawns in
* the exact same slot as its placeholder (confirmed from this server's
* own spawn-conditions data), so the filter id values are deliberately
* chosen placeholder/pop-slot numbers, not arbitrary guesses.
*
* The risk this can't rule out on its own: the same slot number is
* reused for whatever next occupies that pop point, so an id match
* alone can't tell "the NM is here" apart from "something else is
* currently sitting in that NM's slot". That's why local_scan.lua
* additionally gates on the entity's status flag (xi.status: 0 =
* normal/spawned, 3 = invisible/not-yet-popped) before ever calling
* this -- see local_scan.lua's poll() for that check. Matching here is
* deliberately just name-or-id; the "is it actually here" judgement
* lives in local_scan.lua where the live entity state is available.
*
* A filter entry can also be a full Server ID (the big decimal number
* scandebug prints as sid=, e.g. 16793645) rather than a target index.
* This server hands out a fixed, PERMANENT Server ID per pop point
* (confirmed from its own mob_spawn_points.sql, where that same number
* is the table's primary key) rather than reassigning one per spawn, so
* unlike the index it's never shared with a different, unrelated mob --
* a much safer id to filter on when you have it. Only available for the
* local scan (sid is nil from Wide Scan's own packet, which has no
* server id in it).
*
* @param {string} name_lower - The entity's name, already lower-cased.
* @param {number} tidx - Its target index (Wide Scan ActIndex, or the
*   local entity table slot for the local scan).
* @param {number} [sid] - Its Server ID, when known (local scan only).
* @return {boolean} True if it matches the active filter.
--]]
local function matches_filter(name_lower, tidx, sid)
    local i = tostring(tidx);
    for _, v in pairs(motiontracker.filter) do
        if (name_lower:find(v) ~= nil or tidx == tonumber(v, 16) or v == i
                or (sid ~= nil and tonumber(v) == sid)) then
            return true;
        end
    end
    return false;
end

--[[
* Updates the npc list with the current zones information.
*
* @param {number} zid - The zone id to load the npcs of.
* @param {number} zsubid - The zone sub id to load the npcs of.
* @return {boolean} True on success, false otherwise.
--]]
local function update_npcs(zid, zsubid)
    -- Clear the previous npc information..
    motiontracker.npcs = T{ };

    -- Obtain the npc list dat for the given zone..
    local file = dats.get_zone_npclist(zid, zsubid);
    if (file == nil or file:len() == 0) then
        return false;
    end

    -- Open the DAT for reading..
    local f = io.open(file, 'rb');
    if (f == nil) then
        return false;
    end

    -- Obtain the file size..
    local size = f:seek('end');
    f:seek('set', 0);

    -- Validate the file by its size and expected entry count alignment..
    if (size == 0 or ((size - math.floor(size / 0x20) * 0x20) ~= 0)) then
        f:close();
        return false;
    end

    -- Parse the file for npc entries..
    for x = 0, ((size / 0x20) - 0x01) do
        local data = f:read(0x20);
        local name, id = struct.unpack('c28L', data);
        table.insert(motiontracker.npcs, { bit.band(id, 0x0FFF), name });
    end

    f:close();
    return true;
end

--[[
* Returns the npc name for the given target index using the zones npc dat information.
*
* @param {number} tidx - The target index to return the name for.
* @return {string|nil} The npc name for the given index, nil if not found.
--]]
local function name_from_index(tidx)
    if (motiontracker.npcs:len() == 0) then
        return nil;
    end

    for _, v in pairs(motiontracker.npcs) do
        if (v[1] == tidx) then
            return v[2];
        end
    end

    return nil;
end

--[[
* event: load
* desc : Event called when the addon is being loaded.
--]]
ashita.events.register('load', 'load_cb', function ()
    camera.init();

    -- Load the current zone npc list if the player is logged in..
    if (AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() == 2 and AshitaCore:GetMemoryManager():GetParty():GetMemberIsActive(0) > 0) then
        if (update_npcs(AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0), 0)) then
            print(chat.header(addon.name):append(chat.message('Loaded zone npc list.')));
        end
    end
end);

--[[
* event: d3d_present
* desc : Runs the local-memory scan and draws the directional popup
*        compass while an alert is active.
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
    if (settings_obj.local_scan and table.getn(motiontracker.filter) > 0) then
        local_scan.poll(matches_filter, function (name, idx, sid, dx, dz, is_new)
            fire_alert(name, idx, dx, dz, is_new);
        end);
    end

    local has_targets = popup_compass.is_active();
    local filtering   = table.getn(motiontracker.filter) > 0;

    if (has_targets) then
        update_alert_sound();
        last_idle_sound = nil;
    elseif (filtering and settings_obj.alert_sound) then
        -- Loops the "all clear" sound on its own cooldown for as long as
        -- nothing is tracked, rather than a single one-shot on the edge
        -- into idle. Only while actually filtering, so it doesn't chime
        -- forever with an empty filter.
        local now = os.clock();
        if (last_idle_sound == nil or (now - last_idle_sound) >= COOLDOWN_IDLE) then
            last_idle_sound = now;
            play_sound_file(settings_obj.sound_file_idle, 'idle');
        end
    else
        last_idle_sound = nil;
    end

    if (has_targets or popup_compass.is_edit_mode() or settings_obj.compass_idle) then
        popup_compass.render(settings_obj, camera.get_heading());
    end
end);

--[[
* event: command
* desc : Event called when the addon is processing a command.
--]]
ashita.events.register('command', 'command_cb', function (e)
    -- Parse the command arguments..
    local args = e.command:args();
    if (#args == 0 or (args[1] ~= '/motiontracker' and args[1] ~= '/filterscan')) then
        return;
    end

    -- Block all related commands..
    e.blocked = true;

    -- Clear the previous filter..
    motiontracker.filter:clear();

    -- Obtain the filter from the command -- accepts either the current
    -- command name or the original addon's, so muscle memory/macros from
    -- "filterscan" keep working.
    local filter = e.command:gsub('/motiontracker', ''):gsub('/filterscan', ''):trim();

    for t in filter:gmatch('[^,]+') do
        if (t ~= nil) then
            motiontracker.filter:insert(t:lower():trim());
        end
    end

    -- A new filter means a new hunt -- drop anything tracked under the
    -- OLD filter immediately (compass blips, sound state, local-scan's
    -- seen/dead bookkeeping) rather than leaving stale targets on the
    -- compass until their alert_duration times out on its own.
    popup_compass.clear();
    local_scan.reset();
    last_idle_sound = nil;
    last_sound_time = nil;
    last_sound_band = nil;

    print(chat.header(addon.name):append(chat.message('Widescan filter set to: ')):append(chat.success(filter:len() == 0 and '(None; filter is empty.)' or filter)));
end);

--[[
* event: command
* desc : Event called when the addon is processing a command. Alert
*        settings live under their own command so they never collide
*        with "/motiontracker <comma list>" above (which treats everything
*        after the command as the filter list, including the word
*        "test" or "sound" if it were typed there).
--]]
ashita.events.register('command', 'mtalert_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/mtalert') then
        return;
    end

    e.blocked = true;

    local sub = args[2];

    if (sub == 'test') then
        fire_alert('Test Target', 0, 10, 10);

    elseif (sub == 'edit') then
        popup_compass.set_edit_mode(not popup_compass.is_edit_mode());
        if (popup_compass.is_edit_mode()) then
            print(chat.header(addon.name):append(chat.message('Positioning mode ON -- hold Shift and drag the popup to move it. /mtalert edit again to finish.')));
        else
            print(chat.header(addon.name):append(chat.message('Positioning mode OFF.')));
        end

    elseif (sub == 'toggle') then
        settings_obj.alert_sound = not settings_obj.alert_sound;
        settings_obj.alert_popup = settings_obj.alert_sound;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Alerts %s'):format(settings_obj.alert_sound and 'ON' or 'OFF'))));

    elseif (sub == 'togglesound') then
        settings_obj.alert_sound = not settings_obj.alert_sound;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Sound %s'):format(settings_obj.alert_sound and 'ON' or 'OFF'))));

    elseif (sub == 'togglepopup') then
        settings_obj.alert_popup = not settings_obj.alert_popup;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Popup compass %s'):format(settings_obj.alert_popup and 'ON' or 'OFF'))));

    elseif (sub == 'deathdebug') then
        death_debug = not death_debug;
        print(chat.header(addon.name):append(chat.message(('Death-message debug %s'):format(death_debug and 'ON' or 'OFF'))));

    elseif (sub == 'scandebug') then
        scan_debug = not scan_debug;
        local_scan.set_debug(scan_debug);
        print(chat.header(addon.name):append(chat.message(('Local-scan debug %s -- logs every name-matching slot before the status/HP check to your chat log'):format(scan_debug and 'ON' or 'OFF'))));

    elseif (sub == 'localscan') then
        settings_obj.local_scan = not settings_obj.local_scan;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Local-memory scan %s -- %s'):format(
            settings_obj.local_scan and 'ON' or 'OFF',
            settings_obj.local_scan and 'now catches mobs too, not just Wide Scan-able NPCs' or 'Wide Scan filtering still works as before'))));

    elseif (sub == 'sound' and args[3]) then
        settings_obj.sound_file = e.command:match('sound%s+(.+)$') or args[3];
        sound_warned['far'] = nil;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('"Found" sound set to: sounds\\%s'):format(settings_obj.sound_file))));

    elseif (sub == 'soundnear' and args[3]) then
        settings_obj.sound_file_near = e.command:match('soundnear%s+(.+)$') or args[3];
        sound_warned['near'] = nil;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('"Close" (within %dy) sound set to: sounds\\%s'):format(settings_obj.alert_distance_near, settings_obj.sound_file_near))));

    elseif (sub == 'soundidle' and args[3]) then
        settings_obj.sound_file_idle = e.command:match('soundidle%s+(.+)$') or args[3];
        sound_warned['idle'] = nil;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('"All clear" sound set to: sounds\\%s'):format(settings_obj.sound_file_idle))));

    elseif (sub == 'near' and args[3] and tonumber(args[3])) then
        settings_obj.alert_distance_near = tonumber(args[3]);
        settings.save();
        print(chat.header(addon.name):append(chat.message(('"Close" threshold set to %dy'):format(settings_obj.alert_distance_near))));

    elseif (sub == 'range' and args[3] and tonumber(args[3])) then
        settings_obj.radar_range = tonumber(args[3]);
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Radar range set to %dy (blips at/beyond this sit on the ring edge; closer draws nearer the center)'):format(settings_obj.radar_range))));

    elseif (sub == 'idle') then
        settings_obj.compass_idle = not settings_obj.compass_idle;
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Idle compass (stay up with nothing tracked) %s'):format(settings_obj.compass_idle and 'ON' or 'OFF'))));

    elseif (sub == 'duration' and args[3] and tonumber(args[3])) then
        settings_obj.alert_duration = tonumber(args[3]);
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Popup duration set to %ds'):format(settings_obj.alert_duration))));

    elseif (sub == 'move' and args[3] and args[4] and tonumber(args[3]) and tonumber(args[4])) then
        settings_obj.popup_x = tonumber(args[3]);
        settings_obj.popup_y = tonumber(args[4]);
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Popup position set to %d, %d'):format(settings_obj.popup_x, settings_obj.popup_y))));

    elseif (sub == 'size' and args[3] and tonumber(args[3])) then
        settings_obj.popup_radius = tonumber(args[3]);
        settings.save();
        print(chat.header(addon.name):append(chat.message(('Popup radius set to %d'):format(settings_obj.popup_radius))));

    else
        -- Debug commands (deathdebug, scandebug) stay fully functional --
        -- they're just left out of this listing so it doesn't confuse
        -- anyone who isn't chasing a detection bug. Run them directly by
        -- name if you need them.
        print(chat.header(addon.name):append(chat.message('/mtalert test               - fire a test alert (sound + popup)')));
        print(chat.header(addon.name):append(chat.message('/mtalert edit               - keep the popup up; Shift+drag to move it')));
        print(chat.header(addon.name):append(chat.message('/mtalert toggle             - enable/disable sound + popup together')));
        print(chat.header(addon.name):append(chat.message('/mtalert togglesound        - enable/disable sound only')));
        print(chat.header(addon.name):append(chat.message('/mtalert togglepopup        - enable/disable the popup compass only')));
        print(chat.header(addon.name):append(chat.message('/mtalert localscan          - toggle scanning nearby entity memory (catches mobs, not just NPCs)')));
        print(chat.header(addon.name):append(chat.message('/mtalert idle               - toggle keeping the compass up (animated) with nothing tracked')));
        print(chat.header(addon.name):append(chat.message('/mtalert sound <file>       - set the "found" alert .wav (in addon\\sounds\\)')));
        print(chat.header(addon.name):append(chat.message('/mtalert soundnear <file>   - set the "close" alert .wav (within the near distance)')));
        print(chat.header(addon.name):append(chat.message('/mtalert soundidle <file>   - set the "all clear" .wav (plays when the last target drops off)')));
        print(chat.header(addon.name):append(chat.message('/mtalert near <yalms>       - set the "close" distance threshold')));
        print(chat.header(addon.name):append(chat.message('/mtalert range <yalms>      - yalms at which a blip sits on the ring edge; closer targets draw nearer the center')));
        print(chat.header(addon.name):append(chat.message('/mtalert duration <secs>    - how long the popup stays up')));
        print(chat.header(addon.name):append(chat.message('/mtalert move <x> <y>       - reposition the popup')));
        print(chat.header(addon.name):append(chat.message('/mtalert size <radius>      - resize the popup')));
    end
end);

--[[
* event: packet_in
* desc : Event called when the addon is processing incoming packets.
--]]
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    -- Packet: Zone Enter
    if (e.id == 0x000A) then
        -- Ignore mog house zoning..
        if (struct.unpack('b', e.data_modified, 0x80 + 0x01) == 1) then
            return;
        end

        -- Drop anything tracked in the OLD zone immediately. This used
        -- to live in the 0x000B handler below on the theory that 0x000B
        -- was "zone leave" -- it isn't, on this server: 0x000B is really
        -- logout (confirmed from its own server source), which mostly
        -- only fires on an actual logout, not an ordinary zone line. So
        -- targets were never really being cleared on zoning; they just
        -- looked like they were once their alert_duration ran out. This
        -- packet (zone in) is what's reliably sent on every zone change,
        -- so the reset happens here instead, right before the new
        -- zone's npc list loads in below.
        motiontracker.npcs:clear();
        popup_compass.clear();
        local_scan.reset();
        last_idle_sound = nil;
        last_sound_time = nil;
        last_sound_band = nil;

        -- Obtain the zone id from the packet..
        local zid = struct.unpack('H', e.data_modified, 0x30 + 0x01);
        local zsubid = struct.unpack('H', e.data_modified, 0x9E + 0x01);

        -- Update the zone npc list..
        if (update_npcs(zid, zsubid)) then
            print(chat.header(addon.name):append(chat.message('Loaded zone npc list.')));
        end
    end

    -- Packet: Logout (also fires for some zone-change flows on this
    -- server -- e.g. Home Point/Warp menu routes go through the logout
    -- state machine per its own source). Harmless to reset again here
    -- too; 0x000A above is the one doing the real work now.
    if (e.id == 0x000B) then
        motiontracker.npcs:clear();
        popup_compass.clear();
        local_scan.reset();
        last_idle_sound = nil;
        last_sound_time = nil;
        last_sound_band = nil;
    end

    -- Packet: Battle Message -- message_id 6 is "<X> defeats <Y>", sent
    -- the instant something dies. This is what actually fixes the local
    -- scan alerting on dead things: a corpse keeps a live ServerId for
    -- its whole loot window (well after it's dead), so despawn alone is
    -- far too late a signal. Layout matches what LootScope (a mature,
    -- widely-used Ashita loot tracker) uses for the same kill-detection
    -- problem.
    if (e.id == 0x0029) then
        if (#e.data_modified >= 0x1A) then
            local message_id = struct.unpack('H', e.data_modified, 0x18 + 0x01);
            if (message_id == 6) then
                local mob_sid  = struct.unpack('I', e.data_modified, 0x08 + 0x01);
                local mob_tidx = struct.unpack('H', e.data_modified, 0x16 + 0x01);
                if (death_debug) then
                    print(chat.header(addon.name):append(chat.message(
                        ('defeat msg: sid=%u tidx=%u'):format(mob_sid, mob_tidx))));
                end
                local_scan.forget(mob_sid);
                popup_compass.clear_if_idx(mob_tidx);
            end
        end
    end

    -- Packet: Widescan Entry
    if (e.id == 0x00F4) then
        -- Ensure a filter is set..
        if (table.getn(motiontracker.filter) == 0) then
            return;
        end

        -- Obtain the npc information..
        local tidx = struct.unpack('H', e.data_modified, 0x04 + 0x01);
        local name = name_from_index(tidx);

        if (name == nil) then
            return;
        end

        if (matches_filter(name:lower(), tidx)) then
            -- Matched -- alert (sound + directional popup) and let the
            -- entry show in-game as before.
            local dx = struct.unpack('h', e.data_modified, 0x08 + 0x01);
            local dz = struct.unpack('h', e.data_modified, 0x0A + 0x01);
            fire_alert(name, tidx, dx, dz);
            return;
        end

        -- Filter the entry from showing..
        e.blocked = true;
    end
end);
