term.clear()
term.setCursorPos(1, 1)
print("Simple Calculator")
print("Type q at the first prompt to quit.")
print("")

while true do
    write("First number: ")
    local firstInput = read()
    if firstInput:lower() == "q" then return end
    local first = tonumber(firstInput)

    write("Operator (+, -, *, /): ")
    local operator = read()
    write("Second number: ")
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
