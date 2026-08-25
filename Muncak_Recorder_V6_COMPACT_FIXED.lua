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

local TRACEBACK_HANDLER = (debug and debug.traceback) or function(err)
    return tostring(err)
end

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


-- V4: velocity-aware path interpolation
-- Uses local velocity to estimate where the character should be between
-- recorded samples, reducing visible snapping when sample spacing varies.
local function clamp01(x)
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

local function lerpNumber(a, b, t)
    return a + (b - a) * t
end

local function lerpVector(a, b, t)
    return a:Lerp(b, t)
end

local function sampleVelocity(a, b, dt)
    if not a or not b or dt <= 0 then
        return Vector3.zero
    end
    return (b.Position - a.Position) / dt
end

local function velocityBlendCFrame(a, b, t, dt)
    if not a or not b then
        return b or a
    end

    t = clamp01(t)

    local pa = a.Position
    local pb = b.Position
    local va = sampleVelocity(a, b, dt)
    local vb = va

    -- Estimate outgoing velocity from the next segment when available.
    -- The caller can pass a segment dt; the blend remains bounded to the
    -- recorded endpoints so it cannot overshoot excessively.
    local smooth = t * t * (3 - 2 * t)

    -- Position interpolation is weighted by estimated velocity.
    -- Keep the velocity contribution conservative for stability.
    local safeDt = math.min(math.max(dt or 0, 1/240), RECORDER_FINAL_CONFIG.maxInterpolationGap)
    local velocityOffset = (va * safeDt) * (t * (1 - t)) * 0.12
    local p = pa:Lerp(pb, smooth) + velocityOffset

    -- Preserve rotational interpolation independently.
    local rotation = a.Rotation:Lerp(b.Rotation, smooth)
    return CFrame.new(p) * rotation
end


-- V4 playback quality controls
local PLAYBACK_QUALITY = {
    velocityInterpolation = true,
    maxSampleGap = 0.25,       -- cap interpolation across unusually large gaps
    teleportDistance = 80,     -- avoid smoothing a true teleport/respawn
    rotationSmoothing = true,
    adaptiveSubsteps = true,
    minSubsteps = 1,
    maxSubsteps = 6,
}

-- ============================================================
-- FINAL QUALITY CONFIG
-- ============================================================
local RECORDER_FINAL_CONFIG = {
    adaptiveSampling = true,
    baseSampleInterval = 1/30,
    fastSampleInterval = 1/60,
    idleSampleInterval = 1/12,

    positionThreshold = 0.08,
    rotationThreshold = math.rad(1.5),
    velocityThreshold = 0.75,
    idleSpeedThreshold = 0.15,

    compression = true,
    compressionPosition = 0.035,
    compressionRotation = math.rad(0.75),

    velocityInterpolation = true,
    accelerationInterpolation = true,
    maxInterpolationGap = 0.25,

    teleportDistance = 80,
    respawnDistance = 120,

    adaptiveSubsteps = true,
    minSubsteps = 1,
    maxSubsteps = 8,

    preserveExactStops = true,
    preserveSharpTurns = true,
}


-- ============================================================
-- FINAL SAMPLE / PLAYBACK HELPERS
-- ============================================================
local function finalPositionOf(sample)
    if not sample then return nil end
    return sample.cframe and sample.cframe.Position
        or sample.CFrame and sample.CFrame.Position
        or sample.position
        or sample.Position
end

local function finalCFrameOf(sample)
    if not sample then return nil end
    return sample.cframe or sample.CFrame
end

local function finalTimestampOf(sample)
    if not sample then return nil end
    return tonumber(sample.t)
        or tonumber(sample.time)
        or tonumber(sample.timestamp)
        or 0
end

local function finalVelocityOf(sample)
    if not sample then return Vector3.zero end
    local v = sample.velocity or sample.Velocity
    if typeof(v) == "Vector3" then return v end
    if type(v) == "table" then
        return Vector3.new(tonumber(v.x or v.X) or 0, tonumber(v.y or v.Y) or 0, tonumber(v.z or v.Z) or 0)
    end
    return Vector3.zero
end

local function finalSpeedOf(sample)
    return finalVelocityOf(sample).Magnitude
end

