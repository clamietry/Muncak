--[[
    MUNCAK RECORDER - CLEAN STABLE
    Fokus versi ini:
    - Record / Pause / Stop & Save
    - Load / Play / Pause / Stop
    - Speed 0.25x - 3x
    - Adaptive sampling sederhana (berdasarkan gerak/rotasi)
    - Save/load JSON via executor filesystem
    - Compression aman saat save
    - Teleport/respawn detection
    - GUI compact untuk mobile

    Catatan:
    Versi ini sengaja TIDAK memakai velocity/acceleration/Hermite dulu.
    Fondasi dibuat sederhana supaya record -> save -> load -> playback
    stabil terlebih dahulu.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
    Folder = "MuncakRecorder",
    DefaultFile = "muncak_route.json",

    BaseInterval = 1 / 30,
    FastInterval = 1 / 45,
    SlowInterval = 1 / 12,

    PositionThreshold = 0.045,
    RotationThreshold = math.rad(1.0),

    CompressionPosition = 0.035,
    CompressionRotation = math.rad(0.65),

    TeleportDistance = 80,

    DefaultSpeed = 1,
    MinSpeed = 0.25,
    MaxSpeed = 3,
    SpeedStep = 0.25,

    GuiScale = 0.82,
}

local State = {
    Recording = false,
    RecordPaused = false,

    Playing = false,
    PlaybackPaused = false,

    RecordedPath = {},
    LoadedPath = {},

    PlaybackTime = 0,
    PlaybackDuration = 0,
    Speed = CONFIG.DefaultSpeed,

    CurrentRoot = nil,

    RecordToken = 0,
    PlaybackToken = 0,

    RecordStartedAt = 0,
    RecordPausedAt = nil,
    RecordPausedTotal = 0,
}

-- ============================================================
-- SAFE HELPERS
-- ============================================================

local function safeTraceback(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err))
    end
    return tostring(err)
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function number(v, fallback)
    v = tonumber(v)
    if v == nil then
        return fallback
    end
    return v
end

local function getRoot()
    local character = LocalPlayer.Character
    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
        or character.PrimaryPart
end

local function getCharacterReady()
    local root = getRoot()
    if root and root:IsA("BasePart") then
        State.CurrentRoot = root
        return root
    end

    State.CurrentRoot = nil
    return nil
end

-- ============================================================
-- CFRAME SERIALIZATION
-- ============================================================

local function serializeCFrame(cf)
    local components = {cf:GetComponents()}
    return components
end

local function deserializeCFrame(data)
    if type(data) ~= "table" or #data < 12 then
        return nil
    end

    local n = table.create(12)
    for i = 1, 12 do
        n[i] = tonumber(data[i])
        if n[i] == nil then
            return nil
        end
    end

    return CFrame.new(
        n[1], n[2], n[3],
        n[4], n[5], n[6],
        n[7], n[8], n[9],
        n[10], n[11], n[12]
    )
end

-- ============================================================
-- FILESYSTEM
-- ============================================================

local FS = {}

function FS.available()
    return type(writefile) == "function"
        and type(readfile) == "function"
        and type(isfile) == "function"
end

function FS.ensureFolder()
    if not FS.available() then
        return false, "filesystem API tidak tersedia"
    end

    if type(isfolder) == "function" and isfolder(CONFIG.Folder) then
        return true
    end

    if type(makefolder) == "function" then
        local ok, err = pcall(makefolder, CONFIG.Folder)
        if ok then
            return true
        end

        -- Folder may already exist or executor may report a harmless error.
        if type(isfolder) == "function" and isfolder(CONFIG.Folder) then
            return true
        end

        return false, tostring(err)
    end

    -- Some executors expose writefile but not folders.
    -- Fall back to root filename.
    return true
end

function FS.path(filename)
    filename = tostring(filename or "")
    filename = filename:gsub("[/\\]", "_")

    if filename == "" then
        filename = CONFIG.DefaultFile
    end

    if not filename:lower():match("%.json$") then
        filename = filename .. ".json"
    end

    if FS.ensureFolder() and type(isfolder) == "function" and isfolder(CONFIG.Folder) then
        return CONFIG.Folder .. "/" .. filename
    end

    return filename
end

