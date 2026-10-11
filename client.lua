local PROTOCOL = "order_system_v1"
local SERVER_NAME = "order_server"
local TIMEOUT = 5

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

local function readChoice(help)
    local _, height = term.getSize()
    writeAt(2, height - 2, help, colors.lightGray)
    writeAt(2, height - 1, "> ", colors.lime)
    term.setCursorPos(4, height - 1)
    return read():lower()
end

local function showNotice(title, message)
    drawHeader(title, "ORDER DESK  /  SHARED PRODUCT CATALOG")
    writeAt(2, 5, message, colors.white)
    writeAt(2, 7, "Press Enter to continue.", colors.lightGray)
    read()
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
            writeAt(2, y, "#" .. product.id, colors.cyan)
            writeAt(8, y, product.name:sub(1, math.max(1, width - 20)), colors.white)
            writeAt(width - 9, y, money(product.price), colors.lime)
            writeAt(4, y + 1, "BY " .. product.providerName .. "  |  IN CART: "
                .. (cart[product.id] or 0), colors.lightGray)
        end
        writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
    end
    return readChoice("a add by ID  |  c cart " .. cartCount(cart)
        .. "  |  s track  |  n/v pages  |  r refresh  |  q quit"), page
end

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
    for existingId in pairs(cart) do
        local existingProduct = findProduct(products, existingId)
        if existingProduct and existingProduct.providerId ~= product.providerId then
            showNotice("ONE PROVIDER PER ORDER", "Place separate orders for different providers.")
            return
        end
    end
    term.setCursorPos(2, 8)
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
        if product then
            total = total + entry.quantity * product.price
        end
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
    return readChoice("p place order  |  d remove by ID  |  b back")
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
    local visible = math.min(#order.items, math.max(0, height - 11))
    for index = 1, visible do
        local item = order.items[index]
        local y = 5 + index
        writeAt(2, y, item.quantity .. "x " .. item.name, colors.white)
        writeAt(2, y + 1, item.providerName or "Provider", colors.lightGray)
        writeAt(width - 9, y, money(item.lineTotal), colors.lime)
    end
    writeAt(2, height - 4, "TOTAL  " .. money(order.total), colors.white, colors.blue)
    writeAt(2, height - 1, "Press Enter to return.", colors.lightGray)
    read()
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
    local response, err = request({ type = "place_order", items = items })
    if not response then
        showNotice("ORDER NOT PLACED", err)
        return
    end
    for productId in pairs(cart) do cart[productId] = nil end
    showOrder(response.order)
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
    showOrder(response.order)
end

openModems()
local cart = {}
local page = 1
while true do
    local products, err = fetchCatalog()
    local choice, shownPage = renderCatalog(products or {}, cart, err, page)
    page = shownPage or page
    if choice == "a" then
        if products then addToCart(products, cart)
        else showNotice("MARKET UNAVAILABLE", err) end
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
