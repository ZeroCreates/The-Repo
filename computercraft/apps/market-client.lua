local PROTOCOL = "order_system_v1"
local CONTROL_PROTOCOL = "launcher_market_notifications_v1"
local NOTIFICATION_PROTOCOL = "launcher_notifications_v1"
local SERVER_NAME = "order_server"
local TIMEOUT = 5
local FOLLOWED_ORDERS_FILE = "market-followed-orders.json"
local MARKET_USER = "Market customer"
local notifications = require("notifications")
local mouseEnabled = false
local followedOrders = {}

local function clearScreen()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
end

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    term.setCursorPos(x, y)
    term.setTextColor(foreground or colors.white)
    term.setBackgroundColor(background or colors.black)
    term.write(tostring(text):sub(1, width - x + 1))
    term.setBackgroundColor(colors.black)
end

local function drawHeader(title, subtitle)
    local width = term.getSize()
    clearScreen()
    writeAt(1, 1, string.rep(" ", width), colors.white, colors.cyan)
    writeAt(2, 1, title, colors.white, colors.cyan)
    writeAt(2, 2, subtitle, colors.lightGray)
end

local function sectionTitle(y, title)
    local width = term.getSize()
    writeAt(1, y, string.rep(" ", width), colors.white, colors.blue)
    writeAt(2, y, title, colors.white, colors.blue)
end

local function drawChoices(help)
    local width, height = term.getSize()
    local options = {}
    for part in help:gmatch("[^|]+") do
        local key, label = part:match("^%s*([%w/]+)%s*(.-)%s*$")
        if key then
            if key:find("/") then
                local first, second = key:match("([^/]+)/([^/]+)")
                table.insert(options, { key = first, label = "NEXT " .. label })
                table.insert(options, { key = second, label = "PREV " .. label })
            else
                table.insert(options, { key = key, label = label ~= "" and label or key })
            end
        end
    end

    if #options == 0 then return {} end
    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local row = height - rows + math.floor((index - 1) / columns)
        local column = (index - 1) % columns
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[" .. option.label .. "]"):sub(1, right - left + 1)
        writeAt(left, row, label, colors.black, colors.lightBlue)
        table.insert(buttons, { key = option.key, row = row, left = left, right = right })
    end
    return buttons
end

local function readChoice(help)
    if not mouseEnabled then
        local _, height = term.getSize()
        writeAt(2, height - 2, help, colors.lightGray)
        writeAt(2, height - 1, "> ", colors.lime)
        term.setCursorPos(4, height - 1)
        return read():lower()
    end

    local buttons = drawChoices(help)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key
                end
            end
        end
    end
end

local function showNotice(title, message)
    drawHeader(title, "ORDER DESK  /  SHARED PRODUCT CATALOG")
    writeAt(2, 5, message, colors.white)
    if mouseEnabled then
        readChoice("ok continue")
    else
        writeAt(2, 7, "Press Enter to continue.", colors.lightGray)
        read()
    end
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the ordering page.") end
    mouseEnabled = term.isColor()
end