function FS.write(filename, value)
    if not FS.available() then
        return false, "writefile/readfile/isfile tidak tersedia"
    end

    local okFolder, folderErr = FS.ensureFolder()
    if not okFolder then
        return false, folderErr
    end

    local path = FS.path(filename)

    local okEncode, encoded = pcall(function()
        return HttpService:JSONEncode(value)
    end)

    if not okEncode then
        return false, "JSONEncode gagal: " .. tostring(encoded)
    end

    local okWrite, writeErr = pcall(writefile, path, encoded)
    if not okWrite then
        return false, "writefile gagal: " .. tostring(writeErr)
    end

    if type(isfile) == "function" and not isfile(path) then
        return false, "file tidak terdeteksi setelah writefile"
    end

    return true, path
end

function FS.read(filename)
    if not FS.available() then
        return false, "filesystem API tidak tersedia"
    end

    local path = FS.path(filename)

    if type(isfile) == "function" and not isfile(path) then
        -- Also try the raw filename for executors that don't support folders.
        if isfile(filename) then
            path = filename
        else
            return false, "file tidak ditemukan: " .. path
        end
    end

    local okRead, raw = pcall(readfile, path)
    if not okRead then
        return false, "readfile gagal: " .. tostring(raw)
    end

    local okDecode, decoded = pcall(function()
        return HttpService:JSONDecode(raw)
    end)

    if not okDecode then
        return false, "JSONDecode gagal: " .. tostring(decoded)
    end

    return true, decoded
end

-- ============================================================
-- PATH VALIDATION
-- ============================================================

local function validSample(sample)
    if type(sample) ~= "table" then
        return false
    end

    local t = tonumber(sample.t)
    if t == nil or t < 0 then
        return false
    end

    return deserializeCFrame(sample.cf) ~= nil
end

local function sanitizePath(path)
    if type(path) ~= "table" then
        return {}
    end

    local result = {}
    local lastT = -math.huge

    for _, sample in ipairs(path) do
        if validSample(sample) then
            local t = tonumber(sample.t)

            if t >= lastT then
                table.insert(result, {
                    t = t,
                    cf = sample.cf,
                })
                lastT = t
            end
        end
    end

    return result
end

-- ============================================================
-- COMPRESSION
-- ============================================================

local function rotationDifference(a, b)
    local _, _, _, a00,a01,a02,a10,a11,a12,a20,a21,a22 = a:GetComponents()
    local _, _, _, b00,b01,b02,b10,b11,b12,b20,b21,b22 = b:GetComponents()

    local trace =
        a00*b00 + a01*b01 + a02*b02 +
        a10*b10 + a11*b11 + a12*b12 +
        a20*b20 + a21*b21 + a22*b22

    return math.acos(clamp((trace - 1) / 2, -1, 1))
end

