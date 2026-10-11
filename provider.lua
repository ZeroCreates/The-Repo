local PROTOCOL = "order_system_v1"
local SERVER_NAME = "order_server"
local TIMEOUT = 5
local STATUSES = { "preparing", "ready", "completed", "cancelled" }

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
    drawHeader(title, "PROVIDER CONSOLE  /  REDNET ORDER SYSTEM")
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
    if not found then error("Attach a modem before starting the provider page.") end
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

local function printReceipt(order)
    local printer = peripheral.find("printer")
    if not printer then return false, "No printer is attached to this provider computer." end

    local ok, err = pcall(function()
        if printer.getPaperLevel() < 1 then error("The printer needs paper.") end
        if printer.getInkLevel() < 1 then error("The printer needs ink.") end

        if not printer.newPage() then error("The printer could not start a page; check paper and ink.") end
        local width, height = printer.getPageSize()
        local lines = { "ORDER RECEIPT #" .. order.id, "STATUS: PREPARING", "", "DELIVERY ADDRESS" }
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
            printer.setPageTitle("Order #" .. order.id)
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

    if not ok then return false, tostring(err) end
    return true, "Receipt printed for order #" .. order.id .. "."
end

local function refreshOrders()
    local response, err = request({ type = "provider_list" })
    if not response then return nil, err end
    return response.orders or {}
end

local function refreshProducts()
    local response, err = request({ type = "get_provider_products" })
    if not response then return nil, err end
    return response.products or {}
end

local function showOrders(orders, page, errorMessage)
    drawHeader("PROVIDER CONSOLE", "LIVE ORDERS  /  REDNET ORDER SYSTEM")
    sectionTitle(4, "ACTIVE ORDERS  |  " .. #orders)
    if errorMessage then
        writeAt(2, 6, errorMessage, colors.red)
    elseif #orders == 0 then
        writeAt(2, 6, "No active orders right now.", colors.lightGray)
    else
        local _, height = term.getSize()
        local perPage = math.max(1, math.floor((height - 8) / 3))
        local pageCount = math.max(1, math.ceil(#orders / perPage))
        page = math.max(1, math.min(page, pageCount))
        local first = (page - 1) * perPage + 1
        local last = math.min(#orders, first + perPage - 1)
        for index = first, last do
            local order = orders[index]
            local y = 5 + (index - first) * 3
            local statusColor = order.status == "ready" and colors.lime
                or (order.status == "preparing" and colors.orange or colors.yellow)
            writeAt(2, y, "#" .. order.id, colors.cyan)
            writeAt(8, y, order.status:upper(), statusColor)
            writeAt(22, y, money(order.total), colors.white)
            local summary = {}
            for _, item in ipairs(order.items) do
                table.insert(summary, item.quantity .. "x " .. item.name)
            end
            writeAt(2, y + 1, table.concat(summary, ", "), colors.lightGray)
            writeAt(2, y + 2, "DELIVER TO: " .. (order.deliveryAddress or "ADDRESS NOT SET"), colors.yellow)
        end
        writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
    end
    return readChoice("p products  |  u update status  |  n/v pages  |  r refresh  |  q quit"), page
    return readChoice("p products  |  d delivery details  |  u status  |  n/v pages  |  r refresh  |  q quit"), page
end

local function showDeliveryDetails(orders)
    drawHeader("DELIVERY DETAILS", "LOOK UP AN ACTIVE ORDER BY NUMBER")
    term.setCursorPos(2, 6)
    write("Order number: ")
    local orderId = tonumber(read())
    local order
    for _, candidate in ipairs(orders) do
        if candidate.id == orderId then
            order = candidate
            break
        end
    end
    if not order then
        showNotice("ORDER NOT FOUND", "Refresh the provider order list and try again.")
        return
    end

    drawHeader("ORDER #" .. order.id, "STATUS  /  " .. order.status:upper())
    sectionTitle(4, "DELIVERY ADDRESS")
    local width, height = term.getSize()
    local address = order.deliveryAddress or "No address was saved. Update and restart server.lua."
    local lineWidth = math.max(1, width - 3)
    local row = 6
    for start = 1, #address, lineWidth do
        writeAt(2, row, address:sub(start, start + lineWidth - 1), colors.yellow)
        row = row + 1
        if row >= height - 4 then break end
    end
    writeAt(2, height - 1, "Press Enter to return.", colors.lightGray)
    read()
end

local function productPage(products, page, errorMessage)
    drawHeader("MY PRODUCTS", "PUBLISHED LISTINGS  /  MANAGED BY THIS PROVIDER")
    sectionTitle(4, "YOUR CATALOG  |  " .. #products)
    if errorMessage then
        writeAt(2, 6, errorMessage, colors.red)
    elseif #products == 0 then
        writeAt(2, 6, "No products published yet.", colors.lightGray)
    else
        local width, height = term.getSize()
        local perPage = math.max(1, height - 8)
        local pageCount = math.max(1, math.ceil(#products / perPage))
        page = math.max(1, math.min(page, pageCount))
        local first = (page - 1) * perPage + 1
        local last = math.min(#products, first + perPage - 1)
        for index = first, last do
            local product = products[index]
            local y = 5 + index - first
            writeAt(2, y, "#" .. product.id, colors.cyan)
            writeAt(8, y, product.name:sub(1, math.max(1, width - 23)), colors.white)
            writeAt(width - 14, y, money(product.price), colors.yellow)
            writeAt(width - 6, y, product.available and "ON" or "OFF",
                product.available and colors.lime or colors.gray)
        end
        writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
    end
    return readChoice("a add  |  e edit  |  t toggle  |  n/v pages  |  b back"), page
end

local function publishProduct(product)
    local providerName = os.getComputerLabel and os.getComputerLabel()
    if not providerName or providerName == "" then
        providerName = "Provider #" .. os.getComputerID()
    end
    product.providerName = providerName
    local response, err = request({ type = "publish_product", product = product })
    if not response then
        showNotice("PRODUCT NOT SAVED", err)
        return false
    end
    showNotice("PRODUCT SAVED", response.product.name .. " is now on the server catalog.")
    return true
end

local function addProduct()
    drawHeader("NEW PRODUCT", "PUBLISH A LISTING TO THE SHARED CATALOG")
    writeAt(2, 5, "Product names can be up to 32 characters.", colors.lightGray)
    term.setCursorPos(2, 7)
    write("Name: ")
    local name = read()
    if name == "" then return end
    term.setCursorPos(2, 9)
    write("Price in dollars: $")
    local price = tonumber(read())
    if not price or price <= 0 or price > 10000 then
        showNotice("INVALID PRICE", "Enter a price greater than $0 and no more than $10000.")
        return
    end
    publishProduct({ name = name, price = math.floor(price * 100 + 0.5), available = true })
end

local function findProduct(products, productId)
    for _, product in ipairs(products) do
        if product.id == productId then return product end
    end
end

local function editProduct(products)
    local _, height = term.getSize()
    term.setCursorPos(2, height - 1)
    write("Product ID to edit: ")
    local productId = tonumber(read())
    local product = productId and findProduct(products, productId)
    if not product then
        showNotice("PRODUCT NOT FOUND", "Choose one of your product IDs from the catalog.")
        return
    end
    drawHeader("EDIT PRODUCT #" .. product.id, "Leave a field blank to keep it unchanged.")
    term.setCursorPos(2, 6)
    write("Name [" .. product.name .. "]: ")
    local name = read()
    term.setCursorPos(2, 8)
    write("Price [$" .. string.format("%.2f", product.price / 100) .. "]: $")
    local priceInput = read()
    local price = priceInput == "" and product.price or tonumber(priceInput)
    if not price or price <= 0 or price > 10000 then
        showNotice("INVALID PRICE", "Enter a price greater than $0 and no more than $10000.")
        return
    end
    publishProduct({
        id = product.id,
        name = name == "" and product.name or name,
        price = math.floor(price * 100 + 0.5),
        available = product.available,
    })
end

local function toggleProduct(products)
    local _, height = term.getSize()
    term.setCursorPos(2, height - 1)
    write("Product ID to show/hide: ")
    local productId = tonumber(read())
    local product = productId and findProduct(products, productId)
    if not product then
        showNotice("PRODUCT NOT FOUND", "Choose one of your product IDs from the catalog.")
        return
    end
    publishProduct({
        id = product.id,
        name = product.name,
        price = product.price,
        available = not product.available,
    })
end

local function updateStatus()
    drawHeader("UPDATE ORDER", "STATUS CHANGES ARE VALIDATED BY THE SERVER")
    writeAt(2, 5, "Order number:", colors.white)
    term.setCursorPos(2, 6)
    local orderId = tonumber(read())
    if not orderId or orderId % 1 ~= 0 or orderId < 1 then
        showNotice("INVALID ORDER", "Enter a valid order number.")
        return
    end
    writeAt(2, 8, "New: preparing / ready / completed / cancelled", colors.lightGray)
    term.setCursorPos(2, 10)
    local status = read():lower()
    if status == "q" then return end
    local valid = false
    for _, allowed in ipairs(STATUSES) do
        if status == allowed then valid = true break end
    end
    if not valid then
        showNotice("UNKNOWN STATUS", "Choose a listed status.")
        return
    end
    local response, err = request({ type = "set_status", orderId = orderId, status = status })
    if not response then
        showNotice("UPDATE REJECTED", err)
        return
    end
    if response.order.status == "preparing" then
        local printed, printMessage = printReceipt(response.order)
        showNotice(printed and "RECEIPT PRINTED" or "STATUS UPDATED, NO RECEIPT", printMessage)
    else
        showNotice("STATUS UPDATED", "Order #" .. response.order.id .. " is now " .. response.order.status .. ".")
    end
end

openModems()
local orderPage = 1
while true do
    local orders, err = refreshOrders()
    local choice, shownOrderPage = showOrders(orders or {}, orderPage, err)
    orderPage = shownOrderPage or orderPage
    if choice == "u" then
        updateStatus()
    elseif choice == "d" then
        showDeliveryDetails(orders or {})
    elseif choice == "p" then
        local products, productError = refreshProducts()
        local productPageNumber = 1
        while true do
            local productChoice, shownProductPage = productPage(products or {}, productPageNumber, productError)
            productPageNumber = shownProductPage or productPageNumber
            if productChoice == "a" then
                addProduct()
                products, productError = refreshProducts()
            elseif productChoice == "e" then
                if products then editProduct(products) end
                products, productError = refreshProducts()
            elseif productChoice == "t" then
                if products then toggleProduct(products) end
                products, productError = refreshProducts()
            elseif productChoice == "n" then
                productPageNumber = productPageNumber + 1
            elseif productChoice == "v" then
                productPageNumber = math.max(1, productPageNumber - 1)
            elseif productChoice == "b" or productChoice == "q" then
                break
            end
        end
    elseif choice == "n" then
        orderPage = orderPage + 1
    elseif choice == "v" then
        orderPage = math.max(1, orderPage - 1)
    elseif choice == "r" then
        orderPage = 1
    elseif choice == "q" then
        break
    end
end
