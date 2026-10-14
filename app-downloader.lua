local OWNER_REPO = "ZeroCreates/The-Repo"
local BRANCH = "main"
local RAW_BASE_URL = "https://raw.githubusercontent.com/" .. OWNER_REPO .. "/" .. BRANCH .. "/"
local CATALOG_PATH = "app-catalog.json"
local USER_ROOT = "/users/"
local SYSTEM_DIRECTORY = "/.launcher"
local CACHE_DIRECTORY = SYSTEM_DIRECTORY .. "/cache"
local homeDirectory = USER_ROOT .. "default"
local appDirectory = homeDirectory .. "/apps"
local username = "default"
local APP_NAMES_PATH = SYSTEM_DIRECTORY .. "/app-catalog-names.json"
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Loading app catalog from GitHub..."
local themeIndex = 1
local themes = {
    { accent = colors.cyan, highlight = colors.blue },
    { accent = colors.lime, highlight = colors.green },
    { accent = colors.orange, highlight = colors.red },
    { accent = colors.purple, highlight = colors.magenta },
}

local function loadTheme()
    local path = SYSTEM_DIRECTORY .. "/settings.json"
    if not fs.exists(path) then return end
    local file = fs.open(path, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    if ok and type(saved) == "table"
        and type(saved.theme) == "number" and themes[saved.theme] then
        themeIndex = saved.theme
    end
end

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
    contents = contents:gsub("^\239\187\191", "")
    if not textutils or type(textutils.unserializeJSON) ~= "function" then
        return nil, "This ComputerCraft version does not support JSON parsing."
    end
    local ok, entries = pcall(textutils.unserializeJSON, contents)
    if not ok then
        return nil, "Could not parse " .. CATALOG_PATH .. ": " .. tostring(entries)
    end
    if type(entries) ~= "table" then
        return nil, CATALOG_PATH .. " must contain a JSON array of apps."
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
    return math.max(1, height - 6)
end

local function draw()
    local width, height = term.getSize()
    local theme = themes[themeIndex]
    local accent = term.isColor() and theme.accent or colors.gray
    local highlight = term.isColor() and theme.highlight or colors.gray
    local visibleRows = visibleAppRows(height)
    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + visibleRows then
        firstVisible = selected - visibleRows + 1
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(accent)
    term.write((" " .. "COMPUTERCRAFT APP DOWNLOADER"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 2)
    term.setTextColor(colors.lightGray)
    term.write("Apps from " .. OWNER_REPO)

    local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
    for index = firstVisible, lastVisible do
        local row = index - firstVisible + 3
        term.setCursorPos(2, row)
        if index == selected then
            term.setBackgroundColor(highlight)
            term.setTextColor(colors.white)
            term.write(("> " .. apps[index].name):sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(colors.black)
        else
            term.setTextColor(colors.white)
            term.write(("  " .. apps[index].name):sub(1, math.max(0, width - 2)))
        end
    end

    term.setCursorPos(2, height - 3)
    term.setTextColor(colors.lightGray)
    local description = apps[selected] and apps[selected].description or "No apps available."
    term.write(description:sub(1, math.max(0, width - 2)))
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

local function saveCatalogName(fileName, appName)
    local names = {}
    if fs.exists(APP_NAMES_PATH) then
        local file = fs.open(APP_NAMES_PATH, "r")
        if not file then return false, "Could not read " .. APP_NAMES_PATH .. "." end
        local contents = file.readAll()
        file.close()
        local ok, storedNames = pcall(textutils.unserializeJSON, contents)
        if not ok or type(storedNames) ~= "table" then
            return false, "Could not parse " .. APP_NAMES_PATH .. "."
        end
        names = storedNames
    end
    names[fileName] = appName

    local temporary = APP_NAMES_PATH .. ".tmp"
    local backup = APP_NAMES_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(textutils.serializeJSON(names))
    file.close()

    if fs.exists(APP_NAMES_PATH) then fs.move(APP_NAMES_PATH, backup) end
    local ok, moveError = pcall(fs.move, temporary, APP_NAMES_PATH)
    if not ok then
        if fs.exists(APP_NAMES_PATH) then fs.delete(APP_NAMES_PATH) end
        if fs.exists(backup) then fs.move(backup, APP_NAMES_PATH) end
        return false, tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function setHomeDirectory(path)
    if path == nil then path = USER_ROOT .. "default" end
    if type(path) ~= "string" then
        return false, "Invalid user directory. Expected /users/<username>."
    end
    local normalizedPath = path:gsub("^/+", "")
    username = normalizedPath:match("^users/([%w_-]+)$")
    if not username then
        return false, "Invalid user directory. Expected /users/<username>."
    end
    homeDirectory = "/users/" .. username
    appDirectory = homeDirectory .. "/apps"
    APP_NAMES_PATH = SYSTEM_DIRECTORY .. "/app-catalog-names.json"
    fs.makeDir(SYSTEM_DIRECTORY)
    fs.makeDir(CACHE_DIRECTORY)
    local legacyNamesPath = homeDirectory .. "/.app-catalog-names.json"
    if fs.exists(legacyNamesPath) then
        local legacyFile = fs.open(legacyNamesPath, "r")
        if legacyFile then
            local contents = legacyFile.readAll()
            legacyFile.close()
            local ok, legacyNames = pcall(textutils.unserializeJSON, contents)
            if ok and type(legacyNames) == "table" then
                local currentNames = {}
                if fs.exists(APP_NAMES_PATH) then
                    local currentFile = fs.open(APP_NAMES_PATH, "r")
                    if currentFile then
                        local currentContents = currentFile.readAll()
                        currentFile.close()
                        local currentOk, decoded = pcall(textutils.unserializeJSON, currentContents)
                        if currentOk and type(decoded) == "table" then currentNames = decoded end
                    end
                end
                for fileName, appName in pairs(legacyNames) do
                    if type(fileName) == "string" and type(appName) == "string"
                        and currentNames[fileName] == nil then
                        currentNames[fileName] = appName
                    end
                end
                local temporary = APP_NAMES_PATH .. ".tmp"
                local backup = APP_NAMES_PATH .. ".bak"
                if fs.exists(temporary) then fs.delete(temporary) end
                if fs.exists(backup) then fs.delete(backup) end
                local output = fs.open(temporary, "w")
                if output then
                    output.write(textutils.serializeJSON(currentNames))
                    output.close()
                    if fs.exists(APP_NAMES_PATH) then
                        local backedUp = pcall(fs.move, APP_NAMES_PATH, backup)
                        if not backedUp then
                            fs.delete(temporary)
                            return true
                        end
                    end
                    local moved = pcall(fs.move, temporary, APP_NAMES_PATH)
                    if moved then
                        if fs.exists(backup) then fs.delete(backup) end
                        fs.delete(legacyNamesPath)
                    else
                        if fs.exists(backup) then fs.move(backup, APP_NAMES_PATH) end
                    end
                end
            end
        end
    end
    fs.makeDir(homeDirectory)
    fs.makeDir(appDirectory)
    return true
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

    local destination = fs.combine(appDirectory, app.file)
    if not confirmOverwrite(destination) then
        message = "Download cancelled."
        return
    end

    local cacheUserDirectory = fs.combine(CACHE_DIRECTORY, username)
    fs.makeDir(cacheUserDirectory)
    local temporary = fs.combine(cacheUserDirectory, app.file .. ".download-tmp")
    local backup = fs.combine(cacheUserDirectory, app.file .. ".download-bak")
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
    local nameSaved, nameError = saveCatalogName(fs.getName(destination), app.name)
    if not nameSaved then
        message = app.name .. " installed, but its catalog name could not be saved: " .. nameError
        return
    end
    message = app.name .. " downloaded as " .. destination .. "."
end

local mode, target, requestedHome = ...
if mode ~= "update" then
    requestedHome = mode
    mode = nil
end
local homeOk, homeError = setHomeDirectory(requestedHome)
if not homeOk then
    printError(homeError)
    return
end
loadTheme()
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
        local index = firstVisible + y - 3
        if y >= 3 and y < 3 + visibleAppRows(height)
            and index >= firstVisible and index <= #apps then
            local wasSelected = selected == index
            selected = index
            if key == 1 and wasSelected then downloadApp(apps[selected]) end
        end
    end
end