local function compressPath(path)
    if #path <= 2 then
        return path
    end

    local result = {path[1]}

    for i = 2, #path - 1 do
        local prev = result[#result]
        local cur = path[i]
        local nextSample = path[i + 1]

        local a = deserializeCFrame(prev.cf)
        local b = deserializeCFrame(cur.cf)
        local c = deserializeCFrame(nextSample.cf)

        if not a or not b or not c then
            table.insert(result, cur)
        else
            local distance = (b.Position - a.Position).Magnitude
            local rotation = rotationDifference(a, b)

            -- Keep sharp turns and meaningful movement.
            local keep =
                distance >= CONFIG.CompressionPosition
                or rotation >= CONFIG.CompressionRotation

            -- Also preserve a point if the direction changes strongly.
            local ab = b.Position - a.Position
            local bc = c.Position - b.Position

            if ab.Magnitude > 0.001 and bc.Magnitude > 0.001 then
                local angle = math.acos(clamp(ab.Unit:Dot(bc.Unit), -1, 1))
                if angle >= math.rad(4) then
                    keep = true
                end
            end

            if keep then
                table.insert(result, cur)
            end
        end
    end

    table.insert(result, path[#path])
    return result
end

-- ============================================================
-- RECORD CLOCK
-- ============================================================

local function recordTime()
    local now = os.clock()

    if State.RecordPaused and State.RecordPausedAt then
        return State.RecordPausedAt
            - State.RecordStartedAt
            - State.RecordPausedTotal
    end

    return now - State.RecordStartedAt - State.RecordPausedTotal
end

local function adaptiveInterval(root)
    if not root then
        return CONFIG.BaseInterval
    end

    local speed = root.AssemblyLinearVelocity.Magnitude

    if speed < 0.15 then
        return CONFIG.SlowInterval
    elseif speed > 8 then
        return CONFIG.FastInterval
    end

    local alpha = clamp((speed - 0.15) / (8 - 0.15), 0, 1)

    return CONFIG.SlowInterval
        + (CONFIG.FastInterval - CONFIG.SlowInterval) * alpha
end

-- ============================================================
-- GUI
-- ============================================================

local oldGui = PlayerGui:FindFirstChild("MuncakRecorderClean")
if oldGui then
    oldGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "MuncakRecorderClean"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

local UIScale = Instance.new("UIScale")
UIScale.Scale = CONFIG.GuiScale
UIScale.Parent = ScreenGui

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.Size = UDim2.fromOffset(400, 455)
Main.Position = UDim2.new(0.5, -200, 0.5, -228)
Main.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
Main.BorderSizePixel = 0
Main.Parent = ScreenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = Main

local stroke = Instance.new("UIStroke")
stroke.Thickness = 1
stroke.Transparency = 0.25
stroke.Parent = Main

local Padding = Instance.new("UIPadding")
Padding.PaddingTop = UDim.new(0, 10)
Padding.PaddingBottom = UDim.new(0, 10)
Padding.PaddingLeft = UDim.new(0, 10)
Padding.PaddingRight = UDim.new(0, 10)
Padding.Parent = Main

local function makeLabel(parent, text, size, position)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235, 235, 240)
    label.TextSize = size
    label.Font = Enum.Font.Gotham
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Position = position
    label.Size = UDim2.new(1, 0, 0, 22)
    label.Parent = parent
    return label
end

local function makeButton(parent, text, position, size)
    local button = Instance.new("TextButton")
    button.Text = text
    button.TextColor3 = Color3.fromRGB(230, 230, 235)
    button.TextSize = 14
    button.Font = Enum.Font.GothamMedium
    button.BackgroundColor3 = Color3.fromRGB(48, 48, 55)
    button.BorderSizePixel = 0
    button.Position = position
    button.Size = size
    button.AutoButtonColor = true
    button.Parent = parent

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 7)
    c.Parent = button

    return button
end

local Title = makeLabel(Main, "Muncak Recorder — Stable", 16, UDim2.fromOffset(10, 4))
Title.Font = Enum.Font.GothamBold

local Close = makeButton(Main, "×", UDim2.new(1, -40, 0, 2), UDim2.fromOffset(30, 28))
Close.TextSize = 18

local Minimize = makeButton(Main, "—", UDim2.new(1, -75, 0, 2), UDim2.fromOffset(30, 28))
Minimize.TextSize = 18

local FileLabel = makeLabel(Main, "Filename", 12, UDim2.fromOffset(10, 43))

local FileBox = Instance.new("TextBox")
FileBox.Text = CONFIG.DefaultFile
FileBox.PlaceholderText = "nama_file.json"
FileBox.TextColor3 = Color3.fromRGB(235, 235, 240)
FileBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 135)
FileBox.TextSize = 13
FileBox.Font = Enum.Font.Gotham
FileBox.BackgroundColor3 = Color3.fromRGB(42, 42, 48)
FileBox.BorderSizePixel = 0
FileBox.Position = UDim2.fromOffset(10, 66)
FileBox.Size = UDim2.new(1, -20, 0, 40)
FileBox.ClearTextOnFocus = false
FileBox.Parent = Main

local fileCorner = Instance.new("UICorner")
fileCorner.CornerRadius = UDim.new(0, 7)
fileCorner.Parent = FileBox

local RecordButton = makeButton(Main, "●  START RECORDING", UDim2.fromOffset(10, 116), UDim2.new(1, -20, 0, 42))
local RecordPauseButton = makeButton(Main, "Ⅱ  PAUSE RECORDING", UDim2.fromOffset(10, 164), UDim2.new(1, -20, 0, 38))
local SaveButton = makeButton(Main, "■  STOP & SAVE", UDim2.fromOffset(10, 208), UDim2.new(1, -20, 0, 38))

local LoadButton = makeButton(Main, "LOAD", UDim2.fromOffset(10, 252), UDim2.new(0.32, -5, 0, 38))
local PlayButton = makeButton(Main, "PLAY", UDim2.new(0.34, 0, 0, 252), UDim2.new(0.32, -5, 0, 38))
local PlaybackPauseButton = makeButton(Main, "PAUSE", UDim2.new(0.68, 0, 0, 252), UDim2.new(0.32, -5, 0, 38))

local StopPlaybackButton = makeButton(Main, "STOP PLAYBACK", UDim2.fromOffset(10, 296), UDim2.new(1, -20, 0, 36))

