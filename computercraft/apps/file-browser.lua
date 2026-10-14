local requestedHome = ...
local homeDirectory = type(requestedHome) == "string"
    and requestedHome:gsub("^/+", ""):match("^users/[%w_-]+$")
    and ("/" .. requestedHome:gsub("^/+", "")) or "/users/default"
local currentDirectory = homeDirectory
fs.makeDir(homeDirectory)
local entries = {}
local selected = 1
local firstVisible = 1
local message = "Enter opens folders or files; E edits the selected file."
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

local function parentDirectory(path)
    if path == "/" then return "/" end
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return "/" end
    return parent
end

local function refreshEntries()
    local updated = {}
    if currentDirectory ~= homeDirectory then
        table.insert(updated, { name = "..", path = parentDirectory(currentDirectory), isDirectory = true })
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
    return math.max(1, height - 5)
end

local function draw()
    local width, height = term.getSize()
    local theme = themes[themeIndex]
    local accent = term.isColor() and theme.accent or colors.gray
    local highlight = term.isColor() and theme.highlight or colors.gray
    local rowCount = visibleRows(height)
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
    term.write(("Path: " .. currentDirectory):sub(1, math.max(0, width - 2)))

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
            term.setTextColor(entry.isDirectory and colors.cyan or colors.white)
            term.write(("  " .. label):sub(1, math.max(0, width - 2)))
        end
    end

    term.setCursorPos(2, height - 2)
    term.setTextColor(colors.yellow)
    term.write(message:sub(1, math.max(0, width - 2)))
    term.setCursorPos(2, height)
    term.setTextColor(colors.white)
    term.write("UP/DOWN move  DROP upload  ENTER open/edit  E edit")
    term.setBackgroundColor(colors.black)
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

    local ok, result = pcall(shell.run, "edit", entry.path)
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

local function confirmUploadOverwrite(path)
    term.clear()
    term.setCursorPos(1, 1)
    print(path .. " already exists.")
    write("Replace it with the dropped file? [y/N] ")
    local answer = read()
    return answer:lower() == "y"
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
    local temporary = destination .. ".upload-tmp"
    local backup = destination .. ".upload-bak"
    if fs.exists(temporary) then fs.delete(temporary) end
    if fs.exists(backup) then fs.delete(backup) end

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
    draw()
    local event, key, _, y = os.pullEventRaw()
    if event == "key" then
        if key == keys.up then
            if #entries > 0 then selected = math.max(1, selected - 1) end
        elseif key == keys.down then
            if #entries > 0 then selected = math.min(#entries, selected + 1) end
        elseif key == keys.enter then
            openSelected()
        elseif key == keys.e then
            editSelected()
        elseif key == keys.backspace then
            if currentDirectory ~= homeDirectory then
                currentDirectory = parentDirectory(currentDirectory)
                selected = 1
                refreshEntries()
                message = "Opened " .. currentDirectory .. "."
            end
        elseif key == keys.q or key == keys.escape then
            return
        end
    elseif event == "mouse_click" then
        local _, height = term.getSize()
        local index = firstVisible + y - 3
        if y >= 3 and y < 3 + visibleRows(height)
            and index >= firstVisible and index <= #entries then
            local wasSelected = selected == index
            selected = index
            if key == 1 and wasSelected then openSelected() end
        end
    elseif event == "file_transfer" then
        local transferredFiles = key.getFiles()
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
