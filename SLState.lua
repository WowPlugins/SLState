-- SteamLike State
--
-- 把角色状态暴露给 SteamLike Windows 客户端。
--
-- 支持两种暴露方式（设置界面里二选一）：
--   a. Lua 数组内存共享：外部进程扫描 anchor 浮点定位数组，按 16 字节步幅读取；
--   b. 像素点：在屏幕左上角绘制一排色块，外部进程用 BitBlt 截图解码。
--
-- 原理（方式 a）：Lua 5.1 的 table 用顺序整数索引填充时，会分配一块连续的
-- TValue 数组（array part），每槽 16 字节：前 8 字节 double 数值，后 4 字节
-- 类型标签（number 为 3），再 4 字节对齐填充。外部进程扫描前三个 anchor 浮点
-- 定位这块内存，之后按 (i-1)*16 的固定步幅复读。
--
-- 三条硬约束（写错就失效）：
--   1. 初始化时一次顺序填满 1..16，之后永不增删索引
--      （中途跳着写或插入非整数键会触发 rehash，把槽挪到 hash part）；
--   2. 槽里只放 number（放字符串会变成 GC 指针，内容在另一块内存）；
--   3. 表必须保持强引用，不能被 GC 回收。
--
-- 槽位布局（索引 i 对应字节偏移 (i-1)*16）：
--   1..3   anchor 浮点
--   4      seq（帧序号，payload 写完才写它）
--   5..14  状态位 S0..S9（1 = 真，0 = 假），顺序与 STATE_DEFS 一致
--   15     checksum = (seq*31 + Σ S(i)*(i+1)) % 65536
--   16     seq 再写一次（读端要求 4 与 16 相同才接受）
--
-- 像素点布局（屏幕左上角水平排列，每块 6x6，间隔 2）：
--   [锚点蓝][校验青][S0][S1]...[S9]
--   锚点 = 纯蓝 RGB(0,0,255)，校验 = 青色 RGB(0,255,255)
--   状态块：真 = 绿 RGB(0,255,0)，假 = 红 RGB(255,0,0)
--
-- 命令：/slstate          打开/关闭设置面板
--       /slstate debug    切换调试日志（默认关闭）

SLStateDB = SLStateDB or {}
if SLStateDB.debug == nil then
    SLStateDB.debug = false
end
if SLStateDB.enabled == nil then
    SLStateDB.enabled = true
end
if SLStateDB.method == nil then
    SLStateDB.method = "lua"
end
if SLStateDB.exposed_states == nil then
    SLStateDB.exposed_states = { stealthed = true, chatOpen = false }
end
if SLStateDB.pixel_x == nil then
    SLStateDB.pixel_x = 10
end
if SLStateDB.pixel_y == nil then
    SLStateDB.pixel_y = 10
end

local PREFIX = "|cff33ff99[SLState]|r "

--- 可暴露的状态定义（顺序即数组槽位 / 像素块顺序，最多 10 个）
local STATE_DEFS = {
    { id = "stealthed",  name = "潜行中" },
    { id = "chatOpen",   name = "聊天窗打开" },
    { id = "inCombat",   name = "战斗中" },
    { id = "mounted",    name = "骑乘中" },
    { id = "hasTarget",  name = "有目标" },
    { id = "hasPet",     name = "有宠物" },
    { id = "isDead",     name = "死亡" },
    { id = "isGhost",    name = "灵魂状态" },
    { id = "isFalling",  name = "下落中" },
    { id = "isSwimming", name = "游泳中" },
}
local MAX_STATES = #STATE_DEFS
local SLOT_SEQ = 4
local SLOT_FIRST_STATE = 5
local SLOT_CHECKSUM = 15
local SLOT_SEQ2 = 16
local BUF_SLOTS = 16

--- 调试日志：只在设置面板里打开开关后才输出到聊天框
local function Debug(msg)
    if SLStateDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
    end
end

local BUF = {}
for i = 1, BUF_SLOTS do BUF[i] = 0 end -- 顺序填满 → array part 稳定为 16 槽，无 hash part

-- anchor 在运行期拼出来，避免完整三个常量直接出现在字节码常量区
local a1 = 3000 + 494.38 -- 3494.38
local a2 = 1500 + 482.44 -- 1982.44
local a3 = 9000 + 918.71 -- 9918.71
BUF[3] = a3
BUF[2] = a2
BUF[1] = a1

-- 强引用，防止被 GC 回收
SL_STATE_MEM = BUF

