local PROTOCOL = "launcher_email_v1"
local NOTIFICATION_CONTROL_PROTOCOL = "launcher_email_notifications_v1"
local SERVER_NAME = "email_server"
local TIMEOUT = 5
local ACCOUNT_PATH = ".email-account.json"
local STORED_ACCOUNT_PATH = "email/account.json"
local notifications = require("notifications")
local storageLoaded, storage = pcall(require, "storage")
if not storageLoaded or type(storage) ~= "table"
    or type(storage.read) ~= "function" or type(storage.write) ~= "function"
    or type(storage.delete) ~= "function" then
    storage = nil
end
local requestedHome = ...
local profileHome = type(requestedHome) == "string" and requestedHome:gsub("/+$", "")
local mouseEnabled = false
local account
local currentFolder = "Inbox"

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
    writeAt(2, 2, subtitle or "", colors.lightGray)
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

    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local row = height - rows + math.floor((index - 1) / columns)
        local column = (index - 1) % columns
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        writeAt(left, row, ("[" .. option.label .. "]"):sub(1, right - left + 1),
            colors.black, colors.lightBlue)
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

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the email client.") end
    mouseEnabled = term.isColor()
end

local function request(payload)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then
        return nil, "Email server not found. Check that it is running and connected."
    end
    rednet.send(serverId, payload, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, TIMEOUT, serverId)
    if type(response) ~= "table" then return nil, "No response from the email server." end
    if response.type == "error" then
        return nil, response.message or "The email server rejected the request."
    end
    return response
end

local function subscribeForNotifications()
    if not account then return false, "Sign in to enable email notifications." end
    local response, err = notifications.request(NOTIFICATION_CONTROL_PROTOCOL, {
        type = "subscribe",
        email = account.email,
        password = account.password,
    }, SERVER_NAME, TIMEOUT)
    if not response then return false, err end
    if response.type ~= "subscribed" then return false, "Email server did not confirm the notification subscription." end
    return true
end

local function choose(title, subtitle, choices)
    drawHeader(title, subtitle)
    local width, height = term.getSize()
    sectionTitle(4, "SELECT AN OPTION")
    local firstRow = 5
    local lastRow = height - 2
    for index, choice in ipairs(choices) do
        local row = firstRow + index - 1
        if row > lastRow then break end
        local background = index % 2 == 0 and colors.gray or colors.black
        writeAt(2, row, string.rep(" ", math.max(0, width - 2)), colors.white, background)
        writeAt(3, row, choice.label, colors.white, background)
    end

    if not mouseEnabled then
        writeAt(2, height - 1, "Choose an option by number and press Enter.", colors.lightGray)
        local selected = tonumber(read())
        return selected and choices[selected] and choices[selected].key
    end

    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 and x >= 2 then
            local index = y - firstRow + 1
            if index >= 1 and index <= #choices and y <= lastRow then
                return choices[index].key
            end
        end
    end
end

local function notice(title, message)
    drawHeader(title, "RIFTMAIL  /  EMAIL CLIENT")
    sectionTitle(4, "NOTICE")
    local width = term.getSize()
    local row = 5
    for line in (tostring(message) .. "\n"):gmatch("(.-)\n") do
        writeAt(2, row, line, colors.white)
        row = row + 1
    end
    local _, height = term.getSize()
    writeAt(2, height - 1, "[ OK ]", colors.white, colors.blue)
    if mouseEnabled then
        while true do
            local event, button, x, y = os.pullEvent()
            if event == "mouse_click" and button == 1 and y == height - 1 and x >= 2 and x <= math.min(width, 7) then
                return
            end
        end
    end
    read()
end

local function readField(label, secret)
    drawHeader("RIFTMAIL", "EMAIL CLIENT  /  ACCOUNT")
    sectionTitle(4, "INPUT")
    writeAt(2, 6, label, colors.white)
    writeAt(2, 8, "> ", colors.lime)
    term.setCursorPos(4, 8)
    return read(secret and "*" or nil)
end

local function completeEmailAddress(value)
    local email = value:lower():match("^%s*(.-)%s*$")
    if not email:find("@", 1, true) then
        email = email .. "@riftmail.com"
    end
    return email
end

