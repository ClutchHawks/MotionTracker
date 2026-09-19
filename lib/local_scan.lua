-- Local entity-memory scan for motiontracker.
--
-- Wide Scan (the job ability / 0x0F4 packets) only ever gets you NPCs
-- whose name motiontracker can resolve from the zone's static npclist.dat --
-- mobs/NMs aren't in that file, so they never matched even with the
-- right filter set. This scans the client's own local entity table
-- instead: the same one every nearby mob, NPC, or player is already
-- sitting in once it's close enough to render, which works for both.
--
-- Incremental/chunked, same technique as FancyCompass's own entity
-- scan: walking all 2304 possible slots every frame just to call
-- GetServerId would be wasteful, so a small chunk is swept each
-- interval and only the resulting "active" list gets classified.

local M = {}

local CHUNK_SIZE      = 192   -- 2304 / 192 = 12 ticks -> ~600ms full cycle
local SCAN_INTERVAL_S = 0.05

local active_slots  = {}
local active_n       = 0
local active_set     = {}
local rescan_cursor  = 0
local last_scan      = -math.huge

local seen = {}   -- server_id -> true; the currently-matching set, used
                   -- to tell "still here" apart from "just appeared".

-- server_id -> true; confirmed dead (via M.forget), suppressed from
-- matching until the entity actually despawns. A dead mob's ServerId
-- stays live for the whole loot window -- well after it's actually
-- dead -- so despawn alone is much too late a signal; this is what
-- lets motiontracker.lua's death-message handler cut it off immediately.
local dead = {}

-- When on, prints a diagnostic line for every slot that matches the name
-- filter, BEFORE the HP%/actor-pointer gating below is applied -- so a
-- phantom (not actually spawned) match still gets logged, showing which
-- of those fields it has, to help pin down whatever else needs excluding
-- on a given server. Toggle with /mtalert scandebug.
local debug_enabled = false

function M.set_debug(on)
    debug_enabled = on
end

-- Call on zone change (the whole local entity table is meaningless
-- across a zone) so nothing stale lingers and everything re-alerts
-- fresh in the new zone.
function M.reset()
    active_slots, active_n, active_set = {}, 0, {}
    rescan_cursor = 0
    seen = {}
    dead = {}
end

-- Marks a server ID as dead: it's excluded from matching (no more
-- alerts/popup updates for it) until it fully despawns from the local
-- entity table, at which point it's automatically forgotten -- so if
-- the same ID ever gets reused by a later spawn (server IDs are a
-- reused pool), that's treated as fresh, not still-suppressed.
function M.forget(server_id)
    dead[server_id] = true
end

