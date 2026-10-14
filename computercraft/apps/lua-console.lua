local function printResults(results)
    for index = 2, #results do
        print(tostring(results[index]))
    end
end

local function compile(source)
    local chunk, compileError = load("return " .. source, "lua-console")
    if chunk then return chunk end
    return load(source, "lua-console")
end

local themeAccent = colors.cyan
local function loadTheme()
    local path = "/.launcher/settings.json"
    if not fs.exists(path) then return end
    local file = fs.open(path, "r")
    if not file then return end
    local contents = file.readAll()
    file.close()
    local ok, settings = pcall(textutils.unserializeJSON, contents)
    if not ok or type(settings) ~= "table" then return end
    local accents = { colors.cyan, colors.lime, colors.orange, colors.purple }
    if type(settings.theme) == "number" and accents[settings.theme] then
        themeAccent = accents[settings.theme]
    end
end

loadTheme()
local commandHistory = {}
term.setBackgroundColor(colors.black)
term.setTextColor(term.isColor() and themeAccent or colors.gray)
term.clear()
term.setCursorPos(1, 1)
print("Lua Console")
term.setTextColor(colors.lightGray)
print("Type help for commands, or exit to return to the launcher.")
print("")

while true do
    term.setTextColor(term.isColor() and themeAccent or colors.white)
    write("> ")
    term.setTextColor(colors.white)
    local input = read(nil, commandHistory, function(line)
        local startPosition = line:find("[a-zA-Z0-9_%.:]+$")
        if not startPosition then return nil end
        local prefix = line:sub(startPosition)
        if prefix == "" then return nil end
        return textutils.complete(prefix, _ENV)
    end)
    if input:match("%S") and commandHistory[#commandHistory] ~= input then
        table.insert(commandHistory, input)
    end
    local command = input:lower()

    if command == "exit" or command == "quit" then
        return
    elseif command == "help" then
        print("Enter Lua expressions or statements to run them.")
        print("Variables assigned globally remain available between commands.")
        print("Commands: help, clear, exit")
    elseif command == "clear" then
        term.clear()
        term.setCursorPos(1, 1)
    elseif input ~= "" then
        local chunk, compileError = compile(input)
        if not chunk then
            printError(compileError)
        else
            local results = { pcall(chunk) }
            if not results[1] then
                printError(results[2])
            else
                printResults(results)
            end
        end
    end
end
