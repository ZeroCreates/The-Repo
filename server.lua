local PROTOCOL = "order_system_v1"
local SERVER_NAME = "order_server"
local DATA_FILE = "orders.db"
local BACKUP_FILE = "orders.db.bak"
local TEMP_FILE = "orders.db.tmp"
local state

local ALLOWED_TRANSITIONS = {
    received = { preparing = true, cancelled = true },
    preparing = { ready = true, cancelled = true },
    ready = { completed = true },
    completed = {},
    cancelled = {},
}

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the order server.") end
end

local function readState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserialize, contents)
    if ok and type(data) == "table" and type(data.nextId) == "number"
        and type(data.orders) == "table" then
        return data
    end
    return nil
end

local function loadState()
    if not fs.exists(DATA_FILE) and not fs.exists(BACKUP_FILE) then
        return { nextId = 1, nextProductId = 1, orders = {}, products = {} }
    end
    local loaded = readState(DATA_FILE) or readState(BACKUP_FILE)
    if not loaded then
        error("Could not read orders.db or its backup; refusing to overwrite order data.")
    end
    loaded.products = type(loaded.products) == "table" and loaded.products or {}
    loaded.nextProductId = loaded.nextProductId or 1
    return loaded
end

local function saveState()
    local file = fs.open(TEMP_FILE, "w")
    file.write(textutils.serialize(state))
    file.close()
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists(DATA_FILE) then fs.move(DATA_FILE, BACKUP_FILE) end
    fs.move(TEMP_FILE, DATA_FILE)
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
end

local function sendError(senderId, message)
    rednet.send(senderId, { type = "error", message = message }, PROTOCOL)
end

local function findOrder(orderId)
    for _, order in ipairs(state.orders) do
        if order.id == orderId then return order end
    end
end

local function findProduct(productId)
    for _, product in ipairs(state.products) do
        if product.id == productId then return product end
    end
end

local function createOrder(senderId, message)
    if type(message.items) ~= "table" or #message.items < 1 or #message.items > 50 then
        return sendError(senderId, "Choose at least one available product.")
    end
    local items, total, seen = {}, 0, {}
    local orderProviderId
    for _, requested in ipairs(message.items) do
        if type(requested) ~= "table" or type(requested.productId) ~= "number"
            or requested.productId % 1 ~= 0 or type(requested.quantity) ~= "number"
            or requested.quantity % 1 ~= 0 or requested.quantity < 1 or requested.quantity > 99 then
            return sendError(senderId, "The order contains an invalid item or quantity.")
        end
        local product = findProduct(requested.productId)
        if not product or not product.available or seen[requested.productId] then
            return sendError(senderId, "A product is unavailable or repeated in this order.")
        end
        if orderProviderId and orderProviderId ~= product.providerId then
            return sendError(senderId, "Place separate orders for products from different providers.")
        end
        orderProviderId = product.providerId
        seen[requested.productId] = true
        local lineTotal = product.price * requested.quantity
        total = total + lineTotal
        table.insert(items, {
            productId = product.id,
            providerId = product.providerId,
            providerName = product.providerName,
            name = product.name,
            quantity = requested.quantity,
            unitPrice = product.price,
            lineTotal = lineTotal,
        })
    end
    local now = os.epoch("utc")
    local order = {
        id = state.nextId,
        providerId = orderProviderId,
        items = items,
        total = total,
        status = "received",
        createdAt = now,
        updatedAt = now,
    }
    state.nextId = state.nextId + 1
    table.insert(state.orders, order)
    saveState()
    rednet.send(senderId, { type = "order_created", order = order }, PROTOCOL)
end

local function getOrder(senderId, message)
    if type(message.orderId) ~= "number" then
        return sendError(senderId, "Enter a valid order number.")
    end
    local order = findOrder(message.orderId)
    if not order then return sendError(senderId, "Order not found.") end
    rednet.send(senderId, { type = "order_status", order = order }, PROTOCOL)
end

