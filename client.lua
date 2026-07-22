-- kp-web-support client handler for live entity manipulation

RegisterNetEvent('kp-web-support:client:repairVehicle', function(netId)
    if not netId then return end
    
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if DoesEntityExist(vehicle) then
        SetVehicleEngineHealth(vehicle, 1000.0)
        SetVehicleBodyHealth(vehicle, 1000.0)
        SetVehiclePetrolTankHealth(vehicle, 1000.0)
        SetVehicleFixed(vehicle)
        SetVehicleDeformationFixed(vehicle)
        SetVehicleDirtLevel(vehicle, 0.0)
        SetVehicleUndriveable(vehicle, false)
        SetVehicleEngineOn(vehicle, true, true)

        -- Extra framework compatibility triggers if present
        if GetResourceState('qb-vehiclefailure') == 'started' then
            TriggerEvent('qb-vehiclefailure:client:RepairVehicle', vehicle)
        end
    end
end)

RegisterNetEvent('kp-web-support:client:refuelVehicle', function(netId, fuel)
    if not netId then return end
    local fuelAmount = (tonumber(fuel) or 100.0) + 0.0
    
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if DoesEntityExist(vehicle) then
        SetVehicleFuelLevel(vehicle, fuelAmount)

        -- Update state bags
        if Entity(vehicle) and Entity(vehicle).state then
            Entity(vehicle).state:set("fuel", fuelAmount, true)
        end

        -- Try all popular fuel script exports independently
        local fuelExports = { 'LegacyFuel', 'qb-fuel', 'cdn-fuel', 'ox_fuel', 'ps-fuel', 'ti_fuel', 'Renewed-Fuel', 'lc_gas_station' }
        for _, resName in ipairs(fuelExports) do
            if GetResourceState(resName) == 'started' then
                pcall(function()
                    exports[resName]:SetFuel(vehicle, fuelAmount)
                end)
            end
        end
    end
end)

-- Periodically sync body and engine health to vehicle state bag for server & dashboard access
CreateThread(function()
    while true do
        Wait(2000)
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            if DoesEntityExist(veh) and GetPedInVehicleSeat(veh, -1) == ped then
                local bHealth = GetVehicleBodyHealth(veh)
                local eHealth = GetVehicleEngineHealth(veh)
                if Entity(veh) and Entity(veh).state then
                    Entity(veh).state:set('bodyHealth', bHealth, true)
                    Entity(veh).state:set('engineHealth', eHealth, true)
                end
            end
        end
    end
end)

