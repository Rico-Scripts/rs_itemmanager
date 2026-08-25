# RS Item Manager

Scant alle FiveM-resources op itembestanden, voegt ontbrekende definities toe aan `ox_inventory/data/items.lua` en kopieert gevonden PNG-afbeeldingen naar `ox_inventory/web/images/`.

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

## Afbeeldingen

De manager gebruikt `client.image` of standaard `<itemnaam>.png` en zoekt onder andere in:

```text
images/
html/images/
web/images/
inventory_images/
install/images/
installation/images/
```

Voor een afwijkende map voeg je in de `fxmanifest.lua` van het bronscript toe:

```lua
rs_item_images 'assets/inventory'
```

Alleen veilige PNG-bestandsnamen worden automatisch gekopieerd. Dit sluit aan op de standaard `web/images/*.png`-regel van ox_inventory. Bestaande identieke afbeeldingen worden overgeslagen. Bij een andere afbeelding met dezelfde naam blijft standaard de bestaande versie staan en verschijnt het conflict in het rapport. Met `Config.ImageConflictPolicy = 'overwrite'` wordt eerst een back-up gemaakt en daarna de nieuwe afbeelding geplaatst.

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

Het volledige scanrapport staat in `rs_itemmanager/data/report.json`, inclusief gekopieerde, ontbrekende en conflicterende afbeeldingen. Bestaande items worden nooit overschreven. Het automatisch beheerde blok in `ox_inventory/data/items.lua` kan bij een volgende scan veilig worden bijgewerkt.

## Logging

De resource verstuurt het event `rs_discordlogs:server:log`. Vul eventueel daarnaast `Config.Webhook` in voor directe Discord-webhooklogging.