local function saveAccount(data)
    if storage then
        local saved, saveError = storage.write(STORED_ACCOUNT_PATH, data)
        if not saved then
            return false, "Could not save account details to private storage: "
                .. tostring(saveError or "unknown storage error")
        end
        if fs.exists(ACCOUNT_PATH) then
            local ok, deleteError = pcall(fs.delete, ACCOUNT_PATH)
            if not ok then
                return false, "Account was saved to private storage, but the old profile copy could not be removed: "
                    .. tostring(deleteError)
            end
        end
        return true
    end

    local file = fs.open(ACCOUNT_PATH, "w")
    if not file then return false, "Could not save account details in this profile." end
    file.write(textutils.serializeJSON(data))
    file.close()
    return true
end

local function isValidAccount(data)
    return type(data) == "table" and type(data.email) == "string"
        and type(data.password) == "string"
end

local function loadLegacyAccount()
    if not fs.exists(ACCOUNT_PATH) then return nil end
    local file = fs.open(ACCOUNT_PATH, "r")
    if not file then error("Could not open the saved email account.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or not isValidAccount(data) then
        error("Saved email account data is invalid. Remove .email-account.json from your profile to sign in again.")
    end
    return data
end

local function loadAccount()
    if storage then
        local data, storageError = storage.read(STORED_ACCOUNT_PATH)
        if data ~= nil then
            if not isValidAccount(data) then
                error("Saved email account data in private storage is invalid.")
            end
            return data
        end
        if storageError and storageError ~= "Stored data was not found." then
            error("Could not load the saved email account from private storage: " .. storageError)
        end
    end

    local legacyAccount = loadLegacyAccount()
    if legacyAccount and storage then
        local saved, saveError = storage.write(STORED_ACCOUNT_PATH, legacyAccount)
        if not saved then
            notice("ACCOUNT STORAGE", "Using the existing profile copy. Could not migrate it to private storage: "
                .. tostring(saveError or "unknown storage error"))
        else
            local deleted, deleteError = pcall(fs.delete, ACCOUNT_PATH)
            if not deleted then
                notice("ACCOUNT STORAGE", "Account moved to private storage, but the old profile copy remains: "
                    .. tostring(deleteError))
            end
        end
    end
    return legacyAccount
end

local function deleteSavedAccount()
    if storage then
        local deleted, deleteError = storage.delete(STORED_ACCOUNT_PATH)
        if not deleted and deleteError ~= "Stored data was not found." then
            return false, "Could not remove account details from private storage: "
                .. tostring(deleteError or "unknown storage error")
        end
    end
    if fs.exists(ACCOUNT_PATH) then
        local deleted, deleteError = pcall(fs.delete, ACCOUNT_PATH)
        if not deleted then
            return false, "Could not remove account details from this profile: " .. tostring(deleteError)
        end
    end
    return true
end

local function signOut()
    local deleted, deleteError = deleteSavedAccount()
    if not deleted then
        notice("SIGN OUT", deleteError)
        return false
    end
    account = nil
    currentFolder = "Inbox"
    return true
end

local function formatTime(timestamp)
    if os.date then return os.date("%Y-%m-%d %H:%M", math.floor(timestamp / 1000)) end
    return tostring(timestamp)
end

local function appendWrapped(lines, text, lineWidth)
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "")
        else
            while #paragraph > lineWidth do
                local segment = paragraph:sub(1, lineWidth)
                local breakAt = segment:match(".*()%s+")
                if breakAt and breakAt > 1 then
                    table.insert(lines, segment:sub(1, breakAt - 1))
                    paragraph = paragraph:sub(breakAt + 1)
                else
                    table.insert(lines, segment)
                    paragraph = paragraph:sub(lineWidth + 1)
                end
            end
            table.insert(lines, paragraph)
        end
    end
end