-- Call every frame; internally throttled to SCAN_INTERVAL_S.
--   matches_fn(name_lower, target_index, server_id) -> boolean
--   alert_fn(name, idx, server_id, dx, dz, is_new)
-- dx/dz are LIVE world-plane offsets from the player (dz maps to
-- Ashita's local-Y/north-south axis, same convention as everywhere
-- else). is_new is true only on the tick a match first appears (or
-- reappears after leaving), so callers can tell a chat/sound-worthy
-- "spotted" moment apart from "still visible, just refreshing".
function M.poll(matches_fn, alert_fn)
    local now = os.clock()
    if now - last_scan < SCAN_INTERVAL_S then return end
    last_scan = now

    local mm    = AshitaCore:GetMemoryManager()
    local em    = mm:GetEntity()
    local p_idx = mm:GetParty():GetMemberTargetIndex(0)
    if p_idx == 0 then return end

    local p_x = em:GetLocalPositionX(p_idx)
    local p_y = em:GetLocalPositionY(p_idx)
    local p_z = em:GetLocalPositionZ(p_idx)

    -- Incremental discovery: walk a chunk, add newly-seen slots. Only
    -- adds -- de-spawn removal happens for free in the classify pass.
    local last = rescan_cursor + CHUNK_SIZE - 1
    if last > 2303 then last = 2303 end
    for idx = rescan_cursor, last do
        if idx ~= p_idx and not active_set[idx] and em:GetServerId(idx) ~= 0 then
            active_n = active_n + 1
            active_slots[active_n] = idx
            active_set[idx] = true
        end
    end
    rescan_cursor = last + 1
    if rescan_cursor > 2303 then rescan_cursor = 0 end

    -- Classify + de-spawn compaction in one pass.
    local current    = {}   -- server_id -> true, currently matching (not dead)
    local present    = {}   -- server_id -> true, active at all this tick
    local write_back = 0
    for ai = 1, active_n do
        local idx = active_slots[ai]
        local sid = em:GetServerId(idx)
        if sid == 0 then
            active_set[idx] = nil
        else
            write_back = write_back + 1
            active_slots[write_back] = idx
            present[sid] = true

            -- A "dead" mark only exists to suppress a lingering corpse
            -- during its loot window; the old assumption was that it'd
            -- get cleared once the sid fully left the local table (the
            -- prune loop below). That doesn't hold on a server that
            -- hands out a fixed, PERMANENT Server ID per pop point
            -- rather than a fresh one per spawn (confirmed for this
            -- server from its own mob_spawn_points.sql, and directly
            -- from a scandebug capture showing the identical sid across
            -- two separate kills) -- the corpse and the next live spawn
            -- at that exact point can share the same sid, so it may
            -- never actually leave the table, and the mark would
            -- otherwise blacklist that pop point forever after its
            -- first kill. Fix: HP > 0 seen again for a dead-marked sid
            -- means a genuine respawn happened, so clear the mark
            -- immediately rather than waiting for a despawn that might
            -- not come.
            if dead[sid] and em:GetHPPercent(idx) > 0 then
                dead[sid] = nil
            end

            if not dead[sid] then
                local name = em:GetName(idx)
                local name_matches = name ~= nil and name ~= '' and matches_fn(name:lower(), idx, sid)

                if debug_enabled and name_matches then
                    local ok, hpp, actor, rf0, status, spawn, ex, ey, ez = pcall(function ()
                        return em:GetHPPercent(idx), em:GetActorPointer(idx),
                               em:GetRenderFlags0(idx), em:GetStatus(idx), em:GetSpawnFlags(idx),
                               em:GetLocalPositionX(idx), em:GetLocalPositionY(idx), em:GetLocalPositionZ(idx)
                    end)
                    if ok and ex ~= nil and ey ~= nil then
                        local dx      = ex - p_x
                        local dz      = ey - p_y
                        local dist    = math.sqrt(dx * dx + dz * dz)
                        local vert    = (ez or 0) - p_z
                        print(('[motiontracker][scandebug] %s idx=%d sid=%d hp%%=%s actor=0x%X rf0=0x%X status=%s spawn=0x%X pos=(%.1f,%.1f,%.1f) dist=%.1f vert=%.1f (you: z=%.1f)')
                            :format(name, idx, sid, tostring(hpp), actor or 0, rf0 or 0, tostring(status), spawn or 0, ex, ey, ez or 0, dist, vert, p_z))
                    end
                end

                -- Two independent gates, on top of the name/id match:
                --
                -- 1) status ~= 3 ("invisible"). This server's own status
                --    enum (xi.status, confirmed from its LandSandBoat
                --    source) is: 0 normal, 1 update, 2 disappear,
                --    3 invisible, plus a few higher cutscene/shutdown
                --    values. A reserved-but-not-yet-popped slot (e.g. a
                --    lottery NM's placeholder registered in the table
                --    before it actually spawns) reports status 3 -- the
                --    one value we actually have evidence for (every
                --    hp%=0 phantom capture read status=3). This USED to
                --    require status == 0 exactly, which turned out to be
                --    too strict: status isn't a fixed "is this real"
                --    flag, it looks more like which kind of update
                --    packet the client last applied to that entity. A
                --    mob standing still can sit at 0 indefinitely; one
                --    that's actively fighting (moving, taking hits, TP
                --    moves) gets a constant stream of update packets and
                --    may read something other than 0 for as long as
                --    that's happening -- which was silently dropping
                --    detection mid-fight for a mob that was completely
                --    real the whole time. Excluding only the one value
                --    with actual phantom evidence (3) avoids that.
                --
                -- 2) HP% > 0. Belt-and-suspenders alongside (1); costs
                --    nothing extra since it was already required.
                --
                -- (An earlier version also required GetActorPointer(idx)
                -- ~= 0, on the theory that it reflects whether the client
                -- has an actual 3D model loaded for the slot. That turned
                -- out to read 0 for perfectly real, visible mobs on this
                -- server -- possibly a different field layout here -- and
                -- was blocking ALL local-scan matches, not just phantom
                -- ones, so it's been dropped. If a false positive still
                -- gets through, use /mtalert scandebug to see the actor/
                -- rf0/status/spawn values for it.)
                if name_matches and em:GetStatus(idx) ~= 3 and em:GetHPPercent(idx) > 0 then
                    current[sid] = true
                    local dx = em:GetLocalPositionX(idx) - p_x
                    local dz = em:GetLocalPositionY(idx) - p_y
                    alert_fn(name, idx, sid, dx, dz, not seen[sid])
                end
            end
        end
    end
    for k = write_back + 1, active_n do active_slots[k] = nil end
    active_n = write_back

    seen = current

    -- Prune "dead" once the entity is gone from the local table
    -- entirely (fully despawned), so a reused server ID doesn't stay
    -- wrongly suppressed forever.
    for sid in pairs(dead) do
        if not present[sid] then
            dead[sid] = nil
        end
    end
end

return M
