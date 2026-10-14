local LAUNCHER_NAME = "launcher.lua"
local DOWNLOADER_PATH = "/app-downloader.lua"
local REPOSITORY_BASE_URL = "https://raw.githubusercontent.com/ZeroCreates/The-Repo/main/"
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Select a program to launch."
local shiftDown = false
local screen = "apps"
local selectedSetting = 1
local currentUser
local homeDirectory
local USER_ROOT = "/users"
local SYSTEM_DIRECTORY = "/.launcher"
local SETTINGS_PATH = SYSTEM_DIRECTORY .. "/settings.json"
local LEGACY_SETTINGS_PATH = "/.launcher-settings.json"
local THEMES = {
    { name = "Ocean", accent = colors.cyan, highlight = colors.blue },
    { name = "Forest", accent = colors.lime, highlight = colors.green },
    { name = "Sunset", accent = colors.orange, highlight = colors.red },
    { name = "Violet", accent = colors.purple, highlight = colors.magenta },
}
local settings = {
    theme = 1,
    showPath = true,
    alphabetical = true,
}

local preferredApps = {
    { path = "app-downloader.lua", name = "App Downloader" },
}

local function isLuaFile(path)
    return not fs.isDir(path) and path:lower():match("%.lua$") ~= nil
end

local function loadSettings()
    local path = fs.exists(SETTINGS_PATH) and SETTINGS_PATH or LEGACY_SETTINGS_PATH
    if not fs.exists(path) then return end
    local file = fs.open(path, "r")
    if not file then
        message = "Could not read launcher settings."
        return
    end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    if not ok or type(saved) ~= "table" then
        message = "Launcher settings are invalid; using defaults."
        return
    end
    if type(saved.theme) == "number" and THEMES[saved.theme] then
        settings.theme = saved.theme
    end
    if type(saved.showPath) == "boolean" then settings.showPath = saved.showPath end
    if type(saved.alphabetical) == "boolean" then settings.alphabetical = saved.alphabetical end
end

local function saveSettings()
    fs.makeDir(SYSTEM_DIRECTORY)
    local temporary = SETTINGS_PATH .. ".tmp"
    local backup = SETTINGS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        message = "Could not save launcher settings."
        return false
    end
    file.write(textutils.serializeJSON(settings))
    file.close()
    if fs.exists(SETTINGS_PATH) then
        local backedUp, backupError = pcall(fs.move, SETTINGS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            message = "Could not back up launcher settings: " .. tostring(backupError)
            return false
        end
    end
    local ok, err = pcall(fs.move, temporary, SETTINGS_PATH)
    if not ok then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, SETTINGS_PATH) end
        message = "Could not save launcher settings: " .. tostring(err)
        return false
    end
    if fs.exists(backup) then fs.delete(backup) end
    message = "Settings saved."
    return true
end

local function installDownloader()
    if fs.exists(DOWNLOADER_PATH) then return true end
    if not http or not http.get then
        return false, "Enable the ComputerCraft HTTP API to download the app downloader."
    end

    local ok, response, requestError = pcall(http.get, REPOSITORY_BASE_URL .. "app-downloader.lua")
    if not ok then return false, "Downloader request failed: " .. tostring(response) end
    if not response then
        return false, "Downloader request failed: " .. tostring(requestError or "HTTP request failed.")
    end

    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        return false, "Downloader request failed: GitHub returned HTTP " .. responseCode .. "."
    end

    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then
        return false, "Downloader download failed: the file was empty."
    end

    local temporary = DOWNLOADER_PATH .. ".download-tmp"
    if fs.exists(temporary) then fs.delete(temporary) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(contents)
    file.close()

    local moved, moveError = pcall(fs.move, temporary, DOWNLOADER_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not install the app downloader: " .. tostring(moveError)
    end
    return true
end

local function displayName(path)
    local name = path:gsub("%.lua$", ""):gsub("[_%-]", " ")
    return name:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)
end