local Info = makeLabel(Main, "Points: 0\nDuration: 00:00.00\nSpeed: 1.00x", 12, UDim2.fromOffset(10, 342))
Info.Size = UDim2.new(1, -20, 0, 54)
Info.TextYAlignment = Enum.TextYAlignment.Top

local Status = makeLabel(Main, "Ready", 11, UDim2.fromOffset(10, 400))
Status.Size = UDim2.new(1, -20, 0, 35)
Status.TextColor3 = Color3.fromRGB(170, 170, 180)
Status.TextWrapped = true

local SpeedLabel = makeLabel(Main, "Speed: 1.00x", 11, UDim2.fromOffset(10, 432))
SpeedLabel.Size = UDim2.new(0.55, 0, 0, 18)

local SpeedDown = makeButton(Main, "−", UDim2.new(0.62, 0, 0, 428), UDim2.fromOffset(35, 24))
local SpeedUp = makeButton(Main, "+", UDim2.new(0.74, 0, 0, 428), UDim2.fromOffset(35, 24))
local SpeedReset = makeButton(Main, "1x", UDim2.new(0.86, 0, 0, 428), UDim2.fromOffset(45, 24))

-- Dragging
local dragging = false
local dragStart
local startPosition

local function updateDrag(input)
    local delta = input.Position - dragStart
    Main.Position = UDim2.new(
        startPosition.X.Scale,
        startPosition.X.Offset + delta.X,
        startPosition.Y.Scale,
        startPosition.Y.Offset + delta.Y
    )
end

Title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = true
        dragStart = input.Position
        startPosition = Main.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (
        input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    ) then
        updateDrag(input)
    end
end)

local minimized = false
local savedSize = Main.Size

Minimize.MouseButton1Click:Connect(function()
    minimized = not minimized

    for _, child in ipairs(Main:GetChildren()) do
        if child ~= Minimize and child ~= Close and child:IsA("GuiObject") then
            child.Visible = not minimized
        end
    end

    Minimize.Visible = true
    Close.Visible = true

    Main.Size = minimized
        and UDim2.fromOffset(400, 42)
        or savedSize
end)

Close.MouseButton1Click:Connect(function()
    State.Recording = false
    State.Playing = false
    State.RecordPaused = false
    State.PlaybackPaused = false

    ScreenGui:Destroy()
end)

-- ============================================================
-- UI STATUS
-- ============================================================

local function setStatus(text)
    if Status and Status.Parent then
        Status.Text = tostring(text)
    end
end

