--[[
    KeepToonBuffed.lua
    MacroQuest Lua Script

    Features:
      - All configuration loaded from KeepToonBuffed_<CharName>.ini in the MQ config dir
      - Single heal spell (defined once in [Settings]) used for all monitored targets
      - Each target has its own HP threshold that triggers the shared heal spell
      - Recasts buffs on each target when they expire or fall below a tick threshold
      - Heals always fire before buff maintenance each loop
      - Watches a designated tank's current NPC target and casts debuffs when the
        mob's HP falls at or below each debuff's configured trigger percentage
      - Each debuff is cast once per mob and not repeated until a new mob is engaged
      - Follow mode keeps the script within a configurable distance of the tank
      - ImGui control window: Pause/Resume, Exit, Follow toggle
      - Skips buff casting while in combat (configurable)
      - Skips all casting when mana is below a minimum threshold

    Requirements:
      - MacroQuest with Lua support and MQ2Nav loaded
      - KeepToonBuffed_<CharName>.ini in the MacroQuest config directory
      - All spells memorized in the gem slots defined in the INI

    Usage:
      /lua run KeepToonBuffed
--]]

local mq    = require('mq')
local imgui = require('ImGui')
local bit   = require('bit')

-- ============================================================
--  CHARACTER NAME  (resolved after first frame tick)
-- ============================================================

mq.delay(0)
local CHAR_NAME = mq.TLO.Me.Name() or 'Unknown'

-- ============================================================
--  INI PATH
-- ============================================================

-- mq.configDir resolves to the absolute MQ config folder at runtime,
-- e.g. C:\MacroQuest\config — the conventional home for per-character INIs.
local INI_PATH = mq.configDir .. '/KeepToonBuffed_LUA_' .. CHAR_NAME .. '.ini'

-- ============================================================
--  INI PARSER
-- ============================================================

--- Parse a simple INI file into a nested table: result[section][key] = value.
--- Lines beginning with ; or # are treated as comments and ignored.
---@param path string
---@return table
local function parse_ini(path)
    local result  = {}
    local section = 'default'

    local fh, err = io.open(path, 'r')
    if not fh then
        error('[KeepToonBuffed] Cannot open INI file: ' .. path .. '\n' .. (err or ''))
    end

    for line in fh:lines() do
        line = line:match('^%s*(.-)%s*$')

        if line == '' or line:sub(1,1) == ';' or line:sub(1,1) == '#' then
            -- comment or blank — skip

        elseif line:match('^%[.+%]$') then
            -- [Section]
            section = line:match('^%[(.+)%]$')
            if not result[section] then result[section] = {} end

        elseif line:find('=') then
            -- Key=Value
            local k, v = line:match('^([^=]+)=(.*)$')
            if k and v then
                k = k:match('^%s*(.-)%s*$')
                v = v:match('^%s*(.-)%s*$')
                if not result[section] then result[section] = {} end
                result[section][k] = v
            end
        end
    end

    fh:close()
    return result
end

