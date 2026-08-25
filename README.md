# RS Item Manager

Scant alle FiveM-resources op itembestanden en voegt ontbrekende definities toe aan `ox_inventory/data/items.lua`.

## Installatie

1. Plaats `rs_itemmanager` in je resources-map.
2. Zet de resource **vóór** `ox_inventory` in `server.cfg`:

```cfg
ensure ox_lib
ensure rs_itemmanager
ensure ox_inventory
```

3. Start de server. Bij iedere wijziging wordt eerst een back-up in `ox_inventory/data/` geplaatst.

## Itembestanden herkennen

De manager controleert automatisch bekende locaties zoals `items.lua`, `shared/items.lua`, `config/items.lua` en `rs_items.lua`.

Voor een andere locatie voeg je in de `fxmanifest.lua` van het bronscript toe:

```lua
rs_items 'install/ox_items.lua'
```

Het bestand moet een tabel retourneren:

```lua
return {
    ['lockpick_advanced'] = {
        label = 'Geavanceerde lockpick',
        weight = 300,
        stack = true,
        close = true
    }
}
```

Ook statische `QBShared.Items`-tabellen worden herkend en naar het ox_inventory-formaat geconverteerd. Itemdefinities met Lua-functies worden voor de veiligheid overgeslagen en in het rapport vermeld.

## Commando's

Alleen serverconsole of spelers met ACE `rs_itemmanager.manage`:

```text
rsitems scan
rsitems install
rsitems status
```

Eventueel:

```cfg
add_ace group.admin rs_itemmanager.manage allow
```

Het volledige scanrapport staat in `rs_itemmanager/data/report.json`. Bestaande items worden nooit overschreven. Het automatisch beheerde blok in `ox_inventory/data/items.lua` kan bij een volgende scan veilig worden bijgewerkt.

## Logging

De resource verstuurt het event `rs_discordlogs:server:log`. Vul eventueel daarnaast `Config.Webhook` in voor directe Discord-webhooklogging.

