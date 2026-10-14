term.clear()
term.setCursorPos(1, 1)
print("Countdown Timer")
write("Countdown length in seconds (1-86400): ")
local seconds = tonumber(read())

if not seconds or seconds % 1 ~= 0 or seconds < 1 or seconds > 86400 then
    print("Enter a whole number from 1 to 86400.")
    return
end

for remaining = seconds, 1, -1 do
    term.setCursorPos(1, 3)
    term.clearLine()
    write("Time remaining: " .. remaining .. " second(s)")
    sleep(1)
end

print("")
print("Time's up!")
local speaker = peripheral.find("speaker")
if speaker then speaker.playSound("minecraft:block.note_block.pling") end
print("Press any key to return.")
os.pullEventRaw("key")
