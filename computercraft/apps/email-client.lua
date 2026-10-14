local PROTOCOL = "launcher_email_v1"
local NOTIFICATION_CONTROL_PROTOCOL = "launcher_email_notifications_v1"
local SERVER_NAME = "email_server"
local TIMEOUT = 5
local ACCOUNT_PATH = ".email-account.json"
local notifications = require("notifications")
local requestedHome = ...
local profileHome = type(requestedHome) == "string" and requestedHome:gsub("/+$", "")
local mouseEnabled = false
local account

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
    local _, height = term.getSize()
    local firstRow = 4
    local lastRow = height - 1
    for index, choice in ipairs(choices) do
        local row = firstRow + index - 1
        if row > lastRow then break end
        writeAt(2, row, ("[" .. index .. "] " .. choice.label), colors.white, colors.blue)
    end

    if not mouseEnabled then
        writeAt(2, height, "Choose an option by number and press Enter.", colors.lightGray)
        local selected = tonumber(read())
        return selected and choices[selected] and choices[selected].key
    end

    while true do
        local event, button, _, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            local index = y - firstRow + 1
            if index >= 1 and index <= #choices and index <= lastRow - firstRow + 1 then
                return choices[index].key
            end
        end
    end
end

local function notice(title, message)
    drawHeader(title, "EMAIL")
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
    clearScreen()
    writeAt(2, 2, label, colors.cyan)
    writeAt(2, 4, "> ", colors.lime)
    term.setCursorPos(4, 4)
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
    local file = fs.open(ACCOUNT_PATH, "w")
    if not file then return false, "Could not save account details in this profile." end
    file.write(textutils.serializeJSON(data))
    file.close()
    return true
end

local function loadAccount()
    if not fs.exists(ACCOUNT_PATH) then return nil end
    local file = fs.open(ACCOUNT_PATH, "r")
    if not file then error("Could not open the saved email account.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" or type(data.email) ~= "string" or type(data.password) ~= "string" then
        error("Saved email account data is invalid. Remove .email-account.json from your profile to sign in again.")
    end
    return data
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
    local pageSize = math.max(1, height - 7)
    local pageCount = math.max(1, math.ceil(#lines / pageSize))
    local page = 1

    while true do
        drawHeader("MESSAGE", account.email)
        local firstLine = (page - 1) * pageSize + 1
        for index = firstLine, math.min(#lines, firstLine + pageSize - 1) do
            writeAt(2, 4 + index - firstLine, lines[index], colors.white)
        end
        local buttons = {
            { key = "previous", label = "PREV" },
            { key = "next", label = "NEXT" },
            { key = "move", label = "MOVE" },
            { key = "delete", label = "DELETE" },
            { key = "back", label = "BACK" },
        }
        local slotWidth = math.max(1, math.floor(width / #buttons))
        for index, button in ipairs(buttons) do
            local left = (index - 1) * slotWidth + 1
            local right = index == #buttons and width or index * slotWidth
            writeAt(left, height, ("[ " .. button.label .. " ]"):sub(1, right - left + 1),
                colors.white, colors.blue)
        end

        if not mouseEnabled then
            writeAt(2, height - 1, "Page " .. page .. "/" .. pageCount .. " (P/N/M/D/B)", colors.lightGray)
            local action = read():lower()
            if action == "b" or action == "back" then return "back" end
            if action == "d" or action == "delete" then return "delete" end
            if action == "m" or action == "move" then return "move" end
            if action == "n" or action == "next" then page = math.min(pageCount, page + 1) end
            if action == "p" or action == "prev" then page = math.max(1, page - 1) end
        else
            while true do
                local event, button, x, y = os.pullEvent()
                if event == "mouse_click" and button == 1 and y == height then
                    local index = math.min(#buttons, math.floor((x - 1) / slotWidth) + 1)
                    if buttons[index].key == "previous" then
                        page = math.max(1, page - 1)
                        break
                    elseif buttons[index].key == "next" then
                        page = math.min(pageCount, page + 1)
                        break
                    elseif buttons[index].key == "delete" then
                        return "delete"
                    elseif buttons[index].key == "move" then
                        return "move"
                    elseif buttons[index].key == "back" then
                        return "back"
                    end
                end
            end
        end
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
    local pageSize = math.max(1, select(2, term.getSize()) - 7)
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
        local pageSize = math.max(1, select(2, term.getSize()) - 8)
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

    local page, pageSize = 1, math.max(1, select(2, term.getSize()) - 10)
    while true do
        local choices = {}
        local startIndex = (page - 1) * pageSize + 1
        local endIndex = math.min(#response.messages, startIndex + pageSize - 1)
        for index = startIndex, endIndex do
            local message = response.messages[index]
            table.insert(choices, {
                key = "message:" .. tostring(message.id),
                label = string.format("%s%s | %s", message.read and "" or "* ", message.from, message.subject),
            })
        end
        if #response.messages == 0 then
            table.insert(choices, { key = "empty", label = "No messages in this folder" })
        end
        if page > 1 then table.insert(choices, { key = "previous", label = "Previous page" }) end
        if endIndex < #response.messages then table.insert(choices, { key = "next", label = "Next page" }) end
        table.insert(choices, { key = "compose", label = "Compose" })
        table.insert(choices, { key = "folders", label = "Folders" })
        table.insert(choices, { key = "signout", label = "Sign out" })
        table.insert(choices, { key = "quit", label = "Quit" })

        local selected = choose("EMAIL  /  " .. category:upper(),
            account.email .. "  |  Page " .. page, choices)
        if selected == "compose" or selected == "signout" or selected == "quit" then
            return selected
        elseif selected == "folders" then
            return "folder", folders()
        elseif selected == "empty" or not selected then
            -- Keep the empty folder visible while the user chooses an action.
        elseif selected == "next" then
            page = page + 1
        elseif selected == "previous" then
            page = math.max(1, page - 1)
        else
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

local currentFolder = "Inbox"
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
                account = nil
                currentFolder = "Inbox"
                if fs.exists(ACCOUNT_PATH) then fs.delete(ACCOUNT_PATH) end
            elseif homeAction == "quit" then
                return
            end
        elseif action == "compose" then
            compose()
        elseif action == "signout" then
            account = nil
            currentFolder = "Inbox"
            if fs.exists(ACCOUNT_PATH) then fs.delete(ACCOUNT_PATH) end
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
