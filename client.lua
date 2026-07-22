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
    local fuelAmount = tonumber(fuel) or 100.0
    
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if DoesEntityExist(vehicle) then
        if SetVehicleFuelLevel then
            SetVehicleFuelLevel(vehicle, fuelAmount)
        end

        -- Update state bag
        if Entity(vehicle) and Entity(vehicle).state then
            Entity(vehicle).state:set("fuel", fuelAmount, true)
        end

        -- Support popular fuel exports
        if GetResourceState('LegacyFuel') == 'started' then
            exports['LegacyFuel']:SetFuel(vehicle, fuelAmount)
        elseif GetResourceState('cdn-fuel') == 'started' then
            exports['cdn-fuel']:SetFuel(vehicle, fuelAmount)
        elseif GetResourceState('ox_fuel') == 'started' then
            exports['ox_fuel']:SetFuel(vehicle, fuelAmount)
        elseif GetResourceState('ps-fuel') == 'started' then
            exports['ps-fuel']:SetFuel(vehicle, fuelAmount)
        end
    end
end)
