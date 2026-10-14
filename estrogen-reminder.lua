local REMINDER_TEXT = "Eat your estrogen"
local REMINDER_INTERVAL = 4 * 60
local DISPLAY_DURATION = 10
local SCREEN_WIDTH = 1600
local SCREEN_HEIGHT = 900
local REMINDER_ID = "estrogen-reminder"
local REMINDER_COLOR = 0xff69b4

local controller = peripheral.find("ar_controller") or peripheral.find("arController")
if not controller then
    error("Advanced Peripherals AR Controller not found. Connect one and link your Smart Glasses.")
end

controller.setRelativeMode(true, SCREEN_WIDTH, SCREEN_HEIGHT)

while true do
    controller.drawCenteredStringWithId(
        REMINDER_ID,
        REMINDER_TEXT,
        SCREEN_WIDTH / 2,
        SCREEN_HEIGHT / 2,
        REMINDER_COLOR
    )
    sleep(DISPLAY_DURATION)
    controller.clearElement(REMINDER_ID)
    sleep(REMINDER_INTERVAL - DISPLAY_DURATION)
end