local function updateInfo()
    local duration = 0

    if State.Recording then
        duration = math.max(recordTime(), 0)
    elseif #State.RecordedPath > 0 then
        duration = number(State.RecordedPath[#State.RecordedPath].t, 0)
    elseif #State.LoadedPath > 0 then
        duration = number(State.LoadedPath[#State.LoadedPath].t, 0)
    end

    local points = math.max(#State.RecordedPath, #State.LoadedPath)

    Info.Text = string.format(
        "Points: %d\nDuration: %02d:%05.2f\nSpeed: %.2fx",
        points,
        math.floor(duration / 60),
        duration % 60,
        State.Speed
    )

    SpeedLabel.Text = string.format("Speed: %.2fx", State.Speed)
end

-- ============================================================
-- RECORDING
-- ============================================================

local function stopRecording(saveAfter)
    if not State.Recording and #State.RecordedPath == 0 then
        return
    end

    State.Recording = false
    State.RecordPaused = false

    if not saveAfter then
        setStatus("Recording stopped")
        return
    end

    if #State.RecordedPath == 0 then
        setStatus("Tidak ada sample untuk disimpan")
        return
    end

    local output = sanitizePath(State.RecordedPath)

    if #output == 1 then
        local first = output[1]
        table.insert(output, {
            t = first.t + 1 / 30,
            cf = first.cf,
        })
    end

    output = compressPath(output)

    local ok, result = FS.write(FileBox.Text, output)

    if ok then
        setStatus(string.format("Saved: %s | %d samples", tostring(result), #output))
    else
        setStatus("Save gagal: " .. tostring(result))
    end

    updateInfo()
end

local function startRecording()
    if State.Recording then
        return
    end

    if State.Playing then
        State.Playing = false
        State.PlaybackPaused = false
    end

    local root = getCharacterReady()
    if not root then
        setStatus("Character/HumanoidRootPart belum siap")
        return
    end

    State.RecordToken += 1
    local token = State.RecordToken

    State.RecordedPath = {}
    State.Recording = true
    State.RecordPaused = false
    State.RecordStartedAt = os.clock()
    State.RecordPausedAt = nil
    State.RecordPausedTotal = 0

    -- Immediate first sample.
    table.insert(State.RecordedPath, {
        t = 0,
        cf = serializeCFrame(root.CFrame),
    })

    local lastCF = root.CFrame
    local nextInterval = CONFIG.BaseInterval

    setStatus("Recording aktif | sample 1")
    updateInfo()

    task.spawn(function()
        local ok, err = xpcall(function()
            while State.Recording and State.RecordToken == token do
                if State.RecordPaused then
                    task.wait(0.05)
                    continue
                end

                root = getCharacterReady()

                if not root then
                    task.wait(0.1)
                    continue
                end

                local now = recordTime()
                local cf = root.CFrame

                local distance = (cf.Position - lastCF.Position).Magnitude
                local rotation = rotationDifference(lastCF, cf)

                if distance >= CONFIG.PositionThreshold
                    or rotation >= CONFIG.RotationThreshold
                    or now - number(State.RecordedPath[#State.RecordedPath].t, 0) >= 0.20 then

                    table.insert(State.RecordedPath, {
                        t = math.max(now, number(State.RecordedPath[#State.RecordedPath].t, 0)),
                        cf = serializeCFrame(cf),
                    })

                    lastCF = cf

                    nextInterval = adaptiveInterval(root)

                    updateInfo()
                end

                task.wait(clamp(nextInterval * 0.5, 1 / 120, 1 / 20))
            end
        end, safeTraceback)

        if not ok and State.RecordToken == token then
            State.Recording = false
            State.RecordPaused = false
            setStatus("Recording error: " .. tostring(err):sub(1, 220))
        end
    end)
end

local function toggleRecordPause()
    if not State.Recording then
        return
    end

    if State.RecordPaused then
        local now = os.clock()

        if State.RecordPausedAt then
            State.RecordPausedTotal += now - State.RecordPausedAt
        end

        State.RecordPausedAt = nil
        State.RecordPaused = false

        setStatus("Recording resumed")
    else
        State.RecordPausedAt = os.clock()
        State.RecordPaused = true

        setStatus("Recording paused")
    end
end

-- ============================================================
-- PLAYBACK
-- ============================================================

local function findSegment(path, time)
    if #path < 2 then
        return nil
    end

    if time <= path[1].t then
        return 1
    end

    if time >= path[#path].t then
        return #path - 1
    end

    local low = 1
    local high = #path - 1

    while low <= high do
        local mid = math.floor((low + high) / 2)

        local a = number(path[mid].t, nil)
        local b = number(path[mid + 1].t, nil)

        if a == nil or b == nil then
            return nil
        end

        if time < a then
            high = mid - 1
        elseif time > b then
            low = mid + 1
        else
            return mid
        end
    end

    return clamp(low, 1, #path - 1)
end

local function interpolateCFrame(a, b, alpha)
    alpha = clamp(alpha, 0, 1)

    -- Linear position + linear rotation is deliberately used in the
    -- stable build. It cannot invent overshoot between recorded points.
    return a:Lerp(b, alpha)
end

local function stopPlayback()
    State.Playing = false
    State.PlaybackPaused = false
    State.PlaybackToken += 1
    setStatus("Playback stopped")
end

local function playLoadedPath()
    if State.Playing then
        return
    end

    local path = State.LoadedPath

    if #path < 2 then
        setStatus("Playback gagal: load path minimal 2 sample")
        return
    end

    local root = getCharacterReady()
    if not root then
        setStatus("Character/HumanoidRootPart belum siap")
        return
    end

    State.PlaybackToken += 1
    local token = State.PlaybackToken

    State.Playing = true
    State.PlaybackPaused = false
    State.PlaybackTime = 0
    State.PlaybackDuration = number(path[#path].t, 0)

    setStatus("Playback aktif")
    updateInfo()

    task.spawn(function()
        local ok, err = xpcall(function()
            local last = os.clock()

            while State.Playing and State.PlaybackToken == token do
                if State.PlaybackPaused then
                    last = os.clock()
                    task.wait(0.05)
                    continue
                end

                local now = os.clock()
                local dt = clamp(now - last, 0, 0.10)
                last = now

                State.PlaybackTime += dt * State.Speed

                if State.PlaybackTime >= State.PlaybackDuration then
                    State.PlaybackTime = State.PlaybackDuration
                end

                local index = findSegment(path, State.PlaybackTime)

                if not index then
                    setStatus("Playback error: invalid timeline")
                    break
                end

                local sampleA = path[index]
                local sampleB = path[index + 1]

                local cfA = deserializeCFrame(sampleA.cf)
                local cfB = deserializeCFrame(sampleB.cf)

                if not cfA or not cfB then
                    setStatus("Playback error: CFrame sample invalid")
                    break
                end

                local ta = number(sampleA.t, 0)
                local tb = number(sampleB.t, ta + 1 / 30)
                local duration = math.max(tb - ta, 1 / 240)

                local alpha = clamp(
                    (State.PlaybackTime - ta) / duration,
                    0,
                    1
                )

                local distance = (cfB.Position - cfA.Position).Magnitude

                if distance >= CONFIG.TeleportDistance then
                    -- Don't animate a real teleport.
                    root.CFrame = alpha >= 0.999999 and cfB or cfA
                else
                    root.CFrame = interpolateCFrame(cfA, cfB, alpha)
                end

                updateInfo()

                if State.PlaybackTime >= State.PlaybackDuration then
                    break
                end

                RunService.Heartbeat:Wait()
            end
        end, safeTraceback)

        if State.PlaybackToken == token then
            State.Playing = false
            State.PlaybackPaused = false

            if not ok then
                setStatus("Playback error: " .. tostring(err):sub(1, 220))
            else
                setStatus("Playback selesai")
            end
        end
    end)
end

local function togglePlaybackPause()
    if not State.Playing then
        return
    end

    State.PlaybackPaused = not State.PlaybackPaused

    if State.PlaybackPaused then
        setStatus("Playback paused")
    else
        setStatus("Playback resumed")
    end
end

-- ============================================================
-- LOAD
-- ============================================================

local function loadPath()
    local ok, data = FS.read(FileBox.Text)

    if not ok then
        setStatus("Load gagal: " .. tostring(data))
        return
    end

    local path = sanitizePath(data)

    if #path < 2 then
        setStatus("Load gagal: file tidak punya minimal 2 sample valid")
        return
    end

    State.LoadedPath = path
    State.PlaybackTime = 0
    State.PlaybackDuration = number(path[#path].t, 0)

    setStatus(string.format("Loaded | %d samples | %.2fs", #path, State.PlaybackDuration))
    updateInfo()
end

-- ============================================================
-- SPEED
-- ============================================================

local function changeSpeed(delta)
    State.Speed = clamp(
        math.round((State.Speed + delta) / CONFIG.SpeedStep) * CONFIG.SpeedStep,
        CONFIG.MinSpeed,
        CONFIG.MaxSpeed
    )

    updateInfo()
end

SpeedDown.MouseButton1Click:Connect(function()
    changeSpeed(-CONFIG.SpeedStep)
end)

SpeedUp.MouseButton1Click:Connect(function()
    changeSpeed(CONFIG.SpeedStep)
end)

SpeedReset.MouseButton1Click:Connect(function()
    State.Speed = CONFIG.DefaultSpeed
    updateInfo()
end)

-- ============================================================
-- BUTTONS
-- ============================================================

RecordButton.MouseButton1Click:Connect(function()
    startRecording()
end)

RecordPauseButton.MouseButton1Click:Connect(function()
    toggleRecordPause()
end)

SaveButton.MouseButton1Click:Connect(function()
    stopRecording(true)
end)

LoadButton.MouseButton1Click:Connect(function()
    loadPath()
end)

PlayButton.MouseButton1Click:Connect(function()
    playLoadedPath()
end)

PlaybackPauseButton.MouseButton1Click:Connect(function()
    togglePlaybackPause()
end)

StopPlaybackButton.MouseButton1Click:Connect(function()
    stopPlayback()
end)

-- ============================================================
-- CLEANUP / CHARACTER RESPAWN
-- ============================================================

LocalPlayer.CharacterAdded:Connect(function()
    State.CurrentRoot = nil

    if State.Playing then
        stopPlayback()
        setStatus("Playback dihentikan: character respawn")
    end
end)

-- ============================================================
-- INITIAL STATUS
-- ============================================================

if not FS.available() then
    setStatus("Warning: filesystem executor API tidak tersedia")
else
    local okFolder, folderErr = FS.ensureFolder()

    if okFolder then
        setStatus("Ready | folder: " .. CONFIG.Folder)
    else
        setStatus("Ready | filesystem: " .. tostring(folderErr))
    end
end

updateInfo()

print("[Muncak Recorder] CLEAN STABLE loaded")
