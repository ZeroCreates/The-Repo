local CONFIG_FILE = "order-system.cfg"
local FILES = { "server.lua", "client.lua", "provider.lua", "update.lua", "install.lua" }

local function validSource(ownerRepo, branch)
    return type(ownerRepo) == "string"
        and ownerRepo:match("^[%w_.-]+/[%w_.-]+$") ~= nil
        and type(branch) == "string"
        and branch:match("^[%w_./-]+$") ~= nil
        and not branch:find("%.%.")
        and branch:sub(1, 1) ~= "/"
        and branch:sub(-1) ~= "/"
end

local function fetch(url)
    local response, err = http.get(url)
    if not response then return nil, err or "HTTP request failed." end
    local code = response.getResponseCode and response.getResponseCode()
    if code and code ~= 200 then
        response.close()
        return nil, "GitHub returned HTTP " .. code .. "."
    end
    local contents = response.readAll()
    response.close()
    if not contents or contents == "" then return nil, "GitHub returned an empty file." end
    return contents
end

local function stageFile(name, contents)
    local tempPath = name .. ".install-tmp"
    if fs.exists(tempPath) then fs.delete(tempPath) end
    local file = fs.open(tempPath, "w")
    if not file then return nil, "Could not create " .. tempPath end
    file.write(contents)
    file.close()
    return tempPath
end

local function installStaged(staged)
    local installed = {}
    for _, name in ipairs(FILES) do
        local path = name
        local backup = name .. ".bak"
        if fs.exists(backup) then fs.delete(backup) end
        if fs.exists(path) then fs.move(path, backup) end

        local ok, err = pcall(fs.move, staged[name], path)
        if not ok then
            if fs.exists(path) then fs.delete(path) end
            if fs.exists(backup) then fs.move(backup, path) end
            for index = #installed, 1, -1 do
                local previous = installed[index]
                if fs.exists(previous) then fs.delete(previous) end
                if fs.exists(previous .. ".bak") then fs.move(previous .. ".bak", previous) end
            end
            return nil, tostring(err)
        end
        table.insert(installed, path)
    end
    return true
end

local ownerRepo, branch = ...
if not ownerRepo then
    write("GitHub repository (owner/repo): ")
    ownerRepo = read()
end
if not branch then
    write("Branch [main]: ")
    branch = read()
    if branch == "" then branch = "main" end
end

if not validSource(ownerRepo, branch) then
    error("Use a GitHub owner/repo and a valid branch name.")
end
if not http or not http.get then
    error("Enable the ComputerCraft HTTP API, then run install again.")
end

print("Downloading order system from " .. ownerRepo .. " (" .. branch .. ")...")
local staged = {}
for _, name in ipairs(FILES) do
    local url = "https://raw.githubusercontent.com/" .. ownerRepo .. "/" .. branch .. "/" .. name
    local contents, err = fetch(url)
    if not contents then
        for _, tempPath in pairs(staged) do
            if fs.exists(tempPath) then fs.delete(tempPath) end
        end
        error("Could not download " .. name .. ": " .. err)
    end
    local tempPath, stageError = stageFile(name, contents)
    if not tempPath then error(stageError) end
    staged[name] = tempPath
    print("Downloaded " .. name)
end

write("Install these files into this computer's root? [y/N] ")
if read():lower() ~= "y" then
    for _, tempPath in pairs(staged) do
        if fs.exists(tempPath) then fs.delete(tempPath) end
    end
    print("Installation cancelled.")
    return
end

local ok, err = installStaged(staged)
if not ok then error("Installation failed: " .. err) end

local config = fs.open(CONFIG_FILE, "w")
config.write(textutils.serialize({ ownerRepo = ownerRepo, branch = branch }))
config.close()
print("Installed. Run client, provider, or server to start.")