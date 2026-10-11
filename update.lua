local CONFIG_FILE = "order-system.cfg"
local FILES = { "server.lua", "client.lua", "provider.lua", "update.lua", "install.lua" }

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

if not http or not http.get then
    error("Enable the ComputerCraft HTTP API, then run update again.")
end
if not fs.exists(CONFIG_FILE) then
    error("No install configuration found. Run install.lua first.")
end

local configFile = fs.open(CONFIG_FILE, "r")
local configText = configFile.readAll()
configFile.close()
local parsed, config = pcall(textutils.unserialize, configText)
if not parsed or type(config) ~= "table"
    or type(config.ownerRepo) ~= "string" or type(config.branch) ~= "string" then
    error("The saved GitHub source is invalid. Run install.lua again.")
end

local staged = {}
print("Checking GitHub for updates: " .. config.ownerRepo .. " (" .. config.branch .. ")")
for _, name in ipairs(FILES) do
    local url = "https://raw.githubusercontent.com/" .. config.ownerRepo .. "/" .. config.branch .. "/" .. name
    local contents, err = fetch(url)
    if not contents then
        for _, tempPath in pairs(staged) do
            if fs.exists(tempPath) then fs.delete(tempPath) end
        end
        error("Update stopped before changing installed files. Could not download " .. name .. ": " .. err)
    end

    local tempPath = name .. ".update-tmp"
    if fs.exists(tempPath) then fs.delete(tempPath) end
    local file = fs.open(tempPath, "w")
    if not file then error("Could not create " .. tempPath) end
    file.write(contents)
    file.close()
    staged[name] = tempPath
    print("Downloaded " .. name)
end

local installed = {}
for _, name in ipairs(FILES) do
    local backup = name .. ".bak"
    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(name) then fs.move(name, backup) end

    local ok, err = pcall(fs.move, staged[name], name)
    if not ok then
        if fs.exists(name) then fs.delete(name) end
        if fs.exists(backup) then fs.move(backup, name) end
        for index = #installed, 1, -1 do
            local previous = installed[index]
            if fs.exists(previous) then fs.delete(previous) end
            if fs.exists(previous .. ".bak") then fs.move(previous .. ".bak", previous) end
        end
        error("Update failed and previous files were restored: " .. tostring(err))
    end
    table.insert(installed, name)
end

print("All scripts updated. Restart running scripts to use the new versions.")