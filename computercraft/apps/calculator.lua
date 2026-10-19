local function applyTheme()
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

local accent = applyTheme()
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(term.isColor() and accent or colors.white)
print("Simple Calculator")
term.setTextColor(colors.lightGray)
print("Type q at the first prompt to quit.")
print("")

while true do
    term.setTextColor(term.isColor() and accent or colors.white)
    write("First number: ")
    term.setTextColor(colors.white)
    local firstInput = read()
    if firstInput:lower() == "q" then return end
    local first = tonumber(firstInput)

    term.setTextColor(term.isColor() and accent or colors.white)
    write("Operator (+, -, *, /): ")
    term.setTextColor(colors.white)
    local operator = read()
    term.setTextColor(term.isColor() and accent or colors.white)
    write("Second number: ")
    term.setTextColor(colors.white)
    local second = tonumber(read())

    if not first or not second then
        print("Enter valid numbers.")
    elseif operator == "+" then
        print("Result: " .. (first + second))
    elseif operator == "-" then
        print("Result: " .. (first - second))
    elseif operator == "*" then
        print("Result: " .. (first * second))
    elseif operator == "/" and second ~= 0 then
        print("Result: " .. (first / second))
    elseif operator == "/" then
        print("Cannot divide by zero.")
    else
        print("Unknown operator.")
    end
    print("")
end