local function shouldKeepSampleFinal(previous, current, nextSample)
    if not previous or not current then return true end

    local a = finalPositionOf(previous)
    local b = finalPositionOf(current)
    if not a or not b then return true end

    local distance = (b - a).Magnitude
    if distance >= RECORDER_FINAL_CONFIG.teleportDistance then
        return true
    end

    local ca = finalCFrameOf(previous)
    local cb = finalCFrameOf(current)
    if ca and cb then
        local _, _, _, r00,r01,r02,r10,r11,r12,r20,r21,r22 = cb:GetComponents()
        local _, _, _, q00,q01,q02,q10,q11,q12,q20,q21,q22 = ca:GetComponents()
        local dot = math.clamp(
            (r00*q00 + r01*q01 + r02*q02 +
             r10*q10 + r11*q11 + r12*q12 +
             r20*q20 + r21*q21 + r22*q22) / 3,
            -1, 1
        )
        local angle = math.acos(dot)
        if angle >= RECORDER_FINAL_CONFIG.rotationThreshold then
            return true
        end
    end

    if math.abs(finalSpeedOf(current) - finalSpeedOf(previous)) >= RECORDER_FINAL_CONFIG.velocityThreshold then
        return true
    end

    if nextSample then
        local c = finalPositionOf(nextSample)
        if c and (c - b).Magnitude >= RECORDER_FINAL_CONFIG.positionThreshold then
            return true
        end
    end

    return distance >= RECORDER_FINAL_CONFIG.compressionPosition
end

local function finalSampleInterval(previous, current)
    local speed = current and finalSpeedOf(current) or 0
    if speed <= RECORDER_FINAL_CONFIG.idleSpeedThreshold then
        return RECORDER_FINAL_CONFIG.idleSampleInterval
    end
    if speed >= 8 then
        return RECORDER_FINAL_CONFIG.fastSampleInterval
    end
    return RECORDER_FINAL_CONFIG.baseSampleInterval
end

local function finalAdaptiveSubsteps(distance, speed, duration)
    if not RECORDER_FINAL_CONFIG.adaptiveSubsteps then return 1 end
    if duration <= 0 then return 1 end

    local estimate = math.ceil(math.max(
        distance / 2.5,
        speed * duration * 0.35
    ))
    return math.clamp(estimate,
        RECORDER_FINAL_CONFIG.minSubsteps,
        RECORDER_FINAL_CONFIG.maxSubsteps
    )
end



-- ============================================================
-- MUNCAK RECORDER V5 - AUDITED QUALITY LAYER
-- ============================================================
-- Goals:
--   * timestamp-correct playback
--   * velocity + acceleration samples
--   * adaptive sampling decisions
--   * conservative compression
--   * teleport/respawn detection
--   * bounded Hermite interpolation (no extra CFrame chasing)
--   * pause-safe recording/playback clocks
-- ============================================================


local V5_SCHEMA = "MuncakRecorderV5"

local V5_CONFIG = {
    baseInterval = 1/30,
    fastInterval = 1/60,
    idleInterval = 1/12,

    idleSpeed = 0.15,
    fastSpeed = 8.0,

    keepDistance = 0.035,
    keepRotation = 0.01308996938995747, -- 0.75 degrees in radians
    keepVelocityDelta = 0.75,
    keepAccelerationDelta = 4.0,

    teleportDistance = 80,
    hardTeleportDistance = 120,

    maxInterpolationGap = 0.25,
    hermiteTangentScale = 0.85,

    minSubsteps = 1,
    maxSubsteps = 8,
}

