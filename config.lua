Config = {}

-- Zet rs_itemmanager in server.cfg VOOR ox_inventory.
Config.OxInventoryResource = 'ox_inventory'
Config.OxItemsFile = 'data/items.lua'

-- Installeert automatisch bij het starten van rs_itemmanager.
Config.AutoInstall = true
Config.ScanDelayMs = 500
Config.CreateBackup = true

-- first: eerste gevonden definitie wint en conflicten komen in het rapport.
-- skip_conflicts: installeert een item niet als meerdere scripts iets anders definiëren.
Config.DuplicatePolicy = 'first'

Config.ExcludedResources = {
    ['ox_inventory'] = true,
    ['rs_itemmanager'] = true,
}

-- Bekende locaties. Voor afwijkende locaties gebruik je `rs_items 'pad/items.lua'`
-- in de fxmanifest van het betreffende script.
Config.CandidateFiles = {
    'rs_items.lua',
    'items.lua',
    'data/items.lua',
    'shared/items.lua',
    'config/items.lua',
    'config/items.shared.lua',
    'install/items.lua',
    'installation/items.lua',
}

-- Optionele directe Discord-webhook. Laat leeg als rs_discordlogs de events opvangt.
Config.Webhook = ''
Config.WebhookName = 'RS Item Manager'
Config.LogEvent = 'rs_discordlogs:server:log'

-- Console of ACE-toegang. Voor spelers: add_ace group.admin rs_itemmanager.manage allow
Config.Command = 'rsitems'
Config.AcePermission = 'rs_itemmanager.manage'

