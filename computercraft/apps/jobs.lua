local PROTOCOL = "rift_jobs_v1"
local SERVER_NAME = "jobs_server"
local TIMEOUT = 5
local PROFILE_FILE = "jobs-profile.txt"
local playerName

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

local function readText(label)
    drawHeader("RIFT JOBS  /  INPUT", label)
    local _, height = term.getSize()
    writeAt(2, height - 1, "> ", colors.lime)
    term.setCursorPos(4, height - 1)
    return read()
end

local function drawButtons(options)
    local width, height = term.getSize()
    local columns = math.min(3, #options)
    local rows = math.ceil(#options / columns)
    local buttons = {}
    for index, option in ipairs(options) do
        local column = (index - 1) % columns
        local row = height - rows + math.floor((index - 1) / columns) + 1
        local left = math.floor(column * width / columns) + 1
        local right = math.floor((column + 1) * width / columns)
        local label = ("[ " .. option.label .. " ]"):sub(1, right - left + 1)
        writeAt(left, row, string.rep(" ", right - left + 1), colors.black, colors.lightBlue)
        writeAt(left, row, label, colors.black, colors.lightBlue)
        table.insert(buttons, {
            id = option.id,
            key = option.key,
            row = row,
            left = left,
            right = right,
        })
    end
    return buttons
end

local function waitForAction(buttons, rows)
    while true do
        local event, button, x, y = os.pullEvent()
        if event == "mouse_click" and button == 1 then
            for _, entry in ipairs(rows or {}) do
                if y >= entry.top and y <= entry.bottom and x >= entry.left and x <= entry.right then
                    return "job", entry.job
                end
            end
            for _, choice in ipairs(buttons) do
                if y == choice.row and x >= choice.left and x <= choice.right then
                    return choice.id
                end
            end
        elseif event == "key" then
            for _, choice in ipairs(buttons) do
                if choice.key == button then return choice.id end
            end
        end
    end
end

local function showNotice(title, message)
    drawHeader(title, "RIFT JOBS  /  PLAYER CONTRACTS")
    writeAt(2, 5, message, colors.white)
    local buttons = drawButtons({ { id = "ok", label = "OK", key = keys.enter } })
    waitForAction(buttons)
end

local function confirm(title, message)
    drawHeader(title, "RIFT JOBS  /  PLEASE CONFIRM")
    writeAt(2, 5, message, colors.white)
    local buttons = drawButtons({
        { id = "yes", label = "CONFIRM", key = keys.y },
        { id = "no", label = "CANCEL", key = keys.n },
    })
    return waitForAction(buttons) == "yes"
end

local function openModems()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            found = true
        end
    end
    if not found then error("Attach a modem before starting Rift Jobs.") end
end

local function loadProfile()
    if fs.exists(PROFILE_FILE) then
        local file = fs.open(PROFILE_FILE, "r")
        if file then
            playerName = file.readAll():match("^%s*(.-)%s*$")
            file.close()
        end
    end
    if not playerName or playerName == "" then
        drawHeader("WELCOME TO RIFT JOBS", "CHOOSE A NAME OTHER PLAYERS WILL RECOGNIZE")
        playerName = readText("Your name (up to 24 characters)")
        playerName = playerName:match("^%s*(.-)%s*$")
        if playerName == "" then playerName = "Computer #" .. os.getComputerID() end
        local file = fs.open(PROFILE_FILE, "w")
        if file then file.write(playerName:sub(1, 24)); file.close() end
    end
    playerName = playerName:sub(1, 24)
end

local function request(message)
    local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
    if not serverId then
        return nil, "Rift Jobs server not found. Check that it is running and connected."
    end
    rednet.send(serverId, message, PROTOCOL)
    local _, response = rednet.receive(PROTOCOL, TIMEOUT, serverId)
    if type(response) ~= "table" then return nil, "No response from the Jobs server." end
    if response.type == "error" then
        return nil, response.message or "The Jobs server rejected the request."
    end
    return response
end

local function drawJobs(title, subtitle, jobs, page, showStatus)
    drawHeader(title, subtitle)
    local _, height = term.getSize()
    local perPage = math.max(1, math.floor((height - 10) / 4))
    local pageCount = math.max(1, math.ceil(#jobs / perPage))
    page = math.max(1, math.min(page, pageCount))
    writeAt(2, 4, #jobs == 0 and "No jobs to show." or ("JOBS  " .. #jobs), colors.lightBlue)
    local first = (page - 1) * perPage + 1
    local last = math.min(#jobs, first + perPage - 1)
    local clickableRows = {}
    for index = first, last do
        local job = jobs[index]
        local y = 5 + (index - first) * 4
        local status = showStatus and (job.status:upper() .. "  ") or ""
        writeAt(2, y, "#" .. job.id .. "  " .. status .. job.title, colors.yellow)
        writeAt(4, y + 1, "BY " .. (job.posterName or "Unknown") .. "  |  REWARD: " .. job.reward, colors.lime)
        writeAt(4, y + 2, job.description, colors.white)
        local detail = job.submission and ("SUBMITTED: " .. job.submission)
            or job.reviewNote and ("REVISION: " .. job.reviewNote)
            or job.claimantName and ("WORKER: " .. job.claimantName) or ""
        if detail ~= "" then writeAt(4, y + 3, detail, colors.lightGray) end
        table.insert(clickableRows, { job = job, top = y, bottom = y + 3, left = 1, right = term.getSize() })
    end
    writeAt(2, height - 3, "PAGE " .. page .. " / " .. pageCount, colors.lightGray)
    return page, pageCount, clickableRows
end

local function postJob()
    drawHeader("POST A JOB", "DESCRIBE THE WORK AND AGREED REWARD")
    local title = readText("Job title (3-40 characters)")
    local description = readText("Work details (5-180 characters)")
    local reward = readText("Reward, e.g. 2 diamonds or $5.00")
    local response, err = request({
        type = "create_job",
        name = playerName,
        title = title,
        description = description,
        reward = reward,
    })
    if not response then return showNotice("JOB NOT POSTED", err) end
    showNotice("JOB POSTED", "Job #" .. response.job.id .. " is on the board.")
end

local function claimJob(job)
    local response, err = request({ type = "claim_job", jobId = job.id, name = playerName })
    if not response then return showNotice("JOB NOT CLAIMED", err) end
    showNotice("JOB CLAIMED", "You are assigned to: " .. response.job.title)
end

local showJobDetails

local function browseJobs()
    local page = 1
    while true do
        local response, err = request({ type = "list_jobs" })
        if not response then return showNotice("BOARD UNAVAILABLE", err) end
        local jobs = response.jobs or {}
        local shownPage, pageCount, rows = drawJobs("JOB BOARD", "OPEN WORK  /  CLICK A JOB TO VIEW IT", jobs, page)
        page = shownPage
        local buttons = drawButtons({
            { id = "back", label = "BACK", key = keys.backspace },
            { id = "previous", label = "PREVIOUS", key = keys.left },
            { id = "next", label = "NEXT", key = keys.right },
            { id = "refresh", label = "REFRESH", key = keys.r },
        })
        local choice, selectedJob = waitForAction(buttons, rows)
        if choice == "job" then
            showJobDetails(selectedJob, true)
        elseif choice == "next" then
            page = math.min(page + 1, pageCount)
        elseif choice == "previous" then
            page = math.max(page - 1, 1)
        elseif choice == "refresh" then
            page = 1
        elseif choice == "back" then
            return
        end
    end
end

showJobDetails = function(job, fromBoard)
    drawHeader("JOB #" .. job.id .. "  /  " .. job.status:upper(), job.title)
    writeAt(2, 5, "POSTED BY  " .. (job.posterName or "Unknown"), colors.lightGray)
    writeAt(2, 6, "REWARD  " .. job.reward, colors.lime)
    writeAt(2, 8, job.description, colors.white)
    if job.submission then writeAt(2, 10, "SUBMISSION  " .. job.submission, colors.yellow) end
    if job.reviewNote then writeAt(2, 11, "REVISION  " .. job.reviewNote, colors.orange) end

    local isPoster = job.posterId == os.getComputerID()
    local isWorker = job.claimantId == os.getComputerID()
    local options = {}
    if isPoster and job.status == "review" then
        table.insert(options, { id = "approve", label = "APPROVE", key = keys.a })
        table.insert(options, { id = "revise", label = "REQUEST REVISION", key = keys.r })
    elseif isPoster and (job.status == "open" or job.status == "claimed") then
        table.insert(options, { id = "cancel", label = "CANCEL JOB", key = keys.x })
    elseif isWorker and job.status == "claimed" then
        table.insert(options, { id = "submit", label = "SUBMIT WORK", key = keys.s })
        table.insert(options, { id = "withdraw", label = "WITHDRAW", key = keys.w })
    elseif isWorker and job.status == "review" then
        writeAt(2, 13, "Waiting for the poster to review your work.", colors.lightGray)
    elseif fromBoard and job.status == "open" and not isPoster then
        table.insert(options, { id = "claim", label = "CLAIM JOB", key = keys.c })
    end
    table.insert(options, { id = "back", label = "BACK", key = keys.backspace })
    local buttons = drawButtons(options)
    local choice = waitForAction(buttons)

    if choice == "claim" then
        claimJob(job)
    elseif choice == "approve" then
        local response, err = request({ type = "approve_job", jobId = job.id })
        showNotice(response and "WORK APPROVED" or "APPROVAL FAILED",
            response and "Job #" .. job.id .. " is complete. Arrange the reward with the worker." or err)
    elseif choice == "revise" then
        local note = readText("What needs to be revised? (up to 120 characters)")
        local response, err = request({ type = "revise_job", jobId = job.id, note = note })
        showNotice(response and "REVISION REQUESTED" or "REQUEST FAILED",
            response and "The worker can update and resubmit." or err)
    elseif choice == "cancel" and confirm("CANCEL JOB", "Cancel job #" .. job.id .. "?") then
        local response, err = request({ type = "cancel_job", jobId = job.id })
        showNotice(response and "JOB CANCELLED" or "CANCEL FAILED",
            response and "Job #" .. job.id .. " was cancelled." or err)
    elseif choice == "submit" then
        local submission = readText("Describe the completed work (5-180 characters)")
        local response, err = request({ type = "submit_job", jobId = job.id, submission = submission })
        showNotice(response and "SENT FOR REVIEW" or "SUBMISSION FAILED",
            response and "The poster can now review your work." or err)
    elseif choice == "withdraw" and confirm("WITHDRAW CLAIM", "Return this job to the open board?") then
        local response, err = request({ type = "withdraw_claim", jobId = job.id })
        showNotice(response and "CLAIM WITHDRAWN" or "WITHDRAWAL FAILED",
            response and "The job is open for another worker." or err)
    end
end

local function myJobs()
    local page = 1
    while true do
        local response, err = request({ type = "my_jobs" })
        if not response then return showNotice("JOBS UNAVAILABLE", err) end
        local jobs = response.jobs or {}
        local shownPage, pageCount, rows = drawJobs("MY JOBS", "CLICK A JOB TO VIEW ITS STATUS OR ACTIONS", jobs, page, true)
        page = shownPage
        local buttons = drawButtons({
            { id = "back", label = "BACK", key = keys.backspace },
            { id = "previous", label = "PREVIOUS", key = keys.left },
            { id = "next", label = "NEXT", key = keys.right },
            { id = "refresh", label = "REFRESH", key = keys.r },
        })
        local choice, selectedJob = waitForAction(buttons, rows)
        if choice == "job" then
            showJobDetails(selectedJob, false)
        elseif choice == "next" then
            page = math.min(page + 1, pageCount)
        elseif choice == "previous" then
            page = math.max(page - 1, 1)
        elseif choice == "refresh" then
            page = 1
        elseif choice == "back" then
            return
        end
    end
end

openModems()
loadProfile()

while true do
    drawHeader("RIFT JOBS", "PLAYER CONTRACTS  /  SIGNED IN AS " .. playerName:upper())
    writeAt(2, 5, "Post work, pick up a contract, and track your jobs.", colors.white)
    local buttons = drawButtons({
        { id = "post", label = "POST A JOB", key = keys.p },
        { id = "board", label = "BROWSE JOBS", key = keys.b },
        { id = "mine", label = "MY JOBS", key = keys.m },
        { id = "name", label = "CHANGE NAME", key = keys.n },
        { id = "quit", label = "QUIT", key = keys.q },
    })
    local choice = waitForAction(buttons)
    if choice == "post" then
        postJob()
    elseif choice == "board" then
        browseJobs()
    elseif choice == "mine" then
        myJobs()
    elseif choice == "name" then
        local newName = readText("Your display name (up to 24 characters)"):match("^%s*(.-)%s*$")
        if newName ~= "" then
            playerName = newName:sub(1, 24)
            local file = fs.open(PROFILE_FILE, "w")
            if file then file.write(playerName); file.close() end
        end
    elseif choice == "quit" then
        break
    end
end