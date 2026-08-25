--[[
    MUNCAK RECORDER V3
    Untuk Roblox Studio / game yang kamu kontrol sendiri

    Fitur:
    - Recorder adaptive sampling
    - Path compression
    - Smooth Catmull-Rom interpolation
    - Smooth rotation
    - Pause / Resume / Stop playback
    - Speed 0.25x - 3x
    - Loader JSON
    - Multi-file Merge
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CONFIG = {
    SampleInterval = 0.04,
    PositionThreshold = 0.08,
    RotationThreshold = math.rad(1.0),
    CompressionDistance = 0.12,
    CompressionAngle = math.rad(1.5),
    DefaultSpeed = 1,
    MinSpeed = 0.25,
    MaxSpeed = 3,
    DefaultFile = "muncak_route.json",
    GUIWidth = 330,
    GUIHeight = 440
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
    SelectedFile = nil,
    Connections = {}
}

local HAS_FILE_API =
    type(readfile) == "function" and
    type(writefile) == "function" and
    type(isfile) == "function"

local HAS_LISTFILES = type(listfiles) == "function"

local function getRoot()
    local character = player.Character
    if not character then return nil end
    return character:FindFirstChild("HumanoidRootPart")
end

local function serializeCFrame(cf)
    return {cf:GetComponents()}
end

local function deserializeCFrame(data)
    if type(data) ~= "table" or #data < 12 then return nil end
    local ok, result = pcall(function()
        return CFrame.new(unpack(data))
    end)
    return ok and result or nil
end

local function angleDifference(a, b)
    local dot = math.clamp(a.LookVector:Dot(b.LookVector), -1, 1)
    return math.acos(dot)
end

local old = playerGui:FindFirstChild("MuncakRecorderV3")
if old then old:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "MuncakRecorderV3"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = playerGui

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(CONFIG.GUIWidth, CONFIG.GUIHeight)
Main.Position = UDim2.new(0.5, -CONFIG.GUIWidth / 2, 0.5, -CONFIG.GUIHeight / 2)
Main.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
Main.BorderSizePixel = 0
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(65, 65, 70)
Stroke.Parent = Main

local Top = Instance.new("Frame")
Top.Size = UDim2.new(1, 0, 0, 42)
Top.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
Top.BorderSizePixel = 0
Top.Parent = Main

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -90, 1, 0)
Title.Position = UDim2.fromOffset(14, 0)
Title.BackgroundTransparency = 1
Title.Text = "Muncak Recorder V3"
Title.TextColor3 = Color3.new(1,1,1)
Title.TextSize = 14
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Top

local Minimize = Instance.new("TextButton")
Minimize.Size = UDim2.fromOffset(28, 26)
Minimize.Position = UDim2.new(1, -65, 0.5, -13)
Minimize.Text = "-"
Minimize.TextSize = 16
Minimize.Font = Enum.Font.GothamBold
Minimize.TextColor3 = Color3.new(1,1,1)
Minimize.BackgroundColor3 = Color3.fromRGB(220, 175, 40)
Minimize.Parent = Top
Instance.new("UICorner", Minimize).CornerRadius = UDim.new(0, 5)

local Close = Instance.new("TextButton")
Close.Size = UDim2.fromOffset(28, 26)
Close.Position = UDim2.new(1, -33, 0.5, -13)
Close.Text = "×"
Close.TextSize = 17
Close.Font = Enum.Font.GothamBold
Close.TextColor3 = Color3.new(1,1,1)
Close.BackgroundColor3 = Color3.fromRGB(210, 65, 65)
Close.Parent = Top
Instance.new("UICorner", Close).CornerRadius = UDim.new(0, 5)

local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, -20, 0, 36)
TabBar.Position = UDim2.fromOffset(10, 50)
TabBar.BackgroundTransparency = 1
TabBar.Parent = Main

local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection = Enum.FillDirection.Horizontal
TabLayout.Padding = UDim.new(0, 5)
TabLayout.Parent = TabBar

