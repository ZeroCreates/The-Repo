local PROTOCOL = "rift_jobs_v1"
local SERVER_NAME = "jobs_server"
local DATA_FILE = "jobs.db"
local BACKUP_FILE = "jobs.db.bak"
local TEMP_FILE = "jobs.db.tmp"
local state
local sessions = {}

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting the Jobs server.") end
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
    rednet.send(senderId, { type = "error", message = message }, PROTOCOL)
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
    rednet.send(senderId, { type = "authenticated", username = username }, PROTOCOL)
end

local function loginAccount(senderId, message)
    local key = accountKey(message.username)
    local account = key and state.accounts[key]
    if not account or type(message.password) ~= "string"
        or account.password ~= message.password then
        return sendError(senderId, "Username or password is incorrect.")
    end
    sessions[senderId] = account.username
    rednet.send(senderId, { type = "authenticated", username = account.username }, PROTOCOL)
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
    rednet.send(senderId, { type = responseType, job = copyJob(job) }, PROTOCOL)
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
    rednet.send(senderId, { type = "job_created", job = copyJob(job) }, PROTOCOL)
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
    rednet.send(senderId, { type = mineOnly and "my_jobs" or "job_board", jobs = jobs }, PROTOCOL)
end

local function handleRequest(senderId, message)
    if type(message) ~= "table" or type(message.type) ~= "string" then
        return sendError(senderId, "Invalid Jobs request.")
    end
    if message.type == "register" then return registerAccount(senderId, message) end
    if message.type == "login" then return loginAccount(senderId, message) end
    if message.type == "logout" then
        sessions[senderId] = nil
        return rednet.send(senderId, { type = "logged_out" }, PROTOCOL)
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

local function drawDashboard()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    local width, height = term.getSize()
    local function line(row, text, foreground, background)
        if row < 1 or row > height then return end
        term.setCursorPos(1, row)
        term.setTextColor(foreground or colors.white)
        term.setBackgroundColor(background or colors.black)
        term.write(tostring(text):sub(1, width))
    end

    local openCount, activeCount, completedCount = 0, 0, 0
    for _, job in ipairs(state.jobs) do
        if job.status == "open" then openCount = openCount + 1 end
        if job.status == "claimed" or job.status == "review" then activeCount = activeCount + 1 end
        if job.status == "completed" then completedCount = completedCount + 1 end
    end
    line(1, " RIFT JOBS SERVER  |  ONLINE", colors.white, colors.cyan)
    line(2, "Computer #" .. os.getComputerID() .. "  |  Protocol: " .. PROTOCOL, colors.lightGray)
    line(4, "OPEN  " .. openCount .. "    IN PROGRESS  " .. activeCount .. "    COMPLETED  " .. completedCount, colors.lime)
    line(6, "RECENT JOBS", colors.white, colors.blue)
    local row = 7
    for index = #state.jobs, 1, -1 do
        local job = state.jobs[index]
        if row > height then break end
        line(row, "#" .. job.id .. "  " .. job.status:upper() .. "  " .. job.title, colors.yellow)
        row = row + 1
    end
    term.setBackgroundColor(colors.black)
end

openModems()
state = loadState()
rednet.host(PROTOCOL, SERVER_NAME)
drawDashboard()

while true do
    local senderId, message, receivedProtocol = rednet.receive(nil, 1)
    if senderId and receivedProtocol == PROTOCOL then handleRequest(senderId, message) end
    drawDashboard()
end