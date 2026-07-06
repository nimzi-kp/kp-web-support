local logBuffer = {}
local Debug = false

-- Capture server-wide console log outputs in real-time
AddEventHandler('onLogLine', function(msg)
    -- Strip color codes (e.g. ^1, ^2) and clean carriage returns
    local cleanMsg = msg:gsub("%^%d", ""):gsub("[\r\n]", "")
    if cleanMsg and cleanMsg ~= "" then
        table.insert(logBuffer, cleanMsg)
        if #logBuffer > 150 then
            table.remove(logBuffer, 1)
        end
    end
end)

-- Automatic Self-Updater from GitHub Repo via HTTP
CreateThread(function()
    local owner = "nimzi-kp"
    local repo = "kp-web-support"
    local branch = "main"

    local files = { "server.lua", "fxmanifest.lua" }

    if not owner or not repo or not branch then
        if Debug then
            print("^3[kp-web-support] GitHub configuration not complete. Skipping auto-updater.^0")
        end
        return
    end

    for _, filename in ipairs(files) do
        local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s?nocache=%s", owner, repo, branch, filename, tostring(os.time()))
        
        PerformHttpRequest(url, function(statusCode, responseText, headers)
            if statusCode == 200 and responseText and responseText ~= "" then
                local localContent = LoadResourceFile(GetCurrentResourceName(), filename)
                -- If remote content differs from local, save it to disk
                if localContent ~= responseText then
                    SaveResourceFile(GetCurrentResourceName(), filename, responseText, -1)
                    print(string.format("^2[kp-web-support] Updated file automatically: %s. Restart resource to apply updates.^0", filename))
                end
            elseif statusCode == 404 then
                if Debug then
                    print(string.format("^3[kp-web-support] File %s not found in repository path.^0", filename))
                end
            else
                print(string.format("^1[kp-web-support] Failed to download %s (Status Code: %s)^0", filename, tostring(statusCode)))
            end
        end, "GET", "", {})
    end
end)

-- Verify dependencies
if GetResourceState('qbx_core') == 'missing' and GetResourceState('qb-core') == 'missing' then
    print('^1[kp-web-support] Warning: Neither qbx_core nor qb-core was found. Some framework actions may fail.^0')
end

