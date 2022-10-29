_addon.name = 'revisible'
_addon.version = '0.9'
_addon.author = 'Darkdoom;Rubenator;Akaden'
_addon.commands = {'revisible'}

local packets = require('packets')
local bit = require('bit')
require('sets')
local config = require('config')

local path = windower.addon_path:gsub('\\', '/') .. 'EntityFlagChanger.dll'
local _FlagChanger = assert(package.loadlib(path, 'luaopen_EntityFlagChanger'))()

local defaults = {
  filter='alliance',
  show_nameplate=false,
  enabled=true,
}
local settings = config.load(defaults)

local invis_flag = 0x20000000

local invisible_players = S{}
local revisible_players = S{}
local last_packets = {}
local translucent_players = S{}

local update_types = S{'Update Position','Update Status','Update Vitals','Update Name','Update Model',}

local log = function(message, ...)
  windower.add_to_chat(7, 'Revisible: '..string.format(message, ...))
end

local debug = function(message, ...)
  if true then
    print('Revisible >> '..string.format(message, ...))
  end
end

local show_help = function(feature) 
  if feature == 'nameplate' then
    log('Unknown sub-command for "nameplate" command: ')
    log('nameplate [show|hide]           Translucent players will show or hide their nameplate while translucent')
  elseif feature == 'filter' then
    log('Unknown sub-command for "filter" command: ')
    log('filter [all|party|alliance]     Filter to invisible players in your party or alliance, or include all invisible players')
  else
    log('Show invisible players as translucent instead. Available commands:')
    log('[enable|disable]                Enable or disable the addon')
    log('filter [all|party|alliance]     Filter to invisible players in your party or alliance, or include all invisible players')
    log('nameplate [show|hide]           Translucent players will show or hide their nameplate while translucent')
  end
end

local is_player_filtered = function(index)
  if settings.filter == 'all' then return true end 

  local mob = windower.ffxi.get_mob_by_index(index)
  if not mob then return false end

  if settings.filter == 'party' and mob.in_party then
    return true
  elseif settings.filter == 'alliance' and mob.in_alliance then
    return true
  end

  return false
end

local restore_packets = function(index)
  if last_packets[index] and revisible_players:contains(index) then
    for t, _ in pairs(update_types) do
      if last_packets[index][t] then
        debug('Restored packet "%s" for %d', t, index)
        windower.packets.inject_incoming(0xD, last_packets[index][t])
      end
    end
    last_packets[index] = nil
    revisible_players:remove(index)
  end
end

local toggle_translucent = function(index, flag, skip_restore_packet)
  local mob = windower.ffxi.get_mob_by_index(index)
  if not mob then
    -- clear data, we can't find the mob
    translucent_players:remove(index)
    invisible_players:remove(index)
    last_packets[index] = nil

    return
  end

  if flag then
    _FlagChanger.SetEntityTranslucent(index) 
    if settings.show_nameplate then
      _FlagChanger.ShowEntityName(index) 
    else
      _FlagChanger.HideEntityName(index) 
    end
    translucent_players:add(index)
  else    
    if translucent_players:contains(index) then
      _FlagChanger.SetEntityOpaque(index) 
      _FlagChanger.ShowEntityName(index) 
      translucent_players:remove(index)
    end
  end
end

local transluce = function()
  if not settings.enabled then
    for index,_ in pairs(translucent_players:union(invisible_players)) do
      toggle_translucent(index, false)
      restore_packets(index)
    end
    
    return
  end

  -- set opaque: players that we've set translucent, but are no longer in the tracked players
  for index,_ in pairs(translucent_players:diff(invisible_players)) do
    toggle_translucent(index, false)
    restore_packets(index)
  end
  

  for index,_ in pairs(invisible_players) do
    if is_player_filtered(index) then
      toggle_translucent(index, true)
    else
      toggle_translucent(index, false)
      restore_packets(index)
    end
  end
end

-- Clear everything. This happens on zone, logout, unload, etc.
local clear_data = function(restore)
  for index,_ in pairs(translucent_players:union(invisible_players)) do
    toggle_translucent(index, false)
    if restore then
      restore_packets(index)
    end
  end

  last_packets = {}

  invisible_players:clear()
  translucent_players:clear()
end

windower.register_event('incoming chunk',function(id, data, modified, injected, blocked)
  if (id == 0xD) and settings.enabled and not injected then	
    local packet = packets.parse('incoming', modified)
    
    if packet.Despawn then 
      -- clear despawning characters' data
      invisible_players:remove(packet.Index)
      revisible_players:remove(packet.Index)

      toggle_translucent(packet.Index, false)
      return
    end

    local build_packet = false
    if packet['Update Vitals'] then
      -- Invisible flag only matters on vitals updates (for some reason)

      if bit.band(packet["Flags"], invis_flag) == invis_flag then  -- if the character is invisible
        if is_player_filtered(packet.Index) then
          build_packet = true
          packet["Flags"] = bit.bxor(packet["Flags"], invis_flag)  -- turn off invisible flag
          if not revisible_players:contains(packet.Index) then 
            debug('Disabled invisible for %d', packet.Index)
          end
          revisible_players:add(packet.Index)
        end
        invisible_players:add(packet.Index)
      else
        invisible_players:remove(packet.Index)
        revisible_players:remove(packet.Index)
      end
    end

    -- store last packets for later if we need to re-invisible the players.
    last_packets[packet.Index] = last_packets[packet.Index] or {}
    for update_type, _ in pairs(update_types) do
      if packet[update_type] then 
        last_packets[packet.Index][update_type] = modified 
      end
    end

    if build_packet then
      return packets.build(packet)
    end
  end
end)

windower.register_event('prerender', transluce)
windower.register_event('zone change', function() clear_data(false) end)
windower.register_event('logout', function() clear_data(false) end)
windower.register_event('login', function() clear_data(false) end)
windower.register_event('unload', function() clear_data(true) end)

local enable_keywords = S{'enable','on','activate','start','show'}
local disable_keywords = S{'disable','off','deactivate','stop','hide'}
local filter_keywords = S{'filter','f'}
local filter_type_keywords = S{'party','alliance','all'}
local filter_type_label = {['party']='party members',['alliance']='alliance members',['all']='players'}
local nameplate_toggle_keywords = S{'name','nameplate'}

windower.register_event('addon command', function(cmd, ...)
  local args = T{...}
  cmd = cmd:lower()
  
  if enable_keywords:contains(cmd) then
    settings.enabled = true
    log('Invisible %s will be shown as translucent.', filter_type_label[settings.filter])
    settings:save()
    transluce()
  elseif disable_keywords:contains(cmd) then
    settings.enabled = false
    log('Invisible %s will remain invisible.', filter_type_label[settings.filter])
    settings:save()
    transluce()
  elseif filter_keywords:contains(cmd) and #args > 0 then
    if filter_type_keywords:contains(args[1]:lower()) then
      settings.filter = args[1]:lower()
      settings.enabled = true
      log('Invisible %s will be shown as translucent.', filter_type_label[settings.filter])
      settings:save()
      transluce()
    else
      show_help('filter')
    end
  elseif nameplate_toggle_keywords:contains(cmd) then
    if enable_keywords:contains(args[1]:lower()) then
      settings.show_nameplate = true
      log('Translucent players\' nameplates will be visible.')
      settings:save()
      transluce()
    elseif disable_keywords:contains(args[1]:lower()) then
      settings.show_nameplate = false
      log('Translucent players\' nameplates will be hidden.')
      settings:save()
      transluce()
    else
      show_help('nameplate')
    end
  else
    show_help()
  end
end)