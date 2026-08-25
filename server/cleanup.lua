local RESOURCE = GetCurrentResourceName()
local Cleanup = Config.Cleanup or {}
local lastAudit

if not Cleanup.Enabled then return end

local function log(level, message)
    print(('[%s] [CLEANUP:%s] %s'):format(RESOURCE, level, message))
end

local function discordLog(title, description, color)
    TriggerEvent(Config.LogEvent or 'rs_discordlogs:server:log', RESOURCE, title, description, color)
    if not Config.Webhook or Config.Webhook == '' then return end
    PerformHttpRequest(Config.Webhook, function(status)
        if status < 200 or status >= 300 then log('WARN', ('Webhook gaf HTTP-status %s.'):format(status)) end
    end, 'POST', json.encode({
        username = Config.WebhookName or 'RS Item Manager',
        embeds = {{
            title = title,
            description = description,
            color = color,
            footer = { text = RESOURCE },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        }},
    }), { ['Content-Type'] = 'application/json' })
end

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function tableCount(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function safeEnvironment()
    local function vector(...) return { ... } end
    local environment = {
        vec2 = vector,
        vec3 = vector,
        vec4 = vector,
        vector2 = vector,
        vector3 = vector,
        vector4 = vector,
    }

    -- Ondersteun _G.vec3(...) zonder de echte globale omgeving vrij te geven.
    environment._G = environment

    return setmetatable(environment, {
        __index = function(_, key)
            error(('niet-toegestane globale waarde in items.lua: %s'):format(tostring(key)), 2)
        end
    })
end

local function loadOxItems(content)
    local chunk, compileError = load(content, '@@ox_inventory/data/items.lua', 't', safeEnvironment())
    if not chunk then return nil, compileError end
    local ok, items = pcall(chunk)
    if not ok then return nil, items end
    if type(items) ~= 'table' then return nil, 'items.lua retourneert geen tabel' end
    return items
end

local function addBlocker(report, source, reason, kind)
    report.blockers[#report.blockers + 1] = { source = source, reason = tostring(reason), kind = kind or 'fatal' }
end

local function containsItemName(content, name)
    local from = 1
    while true do
        local startAt, endAt = content:find(name, from, true)
        if not startAt then return false end
        local before = startAt > 1 and content:sub(startAt - 1, startAt - 1) or ''
        local after = endAt < #content and content:sub(endAt + 1, endAt + 1) or ''
        if not before:match('[%w_]') and not after:match('[%w_]') then return true end
        from = endAt + 1
    end
end

local function markResourceReferences(report, resource, path, content)
    for name in pairs(report.definedItems) do
        if not report.resourceUsed[name] and containsItemName(content, name) then
            report.resourceUsed[name] = { resource = resource, file = path }
        end
    end
end

local function openDirectory(path)
    if type(io.readdir) ~= 'function' then return nil, 'io.readdir is niet beschikbaar op dit FXServer-artifact' end
    local ok, handle = pcall(io.readdir, path)
    if not ok then return nil, handle end
    return handle
end

local function scanResourceDirectory(report, resource, relative, depth)
    if depth > 24 then
        addBlocker(report, resource .. '/' .. relative, 'maximale mapdiepte bereikt', 'resource')
        return
    end

    local mount = ('@%s/%s'):format(resource, relative)
    local directory, directoryError = openDirectory(mount)
    if not directory then
        addBlocker(report, mount, directoryError or 'map kon niet worden gelezen', 'resource')
        return
    end

    for entry in directory:lines() do
        if entry ~= '.' and entry ~= '..' then
            local child = relative ~= '' and (relative .. '/' .. entry) or entry
            local childDirectory = openDirectory(('@%s/%s'):format(resource, child))

            if childDirectory then
                childDirectory:close()
                if not (Cleanup.ExcludedDirectories or {})[entry] then
                    scanResourceDirectory(report, resource, child, depth + 1)
                end
            else
                local extension = entry:match('%.([%w]+)$')
                extension = extension and extension:lower()
                local isTargetItems = resource == Config.OxInventoryResource and child == Config.OxItemsFile
                local isManagerFile = resource == RESOURCE

                if extension and (Cleanup.TextExtensions or {})[extension] and not isTargetItems and not isManagerFile then
                    local content = LoadResourceFile(resource, child)
                    if not content then
                        addBlocker(report, resource .. '/' .. child, 'tekstbestand kon niet worden gelezen', 'resource')
                    elseif #content > (Cleanup.MaxTextFileBytes or 5242880) then
                        addBlocker(report, resource .. '/' .. child, 'tekstbestand is groter dan de ingestelde scanlimiet', 'resource')
                    elseif content:sub(1, 4) == 'FXAP' then
                        addBlocker(report, resource .. '/' .. child, 'escrowbestand kan niet inhoudelijk worden gecontroleerd', 'resource')
                    else
                        report.resourceFilesScanned = report.resourceFilesScanned + 1
                        markResourceReferences(report, resource, child, content)
                    end
                end
            end
        end
    end
    directory:close()
end

local function scanResources(report)
    if type(io.readdir) ~= 'function' then
        addBlocker(report, 'resources', 'io.readdir ontbreekt; volledige resourcescan is onmogelijk', 'resource')
        return
    end

    for index = 0, GetNumResources() - 1 do
        local resource = GetResourceByFindIndex(index)
        if resource and resource ~= RESOURCE then
            report.resourcesScanned = report.resourcesScanned + 1
            scanResourceDirectory(report, resource, '', 0)
        end
    end
end

local function collectDatabaseNames(value, definedItems, used, source)
    if type(value) ~= 'table' then return end
    if type(value.name) == 'string' and definedItems[value.name] then
        used[value.name] = source
    end
    for _, child in pairs(value) do
        if type(child) == 'table' then collectDatabaseNames(child, definedItems, used, source) end
    end
end

local function scanDatabase(report)
    if not MySQL or not MySQL.query or not MySQL.query.await then
        addBlocker(report, 'database', 'oxmysql is niet beschikbaar', 'database')
        return
    end

    for _, definition in ipairs(Cleanup.DatabaseQueries or {}) do
        local ok, rows = pcall(MySQL.query.await, definition.query)
        if not ok then
            addBlocker(report, 'database:' .. definition.source, rows, 'database')
        elseif type(rows) ~= 'table' then
            addBlocker(report, 'database:' .. definition.source, 'query gaf geen tabel terug', 'database')
        else
            report.databaseRows[definition.source] = #rows
            for _, row in ipairs(rows) do
                local data = row.data
                if type(data) == 'string' and data ~= '' then
                    local decodedOk, decoded = pcall(json.decode, data)
                    if not decodedOk then
                        addBlocker(report, 'database:' .. definition.source, 'ongeldige inventory-JSON aangetroffen', 'database')
                    else
                        collectDatabaseNames(decoded, report.definedItems, report.databaseUsed, definition.source)
                    end
                elseif type(data) == 'table' then
                    collectDatabaseNames(data, report.definedItems, report.databaseUsed, definition.source)
                end
            end
        end
    end
end

local function imageName(name, item)
    local configured = type(item.client) == 'table' and item.client.image or nil
    local value = configured or (name .. '.png')
    if type(value) ~= 'string' then return nil end
    value = value:gsub('\\', '/')
    local file = value:match('([^/]+)$')
    if not file or not file:match('^[%w_%.%-]+%.png$') or file:find('..', 1, true) then return nil end
    return file
end

local function publicAudit(report)
    return {
        generatedAt = report.generatedAt,
        defined = report.defined,
        resourcesScanned = report.resourcesScanned,
        resourceFilesScanned = report.resourceFilesScanned,
        databaseRows = report.databaseRows,
        resourceUsed = report.resourceUsed,
        databaseUsed = report.databaseUsed,
        protected = report.protected,
        removable = report.removable,
        removableImages = report.removableImages,
        blockers = report.blockers,
        cleanupAllowed = report.cleanupAllowed,
        removed = report.removed,
        removedImages = report.removedImages,
        backupItemsFile = report.backupItemsFile,
        errors = report.errors,
    }
end

local function saveAudit(report)
    SaveResourceFile(RESOURCE, 'data/cleanup-report.json', json.encode(publicAudit(report), { indent = true }), -1)
end

local function runAudit()
    local targetContent = LoadResourceFile(Config.OxInventoryResource, Config.OxItemsFile)
    local report = {
        generatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        targetContent = targetContent,
        definedItems = {},
        defined = 0,
        resourcesScanned = 0,
        resourceFilesScanned = 0,
        databaseRows = {},
        resourceUsed = {},
        databaseUsed = {},
        protected = {},
        removable = {},
        removableImages = {},
        blockers = {},
        removed = {},
        removedImages = {},
        errors = {},
    }

    if not targetContent then
        addBlocker(report, Config.OxInventoryResource, Config.OxItemsFile .. ' kon niet worden gelezen')
        report.cleanupAllowed = false
        saveAudit(report)
        return report
    end

    local items, itemError = loadOxItems(targetContent)
    if not items then
        addBlocker(report, Config.OxItemsFile, itemError)
        report.cleanupAllowed = false
        saveAudit(report)
        return report
    end
    report.definedItems = items
    report.defined = tableCount(items)

    scanResources(report)
    scanDatabase(report)

    local onlinePlayers = type(GetPlayers) == 'function' and #GetPlayers() or 0
    if Cleanup.RequireEmptyServer and onlinePlayers > 0 then
        addBlocker(report, 'online spelers', ('%d speler(s) online; inventarissen kunnen nog onopgeslagen zijn'):format(onlinePlayers), 'online')
    end

    local keptImages = {}
    for name, item in pairs(items) do
        local protected = (Cleanup.ProtectedItems or {})[name]
        local used = protected or report.resourceUsed[name] or report.databaseUsed[name]
        if used then
            if protected then report.protected[#report.protected + 1] = name end
            local file = imageName(name, item)
            if file then keptImages[file] = true end
        else
            report.removable[#report.removable + 1] = name
        end
    end
    table.sort(report.protected)
    table.sort(report.removable)

    local imageSet = {}
    for _, name in ipairs(report.removable) do
        local file = imageName(name, items[name])
        if file and not keptImages[file] and not imageSet[file] then
            imageSet[file] = true
            if LoadResourceFile(Config.OxInventoryResource, (Config.OxImagesDirectory or 'web/images') .. '/' .. file) then
                report.removableImages[#report.removableImages + 1] = file
            end
        end
    end
    table.sort(report.removableImages)

    report.cleanupAllowed = true
    for _, blocker in ipairs(report.blockers) do
        if blocker.kind ~= 'resource' or Cleanup.AllowIncompleteResourceScan ~= true then
            report.cleanupAllowed = false
            break
        end
    end
    report.fingerprint = table.concat(report.removable, '\0') .. '\1' .. table.concat(report.removableImages, '\0')
    saveAudit(report)
    return report
end

local function skipTrivia(source, index)
    while index <= #source do
        local char = source:sub(index, index)
        if char:match('%s') then
            index = index + 1
        elseif source:sub(index, index + 1) == '--' then
            local equals = source:match('^%-%-%[(=*)%[', index)
            if equals then
                local close = ']' .. equals .. ']'
                local closeAt = source:find(close, index + 4 + #equals, true)
                index = closeAt and (closeAt + #close) or (#source + 1)
            else
                local newline = source:find('\n', index + 2, true)
                index = newline and (newline + 1) or (#source + 1)
            end
        else
            break
        end
    end
    return index
end

local function skipString(source, index, quote)
    index = index + 1
    while index <= #source do
        local char = source:sub(index, index)
        if char == '\\' then
            index = index + 2
        elseif char == quote then
            return index + 1
        else
            index = index + 1
        end
    end
    return #source + 1
end

local function matchingBrace(source, startAt)
    local depth, index = 0, startAt
    while index <= #source do
        local char = source:sub(index, index)
        if char == "'" or char == '"' or char == '`' then
            index = skipString(source, index, char)
        elseif source:sub(index, index + 1) == '--' then
            index = skipTrivia(source, index)
        else
            local equals = char == '[' and source:match('^%[(=*)%[', index)
            if equals then
                local close = ']' .. equals .. ']'
                local closeAt = source:find(close, index + 2 + #equals, true)
                index = closeAt and (closeAt + #close) or (#source + 1)
            elseif char == '{' then
                depth = depth + 1
                index = index + 1
            elseif char == '}' then
                depth = depth - 1
                if depth == 0 then return index end
                index = index + 1
            else
                index = index + 1
            end
        end
    end
end

local function quotedKey(source, quoteAt)
    local quote = source:sub(quoteAt, quoteAt)
    local after = skipString(source, quoteAt, quote)
    if after > #source + 1 then return nil end
    local literal = source:sub(quoteAt, after - 1)
    local chunk = load('return ' .. literal, '@@rs_itemmanager/item-key', 't', {})
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    return ok and value or nil, after
end

local function skipCommentOnly(source, index)
    local equals = source:match('^%-%-%[(=*)%[', index)
    if equals then
        local close = ']' .. equals .. ']'
        local closeAt = source:find(close, index + 4 + #equals, true)
        return closeAt and (closeAt + #close) or (#source + 1)
    end
    return source:find('\n', index + 2, true) or (#source + 1)
end

local function normalizeOuterBlankLines(content)
    local returnAt = content:find('return', 1, true)
    local outerOpen = returnAt and content:find('{', returnAt + 6, true)
    local outerClose = outerOpen and matchingBrace(content, outerOpen)
    if not outerOpen or not outerClose then return content end

    local newline = content:find('\r\n', 1, true) and '\r\n' or '\n'
    local result = { content:sub(1, outerOpen) }
    local index, depth = outerOpen + 1, 1

    while index < outerClose do
        local char = content:sub(index, index)
        if char == "'" or char == '"' or char == '`' then
            local after = skipString(content, index, char)
            result[#result + 1] = content:sub(index, after - 1)
            index = after
        elseif content:sub(index, index + 1) == '--' then
            local after = skipCommentOnly(content, index)
            result[#result + 1] = content:sub(index, after - 1)
            index = after
        else
            local equals = char == '[' and content:match('^%[(=*)%[', index)
            if equals then
                local close = ']' .. equals .. ']'
                local closeAt = content:find(close, index + 2 + #equals, true)
                local after = closeAt and (closeAt + #close) or outerClose
                result[#result + 1] = content:sub(index, after - 1)
                index = after
            elseif char == '{' then
                depth = depth + 1
                result[#result + 1] = char
                index = index + 1
            elseif char == '}' then
                depth = depth - 1
                result[#result + 1] = char
                index = index + 1
            elseif depth == 1 and char:match('%s') then
                local endAt = index
                while endAt < outerClose and content:sub(endAt, endAt):match('%s') do endAt = endAt + 1 end
                local whitespace = content:sub(index, endAt - 1)
                local _, lineBreaks = whitespace:gsub('\n', '')
                if lineBreaks > 2 then
                    local indentation = whitespace:match('\n([ \t]*)$') or ''
                    result[#result + 1] = newline .. newline .. indentation
                else
                    result[#result + 1] = whitespace
                end
                index = endAt
            else
                result[#result + 1] = char
                index = index + 1
            end
        end
    end

    result[#result + 1] = content:sub(outerClose)
    return table.concat(result)
end

local function removeItemDefinitions(content, removeSet)
    local returnAt = content:find('return', 1, true)
    if not returnAt then return nil, 'return-tabel niet gevonden' end
    local outerOpen = content:find('{', returnAt + 6, true)
    if not outerOpen then return nil, 'openingsaccolade niet gevonden' end
    local outerClose = matchingBrace(content, outerOpen)
    if not outerClose then return nil, 'afsluitende accolade niet gevonden' end

    local ranges, found, index = {}, {}, outerOpen + 1
    while index < outerClose do
        index = skipTrivia(content, index)
        if content:sub(index, index) == '[' then
            local quoteAt = skipTrivia(content, index + 1)
            local quote = content:sub(quoteAt, quoteAt)
            if quote == "'" or quote == '"' then
                local name, afterQuote = quotedKey(content, quoteAt)
                local cursor = afterQuote and skipTrivia(content, afterQuote) or index + 1
                if content:sub(cursor, cursor) == ']' then cursor = skipTrivia(content, cursor + 1) end
                if content:sub(cursor, cursor) == '=' then cursor = skipTrivia(content, cursor + 1) end
                if content:sub(cursor, cursor) == '{' then
                    local valueClose = matchingBrace(content, cursor)
                    if not valueClose then return nil, ('item %s heeft geen geldige afsluiting'):format(tostring(name)) end
                    local endAt = skipTrivia(content, valueClose + 1)
                    if content:sub(endAt, endAt) == ',' then endAt = endAt + 1 end
                    if name and removeSet[name] then
                        ranges[#ranges + 1] = { first = index, last = endAt - 1 }
                        found[name] = true
                    end
                    index = math.max(endAt, valueClose + 1)
                else
                    index = index + 1
                end
            else
                index = index + 1
            end
        else
            index = index + 1
        end
    end

    for name in pairs(removeSet) do
        if not found[name] then return nil, ('itemdefinitie niet veilig gevonden: %s'):format(name) end
    end
    for rangeIndex = #ranges, 1, -1 do
        local range = ranges[rangeIndex]
        content = content:sub(1, range.first - 1) .. content:sub(range.last + 1)
    end
    return normalizeOuterBlankLines(content)
end

local function performCleanup(report)
    local removeSet = {}
    for _, name in ipairs(report.removable) do removeSet[name] = true end
    if not next(removeSet) then return true, 'geen ongebruikte items gevonden' end

    local updated, removeError = removeItemDefinitions(report.targetContent, removeSet)
    if not updated then return false, removeError end
    local verified, verifyError = loadOxItems(updated)
    if not verified then return false, 'opgeschoonde items.lua is ongeldig: ' .. tostring(verifyError) end
    for name in pairs(removeSet) do
        if verified[name] then return false, 'controle na opschonen mislukte voor item ' .. name end
    end

    local stamp = os.date('%Y%m%d-%H%M%S')
    local backupItems = ('data/cleanup-items-%s.lua'):format(stamp)
    if not SaveResourceFile(RESOURCE, backupItems, report.targetContent, -1) then
        return false, 'items.lua-back-up kon niet worden gemaakt'
    end
    report.backupItemsFile = backupItems

    local imageDirectory = (Config.OxImagesDirectory or 'web/images'):gsub('/+$', '')
    local imageBackups = {}
    for _, file in ipairs(report.removableImages) do
        local sourcePath = imageDirectory .. '/' .. file
        local image = LoadResourceFile(Config.OxInventoryResource, sourcePath)
        if image then
            local backupPath = ('data/cleanup-image-%s-%s'):format(stamp, file)
            if not SaveResourceFile(RESOURCE, backupPath, image, #image) then
                return false, ('afbeeldingsback-up mislukt voor %s'):format(file)
            end
            imageBackups[#imageBackups + 1] = { file = file, path = sourcePath, backup = backupPath }
        end
    end

    if not SaveResourceFile(Config.OxInventoryResource, Config.OxItemsFile, updated, -1) then
        return false, 'ox_inventory/items.lua kon niet worden bijgewerkt; controleer add_filesystem_permission'
    end

    for _, image in ipairs(imageBackups) do
        local removed, removeImageError = os.remove(('@%s/%s'):format(Config.OxInventoryResource, image.path))
        if removed then
            report.removedImages[#report.removedImages + 1] = { image = image.file, backup = image.backup }
        else
            report.errors[#report.errors + 1] = { image = image.file, error = tostring(removeImageError) }
        end
    end
    report.removed = report.removable
    saveAudit(report)
    return true, ('%d items en %d afbeeldingen verwijderd'):format(#report.removed, #report.removedImages)
end

local function formatItemsFile()
    local content = LoadResourceFile(Config.OxInventoryResource, Config.OxItemsFile)
    if not content then return false, 'ox_inventory/items.lua kon niet worden gelezen' end
    local updated = normalizeOuterBlankLines(content)
    if updated == content then return true, 'items.lua bevat geen overtollige lege regels' end
    local verified, verifyError = loadOxItems(updated)
    if not verified then return false, 'geformatteerde items.lua is ongeldig: ' .. tostring(verifyError) end

    local backup = ('data/cleanup-format-%s.lua'):format(os.date('%Y%m%d-%H%M%S'))
    if not SaveResourceFile(RESOURCE, backup, content, -1) then
        return false, 'format-back-up kon niet worden gemaakt'
    end
    if not SaveResourceFile(Config.OxInventoryResource, Config.OxItemsFile, updated, -1) then
        return false, 'items.lua kon niet worden bijgewerkt; controleer add_filesystem_permission'
    end
    return true, 'overtollige lege regels verwijderd; herstart ox_inventory of de server'
end

local function allowed(source)
    return source == 0 or IsPlayerAceAllowed(source, Config.AcePermission)
end

RegisterCommand(Cleanup.Command or 'rsitemcleanup', function(source, args)
    if not allowed(source) then return end
    local action = (args[1] or 'scan'):lower()

    if action == 'scan' then
        local report = runAudit()
        lastAudit = nil
        log('INFO', ('%d definities, %d resourcebestanden, %d ongebruikt, %d afbeeldingen, %d blokkades.'):format(
            report.defined, report.resourceFilesScanned, #report.removable, #report.removableImages, #report.blockers
        ))
        if not report.cleanupAllowed then
            log('BLOCKED', 'Cleanup is geblokkeerd. Controleer data/cleanup-report.json.')
        elseif #report.removable == 0 then
            log('OK', 'Geen ongebruikte items gevonden.')
        else
            report.confirmation = ('%06d'):format(math.random(0, 999999))
            report.expiresAt = os.time() + (Cleanup.ConfirmationSeconds or 300)
            lastAudit = report
            log('READY', ('Controleer cleanup-report.json en voer binnen %d seconden uit: %s remove %s'):format(
                Cleanup.ConfirmationSeconds or 300, Cleanup.Command or 'rsitemcleanup', report.confirmation
            ))
        end
    elseif action == 'format' then
        local ok, message = formatItemsFile()
        log(ok and 'OK' or 'ERROR', message)
        discordLog('Ox inventory formatter', message, ok and 3066993 or 15158332)
    elseif action == 'remove' then
        local confirmation = tostring(args[2] or '')
        if not lastAudit or confirmation ~= lastAudit.confirmation or os.time() > lastAudit.expiresAt then
            log('BLOCKED', 'Geen geldige bevestiging. Voer eerst rsitemcleanup scan uit.')
            return
        end

        local fresh = runAudit()
        if not fresh.cleanupAllowed or fresh.fingerprint ~= lastAudit.fingerprint then
            lastAudit = nil
            log('BLOCKED', 'De situatie is gewijzigd of de herscan is onvolledig. Voer opnieuw scan uit.')
            return
        end

        local ok, message = performCleanup(fresh)
        lastAudit = nil
        log(ok and 'OK' or 'ERROR', message)
        discordLog('Ox inventory cleanup', message, ok and 3066993 or 15158332)
    else
        log('INFO', ('Gebruik: %s scan | remove CODE | format'):format(Cleanup.Command or 'rsitemcleanup'))
    end
end, false)

exports('AuditUnusedItems', function() return publicAudit(runAudit()) end)