local function loadFollowedOrders()
    followedOrders = {}
    if not fs.exists(FOLLOWED_ORDERS_FILE) then return end
    local file = fs.open(FOLLOWED_ORDERS_FILE, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    if not ok or type(saved) ~= "table" then return end
    for _, entry in ipairs(saved) do
        if type(entry) == "table" and type(entry.orderId) == "number"
            and entry.orderId % 1 == 0 and type(entry.status) == "string" then
            followedOrders[entry.orderId] = { orderId = entry.orderId, status = entry.status }
        end
    end
end

local function saveFollowedOrders()
    local saved = {}
    for _, entry in pairs(followedOrders) do
        table.insert(saved, { orderId = entry.orderId, status = entry.status })
    end
    table.sort(saved, function(left, right) return left.orderId < right.orderId end)
    local file = fs.open(FOLLOWED_ORDERS_FILE, "w")
    if not file then return false end
    file.write(#saved == 0 and "[]" or textutils.serializeJSON(saved))
    file.close()
    return true
end

local function sendFollowControl(message)
    message.user = MARKET_USER
    local response, err = notifications.request(CONTROL_PROTOCOL, message, SERVER_NAME, TIMEOUT)
    if not response then return false, err end
    if response.type ~= "watch_order_ack" or response.success ~= true then
        return false, type(response.message) == "string"
            and response.message or "The order server did not confirm this notification subscription."
    end
    return true
end

local function registerFollowedOrders()
    local orderIds = {}
    for orderId in pairs(followedOrders) do
        table.insert(orderIds, orderId)
    end
    table.sort(orderIds)

    local failures = {}
    for _, orderId in ipairs(orderIds) do
        local registered, err = sendFollowControl({
            type = "watch_order",
            orderId = orderId,
        })
        if not registered then
            table.insert(failures, "#" .. tostring(orderId) .. ": " .. tostring(err))
        end
    end
    if #failures > 0 then
        showNotice("ORDER NOTIFICATIONS", "Could not activate follows: " .. table.concat(failures, "; "))
    end
end

local function saveKnownOrderStatus(order)
    local followed = followedOrders[order.id]
    if followed and followed.status ~= order.status then
        local previousStatus = followed.status
        followed.status = order.status
        if not saveFollowedOrders() then followed.status = previousStatus end
    end
end

local function promptFollowOrder(order)
    if type(order.customerId) ~= "number" or order.customerId ~= os.getComputerID() then
        return
    end
    local following = followedOrders[order.id] ~= nil
    drawHeader("ORDER NOTIFICATIONS", "FOLLOW STATUS CHANGES FOR THIS ORDER")
    writeAt(2, 5, "Order #" .. order.id .. " is " .. order.status:upper() .. ".", colors.white)
    writeAt(2, 6, following and "You are following this order." or "You are not following this order.", colors.lightGray)
    local choice = readChoice(following and "u unfollow|b back" or "f follow|b back")
    if choice == "f" and not following then
        followedOrders[order.id] = { orderId = order.id, status = order.status }
        if saveFollowedOrders() then
            local registered, registerError = sendFollowControl({
                type = "watch_order",
                orderId = order.id,
            })
            if registered then
                showNotice("FOLLOWING ORDER", "You will be notified when this order's status changes.")
            else
                showNotice("FOLLOW NOT ACTIVE", "The order was saved, but the server did not activate notifications: "
                    .. tostring(registerError))
            end
        else
            followedOrders[order.id] = nil
            showNotice("FOLLOW NOT SAVED", "Could not save your followed order.")
        end
    elseif choice == "u" and following then
        local savedEntry = followedOrders[order.id]
        followedOrders[order.id] = nil
        if saveFollowedOrders() then
            local unregistered, unregisterError = sendFollowControl({
                type = "unwatch_order",
                orderId = order.id,
            })
            if unregistered then
                showNotice("UNFOLLOWED ORDER", "Status notifications are disabled for this order.")
            else
                showNotice("UNFOLLOW SAVED", "Could not confirm notification removal: "
                    .. tostring(unregisterError))
            end
        else
            followedOrders[order.id] = savedEntry
            showNotice("UNFOLLOW NOT SAVED", "Could not save your followed orders.")
        end
    end
end

local function request(message)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then
        return nil, "Order server not found. Check that it is running and connected."
    end
    rednet.send(serverId, message, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, TIMEOUT)
    if type(response) ~= "table" then return nil, "No response from the order server." end
    if response.type == "error" then
        return nil, response.message or "The server rejected the request."
    end
    return response
end

local function money(cents)
    return string.format("$%.2f", cents / 100)
end

local function appendReceiptText(lines, text, width)
    text = tostring(text)
    for start = 1, #text, width do
        table.insert(lines, text:sub(start, start + width - 1))
    end
end

local function printOrderReceipt(order)
    local printer = peripheral.find("printer")
    if not printer then return nil end

    local ok, err = pcall(function()
        if printer.getPaperLevel() < 1 then error("The printer needs paper.") end
        if printer.getInkLevel() < 1 then error("The printer needs ink.") end
        if not printer.newPage() then error("The printer could not start a page; check paper and ink.") end

        local width, height = printer.getPageSize()
        local lines = {
            "ORDER RECEIPT #" .. order.id,
            "PAYMENT REF: " .. (order.reference or string.format("ORD-%06d", order.id)),
            "STATUS: " .. order.status:upper(),
            "PROVIDER PAYMENT ADDRESS",
        }
        appendReceiptText(lines, order.providerAddress or "NOT REGISTERED", width)
        table.insert(lines, "")
        table.insert(lines, "DELIVERY ADDRESS")
        appendReceiptText(lines, order.deliveryAddress or "ADDRESS NOT SAVED", width)
        table.insert(lines, "")
        table.insert(lines, "ITEMS")
        for _, item in ipairs(order.items) do
            appendReceiptText(lines, item.quantity .. " x " .. item.name
                .. "  " .. money(item.lineTotal), width)
        end
        table.insert(lines, "")
        appendReceiptText(lines, "TOTAL: " .. money(order.total), width)

        local lineIndex = 1
        while lineIndex <= #lines do
            printer.setPageTitle("Order " .. (order.reference or order.id))
            for row = 1, height do
                if lineIndex > #lines then break end
                printer.setCursorPos(1, row)
                printer.write(lines[lineIndex]:sub(1, width))
                lineIndex = lineIndex + 1
            end
            if not printer.endPage() then error("The printer could not finish the receipt page.") end
            if lineIndex <= #lines and not printer.newPage() then
                error("The printer could not start another page; check paper and ink.")
            end
        end
    end)
    return ok, err
end

local function fetchCatalog()
    local response, err = request({ type = "get_catalog" })
    if not response then return nil, err end
    return response.products or {}
end

local function findProduct(products, productId)
    for _, product in ipairs(products) do
        if product.id == productId then return product end
    end
end

local function cartCount(cart)
    local count = 0
    for _, quantity in pairs(cart) do count = count + quantity end
    return count
end

local function renderCatalog(products, cart, errorMessage, page)
    local visibleProducts = {}
    drawHeader("THE MARKET", "INDEPENDENT PROVIDERS  /  LIVE CATALOG")
    sectionTitle(4, "AVAILABLE PRODUCTS  |  " .. #products)
    if errorMessage then
        writeAt(2, 6, errorMessage, colors.red)
    elseif #products == 0 then
        writeAt(2, 6, "No products are listed yet.", colors.lightGray)
        writeAt(2, 7, "Check back after a provider publishes a product.", colors.lightGray)
    else
        local width, height = term.getSize()
        local perPage = math.max(1, math.floor((height - 8) / 2))
        local pageCount = math.max(1, math.ceil(#products / perPage))
        page = math.max(1, math.min(page, pageCount))
        local first = (page - 1) * perPage + 1
        local last = math.min(#products, first + perPage - 1)
        for index = first, last do
            local product = products[index]
            local y = 5 + (index - first) * 2
            table.insert(visibleProducts, { product = product, firstRow = y })
            writeAt(2, y, "#" .. product.id, colors.cyan)
            writeAt(8, y, product.name:sub(1, math.max(1, width - 20)), colors.white)
            writeAt(width - 9, y, money(product.price), colors.lime)
            writeAt(4, y + 1, "BY " .. product.providerName .. "  |  IN CART: "
                .. (cart[product.id] or 0), colors.lightGray)
        end
        writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
    end

    local help = "a add by ID|c cart " .. cartCount(cart)
        .. "|s track|n/v pages|r refresh|q quit"
    if not mouseEnabled then return readChoice(help), page end

    local buttons = drawChoices(help)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.key, page
                end
            end
            for _, entry in ipairs(visibleProducts) do
                if y >= entry.firstRow and y <= entry.firstRow + 1 then
                    return "product", page, entry.product
                end
            end
        end
    end
end

local addSelectedProduct

local function addToCart(products, cart)
    drawHeader("ADD TO CART", "ENTER A PRODUCT ID FROM THE MARKET")
    term.setCursorPos(2, 6)
    write("Product ID: ")
    local productId = tonumber(read())
    local product = productId and findProduct(products, productId)
    if not product then
        showNotice("PRODUCT NOT FOUND", "Refresh the market and choose an available product ID.")
        return
    end
    addSelectedProduct(products, product, cart)
end

addSelectedProduct = function(products, product, cart)
    for existingId in pairs(cart) do
        local existingProduct = findProduct(products, existingId)
        if existingProduct and existingProduct.providerId ~= product.providerId then
            showNotice("ONE PROVIDER PER ORDER", "Place separate orders for different providers.")
            return
        end
    end
    drawHeader("ADD TO CART", product.name .. "  /  " .. money(product.price))
    term.setCursorPos(2, 6)
    write("Quantity (1-99): ")
    local quantity = tonumber(read())
    local newQuantity = quantity and ((cart[product.id] or 0) + quantity)
    if not quantity or quantity % 1 ~= 0 or quantity < 1 or newQuantity > 99 then
        showNotice("INVALID QUANTITY", "Choose a whole-number quantity; each product is capped at 99.")
        return
    end
    cart[product.id] = newQuantity
    showNotice("ADDED TO CART", quantity .. "x " .. product.name .. " added.")
end

local function cartPage(products, cart)
    drawHeader("YOUR CART", "REVIEW ITEMS  /  SERVER PRICES ARE FINAL")
    sectionTitle(4, "ITEMS  |  " .. cartCount(cart))
    local width, height = term.getSize()
    local entries, total = {}, 0
    for productId, quantity in pairs(cart) do
        table.insert(entries, { id = productId, quantity = quantity })
    end
    table.sort(entries, function(a, b) return a.id < b.id end)
    local visible = math.min(#entries, math.max(0, height - 10))
    for index, entry in ipairs(entries) do
        local product = findProduct(products, entry.id)
        if product then total = total + entry.quantity * product.price end
        if index <= visible then
            local y = 5 + index
            if product then
                writeAt(2, y, entry.quantity .. "x " .. product.name, colors.white)
                writeAt(width - 9, y, money(entry.quantity * product.price), colors.lime)
            else
                writeAt(2, y, "#" .. entry.id .. " unavailable", colors.red)
            end
        end
    end
    if #entries == 0 then
        writeAt(2, 6, "Your cart is empty.", colors.lightGray)
    else
        writeAt(2, height - 4, "ESTIMATE  " .. money(total), colors.white, colors.blue)
        if visible < #entries then
            writeAt(2, height - 3, "Some items are below the visible area.", colors.yellow)
        end
    end
    return readChoice("p place order|d remove by ID|b back")
end

local function removeFromCart(cart)
    term.setCursorPos(2, 6)
    write("Product ID to remove: ")
    local productId = tonumber(read())
    if not productId or not cart[productId] then
        showNotice("ITEM NOT FOUND", "That product ID is not in your cart.")
        return
    end
    cart[productId] = nil
    showNotice("ITEM REMOVED", "Product removed from your cart.")
end

local function showOrder(order)
    drawHeader("ORDER #" .. order.id, "STATUS  /  " .. order.status:upper())
    sectionTitle(4, "ORDER SUMMARY")
    local width, height = term.getSize()
    writeAt(2, 5, "MAIL PAYMENT WITH REFERENCE: "
        .. (order.reference or string.format("ORD-%06d", order.id)), colors.cyan)
    local providerAddress = order.providerAddress or "Not registered"
    local providerLabel = "PAY PROVIDER: "
    local addressWidth = math.max(1, width - #providerLabel - 2)
    writeAt(2, 6, providerLabel .. providerAddress:sub(1, addressWidth), colors.lime)
    local row = 7
    for start = addressWidth + 1, #providerAddress, math.max(1, width - 2) do
        writeAt(2, row, providerAddress:sub(start, start + width - 3), colors.lime)
        row = row + 1
    end
    writeAt(2, row, "DELIVER TO  " .. (order.deliveryAddress or "Address not provided"), colors.yellow)
    row = row + 1
    local visible = math.min(#order.items, math.max(0, math.floor((height - 4 - row) / 2)))
    for index = 1, visible do
        local item = order.items[index]
        local y = row + (index - 1) * 2
        writeAt(2, y, item.quantity .. "x " .. item.name, colors.white)
        writeAt(2, y + 1, item.providerName or "Provider", colors.lightGray)
        writeAt(width - 9, y, money(item.lineTotal), colors.lime)
    end
    if visible < #order.items then
        writeAt(2, height - 3, "See the printed receipt for remaining items.", colors.yellow)
    end
    writeAt(2, height - 4, "TOTAL  " .. money(order.total), colors.white, colors.blue)
    if mouseEnabled then
        readChoice("b back")
    else
        writeAt(2, height - 1, "Press Enter to return.", colors.lightGray)
        read()
    end
end

local function placeOrder(cart)
    local items = {}
    for productId, quantity in pairs(cart) do
        table.insert(items, { productId = productId, quantity = quantity })
    end
    if #items == 0 then
        showNotice("CART IS EMPTY", "Add a product before placing an order.")
        return
    end

    drawHeader("DELIVERY ADDRESS", "ENTER THE ADDRESS FOR THIS ORDER")
    writeAt(2, 5, "Up to 100 characters.", colors.lightGray)
    term.setCursorPos(2, 7)
    write("Address: ")
    local deliveryAddress = read():match("^%s*(.-)%s*$")
    if #deliveryAddress < 1 or #deliveryAddress > 100 or deliveryAddress:find("%c") then
        showNotice("INVALID ADDRESS", "Enter a non-empty address up to 100 characters.")
        return
    end

    drawHeader("ORDER REVIEW", "CONFIRM THE DELIVERY ADDRESS BEFORE PLACING")
    sectionTitle(4, "DELIVER TO")
    local width, height = term.getSize()
    local lineWidth = math.max(1, width - 3)
    local row = 6
    for start = 1, #deliveryAddress, lineWidth do
        writeAt(2, row, deliveryAddress:sub(start, start + lineWidth - 1), colors.yellow)
        row = row + 1
    end
    writeAt(2, math.min(row + 1, height - 5), "Items in order: " .. #items, colors.lightGray)
    local confirmed
    if mouseEnabled then
        writeAt(2, height - 4, "Confirm order?", colors.lime)
        confirmed = readChoice("y yes|n no") == "y"
    else
        writeAt(2, height - 4, "Place this order? [y/N]", colors.lime)
        term.setCursorPos(2, height - 3)
        confirmed = read():lower() == "y"
    end
    if not confirmed then return end

    local response, err = request({
        type = "place_order",
        items = items,
        deliveryAddress = deliveryAddress,
    })
    if not response then
        showNotice("ORDER NOT PLACED", err)
        return
    end
    for productId in pairs(cart) do cart[productId] = nil end
    if not response.order or response.order.deliveryAddress ~= deliveryAddress then
        local orderId = response.order and response.order.id or "unknown"
        showNotice("SERVER NEEDS UPDATE", "Order #" .. orderId
            .. " was accepted, but the server did not save its address. Update and restart market-server.lua.")
        return
    end
    local printed, printError = printOrderReceipt(response.order)
    if printed == false then
        showNotice("ORDER SAVED, PRINT FAILED", tostring(printError))
    end
    showOrder(response.order)
    promptFollowOrder(response.order)
end

local function checkStatus()
    drawHeader("TRACK AN ORDER", "ENTER THE ORDER NUMBER FROM CHECKOUT")
    term.setCursorPos(2, 6)
    write("Order number: ")
    local orderId = tonumber(read())
    if not orderId or orderId % 1 ~= 0 or orderId < 1 then
        showNotice("INVALID ORDER", "Enter a valid order number.")
        return
    end
    local response, err = request({ type = "get_order", orderId = orderId })
    if not response then
        showNotice("ORDER NOT FOUND", err)
        return
    end
    if response.order.customerId == os.getComputerID() then
        saveKnownOrderStatus(response.order)
    end
    showOrder(response.order)
    promptFollowOrder(response.order)
    if response.order.status ~= "shipping" then return end

    drawHeader("DELIVERY CONFIRMATION", "ONLY CONFIRM AFTER THE ORDER ARRIVES")
    writeAt(2, 5, "Order " .. (response.order.reference or response.order.id) .. " has shipped.", colors.lightGray)
    local confirmCompletion
    if mouseEnabled then
        confirmCompletion = readChoice("y complete|n not yet") == "y"
    else
        writeAt(2, 7, "Mark this order completed? [y/N]", colors.lime)
        term.setCursorPos(2, 9)
        confirmCompletion = read():lower() == "y"
    end
    if not confirmCompletion then return end

    local completed, completionError = request({ type = "complete_order", orderId = orderId })
    if not completed then
        showNotice("ORDER NOT COMPLETED", completionError)
        return
    end
    showOrder(completed.order)
    saveKnownOrderStatus(completed.order)
    promptFollowOrder(completed.order)
end

openModems()
local listenerRegistered, listenerError = notifications.listen(
    NOTIFICATION_PROTOCOL, "title", "message", "Market", "source", "Market"
)
if not listenerRegistered then
    showNotice("ORDER NOTIFICATIONS", listenerError)
end
loadFollowedOrders()
registerFollowedOrders()
local cart = {}
local page = 1
while true do
    local products, err = fetchCatalog()
    local choice, shownPage, selectedProduct = renderCatalog(products or {}, cart, err, page)
    page = shownPage or page
    if choice == "a" then
        if products then addToCart(products, cart)
        else showNotice("MARKET UNAVAILABLE", err) end
    elseif choice == "product" then
        if products and selectedProduct then addSelectedProduct(products, selectedProduct, cart) end
    elseif choice == "c" then
        local cartChoice = cartPage(products or {}, cart)
        if cartChoice == "p" then
            placeOrder(cart)
        elseif cartChoice == "d" then
            removeFromCart(cart)
        end
    elseif choice == "s" then
        checkStatus()
    elseif choice == "n" then
        page = page + 1
    elseif choice == "v" then
        page = math.max(1, page - 1)
    elseif choice == "r" then
        page = 1
    elseif choice == "q" then
        break
    end
end
