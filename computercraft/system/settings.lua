local SYSTEM_DIRECTORY = "/.launcher"
local USER_ROOT = "/users"
local SETTINGS_PATH = SYSTEM_DIRECTORY .. "/settings.json"
local PROFILE_PASSWORDS_PATH = SYSTEM_DIRECTORY .. "/profile-passwords.json"
local PROFILE_ADMINS_PATH = SYSTEM_DIRECTORY .. "/profile-admins.json"
local THEMES = {
    { name = "Ocean", accent = colors.cyan, highlight = colors.blue },
    { name = "Forest", accent = colors.lime, highlight = colors.green },
    { name = "Sunset", accent = colors.orange, highlight = colors.red },
    { name = "Violet", accent = colors.purple, highlight = colors.magenta },
    { name = "Custom", accent = colors.cyan, highlight = colors.blue },
}
local DEFAULT_CYAN = { 0.298, 0.600, 0.698 }
local DEFAULT_BLUE = { 0.200, 0.400, 0.800 }
local function validHexColor(value)
    return type(value) == "string" and value:match("^#?%x%x%x%x%x%x$") ~= nil
end

local function hexToRgb(value)
    value = value:gsub("^#", "")
    return tonumber(value:sub(1, 2), 16) / 255,
        tonumber(value:sub(3, 4), 16) / 255,
        tonumber(value:sub(5, 6), 16) / 255
end

local homeDirectory, currentUser = ...
local normalizedHome = type(homeDirectory) == "string" and homeDirectory:gsub("^/+", "")
local homeUser = normalizedHome and normalizedHome:match("^users/([%w_-]+)$")

if type(currentUser) ~= "string" or not currentUser:match("^[%w_-]+$")
    or homeUser ~= currentUser or not fs.isDir(fs.combine(USER_ROOT, currentUser)) then
    error("System Settings must be opened from an active user profile.", 0)
end

local function readJSON(path, default)
    if not fs.exists(path) then return default end
    if fs.isDir(path) then return nil, path .. " is a directory." end
    local file = fs.open(path, "r")
    if not file then return nil, "Could not read " .. path .. "." end
    local contents = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserializeJSON, contents)
    if not ok or type(value) ~= "table" then
        return nil, "Invalid JSON data in " .. path .. "."
    end
    return value
end

local function saveJSON(path, value)
    local serialized, contents = pcall(textutils.serializeJSON, value)
    if not serialized or type(contents) ~= "string" then
        return false, "Could not serialize " .. path .. "."
    end
    local made, makeError = pcall(fs.makeDir, SYSTEM_DIRECTORY)
    if not made then return false, "Could not create system settings folder: " .. tostring(makeError) end

    local temporary, backup = path .. ".tmp", path .. ".bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end
    local file, openError = fs.open(temporary, "w")
    if not file then return false, "Could not create " .. temporary .. ": " .. tostring(openError) end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, "Could not write " .. path .. ": "
            .. tostring(not wrote and writeError or closeError)
    end

    if fs.exists(path) then
        local backedUp, backupError = pcall(fs.move, path, backup)
        if not backedUp then
            fs.delete(temporary)
            return false, "Could not back up " .. path .. ": " .. tostring(backupError)
        end
    end
    local moved, moveError = pcall(fs.move, temporary, path)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then
            local restored, restoreError = pcall(fs.move, backup, path)
            if not restored then
                return false, "Could not save " .. path .. ": " .. tostring(moveError)
                    .. "; restoring the previous file also failed: " .. tostring(restoreError)
            end
        end
        return false, "Could not save " .. path .. ": " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function validateMap(map, valueType, path)
    for username, value in pairs(map) do
        if type(username) ~= "string" or not username:match("^[%w_-]+$")
            or type(value) ~= valueType then
            return false, "Invalid account data in " .. path .. "."
        end
    end
    return true
end

