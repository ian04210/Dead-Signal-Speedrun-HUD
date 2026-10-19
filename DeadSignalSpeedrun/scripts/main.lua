-- Dead Signal Speedrun HUD v1.0 (UE4SS 3.0.1 / Dead Signal 2.0.0)
-- Live RTA plus checkpoint-only IGT display (internal elapsed gameplay accumulator).
-- Menu paths are confirmed by the user's F8 widget dump (2026-10-18).
-- No FindAllOf, object dumps, or unbounded searches in any background loop.
-- UI objects are constructed only on the game thread.

local PREFIX = "[DSSpeedrun10] "
-- Same wording, hand-wrapped for the game's own ScaleBox to avoid tiny text.
local MODE_DESCRIPTION = "How fast can you\ncomplete the casual\ngamemode?\nMade by ian04"
local HUD_FONT_SIZE = 19         -- previous working release: 26
local HUD_TOP_BLANK_LINES = 3   -- keep clocks clear of top-right PC information

local function say(s) print(PREFIX .. tostring(s) .. "\n") end
local function attempt(fn)
    local ok, value = pcall(fn)
    if ok then return value, nil end
    return nil, tostring(value)
end
local function isValid(o)
    if o == nil then return false end
    return attempt(function() return o:IsValid() end) == true
end
local function getName(o)
    -- IMPORTANT: This game/UE4SS build DOES NOT expose UObject:GetName().
    -- v0.4's use of GetName() was the confirmed cause of its failed menu lookup.
    return attempt(function() return o:GetFName():ToString() end)
        or attempt(function() return o:GetFullName() end)
        or "?"
end
local function getRoot(w)
    if not isValid(w) then return nil end
    local root = attempt(function() return w:GetRootWidget() end)
    if not isValid(root) then root = attempt(function() return w.WidgetTree.RootWidget end) end
    if isValid(root) then return root end
    return nil
end
local function searchWidget(owner, want)
    if not isValid(owner) then return nil end
    local field = attempt(function() return owner[want] end)
    if isValid(field) then return field end
    local root = getRoot(owner)
    if not isValid(root) then return nil end
    -- Small, known widget tree: 26 nodes in the user's capture.
    local seen, count = {}, 0
    local function walk(w, depth)
        if not isValid(w) or depth > 14 or count >= 150 then return nil end
        count = count + 1
        local id = attempt(function() return w:GetAddress() end)
        if id and seen[id] then return nil end
        if id then seen[id] = true end
        if getName(w) == want then return w end
        local n = attempt(function() return w:GetChildrenCount() end)
        if type(n) ~= "number" then n = 0 end
        for i=0, math.min(n-1,39) do
            local child = attempt(function() return w:GetChildAt(i) end)
            local found = walk(child, depth+1)
            if isValid(found) then return found end
        end
        -- User widgets (such as Diff_Casual) contain SEPARATE WidgetTrees.
        if depth > 0 then
            local nested = getRoot(w)
            if isValid(nested) then
                local found = walk(nested,depth+1)
                if isValid(found) then return found end
            end
        end
        return nil
    end
    return walk(root,0)
end
local function cls(path)
    local c = attempt(function() return StaticFindObject(path) end)
    if isValid(c) then return c end
    say("ERROR missing class: " .. path)
    return nil
end
local function newObj(c, outer, name)
    if not isValid(c) or not isValid(outer) then return nil end
    local o, err = attempt(function() return StaticConstructObject(c,outer,FName(name)) end)
    if not isValid(o) then say("ERROR constructing " .. name .. ": " .. tostring(err)) end
    return o
end
local function setText(widget, value)
    local _, err = attempt(function() widget:SetText(FText(value)) end)
    if err then say("ERROR SetText: " .. err); return false end
    return true
end

-- Copy the actual game's UMG font settings instead of supplying Roboto.
-- Native Get/SetFont preserves the family/typeface/weight, not just point size.
local function copyFontAndColor(dst, source, newSize)
    if not (isValid(dst) and isValid(source)) then return false end
    local font = attempt(function() return source.Font end)
    local copied = false
    if font then
        local _, err = attempt(function() dst:SetFont(font) end)
        if not err then copied=true end
        if not copied then
            local _, err2=attempt(function() dst.Font=font end)
            if not err2 then copied=true end
        end
        if not copied then
            -- UE4SS 3.0.1's struct assignment is release-specific; set each
            -- supported member individually as the fallback.
            local fObj=attempt(function() return font.FontObject end)
            local family=attempt(function() return font.TypefaceFontName end)
            local size=attempt(function() return font.Size end)
            if isValid(fObj) then
                local _,e=attempt(function() dst.Font.FontObject=fObj end)
                if not e then copied=true end
            end
            if family then attempt(function() dst.Font.TypefaceFontName=family end) end
            if type(size)=="number" then
                local _,e=attempt(function() dst.Font.Size=size end)
                if not e then copied=true end
            end
        end
    end
    if newSize then attempt(function() dst.Font.Size=newSize end) end
    -- Match the label tint to existing UI when supported.
    local tint=attempt(function() return source.ColorAndOpacity end)
    if tint then attempt(function() dst:SetColorAndOpacity(tint) end) end
    return copied
end


-- Font snapshots are captured while the title-screen labels still exist.
-- WidgetTree objects are often destroyed during map travel; keeping the old
-- TextBlock alone does NOT keep its style valid. Copy scalar font values and
-- a strong reference to the UFont asset instead.
local gameFont = {fontObject=nil, typeface=nil, material=nil, size=nil,
                  letterSpacing=nil, captured=false}
local function rememberFont(source)
    if not isValid(source) then return false end
    local f=attempt(function() return source.Font end)
    if not f then return false end
    local fontObj=attempt(function() return f.FontObject end)
    -- Do not mark an invalid font as a refreshed snapshot; preserve the last
    -- good font and allow the next populated title to update it.
    if not isValid(fontObj) then
        say("FONT SNAPSHOT: native source FontObject unavailable; keeping prior reference")
        return false
    end
    gameFont.fontObject=fontObj
    local typ=attempt(function() return f.TypefaceFontName end)
    if typ then gameFont.typeface=typ end
    local mat=attempt(function() return f.FontMaterial end)
    gameFont.material=isValid(mat) and mat or nil
    local size=attempt(function() return f.Size end)
    if type(size)=="number" then gameFont.size=size end
    local spacing=attempt(function() return f.LetterSpacing end)
    if type(spacing)=="number" then gameFont.letterSpacing=spacing end
    gameFont.captured=true
    say("FONT SNAPSHOT: fontObject="..tostring(isValid(gameFont.fontObject))..", size="..tostring(gameFont.size))
    return true
end
local function restoreFont(label, desiredSize)
    if not isValid(label) then return false end
    local success=false
    -- Never reuse a FontInfo struct proxy after map travel: it can reference
    -- freed UMG memory. Use only captured asset references and scalar values.
    if isValid(gameFont.fontObject) then
        local _,e=attempt(function() label.Font.FontObject=gameFont.fontObject end)
        success=success or e==nil
    end
    if gameFont.typeface then
        attempt(function() label.Font.TypefaceFontName=gameFont.typeface end)
    end
    if isValid(gameFont.material) then
        attempt(function() label.Font.FontMaterial=gameFont.material end)
    end
    if gameFont.letterSpacing then
        attempt(function() label.Font.LetterSpacing=gameFont.letterSpacing end)
    end
    attempt(function() label.Font.Size=desiredSize or gameFont.size or 26 end)
    return success
