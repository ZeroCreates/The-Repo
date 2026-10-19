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
print("Countdown Timer")
term.setTextColor(colors.white)
term.setTextColor(term.isColor() and accent or colors.white)
write("Countdown length in seconds (1-86400): ")
term.setTextColor(colors.white)
local seconds = tonumber(read())

if not seconds or seconds % 1 ~= 0 or seconds < 1 or seconds > 86400 then
    print("Enter a whole number from 1 to 86400.")
    return
end

for remaining = seconds, 1, -1 do
    term.setCursorPos(1, 3)
    term.clearLine()
    term.setTextColor(term.isColor() and accent or colors.white)
    write("Time remaining: " .. remaining .. " second(s)")
    term.setTextColor(colors.white)
    sleep(1)
end

print("")
term.setTextColor(term.isColor() and accent or colors.white)
print("Time's up!")
local speaker = peripheral.find("speaker")
if speaker then speaker.playSound("minecraft:block.note_block.pling") end
print("Press any key to return.")
os.pullEventRaw("key")
