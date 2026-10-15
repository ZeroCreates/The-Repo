local PROTOCOL = "launcher_email_v1"
local NOTIFICATION_CONTROL_PROTOCOL = "launcher_email_notifications_v1"
local NOTIFICATION_PROTOCOL = "launcher_notifications_v1"
local SERVER_NAME = "email_server"
local DATA_DIRECTORY = "/email-server"
local MAILBOX_PATH = DATA_DIRECTORY .. "/mailboxes.json"
local ACCOUNT_PATH = DATA_DIRECTORY .. "/accounts.json"
local CATEGORY_PATH = DATA_DIRECTORY .. "/categories.json"
local DOMAIN_ALLOWLIST_PATH = DATA_DIRECTORY .. "/domain-allowlist.json"
local LEGACY_MAILBOX_PATH = "/.launcher/email-mailboxes.json"
local LEGACY_ACCOUNT_PATH = "/.launcher/email-accounts.json"
local MAX_MESSAGES_PER_MAILBOX = 100
local MAX_SUBJECT_LENGTH = 80
local MAX_BODY_LENGTH = 2000
local MAX_PASSWORD_LENGTH = 128
local MAX_CATEGORIES_PER_ACCOUNT = 20
local MAX_CATEGORY_NAME_LENGTH = 24

local function normalizeEmail(email)
    if type(email) ~= "string" then return nil end
    email = email:lower()
    if #email > 64 or not email:match("^[%w._+-]+@[%w.-]+%.[%a]+$")
        or email:find("%.%.") or email:find("@%.") or email:find("%.@") then
        return nil
    end
    return email
end

local function validDomain(domain)
    if type(domain) ~= "string" or #domain > 253 or domain:find("[^%w.-]") then
        return false
    end
    for label in domain:gmatch("[^.]+") do
        if #label > 63 or label:match("^[%-]") or label:match("%-$") then
            return false
        end
    end
    return domain:find("%.") ~= nil
        and not domain:find("%.%.")
        and not domain:find("^%.")
        and not domain:find("%.$")
end

local function emailDomain(email)
    return email:match("@(.+)$")
end

local function validLegacyMailboxName(name)
    return type(name) == "string" and #name > 0 and #name <= 32
        and name:match("^[%w_-]+$") ~= nil
end

local function validCategoryName(name)
    return type(name) == "string" and #name > 0 and #name <= MAX_CATEGORY_NAME_LENGTH
        and name:match("^[%w _%-]+$") ~= nil and name:match("^%s*$") == nil
        and name == name:match("^%s*(.-)%s*$")
end

local function isInbox(category)
    return type(category) == "string" and category:lower() == "inbox"
end