local profilePasswords, passwordError = readJSON(PROFILE_PASSWORDS_PATH, {})
if not profilePasswords then error(passwordError, 0) end
local validPasswords, passwordValidationError = validateMap(
    profilePasswords, "string", PROFILE_PASSWORDS_PATH
)
if not validPasswords then error(passwordValidationError, 0) end

local profileAdmins, adminError = readJSON(PROFILE_ADMINS_PATH, {})
if not profileAdmins then error(adminError, 0) end
for username, isAdmin in pairs(profileAdmins) do
    if type(username) ~= "string" or not username:match("^[%w_-]+$") or isAdmin ~= true then
        error("Invalid account role data in " .. PROFILE_ADMINS_PATH .. ".", 0)
    end
end

local savedSettings, settingsError = readJSON(SETTINGS_PATH, {})
if not savedSettings then error(settingsError, 0) end
local settings = {
    theme = type(savedSettings.theme) == "number" and THEMES[savedSettings.theme]
        and savedSettings.theme or 1,
    customAccent = validHexColor(savedSettings.customAccent)
        and ("#" .. savedSettings.customAccent:gsub("^#", ""):upper()) or "#4C99B2",
    customHighlight = validHexColor(savedSettings.customHighlight)
        and ("#" .. savedSettings.customHighlight:gsub("^#", ""):upper()) or "#3366CC",
    alphabetical = true,
}
if type(savedSettings.alphabetical) == "boolean" then
    settings.alphabetical = savedSettings.alphabetical
end
local isAdmin = profileAdmins[currentUser] == true
local page = "settings"
local selectedUser = 1
local firstVisible = 1
local message = "Theme row: click left/right; choose Custom to use the hex colors."

local function countAdmins(admins)
    local count = 0
    for username, isProfileAdmin in pairs(admins) do
        if isProfileAdmin == true and fs.isDir(fs.combine(USER_ROOT, username)) then
            count = count + 1
        end
    end
    return count
end

local function copyMap(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function listUsers()
    local users = {}
    fs.makeDir(USER_ROOT)
    for _, username in ipairs(fs.list(USER_ROOT)) do
        if username:match("^[%w_-]+$") and fs.isDir(fs.combine(USER_ROOT, username)) then
            table.insert(users, username)
        end
    end
    table.sort(users, function(first, second) return first:lower() < second:lower() end)
    return users
end

local function saveAccountData(passwords, admins)
    local savedPasswords, savePasswordError = saveJSON(PROFILE_PASSWORDS_PATH, passwords)
    if not savedPasswords then return false, savePasswordError end
    local savedAdmins, saveAdminError = saveJSON(PROFILE_ADMINS_PATH, admins)
    if not savedAdmins then
        local restored, restoreError = saveJSON(PROFILE_PASSWORDS_PATH, profilePasswords)
        if not restored then
            return false, saveAdminError .. " Password rollback failed: " .. tostring(restoreError)
        end
        return false, saveAdminError
    end
    profilePasswords, profileAdmins = passwords, admins
    return true
end

local function createAccount()
    term.clear()
    term.setCursorPos(1, 1)
    print("CREATE USER")
    write("Username (letters, numbers, _ or -): ")
    local username = read()
    if type(username) ~= "string" or not username:match("^[%w_-]+$") then
        return false, "Use only letters, numbers, underscores, and hyphens."
    end
    local profilePath = fs.combine(USER_ROOT, username)
    if fs.exists(profilePath) then return false, "That user already exists." end

    print("")
    print("A password is required for new accounts.")
    print("Launcher passwords are stored unencrypted.")
    write("Password: ")
    local password = read("*")
    if type(password) ~= "string" or password == "" then
        return false, "Password cannot be empty."
    end
    write("Confirm password: ")
    if read("*") ~= password then return false, "Passwords did not match." end

    local created, createError = pcall(fs.makeDir, profilePath)
    if not created then return false, "Could not create user: " .. tostring(createError) end
    local passwords = copyMap(profilePasswords)
    passwords[username] = password
    local saved, saveError = saveJSON(PROFILE_PASSWORDS_PATH, passwords)
    if not saved then
        pcall(fs.delete, profilePath)
        return false, saveError
    end
    profilePasswords = passwords
    return true, "Created standard user " .. username .. ". Change their role if needed.", username
end

local function changeRole(users)
    local username = users[selectedUser]
    if not username then return "Select a user first." end
    if username == currentUser then return "Your own role cannot be changed while signed in." end
    local admins = copyMap(profileAdmins)
    if admins[username] then
        if countAdmins(admins) <= 1 then return "The last admin cannot be demoted." end
        admins[username] = nil
    else
        admins[username] = true
    end
    local saved, saveError = saveJSON(PROFILE_ADMINS_PATH, admins)
    if not saved then return saveError end
    profileAdmins = admins
    return username .. " is now " .. (admins[username] and "an admin." or "a standard user.")
end

local function confirmDeletion(username)
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.red)
    print("DELETE USER")
    term.setTextColor(colors.white)
    print("Delete " .. username .. " and their profile data?")
    print("This cannot be undone.")
    local buttons = {
        { label = "CANCEL", action = false },
        { label = "DELETE USER", action = true },
    }
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local left = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - left + 1 or slotWidth
        term.setCursorPos(left, height)
        term.setBackgroundColor(colors.gray)
        term.write(("[" .. button.label .. "]"):sub(1, buttonWidth))
        button.left = left
        button.right = left + buttonWidth - 1
    end
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 and y == height then
            for _, choice in ipairs(buttons) do
                if x >= choice.left and x <= choice.right then return choice.action end
            end
        end
    end