end
-- Native WBP_DiffCard is the preferred button. It provides the game’s own
-- hover animation, hand cursor, brushes, and label styling. Do not paint over
-- the title or add any custom outline/shadow, even in the fallback.

local menu = {title=nil, row=nil, button=nil, label=nil, holder=nil,
              casual=nil, casualButton=nil, casualLabel=nil, titleLabel=nil, inserted=false, pressed=false,
              attempts=0, errors=0, strategy="none", gameCard=nil, nativeMouse=nil}
local timer = {mode="off", armed=false, startWall=nil, stopWall=nil,
               startCPU=nil, stopCPU=nil, enginePending=false,
               clockWorld=nil, startWorld=nil, stopWorld=nil,
               reason="", startReason="", sinceClick=nil, fallbacks=0}
-- IGT accumulates silently every tick from the same high-resolution clock as
-- RTA, excluding positively detected pause/loading intervals and frame hitches.
-- Its HUD *snapshot* is updated ONLY when a pause or load begins or at finish.
-- This remains an estimate, not a verified official leaderboard IGT.
local igt = {seconds=0, displayed=0, sourceSeen=true, world=nil,
             worldId=nil, status="waiting", skipped=0, lastProbe=nil,
             lastWall=nil, paused=false, loading=false, lastReason=nil,
             published=0, drawnPublished=0, pauseWidgets={}, pendingPause={}, statics=nil, staticsChecked=false}
local hud = {ui=nil, text=nil, tries=0, last=""}
local controller = nil
local function locateWorld(context)
    local w = attempt(function() return context:GetWorld() end)
    if isValid(w) then return w,"context" end
    local pawn=attempt(function() return FindFirstOf("DeskPawn") end)
    if isValid(pawn) then w=attempt(function() return pawn:GetWorld() end) end
    if isValid(w) then return w,"DeskPawn" end
    if not isValid(controller) then controller = attempt(function() return FindFirstOf("PlayerController") end) end
    if isValid(controller) then w = attempt(function() return controller:GetWorld() end) end
    if isValid(w) then return w,"PlayerController" end
    local gi=attempt(function() return FindFirstOf("GameInstance") end)
    if isValid(gi) then w=attempt(function() return gi:GetWorld() end) end
    if isValid(w) then return w,"GameInstance" end
    -- Once at run start, use an active UWorld as last-resort source.
    w=attempt(function() return FindFirstOf("World") end)
    if isValid(w) then return w,"UWorld" end
    return nil,"no-world"
end
-- RTA: MSVC's os.clock() returns fractional WALL time since CRT startup.
-- It deliberately does NOT stop during pause, loading or gameplay lag.
-- Microsoft documents this Windows-specific behavior explicitly.
local function elapsed()
    if not timer.startCPU then return 0 end
    local now = timer.stopCPU or os.clock()
    if type(now)=="number" and now==now and now>=timer.startCPU and now<1e12 then
        return now-timer.startCPU
    end
    return math.max(0,(timer.stopWall or os.time())-(timer.startWall or os.time()))
end

local function worldIdentity(w)
    local addr=attempt(function() return w:GetAddress() end)
    if addr~=nil then return tostring(addr) end
    return tostring(w)
end
-- Runtime pause detection, WITHOUT scanning every Unreal object.
-- First ask Unreal whether the world is paused. Some games use a menu-only
-- pause instead; for those we also watch newly constructed pause-menu widgets.
local function isVisibleInViewport(widget)
    if not isValid(widget) then return false end
    local visible = attempt(function() return widget:IsInViewport() end)
    if visible~=true then return false end
    local state = attempt(function() return widget:GetVisibility() end)
    if type(state)=="number" and (state==1 or state==2) then return false end
    if state~=nil then
        local value=tostring(state):lower()
        if value:find("hidden",1,true) or value:find("collapsed",1,true) then return false end
    end
    -- A pause UserWidget can remain on the viewport while its Blueprint
    -- root is hidden. Check that too before claiming the menu is on screen.
    local root=getRoot(widget)
    if isValid(root) then
        local rootVisibility=attempt(function() return root:GetVisibility() end)
        if type(rootVisibility)=="number" and (rootVisibility==1 or rootVisibility==2) then return false end
        if rootVisibility~=nil then
            local v=tostring(rootVisibility):lower()
            if v:find("hidden",1,true) or v:find("collapsed",1,true) then return false end
        end
        local opacity=attempt(function() return root:GetRenderOpacity() end)
        if type(opacity)=="number" and opacity<=0.001 then return false end
    end
    return true
end
local function looksLikePauseMenu(widget)
    if not isValid(widget) then return false end
    local klass=attempt(function() return widget:GetClass() end)
    local name=(getName(klass).." "..getName(widget)):lower()
    -- The old substring check also accepted Setting_PauseMusicVolume and
    -- other settings components; those remain mounted and can make IGT think
    -- the game stays paused long after the real pause screen is dismissed.
    if name:find("setting_",1,true) or name:find("volume",1,true)
       or name:find("slider",1,true) or name:find("button",1,true)
       or name:find("overlay",1,true) then return false end
    return name:find("wbp_pause_c",1,true)~=nil
        or name:find("wbp_pausemenu_c",1,true)~=nil
        or name:find("wbp_escapemenu_c",1,true)~=nil
end
local function pausedByUI()
    for i=#igt.pauseWidgets,1,-1 do
        local widget=igt.pauseWidgets[i]
        if not isValid(widget) then
            table.remove(igt.pauseWidgets,i)
        elseif isVisibleInViewport(widget) then
            return true
        end
    end
    return false