local function loadMailboxes()
    local path = fs.exists(MAILBOX_PATH) and MAILBOX_PATH or LEGACY_MAILBOX_PATH
    if not fs.exists(path) then return {} end
    local file = fs.open(path, "r")
    if not file then error("Could not open " .. path .. " for reading.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" then
        error("Email mailbox data is invalid; refusing to overwrite it.")
    end
    for username, messages in pairs(data) do
        if not normalizeEmail(username) and not validLegacyMailboxName(username) then
            error("Email mailbox data contains an invalid mailbox.")
        end
        for _, message in ipairs(messages) do
            if type(message) ~= "table" or type(message.id) ~= "number"
                or type(message.from) ~= "string" or type(message.subject) ~= "string"
                or type(message.body) ~= "string" or type(message.sentAt) ~= "number"
                or type(message.read) ~= "boolean" then
                error("Email mailbox data contains an invalid message.")
            end
        end
    end
    return data
end

local function loadAccounts()
    local path = fs.exists(ACCOUNT_PATH) and ACCOUNT_PATH or LEGACY_ACCOUNT_PATH
    if not fs.exists(path) then return {} end
    local file = fs.open(path, "r")
    if not file then error("Could not open " .. path .. " for reading.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" then
        error("Email account data is invalid; refusing to overwrite it.")
    end

    for email, password in pairs(data) do
        if normalizeEmail(email) ~= email or type(password) ~= "string"
            or #password < 1 or #password > MAX_PASSWORD_LENGTH then
            error("Email account data contains an invalid account.")
        end
    end
    return data
end

local function loadCategories()
    if not fs.exists(CATEGORY_PATH) then return {} end
    local file = fs.open(CATEGORY_PATH, "r")
    if not file then error("Could not open " .. CATEGORY_PATH .. " for reading.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" then
        error("Email category data is invalid; refusing to overwrite it.")
    end
    for email, names in pairs(data) do
        if normalizeEmail(email) ~= email or type(names) ~= "table" then
            error("Email category data contains an invalid account.")
        end
        local seen, count = {}, 0
        for index, name in pairs(names) do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0
                or not validCategoryName(name) or isInbox(name) or seen[name:lower()] then
                error("Email category data contains an invalid category.")
            end
            seen[name:lower()] = true
            count = count + 1
        end
        if count > MAX_CATEGORIES_PER_ACCOUNT then
            error("Email category data exceeds the category limit.")
        end
        for index = 1, count do
            if names[index] == nil then error("Email category data contains an invalid category list.") end
        end
    end
    return data
end

local function saveJSON(path, data, label)
    fs.makeDir(DATA_DIRECTORY)
    local temporary = path .. ".tmp"
    local backup = path .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end

    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create the " .. label .. " staging file." end
    file.write(textutils.serializeJSON(data))
    file.close()

    if fs.exists(path) then
        local moved, err = pcall(fs.move, path, backup)
        if not moved then
            fs.delete(temporary)
            return false, "Could not back up " .. label .. ": " .. tostring(err)
        end
    end
    local moved, err = pcall(fs.move, temporary, path)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, path) end
        return false, "Could not save " .. label .. ": " .. tostring(err)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function saveMailboxes(mailboxes)
    return saveJSON(MAILBOX_PATH, mailboxes, "mailbox data")
end

local function saveAccounts(accounts)
    return saveJSON(ACCOUNT_PATH, accounts, "account data")
end

local function saveCategories(categories)
    return saveJSON(CATEGORY_PATH, categories, "category data")
end

local function loadDomainAllowlist()
    if not fs.exists(DOMAIN_ALLOWLIST_PATH) then
        local saved, saveError = saveJSON(DOMAIN_ALLOWLIST_PATH, {}, "domain allowlist")
        if not saved then error(saveError) end
        return {}
    end

    local file = fs.open(DOMAIN_ALLOWLIST_PATH, "r")
    if not file then error("Could not open " .. DOMAIN_ALLOWLIST_PATH .. " for reading.") end
    local contents = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, contents)
    if not ok or type(data) ~= "table" then
        error("Domain allowlist is invalid; refusing account registrations.")
    end

    for domain, computerIds in pairs(data) do
        if not validDomain(domain) or domain ~= domain:lower() or type(computerIds) ~= "table" then
            error("Domain allowlist must map lowercase domains to arrays of computer IDs.")
        end
        for index, computerId in pairs(computerIds) do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0
                or type(computerId) ~= "number" or computerId < 0 or computerId % 1 ~= 0 then
                error("Domain allowlist contains an invalid computer ID.")
            end
        end
    end
    return data
end

local function mailboxFor(mailboxes, username)
    if not mailboxes[username] then mailboxes[username] = {} end
    return mailboxes[username]
end

local function summarize(messages, category)
    local result = {}
    for _, message in ipairs(messages) do
        local messageCategory = message.category or "Inbox"
        if messageCategory == category then
            table.insert(result, {
                id = message.id,
                from = message.from,
                subject = message.subject,
                sentAt = message.sentAt,
                read = message.read,
            })
        end
    end
    return result
end

local function categoriesFor(categories, email)
    local result = { "Inbox" }
    for _, category in ipairs(categories[email] or {}) do
        table.insert(result, category)
    end
    return result
end

local function hasCategory(categories, email, requested)
    if isInbox(requested) then return true, "Inbox" end
    if type(requested) ~= "string" then return false end
    for _, category in ipairs(categories[email] or {}) do
        if category:lower() == requested:lower() then return true, category end
    end
    return false
end

local function nextMessageId(mailboxes, timestamp)
    local largestId = timestamp - 1
    for _, messages in pairs(mailboxes) do
        for _, message in ipairs(messages) do
            if message.id >= largestId then largestId = message.id end
        end
    end
    return largestId + 1
end

local function authenticatedAccount(accounts, request)
    local email = normalizeEmail(request.email)
    if not email or type(request.password) ~= "string"
        or #request.password < 1 or #request.password > MAX_PASSWORD_LENGTH
        or accounts[email] ~= request.password then
        return nil
    end
    return email
end

local function unreadCount(messages)
    local count = 0
    for _, message in ipairs(messages) do
        if not message.read then count = count + 1 end
    end
    return count
end

local function notifySubscribers(subscribers, email, title, message)
    for computerId in pairs(subscribers[email] or {}) do
        rednet.send(computerId, {
            type = "notification",
            source = "Email",
            user = email,
            title = title,
            message = message,
        }, NOTIFICATION_PROTOCOL)
    end
end

local function handleRequest(mailboxes, accounts, categories, domainAllowlist, subscribers, senderId, request)
    if type(request) ~= "table" or type(request.type) ~= "string" then
        return { type = "error", message = "Invalid request." }
    end

    if request.type == "register" then
        local email = normalizeEmail(request.email)
        if not email then
            return { type = "error", message = "Enter a valid email address (for example, name@example.com)." }
        end
        local domain = emailDomain(email)
        local allowedIds = domainAllowlist[domain]
        local permitted = domain == "riftmail.com"
        if not permitted and type(allowedIds) == "table" then
            for _, computerId in ipairs(allowedIds) do
                if computerId == senderId then
                    permitted = true
                    break
                end
            end
        end
        if not permitted then
            return { type = "error", message = "This domain is not enabled for registration from this computer." }
        end
        if type(request.password) ~= "string" or #request.password < 1
            or #request.password > MAX_PASSWORD_LENGTH then
            return { type = "error", message = "Password must be 1 to 128 characters." }
        end
        if accounts[email] then
            return { type = "error", message = "That email address is already registered." }
        end
        accounts[email] = request.password
        local saved, saveError = saveAccounts(accounts)
        if not saved then
            accounts[email] = nil
            return { type = "error", message = saveError }
        end
        return { type = "registered", email = email }
    elseif request.type == "login" then
        local email = authenticatedAccount(accounts, request)
        if not email then return { type = "error", message = "Email address or password is incorrect." } end
        return { type = "authenticated", email = email }
    end

    local email = authenticatedAccount(accounts, request)
    if not email then return { type = "error", message = "Email address or password is incorrect." } end

    if request.type == "send" then
        local recipient = normalizeEmail(request.to)
        if not recipient or not accounts[recipient] then
            return { type = "error", message = "Recipient email address is not registered." }
        end
        if type(request.subject) ~= "string" or #request.subject < 1
            or #request.subject > MAX_SUBJECT_LENGTH or request.subject:find("%c") then
            return { type = "error", message = "Subject must be 1 to 80 characters without control characters." }
        end
        if type(request.body) ~= "string" or #request.body < 1 or #request.body > MAX_BODY_LENGTH then
            return { type = "error", message = "Message body must be 1 to 2000 characters." }
        end

        local recipientMailbox = mailboxFor(mailboxes, recipient)
        if #recipientMailbox >= MAX_MESSAGES_PER_MAILBOX then
            return { type = "error", message = "The recipient mailbox is full." }
        end
        local sentAt = os.epoch and os.epoch("utc") or os.time() * 1000
        local id = nextMessageId(mailboxes, sentAt)
        table.insert(recipientMailbox, {
            id = id,
            from = email,
            subject = request.subject,
            body = request.body,
            sentAt = sentAt,
            read = false,
        })
        local saved, saveError = saveMailboxes(mailboxes)
        if not saved then
            table.remove(recipientMailbox)
            return { type = "error", message = saveError }
        end
        notifySubscribers(
            subscribers,
            recipient,
            "New email",
            "From " .. email .. ": " .. request.subject
        )
        return { type = "sent", id = id }
    elseif request.type == "list" then
        local category = request.category or "Inbox"
        local exists, normalizedCategory = hasCategory(categories, email, category)
        if not exists then return { type = "error", message = "Email category not found." } end
        return {
            type = "inbox",
            category = normalizedCategory,
            messages = summarize(mailboxFor(mailboxes, email), normalizedCategory),
        }
    elseif request.type == "list_categories" then
        return { type = "categories", categories = categoriesFor(categories, email) }
    elseif request.type == "create_category" then
        local name = request.category
        if not validCategoryName(name) or isInbox(name) then
            return {
                type = "error",
                message = "Category names must be 1 to 24 letters, numbers, spaces, underscores, or hyphens, and cannot be Inbox.",
            }
        end
        local accountCategories = categories[email]
        if not accountCategories then
            accountCategories = {}
            categories[email] = accountCategories
        end
        for _, existing in ipairs(accountCategories) do
            if existing:lower() == name:lower() then
                return { type = "error", message = "That category already exists." }
            end
        end
        if #accountCategories >= MAX_CATEGORIES_PER_ACCOUNT then
            return { type = "error", message = "You have reached the category limit." }
        end
        table.insert(accountCategories, name)
        local saved, saveError = saveCategories(categories)
        if not saved then
            table.remove(accountCategories)
            if #accountCategories == 0 then categories[email] = nil end
            return { type = "error", message = saveError }
        end
        return { type = "category_created", category = name }
    elseif request.type == "move" then
        if type(request.id) ~= "number" then
            return { type = "error", message = "Message request is invalid." }
        end
        local exists, destination = hasCategory(categories, email, request.category)
        if not exists then return { type = "error", message = "Email category not found." } end
        local messages = mailboxFor(mailboxes, email)
        for _, message in ipairs(messages) do
            if message.id == request.id then
                local previousCategory = message.category
                if destination == "Inbox" then
                    message.category = nil
                else
                    message.category = destination
                end
                local saved, saveError = saveMailboxes(mailboxes)
                if not saved then
                    message.category = previousCategory
                    return { type = "error", message = saveError }
                end
                return { type = "moved", id = request.id, category = destination }
            end
        end
        return { type = "error", message = "Message not found." }
    elseif request.type == "read" then
        if type(request.id) ~= "number" then
            return { type = "error", message = "Message request is invalid." }
        end
        local messages = mailboxFor(mailboxes, email)
        for _, message in ipairs(messages) do
            if message.id == request.id then
                local wasRead = message.read
                message.read = true
                if not wasRead then
                    local saved, saveError = saveMailboxes(mailboxes)
                    if not saved then
                        message.read = false
                        return { type = "error", message = saveError }
                    end
                end
                return {
                    type = "message",
                    message = {
                        id = message.id,
                        from = message.from,
                        subject = message.subject,
                        body = message.body,
                        sentAt = message.sentAt,
                    },
                }
            end
        end
        return { type = "error", message = "Message not found." }
    elseif request.type == "delete" then
        if type(request.id) ~= "number" then
            return { type = "error", message = "Message request is invalid." }
        end
        local messages = mailboxFor(mailboxes, email)
        for index, message in ipairs(messages) do
            if message.id == request.id then
                local deleted = table.remove(messages, index)
                local saved, saveError = saveMailboxes(mailboxes)
                if not saved then
                    table.insert(messages, index, deleted)
                    return { type = "error", message = saveError }
                end
                return { type = "deleted", id = request.id }
            end
        end
        return { type = "error", message = "Message not found." }
    end
    return { type = "error", message = "Unknown email request." }
end

local function handleNotificationSubscription(accounts, mailboxes, subscribers, senderId, request)
    if type(request) ~= "table"
        or (request.type ~= "subscribe" and request.type ~= "unsubscribe") then
        return { type = "error", message = "Invalid notification subscription." }
    end
    local email = authenticatedAccount(accounts, request)
    if not email then
        return { type = "error", message = "Email address or password is incorrect." }
    end

    if request.type == "unsubscribe" then
        local accountSubscribers = subscribers[email]
        if accountSubscribers then
            accountSubscribers[senderId] = nil
            if next(accountSubscribers) == nil then subscribers[email] = nil end
        end
        return { type = "unsubscribed" }
    end

    local accountSubscribers = subscribers[email]
    if not accountSubscribers then
        accountSubscribers = {}
        subscribers[email] = accountSubscribers
    end
    if accountSubscribers[senderId] then return { type = "subscribed" } end

    accountSubscribers[senderId] = true
    local unread = unreadCount(mailboxFor(mailboxes, email))
    if unread > 0 then
        notifySubscribers(
            { [email] = { [senderId] = true } },
            email,
            "Unread email",
            "You have " .. unread .. " unread message" .. (unread == 1 and "." or "s.")
        )
    end
    return { type = "subscribed" }
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the email server.") end
end

local mailboxes = loadMailboxes()
local accounts = loadAccounts()
local categories = loadCategories()
local domainAllowlist = loadDomainAllowlist()
local notificationSubscribers = {}
openModems()
rednet.host(PROTOCOL, SERVER_NAME)
rednet.host(NOTIFICATION_CONTROL_PROTOCOL, SERVER_NAME)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Email server is running.")
print("Service: " .. SERVER_NAME)
print("Data directory: " .. DATA_DIRECTORY)
print("Domain allowlist: " .. DOMAIN_ALLOWLIST_PATH)
print("Format: {\"example.com\":[computerId,...]}")
print("Find a computer ID with os.getComputerID() on the client computer.")
print("Global registration domain: riftmail.com")
print("Stop the program to shut down the server.")

while true do
    local sender, request, protocol = rednet.receive()
    if protocol == PROTOCOL then
        local response = handleRequest(
            mailboxes, accounts, categories, domainAllowlist, notificationSubscribers, sender, request
        )
        rednet.send(sender, response, PROTOCOL)
    elseif protocol == NOTIFICATION_CONTROL_PROTOCOL then
        local response = handleNotificationSubscription(
            accounts, mailboxes, notificationSubscribers, sender, request
        )
        rednet.send(sender, response, NOTIFICATION_CONTROL_PROTOCOL)
    end
end