--- Collect Key1, Key2, … entries from an INI section as an ordered array.
---@param section table
---@return string[]
local function get_list(section)
    if not section then return {} end
    local items, i = {}, 1
    while true do
        local v = section['Key' .. i]
        if not v then break end
        items[#items + 1] = v
        i = i + 1
    end
    return items
end

--- Split a pipe-delimited string and trim each field.
---@param s string
---@return string[]
local function split_pipe(s)
    local parts = {}
    for part in s:gmatch('([^|]+)') do
        parts[#parts + 1] = part:match('^%s*(.-)%s*$')
    end
    return parts
end

--- Convert a string to a boolean ("true" / "1" / "yes" → true).
---@param s string|nil
---@return boolean
local function to_bool(s)
    return s == 'true' or s == '1' or s == 'yes'
end

-- ============================================================
--  LOAD CONFIGURATION
-- ============================================================

local function load_config(path)
    local ini = parse_ini(path)
    local cfg = {}

    -- [Settings] -----------------------------------------------
    local s = ini['Settings'] or {}
    cfg.loop_interval         = tonumber(s['LoopInterval'])       or 3
    cfg.min_mana_pct          = tonumber(s['MinManaPct'])         or 20
    cfg.pause_buffs_in_combat = to_bool(s['PauseBuffsInCombat']  or 'true')
    cfg.debuff_tank           = s['DebuffTank']                   or ''
    cfg.follow_distance       = tonumber(s['FollowDistance'])     or 30

    -- Shared heal spell — one spell used for every target including the caster
    cfg.heal_spell     = s['HealSpell']              or ''
    cfg.heal_gem       = tonumber(s['HealGem'])       or 1
    cfg.heal_cast      = tonumber(s['HealCastMs'])    or 2500
    cfg.self_heal_pct  = tonumber(s['SelfHealPct'])   or 80

    -- [Targets] ------------------------------------------------
    -- Format: Name | HealPct
    cfg.targets = {}
    for _, raw in ipairs(get_list(ini['Targets'])) do
        local f = split_pipe(raw)
        if #f >= 2 then
            cfg.targets[#cfg.targets + 1] = {
                name     = f[1],
                heal_pct = tonumber(f[2]) or 70,
            }
        else
            mq.cmd('/echo [KeepToonBuffed] WARNING: Malformed [Targets] entry: ' .. raw)
        end
    end

    -- [Buffs] --------------------------------------------------
    -- Format: Name | MinTicks | Gem | CastTimeMs
    cfg.buffs = {}
    for _, raw in ipairs(get_list(ini['Buffs'])) do
        local f = split_pipe(raw)
        if #f >= 4 then
            cfg.buffs[#cfg.buffs + 1] = {
                name      = f[1],
                min_ticks = tonumber(f[2]) or 0,
                gem       = tonumber(f[3]) or 1,
                cast_time = tonumber(f[4]) or 2000,
            }
        else
            mq.cmd('/echo [KeepToonBuffed] WARNING: Malformed [Buffs] entry: ' .. raw)
        end
    end

    -- [SelfBuffs] ----------------------------------------------
    -- Format: Name | MinTicks | Gem | CastTimeMs
    cfg.self_buffs = {}
    for _, raw in ipairs(get_list(ini['SelfBuffs'])) do
        local f = split_pipe(raw)
        if #f >= 4 then
            cfg.self_buffs[#cfg.self_buffs + 1] = {
                name      = f[1],
                min_ticks = tonumber(f[2]) or 0,
                gem       = tonumber(f[3]) or 1,
                cast_time = tonumber(f[4]) or 2000,
            }
        else
            mq.cmd('/echo [KeepToonBuffed] WARNING: Malformed [SelfBuffs] entry: ' .. raw)
        end
    end

    -- [Debuffs] ------------------------------------------------
    -- Format: Name | TriggerPct | Gem | CastTimeMs
    cfg.debuffs = {}
    for _, raw in ipairs(get_list(ini['Debuffs'])) do
        local f = split_pipe(raw)
        if #f >= 4 then
            cfg.debuffs[#cfg.debuffs + 1] = {
                name        = f[1],
                trigger_pct = tonumber(f[2]) or 100,
                gem         = tonumber(f[3]) or 1,
                cast_time   = tonumber(f[4]) or 2000,
            }
        else
            mq.cmd('/echo [KeepToonBuffed] WARNING: Malformed [Debuffs] entry: ' .. raw)
        end
    end

    return cfg
end

local CONFIG = load_config(INI_PATH)

-- ============================================================
--  UTILITY FUNCTIONS
-- ============================================================

local function info(msg)
    mq.cmd('/echo [KeepToonBuffed] ' .. tostring(msg))
end

--- Return the spawn object for a named character, or nil if not visible.
---@param name string
---@return table|nil
local function get_named_spawn(name)
    if name == 'self' then
        return mq.TLO.Me
    end

    -- Prefer a PC spawn by exact name to avoid matching a familiar or pet.
    local spawn = mq.TLO.Spawn('pc ' .. name)
    if spawn and spawn() and spawn.Name() == name then
        return spawn
    end

    spawn = mq.TLO.Spawn(name)
    if spawn and spawn() and spawn.Name() == name then
        return spawn
    end

    return nil
end

--- Return remaining ticks on a buff for a named character (or "self"), else 0.
---@param spawn_name string
---@param buff_name  string
---@return number
local function get_buff_ticks(spawn_name, buff_name)
    local b
    if spawn_name == 'self' then
        b = mq.TLO.Me.Buff(buff_name)
    else
        local spawn = get_named_spawn(spawn_name)
        if spawn and spawn() then
            b = spawn.Buff(buff_name)
        end
    end
    if b and b.Duration() then
        return math.floor(b.Duration() / 6000)  -- 6000 ms = 1 EQ tick
    end
    return 0
end

--- Return HP% for a named character, or 0 if not visible.
---@param name string
---@return number
local function get_hp_pct(name)
    local spawn = get_named_spawn(name)
    if spawn and spawn() then
        return spawn.PctHPs() or 0
    end
    return 0
end

--- Return true while a spell cast is in progress.
local function is_casting()
    return mq.TLO.Me.Casting() ~= nil
end

--- Wait until casting finishes or timeout_ms elapses.
---@param timeout_ms number
local function wait_for_cast(timeout_ms)
    local elapsed, poll = 0, 100
    while elapsed < timeout_ms do
        if not is_casting() then return end
        mq.delay(poll)
        elapsed = elapsed + poll
    end
end

--- Target a named character by name. Returns true when confirmed.
---@param name string  Player name or "self"
---@return boolean
local function target_spawn(name)
    local actual = (name == 'self') and CHAR_NAME or name
    if name == 'self' then
        mq.cmd('/target ' .. actual)
    else
        local spawn = get_named_spawn(actual)
        if spawn and spawn() then
            mq.cmd('/target id ' .. spawn.ID())
        else
            mq.cmd('/target ' .. actual)
        end
    end
    mq.delay(300)
    local tname = mq.TLO.Target.Name()
    return tname ~= nil and tname == actual
end

--- Cast the spell in gem slot `gem` and wait for completion.
---@param gem       number
---@param cast_time number  Expected cast time in ms
local function cast_gem(gem, cast_time)
    mq.cmd('/cast ' .. gem)
    mq.delay(500)
    wait_for_cast(cast_time + 2000)
    mq.delay(500)
end

-- ============================================================
--  HEAL PASS  (highest priority)
-- ============================================================

--- Attempt to heal a single character by name using the shared heal spell.
---@param name     string  Character name or "self"
---@param heal_pct number  Threshold below which healing is triggered
local function heal_target(name, heal_pct)
    -- Get HP: use Me.PctHPs for self, Spawn().PctHPs for others
    local hp
    if name == 'self' then
        hp = mq.TLO.Me.PctHPs() or 0
    else
        hp = get_hp_pct(name)
    end

    if hp == 0 then return end          -- not visible / not loaded
    if hp > heal_pct then return end    -- healthy enough

    info(string.format('Healing [%s] at %d%% HP with [%s]',
        name == 'self' and CHAR_NAME or name, hp, CONFIG.heal_spell))

    if target_spawn(name) then
        cast_gem(CONFIG.heal_gem, CONFIG.heal_cast)
        info(string.format('Heal complete -> [%s]',
            name == 'self' and CHAR_NAME or name))
    else
        info(string.format('WARNING: Could not target [%s] for healing', name))
    end
end

local function manage_heals()
    if CONFIG.heal_spell == '' then return end
    if (mq.TLO.Me.PctMana() or 0) < CONFIG.min_mana_pct then
        info(string.format('Mana low (%d%%), skipping heals.', mq.TLO.Me.PctMana()))
        return
    end

    -- Check and heal the caster first (uses self heal threshold from Settings)
    heal_target('self', CONFIG.self_heal_pct)

    -- Check and heal every monitored target using their individual HP threshold
    for _, t in ipairs(CONFIG.targets) do
        heal_target(t.name, t.heal_pct)
    end
end

-- ============================================================
--  DEBUFF PASS
-- ============================================================

local debuff_state = { mob_id = nil, cast_map = {} }

--- Return SpawnID and HP% of the tank's current NPC target, or nil.
---@return number|nil, number
local function get_tank_target_info()
    if CONFIG.debuff_tank == '' then return nil, 0 end
    local tank_spawn = get_named_spawn(CONFIG.debuff_tank)
    if not tank_spawn or not tank_spawn() then
        return nil, 0
    end
    local tot = tank_spawn.TargetOfTarget
    if tot and tot() then
        local id  = tot.ID()
        local hp  = tot.PctHPs() or 0
        local typ = tot.Type() or ''
        if id and id > 0 and typ ~= 'PC' and typ ~= 'Corpse' then
            return id, hp
        end
    end
    return nil, 0
end

local function manage_debuffs()
    if #CONFIG.debuffs == 0 then return end
    if (mq.TLO.Me.PctMana() or 0) < CONFIG.min_mana_pct then return end

    local mob_id, mob_hp = get_tank_target_info()

    if not mob_id then
        if debuff_state.mob_id ~= nil then
            info('Tank has no NPC target — resetting debuff state.')
            debuff_state.mob_id   = nil
            debuff_state.cast_map = {}
        end
        return
    end

    if mob_id ~= debuff_state.mob_id then
        info(string.format('New mob (ID: %d) — resetting debuff history.', mob_id))
        debuff_state.mob_id   = mob_id
        debuff_state.cast_map = {}
    end

    for _, debuff in ipairs(CONFIG.debuffs) do
        if not debuff_state.cast_map[debuff.name] and mob_hp <= debuff.trigger_pct then

            -- Retry loop: keep casting until the debuff lands or the mob dies/despawns
            local landed  = false
            local attempt = 0
            while not landed do
                -- Verify the mob is still alive before each attempt
                local cur_id, cur_hp = get_tank_target_info()
                if not cur_id or cur_id ~= mob_id or cur_hp == 0 then
                    info(string.format('Mob %d gone — aborting debuff [%s].',
                        mob_id, debuff.name))
                    break
                end

                attempt = attempt + 1
                info(string.format('Casting debuff [%s] on mob %d (HP: %d%%) — attempt %d',
                    debuff.name, mob_id, cur_hp, attempt))

                mq.cmd('/target id ' .. mob_id)
                mq.delay(400)
                local tid = mq.TLO.Target.ID()
                if tid and tid == mob_id then
                    cast_gem(debuff.gem, debuff.cast_time)
                    mq.delay(500)  -- brief settle before checking

                    -- Confirm the debuff appears in the mob's buff bar
                    local mob_spawn = mq.TLO.Spawn('id ' .. mob_id)
                    if mob_spawn and mob_spawn() then
                        local db = mob_spawn.Buff(debuff.name)
                        if db and db() then
                            landed = true
                            debuff_state.cast_map[debuff.name] = true
                            info(string.format('Debuff [%s] confirmed on mob %d.',
                                debuff.name, mob_id))
                        else
                            info(string.format('Debuff [%s] did not land — retrying.',
                                debuff.name))
                        end
                    else
                        -- Mob gone mid-cast
                        info(string.format('Mob %d despawned — aborting debuff [%s].',
                            mob_id, debuff.name))
                        break
                    end
                else
                    info(string.format('WARNING: Could not target mob %d for [%s] — retrying.',
                        mob_id, debuff.name))
                    mq.delay(500)
                end
            end
        end
    end
end

-- ============================================================
--  BUFF PASS  (lowest priority)
-- ============================================================

local function apply_buff_to(char_name, buff)
    local ticks = get_buff_ticks(char_name, buff.name)
    if ticks <= buff.min_ticks then
        info(string.format('Recasting [%s] on [%s] (ticks: %d / threshold: %d)',
            buff.name, char_name, ticks, buff.min_ticks))
        if target_spawn(char_name) then
            cast_gem(buff.gem, buff.cast_time)
            info(string.format('Buff cast complete: [%s] -> [%s]', buff.name, char_name))
        else
            info(string.format('WARNING: Could not target [%s] for [%s]', char_name, buff.name))
        end
    end
end

local function manage_buffs()
    if CONFIG.pause_buffs_in_combat and mq.TLO.Me.CombatState() == 'COMBAT' then
        return
    end
    if (mq.TLO.Me.PctMana() or 0) < CONFIG.min_mana_pct then
        info(string.format('Mana low (%d%%), skipping buffs.', mq.TLO.Me.PctMana()))
        return
    end

    for _, buff in ipairs(CONFIG.self_buffs) do
        apply_buff_to('self', buff)
    end

    for _, t in ipairs(CONFIG.targets) do
        local spawn = get_named_spawn(t.name)
        if spawn and spawn() then
            for _, buff in ipairs(CONFIG.buffs) do
                apply_buff_to(t.name, buff)
            end
        else
            info(string.format('Target [%s] not visible — skipping buffs', t.name))
        end
    end
end

-- ============================================================
--  FOLLOW
-- ============================================================

--- Return distance to a named spawn in feet, or nil if not visible.
---@param name string
---@return number|nil
local function distance_to(name)
    local spawn = get_named_spawn(name)
    if spawn and spawn() then return spawn.Distance() end
    return nil
end

--- Maintain follow distance from the tank using MQ2Nav.
--- Navigates toward the tank when farther than FollowDistance, stops when close enough.
local function manage_follow(follow_active)
    if not follow_active or CONFIG.debuff_tank == '' then
        if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
        return
    end

    local dist = distance_to(CONFIG.debuff_tank)
    if not dist then return end

    if dist > CONFIG.follow_distance then
        if not mq.TLO.Navigation.Active() then
            mq.cmdf('/nav spawn %s |distance=%d',
                CONFIG.debuff_tank, CONFIG.follow_distance)
        end
    else
        if mq.TLO.Navigation.Active() then
            mq.cmd('/nav stop')
        end
    end
end

-- ============================================================
--  GUI
-- ============================================================

local gui = {
    open   = true,
    paused = true,   -- start paused; click Resume to activate
    exit   = false,
    follow = false,
}

-- ImGuiWindowFlags: NoResize=2, AlwaysAutoResize=64, NoCollapse=32
local WIN_FLAGS      = bit.bor(2, 64, 32)
local COL_BUTTON     = 21
local COL_BTN_HOVER  = 22
local COL_BTN_ACTIVE = 23

local function draw_gui()
    if not gui.open then return end

    gui.open = imgui.Begin('KeepToonBuffed', gui.open, WIN_FLAGS)

    -- Status
    if gui.paused then
        imgui.TextColored(1.0, 0.6, 0.0, 1.0, 'Status: PAUSED')
    else
        imgui.TextColored(0.0, 0.9, 0.0, 1.0, 'Status: RUNNING')
    end

    imgui.Separator()

    -- Info
    local current_target = mq.TLO.Target.Name() or 'None'
    local current_cast   = tostring(mq.TLO.Me.Casting() or 'None')

    imgui.Text('Char   : ' .. CHAR_NAME)
    imgui.Text(string.format('Mana   : %d%%', mq.TLO.Me.PctMana() or 0))
    imgui.Text('Heal   : ' .. (CONFIG.heal_spell ~= '' and CONFIG.heal_spell or 'NOT SET'))

	imgui.Separator()
	
    -- imgui.Text('Target : ' .. current_target)
    -- imgui.Text('Casting: ' .. current_cast)

	if current_target ~= 'None' then
		imgui.Text('Target : ' .. current_target)
	end

	if current_cast ~= 'None' then
		imgui.Text('Casting: ' .. current_cast)
	end	

    imgui.Separator()

    -- Pause / Resume
    if gui.paused then
        if imgui.Button('Resume##ktb', 120, 0) then
            gui.paused = false
            info('Resumed.')
        end
    else
        if imgui.Button('Pause##ktb', 120, 0) then
            gui.paused = true
            info('Paused.')
        end
    end

    imgui.SameLine()

    -- Exit (red)
    imgui.PushStyleColor(COL_BUTTON,     0.7, 0.1, 0.1, 1.0)
    imgui.PushStyleColor(COL_BTN_HOVER,  0.9, 0.2, 0.2, 1.0)
    imgui.PushStyleColor(COL_BTN_ACTIVE, 1.0, 0.0, 0.0, 1.0)
    if imgui.Button('Exit##ktb', 80, 0) then
        gui.exit = true
        info('Exited by GUI.')
    end
    imgui.PopStyleColor(3)

    imgui.Separator()

    -- Follow toggle (green when active)
    local tank_label = CONFIG.debuff_tank ~= '' and CONFIG.debuff_tank or 'No tank set'
    if gui.follow then
        imgui.PushStyleColor(COL_BUTTON,     0.0, 0.6, 0.0, 1.0)
        imgui.PushStyleColor(COL_BTN_HOVER,  0.0, 0.8, 0.0, 1.0)
        imgui.PushStyleColor(COL_BTN_ACTIVE, 0.0, 1.0, 0.0, 1.0)
        if imgui.Button('Following: ' .. tank_label .. '##follow', -1, 0) then
            gui.follow = false
            mq.cmd('/nav stop')
            info('Follow off.')
        end
        imgui.PopStyleColor(3)
    else
        if imgui.Button('Follow: ' .. tank_label .. '##follow', -1, 0) then
            if CONFIG.debuff_tank ~= '' then
                gui.follow = true
                info('Follow on: ' .. CONFIG.debuff_tank)
            else
                info('Cannot follow: DebuffTank not set in INI.')
            end
        end
    end

    imgui.End()
end

mq.imgui.init('KeepToonBuffed', draw_gui)

-- ============================================================
--  MAIN LOOP
-- ============================================================

info('Started — INI: ' .. INI_PATH)
info(string.format(
    'Targets: %d | Heal: [%s] gem %d | Buffs/target: %d | Self buffs: %d | Debuffs: %d | Loop: %ds',
    #CONFIG.targets, CONFIG.heal_spell, CONFIG.heal_gem,
    #CONFIG.buffs, #CONFIG.self_buffs, #CONFIG.debuffs, CONFIG.loop_interval
))
if CONFIG.debuff_tank ~= '' then
    info(string.format('Debuff tank / follow target: [%s]  Follow dist: %d ft',
        CONFIG.debuff_tank, CONFIG.follow_distance))
end

while not gui.exit do
    mq.doevents()

    -- Closing the window with X re-shows it next tick rather than stopping
    if not gui.open then gui.open = true end

    if mq.TLO.Me.Zoning() then
        mq.delay(2000)
    else
        manage_follow(gui.follow)  -- always runs, even when paused

        if not gui.paused then
            manage_heals()    -- 1. healing   — highest priority
            manage_debuffs()  -- 2. debuffs   — once per mob
            manage_buffs()    -- 3. buffs     — lowest priority
        end
    end

    mq.delay(CONFIG.loop_interval * 1000)
end

info('Stopped.')
