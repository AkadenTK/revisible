_addon.name = 'revisible'
_addon.version = '0.9.2'
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
  debug=false,
}
local settings = config.load(defaults)

local others_invisible_flag = 0x20000000
local self_invisible_flag = 0x8

local invisible_players = S{}
local altered_players = S{}

local update_types = S{'Update Position','Update Status','Update Vitals','Update Name','Update Model',}

local log = function(message, ...)
  windower.add_to_chat(7, 'Revisible: '..string.format(message, ...))
end

local debug = function(message, ...)
  if settings.debug then
    print('Revisible >> '..string.format(message, ...))
  end
end

local show_help = function(feature) 
  if feature == 'nameplate' then
    log('Unknown sub-command for "name" command: ')
    log('name [show|hide]                Translucent players will show or hide their nameplate while translucent')
  elseif feature == 'filter' then
    log('Unknown sub-command for "filter" command: ')
    log('filter [all|party|alliance]     Filter to invisible players in your party or alliance, or include all invisible players')
  else
    log('Show invisible players as translucent instead. Available commands:')
    log('[enable|disable]                Enable or disable the addon')
    log('filter [all|party|alliance]     Filter to invisible players in your party or alliance, or include all invisible players')
    log('name [show|hide]                Translucent players will show or hide their nameplate while translucent. Toggles the state if the value is not provided.')
    log('debug [on|off]                  Enable or disable debug messages. Toggles the state if the value is not provided.')
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

local revisible = function(index, force_reset)
  if invisible_players:contains(index) then
    local do_revisible = (not force_reset) and settings.enabled and is_player_filtered(index)

    if do_revisible then
      -- Set player to translucent instead of invisible

      if not altered_players:contains(index) then
        debug('Set %d to translucent', index)
      end

      _FlagChanger.RemoveEntityInvisible(index)
      _FlagChanger.SetEntityTranslucent(index) 
      if settings.show_nameplate then
        _FlagChanger.ShowEntityName(index) 
      else
        _FlagChanger.HideEntityName(index) 
      end
      altered_players:add(index)
    else
      -- Set player to invisible

      if altered_players:contains(index) then
        debug('Set %d to invisible', index)
      end

      _FlagChanger.SetEntityInvisible(index)
      altered_players:remove(index)
    end
  else
    -- Set player to visible.

    if altered_players:contains(index) then
      debug('Set %d to visible', index)
    end

    _FlagChanger.SetEntityOpaque(index) 
    _FlagChanger.ShowEntityName(index) 
    altered_players:remove(index)
  end
end

local revisible_all = function(force_reset)
  for index,_ in pairs(altered_players:union(invisible_players)) do
    revisible(index, force_reset)
  end
end

-- Clear lists.
local clear_all = function()
  invisible_players:clear()
  altered_players:clear()
end

windower.register_event('incoming chunk',function(id, data, modified, injected, blocked)
  if injected then return end

  if id == 0xD or id == 0x037 then
    local packet = packets.parse('incoming', modified)
    local index = packet.Index
    
    if packet.Despawn and index then 
      -- clear despawning characters' data
      debug('Despawn Player: %d', index)
      revisible(index, true)

      invisible_players:remove(index)
      altered_players:remove(index)
      return
    end

    local is_invisible = nil
    if id == 0xD and packet['Update Vitals'] then
      -- Invisible flag only matters on vitals updates (for some reason)
      is_invisible = bit.band(packet["Flags"], others_invisible_flag) == others_invisible_flag
    elseif id == 0x37 then
      is_invisible = bit.band(packet['_flags3'], self_invisible_flag) == self_invisible_flag
      index = windower.ffxi.get_player().index
    end

    if is_invisible ~= nil then
      if is_invisible then
        if not invisible_players:contains(index) then
          invisible_players:add(index)
          debug('Invisible Players: %s', invisible_players:filter(function(i) return windower.ffxi.get_mob_by_index(i) end):map(function(i) return windower.ffxi.get_mob_by_index(i).name end):concat(', '))

          revisible(index)
        end        
      else
        if invisible_players:contains(index) then
          invisible_players:remove(index)
          debug('Invisible Players: %s', invisible_players:filter(function(i) return windower.ffxi.get_mob_by_index(i) end):map(function(i) return windower.ffxi.get_mob_by_index(i).name end):concat(', '))

          revisible(index)
        end
      end
    end
  end
end)

windower.register_event('prerender', revisible_all)
windower.register_event('logout', 'login', 'zone change', clear_all)
windower.register_event('unload', function()
  revisible_all(true)
end)
windower.register_event('load', function()
  for _, mob in pairs(windower.ffxi.get_mob_array()) do
    if mob.valid_target and mob.entity_type == 8 and not mob.is_npc then
      if _FlagChanger.IsEntityInvisible(mob.index) then
        invisible_players:add(mob.index)
      end
    end
  end
  debug('Invisible Players: %s', invisible_players:filter(function(i) return windower.ffxi.get_mob_by_index(i) end):map(function(i) return windower.ffxi.get_mob_by_index(i).name end):concat(', '))
end)

local enable_keywords = S{'enable','on','activate','start','show'}
local disable_keywords = S{'disable','off','deactivate','stop','hide'}
local filter_keywords = S{'filter','f'}
local filter_type_keywords = S{'party','alliance','all'}
local filter_type_label = {['party']='party members',['alliance']='alliance members',['all']='players'}
local nameplate_toggle_keywords = S{'name','nameplate'}
local debug_keywords = S{'debug'}
windower.register_event('addon command', function(cmd, ...)
  local args = T{...}
  cmd = cmd:lower()
  
  if enable_keywords:contains(cmd) then
    settings.enabled = true
    log('Invisible %s will be shown as translucent.', filter_type_label[settings.filter])
    settings:save()
    revisible_all()
  elseif disable_keywords:contains(cmd) then
    settings.enabled = false
    log('Invisible %s will remain invisible.', filter_type_label[settings.filter])
    settings:save()
    revisible_all()
  elseif filter_keywords:contains(cmd) and #args > 0 then
    if filter_type_keywords:contains(args[1]:lower()) then
      settings.filter = args[1]:lower()
      settings.enabled = true
      log('Invisible %s will be shown as translucent.', filter_type_label[settings.filter])
      settings:save()
      revisible_all()
    else
      show_help('filter')
    end
  elseif nameplate_toggle_keywords:contains(cmd) then
    if args[1] and enable_keywords:contains(args[1]:lower()) then
      settings.show_nameplate = true
    elseif args[1] and disable_keywords:contains(args[1]:lower()) then
      settings.show_nameplate = false
    else
      settings.show_nameplate = not settings.show_nameplate
    end
    settings:save()
    revisible_all()
    log('Translucent players\' nameplates will be %s.', settings.show_nameplate and 'visible' or 'hidden')
  elseif debug_keywords:contains(cmd) then
    if args[1] and enable_keywords:contains(args[1]:lower()) then
      settings.debug = true
    elseif args[1] and disable_keywords:contains(args[1]:lower()) then
      settings.debug = false
    else
      settings.debug = not settings.debug
    end
    settings:save()
    log('Debug messages are now %s.', settings.debug and 'on' or 'off')
  else
    show_help()
  end
end)