local OWNER_REPO = "ZeroCreates/The-Repo"
local BRANCH = "main"
local RAW_BASE_URL = "https://raw.githubusercontent.com/" .. OWNER_REPO .. "/" .. BRANCH .. "/"
local CATALOG_PATH = "app-catalog.json"
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Loading app catalog from GitHub..."

local function request(url)
    local ok, response, requestError = pcall(http.get, url, {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "ComputerCraft-App-Downloader",
    })
    if not ok then return nil, tostring(response) end
    if not response then return nil, tostring(requestError or "HTTP request failed.") end
    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        return nil, "GitHub returned HTTP " .. responseCode .. "."
    end
    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then return nil, "GitHub returned an empty response." end
    return contents
end

local function loadCatalog()
    if not http or not http.get then
        return nil, "Enable the ComputerCraft HTTP API to load apps from GitHub."
    end

    local contents, err = request(RAW_BASE_URL .. CATALOG_PATH)
    if not contents then return nil, err end
    local ok, entries = pcall(textutils.unserializeJSON, contents)
    if not ok or type(entries) ~= "table" then
        return nil, "Could not parse " .. CATALOG_PATH .. "."
    end

    local catalog, seenFiles = {}, {}
    for _, entry in ipairs(entries) do
        if type(entry) ~= "table" or type(entry.name) ~= "string"
            or type(entry.source) ~= "string" or type(entry.file) ~= "string"
            or type(entry.description) ~= "string"
            or entry.name == "" or entry.description == ""
            or not entry.file:match("^[%w][%w_.%-]*%.lua$")
            or not entry.source:match("^[%w_./%-]+%.lua$")
            or entry.source:find("..", 1, true)
            or seenFiles[entry.file] then
            return nil, "Invalid app entry in " .. CATALOG_PATH .. "."
        end
        table.insert(catalog, entry)
        seenFiles[entry.file] = true
    end
    for key in pairs(entries) do
        if type(key) ~= "number" or key < 1 or key > #catalog or key % 1 ~= 0 then
            return nil, CATALOG_PATH .. " must contain a JSON array of apps."
        end
    end

    table.sort(catalog, function(first, second)
        return first.name:lower() < second.name:lower()
    end)
    return catalog
end

local function visibleAppRows(height)
    return math.max(1, math.floor((height - 6) / 2))
end

local function draw()
    local width, height = term.getSize()
    local visibleRows = visibleAppRows(height)
    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + visibleRows then
        firstVisible = selected - visibleRows + 1
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(term.isColor() and colors.cyan or colors.gray)
    term.write((" " .. "COMPUTERCRAFT APP DOWNLOADER"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 2)
    term.setTextColor(colors.lightGray)
    term.write("Apps from " .. OWNER_REPO)

    local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
    for index = firstVisible, lastVisible do
        local row = (index - firstVisible) * 2 + 3
        term.setCursorPos(2, row)
        if index == selected then
            term.setBackgroundColor(term.isColor() and colors.blue or colors.gray)
            term.setTextColor(colors.white)
            term.write(("> " .. apps[index].name):sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(colors.black)
        else
            term.setTextColor(colors.white)
            term.write(("  " .. apps[index].name):sub(1, math.max(0, width - 2)))
        end
        term.setCursorPos(4, row + 1)
        term.setTextColor(colors.lightGray)
        term.write(apps[index].description:sub(1, math.max(0, width - 4)))
    end

    term.setCursorPos(2, height - 2)
    term.setTextColor(colors.yellow)
    term.write(message:sub(1, math.max(0, width - 2)))
    term.setCursorPos(2, height)
    term.setTextColor(colors.white)
    term.write("UP/DOWN select  ENTER download  R refresh  Q quit")
    term.setBackgroundColor(colors.black)
end

local function confirmOverwrite(file)
    if not fs.exists(file) then return true end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print(file .. " already exists.")
    print("Replace it with the repository version? [y/N]")
    while true do
        local event, value = os.pullEventRaw()
        if event == "char" then
            local answer = value:lower()
            if answer == "y" then return true end
            if answer == "n" then return false end
        elseif event == "key" and (value == keys.enter or value == keys.escape) then
            return false
        end
    end
end

local function downloadApp(app)
    if not app then
        message = "There are no apps available to download."
        return
    end
    if not http or not http.get then
        message = "Enable the ComputerCraft HTTP API to download apps."
        return
    end

    local contents, err = request(RAW_BASE_URL .. app.source)
    if not contents then
        message = "Download failed: " .. err
        return
    end

    local destination = app.file
    if not confirmOverwrite(destination) then
        message = "Download cancelled."
        return
    end

    local temporary = destination .. ".download-tmp"
    local backup = destination .. ".download-bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        message = "Download failed: could not create " .. temporary .. "."
        return
    end
    file.write(contents)
    file.close()

    if fs.exists(destination) then fs.move(destination, backup) end
    local ok, moveError = pcall(fs.move, temporary, destination)
    if not ok then
        if fs.exists(destination) then fs.delete(destination) end
        if fs.exists(backup) then fs.move(backup, destination) end
        message = "Install failed: " .. tostring(moveError)
        return
    end
    if fs.exists(backup) then fs.delete(backup) end
    message = app.name .. " downloaded as " .. destination .. "."
end

local mode, target = ...
local catalog, catalogError = loadCatalog()
if not catalog then
    if mode == "update" then
        printError(catalogError)
        return
    end
    apps = {}
    message = catalogError
else
    apps = catalog
    message = "Loaded " .. #apps .. " app(s) from GitHub."
end

if mode == "update" then
    for _, app in ipairs(apps) do
        if app.file == target then
            downloadApp(app)
            print(message)
            return
        end
    end
    printError("This app is not in the online app catalog: " .. tostring(target))
    return
end

while true do
    draw()
    local event, key, _, y = os.pullEventRaw()
    if event == "key" then
        if key == keys.up then
            selected = math.max(1, selected - 1)
        elseif key == keys.down then
            selected = math.min(#apps, selected + 1)
        elseif key == keys.enter then
            downloadApp(apps[selected])
        elseif key == keys.r then
            local refreshed, refreshError = loadCatalog()
            if refreshed then
                apps = refreshed
                selected = math.min(selected, math.max(1, #apps))
                firstVisible = 1
                message = "Loaded " .. #apps .. " app(s) from GitHub."
            else
                message = refreshError
            end
        elseif key == keys.q or key == keys.escape then
            return
        end
    elseif event == "mouse_click" then
        local _, height = term.getSize()
        local visibleRows = visibleAppRows(height)
        local index = firstVisible + math.floor((y - 3) / 2)
        if y >= 3 and y < 3 + visibleRows * 2
            and index >= firstVisible and index <= #apps then
            selected = index
            if key == 1 then downloadApp(apps[selected]) end
        end
    end
end