end

local function deleteAccount(users)
    local username = users[selectedUser]
    if not username then return "Select a user first." end
    if username == currentUser then return "You cannot delete the active account." end
    if profileAdmins[username] and countAdmins(profileAdmins) <= 1 then
        return "The last admin cannot be deleted."
    end
    if not confirmDeletion(username) then return "Account deletion cancelled." end

    local trashDirectory = SYSTEM_DIRECTORY .. "/account-trash"
    local trashedProfile = fs.combine(trashDirectory, username)
    local privatePath = fs.combine(SYSTEM_DIRECTORY, "user-data/" .. username)
    local trashedPrivate = fs.combine(trashDirectory, username .. "-private")
    if fs.exists(trashedProfile) or fs.exists(trashedPrivate) then
        return "A previous deletion archive already exists; contact an administrator."
    end
    local made, makeError = pcall(fs.makeDir, trashDirectory)
    if not made then return "Could not prepare account deletion: " .. tostring(makeError) end

    local movedProfile, profileMoveError = pcall(fs.move, fs.combine(USER_ROOT, username), trashedProfile)
    if not movedProfile then
        return "Could not stage user profile for deletion: " .. tostring(profileMoveError)
    end
    local hasPrivateData = fs.exists(privatePath)
    if hasPrivateData then
        local movedPrivate, privateMoveError = pcall(fs.move, privatePath, trashedPrivate)
        if not movedPrivate then
            local restored, restoreError = pcall(fs.move, trashedProfile, fs.combine(USER_ROOT, username))
            return "Could not stage private account data: " .. tostring(privateMoveError)
                .. (restored and "" or "; profile restore failed: " .. tostring(restoreError))
        end
    end

    local passwords, admins = copyMap(profilePasswords), copyMap(profileAdmins)
    passwords[username], admins[username] = nil, nil
    local saved, saveError = saveAccountData(passwords, admins)
    if not saved then
        local restoreErrors = {}
        local restoredProfile, restoreProfileError = pcall(
            fs.move, trashedProfile, fs.combine(USER_ROOT, username)
        )
        if not restoredProfile then table.insert(restoreErrors, tostring(restoreProfileError)) end
        if hasPrivateData then
            local restoredPrivate, restorePrivateError = pcall(fs.move, trashedPrivate, privatePath)
            if not restoredPrivate then table.insert(restoreErrors, tostring(restorePrivateError)) end
        end
        if #restoreErrors > 0 then
            return saveError .. " Account data rollback failed: " .. table.concat(restoreErrors, "; ")
        end
        return saveError
    end

    local cleanupErrors = {}
    for _, path in ipairs({ trashedProfile, trashedPrivate }) do
        if fs.exists(path) then
            local removed, removeError = pcall(fs.delete, path)
            if not removed then table.insert(cleanupErrors, path .. ": " .. tostring(removeError)) end
        end
    end
    if #cleanupErrors > 0 then
        return "Account deleted, but staged data could not be removed: " .. table.concat(cleanupErrors, "; ")
    end
    return "Deleted user " .. username .. "."