local seq = 0
local lastStates = {}
local acc = 0          -- 瞬时状态轮询计时（只用于下落/游泳）
local dirty = false    -- 是否有待处理的状态事件
local dirtyAcc = 0     -- 事件合并计时
local usedFallback = false
local chatEditHooked = false -- 聊天输入框脚本是否已挂上（加载时可能还不存在，进世界后重试）
local panel
local optionsPanel
local statusTexts = {}
local debugChecks = {}
local enableChecks = {}
local methodChecks = { lua = {}, pixel = {} }
local stateChecks = {}
local pixelBlocks = {}

--- 设置界面里的状态文字（浮动面板与原生选项页共用）
local function UpdateStatus()
    local parts = {}
    for i = 1, MAX_STATES do
        if SLStateDB.exposed_states[STATE_DEFS[i].id] then
            parts[#parts + 1] = STATE_DEFS[i].name .. "：" ..
                (lastStates[i] and "|cff00ff00是|r" or "|cffff5555否|r")
        end
    end
    local body = #parts > 0 and table.concat(parts, "  ") or "（未启用任何状态）"
    local text = string.format(
        "总开关：%s    方式：%s\nseq = %d    调试日志：%s\n%s",
        SLStateDB.enabled and "开" or "关",
        SLStateDB.method == "pixel" and "像素点" or "Lua 内存",
        seq, SLStateDB.debug and "开" or "关", body)
    for i = 1, #statusTexts do
        statusTexts[i]:SetText(text)
    end
end

--- 把所有界面勾选框同步到当前配置（两个界面共用一份状态）
local function SyncUIControls()
    local i
    for i = 1, #debugChecks do
        debugChecks[i]:SetChecked(SLStateDB.debug and 1 or nil)
    end
    for i = 1, #enableChecks do
        enableChecks[i]:SetChecked(SLStateDB.enabled and 1 or nil)
    end
    for i = 1, #methodChecks.lua do
        methodChecks.lua[i]:SetChecked(SLStateDB.method == "lua" and 1 or nil)
    end
    for i = 1, #methodChecks.pixel do
        methodChecks.pixel[i]:SetChecked(SLStateDB.method == "pixel" and 1 or nil)
    end
    for i = 1, #stateChecks do
        local e = stateChecks[i]
        e.cb:SetChecked(SLStateDB.exposed_states[e.id] and 1 or nil)
    end
end

--- 切换调试日志（两个界面的勾选框保持同步）
local function SetDebug(on)
    SLStateDB.debug = on
    SyncUIControls()
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "调试日志已" .. (on and "开启" or "关闭"))
    end
    UpdateStatus()
end

--- 写入一帧（payload 全部写完才写 seq，读端据此判断整帧有效）
local function Pulse(states)
    seq = (seq + 1) % 65536
    local sum = 0
    for i = 1, MAX_STATES do
        local v = states[i] and 1 or 0
        BUF[SLOT_FIRST_STATE + i - 1] = v
        sum = sum + v * (i + 1)
    end
    local chk = (seq * 31 + sum) % 65536
    BUF[SLOT_CHECKSUM] = chk
    BUF[SLOT_SEQ] = seq
    BUF[SLOT_SEQ2] = seq
    Debug(string.format("写入帧 seq=%d chk=%d", seq, chk))
    UpdateStatus()
end

--- 检测玩家是否处于潜行状态
--- 优先用 IsStealthed()；个别客户端没有该 API 时退回扫描玩家增益图标
local function DetectStealth()
    if IsStealthed then
        return IsStealthed() and 1 or 0
    end
    if not usedFallback then
        usedFallback = true
        Debug("IsStealthed 不可用，改为扫描玩家增益图标")
    end
    for i = 1, 16 do
        -- 1.12 的第 1 个返回值是图标路径，3.3.5 的第 3 个才是，两者都取
        local first, _, third = UnitBuff("player", i)
        local icon = third or first
        if icon then
            local lower = string.lower(icon)
            if string.find(lower, "ability_stealth") or string.find(lower, "ability_ambush") then
                return 1
            end
        end
    end
    return 0
end

--- 按状态 id 分发到具体的客户端 API（API 不存在时视为假）
local function DetectState(id)
    if id == "stealthed" then
        return DetectStealth() == 1
    elseif id == "chatOpen" then
        -- 聊天输入框打开（正在打字）才算"聊天窗打开"；ChatFrame1 本身常驻显示，不能用来判断
        return (ChatFrame1EditBox and ChatFrame1EditBox:IsShown()) and true or false
    elseif id == "inCombat" then
        return UnitAffectingCombat and UnitAffectingCombat("player") and true or false
    elseif id == "mounted" then
        return IsMounted and IsMounted() and true or false
    elseif id == "hasTarget" then
        return UnitExists and UnitExists("target") and true or false
    elseif id == "hasPet" then
        return UnitExists and UnitExists("pet") and true or false
    elseif id == "isDead" then
        return UnitIsDead and UnitIsDead("player") and true or false
    elseif id == "isGhost" then
        return UnitIsGhost and UnitIsGhost("player") and true or false
    elseif id == "isFalling" then
        return IsFalling and IsFalling() and true or false
    elseif id == "isSwimming" then
        return IsSwimming and IsSwimming() and true or false
    end
    return false
