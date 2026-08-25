--[[
    MOTION CORE V5
    Path Recorder / Playback UI

    Features
      • Recording Panel
      • Path Name
      • Record / Undo / Save
      • TP Start / TP End
      • Play / Stop / Reverse / Flip
      • Timeline + duration
      • Path visualization
      • Keybind recording
      • Path compression
      • Velocity-aware interpolation
      • Pause / Resume
      • Playback speed 0.25x - 3x
      • JSON save/load when executor file APIs are available

    NOTE:
      This is a client-side Roblox Lua implementation.
      Save/load uses writefile/readfile when those APIs exist.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

--==================================================
-- CONFIG
--==================================================

local CFG = {
    SampleRate = 30,
    MinPointDistance = 0.08,
    MinRotation = math.rad(0.7),
    MaxPoints = 15000,

    SpeedMin = 0.25,
    SpeedMax = 3.00,
    Speed = 1.00,

    Folder = "MotionCore",
    DefaultFile = "MotionCore_Recordings.json",

    DrawPath = true,
    DrawCamera = false,
    CharacterPlayback = true,
    CameraPlayback = false,

    SmoothStrength = 0.82,
    VelocityInfluence = 0.65,
}

--==================================================
-- STATE
--==================================================

local S = {
    Recording = false,
    Playing = false,
    Paused = false,
    Reverse = false,
    Flip = false,

    RecordStarted = 0,
    Clock = 0,
    Duration = 0,

    Points = {},
    Undo = {},

    TPStart = nil,
    TPEnd = nil,

    RecordKey = Enum.KeyCode.R,

    RecordConn = nil,
    PlaybackConn = nil,

    PathParts = {},
    SelectedPath = nil,

    GUIVisible = true,
}

--==================================================
-- CHARACTER
--==================================================

local function character()
    return LP.Character
end

local function root()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getRootCF()
    local r = root()
    return r and r.CFrame
end

--==================================================
-- UTILS
--==================================================

local function safeDisconnect(conn)
    if conn then
        pcall(function() conn:Disconnect() end)
    end
end

local function setStatus(text)
    if S.StatusLabel then
        S.StatusLabel.Text = text
    end
end

local function formatTime(t)
    t = math.max(0, t or 0)
    return string.format("%02d:%05.2f", math.floor(t / 60), t % 60)
end

local function angle(a, b)
    local dot = math.clamp(a.LookVector:Dot(b.LookVector), -1, 1)
    return math.acos(dot)
end

local function pointDistance(a, b)
    return (a.Position - b.Position).Magnitude
end

local function smoothstep(x)
    x = math.clamp(x, 0, 1)
    return x * x * (3 - 2 * x)
end

local function smootherstep(x)
    x = math.clamp(x, 0, 1)
    return x * x * x * (x * (x * 6 - 15) + 10)
end

local function lerpCF(a, b, t)
    return a:Lerp(b, t)
end

--==================================================
-- PATH COMPRESSION
--==================================================

local function shouldKeep(prev, current)
    if not prev then
        return true
    end

    local d = pointDistance(prev.cf, current.cf)
    local r = angle(prev.cf, current.cf)
    local dt = current.t - prev.t

    if d >= CFG.MinPointDistance then
        return true
    end

    if r >= CFG.MinRotation then
        return true
    end

    if dt >= 0.18 then
        return true
    end

    return false
end

local function compress(points)
    if #points <= 2 then
        return points
    end

    local out = {points[1]}
    local last = points[1]

    for i = 2, #points - 1 do
        if shouldKeep(last, points[i]) then
            table.insert(out, points[i])
            last = points[i]
        end
    end

    table.insert(out, points[#points])
    return out
end

--==================================================
-- PATH VISUALIZER
--==================================================

local PathFolder = Instance.new("Folder")
PathFolder.Name = "MotionCore_Path"
PathFolder.Parent = workspace

local function clearPathVisual()
    for _, p in ipairs(S.PathParts) do
        p:Destroy()
    end
    table.clear(S.PathParts)
end

local function drawPath()
    clearPathVisual()

    if not CFG.DrawPath or #S.Points < 2 then
        return
    end

    for i = 1, #S.Points - 1 do
        local a = S.Points[i].cf.Position
        local b = S.Points[i + 1].cf.Position

        local delta = b - a
        local len = delta.Magnitude

        if len > 0.001 then
            local part = Instance.new("Part")
            part.Anchored = true
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Material = Enum.Material.Neon
            part.Transparency = 0.18
            part.Size = Vector3.new(0.045, 0.045, len)
            part.CFrame = CFrame.lookAt((a + b) / 2, b)
            part.Parent = PathFolder

            table.insert(S.PathParts, part)
        end
    end
end

--==================================================
-- RECORD
--==================================================

local function capture()
    local r = root()
    if not r then return end

    local t = os.clock() - S.RecordStarted
    local cf = r.CFrame

    local previous = S.Points[#S.Points]
    local velocity = Vector3.zero

    if previous then
        local dt = math.max(t - previous.t, 1 / CFG.SampleRate)
        velocity = (cf.Position - previous.cf.Position) / dt

        if pointDistance(previous.cf, cf) < CFG.MinPointDistance
            and angle(previous.cf, cf) < CFG.MinRotation
            and (t - previous.t) < 0.18 then
            return
        end
    end

    if #S.Points >= CFG.MaxPoints then
        return
    end

    table.insert(S.Points, {
        t = t,
        cf = cf,
        cam = Camera.CFrame,
        v = velocity,
    })

    S.Duration = t
end

local function stopRecord()
    if not S.Recording then
        return
    end

    S.Recording = false
    safeDisconnect(S.RecordConn)
    S.RecordConn = nil

    if #S.Points >= 2 then
        S.Points = compress(S.Points)
        S.Duration = S.Points[#S.Points].t
    end

    drawPath()
    setStatus("READY • " .. #S.Points .. " POINTS")
end

local function startRecord()
    if S.Playing then
        S.Playing = false
        safeDisconnect(S.PlaybackConn)
        S.PlaybackConn = nil
    end

    S.Points = {}
    S.Undo = {}
    S.Duration = 0
    S.RecordStarted = os.clock()
    S.Recording = true

    capture()

    local acc = 0
    S.RecordConn = RunService.Heartbeat:Connect(function(dt)
        if not S.Recording then return end

        acc += dt
        local interval = 1 / CFG.SampleRate

        if acc >= interval then
            acc -= interval
            capture()
        end

        setStatus("● RECORDING • " .. #S.Points .. " POINTS")
    end)
end

--==================================================
-- UNDO
--==================================================

local function undo()
    if S.Recording then return end
    if #S.Points <= 1 then return end

    local removed = table.remove(S.Points)
    table.insert(S.Undo, removed)

    S.Duration = #S.Points > 0 and S.Points[#S.Points].t or 0
    drawPath()
end

local function restoreUndo()
    local p = table.remove(S.Undo)
    if not p then return end

    table.insert(S.Points, p)
    table.sort(S.Points, function(a,b)
        return a.t < b.t
    end)

    S.Duration = S.Points[#S.Points].t
    drawPath()
end

--==================================================
-- INTERPOLATION
--==================================================

local function findSegment(time)
    if #S.Points == 0 then
        return nil
    end

    if time <= S.Points[1].t then
        return S.Points[1], S.Points[1], 0
    end

    if time >= S.Points[#S.Points].t then
        return S.Points[#S.Points], S.Points[#S.Points], 1
    end

    local lo = 1
    local hi = #S.Points - 1

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)

        local a = S.Points[mid]
        local b = S.Points[mid + 1]

        if a.t <= time and time <= b.t then
            local alpha = (time - a.t) / math.max(b.t - a.t, 0.0001)
            return a, b, alpha
        end

        if time < a.t then
            hi = mid - 1
        else
            lo = mid + 1
        end
    end

    return S.Points[#S.Points], S.Points[#S.Points], 1
end

local function velocityAlpha(a, b, alpha)
    local dt = math.max(b.t - a.t, 0.001)

    local sa = a.v.Magnitude
    local sb = b.v.Magnitude
    local avg = (sa + sb) * 0.5

    local distance = (b.cf.Position - a.cf.Position).Magnitude
    local expected = avg * dt

    local ratio = 1

    if expected > 0.001 then
        ratio = math.clamp(distance / expected, 0.35, 1.65)
    end

    local influence = math.clamp(1 / ratio, 0.55, 1)
    local s1 = smoothstep(alpha)
    local s2 = smootherstep(alpha)

    local smoothed = s1 + (s2 - s1) * CFG.SmoothStrength

    return math.clamp(
        alpha + (smoothed - alpha) * influence * CFG.VelocityInfluence,
        0,
        1
    )
end

local function sample(time)
    local a, b, alpha = findSegment(time)
    if not a then return end

    if a == b then
        return a.cf, a.cam
    end

    local x = velocityAlpha(a, b, alpha)

    local cf = lerpCF(a.cf, b.cf, x)
    local cam = lerpCF(a.cam, b.cam, x)

    return cf, cam
end

--==================================================
-- PLAYBACK
--==================================================

local function stopPlayback()
    S.Playing = false
    S.Paused = false

    safeDisconnect(S.PlaybackConn)
    S.PlaybackConn = nil

    local h = humanoid()
    if h then
        h.AutoRotate = true
    end

    setStatus("READY • " .. #S.Points .. " POINTS")
end

local function pausePlayback()
    if S.Playing then
        S.Paused = true
        setStatus("Ⅱ PAUSED • " .. formatTime(S.Clock))
    end
end

local function resumePlayback()
    if S.Playing then
        S.Paused = false
        setStatus("▶ PLAYING • " .. formatTime(S.Clock))
    end
end

local function applyPlayback(cf, cam)
    if cf and CFG.CharacterPlayback then
        local r = root()
        if r then
            r.AssemblyLinearVelocity = Vector3.zero
            r.AssemblyAngularVelocity = Vector3.zero
            r.CFrame = cf
        end
    end

    if cam and CFG.CameraPlayback then
        Camera.CFrame = cam
    end
end

local function play()
    if #S.Points < 2 then
        setStatus("NO PATH RECORDED")
        return
    end

    if S.Recording then
        stopRecord()
    end

    stopPlayback()

    S.Playing = true
    S.Paused = false

    if S.Reverse then
        S.Clock = S.Duration
    else
        S.Clock = 0
    end

    local h = humanoid()
    if h then
        h.AutoRotate = false
    end

    S.PlaybackConn = RunService.RenderStepped:Connect(function(dt)
        if not S.Playing or S.Paused then
            return
        end

        local direction = S.Reverse and -1 or 1
        S.Clock += dt * CFG.Speed * direction

        if S.Clock >= S.Duration then
            S.Clock = S.Duration
            local cf, cam = sample(S.Clock)
            applyPlayback(cf, cam)
            stopPlayback()
            return
        end

        if S.Clock <= 0 then
            S.Clock = 0
            local cf, cam = sample(0)
            applyPlayback(cf, cam)
            stopPlayback()
            return
        end

        local cf, cam = sample(S.Clock)

        if S.Flip and cf then
            local p = cf.Position
            local look = -cf.LookVector
            cf = CFrame.lookAt(p, p + look, cf.UpVector)
        end

        applyPlayback(cf, cam)

        setStatus(
            "▶ PLAYING • "
            .. formatTime(S.Clock)
            .. " / "
            .. formatTime(S.Duration)
        )
    end)
end

--==================================================
-- TELEPORT MARKERS
--==================================================

local function setTPStart()
    S.TPStart = getRootCF()

    if S.TPStart then
        setStatus("TP START SET")
    end
end

local function setTPEnd()
    S.TPEnd = getRootCF()

    if S.TPEnd then
        setStatus("TP END SET")
    end
end

local function teleportTo(cf)
    local r = root()
    if r and cf then
        r.CFrame = cf
    end
end

--==================================================
-- FILE FORMAT
--==================================================

local function serializeCF(cf)
    local x,y,z,
        r00,r01,r02,
        r10,r11,r12,
        r20,r21,r22 = cf:GetComponents()

    return {
        x,y,z,
        r00,r01,r02,
        r10,r11,r12,
        r20,r21,r22
    }
end

local function deserializeCF(v)
    return CFrame.new(
        v[1],v[2],v[3],
        v[4],v[5],v[6],
        v[7],v[8],v[9],
        v[10],v[11],v[12]
    )
end

local function exportPath()
    local data = {}

    for _,p in ipairs(S.Points) do
        table.insert(data, {
            t = p.t,
            cf = serializeCF(p.cf),
            cam = serializeCF(p.cam),
            v = {p.v.X,p.v.Y,p.v.Z},
        })
    end

    return data
end

local function savePath()
    if type(writefile) ~= "function" then
        setStatus("WRITEFILE NOT AVAILABLE")
        return
    end

    local payload = {
        version = 5,
        duration = S.Duration,
        points = exportPath(),
    }

    local ok, raw = pcall(function()
        return HttpService:JSONEncode(payload)
    end)

    if not ok then
        setStatus("ENCODE FAILED")
        return
    end

    local success = pcall(function()
        if type(makefolder) == "function" then
            pcall(function() makefolder(CFG.Folder) end)
        end

        local path = CFG.Folder .. "/" .. CFG.DefaultFile
        writefile(path, raw)
    end)

    setStatus(success and "PATH SAVED" or "SAVE FAILED")
end

local function loadPath()
    if type(readfile) ~= "function" then
        setStatus("READFILE NOT AVAILABLE")
        return
    end

    local raw
    local ok = pcall(function()
        raw = readfile(CFG.Folder .. "/" .. CFG.DefaultFile)
    end)

    if not ok then
        setStatus("FILE NOT FOUND")
        return
    end

    local decoded
    local decodedOK = pcall(function()
        decoded = HttpService:JSONDecode(raw)
    end)

    if not decodedOK or type(decoded) ~= "table" then
        setStatus("INVALID FILE")
        return
    end

    local points = {}

    for _,p in ipairs(decoded.points or {}) do
        if p.t and p.cf then
            table.insert(points, {
                t = p.t,
                cf = deserializeCF(p.cf),
                cam = p.cam and deserializeCF(p.cam) or Camera.CFrame,
                v = Vector3.new(
                    p.v and p.v[1] or 0,
                    p.v and p.v[2] or 0,
                    p.v and p.v[3] or 0
                ),
            })
        end
    end

    S.Points = points
    S.Duration = #points > 0 and points[#points].t or 0
    S.Clock = 0

    drawPath()
    setStatus("PATH LOADED • " .. #points .. " POINTS")
end

--==================================================
-- GUI HELPERS
--==================================================

local Gui = Instance.new("ScreenGui")
Gui.Name = "MotionCoreV5"
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = true
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent = PlayerGui

S.Gui = Gui

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(390, 360)
Main.Position = UDim2.new(0.5,-195,0.5,-180)
Main.BackgroundColor3 = Color3.fromRGB(18,16,23)
Main.BorderSizePixel = 0
Main.Parent = Gui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0,15)
Corner.Parent = Main

local Outline = Instance.new("UIStroke")
Outline.Color = Color3.fromRGB(112,78,150)
Outline.Thickness = 1.4
Outline.Transparency = 0.25
Outline.Parent = Main

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1,0,0,54)
Header.BackgroundColor3 = Color3.fromRGB(25,21,32)
Header.BorderSizePixel = 0
Header.Parent = Main

local HeaderCorner = Instance.new("UICorner")
HeaderCorner.CornerRadius = UDim.new(0,15)
HeaderCorner.Parent = Header

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1,-70,1,0)
Title.Position = UDim2.fromOffset(17,0)
Title.BackgroundTransparency = 1
Title.Text = "MOTION CORE"
Title.TextColor3 = Color3.fromRGB(245,240,250)
Title.TextSize = 18
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

local Version = Instance.new("TextLabel")
Version.Size = UDim2.fromOffset(70,20)
Version.Position = UDim2.new(1,-82,0,17)
Version.BackgroundTransparency = 1
Version.Text = "V5"
Version.TextColor3 = Color3.fromRGB(145,110,180)
Version.TextSize = 11
Version.Font = Enum.Font.GothamBold
Version.TextXAlignment = Enum.TextXAlignment.Right
Version.Parent = Header

S.StatusLabel = Instance.new("TextLabel")
S.StatusLabel.Size = UDim2.new(1,-30,0,22)
S.StatusLabel.Position = UDim2.fromOffset(15,60)
S.StatusLabel.BackgroundTransparency = 1
S.StatusLabel.Text = "READY"
S.StatusLabel.TextColor3 = Color3.fromRGB(165,150,180)
S.StatusLabel.TextSize = 11
S.StatusLabel.Font = Enum.Font.GothamSemibold
S.StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
S.StatusLabel.Parent = Main

--==================================================
-- RECORDING PANEL
--==================================================

local Panel = Instance.new("Frame")
Panel.Size = UDim2.fromOffset(360,225)
Panel.Position = UDim2.fromOffset(15,90)
Panel.BackgroundColor3 = Color3.fromRGB(24,20,30)
Panel.BorderSizePixel = 0
Panel.Parent = Main

local PanelCorner = Instance.new("UICorner")
PanelCorner.CornerRadius = UDim.new(0,11)
PanelCorner.Parent = Panel

local PanelTitle = Instance.new("TextLabel")
PanelTitle.Size = UDim2.new(1,-20,0,28)
PanelTitle.Position = UDim2.fromOffset(10,8)
PanelTitle.BackgroundTransparency = 1
PanelTitle.Text = "RECORDING PANEL"
PanelTitle.TextColor3 = Color3.fromRGB(215,205,225)
PanelTitle.TextSize = 12
PanelTitle.Font = Enum.Font.GothamBold
PanelTitle.TextXAlignment = Enum.TextXAlignment.Left
PanelTitle.Parent = Panel

local NameBox = Instance.new("TextBox")
NameBox.Size = UDim2.fromOffset(340,34)
NameBox.Position = UDim2.fromOffset(10,39)
NameBox.BackgroundColor3 = Color3.fromRGB(38,31,46)
NameBox.BorderSizePixel = 0
NameBox.PlaceholderText = "Input Path Name..."
NameBox.Text = ""
NameBox.TextColor3 = Color3.fromRGB(235,225,240)
NameBox.PlaceholderColor3 = Color3.fromRGB(125,115,135)
NameBox.TextSize = 11
NameBox.Font = Enum.Font.Gotham
NameBox.ClearTextOnFocus = false
NameBox.Parent = Panel

local NBC = Instance.new("UICorner")
NBC.CornerRadius = UDim.new(0,8)
NBC.Parent = NameBox

local function button(text,x,y,w,h)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w,h)
    b.Position = UDim2.fromOffset(x,y)
    b.BackgroundColor3 = Color3.fromRGB(49,39,59)
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = Color3.fromRGB(235,225,240)
    b.TextSize = 10
    b.Font = Enum.Font.GothamSemibold
    b.AutoButtonColor = true
    b.Parent = Panel

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0,8)
    c.Parent = b

    return b
end

local RecordBtn = button("● RECORD",10,82,106,34)
local UndoBtn = button("↶ UNDO",127,82,106,34)
local SaveBtn = button("SAVE",244,82,106,34)

local TPStartBtn = button("TP START",10,126,106,34)
local TPEndBtn = button("TP END",127,126,106,34)
local TPBackBtn = button("TP BACK",244,126,106,34)

local PlayBtn = button("▶ PLAY",10,170,106,34)
local PauseBtn = button("Ⅱ PAUSE",127,170,106,34)
local StopBtn = button("■ STOP",244,170,106,34)

--==================================================
-- BOTTOM CONTROLS
--==================================================

local Bottom = Instance.new("Frame")
Bottom.Size = UDim2.fromOffset(360,38)
Bottom.Position = UDim2.fromOffset(15,322)
Bottom.BackgroundTransparency = 1
Bottom.Parent = Main

local ReverseBtn = Instance.new("TextButton")
ReverseBtn.Size = UDim2.fromOffset(108,32)
ReverseBtn.Position = UDim2.fromOffset(0,0)
ReverseBtn.BackgroundColor3 = Color3.fromRGB(49,39,59)
ReverseBtn.BorderSizePixel = 0
ReverseBtn.Text = "REVERSE: OFF"
ReverseBtn.TextColor3 = Color3.fromRGB(225,215,235)
ReverseBtn.TextSize = 10
ReverseBtn.Font = Enum.Font.GothamSemibold
ReverseBtn.Parent = Bottom

local RC = Instance.new("UICorner")
RC.CornerRadius = UDim.new(0,8)
RC.Parent = ReverseBtn

local FlipBtn = ReverseBtn:Clone()
FlipBtn.Position = UDim2.fromOffset(116,0)
FlipBtn.Text = "FLIP: OFF"
FlipBtn.Parent = Bottom

local SpeedBtn = ReverseBtn:Clone()
SpeedBtn.Position = UDim2.fromOffset(232,0)
SpeedBtn.Size = UDim2.fromOffset(128,32)
SpeedBtn.Text = "SPEED 1.00×"
SpeedBtn.Parent = Bottom

--==================================================
-- SPEED CONTROL
--==================================================

local SpeedMenu = Instance.new("Frame")
SpeedMenu.Size = UDim2.fromOffset(128,126)
SpeedMenu.Position = UDim2.new(1,-143,1,-130)
SpeedMenu.BackgroundColor3 = Color3.fromRGB(29,24,36)
SpeedMenu.BorderSizePixel = 0
SpeedMenu.Visible = false
SpeedMenu.ZIndex = 20
SpeedMenu.Parent = Main

local SMC = Instance.new("UICorner")
SMC.CornerRadius = UDim.new(0,9)
SMC.Parent = SpeedMenu

local speeds = {0.25,0.5,0.75,1,1.5,2,3}

for i,v in ipairs(speeds) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,-10,0,15)
    b.Position = UDim2.fromOffset(5,4+(i-1)*17)
    b.BackgroundTransparency = 1
    b.Text = string.format("%.2f×",v)
    b.TextColor3 = Color3.fromRGB(220,210,230)
    b.TextSize = 9
    b.Font = Enum.Font.GothamSemibold
    b.ZIndex = 21
    b.Parent = SpeedMenu

    b.MouseButton1Click:Connect(function()
        CFG.Speed = v
        SpeedBtn.Text = string.format("SPEED %.2f×",v)
        SpeedMenu.Visible = false
    end)
end

--==================================================
-- EVENTS
--==================================================

RecordBtn.MouseButton1Click:Connect(function()
    if S.Recording then
        stopRecord()
        RecordBtn.Text = "● RECORD"
    else
        startRecord()
        RecordBtn.Text = "■ STOP REC"
    end
end)

UndoBtn.MouseButton1Click:Connect(undo)

SaveBtn.MouseButton1Click:Connect(savePath)

TPStartBtn.MouseButton1Click:Connect(setTPStart)
TPEndBtn.MouseButton1Click:Connect(setTPEnd)

TPBackBtn.MouseButton1Click:Connect(function()
    if S.TPStart then
        teleportTo(S.TPStart)
        setStatus("TP START")
    elseif S.TPEnd then
        teleportTo(S.TPEnd)
        setStatus("TP END")
    else
        setStatus("NO TP MARKER")
    end
end)

PlayBtn.MouseButton1Click:Connect(play)
PauseBtn.MouseButton1Click:Connect(function()
    if S.Paused then
        resumePlayback()
    else
        pausePlayback()
    end
end)

StopBtn.MouseButton1Click:Connect(stopPlayback)

ReverseBtn.MouseButton1Click:Connect(function()
    S.Reverse = not S.Reverse
    ReverseBtn.Text = "REVERSE: " .. (S.Reverse and "ON" or "OFF")
end)

FlipBtn.MouseButton1Click:Connect(function()
    S.Flip = not S.Flip
    FlipBtn.Text = "FLIP: " .. (S.Flip and "ON" or "OFF")
end)

SpeedBtn.MouseButton1Click:Connect(function()
    SpeedMenu.Visible = not SpeedMenu.Visible
end)

--==================================================
-- KEYBIND
--==================================================

UIS.InputBegan:Connect(function(input, processed)
    if processed then return end

    if input.KeyCode == S.RecordKey then
        if S.Recording then
            stopRecord()
            RecordBtn.Text = "● RECORD"
        else
            startRecord()
            RecordBtn.Text = "■ STOP REC"
        end
    end
end)

--==================================================
-- DRAG
--==================================================

local dragging = false
local dragStart
local startPos

Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = true
        dragStart = input.Position
        startPos = Main.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UIS.InputChanged:Connect(function(input)
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

--==================================================
-- TOGGLE GUI
--==================================================

UIS.InputBegan:Connect(function(input, processed)
    if processed then return end

    if input.KeyCode == Enum.KeyCode.RightShift then
        S.GUIVisible = not S.GUIVisible
        Main.Visible = S.GUIVisible
    end
end)

--==================================================
-- FINAL INIT
--==================================================

setStatus("READY • 0 POINTS")
drawPath()
