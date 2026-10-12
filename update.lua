local ROLE_FILES = {
    server = "server.lua",
    provider = "provider.lua",
    client = "client.lua",
    packager = "packager.lua",
}
local CONFIG_FILE = "order-system.cfg"
local OWNER_REPO = "ZeroCreates/The-Repo"
local BRANCH = "main"

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
    error("No installed role found. Run install.lua and choose a role first.")
end

local configFile = fs.open(CONFIG_FILE, "r")
local configText = configFile.readAll()
configFile.close()
local parsed, config = pcall(textutils.unserialize, configText)
if not parsed or type(config) ~= "table" or not ROLE_FILES[config.role] then
    error("The installed role configuration is invalid. Run install.lua again.")
end

local roleFile = ROLE_FILES[config.role]
local FILES = { roleFile, "update.lua", "install.lua" }
local staged = {}
print("Checking GitHub for updates: " .. OWNER_REPO .. " (" .. BRANCH .. ")")
for _, name in ipairs(FILES) do
    local url = "https://raw.githubusercontent.com/" .. OWNER_REPO .. "/" .. BRANCH .. "/" .. name
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

for otherRole, otherFile in pairs(ROLE_FILES) do
    if otherRole ~= config.role and fs.exists(otherFile) then
        local backup = otherFile .. ".bak"
        if fs.exists(backup) then fs.delete(backup) end
        fs.move(otherFile, backup)
    end
end

print("The " .. config.role .. " system is updated. Restart running scripts to use the new version.")