end

local function savePreferences()
    local saved, saveError = saveJSON(SETTINGS_PATH, settings)
    if not saved then
        message = saveError
        return
    end
    if not term.isColor() then
        message = "Launcher preferences saved."
        return
    elseif settings.theme == #THEMES then
        if type(term.setPaletteColor) ~= "function" then
            message = "Custom themes require a color terminal with palette support."
            return
        end
        local accentRed, accentGreen, accentBlue = hexToRgb(settings.customAccent)
        local highlightRed, highlightGreen, highlightBlue = hexToRgb(settings.customHighlight)
        term.setPaletteColor(colors.cyan, accentRed, accentGreen, accentBlue)
        term.setPaletteColor(colors.blue, highlightRed, highlightGreen, highlightBlue)
    elseif type(term.setPaletteColor) == "function" then
        term.setPaletteColor(colors.cyan, table.unpack(DEFAULT_CYAN))
        term.setPaletteColor(colors.blue, table.unpack(DEFAULT_BLUE))
    end
    message = "Launcher preferences saved."
end

local function editCustomColor(field, label)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("CUSTOM " .. label:upper())
    print("Enter a six-digit hex color, with or without #.")
    write("Hex color (current " .. settings[field] .. "): ")
    local value = read()
    if not validHexColor(value) then
        message = "Enter exactly six hexadecimal digits, optionally prefixed with #."
        return
    end
    settings[field] = "#" .. value:gsub("^#", ""):upper()
    savePreferences()
end