local function listOrders(senderId)
    local active = {}
    for _, order in ipairs(state.orders) do
        if (order.providerId == senderId or order.providerId == nil)
            and order.status ~= "completed" and order.status ~= "cancelled" then
            table.insert(active, order)
        end
    end
    rednet.send(senderId, { type = "provider_orders", orders = active }, PROTOCOL)
end

local function getCatalog(senderId)
    local available = {}
    for _, product in ipairs(state.products) do
        if product.available then table.insert(available, product) end
    end
    rednet.send(senderId, { type = "catalog", products = available }, PROTOCOL)
end

local function listProviderProducts(senderId)
    local products = {}
    for _, product in ipairs(state.products) do
        if product.providerId == senderId then table.insert(products, product) end
    end
    rednet.send(senderId, { type = "provider_products", products = products }, PROTOCOL)
end

local function publishProduct(senderId, message)
    local submitted = message.product
    if type(submitted) ~= "table" or type(submitted.name) ~= "string"
        or type(submitted.price) ~= "number" or submitted.price % 1 ~= 0
        or submitted.price < 1 or submitted.price > 1000000
        or type(submitted.available) ~= "boolean" then
        return sendError(senderId, "Product name, price, or availability is invalid.")
    end
    local name = submitted.name:match("^%s*(.-)%s*$")
    if #name < 1 or #name > 32 or name:find("%c") then
        return sendError(senderId, "Product names must be 1 to 32 characters without control characters.")
    end

    local product
    if submitted.id ~= nil then
        if type(submitted.id) ~= "number" or submitted.id % 1 ~= 0 then
            return sendError(senderId, "Invalid product ID.")
        end
        product = findProduct(submitted.id)
        if not product or product.providerId ~= senderId then
            return sendError(senderId, "You can only edit your own products.")
        end
    else
        product = {
            id = state.nextProductId,
            providerId = senderId,
            createdAt = os.epoch("utc"),
        }
        state.nextProductId = state.nextProductId + 1
        table.insert(state.products, product)
    end

    product.name = name
    product.price = submitted.price
    product.available = submitted.available
    local providerName = type(submitted.providerName) == "string" and submitted.providerName or ""
    providerName = providerName:match("^%s*(.-)%s*$")
    if providerName == "" then providerName = "Provider #" .. senderId end
    product.providerName = providerName:sub(1, 24)
    product.updatedAt = os.epoch("utc")
    saveState()
    rednet.send(senderId, { type = "product_saved", product = product }, PROTOCOL)
end

local function updateOrder(senderId, message)
    if type(message.orderId) ~= "number" or type(message.status) ~= "string" then
        return sendError(senderId, "The status update is invalid.")
    end
    local order = findOrder(message.orderId)
    if not order then return sendError(senderId, "Order not found.") end
    if order.providerId and order.providerId ~= senderId then
        return sendError(senderId, "You can only update orders for your products.")
    end
    if not ALLOWED_TRANSITIONS[order.status] or not ALLOWED_TRANSITIONS[order.status][message.status] then
        return sendError(senderId, "That status change is not allowed for this order.")
    end
    order.status = message.status
    order.updatedAt = os.epoch("utc")
    saveState()
    rednet.send(senderId, { type = "status_updated", order = order }, PROTOCOL)
end

openModems()
state = loadState()
rednet.host(PROTOCOL, SERVER_NAME)
print("Order server running as " .. SERVER_NAME)
print("Saved orders: " .. #state.orders .. "  |  Products: " .. #state.products)

while true do
    local senderId, message = rednet.receive(PROTOCOL)
    if type(message) ~= "table" then
        sendError(senderId, "Invalid request.")
    elseif message.type == "place_order" then
        createOrder(senderId, message)
    elseif message.type == "get_order" then
        getOrder(senderId, message)
    elseif message.type == "provider_list" then
        listOrders(senderId)
    elseif message.type == "get_catalog" then
        getCatalog(senderId)
    elseif message.type == "get_provider_products" then
        listProviderProducts(senderId)
    elseif message.type == "publish_product" then
        publishProduct(senderId, message)
    elseif message.type == "set_status" then
        updateOrder(senderId, message)
    else
        sendError(senderId, "Unknown request.")
    end
end