local function createTab(text)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.32, 0, 1, 0)
    b.BackgroundColor3 = Color3.fromRGB(45,45,50)
    b.Text = text
    b.TextColor3 = Color3.fromRGB(200,200,205)
    b.TextSize = 11
    b.Font = Enum.Font.GothamSemibold
    b.Parent = TabBar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local TabRecorder = createTab("RECORDER")
local TabLoader = createTab("LOADER")
local TabMerge = createTab("MERGE")

local Content = Instance.new("Frame")
Content.Size = UDim2.new(1, -20, 1, -135)
Content.Position = UDim2.fromOffset(10, 92)
Content.BackgroundTransparency = 1
Content.Parent = Main

local function createPage()
    local page = Instance.new("Frame")
    page.Size = UDim2.fromScale(1,1)
    page.BackgroundTransparency = 1
    page.Visible = false
    page.Parent = Content
    return page
end

local RecorderPage = createPage()
local LoaderPage = createPage()
local MergePage = createPage()

local function createLabel(parent, text, pos, size)
    local l = Instance.new("TextLabel")
    l.Size = size or UDim2.new(1,0,0,25)
    l.Position = pos
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(205,205,210)
    l.TextSize = 12
    l.Font = Enum.Font.Gotham
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = parent
    return l
end

local function createButton(parent, text, pos, size)
    local b = Instance.new("TextButton")
    b.Size = size or UDim2.new(1,0,0,38)
    b.Position = pos
    b.BackgroundColor3 = Color3.fromRGB(48,48,55)
    b.Text = text
    b.TextColor3 = Color3.new(1,1,1)
    b.TextSize = 12
    b.Font = Enum.Font.GothamSemibold
    b.Parent = parent
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,7)
    return b
end

local function createBox(parent, text, pos, size)
    local b = Instance.new("TextBox")
    b.Size = size
    b.Position = pos
    b.BackgroundColor3 = Color3.fromRGB(39,39,44)
    b.Text = text
    b.TextColor3 = Color3.new(1,1,1)
    b.TextSize = 12
    b.Font = Enum.Font.Gotham
    b.ClearTextOnFocus = false
    b.Parent = parent
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    return b
end

local Status = createLabel(
    Main,
    "Ready",
    UDim2.new(0,10,1,-30),
    UDim2.new(1,-20,0,20)
)
Status.TextColor3 = Color3.fromRGB(150,150,155)

local function setStatus(text)
    Status.Text = text
end

createLabel(RecorderPage, "Recording filename", UDim2.fromOffset(0,0))

local FileBox = createBox(
    RecorderPage,
    CONFIG.DefaultFile,
    UDim2.fromOffset(0,24),
    UDim2.new(1,0,0,36)
)

local StartRecord = createButton(
    RecorderPage,
    "● START RECORDING",
    UDim2.fromOffset(0,72)
)

local PauseRecord = createButton(
    RecorderPage,
    "Ⅱ PAUSE",
    UDim2.fromOffset(0,116)
)

local StopRecord = createButton(
    RecorderPage,
    "■ STOP & SAVE",
    UDim2.fromOffset(0,160)
)

local RecordInfo = createLabel(
    RecorderPage,
    "Points: 0\nDuration: 00:00.00",
    UDim2.fromOffset(0,210),
    UDim2.new(1,0,0,70)
)
RecordInfo.TextYAlignment = Enum.TextYAlignment.Top

