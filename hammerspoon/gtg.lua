-- GTG in the menu bar. Grease-the-groove: a small set every hour or so.
--
-- Its own file rather than a block inside init.lua, and init.lua pcalls it:
-- this config has broken itself before (init.lua.broken-2026-08-12), and a
-- fault in a fitness reminder must not be able to take the Spotify ducking
-- with it.
--
-- All the behaviour lives in the `gtg` CLI. This is a face for it, not a
-- second implementation -- the log format, the rotation and the time parser
-- stay in one place, so the menu and the terminal can never disagree.

local M = {}

local GTG = os.getenv("HOME") .. "/.local/bin/gtg"
local bar = nil

-- Every argument quoted as one shell word. Movement text is free text on its
-- way to a shell, so "10 ring crunches; rm -rf ~" has to stay an argument
-- rather than becoming a second command.
local function sh(args)
  local cmd = "'" .. GTG .. "'"
  for _, a in ipairs(args) do
    cmd = cmd .. " '" .. (tostring(a):gsub("'", "'\\''")) .. "'"
  end
  local out = hs.execute(cmd .. " 2>&1")
  return out or ""
end

local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

local function todaySets()
  local out = sh({ "today" })
  local rows = {}
  for line in out:gmatch("[^\n]+") do
    -- "  08:00  ring crunches x10"
    if line:match("^%s+%d%d:%d%d%s") then rows[#rows + 1] = trim(line) end
  end
  local cov, sofar = out:match("in (%d+) of (%d+) waking hours")
  return rows, tonumber(out:match("(%d+) set%(s%)")) or 0, tonumber(cov), tonumber(sofar)
end

-- "🏋 3 · 2/5h": sets today, and how many of the waking hours so far got one.
-- The second number is the one grease-the-groove cares about.
local function refresh()
  if not bar then return end
  local _, n, cov, sofar = todaySets()
  local t = n > 0 and ("🏋 " .. n) or "🏋"
  if cov and sofar then t = t .. " · " .. cov .. "/" .. sofar .. "h" end
  bar:setTitle(t)
end

-- Show what the CLI said, verbatim. A confirmation that paraphrases is a
-- confirmation that can be wrong: the resolved time on a backdated set is the
-- whole reason the CLI prints it back.
local function report(out)
  local msg = trim(out)
  if msg == "" then msg = "nothing logged" end
  hs.alert.show(msg, 3)
  refresh()
end

local function logNow()
  report(sh({}))
end

local function logOther()
  local btn, text = hs.dialog.textPrompt(
    "Log a set",
    "What did you do? Separate a whole round with \";\".\n" ..
    "e.g.  10 ring crunches; pull-ups x5; dead hang 30s",
    "", "Log it", "Cancel")
  if btn ~= "Log it" or trim(text) == "" then return end
  report(sh({ text }))
end

-- The reason this whole thing exists: a round done in the kitchen before you
-- sat down had nowhere to go, because the nudge can only ever stamp the moment
-- you answer it. And memory logged about none of them: two or three sets most
-- mornings, and the log shows almost nothing before the first nudge.
--
-- So it asks. One box per set or round, and it asks again until you say that
-- is all, because the morning is usually more than one thing at more than one
-- time. Each line is handed over whole, as ONE argument: the CLI pulls the
-- @time off itself, and it is the only thing that should, since a multi-word
-- time ("yesterday 7am") needs the same longest-prefix rule the terminal uses.
--
-- Every showing is stamped into the nudge log through `gtg note`, so
-- `gtg fires` can say how often this fires and how much it catches.
local function catchUp(reason)
  sh({ "note", "catch-up shown (" .. reason .. ")" })
  local logged = 0
  while true do
    local btn, text = hs.dialog.textPrompt(
      "Before you sat down?",
      "Anything done away from the desk? Start with the time.\n" ..
      "e.g.  @7:15 10x bulgarian split squats\n" ..
      "      @8am pull-ups x5; dead hang 30s\n" ..
      "Times: 8am  8:00  -90m  \"yesterday 7am\"",
      "@", "Log it", "That's all")
    text = trim(text or "")
    if btn ~= "Log it" or text == "" or text == "@" then break end
    local out = sh({ text })
    report(out)
    for _ in out:gmatch("logged: ") do logged = logged + 1 end
  end
  sh({ "note", "catch-up done: " .. logged .. " logged" })
  refresh()
end

-- The moment to ask is the first unlock after a long gap: that is sitting
-- down. Pure, so it can be checked from the command line:
--   hs -c 'return gtgBar.wantsCatchUp(os.time() - 3*3600, os.time())'
--
-- ponytail: the hours are fixed at 6..22 rather than read from the plan. The
-- plan's window starts at 9, and the whole point here is the sets done before
-- 9. If the plan ever grows a CATCHUP window, read it from `gtg plan`.
local CATCHUP_GAP = 2 * 3600
function M.wantsCatchUp(since, now)
  if not since then return false end
  local h = tonumber(os.date("%H", now))
  if h < 6 or h >= 22 then return false end
  return (now - since) >= CATCHUP_GAP
      or os.date("%Y-%m-%d", since) ~= os.date("%Y-%m-%d", now)
end

-- When the screen went away. Set on lock or sleep, read and cleared on the
-- unlock that follows. Only an UNLOCK asks: a wake with the screen still
-- locked would put the box behind the lock screen.
--
-- ponytail: a Mac that sleeps without locking never unlocks, so it never
-- asks. Fine here, where the lock is on; a lock-free setup would need
-- screensDidWake as a second trigger.
local awayFrom = nil
local function onPower(ev)
  local w = hs.caffeinate.watcher
  if ev == w.screensDidLock or ev == w.screensDidSleep or ev == w.systemWillSleep then
    awayFrom = awayFrom or os.time()
  elseif ev == w.screensDidUnlock or ev == w.sessionDidBecomeActive then
    local since = awayFrom
    awayFrom = nil
    if M.wantsCatchUp(since, os.time()) then
      local mins = math.floor((os.time() - since) / 60)
      local why = string.format("back after %dh%02dm", math.floor(mins / 60), mins % 60)
      -- A beat after the unlock, so the box lands on a settled screen.
      hs.timer.doAfter(15, function() catchUp(why) end)
    end
  end
end

-- Where a complaint goes while it is still fresh. The next iteration of the
-- tool is chosen from these.
local function friction()
  local btn, text = hs.dialog.textPrompt(
    "What got in the way?",
    "One line. It is stamped with the time, where you are, and today's count.",
    "", "Note it", "Cancel")
  if btn ~= "Note it" or trim(text or "") == "" then return end
  hs.alert.show(trim(sh({ "friction", trim(text) })), 2)
end

local function buildMenu()
  local items = {}
  local rows, n = todaySets()
  local where = sh({ "where" }):match("you are:%s*(%a+)") or "?"
  local pick = trim((sh({ "options" }):gsub("\n.*", "")))

  items[#items + 1] = {
    title = n .. (n == 1 and " set today" or " sets today") .. "  ·  " .. where,
    disabled = true,
  }
  items[#items + 1] = { title = "-" }

  if pick ~= "" then
    items[#items + 1] = { title = "Did " .. pick, fn = logNow }
  end
  items[#items + 1] = { title = "Log something else…", fn = logOther }
  items[#items + 1] = { title = "Log what I did before sitting down…", fn = function() catchUp("menu") end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Something got in the way…", fn = friction }
  items[#items + 1] = { title = "-" }

  if #rows > 0 then
    local sub = {}
    for _, r in ipairs(rows) do sub[#sub + 1] = { title = r, disabled = true } end
    items[#items + 1] = { title = "Today", menu = sub }
  end
  items[#items + 1] = { title = "History page…", fn = function() sh({ "page" }) end }
  items[#items + 1] = { title = "Refresh", fn = refresh }
  return items
end

M.menu = buildMenu

M.refresh = refresh

-- Reuses the existing item rather than deleting and rebuilding one. Calling
-- this twice in one Lua state is only something a person does by hand, but
-- delete-then-recreate leaked a live timer each time, and hs.menubar:delete()
-- does not return when it is driven from the `hs` command line -- so the
-- obvious way to re-run this by hand was also the way to hang it.
function M.start()
  bar = bar or hs.menubar.new()
  if not bar then return end
  bar:setMenu(buildMenu)
  if M.timer then M.timer:stop() end
  -- The count goes stale on its own as the nudge logs sets behind your back,
  -- so it is repainted on a timer as well as after every action here.
  M.timer = hs.timer.doEvery(300, refresh)
  if M.power then M.power:stop() end
  M.power = hs.caffeinate.watcher.new(onPower)
  M.power:start()
  refresh()
end

M.catchUp = catchUp

M.start()

-- Exposed for CLI testing, the same way spotifyDuck is:
--   hs -c "return #gtgBar.menu()"
gtgBar = M

return M
