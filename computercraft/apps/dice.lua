term.clear()
term.setCursorPos(1, 1)
print("Dice Roller")
write("How many dice? (1-100): ")
local count = tonumber(read())
write("How many sides per die? (2-1000): ")
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
print("Rolls: " .. table.concat(rolls, ", "))
print("Total: " .. total)