-- HTTP Handler
SetHttpHandler(function(req, res)
    local rawPath = req.path
    local path = rawPath
    local queryParams = {}
    
    local qStart = string.find(rawPath, "?")
    if qStart then
        path = string.sub(rawPath, 1, qStart - 1)
        local qStr = string.sub(rawPath, qStart + 1)
        for k, v in string.gmatch(qStr, "([^&=]+)=([^&=]+)") do
            queryParams[k] = v
        end
    end

    local method = req.method
    local headers = req.headers

    if Debug then
        print(string.format('^3[kp-web-support] Incoming request: %s %s^0', method, path))
    end

    -- Verify API Key (Strictly loaded from server.cfg via 'set kp_web_api_key')
    local apiKey = headers["X-Bridge-API-Key"] or headers["x-bridge-api-key"]
    local expectedKey = GetConvar("kp_web_api_key", "")
    if expectedKey == "" or apiKey ~= expectedKey then
        res.writeHead(403, {["Content-Type"] = "application/json"})
        res.send(json.encode({ error = "Unauthorized: Invalid or unconfigured API Key" }))
        return
    end

    local function proceed(data)
        -- Endpoint: /player/kick
        if path == "/player/kick" and method == "POST" then
            local targetSrc = tonumber(data.source)
            local reason = data.reason or "Kicked via Staff Control Panel"
            if targetSrc and GetPlayerName(targetSrc) then
                DropPlayer(targetSrc, reason)
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Player successfully kicked" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Target player not online or invalid source" }))
            end

        -- Endpoint: /player/revive
        elseif path == "/player/revive" and method == "POST" then
            local targetSrc = tonumber(data.source)
            if targetSrc and GetPlayerName(targetSrc) then
                -- Trigger the exact client event qbx_ambulancejob/qbx_medical uses to revive players
                TriggerClientEvent("qbx_medical:client:playerRevived", targetSrc)
                TriggerClientEvent("hospital:client:Revive", targetSrc)

                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Revive command dispatched" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Target player offline or invalid source" }))
            end

        -- Endpoint: /player/give-money
        elseif path == "/player/give-money" and method == "POST" then
            local citizenId = data.citizenId
            local amount = tonumber(data.amount)
            local moneyType = data.moneyType or "bank"
            
            if not citizenId or not amount then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing citizenId or amount parameters" }))
                return
            end

            local success = false
            local errMsg = "Framework not initialized"

            -- Qbox Framework integration check
            if GetResourceState('qbx_core') == 'started' then
                local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                if player then
                    success = player.Functions.AddMoney(moneyType, amount, "Staff Dashboard adjustment")
                else
                    -- Handle offline Qbox players (directly update database or return status)
                    errMsg = "Player offline, offline adjustments require database integration"
                end
            elseif GetResourceState('qb-core') == 'started' then
                local QBCore = exports['qb-core']:GetCoreObject()
                local player = QBCore.Functions.GetPlayerByCitizenId(citizenId)
                if player then
                    success = player.Functions.AddMoney(moneyType, amount, "Staff Dashboard adjustment")
                else
                    errMsg = "Player offline"
                end
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Successfully added money to character" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = errMsg }))
            end

        -- Endpoint: /player/set-job
        elseif path == "/player/set-job" and method == "POST" then
            local citizenId = data.citizenId
            local jobName = data.jobName
            local jobGrade = tonumber(data.jobGrade) or 0

            if not citizenId or not jobName then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing citizenId or jobName parameters" }))
                return
            end

            local success = false
            local errMsg = "Framework not initialized"

            if GetResourceState('qbx_core') == 'started' then
                local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                if player then
                    success = player.Functions.SetJob(jobName, jobGrade)
                else
                    errMsg = "Player offline"
                end
            elseif GetResourceState('qb-core') == 'started' then
                local QBCore = exports['qb-core']:GetCoreObject()
                local player = QBCore.Functions.GetPlayerByCitizenId(citizenId)
                if player then
                    success = player.Functions.SetJob(jobName, jobGrade)
                else
                    errMsg = "Player offline"
                end
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Job changed successfully" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = errMsg }))
            end

        -- Endpoint: /player/set-gang
        elseif path == "/player/set-gang" and method == "POST" then
            local citizenId = data.citizenId
            local gangName = data.gangName
            local gangGrade = tonumber(data.gangGrade) or 0

            if not citizenId or not gangName then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing citizenId or gangName parameters" }))
                return
            end

            local success = false
            local errMsg = "Framework not initialized"

            if GetResourceState('qbx_core') == 'started' then
                local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                if player then
                    success = player.Functions.SetGang(gangName, gangGrade)
                else
                    errMsg = "Player offline"
                end
            elseif GetResourceState('qb-core') == 'started' then
                local QBCore = exports['qb-core']:GetCoreObject()
                local player = QBCore.Functions.GetPlayerByCitizenId(citizenId)
                if player then
                    success = player.Functions.SetGang(gangName, gangGrade)
                else
                    errMsg = "Player offline"
                end
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Gang faction changed successfully" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = errMsg }))
            end

        -- Endpoint: /player/change-name
        elseif path == "/player/change-name" and method == "POST" then
            local citizenId = data.citizenId
            local firstname = data.firstname
            local lastname = data.lastname

            if not citizenId or not firstname or not lastname then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing citizenId, firstname, or lastname parameters" }))
                return
            end

            local success = false
            local errMsg = "Player offline"

            if GetResourceState('qbx_core') == 'started' then
                local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                if player then
                    local charinfo = player.PlayerData.charinfo
                    charinfo.firstname = firstname
                    charinfo.lastname = lastname
                    player.Functions.SetPlayerData("charinfo", charinfo)
                    success = true
                end
            elseif GetResourceState('qb-core') == 'started' then
                local QBCore = exports['qb-core']:GetCoreObject()
                local player = QBCore.Functions.GetPlayerByCitizenId(citizenId)
                if player then
                    local charinfo = player.PlayerData.charinfo
                    charinfo.firstname = firstname
                    charinfo.lastname = lastname
                    player.Functions.SetPlayerData("charinfo", charinfo)
                    success = true
                end
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Character name updated successfully" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = errMsg }))
            end

        -- Endpoint: /player/teleport
        elseif path == "/player/teleport" and method == "POST" then
            local targetSrc = tonumber(data.source)
            local citizenId = data.citizenId
            local targetType = data.targetType
            
            if not targetSrc and citizenId then
                if GetResourceState('qbx_core') == 'started' then
                    local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                    if player then targetSrc = player.PlayerData.source end
                elseif GetResourceState('qb-core') == 'started' then
                    local QBCore = exports['qb-core']:GetCoreObject()
                    local player = QBCore.Functions.GetPlayerByCitizenId(citizenId)
                    if player then targetSrc = player.PlayerData.source end
                end
            end

            if not targetSrc or not GetPlayerName(targetSrc) then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Target player not online or invalid source" }))
                return
            end

            local success = false
            local ped = GetPlayerPed(targetSrc)

            if targetType == "coords" then
                local x = tonumber(data.x)
                local y = tonumber(data.y)
                local z = tonumber(data.z)
                local w = tonumber(data.w)
                if x and y and z then
                    SetEntityCoords(ped, x, y, z, false, false, false, true)
                    if w then
                        SetEntityHeading(ped, w)
                    end
                    success = true
                end
            elseif targetType == "player" then
                local targetPlayerId = tonumber(data.targetPlayerId)
                
                -- Support looking up target by Citizen ID as well
                if not targetPlayerId then
                    local targetCitizenId = tostring(data.targetPlayerId)
                    if GetResourceState('qbx_core') == 'started' then
                        local player = exports.qbx_core:GetPlayerByCitizenId(targetCitizenId)
                        if player then targetPlayerId = player.PlayerData.source end
                    end
                end

                if targetPlayerId and GetPlayerName(targetPlayerId) then
                    local targetPed = GetPlayerPed(targetPlayerId)
                    local coords = GetEntityCoords(targetPed)
                    local heading = GetEntityHeading(targetPed)
                    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, true)
                    SetEntityHeading(ped, heading)
                    success = true
                end
            elseif targetType == "location" or targetType == "preset" then
                local locations = {
                    ["hospital"] = vector4(295.6186, -583.5738, 43.1548, 245.2264),
                    ["police station"] = vector4(144.8340, -348.2341, 43.7876, 112.2724),
                    ["main garage"] = vector4(-272.6911, -923.1238, 32.9430, 121.5711),
                    ["muthuk garage"] = vector4(-2000.4756, -494.5683, 11.3785, 48.8590),
                    ["airport"] = vector4(-1037.8004, -2737.5520, 20.1693, 325.2922),
                    ["paleto"] = vector4(111.9013, 6597.1875, 32.1295, 269.1739),
                    ["sandy"] = vector4(1508.6074, 3770.0098, 34.1255, 137.2714),
                    ["youtool"] = vector4(2756.5671, 3469.3877, 55.7346, 67.7124)
                }
                local name = tostring(data.locationName):lower()
                local coords = locations[name]
                if coords then
                    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, true)
                    SetEntityHeading(ped, coords.w)
                    success = true
                end
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Player successfully teleported" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Teleportation failed: invalid parameters" }))
            end

        -- Endpoint: /player/give-item
        elseif path == "/player/give-item" and method == "POST" then
            local citizenId = data.citizenId
            local itemName = data.itemName
            local itemCount = tonumber(data.itemCount) or 1

            if not citizenId or not itemName then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing citizenId or itemName parameters" }))
                return
            end

            local success = false
            local errMsg = "Player offline"

            if GetResourceState('qbx_core') == 'started' then
                local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                if player then
                    if GetResourceState('ox_inventory') == 'started' then
                        success = exports.ox_inventory:AddItem(player.PlayerData.source, itemName, itemCount)
                    else
                        success = player.Functions.AddItem(itemName, itemCount)
                    end
                end
            elseif GetResourceState('qb-core') == 'started' then
                local QBCore = exports['qb-core']:GetCoreObject()
                local player = QBCore.Functions.GetPlayerByCitizenId(citizenId)
                if player then
                    if GetResourceState('ox_inventory') == 'started' then
                        success = exports.ox_inventory:AddItem(player.PlayerData.source, itemName, itemCount)
                    else
                        success = player.Functions.AddItem(itemName, itemCount)
                    end
                end
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Item successfully given to player" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = errMsg }))
            end

        -- Endpoint: /player/clear-inventory
        elseif path == "/player/clear-inventory" and method == "POST" then
            local citizenId = data.citizenId
            local targetSrc = tonumber(data.source)
            
            -- Resolve source if player is online but source not sent
            if not targetSrc and citizenId then
                if GetResourceState('qbx_core') == 'started' then
                    local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                    if player then targetSrc = player.PlayerData.source end
                elseif GetResourceState('qb-core') == 'started' then
                    local QBCore = exports['qb-core']:GetCoreObject()
                    local player = QBCore.Functions:GetPlayerByCitizenId(citizenId)
                    if player then targetSrc = player.PlayerData.source end
                end
            end

            local success = false
            local errMsg = "Player offline"

            if targetSrc and GetPlayerName(targetSrc) then
                if GetResourceState('ox_inventory') == 'started' then
                    exports.ox_inventory:ClearInventory(targetSrc)
                end
                
                if GetResourceState('qbx_core') == 'started' then
                    local player = exports.qbx_core:GetPlayer(targetSrc)
                    if player then
                        player.Functions.ClearInventory()
                    end
                elseif GetResourceState('qb-core') == 'started' then
                    local QBCore = exports['qb-core']:GetCoreObject()
                    local player = QBCore.Functions:GetPlayer(targetSrc)
                    if player then
                        player.Functions.ClearInventory()
                    end
                end
                success = true
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, message = "Inventory cleared successfully" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = errMsg }))
            end

        -- Endpoint: /player/data
        elseif path == "/player/data" and method == "GET" then
            local targetSrc = tonumber(queryParams.source or data.source)
            local citizenId = queryParams.citizenId or data.citizenId

            if not targetSrc and citizenId then
                if GetResourceState('qbx_core') == 'started' then
                    local player = exports.qbx_core:GetPlayerByCitizenId(citizenId)
                    if player then targetSrc = player.PlayerData.source end
                elseif GetResourceState('qb-core') == 'started' then
                    local QBCore = exports['qb-core']:GetCoreObject()
                    local player = QBCore.Functions:GetPlayerByCitizenId(citizenId)
                    if player then targetSrc = player.PlayerData.source end
                end
            end

            if targetSrc and GetPlayerName(targetSrc) then
                local money = { cash = 0, bank = 0 }
                local inventory = {}

                -- 1. Get money
                if GetResourceState('qbx_core') == 'started' then
                    local player = exports.qbx_core:GetPlayer(targetSrc)
                    if player then
                        money.cash = player.PlayerData.money.cash or 0
                        money.bank = player.PlayerData.money.bank or 0
                    end
                elseif GetResourceState('qb-core') == 'started' then
                    local QBCore = exports['qb-core']:GetCoreObject()
                    local player = QBCore.Functions:GetPlayer(targetSrc)
                    if player then
                        money.cash = player.PlayerData.money.cash or 0
                        money.bank = player.PlayerData.money.bank or 0
                    end
                end

                -- 2. Get inventory items
                if GetResourceState('ox_inventory') == 'started' then
                    local oxItems = exports.ox_inventory:GetInventoryItems(targetSrc)
                    if oxItems then
                        for slot, item in pairs(oxItems) do
                            if item and item.name then
                                table.insert(inventory, {
                                    name = item.name,
                                    label = item.label or item.name,
                                    amount = item.count or item.amount or 1,
                                    slot = tonumber(slot) or item.slot or 1
                                })
                            end
                        end
                    end
                else
                    local player = nil
                    if GetResourceState('qbx_core') == 'started' then
                        player = exports.qbx_core:GetPlayer(targetSrc)
                    elseif GetResourceState('qb-core') == 'started' then
                        local QBCore = exports['qb-core']:GetCoreObject()
                        player = QBCore.Functions:GetPlayer(targetSrc)
                    end

                    if player and player.PlayerData.items then
                        for slot, item in pairs(player.PlayerData.items) do
                            if item and item.name then
                                table.insert(inventory, {
                                    name = item.name,
                                    label = item.label or item.count or item.name,
                                    amount = item.amount or item.count or 1,
                                    slot = tonumber(slot) or item.slot or 1
                                })
                            end
                        end
                    end
                end

                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, money = money, inventory = inventory }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Player not online" }))
            end

        -- Endpoint: /vehicle/data
        elseif path == "/vehicle/data" and method == "GET" then
            local plate = queryParams.plate or data.plate
            if not plate then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing plate parameter" }))
                return
            end

            plate = string.upper(tostring(plate)):gsub("%s+", "")
            local found = false
            local liveData = {}

            local ok, err = pcall(function()
                if not GetAllVehicles then
                    return
                end
                local allVehicles = GetAllVehicles()
                if allVehicles then
                    for _, vehicle in ipairs(allVehicles) do
                        local vehPlate = GetVehicleNumberPlateText(vehicle)
                        if vehPlate then
                            local cleanVehPlate = string.upper(vehPlate):gsub("%s+", "")
                            if cleanVehPlate == plate then
                                found = true
                                local engineHealth = GetVehicleEngineHealth(vehicle)
                                local bodyHealth = GetVehicleBodyHealth(vehicle)
                                
                                print(string.format("[Vehicle Debug] Plate: %s | Engine Health: %s | Body Health: %s", plate, tostring(engineHealth), tostring(bodyHealth)))
                                
                                local fuel = 100.0
                                if Entity(vehicle).state.fuel then
                                    fuel = Entity(vehicle).state.fuel
                                elseif GetVehicleFuelLevel then
                                    fuel = GetVehicleFuelLevel(vehicle)
                                end
                                local coords = GetEntityCoords(vehicle)
                                liveData = {
                                    online = true,
                                    engine = engineHealth,
                                    body = bodyHealth,
                                    fuel = fuel,
                                    coords = { x = coords.x, y = coords.y, z = coords.z }
                                }
                                break
                            end
                        end
                    end
                end
            end)

            if not ok then
                print("^1[kp-web-support] Error in /vehicle/data: " .. tostring(err) .. "^0")
            end

            if found then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, vehicle = liveData }))
            else
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = false, message = "Vehicle not spawned/active in world" }))
            end

        -- Endpoint: /vehicle/action
        elseif path == "/vehicle/action" and method == "POST" then
            local plate = data.plate
            local action = data.action
            if not plate or not action then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing plate or action parameters" }))
                return
            end

            plate = string.upper(tostring(plate)):gsub("%s+", "")
            local success = false
            local errMsg = "Vehicle not active/spawned in world"

            local ok, err = pcall(function()
                if not GetAllVehicles then
                    errMsg = "GetAllVehicles native is not available on this FiveM server (OneSync might be disabled)"
                    return
                end
                local allVehicles = GetAllVehicles()
                if allVehicles then
                    for _, vehicle in ipairs(allVehicles) do
                        local vehPlate = GetVehicleNumberPlateText(vehicle)
                        if vehPlate then
                            local cleanVehPlate = string.upper(vehPlate):gsub("%s+", "")
                            if cleanVehPlate == plate then
                                if action == "repair" then
                                    SetVehicleEngineHealth(vehicle, 1000.0)
                                    SetVehicleBodyHealth(vehicle, 1000.0)
                                    SetVehicleFixed(vehicle)
                                    SetVehicleDirtLevel(vehicle, 0.0)
                                    success = true
                                elseif action == "refuel" then
                                    local fuelVal = tonumber(data.fuel) or 100.0
                                    if Entity(vehicle).state.fuel then
                                        Entity(vehicle).state.fuel = fuelVal
                                    end
                                    if SetVehicleFuelLevel then
                                        SetVehicleFuelLevel(vehicle, fuelVal)
                                    end
                                    success = true
                                end
                                break
                            end
                        end
                    end
                end
            end)

            if not ok then
                print("^1[kp-web-support] Error in /vehicle/action: " .. tostring(err) .. "^0")
                res.writeHead(500, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Internal server error in vehicle action", details = tostring(err) }))
                return
            end

            res.writeHead(200, {["Content-Type"] = "application/json"})
            res.send(json.encode({ success = success, message = success and "Vehicle action executed successfully" or errMsg }))

        -- Endpoint: /status
        elseif path == "/status" and method == "GET" then
            local players = GetPlayers()
            local activePlayersCount = #players
            local uptimeMs = GetGameTimer()
            local activeResources = GetNumResources()
            
            local onlinePlayersList = {}
            for _, src in ipairs(players) do
                local numSrc = tonumber(src)
                local license = ""
                local citizenid = ""
                local name = GetPlayerName(numSrc) or "Unknown"
                
                for i = 0, GetNumPlayerIdentifiers(numSrc) - 1 do
                    local ident = GetPlayerIdentifier(numSrc, i)
                    if string.match(ident, "license:") then
                        license = ident
                        break
                    end
                end
                
                if GetResourceState('qbx_core') == 'started' then
                    local player = exports.qbx_core:GetPlayer(numSrc)
                    if player then
                        citizenid = player.PlayerData.citizenid
                    end
                elseif GetResourceState('qb-core') == 'started' then
                    local QBCore = exports['qb-core']:GetCoreObject()
                    local player = QBCore.Functions.GetPlayer(numSrc)
                    if player then
                        citizenid = player.PlayerData.citizenid
                    end
                end
                
                table.insert(onlinePlayersList, {
                    source = numSrc,
                    name = name,
                    license = license,
                    citizenid = citizenid
                })
            end

            res.writeHead(200, {["Content-Type"] = "application/json"})
            res.send(json.encode({
                status = "online",
                playersCount = activePlayersCount,
                uptime = uptimeMs,
                resources = activeResources,
                fps = 60,
                players = onlinePlayersList
            }))

        -- Endpoint: /server/resources
        elseif path == "/server/resources" and method == "GET" then
            local resourcesList = {}
            local num = GetNumResources()
            for i = 0, num - 1 do
                local name = GetResourceByFindIndex(i)
                local state = GetResourceState(name)
                local version = GetResourceMetadata(name, 'version') or '1.0.0'
                local author = GetResourceMetadata(name, 'author') or 'Unknown'
                local isDefault = false
                local rPath = GetResourcePath(name)
                if rPath then
                    rPath = string.lower(rPath)
                    if string.find(rPath, "%[cfx%-default%]") or string.find(rPath, "%[default%]") or string.find(rPath, "citizen/system_resources") then
                        isDefault = true
                    end
                end
                
                local defaultNames = { 
                    chat = true, playernames = true, spawnmanager = true, 
                    sessionmanager = true, hardcap = true, rconlog = true, 
                    baseevents = true, yarn = true, webpack = true, 
                    monitor = true, webadmin = true, mapmanager = true,
                    ["basic-gamemode"] = true, ["screenshot-basic"] = true
                }
                if defaultNames[string.lower(name)] then
                    isDefault = true
                end

                table.insert(resourcesList, {
                    name = name,
                    version = version,
                    author = author,
                    status = state,
                    isDefault = isDefault
                })
            end
            res.writeHead(200, {["Content-Type"] = "application/json"})
            res.send(json.encode({ success = true, resources = resourcesList }))

        -- Endpoint: /server/resource/action
        elseif path == "/server/resource/action" and method == "POST" then
            local resourceName = data.resourceName
            local action = data.action
            if not resourceName or not action then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing parameters" }))
                return
            end

            local success = false
            if action == "start" then
                success = StartResource(resourceName)
            elseif action == "stop" then
                success = StopResource(resourceName)
            elseif action == "restart" then
                StopResource(resourceName)
                success = StartResource(resourceName)
            end

            if success then
                res.writeHead(200, {["Content-Type"] = "application/json"})
                res.send(json.encode({ success = true, status = GetResourceState(resourceName), message = "Action performed successfully" }))
            else
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Failed to perform resource action" }))
            end

        -- Endpoint: /server/console/command
        elseif path == "/server/console/command" and method == "POST" then
            local command = data.command
            if not command then
                res.writeHead(400, {["Content-Type"] = "application/json"})
                res.send(json.encode({ error = "Missing command parameter" }))
                return
            end

            print(string.format("> %s", command))
            ExecuteCommand(command)
            res.writeHead(200, {["Content-Type"] = "application/json"})
            res.send(json.encode({ success = true, message = "Command executed successfully" }))

        -- Endpoint: /server/console/logs
        elseif path == "/server/console/logs" and method == "GET" then
            res.writeHead(200, {["Content-Type"] = "application/json"})
            res.send(json.encode({ success = true, logs = logBuffer }))

        else
            res.writeHead(404, {["Content-Type"] = "application/json"})
            res.send(json.encode({ error = "Endpoint not found" }))
        end
    end

    if method == "POST" or method == "PUT" then
        req.setDataHandler(function(body)
            local data = {}
            if body and body ~= "" then
                local status, result = pcall(json.decode, body)
                if status then
                    data = result
                else
                    print('^1[kp-web-support] Failed to decode JSON body^0')
                end
            end
            proceed(data)
        end)
    else
        proceed({})
    end
end)
