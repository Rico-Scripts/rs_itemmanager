fx_version 'cerulean'
game 'gta5'

author 'Rico Scripts'
description 'Scant resources en installeert ontbrekende items in ox_inventory'
version '1.1.1'

server_only 'yes'

server_scripts {
    'config.lua',
    'server/main.lua'
}

files {
    'data/report.json'
}

provide 'rs_itemmanager'
