local PROTOCOL = "launcher_email_v1"
local SERVER_NAME = "email_server"
local DATA_DIRECTORY = "/email-server"
local MAILBOX_PATH = DATA_DIRECTORY .. "/mailboxes.json"
local ACCOUNT_PATH = DATA_DIRECTORY .. "/accounts.json"
local LEGACY_MAILBOX_PATH = "/.launcher/email-mailboxes.json"
local LEGACY_ACCOUNT_PATH = "/.launcher/email-accounts.json"
local MAX_MESSAGES_PER_MAILBOX = 100
local MAX_SUBJECT_LENGTH = 80
local MAX_BODY_LENGTH = 2000
local MAX_PASSWORD_LENGTH = 128

local function normalizeEmail(email)
    if type(email) ~= "string" then return nil end
    email = email:lower()
    if #email > 64 or not email:match("^[%w._+-]+@[%w.-]+%.[%a]+$")
        or email:find("%.%.") or email:find("@%.") or email:find("%.@") then
        return nil
    end
    return email
end

local function validLegacyMailboxName(name)
    return type(name) == "string" and #name > 0 and #name <= 32
        and name:match("^[%w_-]+$") ~= nil
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

local function mailboxFor(mailboxes, username)
    if not mailboxes[username] then mailboxes[username] = {} end
    return mailboxes[username]
end

local function summarize(messages)
    local result = {}
    for index, message in ipairs(messages) do
        result[index] = {
            id = message.id,
            from = message.from,
            subject = message.subject,
            sentAt = message.sentAt,
            read = message.read,
        }
    end
    return result
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

local function handleRequest(mailboxes, accounts, request)
    if type(request) ~= "table" or type(request.type) ~= "string" then
        return { type = "error", message = "Invalid request." }
    end

    if request.type == "register" then
        local email = normalizeEmail(request.email)
        if not email then
            return { type = "error", message = "Enter a valid email address (for example, name@example.com)." }
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
        return { type = "sent", id = id }
    elseif request.type == "list" then
        return { type = "inbox", messages = summarize(mailboxFor(mailboxes, email)) }
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
    end
    return { type = "error", message = "Unknown email request." }
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
openModems()
rednet.host(PROTOCOL, SERVER_NAME)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Email server is running.")
print("Service: " .. SERVER_NAME)
print("Data directory: " .. DATA_DIRECTORY)
print("Stop the program to shut down the server.")

while true do
    local sender, request = rednet.receive(PROTOCOL)
    local response = handleRequest(mailboxes, accounts, request)
    rednet.send(sender, response, PROTOCOL)
end
