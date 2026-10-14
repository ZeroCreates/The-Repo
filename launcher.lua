local LAUNCHER_NAME = "launcher.lua"
local DOWNLOADER_PATH = "/app-downloader.lua"
local REPOSITORY_BASE_URL = "https://raw.githubusercontent.com/ZeroCreates/The-Repo/main/"
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Select a program to launch."
local shiftDown = false

local preferredApps = {
    { path = "app-downloader.lua", name = "App Downloader" },
}

local function isLuaFile(path)
    return not fs.isDir(path) and path:lower():match("%.lua$") ~= nil
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

local function refreshApps()
    local available = {}
    for _, app in ipairs(preferredApps) do
        local rootPath = "/" .. app.path
        if fs.exists(rootPath) and isLuaFile(rootPath) then
            table.insert(available, { path = rootPath, name = app.name })
            available[app.path] = true
        end
    end

    local otherPaths = {}
    for _, path in ipairs(fs.list("/")) do
        if path ~= LAUNCHER_NAME and path ~= "startup.lua"
            and isLuaFile("/" .. path) and not available[path] then
            table.insert(otherPaths, path)
        end
    end
    table.sort(otherPaths, function(first, second)
        return first:lower() < second:lower()
    end)
    for _, path in ipairs(otherPaths) do
        table.insert(available, { path = "/" .. path, name = displayName(path) })
    end
    apps = available
    if #apps == 0 then
        selected = 1
        firstVisible = 1
        message = "No Lua programs found in the computer's root directory."
        return
    end
    selected = math.min(selected, #apps)
end

local function draw()
    local width, height = term.getSize()
    local isColor = term.isColor()
    local textColor = colors.white
    local backgroundColor = colors.black
    local highlightColor = isColor and colors.blue or colors.gray
    local mutedColor = isColor and colors.lightGray or colors.white
    local titleColor = isColor and colors.cyan or colors.gray
    local visibleRows = math.max(1, height - 6)

    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + visibleRows then
        firstVisible = selected - visibleRows + 1
    end

    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(titleColor)
    term.write((" " .. "COMPUTERCRAFT LAUNCHER"):sub(1, width))
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(2, 2)
    term.setTextColor(mutedColor)
    term.write("Choose an installed program")

    local lastVisible = math.min(#apps, firstVisible + visibleRows - 1)
    for index = firstVisible, lastVisible do
        local row = index - firstVisible + 3
        term.setCursorPos(2, row)
        if index == selected then
            term.setBackgroundColor(highlightColor)
            term.setTextColor(textColor)
            term.write(("> " .. apps[index].name):sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(backgroundColor)
        else
            term.setTextColor(textColor)
            term.write(("  " .. apps[index].name):sub(1, math.max(0, width - 2)))
        end
    end

    term.setCursorPos(2, height - 2)
    term.setTextColor(mutedColor)
    term.write(message:sub(1, math.max(0, width - 2)))
    term.setCursorPos(2, height)
    term.write(("ENTER run  SHIFT+CLICK update  R refresh"):sub(1, math.max(0, width - 1)))
    term.setBackgroundColor(backgroundColor)
    term.setTextColor(textColor)
end

local function waitForReturn()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    print("")
    print("Press any key to return to the launcher.")
    while true do
        local event = os.pullEventRaw()
        if event == "key" or event == "mouse_click" then return end
    end
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
    local ok, result = pcall(shell.run, DOWNLOADER_PATH, "update", app.path:gsub("^/", ""))
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

    local ok, result = pcall(shell.run, app.path)
    if not ok then
        printError("Program error: " .. tostring(result))
    elseif result == false then
        printError("The program reported that it did not complete successfully.")
    end
    waitForReturn()
    message = "Returned from " .. app.name .. "."
end

local downloaded, downloadMessage = installDownloader()
refreshApps()
if downloaded then
    message = "App downloader is ready."
else
    message = downloadMessage
end

while true do
    draw()
    local event, first, second, y = os.pullEventRaw()
    if event == "key" then
        if first == keys.leftShift or first == keys.rightShift then
            shiftDown = true
        end
        if first == keys.up then
            if #apps > 0 then selected = math.max(1, selected - 1) end
        elseif first == keys.down then
            if #apps > 0 then selected = math.min(#apps, selected + 1) end
        elseif first == keys.enter then
            launchSelected()
        elseif first == keys.r then
            refreshApps()
            message = "Program list refreshed."
        elseif first == keys.d and not fs.exists(DOWNLOADER_PATH) then
            local ok, err = installDownloader()
            refreshApps()
            message = ok and "App downloader is ready." or err
        end
    elseif event == "key_up" then
        if first == keys.leftShift or first == keys.rightShift then
            shiftDown = false
        end
    elseif event == "mouse_click" then
        local _, screenHeight = term.getSize()
        local visibleRows = math.max(1, screenHeight - 6)
        local clickedIndex = firstVisible + y - 3
        if y >= 3 and y < 3 + visibleRows
            and clickedIndex >= firstVisible and clickedIndex <= #apps then
            local wasSelected = selected == clickedIndex
            selected = clickedIndex
            if first == 1 then
                if shiftDown then
                    updateSelected()
                elseif wasSelected then
                    launchSelected()
                end
            end
        end
    end
end
