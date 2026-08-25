local RESOURCE = GetCurrentResourceName()
local BEGIN_MARKER = '-- RS_ITEMMANAGER:BEGIN (automatisch gegenereerd; niet handmatig aanpassen)'
local END_MARKER = '-- RS_ITEMMANAGER:END'
local lastReport

local function stripManagedBlock(content)
    local beginAt = content:find(BEGIN_MARKER, 1, true)
    if not beginAt then return content end
    local endAt = content:find(END_MARKER, beginAt, true)
    if not endAt then return nil, 'beginmarkering gevonden zonder eindmarkering' end
    endAt = endAt + #END_MARKER
    return content:sub(1, beginAt - 1) .. content:sub(endAt + 1)
end

local function console(level, message)
    print(('[%s] [%s] %s'):format(RESOURCE, level, message))
end

local function tableCount(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return tostring(a) < tostring(b) end
        return type(a) < type(b)
    end)
    return keys
end

local function discordLog(title, description, color)
    if Config.LogEvent and Config.LogEvent ~= '' then
        TriggerEvent(Config.LogEvent, RESOURCE, title, description, color or 3447003)
    end

    if not Config.Webhook or Config.Webhook == '' then return end

    local payload = {
        username = Config.WebhookName or 'RS Item Manager',
        embeds = {{
            title = title,
            description = description,
            color = color or 3447003,
            footer = { text = RESOURCE },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
        }}
    }

    PerformHttpRequest(Config.Webhook, function(status)
        if status < 200 or status >= 300 then
            console('WARN', ('Webhook gaf HTTP-status %s.'):format(status))
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

local function constructor(name, ...)
    return { __rs_constructor = name, values = { ... } }
end

local function safeEnvironment()
    local environment = {
        QBShared = {},
        Config = {},
        vec2 = function(...) return constructor('vec2', ...) end,
        vec3 = function(...) return constructor('vec3', ...) end,
        vec4 = function(...) return constructor('vec4', ...) end,
        vector2 = function(...) return constructor('vector2', ...) end,
        vector3 = function(...) return constructor('vector3', ...) end,
        vector4 = function(...) return constructor('vector4', ...) end,
    }

    return setmetatable(environment, {
        __index = function(_, key)
            error(('niet-toegestane globale waarde: %s'):format(tostring(key)), 2)
        end
    })
end

local function loadLuaTable(content, chunkName)
    if type(content) ~= 'string' or content == '' then return nil, 'leeg bestand' end

    local environment = safeEnvironment()
    local chunk, compileError = load(content, chunkName, 't', environment)
    if not chunk then return nil, compileError end

    local ok, returned = pcall(chunk)
    if not ok then return nil, returned end

    if type(returned) == 'table' then return returned end
    if type(environment.QBShared.Items) == 'table' then return environment.QBShared.Items, nil, 'qb' end
    if type(environment.Config.Items) == 'table' then return environment.Config.Items end

    return nil, 'bestand retourneert geen itemtabel'
end

local function hasUnsupportedValue(value, seen)
    local valueType = type(value)
    if valueType == 'function' or valueType == 'userdata' or valueType == 'thread' then
        return true, valueType
    end
    if valueType ~= 'table' then return false end

    seen = seen or {}
    if seen[value] then return true, 'cirkelverwijzing' end
    seen[value] = true

    for key, child in pairs(value) do
        local bad, reason = hasUnsupportedValue(key, seen)
        if bad then return true, reason end
        bad, reason = hasUnsupportedValue(child, seen)
        if bad then return true, reason end
    end
    seen[value] = nil
    return false
end

local function convertQbItem(name, item)
    local converted = {
        label = item.label or name,
        weight = tonumber(item.weight) or 0,
        stack = item.unique == nil and true or not item.unique,
        close = item.shouldClose == nil and true or item.shouldClose,
        description = item.description,
    }

    if item.image then converted.client = { image = item.image } end
    return converted
end

local function normalizeItems(rawItems, formatHint)
    local normalized = {}

    for key, value in pairs(rawItems) do
        if type(value) == 'table' then
            local name = type(key) == 'string' and key or value.name
            if type(name) == 'string' and name:match('^[%w_%.%-]+$') then
                if formatHint == 'qb' or value.type == 'item' and value.unique ~= nil then
                    value = convertQbItem(name, value)
                end
                normalized[name] = value
            end
        end
    end

    return normalized
end

local function quote(value)
    return string.format('%q', value):gsub('\\\n', '\\n')
end

local function serialize(value, indent, seen)
    indent = indent or 0
    seen = seen or {}
    local valueType = type(value)

    if valueType == 'nil' then return 'nil' end
    if valueType == 'boolean' or valueType == 'number' then return tostring(value) end
    if valueType == 'string' then return quote(value) end
    if valueType ~= 'table' then return nil, ('niet-ondersteund type %s'):format(valueType) end

    if value.__rs_constructor and type(value.values) == 'table' then
        local args = {}
        for index, child in ipairs(value.values) do
            local encoded, err = serialize(child, indent, seen)
            if not encoded then return nil, err end
            args[index] = encoded
        end
        return ('%s(%s)'):format(value.__rs_constructor, table.concat(args, ', '))
    end

    if seen[value] then return nil, 'cirkelverwijzing' end
    seen[value] = true

    local padding = string.rep('    ', indent)
    local childPadding = string.rep('    ', indent + 1)
    local lines = { '{' }
    for _, key in ipairs(sortedKeys(value)) do
        if key ~= '__rs_constructor' and key ~= 'values' then
            local encodedKey
            if type(key) == 'string' and key:match('^[%a_][%w_]*$') then
                encodedKey = key
            else
                local keyValue, keyError = serialize(key, indent + 1, seen)
                if not keyValue then return nil, keyError end
                encodedKey = '[' .. keyValue .. ']'
            end

            local encodedValue, valueError = serialize(value[key], indent + 1, seen)
            if not encodedValue then return nil, valueError end
            lines[#lines + 1] = ('%s%s = %s,'):format(childPadding, encodedKey, encodedValue)
        end
    end
    lines[#lines + 1] = padding .. '}'
    seen[value] = nil
    return table.concat(lines, '\n')
end

local function resourcePaths(resource)
    local paths, used = {}, {}
    local function add(path)
        if type(path) == 'string' and path ~= '' and not used[path] then
            used[path] = true
            paths[#paths + 1] = path
        end
    end

    local count = GetNumResourceMetadata(resource, 'rs_items') or 0
    for index = 0, count - 1 do add(GetResourceMetadata(resource, 'rs_items', index)) end
    for _, path in ipairs(Config.CandidateFiles or {}) do add(path) end
    return paths
end

local function installedOxItems()
    local content = LoadResourceFile(Config.OxInventoryResource, Config.OxItemsFile)
    if not content then return nil, nil, 'ox_inventory-itemsbestand niet gevonden' end
    local clean, stripError = stripManagedBlock(content)
    if not clean then return nil, content, stripError end
    local items, err = loadLuaTable(clean, ('@@%s/%s'):format(Config.OxInventoryResource, Config.OxItemsFile))
    if not items then return nil, content, ('items.lua kon niet worden gelezen: %s'):format(err) end
    return items, content
end

local function scan()
    local installed, targetContent, targetError = installedOxItems()
    local report = {
        generatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        resources = 0,
        files = 0,
        found = 0,
        installable = 0,
        installedExisting = installed and tableCount(installed) or 0,
        items = {},
        duplicates = {},
        skipped = {},
        errors = {},
        targetError = targetError,
        targetContent = targetContent,
        installedItems = installed,
        conflicted = {},
    }

    if not installed then return report end

    local resources = {}
    for index = 0, GetNumResources() - 1 do
        local resource = GetResourceByFindIndex(index)
        if resource
            and resource ~= RESOURCE
            and resource ~= Config.OxInventoryResource
            and not Config.ExcludedResources[resource]
        then
            resources[#resources + 1] = resource
        end
    end
    table.sort(resources)

    for _, resource in ipairs(resources) do
        report.resources = report.resources + 1
        for _, path in ipairs(resourcePaths(resource)) do
            local content = LoadResourceFile(resource, path)
            if content then
                report.files = report.files + 1
                local rawItems, parseError, formatHint = loadLuaTable(content, ('@@%s/%s'):format(resource, path))
                if not rawItems then
                    report.errors[#report.errors + 1] = { resource = resource, file = path, error = tostring(parseError) }
                else
                    for name, item in pairs(normalizeItems(rawItems, formatHint)) do
                        report.found = report.found + 1
                        local unsupported, reason = hasUnsupportedValue(item)
                        if unsupported then
                            report.skipped[#report.skipped + 1] = { item = name, resource = resource, file = path, reason = reason }
                        elseif installed[name] then
                            report.skipped[#report.skipped + 1] = { item = name, resource = resource, file = path, reason = 'bestaat al in ox_inventory' }
                        elseif report.items[name] or report.conflicted[name] then
                            report.duplicates[#report.duplicates + 1] = {
                                item = name,
                                kept = report.items[name] and report.items[name].resource or 'overgeslagen wegens eerder conflict',
                                duplicate = resource,
                                file = path,
                            }
                            if Config.DuplicatePolicy == 'skip_conflicts' then
                                report.items[name] = nil
                                report.conflicted[name] = true
                            end
                        else
                            report.items[name] = { definition = item, resource = resource, file = path }
                        end
                    end
                end
            end
        end
    end

    report.installable = tableCount(report.items)
    return report
end

local function publicReport(report)
    return {
        generatedAt = report.generatedAt,
        resources = report.resources,
        files = report.files,
        found = report.found,
        installable = report.installable,
        installedExisting = report.installedExisting,
        duplicates = report.duplicates,
        skipped = report.skipped,
        errors = report.errors,
        targetError = report.targetError,
    }
end

local function saveReport(report)
    SaveResourceFile(RESOURCE, 'data/report.json', json.encode(publicReport(report), { indent = true }), -1)
end

local function buildManagedBlock(report)
    local lines = { BEGIN_MARKER }
    for _, name in ipairs(sortedKeys(report.items)) do
        local encoded, err = serialize(report.items[name].definition, 1)
        if not encoded then return nil, ('item %s: %s'):format(name, err) end
        lines[#lines + 1] = ('[%s] = %s, -- bron: %s/%s'):format(
            quote(name), encoded, report.items[name].resource, report.items[name].file
        )
    end
    lines[#lines + 1] = END_MARKER
    return table.concat(lines, '\n')
end

local function injectBlock(content, block)
    local clean, stripError = stripManagedBlock(content)
    if not clean then return nil, stripError end

    local closeAt
    for index = #clean, 1, -1 do
        if clean:sub(index, index) == '}' then closeAt = index break end
    end
    if not closeAt then return nil, 'afsluitende accolade van de itemtabel ontbreekt' end

    local before = clean:sub(1, closeAt - 1)
    local after = clean:sub(closeAt)
    local significant = before:match('([^%s])%s*$')
    local separator = significant ~= '{' and significant ~= ',' and ',' or ''
    local updated = before .. separator .. '\n\n' .. block .. '\n' .. after

    local parsed, parseError = loadLuaTable(updated, '@@rs_itemmanager/generated_items.lua')
    if not parsed then return nil, ('gegenereerd bestand is ongeldig: %s'):format(parseError) end
    return updated
end

local function install(report)
    if report.targetError then return false, report.targetError end
    local hasManagedBlock = report.targetContent:find(BEGIN_MARKER, 1, true) ~= nil
    if report.installable == 0 and not hasManagedBlock then
        return true, 'geen ontbrekende items gevonden', 0
    end

    local block, blockError = buildManagedBlock(report)
    if not block then return false, blockError end
    local updated, injectError = injectBlock(report.targetContent, block)
    if not updated then return false, injectError end
    if updated == report.targetContent then return true, 'items.lua is al actueel', 0 end

    if Config.CreateBackup then
        local backup = ('data/items.rs-backup-%s.lua'):format(os.date('%Y%m%d-%H%M%S'))
        if not SaveResourceFile(Config.OxInventoryResource, backup, report.targetContent, -1) then
            return false, 'back-up kon niet worden geschreven; installatie afgebroken'
        end
    end

    if not SaveResourceFile(Config.OxInventoryResource, Config.OxItemsFile, updated, -1) then
        return false, 'items.lua kon niet worden geschreven'
    end

    return true, ('%d items toegevoegd; herstart ox_inventory of de server'):format(report.installable), report.installable
end

local function run(shouldInstall)
    local report = scan()
    lastReport = report
    saveReport(report)

    if report.targetError then
        console('ERROR', report.targetError)
        discordLog('Items scan mislukt', report.targetError, 15158332)
        return false
    end

    console('INFO', ('%d resources, %d itembestanden, %d gevonden, %d te installeren, %d conflicten.'):format(
        report.resources, report.files, report.found, report.installable, #report.duplicates
    ))

    if not shouldInstall then return true end
    local ok, message, installedCount = install(report)
    console(ok and 'OK' or 'ERROR', message)
    discordLog(ok and 'Items scan voltooid' or 'Items installatie mislukt',
        ('%s\nResources: **%d**\nBestanden: **%d**\nGevonden: **%d**\nConflicten: **%d**'):format(
            message, report.resources, report.files, report.found, #report.duplicates
        ), ok and 3066993 or 15158332)

    if ok and (installedCount or 0) > 0 and GetResourceState(Config.OxInventoryResource) == 'started' then
        console('WARN', 'ox_inventory draaide al. Herstart ox_inventory of de hele server om de items te laden.')
    end
    return ok
end

local function allowed(source)
    return source == 0 or IsPlayerAceAllowed(source, Config.AcePermission)
end

RegisterCommand(Config.Command, function(source, args)
    if not allowed(source) then
        if source > 0 then TriggerClientEvent('chat:addMessage', source, { args = { 'RS Items', 'Geen toestemming.' } }) end
        return
    end

    local action = (args[1] or 'status'):lower()
    if action == 'scan' then
        run(false)
    elseif action == 'install' then
        run(true)
    elseif action == 'status' then
        if not lastReport then lastReport = scan(); saveReport(lastReport) end
        console('INFO', ('Laatste scan: %d gevonden, %d te installeren, %d conflicten, %d fouten.'):format(
            lastReport.found, lastReport.installable, #lastReport.duplicates, #lastReport.errors
        ))
    else
        console('INFO', ('Gebruik: %s scan | install | status'):format(Config.Command))
    end
end, false)

exports('ScanItems', function() return publicReport(scan()) end)
exports('InstallItems', function() return run(true) end)

CreateThread(function()
    Wait(Config.ScanDelayMs or 500)
    run(Config.AutoInstall == true)
end)
