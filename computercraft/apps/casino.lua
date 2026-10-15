local OWNER_REPO = "ZeroCreates/The-Repo"
local BRANCH = "main"
local BASE_URL = "https://raw.githubusercontent.com/" .. OWNER_REPO .. "/" .. BRANCH .. "/"
local CASINO_PROTOCOL = "rift_casino_wallet_v1"
local CASINO_SERVER = "casino_server"
local TIMEOUT = 5
local STARTING_CHIPS = 1000
local transactionSequence = 0
local games = {
    { name = "Blackjack", file = "blackjack.lua", source = "computercraft/apps/blackjack.lua", argument = "blackjack" },
    { name = "Texas Hold'em", file = "texas-holdem.lua", source = "computercraft/apps/texas-holdem.lua", argument = "holdem" },
}
local appDirectory = fs.getDir(shell.getRunningProgram())
local balance
local statusMessage = ""

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    term.setCursorPos(x, y)
    term.setTextColor(foreground or colors.white)
    term.setBackgroundColor(background or colors.black)
    term.write(tostring(text):sub(1, width - x + 1))
    term.setBackgroundColor(colors.black)
end

local function drawHeader(subtitle)
    local width = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    writeAt(1, 1, string.rep(" ", width), colors.white, colors.cyan)
    writeAt(2, 1, "RIFT CASINO", colors.white, colors.cyan)
    writeAt(2, 2, subtitle, colors.lightGray)
end

local function drawButtons(options)
    local width, height = term.getSize()
    local columns = math.min(3, #options)
    local rowCount = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local column = (index - 1) % columns
        local row = height - rowCount + math.floor((index - 1) / columns) + 1
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[ " .. option.label .. " ]"):sub(1, right - left + 1)
        writeAt(left, row, string.rep(" ", right - left + 1), colors.black, colors.lightBlue)
        writeAt(left, row, label, colors.black, colors.lightBlue)
        table.insert(buttons, { id = option.id, key = option.key, row = row, left = left, right = right })
    end
    return buttons
end

local function waitForAction(buttons)
    while true do
        local event, value, x, y = os.pullEvent()
        if event == "mouse_click" and value == 1 then
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then return choice.id end
            end
        elseif event == "key" then
            for _, choice in ipairs(buttons) do
                if choice.key == value then return choice.id end
            end
        end
    end
end

local function nextRequestId()
    transactionSequence = transactionSequence + 1
    return os.getComputerID() .. "-" .. os.epoch("utc") .. "-casino-" .. transactionSequence
end

local function serverRequest(message)
    local serverId = rednet.lookup(CASINO_PROTOCOL, CASINO_SERVER)
    if not serverId then return nil, "Casino server offline. Start casino-server.lua." end
    message.requestId = message.requestId or nextRequestId()
    for _ = 1, 2 do
        rednet.send(serverId, message, CASINO_PROTOCOL)
        local _, response = rednet.receive(CASINO_PROTOCOL, TIMEOUT, serverId)
        if type(response) == "table"
            and (response.requestId == nil or response.requestId == message.requestId) then
            if response.type == "error" then
                return nil, response.message or "Casino server rejected the request."
            end
            return response
        end
    end
    return nil, "No matching response from the Casino server."
end

local walletApi = {}
function walletApi.getBalance()
    return serverRequest({ type = "balance" })
end
function walletApi.transact(action, amount, requestId)
    return serverRequest({ type = action, amount = amount, requestId = requestId })
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    return found
end

local function gamePath(game)
    return fs.combine(appDirectory, game.file)
end

local function gameInstalled(game)
    return fs.exists(gamePath(game))
end

local function downloadGame(game)
    if not http or not http.get then return false, "Enable HTTP to install Casino games." end
    local response, requestError = http.get(BASE_URL .. game.source)
    if not response then return false, tostring(requestError or "Download failed.") end
    local statusCode = response.getResponseCode and response.getResponseCode()
    if statusCode and statusCode ~= 200 then
        response.close()
        return false, "GitHub returned HTTP " .. statusCode .. "."
    end
    local contents = response.readAll()
    response.close()
    if type(contents) ~= "string" or contents == "" then return false, "The downloaded game was empty." end

    fs.makeDir(appDirectory)
    local destination = gamePath(game)
    local temporary = destination .. ".casino-tmp"
    local backup = destination .. ".casino-bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create the install file." end
    file.write(contents)
    file.close()

    if fs.exists(destination) then fs.move(destination, backup) end
    local moved, moveError = pcall(fs.move, temporary, destination)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, destination) end
        return false, "Could not install " .. game.name .. ": " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function installGames(onlyMissing)
    for _, game in ipairs(games) do
        if not onlyMissing or not gameInstalled(game) then
            drawHeader("INSTALLING  /  " .. game.name:upper())
            writeAt(2, 5, "Downloading the latest game script...", colors.white)
            local installed, err = downloadGame(game)
            if not installed then return false, err end
        end
    end
    return true