local function v5Num(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function v5Vec3Table(v)
    return {
        x = v.X,
        y = v.Y,
        z = v.Z
    }
end

local function v5Vec3(value)
    if typeof(value) == "Vector3" then
        return value
    end
    if type(value) == "table" then
        return Vector3.new(
            tonumber(value.x or value.X) or 0,
            tonumber(value.y or value.Y) or 0,
            tonumber(value.z or value.Z) or 0
        )
    end
    return Vector3.zero
end

local function v5Clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
end

local function v5SampleData(sample)
    if not sample then return nil, nil end
    local cf = sample.cf or sample.cframe or sample.CFrame
    local t = tonumber(sample.t or sample.time or sample.timestamp)
    return cf, t
end

local function v5Velocity(a, b)
    local cfa, ta = v5SampleData(a)
    local cfb, tb = v5SampleData(b)
    if type(cfa) == "table" then cfa = deserializeCFrame(cfa) end
    if type(cfb) == "table" then cfb = deserializeCFrame(cfb) end
    if not cfa or not cfb or not ta or not tb then
        return Vector3.zero
    end
    local dt = tb - ta
    if dt <= 1/240 then return Vector3.zero end
    return (cfb.Position - cfa.Position) / dt
end

local function v5Acceleration(a, b, c)
    local va = v5Velocity(a, b)
    local vb = v5Velocity(b, c)
    local _, tb = v5SampleData(b)
    local _, tc = v5SampleData(c)
    if not tb or not tc then return Vector3.zero end
    local dt = tc - tb
    if dt <= 1/240 then return Vector3.zero end
    return (vb - va) / dt
end

local function v5ShouldKeep(prev, cur, nxt)
    if not prev or not cur then return true end

    local a = v5SampleData(prev)
    local b = v5SampleData(cur)
    if not a or not b then return true end

    local d = (b.Position - a.Position).Magnitude
    if d >= V5_CONFIG.teleportDistance then
        return true
    end

    local va = v5Velocity(prev, cur)
    local vb = nxt and v5Velocity(cur, nxt) or va
    local dv = (vb - va).Magnitude

    if d >= V5_CONFIG.keepDistance then return true end
    if dv >= V5_CONFIG.keepVelocityDelta then return true end

    local ca = prev.cf or prev.cframe or prev.CFrame
    local cb = cur.cf or cur.cframe or cur.CFrame
    if ca and cb then
        local _, _, _, r00,r01,r02,r10,r11,r12,r20,r21,r22 = cb:GetComponents()
        local _, _, _, q00,q01,q02,q10,q11,q12,q20,q21,q22 = ca:GetComponents()
        local trace = r00*q00 + r01*q01 + r02*q02 +
                      r10*q10 + r11*q11 + r12*q12 +
                      r20*q20 + r21*q21 + r22*q22
        local cosAngle = v5Clamp((trace - 1) / 2, -1, 1)
        if math.acos(cosAngle) >= V5_CONFIG.keepRotation then
            return true
        end
    end

    if nxt then
        local acc = v5Acceleration(prev, cur, nxt)
        if acc.Magnitude >= V5_CONFIG.keepAccelerationDelta then
            return true
        end
    end

    return false
end

local function v5AdaptiveInterval(sample)
    local speed = 0
    if sample then
        local cf, _ = v5SampleData(sample)
        if cf and sample.velocity then
            speed = v5Vec3(sample.velocity).Magnitude
        elseif cf then
            speed = 0
        end
    end

    local idleSpeed = v5Num(V5_CONFIG.idleSpeed, 0.15)
    local fastSpeed = v5Num(V5_CONFIG.fastSpeed, 8.0)
    local idleInterval = v5Num(V5_CONFIG.idleInterval, 1/12)
    local fastInterval = v5Num(V5_CONFIG.fastInterval, 1/60)

    if speed <= idleSpeed then
        return idleInterval
    elseif speed >= fastSpeed then
        return fastInterval
    end

    local span = math.max(fastSpeed - idleSpeed, 0.001)
    local alpha = (speed - idleSpeed) / span
    return idleInterval + (fastInterval - idleInterval) * v5Clamp(alpha, 0, 1)
end

local function v5Hermite(a, b, t)
    local cfa, ta = v5SampleData(a)
    local cfb, tb = v5SampleData(b)
    if not cfa or not cfb then return cfb or cfa end

    t = v5Clamp(t, 0, 1)
    local dt = math.min(math.max((tb or 0) - (ta or 0), 1/240), V5_CONFIG.maxInterpolationGap)

    local p0 = cfa.Position
    local p1 = cfb.Position
    local m0 = (a.velocity or v5Velocity(a, b)) * dt * V5_CONFIG.hermiteTangentScale
    local m1 = (b.velocity or v5Velocity(a, b)) * dt * V5_CONFIG.hermiteTangentScale

    local t2 = t * t
    local t3 = t2 * t
    local h00 =  2*t3 - 3*t2 + 1
    local h10 =    t3 - 2*t2 + t
    local h01 = -2*t3 + 3*t2
    local h11 =    t3 - t2

    local p = p0*h00 + m0*h10 + p1*h01 + m1*h11

    -- Clamp excessive Hermite overshoot to the segment AABB.
    local minX, maxX = math.min(p0.X,p1.X), math.max(p0.X,p1.X)
    local minY, maxY = math.min(p0.Y,p1.Y), math.max(p0.Y,p1.Y)
    local minZ, maxZ = math.min(p0.Z,p1.Z), math.max(p0.Z,p1.Z)
    p = Vector3.new(
        v5Clamp(p.X, minX, maxX),
        v5Clamp(p.Y, minY, maxY),
        v5Clamp(p.Z, minZ, maxZ)
    )

    local rotation = cfa.Rotation:Lerp(cfb.Rotation, t)
    return CFrame.new(p) * rotation
end

local function v5Substeps(a, b, duration)
    local cfa = v5SampleData(a)
    local cfb = v5SampleData(b)
    if not cfa or not cfb or duration <= 0 then return 1 end

    local distance = (cfb.Position - cfa.Position).Magnitude
    local speed = (a.velocity and a.velocity.Magnitude) or
                  (b.velocity and b.velocity.Magnitude) or 0

    return math.clamp(
        math.ceil(math.max(distance / 2.5, speed * duration * 0.35)),
        V5_CONFIG.minSubsteps,
        V5_CONFIG.maxSubsteps
    )
end

-- Create an enriched sample from a CFrame and absolute timeline timestamp.
-- `prev` is the last retained sample; velocity/acceleration are computed
-- from the timeline, not frame rate.
local function v5MakeSample(cf, t, prev, prevPrev)
    local s = { t = t, cf = cf }

    if prev then
        s.velocity = v5Velocity(prev, s)
    else
        s.velocity = Vector3.zero
    end

    if prevPrev and prev then
        s.acceleration = v5Acceleration(prevPrev, prev, s)
    else
        s.acceleration = Vector3.zero
    end

    return s
end

-- Pause-safe recorder clock. Feed `now` from os.clock().
local function v5RecorderClock(state, now)
    state._v5Start = state._v5Start or now
    state._v5PausedAt = state._v5PausedAt
    state._v5PausedTotal = state._v5PausedTotal or 0

    if state._v5PausedAt then
        return state._v5PausedAt - state._v5Start - state._v5PausedTotal
    end

    return now - state._v5Start - state._v5PausedTotal
end

local function v5PauseClock(state, now)
    if not state._v5PausedAt then
        state._v5PausedAt = now
    end
end

local function v5ResumeClock(state, now)
    if state._v5PausedAt then
        state._v5PausedTotal =
            (state._v5PausedTotal or 0) + (now - state._v5PausedAt)
        state._v5PausedAt = nil
    end
end

print("Muncak Recorder V5 audited quality layer loaded")

-- Delta/executor filesystem compatibility
-- File disimpan di workspace executor, dalam folder MuncakRecorder.
local FILE_DIR = "MuncakRecorder"

local HAS_READFILE = type(readfile) == "function"
local HAS_WRITEFILE = type(writefile) == "function"
local HAS_ISFILE = type(isfile) == "function"
local HAS_LISTFILES = type(listfiles) == "function"
local HAS_MAKEFOLDER = type(makefolder) == "function"

local function filePath(filename)
    filename = tostring(filename or "")
    filename = filename:gsub("^[/\\\\]+", "")
    return FILE_DIR .. "/" .. filename
end

local function ensureFileFolder()
    if not HAS_WRITEFILE then
        return false, "writefile tidak tersedia di Delta"
    end

    if HAS_MAKEFOLDER then
        if type(isfolder) == "function" then
            local ok, exists = pcall(isfolder, FILE_DIR)
            if ok and exists then
                return true
            end
        end

        local ok, err = pcall(makefolder, FILE_DIR)
        if not ok then
            -- Folder mungkin sudah ada; lanjutkan dan biarkan writefile yang menentukan.
            if HAS_ISFILE then
                return true
            end
            return false, tostring(err)
        end
    end

    return true
end

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

-- Compact mobile UI
local CompactUIScale = Instance.new("UIScale")
CompactUIScale.Name = "CompactUIScale"
CompactUIScale.Scale = 0.82 -- 82%
CompactUIScale.Parent = ScreenGui
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
Title.Text = "Muncak Recorder V6 Compact FIXED"
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
    if not HAS_WRITEFILE then
        return false, "writefile tidak tersedia di Delta"
    end

    local folderOK, folderErr = ensureFileFolder()
    if not folderOK then
        return false, "Gagal menyiapkan folder: " .. tostring(folderErr)
    end

    local path = filePath(filename)
    local payload = HttpService:JSONEncode(data)

    local ok, err = pcall(function()
        writefile(path, payload)
    end)

    if not ok then
        return false, "writefile gagal: " .. tostring(err)
    end

    -- Verifikasi bila isfile tersedia.
    if HAS_ISFILE then
        local verifyOK, exists = pcall(isfile, path)
        if verifyOK and not exists then
            return false, "writefile dipanggil tetapi file tidak terdeteksi: " .. path
        end
    end

    return true
end

local compressPath

local function stopRecording()
    if not State.Recording then return end

    State.Recording = false
    State.RecordPaused = false
    if PauseRecord then
        PauseRecord.Text = "Ⅱ PAUSE"
    end

    local filename = FileBox.Text
    if filename == "" then filename = CONFIG.DefaultFile end
    if not filename:match("%.json$") then filename = filename .. ".json" end

    if #State.RecordedPath == 0 then
        setStatus("Save dibatalkan: belum ada sample")
        return
    end

    -- A one-sample recording cannot be played as a timeline.
    -- Keep the file valid by adding a tiny-duration stationary endpoint.
    if #State.RecordedPath == 1 then
        local first = State.RecordedPath[1]
        local second = {
            t = tonumber(first.t or 0) + 1/30,
            cf = table.clone(first.cf),
            velocity = {x = 0, y = 0, z = 0},
            acceleration = {x = 0, y = 0, z = 0},
        }
        table.insert(State.RecordedPath, second)
    end

    -- Compress only at save time so recording-time decisions remain responsive.
    local outputPath = compressPath(State.RecordedPath)

    -- Ensure all Vector3 fields are JSON-safe even if a future recorder path
    -- stores native Vector3 values internally.
    for _, point in ipairs(outputPath) do
        if typeof(point.velocity) == "Vector3" then
            point.velocity = v5Vec3Table(point.velocity)
        end
        if typeof(point.acceleration) == "Vector3" then
            point.acceleration = v5Vec3Table(point.acceleration)
        end
    end

    local success, err = saveFile(filename, outputPath)

    if success then
        setStatus(string.format("Saved %s | %d → %d points", filename, #State.RecordedPath, #outputPath))
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

    -- Pause-safe timeline clock.
    local timelineStart = os.clock()
    local pausedAt = nil
    local pausedTotal = 0

    local lastCF = nil
    local lastSampleWall = timelineStart
    local lastRetained = nil
    local lastRetainedPrev = nil

    local function timelineNow(now)
        if pausedAt then
            return pausedAt - timelineStart - pausedTotal
        end
        return now - timelineStart - pausedTotal
    end

    local function pauseTimeline(now)
        if not pausedAt then
            pausedAt = now
        end
    end

    local function resumeTimeline(now)
        if pausedAt then
            pausedTotal += now - pausedAt
            pausedAt = nil
            lastSampleWall = now
        end
    end

    State._V5RecordPause = pauseTimeline
    State._V5RecordResume = resumeTimeline

    -- Capture the initial sample synchronously.
    -- This makes recording visibly active immediately and guarantees a
    -- valid timeline anchor even if the user stops very quickly.
    local initialSample = {
        t = 0,
        cf = serializeCFrame(root.CFrame),
        velocity = v5Vec3Table(Vector3.zero),
        acceleration = v5Vec3Table(Vector3.zero),
    }

    table.insert(State.RecordedPath, initialSample)
    lastCF = root.CFrame
    lastRetained = initialSample
    lastRetainedPrev = nil
    lastSampleWall = timelineStart

    RecordInfo.Text = string.format(
        "Points: %d\nDuration: 00:00.00\nSpeed: 0.00",
        #State.RecordedPath
    )

    setStatus("Recording aktif | 1 sample")

    task.spawn(function()
        local nextSampleInterval = V5_CONFIG.baseInterval

        local ok, runtimeErr = xpcall(function()
        while State.Recording do
            local now = os.clock()

            if State.RecordPaused then
                pauseTimeline(now)
                task.wait()
                continue
            elseif pausedAt then
                resumeTimeline(now)
            end

            local currentRoot = getRoot()

            -- Character reset/respawn: start a new continuity point instead
            -- of interpolating across an invalid root.
            if not currentRoot then
                lastCF = nil
                lastRetained = nil
                lastRetainedPrev = nil
                task.wait(0.05)
                continue
            end

            local cf = currentRoot.CFrame
            local t = timelineNow(now)
            local shouldRecord = false

            if not lastCF then
                shouldRecord = true
            else
                local distance = (cf.Position - lastCF.Position).Magnitude
                local rotation = angleDifference(cf, lastCF)

                -- Fast path: retain sharp movement and large jumps.
                if distance >= CONFIG.PositionThreshold
                    or rotation >= CONFIG.RotationThreshold
                    or (now - lastSampleWall) >= nextSampleInterval then
                    shouldRecord = true
                end
            end

            if shouldRecord then
                -- Build an enriched sample from the actual timeline.
                local sample = {
                    t = t,
                    cf = serializeCFrame(cf),
                }

                if lastRetained then
                    local prevCF = deserializeCFrame(lastRetained.cf)
                    if prevCF then
                        local dtSample = math.max(t - lastRetained.t, 1/240)
                        sample.velocity = v5Vec3Table((cf.Position - prevCF.Position) / dtSample)
                    else
                        sample.velocity = v5Vec3Table(Vector3.zero)
                    end
                else
                    sample.velocity = v5Vec3Table(Vector3.zero)
                end

                if lastRetainedPrev and lastRetained then
                    local prevCF = deserializeCFrame(lastRetained.cf)
                    local prevPrevCF = deserializeCFrame(lastRetainedPrev.cf)

                    if prevCF and prevPrevCF then
                        local dtA = math.max(lastRetained.t - lastRetainedPrev.t, 1/240)
                        local dtB = math.max(t - lastRetained.t, 1/240)
                        local vA = (prevCF.Position - prevPrevCF.Position) / dtA
                        local vB = (cf.Position - prevCF.Position) / dtB
                        sample.acceleration = v5Vec3Table((vB - vA) / math.max((dtA + dtB) * 0.5, 1/240))
                    else
                        sample.acceleration = v5Vec3Table(Vector3.zero)
                    end
                else
                    sample.acceleration = v5Vec3Table(Vector3.zero)
                end

                -- Look-ahead isn't available yet, so retain meaningful changes
                -- now and perform a second conservative compression pass on stop.
                local speed = v5Vec3(sample.velocity).Magnitude

                local keep = true
                if lastRetained then
                    local prevCF = deserializeCFrame(lastRetained.cf)
                    if prevCF then
                        local d = (cf.Position - prevCF.Position).Magnitude
                        local dv = (v5Vec3(sample.velocity) - v5Vec3(lastRetained.velocity)).Magnitude

                        local keepDistance = v5Num(V5_CONFIG.keepDistance, 0.035)
                        local keepRotation = v5Num(V5_CONFIG.keepRotation, 0.01308996938995747)
                        local keepVelocityDelta = v5Num(V5_CONFIG.keepVelocityDelta, 0.75)
                        local keepAccelerationDelta = v5Num(V5_CONFIG.keepAccelerationDelta, 4.0)
                        local teleportDistance = v5Num(V5_CONFIG.teleportDistance, 80)

                        keep =
                            d >= keepDistance
                            or rotation >= keepRotation
                            or dv >= keepVelocityDelta
                            or v5Vec3(sample.acceleration).Magnitude >= keepAccelerationDelta
                            or d >= teleportDistance
                    end
                end

                if keep or not lastRetained then
                    table.insert(State.RecordedPath, sample)

                    lastRetainedPrev = lastRetained
                    lastRetained = sample
                    lastCF = cf
                    lastSampleWall = now

                    -- Faster movement => denser samples.
                    nextSampleInterval = v5AdaptiveInterval(sample)

                    local elapsed = t
                    RecordInfo.Text = string.format(
                        "Points: %d\nDuration: %02d:%05.2f\nSpeed: %.2f",
                        #State.RecordedPath,
                        math.floor(elapsed / 60),
                        elapsed % 60,
                        speed
                    )
                end
            end

            -- Use the adaptive interval as the polling cadence, but never sleep
            -- so long that a sharp movement is skipped for too long.
            task.wait(math.clamp(tonumber(nextSampleInterval) or (1/30), 1/120, 1/20))
        end
        end, TRACEBACK_HANDLER)

        State._V5RecordPause = nil
        State._V5RecordResume = nil

        if not ok and State.Recording then
            State.Recording = false
            State.RecordPaused = false
            setStatus("Recording error: " .. tostring(runtimeErr):sub(1, 180))
            warn("[Muncak Recorder V5] Recording error:\n" .. tostring(runtimeErr))
        end
    end)
end)

PauseRecord.MouseButton1Click:Connect(function()
    if not State.Recording then return end

    State.RecordPaused = not State.RecordPaused
    local now = os.clock()

    if State.RecordPaused then
        if State._V5RecordPause then
            State._V5RecordPause(now)
        end
        PauseRecord.Text = "▶ RESUME"
        setStatus("Recording paused")
    else
        if State._V5RecordResume then
            State._V5RecordResume(now)
        end
        PauseRecord.Text = "Ⅱ PAUSE"
        setStatus("Recording resumed")
    end
end)

StopRecord.MouseButton1Click:Connect(stopRecording)

compressPath = function(path)
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
                    directionA.Unit:Dot(directionB.Unit), -1, 1
                ))
            end

            local rotation = angleDifference(cfA, cfB)

            local velocityDelta = 0
            if current.velocity and previous.velocity then
                velocityDelta = (v5Vec3(current.velocity) - v5Vec3(previous.velocity)).Magnitude
            end

            local acceleration = v5Vec3(current.acceleration).Magnitude

            local keep =
                move >= CONFIG.CompressionDistance
                or nextMove >= CONFIG.CompressionDistance
                or angle >= CONFIG.CompressionAngle
                or rotation >= CONFIG.CompressionAngle
                or velocityDelta >= V5_CONFIG.keepVelocityDelta
                or acceleration >= V5_CONFIG.keepAccelerationDelta
                or move >= V5_CONFIG.teleportDistance

            if keep then
                table.insert(result, current)
            end
        else
            -- Never silently drop malformed points.
            table.insert(result, current)
        end
    end

    table.insert(result, path[#path])
    return result
end

local function getSmoothCFrame(path, index, alpha)
    local a = path[index]
    local b = path[index + 1]
    if not a or not b then return nil end

    local cfa = deserializeCFrame(a.cf)
    local cfb = deserializeCFrame(b.cf)
    if not cfa or not cfb then return nil end

    local ta = tonumber(a.t)
    local tb = tonumber(b.t)
    if not ta or not tb or tb < ta then
        return nil
    end

    local duration = math.max(tb - ta, 1/240)
    if duration > V5_CONFIG.maxInterpolationGap
        or (cfb.Position - cfa.Position).Magnitude >= V5_CONFIG.teleportDistance then
        return cfa:Lerp(cfb, math.clamp(alpha, 0, 1))
    end

    alpha = math.clamp(alpha, 0, 1)

    local v0 = a.velocity and v5Vec3(a.velocity) or v5Velocity(a, b)
    local v1 = b.velocity and v5Vec3(b.velocity) or v5Velocity(a, b)

    local dt = math.min(duration, V5_CONFIG.maxInterpolationGap)
    local m0 = v0 * dt * V5_CONFIG.hermiteTangentScale
    local m1 = v1 * dt * V5_CONFIG.hermiteTangentScale

    local t = alpha
    local t2 = t * t
    local t3 = t2 * t

    local h00 =  2*t3 - 3*t2 + 1
    local h10 =    t3 - 2*t2 + t
    local h01 = -2*t3 + 3*t2
    local h11 =    t3 - t2

    local p0 = cfa.Position
    local p1 = cfb.Position

    local position =
        p0 * h00 +
        m0 * h10 +
        p1 * h01 +
        m1 * h11

    -- Prevent Hermite overshoot from creating movement outside the segment.
    position = Vector3.new(
        math.clamp(position.X, math.min(p0.X,p1.X), math.max(p0.X,p1.X)),
        math.clamp(position.Y, math.min(p0.Y,p1.Y), math.max(p0.Y,p1.Y)),
        math.clamp(position.Z, math.min(p0.Z,p1.Z), math.max(p0.Z,p1.Z))
    )

    local rotation = cfa.Rotation:Lerp(cfb.Rotation, alpha)
    return CFrame.new(position) * rotation
end

local function findSegment(path, time)
    local low = 1
    local high = #path - 1

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local a = tonumber(path[mid].t)
        local b = tonumber(path[mid + 1].t)

        if not a or not b then
            return nil
        end

        if b < a then
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

    return math.clamp(low, 1, #path - 1)
end

local function stopPlayback()
    State.Playing = false
    State.PlaybackPaused = false
    State._PlaybackRunId = (State._PlaybackRunId or 0) + 1
end

local function playPath(path)
    if State.Playing then return end

    if #path < 2 then
        setStatus("Path terlalu pendek")
        return
    end

    -- Validate and normalize loaded JSON before playback.
    local cleanPath = {}
    local lastT = -math.huge

    for _, sample in ipairs(path) do
        if type(sample) == "table" then
            local t = tonumber(sample.t)
            local cf = sample.cf

            if t and type(cf) == "table" and #cf >= 12 and t >= lastT then
                sample.t = t
                if sample.velocity then
                    sample.velocity = v5Vec3(sample.velocity)
                end
                if sample.acceleration then
                    sample.acceleration = v5Vec3(sample.acceleration)
                end
                table.insert(cleanPath, sample)
                lastT = t
            end
        end
    end

    if #cleanPath < 2 then
        setStatus("Path invalid: butuh minimal 2 sample valid")
        return
    end

    local compressed = compressPath(cleanPath)
    if #compressed < 2 then
        setStatus("Path invalid")
        return
    end

    State.LoadedPath = compressed
    State.Playing = true
    State.PlaybackPaused = false
    State.PlaybackTime = 0
    State.PlaybackDuration = compressed[#compressed].t
    State._PlaybackRunId = (State._PlaybackRunId or 0) + 1
    local playbackRunId = State._PlaybackRunId

    setStatus(string.format("Playing %.2fx | %d points", State.Speed, #compressed))

    task.spawn(function()
        local ok, runtimeErr = xpcall(function()
        local lastClock = os.clock()

        while State.Playing and State._PlaybackRunId == playbackRunId do
            if State.PlaybackPaused then
                lastClock = os.clock()
                task.wait()
                continue
            end

            local now = os.clock()
            local wallDt = now - lastClock
            lastClock = now

            -- Don't discard elapsed timeline on frame spikes.
            local dt = math.clamp(wallDt, 0, 0.10)
            State.PlaybackTime += dt * State.Speed

            if State.PlaybackTime >= State.PlaybackDuration then
                State.PlaybackTime = State.PlaybackDuration

                local root = getRoot()
                if root then
                    local final = deserializeCFrame(compressed[#compressed].cf)
                    if final then
                        root.CFrame = final
                    end
                end
                break
            end

            local index = findSegment(compressed, State.PlaybackTime)
            if not index then
                setStatus("Playback error: timeline sample invalid")
                break
            end

            local a = compressed[index]
            local b = compressed[index + 1]

            if not a or not b then
                setStatus("Playback error: segment invalid")
                break
            end

            local duration = math.max(b.t - a.t, 1/240)
            local alpha = math.clamp(
                (State.PlaybackTime - a.t) / duration,
                0,
                1
            )

            local root = getRoot()
            if root then
                -- Teleports/respawns are snapped instead of interpolated.
                local cfa = deserializeCFrame(a.cf)
                local cfb = deserializeCFrame(b.cf)

                if cfa and cfb then
                    local distance = (cfb.Position - cfa.Position).Magnitude
                    local target

                    if distance >= V5_CONFIG.teleportDistance then
                        -- A recorded teleport/respawn is an event, not a path.
                        -- Hold A until B's timestamp, then snap to B.
                        target = (alpha >= 0.999999) and cfb or cfa
                    elseif duration >= V5_CONFIG.maxInterpolationGap then
                        -- Large gaps are interpolated linearly rather than
                        -- inventing velocity that was never recorded.
                        target = cfa:Lerp(cfb, alpha)
                    else
                        target = getSmoothCFrame(compressed, index, alpha)
                    end

                    if target then
                        -- IMPORTANT: direct timeline application.
                        -- No root.CFrame:Lerp() chase, so playback time remains
                        -- the single source of truth at every speed/FPS.
                        root.CFrame = target
                    end
                end
            end

            task.wait()
        end
        end, TRACEBACK_HANDLER)

        State.Playing = false

        if not ok then
            setStatus("Playback error: " .. tostring(runtimeErr):sub(1, 180))
            warn("[Muncak Recorder V5] Playback error:\n" .. tostring(runtimeErr))
            return
        end

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
    if not HAS_READFILE then
        return nil, "readfile tidak tersedia di Delta"
    end

    local path = filePath(filename)

    if HAS_ISFILE then
        local existsOK, exists = pcall(isfile, path)
        if existsOK and not exists then
            return nil, "File tidak ditemukan: " .. path
        end
    end

    local ok, result = pcall(function()
        return HttpService:JSONDecode(readfile(path))
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
        setStatus("listfiles tidak tersedia di Delta")
        return
    end

    local ok, files = pcall(listfiles, FILE_DIR)
    if not ok then
        -- Beberapa executor hanya menerima listfiles() tanpa argumen.
        ok, files = pcall(listfiles)
    end
    if not ok then return end

    for _, file in ipairs(files) do
        file = tostring(file)

        -- listfiles() bisa mengembalikan "MuncakRecorder/nama.json"
        -- atau hanya "nama.json".
        local displayName = file:match("([^/\\\\]+)$") or file

        if displayName:lower():match("%.json$") then
            local b = createButton(
                FileList,
                displayName,
                UDim2.fromOffset(0,0),
                UDim2.new(1,-10,0,34)
            )

            b.Parent = FileList

            b.MouseButton1Click:Connect(function()
                State.SelectedFile = displayName
                setStatus("Selected: " .. displayName)
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

if not HAS_WRITEFILE then
    setStatus("Delta: writefile tidak tersedia")
elseif not HAS_READFILE then
    setStatus("Delta: writefile OK, readfile tidak tersedia")
else
    setStatus("FINAL: adaptive + compression + velocity playback aktif")
end

print("Muncak Recorder V3 Loaded Successfully")
print("Storage folder: " .. FILE_DIR)
print("writefile:", HAS_WRITEFILE, "readfile:", HAS_READFILE, "isfile:", HAS_ISFILE, "listfiles:", HAS_LISTFILES, "makefolder:", HAS_MAKEFOLDER)


-- FINAL build diagnostics
print("Recorder FINAL config loaded")
print("Adaptive sampling:", RECORDER_FINAL_CONFIG.adaptiveSampling)
print("Compression:", RECORDER_FINAL_CONFIG.compression)
print("Velocity interpolation:", RECORDER_FINAL_CONFIG.velocityInterpolation)
print("Acceleration interpolation:", RECORDER_FINAL_CONFIG.accelerationInterpolation)
print("Adaptive substeps:", RECORDER_FINAL_CONFIG.adaptiveSubsteps)
print("Teleport detection:", RECORDER_FINAL_CONFIG.teleportDistance)

-- V5 integration note:
-- The helper API above is intentionally standalone so it can be wired into
-- the recorder/playback loop without relying on undocumented executor APIs.
-- Existing UI/file/save functions remain untouched.

print("Muncak Recorder V6 Stable loaded")
