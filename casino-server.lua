local PROTOCOL = "rift_casino_wallet_v1"
local SERVICE_NAME = "casino_server"
local STARTING_CHIPS = 1000
local REBUY_THRESHOLD = 10
local MAX_BALANCE = 2000000000
local MAX_TRANSACTION = 2000000000
local MAX_SAVED_TRANSACTIONS = 64
local DATA_FILE = "casino-wallets.db"
local BACKUP_FILE = "casino-wallets.db.bak"
local TEMP_FILE = "casino-wallets.db.tmp"
local state

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the Casino server.") end
end

local function readState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" and type(saved.wallets) == "table" then
        return saved
    end
end

local function loadState()
    if not fs.exists(DATA_FILE) and not fs.exists(BACKUP_FILE) then
        return { wallets = {} }
    end
    local loaded = readState(DATA_FILE) or readState(BACKUP_FILE)
    if not loaded then error("Could not read Casino wallet data; refusing to overwrite it.") end
    loaded.wallets = type(loaded.wallets) == "table" and loaded.wallets or {}
    for _, wallet in pairs(loaded.wallets) do
        if type(wallet) ~= "table" then
            error("Casino wallet data is invalid; refusing to overwrite it.")
        end
        wallet.balance = type(wallet.balance) == "number" and wallet.balance or 0
        wallet.transactions = type(wallet.transactions) == "table" and wallet.transactions or {}
    end
    return loaded
end

local function saveState()
    if fs.exists(TEMP_FILE) then fs.delete(TEMP_FILE) end
    local file = fs.open(TEMP_FILE, "w")
    if not file then return false, "Could not create temporary wallet data." end
    file.write(textutils.serialize(state))
    file.close()

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists(DATA_FILE) then fs.move(DATA_FILE, BACKUP_FILE) end
    local moved, moveError = pcall(fs.move, TEMP_FILE, DATA_FILE)
    if not moved then
        if fs.exists(BACKUP_FILE) and not fs.exists(DATA_FILE) then fs.move(BACKUP_FILE, DATA_FILE) end
        return false, "Could not save Casino wallet data: " .. tostring(moveError)
    end
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    return true
end

local function getWallet(computerId)
    local key = tostring(computerId)
    local wallet = state.wallets[key]
    if not wallet then
        wallet = { balance = STARTING_CHIPS, transactions = {} }
        state.wallets[key] = wallet
        local saved, saveError = saveState()
        if not saved then
            state.wallets[key] = nil
            return nil, saveError
        end
    end
    return wallet
end

local function sendError(computerId, message, requestId)
    rednet.send(computerId, { type = "error", message = message, requestId = requestId }, PROTOCOL)
end

local function validAmount(amount)
    return type(amount) == "number" and amount % 1 == 0
        and amount > 0 and amount <= MAX_TRANSACTION
end

local function findTransaction(wallet, requestId)
    for _, transaction in ipairs(wallet.transactions) do
        if transaction.id == requestId then return transaction.response end
    end
end

local function transact(computerId, request, wallet)
    if type(request.requestId) ~= "string" or #request.requestId < 1 or #request.requestId > 64 then
        return sendError(computerId, "A unique transaction ID is required.")
    end
    local previous = findTransaction(wallet, request.requestId)
    if previous then
        rednet.send(computerId, previous, PROTOCOL)
        return
    end

    local oldBalance = wallet.balance
    if request.type == "debit" then
        if not validAmount(request.amount) then return sendError(computerId, "Debit amount is invalid.", request.requestId) end
        if wallet.balance < request.amount then return sendError(computerId, "Not enough Casino chips.", request.requestId) end
        wallet.balance = wallet.balance - request.amount
    elseif request.type == "credit" then
        if not validAmount(request.amount) then return sendError(computerId, "Credit amount is invalid.", request.requestId) end
        if wallet.balance + request.amount > MAX_BALANCE then
            return sendError(computerId, "That payout exceeds the wallet limit.", request.requestId)
        end
        wallet.balance = wallet.balance + request.amount
    elseif request.type == "rebuy" then
        if wallet.balance >= REBUY_THRESHOLD then
            return sendError(computerId, "A rebuy is available only below " .. REBUY_THRESHOLD .. " chips.", request.requestId)
        end
        wallet.balance = STARTING_CHIPS
    else
        return sendError(computerId, "Unknown Casino wallet request.", request.requestId)
    end

    local response = {
        type = "transaction",
        action = request.type,
        amount = request.amount or STARTING_CHIPS,
        balance = wallet.balance,
        requestId = request.requestId,
    }
    table.insert(wallet.transactions, { id = request.requestId, response = response })
    while #wallet.transactions > MAX_SAVED_TRANSACTIONS do table.remove(wallet.transactions, 1) end

    local saved, saveError = saveState()
    if not saved then
        wallet.balance = oldBalance
        table.remove(wallet.transactions)
        return sendError(computerId, saveError, request.requestId)
    end
    rednet.send(computerId, response, PROTOCOL)
end

local function handleRequest(computerId, request)
    if type(request) ~= "table" or type(request.type) ~= "string" then
        return sendError(computerId, "Invalid Casino request.", type(request) == "table" and request.requestId)
    end
    local wallet, walletError = getWallet(computerId)
    if not wallet then return sendError(computerId, walletError, request.requestId) end
    if request.type == "balance" then
        return rednet.send(computerId, {
            type = "balance",
            balance = wallet.balance,
            requestId = request.requestId,
        }, PROTOCOL)
    end
    transact(computerId, request, wallet)
end

local function drawDashboard()
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    local function line(row, text, foreground, background)
        if row < 1 or row > height then return end
        term.setCursorPos(1, row)
        term.setTextColor(foreground or colors.white)
        term.setBackgroundColor(background or colors.black)
        term.write(tostring(text):sub(1, width))
    end

    local walletCount, totalChips = 0, 0
    for _, wallet in pairs(state.wallets) do
        walletCount = walletCount + 1
        totalChips = totalChips + wallet.balance
    end
    line(1, " RIFT CASINO SERVER  |  ONLINE", colors.white, colors.cyan)
    line(2, "Computer #" .. os.getComputerID() .. "  |  Protocol: " .. PROTOCOL, colors.lightGray)
    line(4, "PLAYER WALLETS  " .. walletCount, colors.white, colors.blue)
    line(5, "CHIPS IN CIRCULATION  " .. totalChips, colors.lime)
    line(7, "DEFAULT WALLET  " .. STARTING_CHIPS .. " chips", colors.lightGray)
    line(8, "REBUY THRESHOLD  " .. REBUY_THRESHOLD .. " chips", colors.lightGray)
    line(10, "Accounts are keyed by the player's ComputerCraft ID.", colors.yellow)
    line(11, "Wallets persist in " .. DATA_FILE .. ".", colors.lightGray)
    line(13, "Casino games must be installed on player computers", colors.lightGray)
    line(14, "and connected to this server over rednet.", colors.lightGray)
    term.setBackgroundColor(colors.black)
end

openModems()
state = loadState()
rednet.host(PROTOCOL, SERVICE_NAME)
drawDashboard()

while true do
    local computerId, request, protocol = rednet.receive(nil, 1)
    if computerId and protocol == PROTOCOL then handleRequest(computerId, request) end
    drawDashboard()
end