end

local function updateBalance()
    local response, err = walletApi.getBalance()
    if response then
        balance = response.balance
        statusMessage = "Balance refreshed from Casino server."
    else
        balance = nil
        statusMessage = tostring(err)
    end
end

local function launchGame(game)
    if not gameInstalled(game) then
        local installed, err = downloadGame(game)
        if not installed then
            statusMessage = "INSTALL FAILED  /  " .. tostring(err)
            return
        end
    end
    local path = gamePath(game)
    local file = fs.open(path, "r")
    if not file then
        statusMessage = "Could not open " .. game.file .. "."
        return
    end
    local source = file.readAll()
    file.close()

    local gameEnvironment = setmetatable({ riftCasino = walletApi }, { __index = _ENV })
    gameEnvironment._G = gameEnvironment
    local gameChunk, compileError = load(source, "@" .. path, "t", gameEnvironment)
    if not gameChunk then
        statusMessage = "Could not load " .. game.name .. ": " .. tostring(compileError)
        return
    end
    local ok, runError = pcall(gameChunk)
    if not ok then statusMessage = game.name .. " stopped: " .. tostring(runError) end
    updateBalance()
end

local function startModemsAndInstall()
    openModems()
    local missing = false
    for _, game in ipairs(games) do
        if not gameInstalled(game) then missing = true end
    end
    if missing then
        local installed, err = installGames(true)
        statusMessage = installed and "Both Casino games are installed." or ("INSTALL FAILED  /  " .. tostring(err))
    end
    updateBalance()
end

local requestedGame = select(1, ...)
startModemsAndInstall()
if requestedGame == "blackjack" then
    launchGame(games[1])
    return
elseif requestedGame == "holdem" then
    launchGame(games[2])
    return
end

while true do
    local bankroll = balance and ("BANKROLL  " .. balance .. " CHIPS") or "BANKROLL  SERVER OFFLINE"
    drawHeader(bankroll)
    writeAt(2, 5, "BLACKJACK", colors.yellow)
    writeAt(2, 6, "Dealer game  /  shared Casino bankroll", colors.lightGray)
    writeAt(2, 8, "TEXAS HOLD'EM", colors.yellow)
    writeAt(2, 9, "Three automated opponents  /  shared bankroll", colors.lightGray)
    writeAt(2, 12, statusMessage, colors.white)
    local options = {
        { id = "blackjack", label = "BLACKJACK", key = keys.b },
        { id = "holdem", label = "HOLD'EM", key = keys.h },
        { id = "install", label = "INSTALL / UPDATE", key = keys.i },
        { id = "refresh", label = "BALANCE", key = keys.r },
    }
    if balance and balance < 10 then
        table.insert(options, { id = "rebuy", label = "REBUY", key = keys.e })
    end
    table.insert(options, { id = "quit", label = "QUIT", key = keys.q })

    local choice = waitForAction(drawButtons(options))
    if choice == "blackjack" then
        launchGame(games[1])
    elseif choice == "holdem" then
        launchGame(games[2])
    elseif choice == "install" then
        local installed, err = installGames(false)
        statusMessage = installed and "Both games installed or updated." or ("INSTALL FAILED  /  " .. tostring(err))
    elseif choice == "refresh" then
        updateBalance()
    elseif choice == "rebuy" then
        local response, err = walletApi.transact("rebuy")
        if response then
            balance = response.balance
            statusMessage = "Rebuy complete."
        else
            statusMessage = "REBUY FAILED  /  " .. tostring(err)
        end
    elseif choice == "quit" then
        break
    end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
