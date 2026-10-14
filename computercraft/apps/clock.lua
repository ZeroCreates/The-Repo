local function draw()
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.write((" " .. "CLOCK"):sub(1, width))
    term.setBackgroundColor(colors.black)

    local date = os.date("%A, %B %d, %Y")
    local time = os.date("%I:%M:%S %p")
    term.setCursorPos(math.max(1, math.floor((width - #date) / 2)), math.max(2, math.floor(height / 2) - 1))
    term.setTextColor(colors.lightBlue)
    term.write(date)
    term.setCursorPos(math.max(1, math.floor((width - #time) / 2)), math.max(3, math.floor(height / 2)))
    term.setTextColor(colors.white)
    term.write(time)
    term.setCursorPos(2, height)
    term.setTextColor(colors.lightGray)
    term.write("Press Q to return to the launcher.")
end

while true do
    draw()
    local timer = os.startTimer(1)
    while true do
        local event, value = os.pullEventRaw()
        if event == "key" and value == keys.q then return end
        if event == "timer" and value == timer then break end
    end
end
