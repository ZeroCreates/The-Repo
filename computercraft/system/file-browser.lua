local requestedHome, runProfileProgram, listOtherProfiles, authorizeProfileAccess = ...
local normalizedHome = type(requestedHome) == "string" and requestedHome:gsub("^/+", "")
local homeDirectory = normalizedHome and normalizedHome:match("^users/[%w_-]+$")
    and normalizedHome or "users/default"
local username = homeDirectory:match("^users/([%w_-]+)$")
local privateDataDirectory = fs.combine(".launcher", "user-data", username)
local encryptionKeyPath = "/.launcher/.data-key"
local profilesDirectory = "users"
local currentDirectory = fs.combine(homeDirectory, "desktop")
local currentRoot = homeDirectory
local authorizedProfileRoot
local diskMounts = {}
fs.makeDir(homeDirectory)
fs.makeDir(currentDirectory)
local entries = {}
local selected = 1
local firstVisible = 1
local message = "Hold ALT to show hidden files and Private Data."
local clipboard
local controlHeld = false
local altHeld = false
local privateEditSequence = 0
local themeIndex = 1
local themes = {
    { accent = colors.cyan, highlight = colors.blue },
    { accent = colors.lime, highlight = colors.green },
    { accent = colors.orange, highlight = colors.red },
    { accent = colors.purple, highlight = colors.magenta },
}

