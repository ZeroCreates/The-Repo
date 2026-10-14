local LAUNCHER_NAME = "launcher.lua"
local SYSTEM_APP_DIRECTORY = "/.launcher/apps"
local DOWNLOADER_PATH = SYSTEM_APP_DIRECTORY .. "/app-downloader.lua"
local SYSTEM_FILE_BROWSER_PATH = SYSTEM_APP_DIRECTORY .. "/file-browser.lua"
local REPOSITORY_BASE_URL = "https://raw.githubusercontent.com/ZeroCreates/The-Repo/main/"
local nativeFs = fs
local nativeOs = os
local nativeRequire = require
local nativeTerm = term.current()
local nativeParallel = parallel
local nativeWindow = window
local apps = {}
local selected = 1
local firstVisible = 1
local message = "Select a program to launch."
local shiftDown = false
local screen = "apps"
local selectedSetting = 1
local notificationListenerPage = 1
local notificationHistory = {}
local currentUser
local homeDirectory
local notificationConfigRevision = 0
local apiNotificationQueue = {}
local profilePasswords = {}
local profileAdmins = {}
local authorizedProfiles = {}
local USER_ROOT = "/users"
local SYSTEM_DIRECTORY = "/.launcher"
local SETTINGS_PATH = SYSTEM_DIRECTORY .. "/settings.json"
local PROFILE_PASSWORDS_PATH = SYSTEM_DIRECTORY .. "/profile-passwords.json"
local PROFILE_ADMINS_PATH = SYSTEM_DIRECTORY .. "/profile-admins.json"
local LEGACY_SETTINGS_PATH = "/.launcher-settings.json"
local THEMES = {
    { name = "Ocean", accent = colors.cyan, highlight = colors.blue },
    { name = "Forest", accent = colors.lime, highlight = colors.green },
    { name = "Sunset", accent = colors.orange, highlight = colors.red },
    { name = "Violet", accent = colors.purple, highlight = colors.magenta },
}
local settings = {
    theme = 1,
    alphabetical = true,
}

local function readJSONFile(path)
    if not nativeFs.exists(path) or nativeFs.isDir(path) then return nil end
    local file = nativeFs.open(path, "r")
    if not file then return nil, "Could not read " .. path .. "." end
    local contents = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserializeJSON, contents)
    if not ok or type(value) ~= "table" then
        return nil, "Invalid JSON data in " .. path .. "."
    end
    return value
end

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

local function loadProfilePasswords()
    if not fs.exists(PROFILE_PASSWORDS_PATH) then return {} end
    local file = fs.open(PROFILE_PASSWORDS_PATH, "r")
    if not file then
        return nil, "Could not read profile passwords from " .. PROFILE_PASSWORDS_PATH .. "."
    end
    local contents = file.readAll()
    file.close()
    local ok, passwords = pcall(textutils.unserializeJSON, contents)
    if not ok or type(passwords) ~= "table" then
        return nil, "Profile password data is invalid. Refusing to bypass profile passwords."
    end
    for username, password in pairs(passwords) do
        if type(username) ~= "string" or not username:match("^[%w_-]+$")
            or type(password) ~= "string" then
            return nil, "Profile password data is invalid. Refusing to bypass profile passwords."
        end
    end
    return passwords
end

local function saveProfilePasswords(passwords)
    fs.makeDir(SYSTEM_DIRECTORY)
    local temporary = PROFILE_PASSWORDS_PATH .. ".tmp"
    local backup = PROFILE_PASSWORDS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(textutils.serializeJSON(passwords))
    file.close()

    if fs.exists(PROFILE_PASSWORDS_PATH) then
        local backedUp, backupError = pcall(fs.move, PROFILE_PASSWORDS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up profile passwords: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, PROFILE_PASSWORDS_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, PROFILE_PASSWORDS_PATH) end
        return false, "Could not save profile passwords: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function loadProfileAdmins()
    if not fs.exists(PROFILE_ADMINS_PATH) then return {} end
    local file = fs.open(PROFILE_ADMINS_PATH, "r")
    if not file then
        return nil, "Could not read profile admins from " .. PROFILE_ADMINS_PATH .. "."
    end
    local contents = file.readAll()
    file.close()
    local ok, admins = pcall(textutils.unserializeJSON, contents)
    if not ok or type(admins) ~= "table" then
        return nil, "Profile admin data is invalid. Refusing to grant sudo access."
    end
    for username, isAdmin in pairs(admins) do
        if type(username) ~= "string" or not username:match("^[%w_-]+$")
            or isAdmin ~= true then
            return nil, "Profile admin data is invalid. Refusing to grant sudo access."
        end
    end
    return admins
end

local function saveProfileAdmins(admins)
    fs.makeDir(SYSTEM_DIRECTORY)
    local temporary = PROFILE_ADMINS_PATH .. ".tmp"
    local backup = PROFILE_ADMINS_PATH .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(textutils.serializeJSON(admins))
    file.close()

    if fs.exists(PROFILE_ADMINS_PATH) then
        local backedUp, backupError = pcall(fs.move, PROFILE_ADMINS_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up profile admins: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, PROFILE_ADMINS_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, PROFILE_ADMINS_PATH) end
        return false, "Could not save profile admins: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function installDownloader()
    if fs.exists(DOWNLOADER_PATH) and fs.exists(SYSTEM_FILE_BROWSER_PATH) then return true end
    if not http or not http.get then
        return false, "Enable the ComputerCraft HTTP API to download the app downloader."
    end

    local ok, response, requestError = pcall(
        http.get, REPOSITORY_BASE_URL .. "computercraft/system/app-downloader.lua"
    )
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
    local backup = DOWNLOADER_PATH .. ".download-bak"
    fs.makeDir(SYSTEM_APP_DIRECTORY)
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. "." end
    file.write(contents)
    file.close()

    if fs.exists(DOWNLOADER_PATH) then
        local backedUp, backupError = pcall(fs.move, DOWNLOADER_PATH, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up the app downloader: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, DOWNLOADER_PATH)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, DOWNLOADER_PATH) end
        return false, "Could not install the app downloader: " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function updateLauncher()
    if not http or not http.get then
        message = "Enable the ComputerCraft HTTP API to update the launcher."
        return
    end

    local destination = "/" .. LAUNCHER_NAME
    local temporary = destination .. ".update-tmp"
    local backup = destination .. ".update-bak"
    local ok, response, requestError = pcall(http.get, REPOSITORY_BASE_URL .. LAUNCHER_NAME)
    if not ok then
        message = "Launcher update request failed: " .. tostring(response)
        return
    end
    if not response then
        message = "Launcher update request failed: " .. tostring(requestError or "HTTP request failed.")
        return
    end

    local responseCode = response.getResponseCode and response.getResponseCode()
    if responseCode and responseCode ~= 200 then
        response.close()
        message = "Launcher update failed: GitHub returned HTTP " .. responseCode .. "."
        return
    end

    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then
        message = "Launcher update failed: the downloaded file was empty."
        return
    end

    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file = fs.open(temporary, "w")
    if not file then
        message = "Could not create " .. temporary .. "."
        return
    end
    file.write(contents)
    file.close()

    if fs.exists(destination) then
        local backedUp, backupError = pcall(fs.move, destination, backup)
        if not backedUp then
            fs.delete(temporary)
            message = "Could not back up the current launcher: " .. tostring(backupError)
            return
        end
    end

    local moved, moveError = pcall(fs.move, temporary, destination)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, destination) end
        message = "Could not install the launcher update: " .. tostring(moveError)
        return
    end
    if fs.exists(backup) then fs.delete(backup) end
    message = "Launcher updated. Restart to use the new version."