end
local function pausedByEngine(w)
    if not isValid(w) then return false end
    if not igt.staticsChecked then
        igt.staticsChecked=true
        local gs=attempt(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
        if isValid(gs) then igt.statics=gs end
    end
    if isValid(igt.statics) then
        local state=attempt(function() return igt.statics:IsGamePaused(w) end)
        if type(state)=="boolean" then return state end
    end
    local b=attempt(function() return w:IsPaused() end)
    if type(b)=="boolean" then return b end
    return false
end
-- Never retain stale UI candidates or pause states into a new run.
local function resetIGT()
    igt.seconds=0;igt.displayed=0;igt.sourceSeen=true;igt.world=nil
    igt.worldId=nil;igt.status="waiting";igt.skipped=0;igt.lastProbe=nil
    igt.lastWall=nil;igt.paused=false;igt.loading=false;igt.lastReason=nil
    igt.published=0;igt.drawnPublished=0;igt.pauseWidgets={};igt.pendingPause={}
end
local function checkpointIGT(reason)
    -- The visual IGT is a held checkpoint, NOT another moving clock.
    local n=igt.seconds
    if type(n)~="number" or n~=n or n<0 or n==math.huge then n=0 end
    igt.displayed=n
    igt.published=igt.published+1
    igt.lastReason=reason
    -- Force a fresh HUD paint even if the game has paused its normal UI tick;
    -- the active frame that detects the checkpoint performs the repaint.
    hud.last=""
    say("IGT CHECKPOINT #"..tostring(igt.published).." ("..tostring(reason).."): "..string.format("%.3f", n).." sec")
end
-- IMPORTANT: NotifyOnNewObject fires as the Unreal object is being created.
-- Never read widget:GetClass(), GetFName(), UI state, etc. in that callback.
-- The previous version did, and is the leading suspected cause of an intro
-- transition crash that occurred immediately after launching Casual.
-- Process ONLY mature candidates, on the normal game thread, while timing.
local function processPauseCandidates(now)
    if timer.mode~="running" then return end
    for i=#igt.pendingPause,1,-1 do
        local item=igt.pendingPause[i]
        if now>=item.readyAt then
            table.remove(igt.pendingPause,i)
            local candidate=item.widget
            if isValid(candidate) and looksLikePauseMenu(candidate) and #igt.pauseWidgets<24 then
                igt.pauseWidgets[#igt.pauseWidgets+1]=candidate
                say("IGT PAUSE MENU CACHED (deferred): "..getName(candidate))
            end
        end
    end
end
-- One cheap engine/UI poll every HUD tick. Any global lookup is limited to
-- 1 per second when the world is unavailable; no FindAllOf in this loop.
local function sampleIGT(ctx)
    if timer.mode~="running" then return end
    local now=os.clock()
    if type(now)~="number" or now~=now or now<0 then return end
    if igt.lastWall==nil then igt.lastWall=now end
    local delta=now-igt.lastWall
    igt.lastWall=now
    if delta<0 or delta~=delta then delta=0 end

    local w=isValid(ctx) and attempt(function() return ctx:GetWorld() end) or nil
    if not isValid(w) and isValid(igt.world) then w=igt.world end
    if not isValid(w) and (not igt.lastProbe or now-igt.lastProbe>=1.0) then
        igt.lastProbe=now
        w=locateWorld(ctx)
    end
    local loading=false
    if isValid(w) then
        local id=worldIdentity(w)
        if igt.worldId and igt.worldId~=id then
            loading=true -- a new map/world was attached
        end
        igt.world=w;igt.worldId=id
        local streams=attempt(function() return w.NumStreamingLevelsBeingLoaded end)
        local streaming=(type(streams)=="number" and streams>0)
        local blocking=attempt(function() return w.IsInBlockTillLevelStreamingCompleted end)
        if type(blocking)~="boolean" then
            blocking=attempt(function() return w.bIsInBlockTillLevelStreamingCompleted end)
        end
        local teardown=attempt(function() return w.bIsTearingDown end)
        loading=loading or streaming or blocking==true or teardown==true
    else
        -- Do NOT force all IGT to zero when Unreal's world cannot be read.
        -- Game-clock access failed in v1.0 on the user's actual run.
        -- During known map loss, consider it loading. Initial absence during
        -- the Begin Shift intro is not proof that gameplay has paused.
        if igt.worldId then loading=true end
        igt.world=nil;igt.worldId=nil
    end
    processPauseCandidates(now)
    local paused=pausedByEngine(w) or pausedByUI()

    -- Count only playable intervals. Skip >=500ms callback stalls; these are
    -- likely heavy loads, hitches, or UE4SS thread scheduling delays.
    if not igt.paused and not igt.loading and not paused and not loading then
        if delta<=0.5 then
            igt.seconds=igt.seconds+delta
        else
            igt.skipped=igt.skipped+1
            if igt.skipped<=3 then say("IGT: ignored "..string.format("%.3f",delta).."s frame stall") end
        end
    end
    if type(igt.seconds)~="number" or igt.seconds~=igt.seconds or igt.seconds<0 then igt.seconds=0 end

    -- Update the on-screen IGT only on a transition INTO a pause or load.
    -- Hold the same snapshot when resuming gameplay; RTA remains live.
    if paused and not igt.paused then checkpointIGT("pause")
    elseif loading and not igt.loading then checkpointIGT("loading") end
    igt.paused=paused;igt.loading=loading
    if paused then igt.status="paused"
    elseif loading then igt.status="loading"
    else igt.status="running" end
end

local function formatTime(t)
    if type(t)~="number" or t~=t or t==math.huge or t==-math.huge then t=0 end
    t=math.max(0,math.min(t,9999999))
    local hours = math.floor(t/3600)
    local mins = math.floor((t%3600)/60)
    local secs = math.floor(t%60)
    local millis = math.min(999,math.floor((t%1)*1000+0.00001))
    return string.format("%02d:%02d:%02d.%03d",hours,mins,secs,millis)
end
local function content()
    if timer.mode=="off" then return "" end
    local rta=timer.mode=="waiting" and 0 or elapsed()
    -- Numeric only. The old --:--:--.--- placeholder rendered as garbage with
    -- Dead Signal's game font after the tutorial choice.
    local game=formatTime(igt.displayed)
    local header=timer.mode=="done" and " [END]" or ""
    return string.rep("\n", HUD_TOP_BLANK_LINES).."RTA: "..formatTime(rta).."\nIGT: "..game..header
end
-- Based on a previously tested Dead Signal UMG overlay implementation:
-- a TextBlock as the DIRECT WidgetTree root fills the screen, so setting its
-- text justification to Right places the clock at the upper-right without
-- unreliable CanvasPanelSlot struct marshalling in UE4SS 3.0.1.
local function getFont()
    for _,path in ipairs({"/Engine/EngineFonts/Roboto.Roboto", "/Engine/EngineFonts/Roboto"}) do
        local f=attempt(function() return StaticFindObject(path) end)
        if isValid(f) then return f end
    end
    local f=attempt(function() return FindFirstOf("Font") end)
    if isValid(f) then return f end
    return nil
end
local function makeHUD()
    if isValid(hud.ui) and isValid(hud.text) then return true end
    if hud.tries>=3 then return false end
    hud.tries=hud.tries+1
    local outer=attempt(function() return FindFirstOf("GameInstance") end)
    if not isValid(outer) then say("HUD: no GameInstance yet"); return false end
    local userClass=cls("/Script/UMG.UserWidget")
    local treeClass=cls("/Script/UMG.WidgetTree")
    local textClass=cls("/Script/UMG.TextBlock")
    if not (userClass and treeClass and textClass) then return false end
    local ui=newObj(userClass,outer,"DSR10HUD")
    if not isValid(ui) then return false end
    local tree=newObj(treeClass,ui,"DSR10WidgetTree")
    if not isValid(tree) then return false end
    local _, e=attempt(function() ui.WidgetTree=tree end)
    if e then say("HUD can't attach WidgetTree: "..e);return false end
    local label=newObj(textClass,tree,"DSR10HUDText")
    if not isValid(label) then return false end
    local _,treeErr=attempt(function() tree.RootWidget=label end)
    if treeErr then say("HUD can't set text root: "..treeErr);return false end
    if not setText(label,string.rep("\n", HUD_TOP_BLANK_LINES).."RTA: 00:00:00.000\nIGT: 00:00:00.000") then return false end
    attempt(function() label:SetJustification(2) end) -- Text right-justified over viewport
    attempt(function() label:SetVisibility(3) end) -- hit-test invisible
    local matching = isValid(menu.titleLabel) and menu.titleLabel or menu.casualLabel
    local exactFont=false
    if gameFont.captured then exactFont=restoreFont(label,HUD_FONT_SIZE) end
    if not exactFont then exactFont=copyFontAndColor(label,matching,HUD_FONT_SIZE) end
    if not exactFont then
        local font=getFont()
        if font then attempt(function() label.Font.FontObject=font end) end
        attempt(function() label.Font.Size=HUD_FONT_SIZE end)
        say("HUD FONT: game style unavailable; falling back to loaded UFont")
    else
        say("HUD FONT: restored cached native menu typography (survives map travel)")
    end
    -- Readability-only styling: a 1px BLACK font outline over white/pale
    -- in-game settings controls. This affects both lines in our single
    -- HUD TextBlock. Apply before AddToViewport so UMG's first Slate sync
    -- sees the outline even if SetFont is not exposed by this UE4SS build.
    -- NEVER change content(), updateHUD(), or RTA/IGT timer state here.
    local _,outlineErr=attempt(function()
        label.Font.OutlineSettings.OutlineSize=1
    end)
    if not outlineErr then
        -- Unreal usually defaults the outline to black. Explicitly request
        -- opaque black when the FLinearColor struct is writable in UE4SS.
        attempt(function()
            local ink=label.Font.OutlineSettings.OutlineColor
            ink.R=0.0
            ink.G=0.0
            ink.B=0.0
            ink.A=1.0
        end)
        say("HUD OUTLINE: applied 1px black text outline")
    else
        -- Cosmetic failure must never prevent a run from starting.
        say("HUD OUTLINE: unavailable, timers unaffected ("..tostring(outlineErr)..")")
    end
    attempt(function() label:SetRenderOpacity(1.0) end)
    local _,err=attempt(function() ui:AddToViewport(10000) end)
    if err then say("HUD AddToViewport ERROR: "..err);return false end
    attempt(function() ui:SetVisibility(4) end) -- self-hit-test invisible
    attempt(function() ui:SetRenderOpacity(1.0) end)
    hud.ui=ui;hud.text=label;hud.last=""
    say("HUD READY: RTA over IGT, compact font, lower top-right; copied game font=" .. tostring(exactFont))
    return true
end
local function updateHUD()
    if timer.mode=="off" then return end
    if not (isValid(hud.ui) and isValid(hud.text)) then
        if not makeHUD() then return end
    end
    if isValid(hud.ui) then
        local inViewport=attempt(function() return hud.ui:IsInViewport() end)
        if inViewport==false then
            -- Level transitions sometimes clear widgets from the viewport.
            local _,err=attempt(function() hud.ui:AddToViewport(10000) end)
            if err then say("HUD reattach error: "..err) end
        end
    end
    local s=content()
    if s~=hud.last then
        if setText(hud.text,s) then
            hud.last=s
            if igt.published>igt.drawnPublished then
                igt.drawnPublished=igt.published
                say("IGT HUD PAINTED CHECKPOINT #"..tostring(igt.drawnPublished)..": "..formatTime(igt.displayed))
            end
        end
    end
end
local resetShift
local function arm()
    timer.mode="waiting"; timer.armed=true
    timer.startWall=nil;timer.stopWall=nil;timer.startCPU=nil;timer.stopCPU=nil
    timer.enginePending=false;timer.clockWorld=nil
    timer.startWorld=nil;timer.stopWorld=nil;timer.sinceClick=os.time()
    timer.fallbacks=0;timer.startReason="";timer.reason=""
    resetIGT()
    resetShift()
    hud.tries=0
    say("SPEEDRUN SELECTED: RTA and IGT armed. Waiting for the Begin Shift button press")
    updateHUD()
end
local function start(source,context)
    say("Start signal: " .. tostring(source) .. " (armed=" .. tostring(timer.armed) .. ")")
    if not timer.armed or timer.mode~="waiting" then return end
    timer.startWall=os.time();timer.startCPU=os.clock()
    timer.mode="running";timer.startReason=source
    resetIGT()
    igt.lastWall=timer.startCPU
    sampleIGT(context)
    say("BOTH TIMERS START: "..source.."; RTA = wall time, IGT internally accumulates, HUD updates at pauses/loads")
    updateHUD()
end
local function finish(source)
    say("GameEnd observed: " .. tostring(source) .. " (timer="..timer.mode..")")
    if timer.mode~="running" then return end
    sampleIGT(nil)
    checkpointIGT("finish")
    timer.stopWall=os.time();timer.stopCPU=os.clock();timer.mode="done";timer.reason=source
    say("BOTH TIMERS STOP: RTA="..formatTime(elapsed()).." IGT="..formatTime(igt.displayed).." via "..source)
    -- GameEnd is NOT verified as victory-only. Could fire on death/quit.
    updateHUD()
end
-- BEGIN SHIFT timing detection (speedrun category): begin when the user presses
-- the game's own Begin Shift control, not when DeskPawn spawns or GameStart
-- eventually fires at the tutorial choice. The exact intro widget class is
-- unknown in the logs, so detect it by its visible UMG text and UButton.
-- Constructed UserWidgets are cached via a single NotifyOnNewObject callback.
-- One optional *one-shot* fallback captures pre-existing widget instances;
-- there is never a repeated FindAllOf scan (which lagged badly in v0.2).
-- Widget construction notifications are not safe to inspect immediately.
-- Keep each candidate for a short, bounded interval and only inspect mature
-- widgets on the game thread. Every new run gets a new generation number, so
-- construction notifications from the previous run cannot be reused.
local shift = {widgets={}, button=nil, label=nil, source=nil, pressed=false,
               captured=false, lastSearch=0, scannedOnce=false, scans=0,
               current=nil, warned=false, generation=0}
resetShift = function()
    shift.generation=shift.generation+1
    shift.widgets={};shift.button=nil;shift.label=nil;shift.source=nil
    shift.pressed=false;shift.captured=false;shift.lastSearch=0
    shift.scannedOnce=false;shift.scans=0;shift.current=nil;shift.warned=false
end
local function isShiftText(s)
    if type(s)~="string" then return false end
    local normalized=s:upper():gsub("[%s%p_]", "")
    return normalized:find("BEGINSHIFT",1,true)~=nil
end
local function isButton(o)
    if not isValid(o) then return false end
    local pressed=attempt(function() return o:IsPressed() end)
    return type(pressed)=="boolean"
end
local function findIntroInWidget(owner)
    if not isValid(owner) then return nil end
    local root=getRoot(owner)
    if not isValid(root) then return nil end
    local count=0
    local labels,buttons={},{}
    local seen={}
    local function walk(node,depth)
        if not isValid(node) or depth>12 or count>=180 then return end
        local addr=attempt(function()return node:GetAddress() end)
        if addr and seen[tostring(addr)] then return end
        if addr then seen[tostring(addr)]=true end
        count=count+1
        if isButton(node) then buttons[#buttons+1]=node end
        local raw=attempt(function() return node:GetText():ToString() end)
        if isShiftText(raw) then labels[#labels+1]=node end
        local n=attempt(function()return node:GetChildrenCount() end)
        if type(n)=="number" then
            for i=0,math.min(n-1,49) do
                walk(attempt(function() return node:GetChildAt(i) end),depth+1)
            end
        end
        -- Nested userwidget roots are not normal panel children.
        if depth>0 then
            local nested=getRoot(node)
            if isValid(nested) and nested~=node then walk(nested,depth+1) end
        end
    end
    walk(root,0)
    if #labels==0 then return nil end
    for _,label in ipairs(labels) do
        local ancestor=label
        for _=1,10 do
            if isButton(ancestor) then return ancestor,label end
            ancestor=attempt(function() return ancestor:GetParent() end)
            if not isValid(ancestor) then break end
        end
    end
    -- Custom game WBP buttons often wrap the label and button separately.
    -- Prefer a button named Begin/Shift, or the sole button in the widget.
    for _,b in ipairs(buttons) do
        local n=getName(b):lower()
        if n:find("shift",1,true) or n:find("begin",1,true) then
            return b,labels[1]
        end
    end
    if #buttons==1 then return buttons[1],labels[1] end
    if #buttons>1 then
        -- For WBP_DS_Button, the main button is commonly BTN_Button or Button_0.
        for _,b in ipairs(buttons) do
            local n=getName(b):lower()
            if n:find("btn",1,true) then return b,labels[1] end
        end
    end
    return nil
end
local _,shiftNotifyErr=attempt(function()
    NotifyOnNewObject("/Script/UMG.UserWidget", function(obj)
        -- DATA ONLY: no GetName/GetClass/IsValid/UI calls from the constructor.
        -- Wait at least 1.6 sec before touching newly constructed UMG widgets;
        -- do not scan live objects while Dead Signal swaps maps on a reset.
        if timer.mode=="waiting" and #shift.widgets<100 then
            shift.widgets[#shift.widgets+1]={widget=obj,
                generation=shift.generation,
                readyAt=os.clock()+1.6, retries=0}
        end
        if timer.mode=="running" and #igt.pendingPause<64 then
            igt.pendingPause[#igt.pendingPause+1]={widget=obj,readyAt=os.clock()+1.0}
        end
    end)
end)
if shiftNotifyErr then say("BEGIN SHIFT: UserWidget construction notification unavailable: "..shiftNotifyErr) end
local function resolveShiftButton()
    if timer.mode~="waiting" or isValid(shift.button) then return end
    local now=os.clock()
    -- Only objects created during THIS attempt can be inspected; inspect no
    -- earlier than the safe window, and only on the game thread. Prefer the
    -- specific, already observed WBP_Loading_C containing Begin Shift.
    for i=#shift.widgets,1,-1 do
        local entry=shift.widgets[i]
        if entry.generation~=shift.generation then
            table.remove(shift.widgets,i)
        elseif now>=entry.readyAt then
            local widget=entry.widget
            local name=isValid(widget) and getName(widget) or ""
            local loader=type(name)=="string" and (
                name:find("WBP_Loading_C",1,true)~=nil or
                name:find("WBP_BeginShift_C",1,true)~=nil)
            if loader then
                local btn,label=findIntroInWidget(widget)
                if isValid(btn) then
                    shift.button=btn;shift.label=label;shift.source=name
                    shift.widgets={}
                    say("BEGIN SHIFT CONTROL FOUND (deferred): "..getName(btn).." within "..name)
                    return
                end
                -- The loading page can continue populating its nested tree
                -- after UserWidget construction. Allow three safe retries.
                entry.retries=entry.retries+1
                if entry.retries<4 then
                    entry.readyAt=now+0.75
                else
                    table.remove(shift.widgets,i)
                end
            else
                -- Never retain references to unrelated/old UserWidgets.
                table.remove(shift.widgets,i)
            end
        end
    end
    -- IMPORTANT: deliberately no FindAllOf("UserWidget") on intro loading or
    -- restarting. The former one-shot scan enumerated partially destroyed
    -- widgets, and can hard-crash UE4SS even inside a Lua pcall.
    if not shift.warned and type(timer.sinceClick)=="number"
       and os.time()-timer.sinceClick>=7 then
        shift.warned=true
        say("BEGIN SHIFT: still waiting for mature loading widget")
    end
end

local function pollShift()
    if timer.mode~="waiting" then return end
    if not isValid(shift.button) then resolveShiftButton() end
    if not isValid(shift.button) then return end
    local pressed=attempt(function() return shift.button:IsPressed() end)==true
    if pressed and not shift.pressed then
        start("Begin Shift button pressed (speedrun start)")
    end
    shift.pressed=pressed
end
-- UE4SS 3.0.1 does not implement multicast-delegate :Broadcast() in Lua.
-- Instead call the SAME Blueprint-generated function bound to the real
-- Casual DiffCard's BTN_DiffSelect OnClicked. This runs Casual's original
-- handler and retains its normal new-game/overwrite behavior.
local function selectCasualHandler()
    if not isValid(menu.casual) then return nil,nil end
    local clsObj=attempt(function() return menu.casual:GetClass() end)
    if not isValid(clsObj) then
        say("LAUNCH ERROR: no Casual card class for reflection")
        return nil,nil
    end
    local best, bestName, bestScore=nil,nil,0
    local samples={}
    local _, errorText=attempt(function()
        clsObj:ForEachFunction(function(func)
            local name=getName(func)
            local l=name:lower()
            if l:find("diff") or l:find("click") or l:find("bndevt") then
                if #samples<15 then samples[#samples+1]=name end
            end
            local s=0
            if l:find("btn_diffselect",1,true) and l:find("onbuttonclicked",1,true) then s=120
            elseif l:find("btn_diffselect",1,true) and l:find("bndevt",1,true) then s=110
            elseif l:find("btn_diffselect",1,true) and l:find("clicked",1,true) then s=100
            elseif l:find("bndevt",1,true) and l:find("diffselect",1,true) then s=90
            elseif l:find("bndevt",1,true) and l:find("onbuttonclicked",1,true) then s=70
            end
            if s>0 then
                local params=attempt(function() return func.NumParms end)
                if type(params)=="number" and params~=0 then s=0 end
            end
            if s>bestScore then best,bestName,bestScore=func,name,s end
        end)
    end)
    if errorText then say("LAUNCH ERROR: ForEachFunction unavailable: "..errorText) end
    if bestName then say("CASUAL HANDLER FOUND: "..bestName.." score="..bestScore)
    else say("CASUAL HANDLER NOT FOUND. Reflected candidates: "..table.concat(samples," | ")) end
    return best,bestName
end
local casualHandler=nil
local casualHandlerName=nil
local handlerResolved=false
local function clickCasual()
    if not isValid(menu.casual) then say("LAUNCH ERROR: Casual card invalid");return false end
    if not handlerResolved then
        casualHandler,casualHandlerName=selectCasualHandler()
        handlerResolved=true
    end
    if not isValid(casualHandler) then
        say("LAUNCH ERROR: no compatible Blueprint click handler (not using 3.0.1's unsupported delegate Broadcast)")
        return false
    end
    -- UE4SS's __index produces a bound, CALLABLE UFunction userdata,
    -- not a Lua function. v0.6's type(method)=="function" incorrectly
    -- skipped this path entirely, and UObject:CallFunction failed in-game.
    local bound=attempt(function() return menu.casual[casualHandlerName] end)
    if bound~=nil then
        local _,callError=attempt(function() return bound() end)
        if not callError then
            say("CASUAL LAUNCH: bound UFunction invoked: "..casualHandlerName)
            return true
        end
        say("CASUAL LAUNCH: bound UFunction failed: "..callError)
    end
    -- Non-bound UFunctions need explicit context as first argument.
    local _,directErr=attempt(function() return casualHandler(menu.casual) end)
    if not directErr then
        say("CASUAL LAUNCH: raw UFunction invoked with Casual context")
        return true
    end
    say("CASUAL LAUNCH: raw function failed: "..directErr)
    local _,err=attempt(function() menu.casual:CallFunction(casualHandler) end)
    if not err then
        say("CASUAL LAUNCH: UObject CallFunction fallback succeeded")
        return true
    end
    say("CASUAL LAUNCH: CallFunction fallback failed: "..err)
    return false
end
local function speedrunPressed()
    if timer.mode=="running" or timer.mode=="waiting" then return end
    arm()
    if not clickCasual() then
        -- Keep Speedrun armed. If the handler cannot be called, selecting the
        -- ORIGINAL Casual button manually will STILL start the timer.
        say("CASUAL LAUNCH FAILED. Speedrun remains armed; original Casual selection remains usable.")
    end
end
local function clearMenu(reason)
    if menu.inserted then say("MENU RESET: "..tostring(reason)) end
    menu.title=nil; menu.row=nil;menu.button=nil;menu.label=nil;menu.holder=nil
    menu.casual=nil;menu.casualButton=nil;menu.casualLabel=nil;menu.titleLabel=nil
    menu.gameCard=nil; menu.nativeMouse=nil;menu.inserted=false
    menu.artRefreshPending=false
    menu.strategy="none"; menu.pressed=false;menu.attempts=0
    casualHandler=nil; casualHandlerName=nil; handlerResolved=false
end

-- Load a loose PNG through Unreal's built-in KismetRenderingLibrary, not
-- unsafe direct texture memory access. If unavailable, keep the untouched
-- native card image and hover behavior (no user-side extra setup).
local stopwatchTexture=nil
local artDiagnostic=false
local function stopwatchPath()
    local candidates={}
    local src=nil
    if debug and debug.getinfo then
        src=attempt(function() return debug.getinfo(1,"S").source end)
    end
    -- During an Unreal call the function's own source may also be @main.lua.
    if type(src)=="string" and src:sub(1,1)=="@" then
        local script=src:sub(2)
        local moddir=script:match("^(.*)[/\\]scripts[/\\]main%.lua$")
        if moddir then candidates[#candidates+1]=moddir.."/assets/stopwatch_gold.png" end
    end
    candidates[#candidates+1]="Mods/DeadSignalSpeedrun/assets/stopwatch_gold.png"
    candidates[#candidates+1]="./Mods/DeadSignalSpeedrun/assets/stopwatch_gold.png"
    if io and io.open then
        for _,p in ipairs(candidates) do
            local f=attempt(function() return io.open(p,"rb") end)
            if f then attempt(function() f:close() end);return p end
        end
    end
    return nil
end
local function installStopwatchArt(card,title)
    local image=searchWidget(card,"I_Image")
    if not isValid(image) then say("STOPWATCH: no I_Image in new card");return false end
    if not isValid(stopwatchTexture) then
        local path=stopwatchPath()
        if path then
            local lib=attempt(function() return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end)
            if isValid(lib) then
                local tex,err=attempt(function() return lib:ImportFileAsTexture2D(title,path) end)
                if isValid(tex) then stopwatchTexture=tex
                elseif not artDiagnostic then say("STOPWATCH: PNG importer failed: "..tostring(err)) end
            end
        elseif not artDiagnostic then say("STOPWATCH: PNG not found in mod assets") end
    end
    if not isValid(stopwatchTexture) then artDiagnostic=true;return false end
    -- v1.0 UI update used false for bMatchSize. With a newly constructed
    -- WBP_DiffCard, its image brush can have a zero preferred size, making
    -- a successfully imported PNG INVISIBLE. Pass true to set brush size.
    local _,err=attempt(function() image:SetBrushFromTexture(stopwatchTexture,true) end)
    if err then say("STOPWATCH: brush assignment failed: "..err);return false end
    -- The cloned card's Blueprint default can be transparent or collapsed.
    -- These setters only affect the new Speedrun card, not the other modes.
    attempt(function() image:SetVisibility(0) end)
    attempt(function() image:SetRenderOpacity(1.0) end)
    attempt(function() image:SetOpacity(1.0) end)
    -- Preserve the real Casual icon footprint if accessible. Otherwise the
    -- existing ScaleBox will constrain the texture to the native card size.
    local original=searchWidget(menu.casual,"I_Image")
    if isValid(original) then
        local srcBrush=attempt(function() return original:GetBrush() end)
            or attempt(function() return original.Brush end)
        local srcSize=srcBrush and attempt(function() return srcBrush.ImageSize end)
        local w=srcSize and attempt(function() return srcSize.X end)
        local h=srcSize and attempt(function() return srcSize.Y end)
        if type(w)=="number" and type(h)=="number" and w>5 and h>5 then
            attempt(function() image:SetDesiredSizeOverride(srcSize) end)
            say("STOPWATCH: matched Casual icon footprint "..tostring(w).."x"..tostring(h))
        end
    end
    local brush=attempt(function() return image:GetBrush() end)
       or attempt(function() return image.Brush end)
    local size=brush and attempt(function() return brush.ImageSize end)
    local x=size and attempt(function() return size.X end)
    local y=size and attempt(function() return size.Y end)
    say("STOPWATCH: applied gold image with bMatchSize=true, brush="..tostring(x).."x"..tostring(y))
    return true
end

local function installCardDescription(card)
    local foot=searchWidget(card,"TB_FootNotes")
    if not isValid(foot) then
        say("CARD DESCRIPTION: native TB_FootNotes not found")
        return false
    end
    -- Match Casual's native font size/color, not Blueprint defaults.
    local source=searchWidget(menu.casual,"TB_FootNotes")
    if isValid(source) then
        local copied=copyFontAndColor(foot,source)
        say("CARD DESCRIPTION: copied Casual footnote typography="..tostring(copied))
    end
    -- The footnotes live inside a ScaleBox. Auto-wrapping this long sentence
    -- makes the ScaleBox shrink the text to a few pixels. Manual line breaks
    -- keep the exact wording but produce lines close to Casual's dimensions.
    attempt(function() foot:SetAutoWrapText(false) end)
    attempt(function() foot:SetJustification(1) end)
    return setText(foot,MODE_DESCRIPTION)
end

-- Use the game's OWN blueprint widget class. This gives us the exact same
-- SButton hover, custom cursor, image brushes, fonts and animations as Casual.
-- Standard UE UWidgetBlueprintLibrary.Create properly initializes WidgetTree.
local function createNativeCard(title, casual)
    local lib=attempt(function() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end)
    local klass=attempt(function() return casual:GetClass() end)
    if not (isValid(lib) and isValid(klass)) then
        say("CARD CLONE: native class/library unavailable")
        return nil,nil,nil
    end
    local player=attempt(function() return title:GetOwningPlayer() end)
    if not isValid(player) then
        player=attempt(function() return FindFirstOf("PlayerController") end)
    end
    local card=nil
    if isValid(player) then
        card=attempt(function() return lib:Create(title,klass,player) end)
    end
    if not isValid(card) then
        local instance=attempt(function() return FindFirstOf("GameInstance") end)
        if isValid(instance) then
            card=attempt(function() return lib:Create(instance,klass,player) end)
        end
    end
    if not isValid(card) then
        say("CARD CLONE: native Create failed, using safe styled Button fallback")
        return nil,nil,nil
    end
    local nativeBtn=searchWidget(card,"BTN_DiffSelect")
    local label=searchWidget(card,"TB_Title")
    if not (isValid(nativeBtn) and isValid(label)) then
        say("CARD CLONE: instantiated card lacks initialized BTN_DiffSelect/TB_Title")
        return nil,nil,nil
    end
    -- Blueprint defaults sometimes use a difficulty enum to set the image.
    -- Copy primitive settings from Casual to preserve its native background.
    local copied={}
    attempt(function()
        klass:ForEachProperty(function(prop)
            local n=getName(prop)
            local lower=n:lower()
            if (lower:find("difficulty",1,true) or lower:find("diffmode",1,true)
                or lower:find("diff_type",1,true))
                and not lower:find("widget",1,true) then
                local v=attempt(function() return casual[n] end)
                if type(v)=="number" or type(v)=="boolean" or type(v)=="string" then
                    local _,err=attempt(function() card[n]=v end)
                    if not err then copied[#copied+1]=n end
                end
            end
        end)
    end)
    if #copied>0 then say("CARD CLONE: copied native Casual settings "..table.concat(copied,",")) end
    -- Same native fonts, layout, hover and cursor as Casual; custom description
    -- is inserted into the game's own existing TB_FootNotes TextBlock.
    if not setText(label,"SPEEDRUN") then return nil,nil,nil end
    installCardDescription(card)
    -- Do not set the brush until after adding the card to the native row.
    -- Dead Signal can run Construct again on attachment and reset I_Image.
    say("CARD CLONE: created real WBP_DiffCard_C with native hover/cursor/style")
    return card,nativeBtn,label
end

local function addFallbackButton(title, row, casual, nativeButton, casualLabel)
    local tree=attempt(function() return title.WidgetTree end)
    if not isValid(tree) then return false end
    local sizeCls=cls("/Script/UMG.SizeBox")
    local buttonCls=cls("/Script/UMG.Button")
    local textCls=cls("/Script/UMG.TextBlock")
    if not (sizeCls and buttonCls and textCls) then return false end
    local holder=newObj(sizeCls,tree,"DSR10_SpeedrunSlot")
    local btn=newObj(buttonCls,tree,"DSR10_SpeedrunButton")
    local txt=newObj(textCls,tree,"DSR10_SpeedrunText")
    if not (isValid(holder) and isValid(btn) and isValid(txt)) then return false end
    setText(txt,"SPEEDRUN")
    copyFontAndColor(txt,casualLabel)
    -- Native style and cursor, without custom fills, dark outlines or shadows.
    local style=attempt(function() return nativeButton.WidgetStyle end)
    if style then attempt(function() btn:SetStyle(style) end) end
    local cursor=attempt(function() return nativeButton.Cursor end)
    if cursor~=nil then attempt(function() btn:SetCursor(cursor) end) end
    attempt(function() txt:SetJustification(1) end)
    attempt(function() txt:SetVisibility(3) end)
    attempt(function() btn:SetVisibility(0) end)
    attempt(function() holder:SetVisibility(0) end)
    local slot=attempt(function() return btn:AddChild(txt) end)
    if not isValid(slot) then return false end
    attempt(function() slot:SetHorizontalAlignment(2) end)
    attempt(function() slot:SetVerticalAlignment(2) end)
    local parent=attempt(function() return holder:AddChild(btn) end)
    if not isValid(parent) then return false end
    attempt(function() holder:SetWidthOverride(175) end)
    attempt(function() holder:SetHeightOverride(115) end)
    local rowSlot=attempt(function() return row:AddChildToHorizontalBox(holder) end)
    if not isValid(rowSlot) then rowSlot=attempt(function() return row:AddChild(holder) end) end
    if not isValid(rowSlot) then return false end
    attempt(function() rowSlot:SetVerticalAlignment(2) end)
    attempt(function() rowSlot:SetPadding({Left=14,Right=4,Top=0,Bottom=0}) end)
    menu.holder=holder;menu.button=btn;menu.label=txt;menu.strategy="styled-fallback"
    say("BUTTON: styled native Button fallback; hover animations may differ")
    return true
end
local function addButton(title,row,casual)
    local nativeButton=searchWidget(casual,"BTN_DiffSelect")
    if not isValid(nativeButton) then
        say("ERROR: Diff_Casual native button not found")
        return false
    end
    local casualLabel=searchWidget(casual,"TB_Title")
    menu.title=title;menu.row=row;menu.casual=casual
    menu.casualButton=nativeButton;menu.casualLabel=casualLabel
    menu.titleLabel=searchWidget(title,"TB_Text")
    -- A long run can unload the font asset captured at the very first title.
    -- Re-snapshot it from the *current* native title every time a new card is
    -- inserted. This avoids restoring a stale asset after death/restarts.
    rememberFont(isValid(menu.titleLabel) and menu.titleLabel or casualLabel)
    local card,btn,label=createNativeCard(title,casual)
    if isValid(card) then
        local slot=attempt(function() return row:AddChildToHorizontalBox(card) end)
        if not isValid(slot) then slot=attempt(function() return row:AddChild(card) end) end
        if isValid(slot) then
            attempt(function() slot:SetVerticalAlignment(2) end)
            attempt(function() slot:SetPadding({Left=14,Right=4,Top=0,Bottom=0}) end)
            menu.button=btn;menu.label=label;menu.gameCard=card
            menu.strategy="native-WBP_DiffCard"
            menu.inserted=true;menu.pressed=false
            setText(label,"SPEEDRUN") -- in case UMG Construct reset it
            installCardDescription(card)
            installStopwatchArt(card,title)
            menu.artRefreshPending=true
            say("BUTTON READY: native Speedrun difficulty card (same hover/cursor as Casual)")
            return true
        end
        say("CARD CLONE: horizontal row rejected native card, trying fallback")
    end
    if addFallbackButton(title,row,casual,nativeButton,casualLabel) then
        menu.inserted=true;menu.pressed=false
        return true
    end
    clearMenu("could not attach Speedrun card")
    return false
end

-- During gameplay the title widget may be removed/recreated by map travel.
-- Keep this retry loop active forever at a low cadence; do not permanently
-- stop it after the first successful insertion as v0.7 did.
local function resetRunAtMenu()
    if timer.mode=="off" then return end
    say("RUN RESET: returned to title menu; next Speedrun starts a fresh timer")
    timer.mode="off";timer.armed=false;timer.startWall=nil;timer.startCPU=nil
    timer.stopWall=nil;timer.stopCPU=nil;timer.startWorld=nil;timer.stopWorld=nil
    timer.clockWorld=nil;timer.enginePending=false;timer.sinceClick=nil
    timer.fallbacks=0
    resetIGT()
    resetShift()
    if isValid(hud.ui) then attempt(function() hud.ui:RemoveFromParent() end) end
    hud.ui=nil;hud.text=nil;hud.tries=0;hud.last=""
end
-- Cache new title widgets as Unreal constructs them. This is event-driven
-- (no global widget scan) and helps when FindFirstOf returns an old hidden title.
local newestTitle=nil
local _,notificationError=attempt(function()
    NotifyOnNewObject("/Game/Widgets/Title/WBP_TitleScreen.WBP_TitleScreen_C",function(obj)
        newestTitle=obj
    end)
end)
if notificationError then say("TITLE NOTIFY unavailable; using infrequent cached title lookup") end

local function setup()
    if menu.inserted and isValid(menu.button) and isValid(menu.title) then
        local onScreen=attempt(function() return menu.title:IsInViewport() end)
        if onScreen~=false then
            -- Exactly one post-construction artwork refresh to handle cards
            -- whose Blueprint SetUp() replaces their brush after attachment.
            if menu.artRefreshPending and isValid(menu.gameCard) then
                menu.artRefreshPending=false
                installStopwatchArt(menu.gameCard,menu.title)
                installCardDescription(menu.gameCard)
            end
            return true
        end
        clearMenu("title left the viewport")
    elseif menu.inserted then
        clearMenu("old title/button no longer valid")
    end
    local title=isValid(newestTitle) and newestTitle or nil
    if not isValid(title) or attempt(function() return title:IsInViewport() end)==false then
        title=attempt(function() return FindFirstOf("WBP_TitleScreen_C") end)
    end
    if not isValid(title) then return false end
    if attempt(function() return title:IsInViewport() end)==false then return false end
    local row=searchWidget(title,"HB_Dff")
    local casual=searchWidget(title,"Diff_Casual")
    if not (isValid(row) and isValid(casual)) then return false end
    -- Only reached when binding to a title menu again, not during an active
    -- title widget. Reset stale run state so the next click is never blocked.
    resetRunAtMenu()
    -- If Dead Signal reuses its original title screen on return, keep the
    -- existing Speedrun option instead of inserting duplicates.
    local n=attempt(function() return row:GetChildrenCount() end)
    if type(n)=="number" and n>=4 then
        for i=3,math.min(n-1,7) do
            local existing=attempt(function() return row:GetChildAt(i) end)
            local label=searchWidget(existing,"TB_Title")
            local button=searchWidget(existing,"BTN_DiffSelect")
            local holder=nil
            if not isValid(label) then
                local fallbackBtn=searchWidget(existing,"DSR10_SpeedrunButton")
                if isValid(fallbackBtn) then
                    label=searchWidget(existing,"DSR10_SpeedrunText")
                    button=fallbackBtn;holder=existing
                end
            end
            local printed=attempt(function() return label:GetText():ToString() end)
            local lastName=getName(existing)
            if isValid(button) and (printed=="SPEEDRUN" or lastName:find("DSR10_Speedrun")) then
                menu.title=title;menu.row=row;menu.casual=casual
                menu.casualButton=searchWidget(casual,"BTN_DiffSelect")
                menu.casualLabel=searchWidget(casual,"TB_Title")
                menu.titleLabel=searchWidget(title,"TB_Text")
                -- Refresh even when the game reused a previously inserted card.
                rememberFont(isValid(menu.titleLabel) and menu.titleLabel or menu.casualLabel)
                menu.label=label;menu.button=button;menu.holder=holder
                menu.gameCard=isValid(holder) and nil or existing
                menu.strategy=isValid(holder) and "styled-fallback" or "native-WBP_DiffCard"
                menu.inserted=true;menu.pressed=false
                handlerResolved=false;casualHandler=nil;casualHandlerName=nil
                if isValid(menu.gameCard) then
                    installCardDescription(menu.gameCard)
                    installStopwatchArt(menu.gameCard,title)
                end
                say("MENU REUSED: Speedrun option is already attached to this title screen")
                return true
            end
        end
    end
    say("FOUND difficulty row; installing Speedrun on current title")
    return addButton(title,row,casual)
end
local function pollButton()
    if not isValid(menu.button) then return end
    local now=attempt(function() return menu.button:IsPressed() end)==true
    if now and not menu.pressed then
        say("SPEEDRUN BUTTON mouse down detected")
        speedrunPressed()
    end
    menu.pressed=now
end

local function register(event,path,callback)
    local _,err=attempt(function() RegisterHook(path,callback) end)
    if err then say("WARNING can't hook "..event..": "..err)
    else say("Hook active: "..event) end
end
register("ThreatSubsystem.GameStart","/Script/DeadSignal.ThreatSubsystem:GameStart",function()
    say("GameStart observed (tutorial stage). Not starting speedrun timer")
end)
register("DeskPawn.GameStart","/Script/DeadSignal.DeskPawn:GameStart",function()
    say("DeskPawn.GameStart observed. Not starting speedrun timer")
end)
register("ThreatSubsystem.GameEnd","/Script/DeadSignal.ThreatSubsystem:GameEnd",function()
    finish("ThreatSubsystem.GameEnd")
end)
register("DeskPawn.GameEnd","/Script/DeadSignal.DeskPawn:GameEnd",function()
    finish("DeskPawn.GameEnd")
end)

-- A low-frequency, non-global lookup keeps the button present after map
-- travel and returning to New Game. This is NOT a FindAllOf(UserWidget).
LoopAsync(1500,function()
    ExecuteInGameThread(function()
        local _,err=attempt(setup)
        if err then say("SETUP ERROR: "..err) end
    end)
    return false
end)
-- Poll only cached actual buttons; no global scan during gameplay.
LoopAsync(25,function()
    if menu.inserted then
        ExecuteInGameThread(function()
            local _,err=attempt(pollButton)
            if err then say("BUTTON INPUT ERROR: "..err) end
        end)
    end
    return false
end)
LoopAsync(40,function()
    if timer.mode=="off" then return false end
    ExecuteInGameThread(function()
        if timer.mode=="running" then
            local _,clockErr=attempt(sampleIGT)
            if clockErr then say("IGT SAMPLE ERROR: "..clockErr) end
        end
        local _,err=attempt(updateHUD)
        if err then say("HUD UPDATE ERROR: "..err) end
    end)
    return false
end)
LoopAsync(25,function()
    if timer.mode=="waiting" then
        ExecuteInGameThread(function()
            -- All UObject operations, including IsValid, stay on game thread.
            if timer.mode=="waiting" and isValid(shift.button) then
                local _,err=attempt(pollShift)
                if err then say("BEGIN SHIFT INPUT ERROR: "..err) end
            end
        end)
    end
    return false
end)
LoopAsync(600,function()
    if timer.mode=="waiting" then
        ExecuteInGameThread(function()
            if timer.mode=="waiting" and not isValid(shift.button) then
                local _,err=attempt(resolveShiftButton)
                if err then say("BEGIN SHIFT LOOKUP ERROR: "..err) end
            end
        end)
    end
    return false
end)
-- Public release candidates intentionally have no manual start or stop keys.
-- The run starts on Begin Shift and ends on the game's GameEnd callback.
say("v1.0 RC2 font-cache fix loaded. Auto Begin Shift; stacked RTA/IGT; gold card; 1px HUD outline; restart-safety protections.")

-- An exported test API is inert in the game and lets us exercise the real code in a mock.
if rawget(_G,"DSR10_TEST_MODE") then
    _G.DSR10_TEST = {setup=setup, poll=pollButton, start=start, finish=finish,
                    arm=arm, click=speedrunPressed, draw=updateHUD,
                    menu=menu, timer=timer, hud=hud, elapsed=elapsed, resolve=selectCasualHandler, sampleIGT=sampleIGT, igt=igt, resetIGT=resetIGT, gameFont=gameFont, clearMenu=clearMenu, resetRun=resetRunAtMenu, shift=shift, shiftFind=resolveShiftButton, shiftPoll=pollShift, shiftReset=resetShift, formatTime=formatTime, checkpoint=checkpointIGT, pauseVisible=pausedByUI}
end
