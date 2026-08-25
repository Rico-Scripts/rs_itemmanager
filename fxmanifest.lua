fx_version 'cerulean'
game 'gta5'

author 'Rico Scripts'
description 'Scant resources en installeert ontbrekende items in ox_inventory'
version '1.2.5'

server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server/main.lua',
    'server/cleanup.lua'
}

files {
    'data/report.json',
    'data/cleanup-report.json'
}

dependency 'oxmysql'

provide 'rs_itemmanager'