local function chooseUser()
    fs.makeDir(USER_ROOT)
    local userSelected = 1
    local userFirstVisible = 1

    local function createProfile()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        write("New username: ")
        local username = read()
        if not username or not username:match("^[%w_-]+$") then
            message = "Use only letters, numbers, underscores, and hyphens."
            return false
        end
        local path = fs.combine(USER_ROOT, username)
        if fs.exists(path) then
            message = "That profile already exists. Select it from the list."
            return false
        end
        currentUser = username
        homeDirectory = path
        fs.makeDir(homeDirectory)
        return true
    end

    while true do
        local users = {}
        for _, entry in ipairs(fs.list(USER_ROOT)) do
            if fs.isDir(fs.combine(USER_ROOT, entry)) and entry:match("^[%w_-]+$") then
                table.insert(users, entry)
            end
        end
        table.sort(users, function(first, second) return first:lower() < second:lower() end)
        local createIndex = #users + 1
        local optionCount = createIndex
        local visibleRows = math.max(1, select(2, term.getSize()) - 5)
        if userSelected < 1 or userSelected > optionCount then userSelected = 1 end
        if userSelected < userFirstVisible then userFirstVisible = userSelected end
        if userSelected >= userFirstVisible + visibleRows then
            userFirstVisible = userSelected - visibleRows + 1
        end

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("COMPUTERCRAFT USER PROFILES")
        term.setTextColor(colors.lightGray)
        print("Select a profile, or choose Create Profile.")
        print("Profiles have no password and are not security-isolated.")
        local width, height = term.getSize()
        local lastVisible = math.min(optionCount, userFirstVisible + visibleRows - 1)
        for index = userFirstVisible, lastVisible do
            term.setCursorPos(2, index - userFirstVisible + 4)
            local label = index == createIndex and "+ Create Profile" or users[index]
            if index == userSelected then
                term.setBackgroundColor(colors.blue)
                term.setTextColor(colors.white)
                term.write(("> " .. label):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.setTextColor(index == createIndex and colors.lime or colors.white)
                term.write(("  " .. label):sub(1, math.max(0, width - 2)))
            end
        end
        term.setCursorPos(2, height)
        term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
        term.setTextColor(colors.white)
        term.write((currentUser and "[CANCEL]" or ""))
        term.setCursorPos(math.floor(width / 2) + 1, height)
        term.write("[CREATE PROFILE]")
        term.setBackgroundColor(colors.black)

        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 then
            local index = userFirstVisible + y - 4
            if y >= 4 and y < 4 + visibleRows and index >= userFirstVisible and index <= optionCount then
                local wasSelected = userSelected == index
                userSelected = index
                if userSelected == createIndex then
                    if createProfile() then return true end
                elseif wasSelected then
                    currentUser = users[userSelected]
                    homeDirectory = fs.combine(USER_ROOT, currentUser)
                    return true
                end
            elseif y == height then
                if x <= math.floor(width / 2) and currentUser then
                    return false
                elseif x > math.floor(width / 2) then
                    if createProfile() then return true end
                end
            end
        end
    end
end

local function loadCatalogNames()
    local path = SYSTEM_DIRECTORY .. "/app-catalog-names.json"
    local names = {}
    if fs.exists(path) then
        local file = fs.open(path, "r")
        if not file then
            message = "Could not read the system app catalog names."
            return names
        end
        local contents = file.readAll()
        file.close()
        local ok, saved = pcall(textutils.unserializeJSON, contents)
        if not ok or type(saved) ~= "table" then
            message = "System app catalog names are invalid."
            return names
        end
        names = saved
    end

    local legacyPath = fs.combine(homeDirectory, ".app-catalog-names.json")
    if fs.exists(legacyPath) then
        local file = fs.open(legacyPath, "r")
        if file then
            local contents = file.readAll()
            file.close()
            local ok, legacyNames = pcall(textutils.unserializeJSON, contents)
            if ok and type(legacyNames) == "table" then
                for fileName, appName in pairs(legacyNames) do
                    if type(fileName) == "string" and type(appName) == "string"
                        and names[fileName] == nil then
                        names[fileName] = appName
                    end
                end
                fs.makeDir(SYSTEM_DIRECTORY)
                local temporary = path .. ".tmp"
                local backup = path .. ".bak"
                if fs.exists(temporary) then fs.delete(temporary) end
                if fs.exists(backup) then fs.delete(backup) end
                local output = fs.open(temporary, "w")
                if output then
                    output.write(textutils.serializeJSON(names))
                    output.close()
                    if fs.exists(path) then
                        local backedUp = pcall(fs.move, path, backup)
                        if not backedUp then
                            fs.delete(temporary)
                            message = "Could not migrate old app catalog names."
                            return names
                        end
                    end
                    local moved = pcall(fs.move, temporary, path)
                    if moved then
                        if fs.exists(backup) then fs.delete(backup) end
                        fs.delete(legacyPath)
                    else
                        if fs.exists(backup) then fs.move(backup, path) end
                        message = "Could not migrate old app catalog names."
                    end
                else
                    message = "Could not create system app catalog names."
                end
            else
                message = "Old app catalog names could not be parsed."
            end
        end
    end

    local validNames = {}
    for fileName, appName in pairs(names) do
        if type(fileName) == "string" and type(appName) == "string" and appName ~= "" then
            validNames[fileName] = appName
        end
    end
    return validNames
end

local function refreshApps()
    local available = {}
    local catalogNames = loadCatalogNames()
    for _, app in ipairs(preferredApps) do
        local rootPath = "/" .. app.path
        if fs.exists(rootPath) and isLuaFile(rootPath) then
            table.insert(available, {
                path = rootPath,
                name = catalogNames[app.path] or app.name,
            })
            available[app.path] = true
        end
    end

    local appDirectory = fs.combine(homeDirectory, "apps")
    fs.makeDir(appDirectory)

    local migrationErrors = {}
    for _, name in ipairs(fs.list(homeDirectory)) do
        local legacyPath = fs.combine(homeDirectory, name)
        if name ~= "apps" and name ~= "launcher.lua" and name ~= "app-downloader.lua"
            and isLuaFile(legacyPath) then
            local destination = fs.combine(appDirectory, name)
            if not fs.exists(destination) then
                local moved, moveError = pcall(fs.move, legacyPath, destination)
                if not moved then
                    table.insert(migrationErrors, name .. ": " .. tostring(moveError))
                end
            end
        end
    end

    local otherPaths = {}
    local function addAppsFrom(directory, includeLegacyRoot)
        for _, name in ipairs(fs.list(directory)) do
            local fullPath = fs.combine(directory, name)
            if isLuaFile(fullPath) and not available[fullPath]
                and (not includeLegacyRoot or name ~= "launcher.lua" and name ~= "app-downloader.lua"
                    and not fs.exists(fs.combine(appDirectory, name))) then
                table.insert(otherPaths, fullPath)
                available[fullPath] = true
            end
        end
    end
    addAppsFrom(appDirectory, false)
    addAppsFrom(homeDirectory, true)
    if settings.alphabetical then
        table.sort(otherPaths, function(first, second)
            return fs.getName(first):lower() < fs.getName(second):lower()
        end)
    end
    for _, path in ipairs(otherPaths) do
        local name = fs.getName(path)
        table.insert(available, {
            path = path,
            name = catalogNames[name] or displayName(name),
        })
    end
    if #migrationErrors > 0 then
        message = "Some old apps could not be moved: " .. table.concat(migrationErrors, "; ")
    end
    apps = available
    if #apps == 0 then
        selected = 1
        firstVisible = 1
        message = "No Lua programs found in " .. homeDirectory .. "."
        return
    end
    selected = math.min(selected, #apps)
end

local function drawButtons(buttons, row, width, isColor)
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local x = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - x + 1 or slotWidth
        term.setCursorPos(x, row)
        term.setBackgroundColor(isColor and colors.gray or colors.black)
        term.setTextColor(colors.white)
        term.write(("[" .. button.label .. "]"):sub(1, buttonWidth))
        button.left = x
        button.right = x + buttonWidth - 1
    end
end

local function buttonAt(buttons, x)
    for _, button in ipairs(buttons) do
        if x >= button.left and x <= button.right then return button.action end
    end
end

local function draw()
    local width, height = term.getSize()
    local isColor = term.isColor()
    local textColor = colors.white
    local backgroundColor = colors.black
    local theme = THEMES[settings.theme]
    local highlightColor = isColor and theme.highlight or colors.gray
    local mutedColor = isColor and colors.lightGray or colors.white
    local titleColor = isColor and theme.accent or colors.gray
    local visibleRows = math.max(1, height - 12)
    local firstButtons, secondButtons

    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + visibleRows then
        firstVisible = selected - visibleRows + 1
    end

    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(titleColor)
    term.write((" " .. "COMPUTERCRAFT LAUNCHER - " .. tostring(currentUser)):sub(1, width))
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(2, 2)
    term.setTextColor(mutedColor)
    term.write((screen == "apps" and "YOUR PROGRAMS" or "LAUNCHER CUSTOMISATION"):sub(1, math.max(0, width - 2)))

    if screen == "apps" then
        local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
        for index = firstVisible, lastVisible do
            local row = index - firstVisible + 4
            term.setCursorPos(2, row)
            if index == selected then
                term.setBackgroundColor(highlightColor)
                term.setTextColor(textColor)
                term.write(("  > " .. apps[index].name):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(backgroundColor)
            else
                term.setTextColor(textColor)
                term.write(("    " .. apps[index].name):sub(1, math.max(0, width - 2)))
            end
        end
        term.setCursorPos(2, height - 6)
        term.setTextColor(titleColor)
        local selectedApp = apps[selected]
        local detail = selectedApp and (settings.showPath and selectedApp.path or "Ready to launch") or "No programs found"
        term.write(detail:sub(1, math.max(0, width - 2)))
        firstButtons = {
            { label = "UPDATE", action = "update" },
            { label = "SETTINGS", action = "settings" },
        }
        secondButtons = {
            { label = "SWITCH USER", action = "user" },
            { label = "REFRESH", action = "refresh" },
        }
        drawButtons(firstButtons, height - 2, width, isColor)
        drawButtons(secondButtons, height - 1, width, isColor)
    else
        local options = {
            "Accent theme: " .. theme.name,
            "Show app file paths: " .. (settings.showPath and "On" or "Off"),
            "Sort programs alphabetically: " .. (settings.alphabetical and "On" or "Off"),
            "WIPE ENTIRE COMPUTER",
        }
        for index, option in ipairs(options) do
            local row = index + 4
            term.setCursorPos(2, row)
            if selectedSetting == index then
                term.setBackgroundColor(highlightColor)
                term.setTextColor(textColor)
                term.write(("  > " .. option):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(backgroundColor)
            else
                term.setTextColor(textColor)
                term.write(("    " .. option):sub(1, math.max(0, width - 2)))
            end
        end
        firstButtons = {}
        secondButtons = { { label = "BACK TO PROGRAMS", action = "back" } }
        drawButtons(secondButtons, height - 1, width, isColor)
    end

    term.setCursorPos(2, height - 4)
    term.setTextColor(mutedColor)
    term.write(message:sub(1, math.max(0, width - 2)))
    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
    return firstButtons, secondButtons
end

local function waitForReturn()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(1, 1)
    term.clear()
    print("")
    print("Exit the program and returning to the launcher.")
end

local function updateSelected()
    local app = apps[selected]
    if not app then
        message = "Select an available program first."
        return
    end

    if not fs.exists(DOWNLOADER_PATH) then
        local downloaded, downloadError = installDownloader()
        if not downloaded then
            message = downloadError
            return
        end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Opening the app downloader to update " .. app.name .. "...")
    local ok, result = pcall(os.run, _ENV, DOWNLOADER_PATH, "update", fs.getName(app.path), homeDirectory)
    if not ok then
        printError("Could not run the app downloader: " .. tostring(result))
    elseif result == false then
        printError("The app downloader did not complete successfully.")
    end
    waitForReturn()
    shiftDown = false
    refreshApps()
    message = "Returned from the app downloader."
end

local function launchSelected()
    local app = apps[selected]
    if not app then
        message = "Select an available program first."
        return
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Launching " .. app.name .. "...")

    local previousDirectory = shell.dir()
    shell.setDir(homeDirectory)
    local ok, result = pcall(os.run, _ENV, app.path, homeDirectory)
    shell.setDir(previousDirectory)
    if not ok then
        printError("Program error: " .. tostring(result))
    elseif result == false then
        printError("The program reported that it did not complete successfully.")
    end
    waitForReturn()
    message = "Returned from " .. app.name .. "."
    refreshApps()
end

local function changeSetting(direction)
    if selectedSetting == 1 then
        settings.theme = ((settings.theme - 1 + direction) % #THEMES) + 1
    elseif selectedSetting == 2 then
        settings.showPath = not settings.showPath
    elseif selectedSetting == 3 then
        settings.alphabetical = not settings.alphabetical
        refreshApps()
    end
    saveSettings()
end

local function uninstallLauncher()
    local width, height = term.getSize()
    local confirmationButtons = {
        { label = "CANCEL", action = false },
        { label = "WIPE COMPUTER", action = true },
    }
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.red)
    print("WIPE COMPUTER")
    term.setTextColor(colors.white)
    print("This permanently deletes every file and folder")
    print("on this computer, including all user profiles,")
    print("apps, settings, and startup files.")
    term.setTextColor(colors.yellow)
    print("")
    print("Click WIPE COMPUTER below to confirm.")
    drawButtons(confirmationButtons, height - 1, width, term.isColor())
    local confirmed = false
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 and y == height - 1 then
            for _, choice in ipairs(confirmationButtons) do
                if x >= choice.left and x <= choice.right then
                    confirmed = choice.action
                    break
                end
            end
            break
        end
    end
    if not confirmed then
        message = "Computer wipe cancelled."
        return
    end

    local failures = {}
    local rootEntries = fs.list("/")
    for _, entry in ipairs(rootEntries) do
        if entry:lower() ~= "rom" then
            local path = fs.combine("/", entry)
            local ok, err = pcall(fs.delete, path)
            if not ok or fs.exists(path) then
                table.insert(failures, path .. ": " .. tostring(err or "could not remove"))
            end
        end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    if #failures > 0 then
        term.setTextColor(colors.red)
        print("Computer wipe was incomplete:")
        for _, failure in ipairs(failures) do print(failure) end
        print("Some files or folders could not be removed.")
        waitForReturn()
        return
    end

    term.setTextColor(colors.lime)
    print("Computer filesystem wiped.")
    term.setTextColor(colors.white)
    print("The ROM folder was preserved.")
    print("Turn off or reboot the computer.")
    while true do os.pullEventRaw() end
end

local migrateLegacySettings = not fs.exists(SETTINGS_PATH) and fs.exists(LEGACY_SETTINGS_PATH)
loadSettings()
if migrateLegacySettings and saveSettings() then
    fs.delete(LEGACY_SETTINGS_PATH)
end
chooseUser()
local downloaded, downloadMessage = installDownloader()
refreshApps()
if downloaded then
    message = "App downloader is ready."
else
    message = downloadMessage
end

while true do
    local firstButtons, secondButtons = draw()
    local event, button, x, y = os.pullEventRaw()
    if event == "mouse_click" and button == 1 then
        local _, height = term.getSize()
        if screen == "apps" then
            local visibleRows = math.max(1, height - 12)
            local clickedIndex = firstVisible + y - 4
            if y >= 4 and y < 4 + visibleRows
                and clickedIndex >= firstVisible and clickedIndex <= #apps then
                local wasSelected = selected == clickedIndex
                selected = clickedIndex
                if wasSelected then launchSelected() end
            elseif y == height - 2 then
                local action = buttonAt(firstButtons, x)
                if action == "open" then
                    launchSelected()
                elseif action == "update" then
                    updateSelected()
                elseif action == "settings" then
                    screen = "settings"
                    message = "Click a setting to change it."
                end
            elseif y == height - 1 then
                local action = buttonAt(secondButtons, x)
                if action == "user" then
                    if chooseUser() then
                        selected = 1
                        firstVisible = 1
                        refreshApps()
                        message = "Switched to " .. currentUser .. "."
                    else
                        message = "Profile switch cancelled."
                    end
                elseif action == "refresh" then
                    refreshApps()
                    message = "Program list refreshed."
                elseif action == "exit" then
                    return
                end
            end
        elseif y >= 5 and y <= 8 then
            selectedSetting = y - 4
            if selectedSetting == 1 then
                local direction = x <= math.floor(select(1, term.getSize()) / 2) and -1 or 1
                changeSetting(direction)
            elseif selectedSetting == 2 or selectedSetting == 3 then
                changeSetting(1)
            elseif selectedSetting == 4 then
                uninstallLauncher()
            end
        elseif y == height - 1 and buttonAt(secondButtons, x) == "back" then
            screen = "apps"
            message = "Back to your programs."
        end
    end
end