local function saveFile(filename, data)
    if not HAS_FILE_API then
        return false, "File API tidak tersedia"
    end

    local ok, err = pcall(function()
        writefile(filename, HttpService:JSONEncode(data))
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function stopRecording()
    if not State.Recording then return end

    State.Recording = false
    State.RecordPaused = false

    local filename = FileBox.Text
    if filename == "" then filename = CONFIG.DefaultFile end
    if not filename:match("%.json$") then filename = filename .. ".json" end

    local success, err = saveFile(filename, State.RecordedPath)

    if success then
        setStatus(string.format("Saved %s | %d points", filename, #State.RecordedPath))
    else
        setStatus("Save error: " .. tostring(err))
    end
end

StartRecord.MouseButton1Click:Connect(function()
    if State.Recording then return end

    local root = getRoot()
    if not root then
        setStatus("Character belum siap")
        return
    end

    State.RecordedPath = {}
    State.Recording = true
    State.RecordPaused = false

    local startTime = os.clock()
    local lastCF = nil
    local lastSample = os.clock()

    setStatus("Recording...")

    task.spawn(function()
        while State.Recording do
            if not State.RecordPaused then
                local now = os.clock()
                local currentRoot = getRoot()

                if currentRoot then
                    local cf = currentRoot.CFrame
                    local shouldRecord = false

                    if not lastCF then
                        shouldRecord = true
                    else
                        local distance = (cf.Position - lastCF.Position).Magnitude
                        local rotation = angleDifference(cf, lastCF)

                        if distance >= CONFIG.PositionThreshold
                            or rotation >= CONFIG.RotationThreshold
                            or now - lastSample >= CONFIG.SampleInterval then
                            shouldRecord = true
                        end
                    end

                    if shouldRecord then
                        table.insert(State.RecordedPath, {
                            t = now - startTime,
                            cf = serializeCFrame(cf)
                        })

                        lastCF = cf
                        lastSample = now

                        local elapsed = now - startTime

                        RecordInfo.Text = string.format(
                            "Points: %d\nDuration: %02d:%05.2f",
                            #State.RecordedPath,
                            math.floor(elapsed / 60),
                            elapsed % 60
                        )
                    end
                end
            end

            task.wait(CONFIG.SampleInterval)
        end
    end)
end)

PauseRecord.MouseButton1Click:Connect(function()
    if not State.Recording then return end

    State.RecordPaused = not State.RecordPaused

    if State.RecordPaused then
        PauseRecord.Text = "▶ RESUME"
        setStatus("Recording paused")
    else
        PauseRecord.Text = "Ⅱ PAUSE"
        setStatus("Recording resumed")
    end
end)

StopRecord.MouseButton1Click:Connect(stopRecording)

local function compressPath(path)
    if #path <= 2 then return path end

    local result = {path[1]}

    for i = 2, #path - 1 do
        local previous = result[#result]
        local current = path[i]
        local nextPoint = path[i + 1]

        local cfA = deserializeCFrame(previous.cf)
        local cfB = deserializeCFrame(current.cf)
        local cfC = deserializeCFrame(nextPoint.cf)

        if cfA and cfB and cfC then
            local move = (cfB.Position - cfA.Position).Magnitude
            local nextMove = (cfC.Position - cfB.Position).Magnitude

            local directionA = cfB.Position - cfA.Position
            local directionB = cfC.Position - cfB.Position

            local angle = 0

            if directionA.Magnitude > 0 and directionB.Magnitude > 0 then
                angle = math.acos(math.clamp(
                    directionA.Unit:Dot(directionB.Unit),
                    -1,
                    1
                ))
            end

            local rotation = angleDifference(cfA, cfB)

            if move >= CONFIG.CompressionDistance
                or angle >= CONFIG.CompressionAngle
                or rotation >= CONFIG.CompressionAngle
                or nextMove >= CONFIG.CompressionDistance then
                table.insert(result, current)
            end
        end
    end

    table.insert(result, path[#path])
    return result
end

local function catmullRom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t

    return (
        p1 * 2
        + (p2 - p0) * t
        + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
        + (-p0 + p1 * 3 - p2 * 3 + p3) * t3
    ) * 0.5
end

local function findSegment(path, time)
    local low = 1
    local high = #path - 1

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local a = path[mid].t
        local b = path[mid + 1].t

        if time < a then
            high = mid - 1
        elseif time > b then
            low = mid + 1
        else
            return mid
        end
    end

    return math.clamp(low, 1, #path - 1)
end

local function getSmoothCFrame(path, index, alpha)
    local p0 = path[math.max(index - 1, 1)]
    local p1 = path[index]
    local p2 = path[math.min(index + 1, #path)]
    local p3 = path[math.min(index + 2, #path)]

    local cf0 = deserializeCFrame(p0.cf)
    local cf1 = deserializeCFrame(p1.cf)
    local cf2 = deserializeCFrame(p2.cf)
    local cf3 = deserializeCFrame(p3.cf)

    if not cf1 or not cf2 then return nil end

    local position = catmullRom(
        cf0.Position,
        cf1.Position,
        cf2.Position,
        cf3.Position,
        alpha
    )

    local rotation = cf1.Rotation:Lerp(cf2.Rotation, alpha)

    return CFrame.new(position) * rotation
end

local function stopPlayback()
    State.Playing = false
    State.PlaybackPaused = false
end

local function playPath(path)
    if State.Playing then return end

    if #path < 2 then
        setStatus("Path terlalu pendek")
        return
    end

    local compressed = compressPath(path)

    if #compressed < 2 then
        setStatus("Path invalid")
        return
    end

    State.LoadedPath = compressed
    State.Playing = true
    State.PlaybackPaused = false
    State.PlaybackTime = 0
    State.PlaybackDuration = compressed[#compressed].t

    setStatus(string.format("Playing %.2fx", State.Speed))

    task.spawn(function()
        local lastClock = os.clock()

        while State.Playing do
            if State.PlaybackPaused then
                task.wait()
                lastClock = os.clock()
                continue
            end

            local now = os.clock()
            local dt = math.min(now - lastClock, 0.05)
            lastClock = now

            State.PlaybackTime += dt * State.Speed

            if State.PlaybackTime >= State.PlaybackDuration then
                State.PlaybackTime = State.PlaybackDuration

                local root = getRoot()
                if root then
                    local final = deserializeCFrame(compressed[#compressed].cf)
                    if final then root.CFrame = final end
                end

                break
            end

            local index = findSegment(compressed, State.PlaybackTime)
            local a = compressed[index]
            local b = compressed[index + 1]

            local duration = math.max(b.t - a.t, 0.0001)

            local alpha = math.clamp(
                (State.PlaybackTime - a.t) / duration,
                0,
                1
            )

            alpha = alpha * alpha * (3 - 2 * alpha)

            local target = getSmoothCFrame(compressed, index, alpha)
            local root = getRoot()

            if target and root then
                root.CFrame = root.CFrame:Lerp(
                    target,
                    math.clamp(dt * 30, 0, 1)
                )
            end

            task.wait()
        end

        State.Playing = false

        if State.PlaybackTime >= State.PlaybackDuration then
            setStatus("Playback selesai")
        else
            setStatus("Playback stopped")
        end
    end)
end

createLabel(LoaderPage, "JSON files", UDim2.fromOffset(0,0))

local FileList = Instance.new("ScrollingFrame")
FileList.Size = UDim2.new(1,0,1,-105)
FileList.Position = UDim2.fromOffset(0,28)
FileList.BackgroundColor3 = Color3.fromRGB(31,31,35)
FileList.BorderSizePixel = 0
FileList.ScrollBarThickness = 4
FileList.Parent = LoaderPage

local FileLayout = Instance.new("UIListLayout")
FileLayout.Padding = UDim.new(0,5)
FileLayout.Parent = FileList

local Refresh = createButton(
    LoaderPage,
    "↻ REFRESH",
    UDim2.new(0,0,1,-75),
    UDim2.new(0.48,-3,0,36)
)

local Play = createButton(
    LoaderPage,
    "▶ PLAY",
    UDim2.new(0.52,3,1,-75),
    UDim2.new(0.48,-3,0,36)
)

local Pause = createButton(
    LoaderPage,
    "Ⅱ PAUSE / RESUME",
    UDim2.new(0,0,1,-35),
    UDim2.new(0.48,-3,0,30)
)

local Stop = createButton(
    LoaderPage,
    "■ STOP",
    UDim2.new(0.52,3,1,-35),
    UDim2.new(0.48,-3,0,30)
)

local function loadJSON(filename)
    if not HAS_FILE_API then
        return nil, "File API tidak tersedia"
    end

    if not isfile(filename) then
        return nil, "File tidak ditemukan"
    end

    local ok, result = pcall(function()
        return HttpService:JSONDecode(readfile(filename))
    end)

    if not ok then return nil, tostring(result) end
    return result
end

local function refreshFiles()
    for _, child in ipairs(FileList:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    if not HAS_LISTFILES then
        setStatus("listfiles tidak tersedia")
        return
    end

    local ok, files = pcall(listfiles)
    if not ok then return end

    for _, file in ipairs(files) do
        file = tostring(file)

        if file:lower():match("%.json$") then
            local b = createButton(
                FileList,
                file,
                UDim2.fromOffset(0,0),
                UDim2.new(1,-10,0,34)
            )

            b.Parent = FileList

            b.MouseButton1Click:Connect(function()
                State.SelectedFile = file
                setStatus("Selected: " .. file)
            end)
        end
    end

    task.defer(function()
        FileList.CanvasSize = UDim2.fromOffset(
            0,
            FileLayout.AbsoluteContentSize.Y + 10
        )
    end)
end

Refresh.MouseButton1Click:Connect(refreshFiles)

Play.MouseButton1Click:Connect(function()
    if not State.SelectedFile then
        setStatus("Pilih file dahulu")
        return
    end

    local data, err = loadJSON(State.SelectedFile)

    if not data then
        setStatus("Load error: " .. tostring(err))
        return
    end

    playPath(data)
end)

Pause.MouseButton1Click:Connect(function()
    if not State.Playing then return end

    State.PlaybackPaused = not State.PlaybackPaused

    if State.PlaybackPaused then
        setStatus("Playback paused")
    else
        setStatus("Playback resumed")
    end
end)

Stop.MouseButton1Click:Connect(stopPlayback)

local SpeedLabel = createLabel(
    LoaderPage,
    "Speed: 1.00x",
    UDim2.new(0,0,1,-125),
    UDim2.new(0.45,0,0,20)
)

local SpeedSlider = Instance.new("Frame")
SpeedSlider.Size = UDim2.new(0.55,-5,0,8)
SpeedSlider.Position = UDim2.new(0.45,5,1,-118)
SpeedSlider.BackgroundColor3 = Color3.fromRGB(55,55,60)
SpeedSlider.Parent = LoaderPage
Instance.new("UICorner", SpeedSlider).CornerRadius = UDim.new(1,0)

local SpeedFill = Instance.new("Frame")
SpeedFill.Size = UDim2.new(
    (CONFIG.DefaultSpeed-CONFIG.MinSpeed) /
    (CONFIG.MaxSpeed-CONFIG.MinSpeed),
    0,1,0
)
SpeedFill.BackgroundColor3 = Color3.fromRGB(70,130,220)
SpeedFill.Parent = SpeedSlider
Instance.new("UICorner", SpeedFill).CornerRadius = UDim.new(1,0)

local SpeedButton = Instance.new("TextButton")
SpeedButton.Size = UDim2.fromOffset(18,18)
SpeedButton.AnchorPoint = Vector2.new(0.5,0.5)
SpeedButton.Position = UDim2.new(SpeedFill.Size.X.Scale,0,0.5,0)
SpeedButton.BackgroundColor3 = Color3.new(1,1,1)
SpeedButton.Text = ""
SpeedButton.Parent = SpeedSlider
Instance.new("UICorner", SpeedButton).CornerRadius = UDim.new(1,0)

local speedDragging = false

local function updateSpeed(input)
    local x = math.clamp(
        input.Position.X - SpeedSlider.AbsolutePosition.X,
        0,
        SpeedSlider.AbsoluteSize.X
    )

    local alpha = x / SpeedSlider.AbsoluteSize.X

    local speed =
        CONFIG.MinSpeed +
        (CONFIG.MaxSpeed-CONFIG.MinSpeed) * alpha

    speed = math.round(speed * 100) / 100
    State.Speed = speed

    SpeedFill.Size = UDim2.new(alpha,0,1,0)
    SpeedButton.Position = UDim2.new(alpha,0,0.5,0)

    SpeedLabel.Text = string.format("Speed: %.2fx", speed)
end

SpeedButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        speedDragging = true
    end
end)

SpeedButton.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        speedDragging = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if speedDragging then
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            updateSpeed(input)
        end
    end
end)

createLabel(MergePage, "Files to merge", UDim2.fromOffset(0,0))

local MergeInput = createBox(
    MergePage,
    "part1.json, part2.json",
    UDim2.fromOffset(0,25),
    UDim2.new(1,0,0,38)
)

createLabel(MergePage, "Output file", UDim2.fromOffset(0,72))

local OutputBox = createBox(
    MergePage,
    "merged_full_muncak.json",
    UDim2.fromOffset(0,97),
    UDim2.new(1,0,0,38)
)

local MergeButton = createButton(
    MergePage,
    "＋ MERGE",
    UDim2.fromOffset(0,150)
)

local CompressButton = createButton(
    MergePage,
    "COMPRESS & MERGE",
    UDim2.fromOffset(0,195)
)

local MergeInfo = createLabel(
    MergePage,
    "Gunakan koma untuk memisahkan file.",
    UDim2.fromOffset(0,245),
    UDim2.new(1,0,0,70)
)
MergeInfo.TextYAlignment = Enum.TextYAlignment.Top

local function parseFiles(text)
    local result = {}

    for file in string.gmatch(text, "([^,]+)") do
        file = file:gsub("^%s+",""):gsub("%s+$","")
        if file ~= "" then
            table.insert(result, file)
        end
    end

    return result
end

local function mergePaths(files)
    local master = {}

    for _, file in ipairs(files) do
        local data, err = loadJSON(file)

        if not data then
            return nil, err
        end

        for _, point in ipairs(data) do
            table.insert(master, point)
        end
    end

    local offset = 0
    local lastTime = 0

    for _, point in ipairs(master) do
        local t = tonumber(point.t) or 0

        if t < lastTime then
            offset += lastTime
        end

        point.t = t + offset
        lastTime = point.t
    end

    return master
end

MergeButton.MouseButton1Click:Connect(function()
    local files = parseFiles(MergeInput.Text)
    local merged, err = mergePaths(files)

    if not merged then
        setStatus("Merge error: " .. tostring(err))
        return
    end

    local output = OutputBox.Text
    if not output:match("%.json$") then
        output = output .. ".json"
    end

    local success, saveErr = saveFile(output, merged)

    if success then
        setStatus(string.format("Merged: %d points", #merged))
    else
        setStatus("Save error: " .. tostring(saveErr))
    end
end)

CompressButton.MouseButton1Click:Connect(function()
    local files = parseFiles(MergeInput.Text)
    local merged, err = mergePaths(files)

    if not merged then
        setStatus("Merge error: " .. tostring(err))
        return
    end

    local before = #merged
    local compressed = compressPath(merged)

    local output = OutputBox.Text
    if not output:match("%.json$") then
        output = output .. ".json"
    end

    local success, saveErr = saveFile(output, compressed)

    if success then
        setStatus(string.format(
            "Compressed: %d → %d points",
            before,
            #compressed
        ))
    else
        setStatus("Save error: " .. tostring(saveErr))
    end
end)

local function showPage(page)
    RecorderPage.Visible = false
    LoaderPage.Visible = false
    MergePage.Visible = false
    page.Visible = true
end

TabRecorder.MouseButton1Click:Connect(function()
    showPage(RecorderPage)
end)

TabLoader.MouseButton1Click:Connect(function()
    showPage(LoaderPage)
    refreshFiles()
end)

TabMerge.MouseButton1Click:Connect(function()
    showPage(MergePage)
end)

showPage(RecorderPage)

local dragging = false
local dragStart
local startPos

Top.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = Main.Position
    end
end)

Top.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end

    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then

        local delta = input.Position - dragStart

        Main.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

local minimized = false

Minimize.MouseButton1Click:Connect(function()
    minimized = not minimized

    if minimized then
        Main.Size = UDim2.fromOffset(CONFIG.GUIWidth, 42)
        TabBar.Visible = false
        Content.Visible = false
        Status.Visible = false
        Minimize.Text = "+"
    else
        Main.Size = UDim2.fromOffset(CONFIG.GUIWidth, CONFIG.GUIHeight)
        TabBar.Visible = true
        Content.Visible = true
        Status.Visible = true
        Minimize.Text = "-"
    end
end)

Close.MouseButton1Click:Connect(function()
    stopPlayback()
    State.Recording = false

    for _, connection in ipairs(State.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    ScreenGui:Destroy()
end)

if not HAS_FILE_API then
    setStatus("File API tidak tersedia")
end

print("Muncak Recorder V3 Loaded Successfully")
