local PROTOCOL = "order_system_v1"
local SERVER_NAME = "order_server"
local REQUEST_TIMEOUT = 5
local POLL_INTERVAL = 5
local RECEIPT_ITEM = "computercraft:printout"
local PAYMENT_PACKAGE_ADDRESS = "Money Transfer"
local REDSTONE_SIDE = "back"
local HOPPER_PERIPHERAL_NAME = ""
local PACKAGE_TIMEOUT = 45
local COMPLETED_FILE = "sent-orders.db"

local completedOrders = {}
local preparedReference
local lastMessage

local function loadCompletedOrders()
    if not fs.exists(COMPLETED_FILE) then return end
    local file = fs.open(COMPLETED_FILE, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" then completedOrders = saved end
end

local function saveCompletedOrders()
    local file = fs.open(COMPLETED_FILE, "w")
    if not file then return false end
    file.write(textutils.serialize(completedOrders))
    file.close()
    return true
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the Packager program.") end
end

local function request(message)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then return nil, "Order server not found. Check the network." end
    rednet.send(serverId, message, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)
    if type(response) ~= "table" then return nil, "No response from the order server." end
    if response.type == "error" then return nil, response.message or "The server rejected the request." end
    return response
end

local function hasMethod(name, methodName)
    for _, candidate in ipairs(peripheral.getMethods(name) or {}) do
        if candidate == methodName then return true end
    end
    return false
end

local function getInventories(excludedName, secondExcludedName)
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name ~= excludedName and name ~= secondExcludedName and hasMethod(name, "list")
            and hasMethod(name, "getItemDetail") and hasMethod(name, "pushItems") then
            table.insert(found, { name = name, device = peripheral.wrap(name) })
        end
    end
    return found
end

local function findPackager()
    for _, name in ipairs(peripheral.getNames()) do
        if hasMethod(name, "setAddress") then
            return name, peripheral.wrap(name)
        end
    end
    return nil
end

local function findHopper(packagerName)
    local function isInventory(name)
        return hasMethod(name, "list") and hasMethod(name, "getItemDetail")
            and hasMethod(name, "pushItems")
    end

    if HOPPER_PERIPHERAL_NAME ~= "" then
        if isInventory(HOPPER_PERIPHERAL_NAME) then
            return HOPPER_PERIPHERAL_NAME, peripheral.wrap(HOPPER_PERIPHERAL_NAME)
        end
        return nil, nil, "Configured hopper peripheral not found: " .. HOPPER_PERIPHERAL_NAME
    end

    local candidates = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name ~= packagerName and isInventory(name) then
            local peripheralType = peripheral.getType(name)
            local description = (name .. " " .. tostring(peripheralType)):lower()
            if description:find("hopper", 1, true) then
                table.insert(candidates, name)
            end
        end
    end
    if #candidates == 1 then
        return candidates[1], peripheral.wrap(candidates[1])
    end

    local available = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name ~= packagerName and isInventory(name) then table.insert(available, name) end
    end
    local message = "Could not uniquely identify the hopper. Set HOPPER_PERIPHERAL_NAME; inventories: "
        .. (#available > 0 and table.concat(available, ", ") or "none")
    return nil, nil, message
end

local function findNbtValue(root, key, depth)
    if type(root) ~= "table" or (depth or 0) > 8 then return nil end
    if root[key] ~= nil then return root[key] end
    for _, value in pairs(root) do
        if type(value) == "table" then
            local found = findNbtValue(value, key, (depth or 0) + 1)
            if found ~= nil then return found end
        end
    end
    return nil
end

local function printoutReference(detail)
    if not detail or detail.name ~= RECEIPT_ITEM then return nil end
    local title = findNbtValue(detail.nbt, "title")
    if type(title) ~= "string" then return nil end
    return title:match("(ORD%-%d%d%d%d%d%d)")
end

local function findPendingReference(inventories)
    for _, inventory in ipairs(inventories) do
        for slot in pairs(inventory.device.list()) do
            local reference = printoutReference(inventory.device.getItemDetail(slot, true))
            if reference and not completedOrders[reference] then return reference end
        end
    end
    return nil
end

local function packageAddress(detail)
    local address = findNbtValue(detail and detail.nbt, "create:package_address")
    if type(address) == "table" then address = address.value end
    return address
end

local function findPaymentPackage(inventories)
    for _, inventory in ipairs(inventories) do
        for slot in pairs(inventory.device.list()) do
            if packageAddress(inventory.device.getItemDetail(slot, true)) == PAYMENT_PACKAGE_ADDRESS then
                return inventory, slot
            end
        end
    end
    return nil
end

local function pulsePackager(name)
    local side = name
    if side ~= "left" and side ~= "right" and side ~= "top" and side ~= "bottom"
        and side ~= "front" and side ~= "back" then
        side = REDSTONE_SIDE
    end
    redstone.setOutput(side, false)
    sleep(0.2)
    redstone.setOutput(side, true)
    sleep(0.2)
    redstone.setOutput(side, false)
end

local function waitForHopper(name, hopper)
    local deadline = os.clock() + PACKAGE_TIMEOUT
    local emptyChecks = 0
    while os.clock() < deadline do
        local contents = hopper.list()
        if next(contents) == nil then
            emptyChecks = emptyChecks + 1
            if emptyChecks >= 4 then return true end
        else
            emptyChecks = 0
        end
        sleep(0.5)
    end
    return false, "Hopper " .. name .. " did not clear within " .. PACKAGE_TIMEOUT .. " seconds."
end

local function providerAddressFor(orderId)
    local response, err = request({ type = "get_provider_address", orderId = orderId })
    if not response then return nil, err end
    if response.type ~= "provider_address" or type(response.address) ~= "string"
        or response.address == "" then
        return nil, "The order server returned no provider address."
    end
    return response.address
end

local function sendOrder(reference, packagerName, packager, hopperName, hopper)
    local orderId = tonumber(reference:match("ORD%-(%d%d%d%d%d%d)"))
    local address, addressError = providerAddressFor(orderId)
    if not address then return false, addressError end

    if preparedReference ~= reference then
        local ok, setError = pcall(packager.setAddress, address)
        if not ok then return false, "Could not set the Packager address: " .. tostring(setError) end
        pulsePackager(packagerName)
        preparedReference = reference
    end

    local inventories = getInventories(packagerName, hopperName)
    local packageCount = 0
    while true do
        local source, slot = findPaymentPackage(inventories)
        if not source then break end
        if next(hopper.list()) ~= nil then
            return false, "Hopper " .. hopperName .. " must be empty before receiving another package."
        end
        local ok, transferred = pcall(source.device.pushItems, hopperName, slot, 1)
        if not ok then return false, "Could not move a mailbox package: " .. tostring(transferred) end
        if transferred ~= 1 then
            return false, "The hopper rejected a package from " .. source.name .. "."
        end
        pulsePackager(packagerName)
        local finished, waitError = waitForHopper(hopperName, hopper)
        if not finished then return false, waitError end
        packageCount = packageCount + 1
    end

    if packageCount == 0 then return false, "Waiting for Money Transfer packages." end
    completedOrders[reference] = true
    if not saveCompletedOrders() then
        return false, "Packages were sent, but completion could not be saved to " .. COMPLETED_FILE .. "."
    end
    preparedReference = nil
    return true, "Sent " .. packageCount .. " package(s) for " .. reference .. " to " .. address .. "."
end

local function processOneOrder()
    local packagerName, packager = findPackager()
    if not packagerName then return false, "No Packager peripheral with setAddress() was found." end
    local hopperName, hopper, hopperError = findHopper(packagerName)
    if not hopperName then return false, hopperError end
    local inventories = getInventories(packagerName, hopperName)
    local reference = findPendingReference(inventories)
    if not reference then return nil end
    return sendOrder(reference, packagerName, packager, hopperName, hopper)
end

openModems()
loadCompletedOrders()
print("Packager automation running. Waiting for an order printout...")

while true do
    local success, message = processOneOrder()
    if message and message ~= lastMessage then
        print(message)
        lastMessage = message
    elseif success then
        lastMessage = nil
    end
    sleep(POLL_INTERVAL)
end