local function loadTheme()
    if type(launcherTheme) == "table" and type(launcherTheme.index) == "number"
        and themes[launcherTheme.index] then
        themeIndex = launcherTheme.index
        return
    end
    local path = "/.launcher/settings.json"
    if not fs.exists(path) then return end
    local file = fs.open(path, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()
    local ok, settings = pcall(textutils.unserializeJSON, contents)
    if ok and type(settings) == "table"
        and type(settings.theme) == "number" and themes[settings.theme] then
        themeIndex = settings.theme
    end
end

local function isWithinRoot(path, root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function isPrivateDataPath(path)
    return isWithinRoot(path, privateDataDirectory) and path ~= privateDataDirectory
end

local function loadEncryptionKey()
    local file = fs.open(encryptionKeyPath, "r")
    if not file then return nil, "Could not read the local data key." end
    local key = file.readAll()
    file.close()
    if type(key) ~= "string" or #key ~= 64 or key:find("[^%x]") then
        return nil, "The local data key is invalid."
    end
    key = key:upper()
    local keyBytes = {}
    for index = 1, #key, 2 do
        keyBytes[#keyBytes + 1] = tonumber(key:sub(index, index + 1), 16)
    end
    return keyBytes
end

local function xorByte(first, second)
    local result, bit = 0, 1
    while first > 0 or second > 0 do
        if first % 2 ~= second % 2 then result = result + bit end
        first = math.floor(first / 2)
        second = math.floor(second / 2)
        bit = bit * 2
    end
    return result
end

local function cryptData(contents, keyBytes)
    local state = 1
    for _, value in ipairs(keyBytes) do
        state = (state * 257 + value) % 2147483647
    end
    local output = {}
    for index = 1, #contents do
        state = (state * 48271) % 2147483647
        local mask = (state % 256 + keyBytes[(index - 1) % #keyBytes + 1]) % 256
        output[index] = string.char(xorByte(contents:byte(index), mask))
    end
    return table.concat(output)
end

local function decryptPrivateData(contents, keyBytes)
    local prefix = "CCLOCAL1:"
    if contents:sub(1, #prefix) ~= prefix then return contents end
    local encoded = contents:sub(#prefix + 1)
    if #encoded % 2 ~= 0 or encoded:find("[^%x]") then
        return nil, "Encrypted private data is malformed."
    end
    local encrypted = {}
    for index = 1, #encoded, 2 do
        encrypted[#encrypted + 1] = string.char(tonumber(encoded:sub(index, index + 1), 16))
    end
    return cryptData(table.concat(encrypted), keyBytes)
end

local function encryptPrivateData(contents, keyBytes)
    local encrypted = cryptData(contents, keyBytes)
    local encoded = {}
    for index = 1, #encrypted do
        encoded[index] = string.format("%02X", encrypted:byte(index))
    end
    return "CCLOCAL1:" .. table.concat(encoded)
end

local function readFile(path)
    local file = fs.open(path, "r")
    if not file then return nil, "Could not open the selected file." end
    local contents = file.readAll()
    file.close()
    return contents
end

local function writeFile(path, contents)
    local file = fs.open(path, "w")
    if not file then return false, "Could not create " .. path .. "." end
    local wrote, writeError = pcall(file.write, contents)
    local closed, closeError = pcall(file.close)
    if not wrote or not closed then
        return false, "Could not write " .. path .. ": "
            .. tostring(not wrote and writeError or closeError)
    end
    return true
end

local function deleteFile(path)
    local deleted, deleteError = pcall(fs.delete, path)
    if not deleted then return false, tostring(deleteError) end
    return true
end

local function displayPath(path)
    local normalizedPath = path:gsub("^/+", "")
    local normalizedPrivateData = privateDataDirectory:gsub("^/+", "")
    if normalizedPath == normalizedPrivateData then return "H://[PRIVATE DATA]" end
    if isWithinRoot(normalizedPath, normalizedPrivateData) then
        return "H://[PRIVATE DATA]/" .. normalizedPath:sub(#normalizedPrivateData + 2)
    end
    if authorizedProfileRoot and isWithinRoot(normalizedPath, authorizedProfileRoot) then
        local username = authorizedProfileRoot:match("^users/([%w_-]+)$")
        if username then
            local suffix = normalizedPath == authorizedProfileRoot
                and "" or normalizedPath:sub(#authorizedProfileRoot + 2)
            return "H@" .. username .. "://" .. suffix
        end
    end
    if normalizedPath == homeDirectory then return "H://" end
    if isWithinRoot(normalizedPath, homeDirectory) then
        return "H://" .. normalizedPath:sub(#homeDirectory + 2)
    end
    return path
end

local function displayMessage(text)
    local privatePattern = privateDataDirectory:gsub("^/+", ""):gsub("([^%w])", "%%%1")
    text = text:gsub(privatePattern .. "/", "H://[PRIVATE DATA]/")
        :gsub(privatePattern, "H://[PRIVATE DATA]")
    if authorizedProfileRoot then
        local username = authorizedProfileRoot:match("^users/([%w_-]+)$")
        if username then
            local profilePattern = authorizedProfileRoot:gsub("([^%w])", "%%%1")
            text = text:gsub(profilePattern .. "/", "H@" .. username .. "://")
                :gsub(profilePattern, "H@" .. username .. "://")
        end
    end
    local homePattern = homeDirectory:gsub("([^%w])", "%%%1")
    return (text:gsub(homePattern .. "/", "H://"):gsub(homePattern, "H://"))
end

local function refreshDiskMounts()
    local mounted = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ok, peripheralType = pcall(peripheral.getType, name)
        if ok and peripheralType == "drive" then
            local wrapped, drive = pcall(peripheral.wrap, name)
            if wrapped and drive and type(drive.getMountPath) == "function" then
                local mountOk, mountPath = pcall(drive.getMountPath)
                if mountOk and type(mountPath) == "string" then
                    mountPath = mountPath:gsub("^/+", ""):gsub("/+$", "")
                    if mountPath:match("^[%w_%-]+$") then
                        mounted[mountPath] = { name = name, path = mountPath }
                    end
                end
            end
        end
    end

    diskMounts = {}
    for _, mount in pairs(mounted) do
        table.insert(diskMounts, mount)
    end
    table.sort(diskMounts, function(first, second)
        return first.path:lower() < second.path:lower()
    end)
end

local function isMountedDisk(path)
    for _, mount in ipairs(diskMounts) do
        if mount.path == path then return true end
    end
    return false
end

local function parentDirectory(path)
    if path == currentRoot then return currentRoot end
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" or not isWithinRoot(parent, currentRoot) then
        return currentRoot
    end
    return parent
end

local function refreshEntries()
    refreshDiskMounts()
    if currentRoot ~= homeDirectory and currentRoot ~= profilesDirectory
        and currentRoot ~= authorizedProfileRoot and currentRoot ~= privateDataDirectory
        and not isMountedDisk(currentRoot) then
        currentDirectory = homeDirectory
        currentRoot = homeDirectory
        authorizedProfileRoot = nil
        message = "The disk was removed. Returned to your home directory."
    end

    local updated = {}
    if currentDirectory ~= currentRoot then
        table.insert(updated, { name = "..", path = parentDirectory(currentDirectory), isDirectory = true })
    elseif currentRoot == profilesDirectory then
        table.insert(updated, {
            name = "..",
            path = homeDirectory,
            isDirectory = true,
            returnHome = true,
        })
        if type(listOtherProfiles) == "function" then
            for _, username in ipairs(listOtherProfiles()) do
                if type(username) == "string" and username:match("^[%w_-]+$") then
                    table.insert(updated, {
                        name = username,
                        path = fs.combine(profilesDirectory, username),
                        isDirectory = true,
                        profileRoot = true,
                        username = username,
                    })
                end
            end
        end
    elseif currentRoot ~= homeDirectory then
        table.insert(updated, {
            name = "..",
            path = homeDirectory,
            isDirectory = true,
            returnHome = true,
        })
    else
        table.insert(updated, {
            name = "[Other Users]",
            path = profilesDirectory,
            isDirectory = true,
            profilesRoot = true,
        })
        for _, mount in ipairs(diskMounts) do
            table.insert(updated, {
                name = "[Disk] " .. mount.path,
                path = mount.path,
                isDirectory = true,
                diskRoot = true,
            })
        end
    end

    if currentRoot == homeDirectory and altHeld then
        table.insert(updated, {
            name = "[Private Data]",
            path = privateDataDirectory,
            isDirectory = true,
            privateDataRoot = true,
        })
    end

    if currentRoot ~= profilesDirectory then
        for _, name in ipairs(fs.list(currentDirectory)) do
            if altHeld or name:sub(1, 1) ~= "." then
                local path = fs.combine(currentDirectory, name)
                table.insert(updated, {
                    name = name,
                    path = path,
                    isDirectory = fs.isDir(path),
                })
            end
        end
    end

    table.sort(updated, function(first, second)
        if first.name == ".." then return true end
        if second.name == ".." then return false end
        if first.isDirectory ~= second.isDirectory then return first.isDirectory end
        return first.name:lower() < second.name:lower()
    end)

    entries = updated
    selected = math.min(selected, math.max(1, #entries))
    firstVisible = 1
end

local function visibleRows(height)
    return math.max(1, height - 9)
end

local function drawButtons(buttons, row, width)
    local slotWidth = math.max(1, math.floor(width / #buttons))
    for index, button in ipairs(buttons) do
        local x = (index - 1) * slotWidth + 1
        local buttonWidth = index == #buttons and width - x + 1 or slotWidth
        term.setCursorPos(x, row)
        term.setBackgroundColor(term.isColor() and colors.gray or colors.black)
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
    local theme = themes[themeIndex]
    local accent = term.isColor() and theme.accent or colors.gray
    local highlight = term.isColor() and theme.highlight or colors.gray
    local rowCount = visibleRows(height)
    local topButtons = {
        { label = "NEW FILE", action = "create" },
        { label = "FOLDER", action = "create-folder" },
        { label = "EDIT", action = "edit" },
        { label = "OPEN", action = "open" },
    }
    local selectedEntry = entries[selected]
    if selectedEntry and not selectedEntry.isDirectory
        and selectedEntry.path:lower():match("%.lua$")
        and isWithinRoot(selectedEntry.path, homeDirectory) then
        table.insert(topButtons, { label = "RUN", action = "run" })
    end
    local bottomButtons
    if currentDirectory == homeDirectory then
        bottomButtons = {
            { label = "HOME", action = "home" },
            { label = "DELETE", action = "delete" },
            { label = "EXIT", action = "exit" },
        }
    else
        bottomButtons = {
            { label = "UP", action = "up" },
            { label = "HOME", action = "home" },
            { label = "DELETE", action = "delete" },
            { label = "EXIT", action = "exit" },
        }
    end
    if selected < firstVisible then firstVisible = selected end
    if selected >= firstVisible + rowCount then
        firstVisible = selected - rowCount + 1
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(accent)
    term.write((" FILE BROWSER"):sub(1, width))
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 2)
    term.setTextColor(colors.lightGray)
    term.write(("Path: " .. displayPath(currentDirectory)):sub(1, math.max(0, width - 2)))

    local lastVisible = math.min(#entries, firstVisible + rowCount - 1)
    for index = firstVisible, lastVisible do
        local row = index - firstVisible + 3
        local entry = entries[index]
        local label = entry.name .. (entry.isDirectory and "/" or "")
        term.setCursorPos(2, row)
        if index == selected then
            term.setBackgroundColor(highlight)
            term.setTextColor(colors.white)
            term.write(("> " .. label):sub(1, math.max(0, width - 2)))
            term.setBackgroundColor(colors.black)
        else
            term.setTextColor(entry.isDirectory and (term.isColor() and accent or colors.white) or colors.white)
            term.write(("  " .. label):sub(1, math.max(0, width - 2)))
        end
    end

    term.setCursorPos(2, height - 4)
    term.setTextColor(colors.yellow)
    term.write(displayMessage(message):sub(1, math.max(0, width - 2)))
    drawButtons(topButtons, height - 2, width)
    drawButtons(bottomButtons, height - 1, width)
    term.setBackgroundColor(colors.black)
    return topButtons, bottomButtons
end

local function editSelected()
    local entry = entries[selected]
    if not entry then
        message = "Select a file first."
        return
    end
    if entry.isDirectory then
        message = "Select a file to edit."
        return
    end
    if not isWithinRoot(entry.path, currentRoot) or entry.path == currentRoot then
        message = "That file is outside the current location."
        return
    end

    local editorPath = shell.resolveProgram("edit")
    if not editorPath then
        message = "The built-in edit program could not be found."
        return
    end

    if isPrivateDataPath(entry.path) then
        local keyBytes, keyError = loadEncryptionKey()
        if not keyBytes then
            message = keyError
            return
        end
        local encryptedContents, readError = readFile(entry.path)
        if not encryptedContents then
            message = readError
            return
        end
        local plaintext, decryptError = decryptPrivateData(encryptedContents, keyBytes)
        if not plaintext then
            message = "Could not decrypt private data: " .. tostring(decryptError)
            return
        end

        privateEditSequence = privateEditSequence + 1
        local epoch = type(os.epoch) == "function" and os.epoch("utc") or os.time()
        local temporaryPath
        repeat
            temporaryPath = fs.combine("/.launcher",
                ".file-browser-edit-" .. tostring(epoch) .. "-" .. privateEditSequence)
            if fs.exists(temporaryPath) then privateEditSequence = privateEditSequence + 1 end
        until not fs.exists(temporaryPath)

        local temporarySaved, temporaryError = writeFile(temporaryPath, plaintext)
        if not temporarySaved then
            message = temporaryError
            return
        end
        local ran, result = pcall(os.run, _ENV, editorPath, temporaryPath)
        if not ran or result == false then
            local removed, removeError = deleteFile(temporaryPath)
            message = not ran and ("Could not run edit: " .. tostring(result))
                or "The edit command did not complete successfully."
            if not removed then
                message = message .. " Plaintext remains at " .. temporaryPath
                    .. ": " .. removeError
            end
            return
        end

        local editedContents, editedReadError = readFile(temporaryPath)
        if not editedContents then
            message = editedReadError .. " The original remains encrypted; plaintext recovery file: "
                .. temporaryPath .. "."
            return
        end
        local protectedContents = encryptPrivateData(editedContents, keyBytes)
        local encryptedTemporary = entry.path .. ".enc-tmp"
        local backup = entry.path .. ".enc-bak"
        if fs.exists(encryptedTemporary) or fs.exists(backup) then
            message = "Could not re-encrypt private data: a recovery file already exists. "
                .. "Plaintext remains at " .. temporaryPath .. "."
            return
        end
        local wrote, writeError = writeFile(encryptedTemporary, protectedContents)
        if not wrote then
            local removed = deleteFile(encryptedTemporary)
            message = writeError .. " Plaintext remains at " .. temporaryPath .. "."
                .. (removed and "" or " Encrypted staging-file cleanup failed.")
            return
        end
        local backedUp, backupError = pcall(fs.move, entry.path, backup)
        if not backedUp then
            deleteFile(encryptedTemporary)
            message = "Could not protect private data: " .. tostring(backupError)
                .. " Plaintext remains at " .. temporaryPath .. "."
            return
        end
        local installed, installError = pcall(fs.move, encryptedTemporary, entry.path)
        if not installed then
            if fs.exists(encryptedTemporary) then deleteFile(encryptedTemporary) end
            local restored, restoreError = pcall(fs.move, backup, entry.path)
            message = "Could not re-encrypt private data: " .. tostring(installError)
                .. (restored and "" or "; restoring the original failed: " .. tostring(restoreError))
                .. " Plaintext remains at " .. temporaryPath .. "."
            return
        end
        local backupRemoved, backupRemoveError = deleteFile(backup)
        local plaintextRemoved, plaintextRemoveError = deleteFile(temporaryPath)
        message = "Re-encrypted " .. entry.name .. " after editing."
        if not backupRemoved then
            message = message .. " The old encrypted backup remains at " .. backup .. ": "
                .. backupRemoveError
        end
        if not plaintextRemoved then
            message = message .. " Plaintext remains at " .. temporaryPath .. ": "
                .. plaintextRemoveError
        end
        refreshEntries()
        return
    end

    local ok, result = pcall(os.run, _ENV, editorPath, "/" .. entry.path)
    if not ok then
        message = "Could not run edit: " .. tostring(result)
    elseif result == false then
        message = "The edit command did not complete successfully."
    else
        message = "Returned from editing " .. entry.name .. "."
    end
    loadTheme()
    refreshEntries()
end

local function runSelected()
    local entry = entries[selected]
    if not entry or entry.isDirectory or not entry.path:lower():match("%.lua$")
        or not isWithinRoot(entry.path, homeDirectory) then
        message = "Select a Lua file in your home directory to run."
        return
    end
    if type(runProfileProgram) ~= "function" then
        message = "The launcher could not provide the profile-safe program runner."
        return
    end

    local ok, result = pcall(runProfileProgram, "/" .. entry.path, homeDirectory)
    if not ok then
        message = "Could not run " .. entry.name .. ": " .. tostring(result)
    elseif result == false then
        message = "The program did not complete successfully."
    else
        message = "Returned from " .. entry.name .. "."
    end
    loadTheme()
    refreshEntries()
end

local function createFile()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Create a file in " .. displayPath(currentDirectory))
    write("File name: ")
    local name = read()
    if name == "" then
        message = "File creation cancelled."
        return
    end
    if name:find("[/\\:]", 1) or name == "." or name == ".." then
        message = "Enter a file name, not a path."
        return
    end

    local path = fs.combine(currentDirectory, name)
    if fs.exists(path) then
        message = "That file or folder already exists."
        return
    end
    local file = fs.open(path, "w")
    if not file then
        message = "Could not create " .. name .. "."
        return
    end
    file.close()
    refreshEntries()
    for index, entry in ipairs(entries) do
        if entry.path == path then
            selected = index
            break
        end
    end
    message = "Created " .. name .. " in your home directory."
end

local function createFolder()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Create a folder in " .. displayPath(currentDirectory))
    write("Folder name: ")
    local name = read()
    if name == "" then
        message = "Folder creation cancelled."
        return
    end
    if name:find("[/\\:]", 1) or name == "." or name == ".." then
        message = "Enter a folder name, not a path."
        return
    end

    local path = fs.combine(currentDirectory, name)
    if fs.exists(path) then
        message = "That file or folder already exists."
        return
    end
    local ok, err = pcall(fs.makeDir, path)
    if not ok then
        message = "Could not create " .. name .. ": " .. tostring(err)
        return
    end
    refreshEntries()
    for index, entry in ipairs(entries) do
        if entry.path == path then
            selected = index
            break
        end
    end
    message = "Created folder " .. name .. "."
end

local function confirmUploadOverwrite(path)
    local width, height = term.getSize()
    local buttons = {
        { label = "CANCEL", action = false },
        { label = "REPLACE", action = true },
    }
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print(displayPath(path) .. " already exists.")
    term.setTextColor(colors.white)
    print("Choose whether to replace it.")
    drawButtons(buttons, height - 1, width)
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 and y == height - 1 then
            for _, choice in ipairs(buttons) do
                if x >= choice.left and x <= choice.right then return choice.action end
            end
        end
    end
end

local function confirmDelete(path)
    local width, height = term.getSize()
    local buttons = {
        { label = "CANCEL", action = false },
        { label = "DELETE", action = true },
    }
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("Delete " .. displayPath(path) .. "?")
    print("Folders and their contents will be removed.")
    term.setTextColor(colors.white)
    drawButtons(buttons, height - 1, width)
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "mouse_click" and button == 1 and y == height - 1 then
            for _, choice in ipairs(buttons) do
                if x >= choice.left and x <= choice.right then return choice.action end
            end
        end
    end
end

local function deleteSelected()
    local entry = entries[selected]
    if not entry or entry.name == ".." or entry.profilesRoot or entry.profileRoot then
        message = "Select a file or folder to delete."
        return
    end
    if entry.path == currentRoot or not isWithinRoot(entry.path, currentRoot) then
        message = "That location cannot be deleted."
        return
    end
    if not confirmDelete(entry.path) then
        message = "Deletion cancelled."
        return
    end

    local ok, err = pcall(fs.delete, entry.path)
    if not ok then
        message = "Could not delete " .. entry.name .. ": " .. tostring(err)
        return
    end
    refreshEntries()
    message = "Deleted " .. entry.name .. "."
end

local function copyOrCutSelected(mode)
    local entry = entries[selected]
    if not entry or entry.name == ".." or entry.diskRoot or entry.returnHome
        or entry.profilesRoot or entry.profileRoot
        or not isWithinRoot(entry.path, currentRoot) or entry.path == currentRoot then
        message = "Select a file or folder first."
        return
    end

    clipboard = {
        path = entry.path,
        name = entry.name,
        isDirectory = entry.isDirectory,
        root = currentRoot,
        mode = mode,
    }
    message = (mode == "cut" and "Cut " or "Copied ") .. entry.name .. ". Navigate to a folder and press Ctrl+V."
end

local function pasteClipboard()
    if not clipboard then
        message = "Nothing to paste. Select a file or folder and press Ctrl+C or Ctrl+X first."
        return
    end

    refreshDiskMounts()
    if (clipboard.root ~= homeDirectory and clipboard.root ~= privateDataDirectory
        and not isMountedDisk(clipboard.root))
        or not isWithinRoot(clipboard.path, clipboard.root)
        or not fs.exists(clipboard.path:sub(1, 1) == "/" and clipboard.path or "/" .. clipboard.path) then
        clipboard = nil
        message = "The copied or cut file is no longer available."
        return
    end

    local destination = fs.combine(currentDirectory, clipboard.name)
    local absoluteSource = clipboard.path:sub(1, 1) == "/" and clipboard.path or "/" .. clipboard.path
    local absoluteDestination = destination:sub(1, 1) == "/" and destination or "/" .. destination
    if not isWithinRoot(destination, currentRoot) or destination == currentRoot then
        message = "That paste location is outside the current root."
        return
    end
    if fs.exists(absoluteDestination) then
        message = "Cannot paste: " .. clipboard.name .. " already exists here."
        return
    end
    if clipboard.isDirectory
        and (currentDirectory == clipboard.path
            or currentDirectory:sub(1, #clipboard.path + 1) == clipboard.path .. "/") then
        message = "A folder cannot be pasted into itself or one of its subfolders."
        return
    end

    local operation = clipboard.mode == "cut" and fs.move or fs.copy
    local ok, err = pcall(operation, absoluteSource, absoluteDestination)
    if not ok then
        message = "Could not paste " .. clipboard.name .. ": " .. tostring(err)
        return
    end

    if clipboard.mode == "cut" then clipboard = nil end
    refreshEntries()
    message = "Pasted " .. fs.getName(destination) .. " into " .. displayPath(currentDirectory) .. "."
end

local function saveTransferredFile(source)
    local name = source.getName()
    local fileName = fs.getName(name)
    if fileName == "" or fileName == "." or fileName == ".." then
        source.close()
        return false, "Skipped a transfer with an invalid filename."
    end

    local destination = fs.combine(currentDirectory, fileName)
    if fs.isDir(destination) then
        source.close()
        return false, "Skipped " .. fileName .. " (a folder with that name exists)."
    end
    if fs.exists(destination) and not confirmUploadOverwrite(destination) then
        source.close()
        return false, "Skipped " .. fileName .. " (replacement cancelled)."
    end

    local contents = source.readAll()
    source.close()
    local temporary = fs.combine(currentDirectory, fileName .. ".upload-tmp")
    local backup = fs.combine(currentDirectory, fileName .. ".upload-bak")
    if fs.exists(temporary) or fs.exists(backup) then
        return false, "Skipped " .. fileName .. " because an upload recovery file already exists."
    end

    local output = fs.open(temporary, "wb")
    if not output then return false, "Could not create " .. temporary .. "." end
    output.write(contents)
    output.close()

    if fs.exists(destination) then
        local moved, moveError = pcall(fs.move, destination, backup)
        if not moved then
            fs.delete(temporary)
            return false, "Could not back up " .. displayPath(destination) .. ": " .. tostring(moveError)
        end
    end

    local moved, moveError = pcall(fs.move, temporary, destination)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, destination) end
        return false, "Could not save " .. displayPath(destination) .. ": " .. tostring(moveError)
    end
    if fs.exists(backup) then fs.delete(backup) end
    return true, "Uploaded " .. fileName .. "."
end

local function openSelected()
    local entry = entries[selected]
    if not entry then
        message = "This directory is empty."
        return
    end
    if entry.diskRoot then
        currentRoot = entry.path
        currentDirectory = entry.path
        authorizedProfileRoot = nil
        selected = 1
        refreshEntries()
        message = "Opened disk " .. displayPath(entry.path) .. "."
        return
    end
    if entry.privateDataRoot then
        fs.makeDir(privateDataDirectory)
        currentRoot = privateDataDirectory
        currentDirectory = privateDataDirectory
        authorizedProfileRoot = nil
        selected = 1
        refreshEntries()
        message = "Opened private data. Keep Alt held to show hidden files."
        return
    end
    if entry.returnHome then
        currentRoot = homeDirectory
        currentDirectory = homeDirectory
        authorizedProfileRoot = nil
        selected = 1
        refreshEntries()
        message = "Returned to your home directory."
        return
    end
    if entry.profilesRoot then
        currentRoot = profilesDirectory
        currentDirectory = profilesDirectory
        selected = 1
        refreshEntries()
        message = "Choose a profile and enter its password."
        return
    end
    if entry.profileRoot then
        if type(authorizeProfileAccess) ~= "function" then
            message = "The launcher could not authenticate access to other profiles."
            return
        end
        local authorized, accessError = authorizeProfileAccess(entry.username)
        if not authorized then
            message = accessError or "Profile access denied."
            return
        end
        authorizedProfileRoot = entry.path
        currentRoot = entry.path
        currentDirectory = entry.path
        selected = 1
        refreshEntries()
        message = "Opened " .. entry.name .. "'s home directory."
        return
    end
    if not isWithinRoot(entry.path, currentRoot) then
        message = "That location is outside the current location."
        return
    end
    if entry.isDirectory then
        currentDirectory = entry.path
        selected = 1
        refreshEntries()
        message = "Opened " .. displayPath(currentDirectory) .. "."
    else
        editSelected()
    end
end

refreshEntries()
while true do
    local topButtons, bottomButtons = draw()
    local event, button, x, y = os.pullEventRaw()
    if event == "key" then
        if button == keys.leftAlt or button == keys.rightAlt then
            if not altHeld then
                altHeld = true
                refreshEntries()
            end
        elseif button == keys.leftCtrl or button == keys.rightCtrl then
            controlHeld = true
        elseif controlHeld and button == keys.c then
            copyOrCutSelected("copy")
        elseif controlHeld and button == keys.x then
            copyOrCutSelected("cut")
        elseif controlHeld and button == keys.v then
            pasteClipboard()
        end
    elseif event == "key_up" then
        if button == keys.leftAlt or button == keys.rightAlt then
            if altHeld then
                altHeld = false
                refreshEntries()
            end
        elseif button == keys.leftCtrl or button == keys.rightCtrl then
            controlHeld = false
        end
    elseif event == "mouse_scroll" then
        local _, height = term.getSize()
        if y >= 3 and y < 3 + visibleRows(height) then
            selected = math.max(1, math.min(#entries, selected + button))
        end
    elseif event == "mouse_click" then
        local _, height = term.getSize()
        local index = firstVisible + y - 3
        if button == 1 and y >= 3 and y < 3 + visibleRows(height)
            and index >= firstVisible and index <= #entries then
            local wasSelected = selected == index
            selected = index
            if button == 1 and wasSelected then openSelected() end
        elseif button == 1 and y == height - 2 then
            local action = buttonAt(topButtons, x)
            if action == "create" then
                createFile()
            elseif action == "create-folder" then
                createFolder()
            elseif action == "edit" then
                editSelected()
            elseif action == "open" then
                openSelected()
            elseif action == "run" then
                runSelected()
            end
        elseif button == 1 and y == height - 1 then
            local action = buttonAt(bottomButtons, x)
            if action == "up" and currentDirectory ~= homeDirectory then
                if currentDirectory == currentRoot then
                    currentRoot = homeDirectory
                    currentDirectory = homeDirectory
                else
                    currentDirectory = parentDirectory(currentDirectory)
                end
                selected = 1
                refreshEntries()
                message = "Opened " .. displayPath(currentDirectory) .. "."
            elseif action == "home" then
                currentDirectory = homeDirectory
                currentRoot = homeDirectory
                authorizedProfileRoot = nil
                selected = 1
                refreshEntries()
                message = "Returned to your home directory."
            elseif action == "delete" then
                deleteSelected()
            elseif action == "exit" then
                return
            end
        end
    elseif event == "peripheral" or event == "peripheral_detach" then
        refreshEntries()
    elseif event == "file_transfer" then
        local transferredFiles = button.getFiles()
        local uploaded, failures = 0, {}
        for _, transferredFile in ipairs(transferredFiles) do
            local ok, result = saveTransferredFile(transferredFile)
            if ok then
                uploaded = uploaded + 1
            else
                table.insert(failures, result)
            end
        end
        refreshEntries()
        if #failures > 0 then
            message = table.concat(failures, " ")
        elseif uploaded > 0 then
            message = "Uploaded " .. uploaded .. " file(s) to " .. displayPath(currentDirectory) .. "."
        else
            message = "No files were uploaded."
        end
    end
end
