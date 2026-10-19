local PROTOCOL = "rift_jobs_v1"
local ACCOUNT_PROTOCOL = "rift_account_v1"
local LOGIN_SERVER_NAME = "rift-server"
local JOBS_SERVER_NAME = "rift-jobs"
local MARKET_PROTOCOL = "order_system_v1"
local MARKET_SERVER_NAME = "rift-market"
local DATA_FILE = "jobs.db"
local BACKUP_FILE = "jobs.db.bak"
local TEMP_FILE = "jobs.db.tmp"
local state
local sessions = {}
local handleMarketRequest
local getMarketDashboardStats
local responseProtocol = PROTOCOL

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the combined Jobs and Market server.") end
end

local function readState(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserialize, contents)
    if ok and type(saved) == "table" and type(saved.jobs) == "table" then
        return saved
    end
end

local function loadState()
    if not fs.exists(DATA_FILE) and not fs.exists(BACKUP_FILE) then
        return { nextId = 1, jobs = {}, accounts = {} }
    end
    local loaded = readState(DATA_FILE) or readState(BACKUP_FILE)
    if not loaded then error("Could not read saved Jobs data; refusing to overwrite it.") end
    loaded.nextId = type(loaded.nextId) == "number" and loaded.nextId or 1
    loaded.jobs = type(loaded.jobs) == "table" and loaded.jobs or {}
    if loaded.accounts == nil then loaded.accounts = {} end
    if type(loaded.accounts) ~= "table" then
        error("Saved Jobs account data is invalid; refusing to overwrite it.")
    end
    for username, account in pairs(loaded.accounts) do
        if type(username) ~= "string" or type(account) ~= "table"
            or type(account.username) ~= "string" or account.username:lower() ~= username
            or #account.username < 3 or #account.username > 24
            or not account.username:match("^[%w_-]+$") or type(account.password) ~= "string"
            or #account.password < 1 or #account.password > 128 then
            error("Saved Jobs account data is invalid; refusing to overwrite it.")
        end
    end
    for _, job in ipairs(loaded.jobs) do
        if type(job.id) == "number" then loaded.nextId = math.max(loaded.nextId, job.id + 1) end
    end
    return loaded
end

local function saveState()
    local file = fs.open(TEMP_FILE, "w")
    if not file then return false, "Could not create the temporary Jobs data file." end
    file.write(textutils.serialize({
        nextId = state.nextId,
        jobs = state.jobs,
        accounts = state.accounts,
    }))
    file.close()

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists(DATA_FILE) then fs.move(DATA_FILE, BACKUP_FILE) end
    local ok, saveError = pcall(fs.move, TEMP_FILE, DATA_FILE)
    if not ok then
        if fs.exists(BACKUP_FILE) and not fs.exists(DATA_FILE) then fs.move(BACKUP_FILE, DATA_FILE) end
        return false, "Could not save Jobs data: " .. tostring(saveError)
    end
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    return true
end

local function sendError(senderId, message)
    rednet.send(senderId, { type = "error", message = message }, responseProtocol)
end

local function findJob(jobId)
    for _, job in ipairs(state.jobs) do
        if job.id == jobId then return job end
    end
end

local function cleanText(value, minimum, maximum)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if #value < minimum or #value > maximum or value:find("%c") then return nil end
    return value
end

local function accountKey(username)
    local cleaned = cleanText(username, 3, 24)
    if not cleaned or not cleaned:match("^[%w_-]+$") then return nil end
    return cleaned:lower(), cleaned
end

local function registerAccount(senderId, message)
    local key, username = accountKey(message.username)
    local password = message.password
    if not key then
        return sendError(senderId, "Username must be 3-24 letters, numbers, underscores, or dashes.")
    end
    if type(password) ~= "string" or #password < 1 or #password > 128 then
        return sendError(senderId, "Password must be 1 to 128 characters.")
    end
    if state.accounts[key] then
        return sendError(senderId, "That Jobs username is already registered.")
    end

    state.accounts[key] = { username = username, password = password }
    local saved, saveError = saveState()
    if not saved then
        state.accounts[key] = nil
        return sendError(senderId, saveError)
    end
    sessions[senderId] = username
    rednet.send(senderId, { type = "authenticated", username = username }, responseProtocol)