local function displayMessage(item)
    local width, height = term.getSize()
    local lines = {
        "From: " .. item.from,
        "Date: " .. formatTime(item.sentAt),
        "Subject: " .. item.subject,
        "",
    }
    appendWrapped(lines, item.body, math.max(1, width - 4))
    local pageSize = math.max(1, height - 9)
    local pageCount = math.max(1, math.ceil(#lines / pageSize))
    local page = 1

    while true do
        drawHeader("RIFTMAIL", account.email)
        sectionTitle(4, "MESSAGE  |  " .. item.subject)
        local firstLine = (page - 1) * pageSize + 1
        for index = firstLine, math.min(#lines, firstLine + pageSize - 1) do
            writeAt(2, 5 + index - firstLine, lines[index], colors.white)
        end
        writeAt(2, height - 4, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
        local action = readChoice("p prev|n next|m move|d delete|b back")
        if action == "b" then return "back" end
        if action == "d" then return "delete" end
        if action == "m" then return "move" end
        if action == "n" then page = math.min(pageCount, page + 1) end
        if action == "p" then page = math.max(1, page - 1) end
    end
end

local function fetchCategories()
    local response, err = request({
        type = "list_categories",
        email = account.email,
        password = account.password,
    })
    if not response then return nil, err end
    if type(response.categories) ~= "table" then
        return nil, "The email server returned invalid categories."
    end
    return response.categories
end

local function chooseFolder(categories, title)
    local pageSize = math.max(1, select(2, term.getSize()) - 10)
    local page, pageCount = 1, math.max(1, math.ceil(#categories / pageSize))
    while true do
        local choices = {}
        local first = (page - 1) * pageSize + 1
        local last = math.min(#categories, first + pageSize - 1)
        for index = first, last do
            table.insert(choices, { key = "category:" .. categories[index], label = categories[index] })
        end
        if page > 1 then table.insert(choices, { key = "previous", label = "Previous page" }) end
        if page < pageCount then table.insert(choices, { key = "next", label = "Next page" }) end
        table.insert(choices, { key = "back", label = "Back" })
        local selected = choose(title, "Choose a folder", choices)
        if selected == "back" or not selected then return nil end
        if selected == "next" then
            page = math.min(pageCount, page + 1)
        elseif selected == "previous" then
            page = math.max(1, page - 1)
        else
            return selected:match("^category:(.+)$")
        end
    end
end

local function folders()
    local page = 1
    while true do
        local categories, err = fetchCategories()
        if not categories then notice("FOLDERS", err); return nil end
        local pageSize = math.max(1, select(2, term.getSize()) - 11)
        local pageCount = math.max(1, math.ceil(#categories / pageSize))
        page = math.min(page, pageCount)
        local choices = {}
        local first = (page - 1) * pageSize + 1
        local last = math.min(#categories, first + pageSize - 1)
        for index = first, last do
            table.insert(choices, {
                key = "category:" .. categories[index],
                label = "Open " .. categories[index],
            })
        end
        if page > 1 then table.insert(choices, { key = "previous", label = "Previous page" }) end
        if page < pageCount then table.insert(choices, { key = "next", label = "Next page" }) end
        table.insert(choices, { key = "create", label = "Create category" })
        table.insert(choices, { key = "back", label = "Back" })
        local selected = choose("EMAIL FOLDERS", account.email, choices)
        if selected == "back" or not selected then return nil end
        if selected == "create" then
            local name = readField("New category name (up to 24 characters):")
            name = name:match("^%s*(.-)%s*$")
            local created, createError = request({
                type = "create_category",
                email = account.email,
                password = account.password,
                category = name,
            })
            if not created then
                notice("CREATE CATEGORY", createError)
            else
                notice("CREATE CATEGORY", "Created " .. created.category .. ".")
            end
        elseif selected == "next" then
            page = math.min(pageCount, page + 1)
        elseif selected == "previous" then
            page = math.max(1, page - 1)
        else
            return selected:match("^category:(.+)$")
        end
    end
end

local function inbox(category)
    local response, err = request({
        type = "list",
        email = account.email,
        password = account.password,
        category = category,
    })
    if not response then notice("INBOX", err); return "home" end
    if type(response.messages) ~= "table" then
        notice("INBOX", "The email server returned an invalid inbox.")
        return "home"
    end

    local _, height = term.getSize()
    local page, pageSize = 1, math.max(1, math.floor((height - 9) / 2))
    while true do
        local startIndex = (page - 1) * pageSize + 1
        local endIndex = math.min(#response.messages, startIndex + pageSize - 1)

        drawHeader("RIFTMAIL", account.email .. "  /  EMAIL CLIENT")
        sectionTitle(4, category:upper() .. "  |  " .. #response.messages .. " MESSAGES")
        if #response.messages == 0 then
            writeAt(2, 6, "No messages in this folder.", colors.lightGray)
        else
            for index = startIndex, endIndex do
                local message = response.messages[index]
                local y = 5 + (index - startIndex) * 2
                local unreadMark = message.read and "" or "* "
                writeAt(2, y, string.format("%02d  %s%s | %s",
                    index - startIndex + 1, unreadMark, message.from, message.subject),
                    message.read and colors.white or colors.lime)
                writeAt(4, y + 1, message.read and "READ" or "UNREAD", colors.lightGray)
            end
        end
        local pageCount = math.max(1, math.ceil(#response.messages / pageSize))
        writeAt(2, height - 4, "PAGE " .. page .. " / " .. pageCount, colors.yellow)
        local help = (page > 1 and "p prev|" or "")
            .. (endIndex < #response.messages and "n next|" or "")
            .. "i inbox|c compose|f folders|s sign out|q quit"
        local selected
        if mouseEnabled then
            local buttons = drawChoices(help)
            while true do
                local event, button, x, y = os.pullEvent()
                if event == "mouse_click" and button == 1 then
                    for _, choice in ipairs(buttons) do
                        if y == choice.row and x >= choice.left and x <= choice.right then
                            selected = choice.key
                            break
                        end
                    end
                    if selected then break end
                    if y >= 5 and y < height - 4 and #response.messages > 0 then
                        local visibleIndex = math.floor((y - 5) / 2) + 1
                        local messageIndex = startIndex + visibleIndex - 1
                        local message = response.messages[messageIndex]
                        if message then
                            selected = "message:" .. tostring(message.id)
                            break
                        end
                    end
                end
            end
        else
            writeAt(2, height - 2, help, colors.lightGray)
            writeAt(2, height - 1, "Message number or action: ", colors.lime)
            selected = read():lower()
            local choice = tonumber(selected)
            if choice then
                local message = response.messages[startIndex + choice - 1]
                if message and startIndex + choice - 1 <= endIndex then
                    selected = "message:" .. tostring(message.id)
                end
            end
        end
        if selected == "c" then return "compose" end
        if selected == "f" then return "folder", folders() end
        if selected == "i" then return "folder", "Inbox" end
        if selected == "s" then return "signout" end
        if selected == "q" then return "quit" end
        if selected == "p" then page = math.max(1, page - 1) end
        if selected == "n" then page = math.min(pageCount, page + 1) end

        if type(selected) == "string" then
            local id = tonumber(selected:match("^message:(.+)$"))
            if id then
                local full, readError = request({
                    type = "read",
                    email = account.email,
                    password = account.password,
                    id = id,
                })
                if not full then
                    notice("MESSAGE", readError)
                elseif type(full.message) ~= "table" then
                    notice("MESSAGE", "The email server returned an invalid message.")
                else
                    local item = full.message
                    local messageAction = displayMessage(item)
                    for _, inboxMessage in ipairs(response.messages) do
                        if inboxMessage.id == id then inboxMessage.read = true; break end
                    end
                    if messageAction == "delete" then
                        local confirmation = choose("DELETE MESSAGE",
                            "Delete this message permanently?",
                            {
                                { key = "yes", label = "Delete" },
                                { key = "no", label = "Cancel" },
                            })
                        if confirmation == "yes" then
                            local deleted, deleteError = request({
                                type = "delete",
                                email = account.email,
                                password = account.password,
                                id = id,
                            })
                            if not deleted then
                                notice("DELETE FAILED", deleteError)
                            else
                                for index, inboxMessage in ipairs(response.messages) do
                                    if inboxMessage.id == id then
                                        table.remove(response.messages, index)
                                        break
                                    end
                                end
                                page = math.max(1, math.ceil(#response.messages / pageSize))
                                notice("MESSAGE DELETED", "The email was permanently deleted.")
                            end
                        end
                    elseif messageAction == "move" then
                        local categories, categoryError = fetchCategories()
                        if not categories then
                            notice("MOVE MESSAGE", categoryError)
                        else
                            local destination = chooseFolder(categories, "MOVE MESSAGE")
                            if destination then
                                local moved, moveError = request({
                                    type = "move",
                                    email = account.email,
                                    password = account.password,
                                    id = id,
                                    category = destination,
                                })
                                if not moved then
                                    notice("MOVE MESSAGE", moveError)
                                else
                                    for index, inboxMessage in ipairs(response.messages) do
                                        if inboxMessage.id == id and destination ~= category then
                                            table.remove(response.messages, index)
                                            break
                                        end
                                    end
                                    page = math.max(1, math.ceil(#response.messages / pageSize))
                                    notice("MESSAGE MOVED", "Moved to " .. destination .. ".")
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function compose()
    local recipient = completeEmailAddress(readField("Recipient email (or username for @riftmail.com):"))
    local subject = readField("Subject:")
    if #subject < 1 or #subject > 80 then
        notice("COMPOSE", "Subject must be 1 to 80 characters.")
        return
    end
    local bodyLines = {}
    local bodyLength = 0
    while bodyLength <= 2000 do
        local line = readField("Message body ('.' on a line sends):")
        if line == "." then break end
        bodyLength = bodyLength + #line + (#bodyLines > 0 and 1 or 0)
        if bodyLength <= 2000 then table.insert(bodyLines, line) end
    end
    local body = table.concat(bodyLines, "\n")
    if #body < 1 or #body > 2000 or bodyLength > 2000 then
        notice("COMPOSE", "Message body must be 1 to 2000 characters.")
        return
    end
    local response, err = request({
        type = "send",
        email = account.email,
        password = account.password,
        to = recipient,
        subject = subject,
        body = body,
    })
    if response then
        notice("COMPOSE", "Message sent to " .. recipient .. ".")
    else
        notice("COMPOSE", err)
    end
end

local function createAccount()
    local email = completeEmailAddress(readField("Choose email (or username for @riftmail.com):"))
    local password = readField("Choose a password:", true)
    local confirmation = readField("Confirm password:", true)
    if password ~= confirmation then
        notice("CREATE ACCOUNT", "The passwords do not match.")
        return
    end
    local response, err = request({
        type = "register",
        email = email,
        password = password,
    })
    if not response then
        notice("CREATE ACCOUNT", err)
        return
    end
    account = { email = response.email, password = password }
    local saved, saveError = saveAccount(account)
    if not saved then
        notice("CREATE ACCOUNT", saveError)
        return
    end
    local subscribed, subscriptionError = subscribeForNotifications()
    notice("CREATE ACCOUNT", subscribed
        and ("Account created: " .. account.email .. "\nEmail notifications enabled.")
        or ("Account created: " .. account.email .. "\n" .. subscriptionError))
end

local function signIn()
    local email = completeEmailAddress(readField("Email (or username for @riftmail.com):"))
    local password = readField("Password:", true)
    local response, err = request({
        type = "login",
        email = email,
        password = password,
    })
    if not response then
        notice("SIGN IN", err)
        return
    end
    account = { email = response.email, password = password }
    local saved, saveError = saveAccount(account)
    if not saved then
        notice("SIGN IN", saveError)
        return
    end
    local subscribed, subscriptionError = subscribeForNotifications()
    if not subscribed then notice("EMAIL NOTIFICATIONS", subscriptionError) end
end

if not profileHome then error("Could not determine the launcher profile home.") end
openModems()
account = loadAccount()
if account then
    local subscribed, subscriptionError = subscribeForNotifications()
    if not subscribed then notice("EMAIL NOTIFICATIONS", subscriptionError) end
end

while true do
    if account then
        local action, selectedFolder = inbox(currentFolder)
        if action == "folder" then
            if selectedFolder then currentFolder = selectedFolder end
        elseif action == "home" then
            local homeAction = choose("EMAIL", account.email, {
                { key = "inbox", label = "Inbox" },
                { key = "folders", label = "Folders" },
                { key = "compose", label = "Compose" },
                { key = "signout", label = "Sign out" },
                { key = "quit", label = "Quit" },
            })
            if homeAction == "inbox" then
                currentFolder = "Inbox"
            elseif homeAction == "folders" then
                currentFolder = folders() or "Inbox"
            elseif homeAction == "compose" then
                compose()
            elseif homeAction == "signout" then
                signOut()
            elseif homeAction == "quit" then
                return
            end
        elseif action == "compose" then
            compose()
        elseif action == "signout" then
            signOut()
        elseif action == "quit" then
            return
        end
    else
        local action = choose("EMAIL", "Create or sign in to an email account", {
            { key = "create", label = "Create account" },
            { key = "login", label = "Sign in" },
            { key = "quit", label = "Quit" },
        })
        if action == "create" then
            createAccount()
        elseif action == "login" then
            signIn()
        elseif action == "quit" then
            return
        end
    end
end