end

local function displayName(path)
    local name = path:gsub("%.lua$", ""):gsub("[_%-]", " ")
    return name:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)
end

local function chooseUser()
    fs.makeDir(USER_ROOT)
    local loadedPasswords, passwordError = loadProfilePasswords()
    if not loadedPasswords then error(passwordError, 0) end
    profilePasswords = loadedPasswords
    local loadedAdmins, adminError = loadProfileAdmins()
    if not loadedAdmins then error(adminError, 0) end
    profileAdmins = loadedAdmins
    local userSelected = 1
    local userFirstVisible = 1
    local profileMessage = ""

    local function askPasswordOption()
        local width, height = term.getSize()
        local buttons = {
            { label = "NO PASSWORD", action = "none" },
            { label = "SET PASSWORD", action = "set" },
            { label = "CANCEL", action = "cancel" },
        }
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("PROFILE PASSWORD")
        term.setTextColor(colors.lightGray)
        print("This password only gates access through the launcher.")
        print("It is saved unencrypted; other programs can read profile files.")
        local slotWidth = math.max(1, math.floor(width / #buttons))
        for index, option in ipairs(buttons) do
            local left = (index - 1) * slotWidth + 1
            local buttonWidth = index == #buttons and width - left + 1 or slotWidth
            term.setCursorPos(left, height)
            term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
            term.setTextColor(colors.white)
            term.write(("[" .. option.label .. "]"):sub(1, buttonWidth))
            option.left = left
            option.right = left + buttonWidth - 1
        end
        while true do
            local event, button, x, y = os.pullEventRaw()
            if event == "mouse_click" and button == 1 and y == height then
                for _, option in ipairs(buttons) do
                    if x >= option.left and x <= option.right then
                        if option.action == "none" then return false end
                        if option.action == "set" then return true end
                        return nil
                    end
                end
            end
        end
    end

    local function authenticate(username)
        local expected = profilePasswords[username]
        if not expected then return true end
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("PROFILE LOCKED")
        term.setTextColor(colors.white)
        write("Password for " .. username .. ": ")
        local entered = read("*")
        if entered == expected then return true end
        profileMessage = "Incorrect password. Try again."
        return false
    end

    local function createProfile()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        write("New username: ")
        local username = read()
        if not username or not username:match("^[%w_-]+$") then
            profileMessage = "Use only letters, numbers, underscores, and hyphens."
            return false
        end
        local path = fs.combine(USER_ROOT, username)
        if fs.exists(path) then
            profileMessage = "That profile already exists. Select it from the list."
            return false
        end
        local setPassword = askPasswordOption()
        if setPassword == nil then
            profileMessage = "Profile creation cancelled."
            return false
        end
        local password
        if setPassword then
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("Set a profile password")
            write("Password: ")
            password = read("*")
            if password == "" then
                profileMessage = "Password cannot be empty."
                return false
            end
            write("Confirm password: ")
            if read("*") ~= password then
                profileMessage = "Passwords did not match."
                return false
            end
        end

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.cyan)
        print("ADMIN PROFILE")
        term.setTextColor(colors.lightGray)
        print("Admin profiles can use sudo to access other profiles.")
        local adminExists = next(profileAdmins) ~= nil
        if adminExists then
            print("An admin profile already exists; only standard profiles can be created.")
        else
            print("Choose whether " .. username .. " should be an admin.")
        end
        local adminButtons = {
            { label = "STANDARD PROFILE", admin = false },
        }
        if not adminExists then
            table.insert(adminButtons, { label = "MAKE ADMIN", admin = true })
        end
        table.insert(adminButtons, { label = "CANCEL", cancel = true })
        local width, height = term.getSize()
        local slotWidth = math.max(1, math.floor(width / #adminButtons))
        for index, option in ipairs(adminButtons) do
            local left = (index - 1) * slotWidth + 1
            local buttonWidth = index == #adminButtons and width - left + 1 or slotWidth
            term.setCursorPos(left, height)
            term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
            term.setTextColor(colors.white)
            term.write(("[" .. option.label .. "]"):sub(1, buttonWidth))
            option.left = left
            option.right = left + buttonWidth - 1
        end
        local isAdmin
        while isAdmin == nil do
            local event, button, x, y = os.pullEventRaw()
            if event == "mouse_click" and button == 1 and y == height then
                for _, option in ipairs(adminButtons) do
                    if x >= option.left and x <= option.right then
                        if option.cancel then
                            profileMessage = "Profile creation cancelled."
                            return false
                        end
                        isAdmin = option.admin
                        break
                    end
                end
            end
        end

        local created, createError = pcall(fs.makeDir, path)
        if not created then
            profileMessage = "Could not create profile: " .. tostring(createError)
            return false
        end
        if password then
            profilePasswords[username] = password
        else
            profilePasswords[username] = nil
        end
        local saved, saveError = saveProfilePasswords(profilePasswords)
        if not saved then
            profilePasswords[username] = nil
            pcall(fs.delete, path)
            profileMessage = saveError
            return false
        end
        if isAdmin and next(profileAdmins) ~= nil then
            profilePasswords[username] = nil
            local rollbackSaved, rollbackError = saveProfilePasswords(profilePasswords)
            pcall(fs.delete, path)
            profileMessage = "An admin profile already exists; cannot create another."
            if not rollbackSaved then
                profileMessage = profileMessage .. " Password rollback failed: " .. tostring(rollbackError)
            end
            return false
        end
        if isAdmin then
            profileAdmins[username] = true
        end
        local adminsSaved, adminsError = saveProfileAdmins(profileAdmins)
        if not adminsSaved then
            profilePasswords[username] = nil
            profileAdmins[username] = nil
            local rollbackSaved, rollbackError = saveProfilePasswords(profilePasswords)
            pcall(fs.delete, path)
            profileMessage = adminsError
            if not rollbackSaved then
                profileMessage = profileMessage .. " Password rollback also failed: " .. tostring(rollbackError)
            end
            return false
        end
        currentUser = username
        homeDirectory = path
        authorizedProfiles = {}
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
        local width, height = term.getSize()
        local visibleRows = math.max(1, height - 9)
        if userSelected < 1 or userSelected > #users then userSelected = 1 end
        if userSelected < userFirstVisible then userFirstVisible = userSelected end
        if userSelected >= userFirstVisible + visibleRows then
            userFirstVisible = userSelected - visibleRows + 1
        end

        local theme = THEMES[settings.theme]
        local accent = term.isColor() and theme.accent or colors.gray
        local highlight = term.isColor() and theme.highlight or colors.gray
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        term.setBackgroundColor(accent)
        term.write((" " .. "PROFILE SELECTOR"):sub(1, width))
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 2)
        term.setTextColor(colors.lightGray)
        term.write(("Welcome back. Choose a profile to continue."):sub(1, math.max(0, width - 2)))
        term.setCursorPos(2, 3)
        term.setTextColor(accent)
        term.write((#users .. (#users == 1 and " PROFILE" or " PROFILES")):sub(1, math.max(0, width - 2)))

        local lastVisible = math.min(#users, userFirstVisible + visibleRows - 1)
        for index = userFirstVisible, lastVisible do
            local row = index - userFirstVisible + 5
            term.setCursorPos(2, row)
            if index == userSelected then
                term.setBackgroundColor(highlight)
                term.setTextColor(colors.white)
                term.write(("  > " .. users[index]):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.setTextColor(colors.white)
                term.write(("    " .. users[index]):sub(1, math.max(0, width - 2)))
            end
        end
        if profileMessage ~= "" then
            term.setCursorPos(2, height - 3)
            term.setTextColor(colors.yellow)
            term.write(profileMessage:sub(1, math.max(0, width - 2)))
        elseif #users == 0 then
            term.setCursorPos(2, 6)
            term.setTextColor(colors.lightGray)
            term.write("No profiles yet. Create one to get started.")
        else
            term.setCursorPos(2, height - 3)
            term.setTextColor(colors.lightGray)
            term.write(("Click a profile once to select, again to open."):sub(1, math.max(0, width - 2)))
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.yellow)
        term.write(("Launcher sandbox is best-effort; cross-profile access needs a password."):sub(1, math.max(0, width - 2)))

        local buttons = {}
        if currentUser then
            buttons = {
                { label = "CANCEL", action = "cancel" },
                { label = "CREATE PROFILE", action = "create" },
            }
        else
            buttons = {
                { label = "CREATE PROFILE", action = "create" },
            }
        end
        local slotWidth = math.max(1, math.floor(width / #buttons))
        for index, profileButton in ipairs(buttons) do
            local left = (index - 1) * slotWidth + 1
            local buttonWidth = index == #buttons and width - left + 1 or slotWidth
            term.setCursorPos(left, height)
            term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
            term.setTextColor(colors.white)
            term.write(("[" .. profileButton.label .. "]"):sub(1, buttonWidth))
            profileButton.left = left
            profileButton.right = left + buttonWidth - 1
        end
        term.setBackgroundColor(colors.black)

        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 then
            local index = userFirstVisible + y - 5
            if y >= 5 and y < 5 + visibleRows and index >= userFirstVisible and index <= #users then
                local wasSelected = userSelected == index
                userSelected = index
                if wasSelected then
                    local username = users[userSelected]
                    if authenticate(username) then
                        currentUser = username
                        homeDirectory = fs.combine(USER_ROOT, currentUser)
                        authorizedProfiles = {}
                        return true
                    end
                end
            elseif y == height then
                for _, profileButton in ipairs(buttons) do
                    if x >= profileButton.left and x <= profileButton.right then
                        if profileButton.action == "cancel" then return false end
                        if createProfile() then return true end
                        break
                    end
                end
            end
        end
    end
end

local function authorizeProfileAccess(username)
    if type(username) ~= "string" or not username:match("^[%w_-]+$") then
        return false, "Invalid profile name."
    end
    if username == currentUser or authorizedProfiles[username] then return true end

    local profilePath = fs.combine(USER_ROOT, username)
    if not fs.isDir(profilePath) then return false, "That profile does not exist." end

    local expected = profilePasswords[username]
    if type(expected) ~= "string" or expected == "" then
        return false, "This profile has no password. Set one before accessing it."
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("PROFILE ACCESS REQUIRED")
    term.setTextColor(colors.white)
    print("Enter " .. username .. "'s password, or type sudo as an admin.")
    write("Password: ")
    local entered = read("*")
    if entered == expected then
        authorizedProfiles[username] = true
        return true
    elseif entered == "sudo" and profileAdmins[currentUser] == true then
        authorizedProfiles[username] = true
        return true
    elseif entered == "sudo" then
        return false, "The current profile is not an admin."
    else
        term.setTextColor(colors.yellow)
        print("Incorrect password. Access denied.")
        sleep(1)
        return false, "Incorrect password for " .. username .. "."
    end
end

local function listOtherProfiles()
    local profiles = {}
    for _, username in ipairs(fs.list(USER_ROOT)) do
        if username ~= currentUser and username:match("^[%w_-]+$")
            and fs.isDir(fs.combine(USER_ROOT, username)) then
            table.insert(profiles, username)
        end
    end
    table.sort(profiles, function(first, second) return first:lower() < second:lower() end)
    return profiles
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

    fs.makeDir(SYSTEM_APP_DIRECTORY)
    for _, name in ipairs(fs.list(SYSTEM_APP_DIRECTORY)) do
        local path = fs.combine(SYSTEM_APP_DIRECTORY, name)
        if isLuaFile(path) and not available[path] then
            table.insert(available, {
                path = path,
                name = catalogNames[name] or displayName(name),
            })
            available[path] = true
        end
    end

    local appDirectory = fs.combine(homeDirectory, "apps")
    fs.makeDir(appDirectory)
    local desktopDirectory = fs.combine(homeDirectory, "desktop")
    fs.makeDir(desktopDirectory)

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
    addAppsFrom(desktopDirectory, false)
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
    local subtitle = screen == "apps" and "YOUR PROGRAMS"
        or (screen == "notifications" and "LISTENING NOTIFICATIONS" or "LAUNCHER CUSTOMISATION")
    term.write(subtitle:sub(1, math.max(0, width - 2)))

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
        local detail = selectedApp and "Ready to launch" or "No programs found"
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
    elseif screen == "settings" then
        local options = {
            "Accent theme: " .. theme.name,
            "Sort programs alphabetically: " .. (settings.alphabetical and "On" or "Off"),
            "UPDATE LAUNCHER",
            "WIPE ENTIRE COMPUTER",
            "NOTIFICATIONS",
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
    else
        local config = homeDirectory
            and readJSONFile(nativeFs.combine(homeDirectory, "notification-listeners.json"))
        local listeners = type(config) == "table" and type(config.listeners) == "table"
            and config.listeners or {}
        local pageSize = math.max(1, math.floor((height - 8) / 2))
        local pageCount = math.max(1, math.ceil(#listeners / pageSize))
        notificationListenerPage = math.min(notificationListenerPage, pageCount)
        local firstListener = (notificationListenerPage - 1) * pageSize + 1
        local lastListener = math.min(#listeners, firstListener + pageSize - 1)
        term.setCursorPos(2, 4)
        term.setTextColor(titleColor)
        term.write("ACTIVE LISTENERS (click to remove)")
        local row = 5
        local listenerRows = {}
        for index = firstListener, lastListener do
            local listener = listeners[index]
            local visibleIndex = index - firstListener + 1
            local label = string.format("[%d] %s  /  %s", visibleIndex,
                tostring(listener.name or "Listener"), tostring(listener.protocol or ""))
            term.setCursorPos(2, row)
            term.setTextColor(textColor)
            term.write(label:sub(1, math.max(0, width - 2)))
            listenerRows[row] = index
            row = row + 1
        end
        if #listeners == 0 then
            term.setCursorPos(2, row)
            term.setTextColor(mutedColor)
            term.write("No custom protocol listeners are configured.")
            row = row + 1
        end

        local historyHeader = math.min(height - 8, row + 1)
        if historyHeader > row then
            term.setCursorPos(2, historyHeader)
            term.setTextColor(titleColor)
            term.write("RECENT NOTIFICATIONS")
        end
        local historyRow = historyHeader + 1
        local historyLimit = math.max(0, height - historyRow - 5)
        for index = 1, math.min(#notificationHistory, historyLimit) do
            local item = notificationHistory[index]
            term.setCursorPos(2, historyRow)
            term.setTextColor(mutedColor)
            term.write((item.source .. ": " .. item.title .. " - " .. item.message)
                :sub(1, math.max(0, width - 2)))
            historyRow = historyRow + 1
        end
        if #notificationHistory == 0 and historyRow < height - 4 then
            term.setCursorPos(2, historyRow)
            term.setTextColor(mutedColor)
            term.write("No notifications received this session.")
        end
        term.setCursorPos(2, height - 4)
        term.setTextColor(mutedColor)
        term.write(message:sub(1, math.max(0, width - 2)))
        firstButtons = {}
        secondButtons = {
            { label = "PREVIOUS", action = "notifications-prev" },
            { label = "BACK TO SETTINGS", action = "back-settings" },
            { label = "NEXT", action = "notifications-next" },
        }
        drawButtons(secondButtons, height - 1, width, isColor)
        return firstButtons, secondButtons, listenerRows
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
    print("")
    print("Exiting the program and returning to the launcher.")
    sleep(1)
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

local function isInHomeDirectory(path)
    local normalizedPath = path:gsub("^/+", ""):gsub("/+$", "")
    local normalizedHome = homeDirectory:gsub("^/+", ""):gsub("/+$", "")
    return normalizedPath == normalizedHome
        or normalizedPath:sub(1, #normalizedHome + 1) == normalizedHome .. "/"
end

local function runHomeProgram(programPath, ...)
    local normalizedHome = homeDirectory:gsub("^/+", ""):gsub("/+$", "")
    local normalizedProgram = programPath:gsub("^/+", ""):gsub("/+$", "")
    local virtualProgram
    if normalizedProgram == normalizedHome then
        virtualProgram = ""
    elseif normalizedProgram:sub(1, #normalizedHome + 1) == normalizedHome .. "/" then
        virtualProgram = normalizedProgram:sub(#normalizedHome + 2)
    else
        error("The program is outside the active profile home.", 0)
    end

    local virtualDirectory = ""
    local function normalizeVirtualPath(path)
        if type(path) ~= "string" then
            error("Filesystem paths must be strings.", 0)
        end

        local segments = {}
        if path:sub(1, 1) ~= "/" and virtualDirectory ~= "" then
            for segment in virtualDirectory:gmatch("[^/]+") do
                table.insert(segments, segment)
            end
        end
        for segment in path:gmatch("[^/]+") do
            if segment == ".." then
                if #segments > 0 then table.remove(segments) end
            elseif segment ~= "." then
                table.insert(segments, segment)
            end
        end
        return table.concat(segments, "/")
    end

    local function physicalPath(path)
        local normalizedPath = normalizeVirtualPath(path)
        if type(path) == "string" and path:sub(1, 1) == "/" then
            local username, profilePath = normalizedPath:match("^users/([%w_-]+)/*(.*)$")
            if username then
                local authorized, accessError = authorizeProfileAccess(username)
                if not authorized then error(accessError, 0) end
                return nativeFs.combine(USER_ROOT, username, profilePath)
            end
        end
        return nativeFs.combine(homeDirectory, normalizedPath)
    end

    local function virtualAbsolute(path)
        local normalized = normalizeVirtualPath(path)
        return normalized == "" and "/" or "/" .. normalized
    end

    local function createNotificationsModule()
        local configPath = nativeFs.combine(homeDirectory, "notification-listeners.json")
        local reservedProtocols = {
            launcher_notifications_v1 = true,
            launcher_email_v1 = true,
            launcher_email_notifications_v1 = true,
            launcher_market_notifications_v1 = true,
            order_system_v1 = true,
        }

        local function loadConfig()
            if not nativeFs.exists(configPath) then return { listeners = {} } end
            local file = nativeFs.open(configPath, "r")
            if not file then return nil, "Could not open notification listener settings." end
            local contents = file.readAll()
            file.close()
            local ok, config = pcall(textutils.unserializeJSON, contents)
            if not ok or type(config) ~= "table" or type(config.listeners) ~= "table" then
                return nil, "Notification listener settings are invalid."
            end
            return config
        end

        local function saveConfig(config)
            local temporary = configPath .. ".tmp"
            local backup = configPath .. ".bak"
            local file = nativeFs.open(temporary, "w")
            if not file then return false, "Could not create notification listener settings." end
            file.write(textutils.serializeJSON(config))
            file.close()
            if nativeFs.exists(backup) then nativeFs.delete(backup) end
            if nativeFs.exists(configPath) then
                local backedUp, backupError = pcall(nativeFs.move, configPath, backup)
                if not backedUp then
                    nativeFs.delete(temporary)
                    return false, "Could not back up notification settings: " .. tostring(backupError)
                end
            end
            local moved, moveError = pcall(nativeFs.move, temporary, configPath)
            if not moved then
                if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
                if nativeFs.exists(backup) then nativeFs.move(backup, configPath) end
                return false, "Could not save notification settings: " .. tostring(moveError)
            end
            if nativeFs.exists(backup) then nativeFs.delete(backup) end
            notificationConfigRevision = notificationConfigRevision + 1
            return true
        end

        local api = {}
        function api.send(protocol, payload, serviceName)
            if type(protocol) ~= "string" or type(payload) ~= "table" then
                return false, "A protocol string and table payload are required."
            end
            if type(serviceName) == "string" then
                local serverId = rednet.lookup(protocol, serviceName)
                if not serverId then return false, serviceName .. " was not found on rednet." end
                rednet.send(serverId, payload, protocol)
            else
                rednet.broadcast(payload, protocol)
            end
            return true
        end

        function api.request(protocol, payload, serviceName, timeout)
            if type(protocol) ~= "string" or type(payload) ~= "table"
                or type(serviceName) ~= "string" then
                return nil, "A protocol string, table payload, and service name are required."
            end
            local serverId = rednet.lookup(protocol, serviceName)
            if not serverId then return nil, serviceName .. " was not found on rednet." end
            rednet.send(serverId, payload, protocol)
            local _, response = rednet.receive(protocol, timeout or 5, serverId)
            if type(response) ~= "table" then return nil, "No response from " .. serviceName .. "." end
            if response.type == "error" then
                return nil, response.message or serviceName .. " rejected the request."
            end
            return response
        end

        function api.listen(protocol, titleField, messageField, name)
            if type(protocol) ~= "string" or #protocol < 1 or #protocol > 64
                or not protocol:match("^[%w_.%-]+$") then
                return false, "Protocol must be 1 to 64 letters, numbers, dots, dashes, or underscores."
            end
            if reservedProtocols[protocol] then
                return false, "That protocol is reserved for a built-in launcher service."
            end
            if type(titleField) ~= "string" or not titleField:match("^[%w_]+$") then
                return false, "Title field must be a table key containing letters, numbers, or underscores."
            end
            if #titleField > 32 then
                return false, "Title field must be no longer than 32 characters."
            end
            if type(messageField) ~= "string" or #messageField > 32
                or not messageField:match("^[%w_]+$") then
                return false, "Message field must be a table key containing letters, numbers, or underscores."
            end
            name = name == nil and protocol or name
            if type(name) ~= "string" or #name < 1 or #name > 32 then
                return false, "Notification name must be 1 to 32 characters."
            end

            local config, loadError = loadConfig()
            if not config then return false, loadError end
            for _, listener in ipairs(config.listeners) do
                if type(listener) == "table" and listener.protocol == protocol then
                    return false, "A listener for that protocol already exists."
                end
            end
            table.insert(config.listeners, {
                name = name,
                protocol = protocol,
                titleField = titleField,
                messageField = messageField,
            })
            return saveConfig(config)
        end

        function api.unlisten(protocol)
            if type(protocol) ~= "string" then return false, "Protocol must be a string." end
            local config, loadError = loadConfig()
            if not config then return false, loadError end
            for index, listener in ipairs(config.listeners) do
                if type(listener) == "table" and listener.protocol == protocol then
                    table.remove(config.listeners, index)
                    return saveConfig(config)
                end
            end
            return false, "No listener is registered for that protocol."
        end

        function api.notify(title, message, source)
            if (type(title) ~= "string" and type(title) ~= "number")
                or (type(message) ~= "string" and type(message) ~= "number") then
                return false, "Notification title and message must be strings or numbers."
            end
            if #tostring(title) > 256 or #tostring(message) > 2000 then
                return false, "Notification title or message is too long."
            end
            table.insert(apiNotificationQueue, {
                type = "notification",
                source = type(source) == "string" and source or "App",
                user = currentUser,
                title = title,
                message = message,
            })
            return true
        end

        return api
    end

    local function createStorageModule()
        local storageRoot = nativeFs.combine("/.launcher/user-data", currentUser)

        local function resolvePath(path)
            if type(path) ~= "string" or #path < 1 or #path > 160
                or path:sub(1, 1) == "/" or path:sub(-1) == "/"
                or path:find("//", 1, true) or path:find("\\", 1, true) then
                return nil, "Storage paths must be relative names."
            end
            local segments = {}
            for segment in path:gmatch("[^/]+") do
                if segment == "." or segment == ".." or not segment:match("^[%w_.%-]+$") then
                    return nil, "Storage paths may contain only letters, numbers, dots, underscores, and dashes."
                end
                table.insert(segments, segment)
            end
            if #segments == 0 then return nil, "A storage name is required." end
            return nativeFs.combine(storageRoot, table.concat(segments, "/"))
        end

        local api = {}
        function api.read(path)
            local target, pathError = resolvePath(path)
            if not target then return nil, pathError end
            if not nativeFs.exists(target) then return nil, "Stored data was not found." end
            if nativeFs.isDir(target) then return nil, "Stored data name refers to a folder." end
            local file = nativeFs.open(target, "r")
            if not file then return nil, "Could not open stored data." end
            local contents = file.readAll()
            file.close()
            local ok, value = pcall(textutils.unserializeJSON, contents)
            if not ok then return nil, "Stored data is not valid JSON." end
            return value
        end

        function api.write(path, value)
            local target, pathError = resolvePath(path)
            if not target then return false, pathError end
            local serialized, contents = pcall(textutils.serializeJSON, value)
            if not serialized or type(contents) ~= "string" then
                return false, "Value must be serializable as JSON."
            end
            if nativeFs.exists(target) and nativeFs.isDir(target) then
                return false, "Stored data name refers to a folder."
            end

            local directory = nativeFs.getDir(target)
            if directory ~= "" then
                local made, makeError = pcall(nativeFs.makeDir, directory)
                if not made then return false, "Could not create storage folder: " .. tostring(makeError) end
            end
            local temporary = target .. ".tmp"
            local backup = target .. ".bak"
            local file = nativeFs.open(temporary, "w")
            if not file then return false, "Could not create the storage staging file." end
            file.write(contents)
            file.close()

            if nativeFs.exists(backup) then nativeFs.delete(backup) end
            if nativeFs.exists(target) then
                local backedUp, backupError = pcall(nativeFs.move, target, backup)
                if not backedUp then
                    nativeFs.delete(temporary)
                    return false, "Could not back up stored data: " .. tostring(backupError)
                end
            end
            local moved, moveError = pcall(nativeFs.move, temporary, target)
            if not moved then
                if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
                if nativeFs.exists(backup) then nativeFs.move(backup, target) end
                return false, "Could not save stored data: " .. tostring(moveError)
            end
            if nativeFs.exists(backup) then nativeFs.delete(backup) end
            return true
        end

        function api.delete(path)
            local target, pathError = resolvePath(path)
            if not target then return false, pathError end
            if not nativeFs.exists(target) then return false, "Stored data was not found." end
            if nativeFs.isDir(target) then return false, "Stored data name refers to a folder." end
            local ok, deleteError = pcall(nativeFs.delete, target)
            if not ok then return false, "Could not delete stored data: " .. tostring(deleteError) end
            return true
        end

        function api.list(path)
            local target = storageRoot
            if path ~= nil and path ~= "" then
                local pathError
                target, pathError = resolvePath(path)
                if not target then return nil, pathError end
            end
            if not nativeFs.exists(target) then return {} end
            if not nativeFs.isDir(target) then return nil, "Storage path is not a folder." end
            return nativeFs.list(target)
        end

        return api
    end

    local function createEnvironment(parent, runningProgram)
        term.clear()
        term.setCursorPos(1, 1)
        local environment = {}
        for name, value in pairs(_ENV) do environment[name] = value end
        if type(parent) == "table" then
            for name, value in pairs(parent) do environment[name] = value end
        end

        local sandboxFs = {}
        sandboxFs.combine = function(...)
            local parts = { ... }
            local joined = ""
            for index, part in ipairs(parts) do
                if type(part) ~= "string" then
                    error("Filesystem paths must be strings.", 0)
                end
                if index == 1 then
                    joined = part
                elseif joined == "" then
                    joined = part
                else
                    joined = joined .. "/" .. part
                end
            end
            return virtualAbsolute(joined)
        end
        sandboxFs.getName = function(path)
            return nativeFs.getName(normalizeVirtualPath(path))
        end
        sandboxFs.getDir = function(path)
            local directory = nativeFs.getDir(normalizeVirtualPath(path))
            return directory == "" and "/" or "/" .. directory
        end

        local pathFunctions = {
            "exists", "isDir", "list", "makeDir", "delete", "getSize",
            "getFreeSpace", "getDrive", "isDriveRoot", "isReadOnly",
            "getCapacity", "attributes", "open",
        }
        for _, name in ipairs(pathFunctions) do
            if type(nativeFs[name]) == "function" then
                local nativeFunction = nativeFs[name]
                sandboxFs[name] = function(path, ...)
                    return nativeFunction(physicalPath(path), ...)
                end
            end
        end
        for _, name in ipairs({ "move", "copy" }) do
            if type(nativeFs[name]) == "function" then
                local nativeFunction = nativeFs[name]
                sandboxFs[name] = function(source, destination, ...)
                    return nativeFunction(physicalPath(source), physicalPath(destination), ...)
                end
            end
        end
        if type(nativeFs.find) == "function" then
            sandboxFs.find = function(pattern)
                local results = {}
                local physicalHome = nativeFs.combine(homeDirectory, "")
                local normalizedPattern = normalizeVirtualPath(pattern)
                local targetUsername = normalizedPattern:match("^users/([%w_-]+)/")
                    or normalizedPattern:match("^users/([%w_-]+)$")
                local physicalProfileRoot = targetUsername
                    and nativeFs.combine(USER_ROOT, targetUsername)
                for _, found in ipairs(nativeFs.find(physicalPath(pattern))) do
                    local normalizedFound = found:gsub("^/+", "")
                    if normalizedFound == physicalHome then
                        table.insert(results, "/")
                    elseif normalizedFound:sub(1, #physicalHome + 1) == physicalHome .. "/" then
                        table.insert(results, "/" .. normalizedFound:sub(#physicalHome + 2))
                    elseif physicalProfileRoot
                        and (normalizedFound == physicalProfileRoot
                            or normalizedFound:sub(1, #physicalProfileRoot + 1) == physicalProfileRoot .. "/") then
                        table.insert(results, "/" .. normalizedFound)
                    end
                end
                return results
            end
        end
        if type(nativeFs.complete) == "function" then
            sandboxFs.complete = function(path, location, includeFiles, includeDirs)
                local pathDirectory = nativeFs.getDir(path)
                local name = nativeFs.getName(path)
                local baseDirectory = path:sub(1, 1) == "/" and "/" or (location or virtualDirectory)
                local completionDirectory = normalizeVirtualPath(
                    baseDirectory .. (pathDirectory ~= "" and "/" .. pathDirectory or "")
                )
                local physicalDirectory = physicalPath("/" .. completionDirectory)
                local completions = nativeFs.complete(
                    name,
                    physicalDirectory,
                    includeFiles,
                    includeDirs
                )
                local prefix = pathDirectory ~= "" and pathDirectory .. "/" or ""
                local result = {}
                for _, completion in ipairs(completions) do
                    table.insert(result, prefix .. completion)
                end
                return result
            end
        end

        local sandboxOs = {}
        for name, value in pairs(nativeOs) do sandboxOs[name] = value end
        sandboxOs.loadAPI = nil
        sandboxOs.unloadAPI = nil
        local currentEnvironment = environment
        sandboxOs.run = function(parent, path, ...)
            local virtualPath = normalizeVirtualPath(path)
            local target = nativeFs.combine(homeDirectory, virtualPath)
            if not nativeFs.exists(target) or nativeFs.isDir(target) then return false end
            local parentEnvironment = type(parent) == "table" and parent or currentEnvironment
            local child = createEnvironment(parentEnvironment, virtualPath)
            return nativeOs.run(child, target, ...)
        end

        local sandboxShell
        sandboxShell = {
            dir = function() return virtualDirectory end,
            setDir = function(path)
                local target = physicalPath(path)
                if not nativeFs.isDir(target) then return false end
                virtualDirectory = normalizeVirtualPath(path)
                return true
            end,
            getRunningProgram = function() return virtualAbsolute(runningProgram) end,
            resolveProgram = function(path)
                if type(path) ~= "string" then return nil end
                local target = normalizeVirtualPath(path)
                local candidates = { target }
                if not path:find("/", 1, true) then
                    table.insert(candidates, normalizeVirtualPath("apps/" .. path))
                end
                for _, candidate in ipairs(candidates) do
                    local resolved = nativeFs.combine(homeDirectory, candidate)
                    if nativeFs.exists(resolved) and not nativeFs.isDir(resolved) then
                        return candidate == "" and "/" or "/" .. candidate
                    end
                end
                return nil
            end,
            run = function(path, ...)
                local resolved = sandboxShell.resolveProgram(path)
                if not resolved then return false end
                return sandboxOs.run(currentEnvironment, resolved, ...)
            end,
            execute = function(path, ...)
                return sandboxShell.run(path, ...)
            end,
            path = function() return "." end,
        }

        environment.fs = sandboxFs
        environment.os = sandboxOs
        environment.shell = sandboxShell
        local notificationsModule = createNotificationsModule()
        local storageModule = createStorageModule()
        environment.notifications = notificationsModule
        environment.storage = storageModule
        environment._G = environment
        environment.debug = nil
        environment.package = nil
        environment.require = function(moduleName)
            if moduleName == "notifications" then
                return notificationsModule
            end
            if moduleName == "storage" then
                return storageModule
            end
            if moduleName ~= "cc.pretty" or type(nativeRequire) ~= "function" then
                error("Only the storage, notifications, and built-in cc.pretty modules are available to profile apps.", 2)
            end
            return nativeRequire(moduleName)
        end
        environment.loadfile = nil
        environment.dofile = nil
        environment.loadstring = nil
        environment.getfenv = nil
        environment.setfenv = nil
        environment.io = nil
        environment.help = nil
        environment.settings = nil
        environment.multishell = nil
        if type(environment.paintutils) == "table" then
            local safePaintutils = {}
            for name, value in pairs(environment.paintutils) do safePaintutils[name] = value end
            if type(environment.paintutils.loadImage) == "function" then
                local nativeLoadImage = environment.paintutils.loadImage
                safePaintutils.loadImage = function(path)
                    return nativeLoadImage(physicalPath(path))
                end
            end
            environment.paintutils = safePaintutils
        end
        if type(environment.cc) == "table" then
            local safeCc = {}
            for name, value in pairs(environment.cc) do
                if name ~= "require" and name ~= "internal" then safeCc[name] = value end
            end
            environment.cc = safeCc
        end
        if type(load) == "function" then
            local nativeLoad = load
            environment.load = function(chunk, chunkName, mode, chunkEnvironment)
                return nativeLoad(chunk, chunkName, mode, chunkEnvironment or environment)
            end
        end
        return environment
    end

    local environment = createEnvironment(_ENV, virtualProgram)
    return nativeOs.run(environment, nativeFs.combine(homeDirectory, virtualProgram), ...)
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
    local ok, result
    if isInHomeDirectory(app.path) then
        ok, result = pcall(runHomeProgram, app.path, homeDirectory)
    elseif app.path:gsub("^/+", "") == SYSTEM_FILE_BROWSER_PATH:gsub("^/+", "") then
        local function runProfileProgram(path, ...)
            if type(path) ~= "string" or not isInHomeDirectory(path) then
                error("Only programs in the active profile home can be run here.", 0)
            end
            return runHomeProgram(path, ...)
        end
        ok, result = pcall(
            nativeOs.run, _ENV, app.path, homeDirectory,
            runProfileProgram, listOtherProfiles, authorizeProfileAccess
        )
    else
        ok, result = pcall(nativeOs.run, _ENV, app.path, homeDirectory)
    end
    shell.setDir(previousDirectory)
    term.clear()
    term.setCursorPos(1, 1)
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

local NOTIFICATION_PROTOCOL = "launcher_notifications_v1"
local EMAIL_PROTOCOL = "launcher_email_v1"
local EMAIL_NOTIFICATION_CONTROL_PROTOCOL = "launcher_email_notifications_v1"
local MARKET_PROTOCOL = "order_system_v1"
local MARKET_NOTIFICATION_CONTROL_PROTOCOL = "launcher_market_notifications_v1"
local function showNotificationPopup(notification)
    local function popupText(value)
        return tostring(value):gsub("%c", " ")
    end
    table.insert(notificationHistory, 1, {
        source = popupText(notification.source or "System"),
        title = popupText(notification.title or "Notification"),
        message = popupText(notification.message or ""),
        receivedAt = os.epoch and os.epoch("utc") or os.time() * 1000,
    })
    while #notificationHistory > 20 do table.remove(notificationHistory) end
    if not nativeWindow or not nativeTerm then return end
    local width, height = nativeTerm.getSize()
    if width < 12 or height < 4 then return end

    local popupWidth = math.min(width, 34)
    local popupHeight = math.min(height, 4)
    local popupX = width - popupWidth + 1
    local popup = nativeWindow.create(nativeTerm, popupWidth, popupHeight, popupX, 1, false)
    popup.setBackgroundColor(colors.black)
    popup.setTextColor(colors.white)
    popup.clear()
    popup.setCursorPos(1, 1)
    popup.setBackgroundColor(colors.cyan)
    popup.write(string.rep(" ", popupWidth))
    popup.setCursorPos(2, 1)
    popup.write(popupText(notification.title or "Notification"):sub(1, popupWidth - 2))
    popup.setBackgroundColor(colors.black)
    popup.setCursorPos(2, 2)
    popup.write(popupText(notification.source or "System"):sub(1, popupWidth - 2))
    popup.setCursorPos(2, 3)
    popup.write(popupText(notification.message or ""):sub(1, popupWidth - 2))
    popup.setVisible(true)
    sleep(4)
    popup.setVisible(false)
end

local function removeNotificationListener(index)
    if not homeDirectory then return false, "No active profile." end
    local configPath = nativeFs.combine(homeDirectory, "notification-listeners.json")
    local config, loadError = readJSONFile(configPath)
    if not config then return false, loadError or "No listener settings were found." end
    if type(config.listeners) ~= "table" or type(config.listeners[index]) ~= "table" then
        return false, "That listener is no longer available."
    end

    local removed = table.remove(config.listeners, index)
    local temporary = configPath .. ".tmp"
    local backup = configPath .. ".bak"
    local file = nativeFs.open(temporary, "w")
    if not file then
        table.insert(config.listeners, index, removed)
        return false, "Could not create temporary notification settings."
    end
    file.write(textutils.serializeJSON(config))
    file.close()

    if nativeFs.exists(backup) then nativeFs.delete(backup) end
    if nativeFs.exists(configPath) then
        local backedUp, backupError = pcall(nativeFs.move, configPath, backup)
        if not backedUp then
            nativeFs.delete(temporary)
            table.insert(config.listeners, index, removed)
            return false, "Could not back up notification settings: " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(nativeFs.move, temporary, configPath)
    if not moved then
        if nativeFs.exists(temporary) then nativeFs.delete(temporary) end
        if nativeFs.exists(backup) then nativeFs.move(backup, configPath) end
        table.insert(config.listeners, index, removed)
        return false, "Could not save notification settings: " .. tostring(moveError)
    end
    if nativeFs.exists(backup) then nativeFs.delete(backup) end
    notificationConfigRevision = notificationConfigRevision + 1
    return true, "Removed listener for " .. tostring(removed.protocol) .. "."
end

local function openNotificationModems()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and not rednet.isOpen(name) then
            rednet.open(name)
        end
    end
end

local function loadMarketFollows(profilePath)
    local follows, err = readJSONFile(nativeFs.combine(profilePath, "market-followed-orders.json"))
    if not follows then
        if err then showNotificationPopup({
            source = "Market",
            title = "Notification setup",
            message = err,
        }) end
        return {}
    end
    return follows
end

local function loadEmailAccount(profilePath)
    local account, err = readJSONFile(nativeFs.combine(profilePath, ".email-account.json"))
    if not account then
        if err then showNotificationPopup({
            source = "Email",
            title = "Notification setup",
            message = err,
        }) end
        return nil
    end
    if type(account.email) ~= "string" or type(account.password) ~= "string" then
        showNotificationPopup({
            source = "Email",
            title = "Notification setup",
            message = "Saved email account details are invalid.",
        })
        return nil
    end
    return account
end

local function loadNotificationListeners(profilePath)
    local config, err = readJSONFile(nativeFs.combine(profilePath, "notification-listeners.json"))
    if not config then
        if err then
            showNotificationPopup({
                source = "Notifications",
                title = "Listener settings",
                message = err,
            })
        end
        return {}
    end
    if type(config.listeners) ~= "table" then
        showNotificationPopup({
            source = "Notifications",
            title = "Listener settings",
            message = "Listener settings need a listeners array.",
        })
        return {}
    end

    local listeners = {}
    for _, listener in ipairs(config.listeners) do
        if type(listener) == "table" and type(listener.name) == "string"
            and type(listener.protocol) == "string"
            and type(listener.titleField) == "string"
            and type(listener.messageField) == "string" then
            table.insert(listeners, listener)
        else
            showNotificationPopup({
                source = "Notifications",
                title = "Listener settings",
                message = "A listener entry is invalid and was ignored.",
            })
        end
    end
    return listeners
end

local function sendNotificationSubscriptions(profilePath, computerId)
    openNotificationModems()
    local emailAccount = loadEmailAccount(profilePath)
    if emailAccount then
        local serverId = rednet.lookup(EMAIL_PROTOCOL, "email_server")
        if serverId then
            rednet.send(serverId, {
                type = "subscribe",
                email = emailAccount.email,
                password = emailAccount.password,
            }, EMAIL_NOTIFICATION_CONTROL_PROTOCOL)
        end
    end

    local followedOrders = loadMarketFollows(profilePath)
    if type(followedOrders) ~= "table" then return end
    local serverId = rednet.lookup(MARKET_PROTOCOL, "order_server")
    if not serverId then return end
    for _, followed in ipairs(followedOrders) do
        if type(followed) == "table" and type(followed.orderId) == "number" then
            rednet.send(serverId, {
                type = "watch_order",
                orderId = followed.orderId,
                computerId = computerId,
            }, MARKET_NOTIFICATION_CONTROL_PROTOCOL)
        end
    end
end

local function notificationReceiver()
    local lastProfilePath
    local nextSubscriptionSync = 0
    local computerId = os.getComputerID()
    local activeListeners = {}
    local loadedConfigRevision = -1

    while true do
        local now = os.clock()
        if homeDirectory and (homeDirectory ~= lastProfilePath
            or now >= nextSubscriptionSync
            or loadedConfigRevision ~= notificationConfigRevision) then
            lastProfilePath = homeDirectory
            nextSubscriptionSync = now + 30
            activeListeners = loadNotificationListeners(homeDirectory)
            sendNotificationSubscriptions(homeDirectory, computerId)
            loadedConfigRevision = notificationConfigRevision
        end

        while #apiNotificationQueue > 0 do
            showNotificationPopup(table.remove(apiNotificationQueue, 1))
        end

        openNotificationModems()
        local _, payload, protocol = rednet.receive(nil, 1)
        if protocol == NOTIFICATION_PROTOCOL
            and type(payload) == "table" and payload.type == "notification" then
            local show = true
            if payload.source == "Email" then
                local savedAccount = homeDirectory and loadEmailAccount(homeDirectory)
                show = savedAccount ~= nil and savedAccount.email == payload.user
            elseif payload.source ~= "Market"
                and type(payload.user) == "string" and currentUser then
                show = payload.user == currentUser
            end
            if show then showNotificationPopup(payload) end
        elseif type(payload) == "table" then
            for _, listener in ipairs(activeListeners) do
                if listener.protocol == protocol then
                    local title = payload[listener.titleField]
                    local body = payload[listener.messageField]
                    local titleType, bodyType = type(title), type(body)
                    if (titleType == "string" or titleType == "number")
                        and (bodyType == "string" or bodyType == "number") then
                        showNotificationPopup({
                            source = listener.name,
                            title = title,
                            message = body,
                        })
                    end
                end
            end
        end
    end
end

local function launcherMain()
local migrateLegacySettings = not fs.exists(SETTINGS_PATH) and fs.exists(LEGACY_SETTINGS_PATH)
loadSettings()
if migrateLegacySettings and saveSettings() then
    fs.delete(LEGACY_SETTINGS_PATH)
end

chooseUser()
local downloaded, downloadMessage = installDownloader()
local systemAppsInstalled = false
local systemAppInstallMessage
if downloaded then
    local ok, result = pcall(os.run, _ENV, DOWNLOADER_PATH, "install-system", homeDirectory)
    if ok and result ~= false then
        systemAppsInstalled = true
    else
        systemAppInstallMessage = ok
            and "Could not automatically install system apps."
            or "Could not run system app installation: " .. tostring(result)
    end
end

refreshApps()
if systemAppInstallMessage then
    message = systemAppInstallMessage
elseif downloaded and systemAppsInstalled then
    message = "System apps are ready."
elseif downloaded then
    message = "App downloader is ready."
else
    message = downloadMessage
end

while true do
    local firstButtons, secondButtons, listenerRows = draw()
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
        elseif screen == "notifications" then
            local listenerIndex = listenerRows and listenerRows[y]
            if listenerIndex then
                local removed, result = removeNotificationListener(listenerIndex)
                message = result
            elseif y == height - 1 then
                local action = buttonAt(secondButtons, x)
                if action == "back-settings" then
                    screen = "settings"
                    message = "Click a setting to change it."
                elseif action == "notifications-prev" then
                    notificationListenerPage = math.max(1, notificationListenerPage - 1)
                elseif action == "notifications-next" then
                    notificationListenerPage = notificationListenerPage + 1
                end
            end
        elseif y >= 5 and y <= 9 then
            selectedSetting = y - 4
            if selectedSetting == 1 then
                local direction = x <= math.floor(select(1, term.getSize()) / 2) and -1 or 1
                changeSetting(direction)
            elseif selectedSetting == 2 then
                changeSetting(1)
            elseif selectedSetting == 3 then
                updateLauncher()
            elseif selectedSetting == 4 then
                uninstallLauncher()
            elseif selectedSetting == 5 then
                screen = "notifications"
                notificationListenerPage = 1
                message = "Click an active listener to remove it."
            end
        elseif y == height - 1 and buttonAt(secondButtons, x) == "back" then
            screen = "apps"
            message = "Back to your programs."
        end
    end
end

end

nativeParallel.waitForAny(launcherMain, notificationReceiver)