end

local function loginAccount(senderId, message)
    local key = accountKey(message.username)
    local account = key and state.accounts[key]
    if not account or type(message.password) ~= "string"
        or account.password ~= message.password then
        return sendError(senderId, "Username or password is incorrect.")
    end
    sessions[senderId] = account.username
    rednet.send(senderId, { type = "authenticated", username = account.username }, responseProtocol)
end

local function belongsToUser(job, field, legacyId, senderId, username)
    local owner = job[field]
    if owner then return owner == username end
    return job[legacyId] == senderId
end

local function copyJob(job)
    local copy = {}
    for key, value in pairs(job) do copy[key] = value end
    return copy
end

local function mutateJob(senderId, job, changes, responseType)
    local previous = copyJob(job)
    for key, value in pairs(changes) do job[key] = value end
    job.updatedAt = os.epoch("utc")
    local saved, saveError = saveState()
    if not saved then
        for key in pairs(job) do job[key] = nil end
        for key, value in pairs(previous) do job[key] = value end
        return sendError(senderId, saveError)
    end
    rednet.send(senderId, { type = responseType, job = copyJob(job) }, responseProtocol)
end

local function createJob(senderId, username, message)
    local title = cleanText(message.title, 3, 40)
    local description = cleanText(message.description, 5, 180)
    local reward = cleanText(message.reward, 1, 60)
    if not title or not description or not reward then
        return sendError(senderId, "Enter a title (3-40 chars), details (5-180), and reward (1-60).")
    end

    local job = {
        id = state.nextId,
        posterId = senderId,
        posterName = username,
        posterUser = username,
        title = title,
        description = description,
        reward = reward,
        status = "open",
        createdAt = os.epoch("utc"),
        updatedAt = os.epoch("utc"),
    }
    state.nextId = state.nextId + 1
    table.insert(state.jobs, job)
    local saved, saveError = saveState()
    if not saved then
        table.remove(state.jobs)
        state.nextId = state.nextId - 1
        return sendError(senderId, saveError)
    end
    rednet.send(senderId, { type = "job_created", job = copyJob(job) }, responseProtocol)
end

local function listJobs(senderId, username, mineOnly)
    local jobs = {}
    for _, job in ipairs(state.jobs) do
        local isMine = belongsToUser(job, "posterUser", "posterId", senderId, username)
            or belongsToUser(job, "claimantUser", "claimantId", senderId, username)
        if mineOnly and isMine or not mineOnly and job.status == "open" then
            table.insert(jobs, copyJob(job))
        end
    end
    rednet.send(senderId, { type = mineOnly and "my_jobs" or "job_board", jobs = jobs }, responseProtocol)
end

