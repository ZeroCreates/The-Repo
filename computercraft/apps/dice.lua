local function loadTheme()
    if type(launcherTheme) == "table" and type(launcherTheme.accent) == "number" then
        return term.isColor() and launcherTheme.accent or colors.gray
    end
    local path = "/.launcher/settings.json"
    if not fs.exists(path) then return colors.cyan end
    local file = fs.open(path, "r")
    if not file then return colors.cyan end
    local contents = file.readAll()
    file.close()
    local ok, saved = pcall(textutils.unserializeJSON, contents)
    local accents = { colors.cyan, colors.lime, colors.orange, colors.purple }
    if ok and type(saved) == "table" and accents[saved.theme] then return accents[saved.theme] end
    return colors.cyan
end

local accent = loadTheme()
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(term.isColor() and accent or colors.white)
print("Dice Roller")
term.setTextColor(term.isColor() and accent or colors.white)
write("How many dice? (1-100): ")
term.setTextColor(colors.white)
local count = tonumber(read())
term.setTextColor(term.isColor() and accent or colors.white)
write("How many sides per die? (2-1000): ")
term.setTextColor(colors.white)
local sides = tonumber(read())

if not count or count % 1 ~= 0 or count < 1 or count > 100 then
    print("Dice count must be a whole number from 1 to 100.")
    return
end
if not sides or sides % 1 ~= 0 or sides < 2 or sides > 1000 then
    print("Sides must be a whole number from 2 to 1000.")
    return
end

local rolls = {}
local total = 0
for index = 1, count do
    rolls[index] = math.random(1, sides)
    total = total + rolls[index]
end

print("")
term.setTextColor(term.isColor() and accent or colors.white)
print("Rolls: " .. table.concat(rolls, ", "))
print("Total: " .. total)