local function drawButtons(buttons, width, row, isColor)
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local left = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - left + 1 or slotWidth
        term.setCursorPos(left, row)
        term.setBackgroundColor(isColor and colors.gray or colors.black)
        term.setTextColor(colors.white)
        term.write(("[" .. button.label .. "]"):sub(1, buttonWidth))
        button.left = left
        button.right = left + buttonWidth - 1
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
    local theme = THEMES[settings.theme]
    local accent = isColor and theme.accent or colors.gray
    local highlight = isColor and theme.highlight or colors.gray
    local buttons
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(accent)
    term.write((" SYSTEM SETTINGS"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 2)
    term.setTextColor(colors.lightGray)
    term.write((page == "settings" and "LAUNCHER PREFERENCES" or "USER ACCOUNTS")
        :sub(1, math.max(0, width - 2)))

    if page == "settings" then
        local options = {
            "Accent theme: " .. theme.name,
            "Custom accent: " .. settings.customAccent,
            "Custom highlight: " .. settings.customHighlight,
            "Sort programs alphabetically: " .. (settings.alphabetical and "On" or "Off"),
        }
        for index, option in ipairs(options) do
            term.setCursorPos(2, index + 4)
            if index == selectedUser then
                term.setBackgroundColor(highlight)
                term.write(("  > " .. option):sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.write(("    " .. option):sub(1, math.max(0, width - 2)))
            end
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.lightGray)
        term.write(message:sub(1, math.max(0, width - 2)))
        buttons = {
            { label = isAdmin and "ACCOUNTS" or "NO ADMIN ACCESS", action = "accounts" },
            { label = "EXIT", action = "exit" },
        }
    else
        local users = listUsers()
        local visibleRows = math.max(1, height - 8)
        if #users == 0 then
            selectedUser, firstVisible = 1, 1
        else
            selectedUser = math.max(1, math.min(selectedUser, #users))
            firstVisible = math.max(1, math.min(firstVisible, selectedUser))
            if selectedUser >= firstVisible + visibleRows then
                firstVisible = selectedUser - visibleRows + 1
            end
        end
        local lastVisible = math.min(#users, firstVisible + visibleRows - 1)
        for index = firstVisible, lastVisible do
            local username = users[index]
            local role = profileAdmins[username] and "ADMIN" or "STANDARD"
            term.setCursorPos(2, index - firstVisible + 4)
            if index == selectedUser then
                term.setBackgroundColor(highlight)
                term.write(("  > " .. username .. " [" .. role .. "]")
                    :sub(1, math.max(0, width - 2)))
                term.setBackgroundColor(colors.black)
            else
                term.write(("    " .. username .. " [" .. role .. "]")
                    :sub(1, math.max(0, width - 2)))
            end
        end
        if #users == 0 then
            term.setCursorPos(2, 5)
            term.setTextColor(colors.lightGray)
            term.write("No user accounts exist.")
        end
        term.setCursorPos(2, height - 2)
        term.setTextColor(colors.lightGray)
        term.write(message:sub(1, math.max(0, width - 2)))
        buttons = {
            { label = "CREATE", action = "create" },
            { label = "ROLE", action = "role" },
            { label = "DELETE", action = "delete" },
            { label = "SETTINGS", action = "preferences" },
        }
        drawButtons(buttons, width, height, isColor)
        return buttons, users, firstVisible, visibleRows
    end

    drawButtons(buttons, width, height, isColor)
    return buttons
end

while true do
    local buttons, users, firstUserRow, visibleRows = draw()
    local event, button, x, y = os.pullEventRaw()
    if event == "mouse_scroll" and page == "accounts" then
        selectedUser = math.max(1, math.min(#users, selectedUser + button))
        if selectedUser < firstUserRow then firstVisible = selectedUser end
        if selectedUser >= firstUserRow + visibleRows then
            firstVisible = selectedUser - visibleRows + 1
        end
    elseif event == "mouse_click" and button == 1 then
        local _, height = term.getSize()
        if page == "settings" and y == 5 then
            selectedUser = 1
            settings.theme = ((settings.theme - 1 + (x <= math.floor(select(1, term.getSize()) / 2) and -1 or 1))
                % #THEMES) + 1
            savePreferences()
        elseif page == "settings" and y == 6 then
            selectedUser = 2
            editCustomColor("customAccent", "Accent color")
        elseif page == "settings" and y == 7 then
            selectedUser = 3
            editCustomColor("customHighlight", "Highlight color")
        elseif page == "settings" and y == 8 then
            selectedUser = 4
            settings.alphabetical = not settings.alphabetical
            savePreferences()
        elseif y == height then
            local action = buttonAt(buttons, x)
            if action == "exit" then return end
            if action == "accounts" then
                if isAdmin then
                    page = "accounts"
                    selectedUser, firstVisible = 1, 1
                    message = "Select a user to change their role or delete them."
                else
                    message = "Only an administrator can manage user accounts."
                end
            elseif action == "preferences" then
                page = "settings"
                message = "Theme row: click left/right; choose Custom to use the hex colors."
            elseif action == "create" then
                local created, result, createdUsername = createAccount()
                message = result
                if created then
                    local updatedUsers = listUsers()
                    for index, username in ipairs(updatedUsers) do
                        if username == createdUsername then
                            selectedUser = index
                            break
                        end
                    end
                    firstVisible = math.min(firstVisible, selectedUser)
                end
            elseif action == "role" then
                message = changeRole(users)
            elseif action == "delete" then
                message = deleteAccount(users)
                selectedUser = math.max(1, selectedUser - 1)
            end
        elseif page == "accounts" and y >= 4 and y < 4 + visibleRows then
            local clickedIndex = firstUserRow + y - 4
            if clickedIndex >= 1 and clickedIndex <= #users then selectedUser = clickedIndex end
        end
    end
end