local function handleRequest(senderId, message, protocol)
    responseProtocol = protocol
    if type(message) ~= "table" or type(message.type) ~= "string" then
        return sendError(senderId, "Invalid Jobs request.")
    end
    if protocol == ACCOUNT_PROTOCOL and message.type ~= "register"
        and message.type ~= "login" and message.type ~= "logout" then
        return sendError(senderId, "The Rift account endpoint only accepts account requests.")
    end
    if message.type == "register" then return registerAccount(senderId, message) end
    if message.type == "login" then return loginAccount(senderId, message) end
    if message.type == "logout" then
        sessions[senderId] = nil
        return rednet.send(senderId, { type = "logged_out" }, responseProtocol)
    end

    local username = sessions[senderId]
    if not username then return sendError(senderId, "Sign in to a Jobs account first.") end
    if message.type == "list_jobs" then return listJobs(senderId, username, false) end
    if message.type == "my_jobs" then return listJobs(senderId, username, true) end
    if message.type == "create_job" then return createJob(senderId, username, message) end

    if type(message.jobId) ~= "number" or message.jobId % 1 ~= 0 then
        return sendError(senderId, "Enter a valid job number.")
    end
    local job = findJob(message.jobId)
    if not job then return sendError(senderId, "Job not found.") end

    if message.type == "claim_job" then
        if job.status ~= "open" then return sendError(senderId, "That job is no longer open.") end
        if belongsToUser(job, "posterUser", "posterId", senderId, username) then
            return sendError(senderId, "You cannot claim your own job.")
        end
        return mutateJob(senderId, job, {
            claimantId = senderId,
            claimantName = username,
            claimantUser = username,
            status = "claimed",
            submission = nil,
            reviewNote = nil,
        }, "job_updated")
    elseif message.type == "submit_job" then
        local submission = cleanText(message.submission, 5, 180)
        if not belongsToUser(job, "claimantUser", "claimantId", senderId, username)
            or job.status ~= "claimed" then
            return sendError(senderId, "Only the assigned worker can submit a claimed job.")
        end
        if not submission then return sendError(senderId, "Describe the completed work (5-180 characters).") end
        return mutateJob(senderId, job, { submission = submission, reviewNote = nil, status = "review" }, "job_updated")
    elseif message.type == "approve_job" then
        if not belongsToUser(job, "posterUser", "posterId", senderId, username)
            or job.status ~= "review" then
            return sendError(senderId, "Only the job poster can approve submitted work.")
        end
        return mutateJob(senderId, job, { status = "completed" }, "job_updated")
    elseif message.type == "revise_job" then
        local note = cleanText(message.note, 1, 120)
        if not belongsToUser(job, "posterUser", "posterId", senderId, username)
            or job.status ~= "review" then
            return sendError(senderId, "Only the job poster can request a revision.")
        end
        if not note then return sendError(senderId, "Enter a revision note (1-120 characters).") end
        return mutateJob(senderId, job, { status = "claimed", reviewNote = note, submission = nil }, "job_updated")
    elseif message.type == "withdraw_claim" then
        if not belongsToUser(job, "claimantUser", "claimantId", senderId, username)
            or job.status ~= "claimed" then
            return sendError(senderId, "You can only withdraw a job before submitting it.")
        end
        return mutateJob(senderId, job, {
            claimantId = nil,
            claimantName = nil,
            claimantUser = nil,
            status = "open",
            reviewNote = nil,
        }, "job_updated")
    elseif message.type == "cancel_job" then
        if not belongsToUser(job, "posterUser", "posterId", senderId, username)
            or (job.status ~= "open" and job.status ~= "claimed") then
            return sendError(senderId, "Only the poster can cancel an open or claimed job.")
        end
        return mutateJob(senderId, job, { status = "cancelled" }, "job_updated")
    end
    sendError(senderId, "Unknown Jobs request.")
end

local startedAt = os.clock()
local requestsByService = { login = 0, jobs = 0, market = 0 }
local lastRequest = "Waiting for network requests"

