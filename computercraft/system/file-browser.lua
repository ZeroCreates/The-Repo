local requestedHome = ...
local normalizedHome = type(requestedHome) == "string" and requestedHome:gsub("^/+", "")
local homeDirectory = normalizedHome and normalizedHome:match("^users/[%w_-]+$")
    and normalizedHome or "users/default"
local currentDirectory = homeDirectory
local currentRoot = homeDirectory
local diskMounts = {}
fs.makeDir(homeDirectory)
local entries = {}
local selected = 1
local firstVisible = 1
local message = "Ctrl+C copy, Ctrl+X cut, Ctrl+V paste. Drop files to upload."
local clipboard
local controlHeld = false
local themeIndex = 1
local themes = {
    { accent = colors.cyan, highlight = colors.blue },
    { accent = colors.lime, highlight = colors.green },
    { accent = colors.orange, highlight = colors.red },
    { accent = colors.purple, highlight = colors.magenta },
}

local function loadTheme()
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
    if currentRoot ~= homeDirectory and not isMountedDisk(currentRoot) then
        currentDirectory = homeDirectory
        currentRoot = homeDirectory
        message = "The disk was removed. Returned to your home directory."
    end

    local updated = {}
    if currentDirectory ~= currentRoot then
        table.insert(updated, { name = "..", path = parentDirectory(currentDirectory), isDirectory = true })
    elseif currentRoot ~= homeDirectory then
        table.insert(updated, {
            name = "..",
            path = homeDirectory,
            isDirectory = true,
            returnHome = true,
        })
    else
        for _, mount in ipairs(diskMounts) do
            table.insert(updated, {
                name = "[Disk] " .. mount.path,
                path = mount.path,
                isDirectory = true,
                diskRoot = true,
            })
        end
    end

    for _, name in ipairs(fs.list(currentDirectory)) do
        local path = fs.combine(currentDirectory, name)
        table.insert(updated, {
            name = name,
            path = path,
            isDirectory = fs.isDir(path),
        })
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
        { label = "NEW FOLDER", action = "create-folder" },
        { label = "EDIT", action = "edit" },
        { label = "OPEN", action = "open" },
    }
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
    local displayPath
    if currentRoot == homeDirectory then
        displayPath = currentDirectory == homeDirectory and "home/"
            or "home/" .. currentDirectory:sub(#homeDirectory + 2)
    else
        displayPath = currentDirectory
    end
    term.write(("Path: " .. displayPath):sub(1, math.max(0, width - 2)))

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
    term.write(message:sub(1, math.max(0, width - 2)))
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

local function createFile()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Create a file in " .. currentDirectory)
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
    print("Create a folder in " .. currentDirectory)
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
    print(path .. " already exists.")
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
    print("Delete " .. path .. "?")
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
    if not entry or entry.name == ".." then
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
    if (clipboard.root ~= homeDirectory and not isMountedDisk(clipboard.root))
        or not isWithinRoot(clipboard.path, clipboard.root)
        or not fs.exists("/" .. clipboard.path) then
        clipboard = nil
        message = "The copied or cut file is no longer available."
        return
    end

    local destination = fs.combine(currentDirectory, clipboard.name)
    local absoluteSource = "/" .. clipboard.path
    local absoluteDestination = "/" .. destination
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
    message = "Pasted " .. fs.getName(destination) .. " into " .. currentDirectory .. "."
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
            return false, "Could not back up " .. destination .. ": " .. tostring(moveError)
        end
    end

    local moved, moveError = pcall(fs.move, temporary, destination)
    if not moved then
        if fs.exists(temporary) then fs.delete(temporary) end
        if fs.exists(backup) then fs.move(backup, destination) end
        return false, "Could not save " .. destination .. ": " .. tostring(moveError)
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
        selected = 1
        refreshEntries()
        message = "Opened disk " .. entry.path .. "."
        return
    end
    if entry.returnHome then
        currentRoot = homeDirectory
        currentDirectory = homeDirectory
        selected = 1
        refreshEntries()
        message = "Returned to your home directory."
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
        message = "Opened " .. currentDirectory .. "."
    else
        editSelected()
    end
end

refreshEntries()
while true do
    local topButtons, bottomButtons = draw()
    local event, button, x, y = os.pullEventRaw()
    if event == "key" then
        if button == keys.leftCtrl or button == keys.rightCtrl then
            controlHeld = true
        elseif controlHeld and button == keys.c then
            copyOrCutSelected("copy")
        elseif controlHeld and button == keys.x then
            copyOrCutSelected("cut")
        elseif controlHeld and button == keys.v then
            pasteClipboard()
        end
    elseif event == "key_up" then
        if button == keys.leftCtrl or button == keys.rightCtrl then
            controlHeld = false
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
                message = "Opened " .. currentDirectory .. "."
            elseif action == "home" then
                currentDirectory = homeDirectory
                currentRoot = homeDirectory
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
            message = "Uploaded " .. uploaded .. " file(s) to " .. currentDirectory .. "."
        else
            message = "No files were uploaded."
        end
    end
end