end

--- 采集所有启用状态的当前值（未启用的位置固定为 false）
local function DetectAllStates()
    local states = {}
    for i = 1, MAX_STATES do
        local def = STATE_DEFS[i]
        if SLStateDB.exposed_states[def.id] then
            states[i] = DetectState(def.id) and true or false
        else
            states[i] = false
        end
    end
    return states
end

--- 比较两帧状态是否一致
local function StatesChanged(a, b)
    for i = 1, MAX_STATES do
        if (a[i] and true or false) ~= (b[i] and true or false) then
            return true
        end
    end
    return false
end

-- 像素块尺寸（物理像素）：6x6，间隔 2
local PIXEL_BLOCK = 6
local PIXEL_STEP = 8

--- UI 坐标与物理像素的换算比例
local function PixelScale()
    local s = 1
    if UIParent and UIParent.GetEffectiveScale then
        s = UIParent:GetEffectiveScale() or 1
    end
    if not s or s <= 0 then
        s = 1
    end
    return s
end

--- 创建一个纯色像素块（白纹理 + 顶点着色）
local function CreatePixelBlock()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(f)
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    f.tex = tex
    f:Hide()
    pixelBlocks[#pixelBlocks + 1] = f
    return f
end

--- 按物理像素坐标摆放色块
local function PlacePixelBlock(f, physX, physY)
    local s = PixelScale()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", physX / s, -(physY / s))
    f:SetWidth(PIXEL_BLOCK / s)
    f:SetHeight(PIXEL_BLOCK / s)
end

--- 绘制一整排像素块：[锚点][校验][S0..S9]
local function DrawPixels(states)
    local need = 2 + MAX_STATES
    while #pixelBlocks < need do
        CreatePixelBlock()
    end
    local bx = SLStateDB.pixel_x or 10
    local by = SLStateDB.pixel_y or 10
    local anchor = pixelBlocks[1]
    PlacePixelBlock(anchor, bx, by)
    anchor.tex:SetVertexColor(0, 0, 1)
    anchor:Show()
    local verify = pixelBlocks[2]
    PlacePixelBlock(verify, bx + PIXEL_STEP, by)
    verify.tex:SetVertexColor(0, 1, 1)
    verify:Show()
    for i = 1, MAX_STATES do
        local b = pixelBlocks[2 + i]
        PlacePixelBlock(b, bx + PIXEL_STEP * (1 + i), by)
        if states[i] then
            b.tex:SetVertexColor(0, 1, 0)
        else
            b.tex:SetVertexColor(1, 0, 0)
        end
        b:Show()
    end
end

--- 隐藏所有像素块（非像素方式 / 总开关关闭时）
local function HidePixels()
    for i = 1, #pixelBlocks do
        pixelBlocks[i]:Hide()
    end
end

--- 刷新状态：按总开关与暴露方式分支；仅状态变化时写新帧
local function Refresh(force)
    if not SLStateDB.enabled then
        HidePixels()
        UpdateStatus()
        return
    end
    local states = DetectAllStates()
    local changed = force or StatesChanged(lastStates, states)
    lastStates = states
    if SLStateDB.method == "pixel" then
        DrawPixels(states)
        UpdateStatus()
    else
        HidePixels()
        if changed then
            Pulse(states)
        else
            UpdateStatus()
        end
    end
end

--- 创建一个带文字的勾选框
local function MakeCheck(parent, name, text, onClick)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetWidth(24)
    cb:SetHeight(24)
    local label = _G[name .. "Text"]
    if label then
        label:SetText(text)
    end
    cb:SetScript("OnClick", function(self)
        onClick(self, self:GetChecked() and true or false)
    end)
    return cb
end

--- 在一张面板里创建完整的设置控件（浮动面板与原生选项页共用）
local function BuildControls(parent, prefix, topAnchor, topX, topY)
    -- 总开关
    local enable = MakeCheck(parent, prefix .. "Enable", "启用状态暴露（总开关）", function(self)
        SLStateDB.enabled = self:GetChecked() and true or false
        SyncUIControls()
        Refresh(true)
    end)
    enable:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", topX, topY)
    enableChecks[#enableChecks + 1] = enable

    -- 暴露方式（二选一，勾选一个会自动取消另一个）
    local methodLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    methodLabel:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 4, -6)
    methodLabel:SetText("暴露方式（二选一）")

    local luaCb = MakeCheck(parent, prefix .. "MethodLua", "Lua 内存共享", function(self)
        if self:GetChecked() then
            SLStateDB.method = "lua"
        end
        SyncUIControls()
        Refresh(true)
    end)
    luaCb:SetPoint("TOPLEFT", methodLabel, "BOTTOMLEFT", -4, -2)
    methodChecks.lua[#methodChecks.lua + 1] = luaCb

    local pixelCb = MakeCheck(parent, prefix .. "MethodPixel", "像素点（截图解码）", function(self)
        if self:GetChecked() then
            SLStateDB.method = "pixel"
        end
        SyncUIControls()
        Refresh(true)
    end)
    pixelCb:SetPoint("TOPLEFT", luaCb, "TOPLEFT", 140, 0)
    methodChecks.pixel[#methodChecks.pixel + 1] = pixelCb

    -- 状态列表（两列排布）
    local stateLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stateLabel:SetPoint("TOPLEFT", luaCb, "BOTTOMLEFT", 4, -8)
    stateLabel:SetText("暴露的状态（最多 10 个）")

    for i = 1, MAX_STATES do
        local def = STATE_DEFS[i]
        local cb = MakeCheck(parent, prefix .. "State" .. i, def.name, function(self)
            SLStateDB.exposed_states[def.id] = self:GetChecked() and true or false
            Refresh(true)
        end)
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", stateLabel, "BOTTOMLEFT", col * 140 - 4, -2 - row * 24)
        stateChecks[#stateChecks + 1] = { cb = cb, id = def.id }
    end

    -- 调试日志
    local debugCb = MakeCheck(parent, prefix .. "Debug", "启用调试日志（输出到聊天框）", function(self)
        SetDebug(self:GetChecked() and true or false)
    end)
    debugCb:SetPoint("TOPLEFT", stateLabel, "BOTTOMLEFT", 0, -128)
    debugChecks[#debugChecks + 1] = debugCb

    -- 状态文字
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", debugCb, "BOTTOMLEFT", 4, -8)
    text:SetJustifyH("LEFT")
    text:SetWidth(260)
    statusTexts[#statusTexts + 1] = text

    SyncUIControls()
    UpdateStatus()
    return debugCb
end

--- 懒创建设置面板（1.12 的 API：SetBackdrop / UICheckButtonTemplate 都可用）
local function CreatePanel()
    if panel then
        return panel
    end
    panel = CreateFrame("Frame", "SLStatePanel", UIParent)
    panel:SetWidth(300)
    panel:SetHeight(400)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", panel, "TOP", 0, -14)
    title:SetText("SteamLike State（SLState）")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)

    -- 控件链的起点（内容从标题下方开始向下排布）
    local anchor = CreateFrame("Frame", nil, panel)
    anchor:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -36)
    anchor:SetWidth(1)
    anchor:SetHeight(1)

    BuildControls(panel, "SLState", anchor, 16, 0)
    return panel
end

--- 原生插件管理页里的选项面板（3.3.5 的「界面 → 插件」页可点开）
local function CreateOptionsPanel()
    if optionsPanel then
        return optionsPanel
    end
    local p = CreateFrame("Frame", "SLStateOptionsPanel", InterfaceOptionsFramePanelContainer or UIParent)
    p.name = "SLState"
    p:Hide()

    local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -16)
    title:SetText("SLState（SteamLike 角色状态）")

    local desc = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    -- 右侧锚点让宽度跟随设置面板，文字自动换行，不会跑出窗口
    desc:SetPoint("RIGHT", p, "RIGHT", -20, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText("把角色状态暴露给 SteamLike 客户端，用作按键映射的生效条件。\n"
        .. "可选 Lua 内存共享或屏幕像素点两种方式（二选一），"
        .. "需要在客户端里打开「启用角色状态读取」并选择对应的读取方式。")

    local anchor = CreateFrame("Frame", nil, p)
    anchor:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    anchor:SetWidth(1)
    anchor:SetHeight(1)

    BuildControls(p, "SLStateOpt", anchor, 0, 0)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(p)
    end
    -- 让面板铺满右侧设置区域，内容按左上角排布
    if InterfaceOptionsFramePanelContainer then
        p:SetAllPoints(InterfaceOptionsFramePanelContainer)
    end
    return p
end

SLASH_SLSTATE1 = "/slstate"
SlashCmdList["SLSTATE"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "debug" then
        SetDebug(not SLStateDB.debug)
        return
    end
    local p = CreatePanel()
    if p:IsShown() then
        p:Hide()
    else
        p:Show()
        UpdateStatus()
    end
end

-- 注册到原生插件管理页（3.3.5 的「界面 → 插件」列表里出现 SLState 选项）
CreateOptionsPanel()

-- ---------------------------------------------------------------------
-- 事件驱动
-- 绝大多数状态都有对应的客户端事件；事件到来时只打脏标记，由 50ms 合并窗口
-- 统一刷新一次，避免 UNIT_AURA 这类高频事件反复重绘。
-- 只有「下落中 / 游泳中」是瞬时查询、没有事件可用，且仅在用户勾选它们时才轮询。
-- ---------------------------------------------------------------------
local function MarkDirty()
    dirty = true
end

-- 需要轮询的瞬时状态（客户端没有对应事件）
local NEEDS_POLL = { isFalling = true, isSwimming = true }

local function NeedsPolling()
    for id in pairs(NEEDS_POLL) do
        if SLStateDB.exposed_states[id] then
            return true
        end
    end
    return false
end

-- 聊天输入框没有原生事件：挂到编辑框的显示/隐藏脚本与开关函数上
-- 不同版本的聊天函数名不一致（ChatEdit_ActivateEdit / ChatEdit_ActivateChat 等），
-- 也可能被聊天类插件替换，因此逐个判断存在性，缺哪个就跳过哪个
local CHAT_HOOKS = {
    "ChatFrame_OpenChat",
    "ChatEdit_ActivateChat",
    "ChatEdit_DeactivateChat",
    "ChatEdit_ActivateEdit",
    "ChatEdit_DeactivateEdit",
}

local function SafeHook(name)
    if hooksecurefunc and type(_G[name]) == "function" then
        hooksecurefunc(name, MarkDirty)
    end
end

local function HookChatEditBox()
    if chatEditHooked then
        return
    end
    local eb = ChatFrame1EditBox or (ChatFrame1 and ChatFrame1.editBox)
    if eb and eb.HookScript then
        eb:HookScript("OnShow", MarkDirty)
        eb:HookScript("OnHide", MarkDirty)
        chatEditHooked = true
    end
end

local function HookChatEvents()
    HookChatEditBox()
    for _, name in ipairs(CHAT_HOOKS) do
        SafeHook(name)
    end
end

local EVENTS = {
    "PLAYER_ENTERING_WORLD", -- 进世界/重载界面：全量刷新一次
    "PLAYER_REGEN_DISABLED", -- 进入战斗（战斗中）
    "PLAYER_REGEN_ENABLED",  -- 脱离战斗
    "PLAYER_TARGET_CHANGED", -- 目标变化（有目标）
    "PLAYER_DEAD",           -- 死亡
    "PLAYER_ALIVE",          -- 复活
    "PLAYER_UNGHOST",        -- 不再是灵魂状态
    "UNIT_PET",              -- 宠物变化（有宠物）
    "UNIT_AURA",             -- 光环变化（潜行 / 骑乘）
}

local SL_FRAME = CreateFrame("Frame")
for _, ev in ipairs(EVENTS) do
    SL_FRAME:RegisterEvent(ev)
end
SL_FRAME:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_ENTERING_WORLD" then
        HookChatEditBox() -- 加载时聊天框可能还没建好，这里补挂一次
        Debug("PLAYER_ENTERING_WORLD 触发，立即刷新")
        Refresh(true)
        return
    end
    if event == "UNIT_AURA" and unit and unit ~= "player" then
        return -- 只关心玩家自身的光环
    end
    MarkDirty()
end)

SL_FRAME:SetScript("OnUpdate", function(_, elapsed)
    -- 事件合并：50ms 内的多次事件只刷新一次
    if dirty then
        dirtyAcc = dirtyAcc + elapsed
        if dirtyAcc >= 0.05 then
            dirty = false
            dirtyAcc = 0
            Refresh()
        end
    end
    -- 仅当勾选了无事件的瞬时状态（下落/游泳）时才轮询，否则完全零轮询
    if SLStateDB.enabled and NeedsPolling() then
        acc = acc + elapsed
        if acc >= 0.1 then
            acc = 0
            Refresh()
        end
    end
end)

HookChatEvents()

Debug(string.format("插件已加载，anchor = %.2f / %.2f / %.2f", BUF[1], BUF[2], BUF[3]))