local function drawDashboard()
    local width, height = term.getSize()
    local color = term.isColor()
    local background = colors.black
    local foreground = colors.white
    local accent = color and colors.cyan or colors.white
    local panel = color and colors.blue or colors.gray
    local muted = color and colors.lightGray or colors.white
    local good = color and colors.lime or colors.white
    local warning = color and colors.yellow or colors.white

    local function lineAt(column, row, text, textColor, fill, cellWidth)
        if row < 1 or row > height then return end
        local available = math.min(cellWidth or (width - column + 1), width - column + 1)
        if available < 1 then return end
        term.setCursorPos(column, row)
        term.setBackgroundColor(fill or background)
        term.setTextColor(textColor or foreground)
        local content = tostring(text):sub(1, available)
        term.write(content .. string.rep(" ", math.max(0, available - #content)))
    end

    local function line(row, text, textColor, fill)
        lineAt(1, row, text, textColor, fill)
    end

    local function section(column, row, title, cellWidth)
        lineAt(column, row, " " .. title, foreground, panel, cellWidth)
    end

    local market = getMarketDashboardStats()
    local openCount, activeCount, completedCount = 0, 0, 0
    for _, job in ipairs(state.jobs) do
        if job.status == "open" then
            openCount = openCount + 1
        elseif job.status == "claimed" or job.status == "review" then
            activeCount = activeCount + 1
        elseif job.status == "completed" then
            completedCount = completedCount + 1
        end
    end

    local sessionCount = 0
    for _ in pairs(sessions) do sessionCount = sessionCount + 1 end

    term.setBackgroundColor(background)
    term.setTextColor(foreground)
    term.clear()
    line(1, " RIFT SERVER  /  JOBS + MARKET", foreground, accent)
    line(2, " ONLINE  |  COMPUTER #" .. os.getComputerID()
        .. "  |  UP " .. string.format("%02d:%02d", math.floor((os.clock() - startedAt) / 60),
            math.floor((os.clock() - startedAt) % 60)), muted)

    local jobsColumnWidth = math.max(1, math.floor(width / 2))
    local marketColumn = jobsColumnWidth + 1
    local marketColumnWidth = width - jobsColumnWidth
    if width >= 40 then
        section(1, 4, "JOBS", jobsColumnWidth)
        section(marketColumn, 4, "MARKET", marketColumnWidth)
        lineAt(1, 5, " Open " .. openCount .. "  |  Active " .. activeCount
            .. "  |  Done " .. completedCount, good, nil, jobsColumnWidth)
        lineAt(marketColumn, 5, " Orders " .. market.activeOrders
            .. " active  |  Products " .. market.liveProducts .. "/" .. market.totalProducts,
            good, nil, marketColumnWidth)
        lineAt(1, 6, " Signed in: " .. sessionCount, muted, nil, jobsColumnWidth)
        lineAt(marketColumn, 6, " Done " .. market.completedOrders
            .. "  |  Cancelled " .. market.cancelledOrders, muted, nil, marketColumnWidth)
    else
        section(1, 4, "JOBS", width)
        line(5, " Open " .. openCount .. "  Active " .. activeCount
            .. "  Done " .. completedCount, good)
        line(6, " Signed in: " .. sessionCount, muted)
        section(1, 7, "MARKET", width)
        line(8, " Active orders: " .. market.activeOrders
            .. "  Products: " .. market.liveProducts .. "/" .. market.totalProducts, good)
        line(9, " Completed: " .. market.completedOrders
            .. "  Cancelled: " .. market.cancelledOrders, muted)
    end

    local endpointRow = width >= 40 and 8 or 11
    section(1, endpointRow, "NETWORK ENDPOINTS", width)
    line(endpointRow + 1, " Login / rift-server  |  Jobs / rift-jobs", muted)
    line(endpointRow + 2, " Market / rift-market", muted)

    local activityRow = endpointRow + 4
    section(1, activityRow, "TRAFFIC", width)
    line(activityRow + 1, " Login " .. requestsByService.login
        .. "  |  Jobs " .. requestsByService.jobs
        .. "  |  Market " .. requestsByService.market, good)
    line(activityRow + 2, " Last: " .. lastRequest, muted)

    local recentHeaderRow = activityRow + 4
    if width >= 40 then
        section(1, recentHeaderRow, "RECENT JOBS", jobsColumnWidth)
        section(marketColumn, recentHeaderRow, "RECENT ORDERS", marketColumnWidth)
        local row = recentHeaderRow + 1
        local availableRows = math.max(0, height - row)
        local recentJobCount = math.min(#state.jobs, availableRows)
        for index = 1, recentJobCount do
            local job = state.jobs[#state.jobs - index + 1]
            local statusColor = job.status == "open" and good
                or (job.status == "completed" and muted or warning)
            lineAt(1, row, "#" .. job.id .. " " .. job.status:upper() .. " " .. job.title,
                statusColor, nil, jobsColumnWidth)
            row = row + 1
        end
        if #state.jobs == 0 and row <= height then
            lineAt(1, row, " No jobs posted", muted, nil, jobsColumnWidth)
        end

        row = recentHeaderRow + 1
        local recentOrderCount = math.min(#market.recentOrders, math.max(0, height - row))
        for index = 1, recentOrderCount do
            local order = market.recentOrders[index]
            local statusColor = order.status == "shipping" and good
                or (order.status == "preparing" and warning or muted)
            lineAt(marketColumn, row, "#" .. order.id .. " " .. order.status:upper()
                .. " $" .. string.format("%.2f", order.total / 100),
                statusColor, nil, marketColumnWidth)
            row = row + 1
        end
        if #market.recentOrders == 0 and row <= height then
            lineAt(marketColumn, row, " No active orders", muted, nil, marketColumnWidth)
        end
    else
        section(1, recentHeaderRow, "LATEST JOBS / ORDERS", width)
        local row = recentHeaderRow + 1
        local jobIndex, orderIndex = #state.jobs, 1
        while row < height and (jobIndex > 0 or orderIndex <= #market.recentOrders) do
            if jobIndex > 0 then
                local job = state.jobs[jobIndex]
                line(row, "J #" .. job.id .. " " .. job.status:upper() .. " " .. job.title, warning)
                jobIndex = jobIndex - 1
                row = row + 1
            end
            if orderIndex <= #market.recentOrders and row < height then
                local order = market.recentOrders[orderIndex]
                line(row, "M #" .. order.id .. " " .. order.status:upper(), good)
                orderIndex = orderIndex + 1
                row = row + 1
            end
        end
        if #state.jobs == 0 and #market.recentOrders == 0 and row < height then
            line(row, " No recent activity", muted)
        end
    end

    if height >= 2 then
        term.setCursorPos(1, height)
        term.setBackgroundColor(background)
        term.setTextColor(muted)
        term.write((" Ctrl+T / terminate  |  Computer #%s"):format(os.getComputerID()):sub(1, width))
    end
    term.setBackgroundColor(background)
end

openModems()

local marketServerPath = fs.combine(fs.getDir(shell.getRunningProgram()), "rift-server-market.lua")
local marketServerChunk, marketLoadError = loadfile(marketServerPath)
if not marketServerChunk then
    error("Could not load the Market server module at " .. marketServerPath .. ": "
        .. tostring(marketLoadError), 0)
end
local moduleLoaded, createMarketServer = pcall(marketServerChunk)
if not moduleLoaded or type(createMarketServer) ~= "function" then
    error("The Market server module is invalid: " .. tostring(createMarketServer), 0)
end
handleMarketRequest, getMarketDashboardStats = createMarketServer(function(senderId)
    return sessions[senderId]
end)
if type(handleMarketRequest) ~= "function" then
    error("The Market server module did not provide a request handler.", 0)
end
if type(getMarketDashboardStats) ~= "function" then
    error("The Market server module did not provide dashboard statistics.", 0)
end

state = loadState()
rednet.host(PROTOCOL, JOBS_SERVER_NAME)
rednet.host(ACCOUNT_PROTOCOL, LOGIN_SERVER_NAME)
rednet.host(MARKET_PROTOCOL, MARKET_SERVER_NAME)
drawDashboard()

while true do
    local senderId, message, receivedProtocol = rednet.receive(nil, 1)
    if senderId and (receivedProtocol == PROTOCOL or receivedProtocol == ACCOUNT_PROTOCOL) then
        responseProtocol = receivedProtocol
        local isLoginRequest = receivedProtocol == ACCOUNT_PROTOCOL
            or type(message) == "table" and (message.type == "login"
                or message.type == "register" or message.type == "logout")
        if isLoginRequest then
            requestsByService.login = requestsByService.login + 1
            lastRequest = "Login from #" .. senderId .. "  /  "
                .. tostring(type(message) == "table" and message.type or "invalid request")
        else
            requestsByService.jobs = requestsByService.jobs + 1
            lastRequest = "Jobs from #" .. senderId .. "  /  "
                .. tostring(type(message) == "table" and message.type or "invalid request")
        end
        handleRequest(senderId, message, receivedProtocol)
    elseif senderId and receivedProtocol == MARKET_PROTOCOL then
        requestsByService.market = requestsByService.market + 1
        lastRequest = "Market from #" .. senderId .. "  /  "
            .. tostring(type(message) == "table" and message.type or "invalid request")
        handleMarketRequest(senderId, message)
    end
    drawDashboard()
end