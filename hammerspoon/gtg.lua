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

-- THE MENU DOES NO WORK ON THE CLICK.
--
-- It used to run three `gtg` commands while the click waited -- today, where
-- and options -- which measured 153ms, 145ms and 634ms on this Mac: a second
-- of nothing happening, every time, and "sometimes it just does not open" is
-- what that feels like. hs.menubar builds its menu synchronously, so that
-- second was spent on Hammerspoon's main thread with the pointer already down.
--
-- So the menu is drawn from the last snapshot and nothing else. Opening it
-- also starts a fresh one in the BACKGROUND (hs.task, not hs.execute), which
-- the next open and the timer pick up. The cost of that trade is a count up to
-- a few minutes stale; the actions never use it -- `gtg` recomputes the pick
-- when it runs -- so the worst case is a label, not a wrong set logged.
local snap = { rows = {}, sets = 0, cov = nil, sofar = nil, where = "?", pick = "", paused = nil }
local fetcher = nil

local function parseStatus(out)
  local s = { rows = {}, sets = 0 }
  s.where = out:match("where:%s*([^\n]*)") or "?"
  s.pick = trim(out:match("pick:%s*([^\n]*)") or "")
  s.paused = out:match("paused:%s*([^\n]*)")   -- nil unless it is off
  for line in out:gmatch("[^\n]+") do
    -- "  08:00  ring crunches x10"
    if line:match("^%s+%d%d:%d%d%s") then s.rows[#s.rows + 1] = trim(line) end
  end
  s.sets = tonumber(out:match("(%d+) set%(s%)")) or 0
  local cov, sofar = out:match("in (%d+) of (%d+) waking hours")
  s.cov, s.sofar = tonumber(cov), tonumber(sofar)
  return s
end

-- "🏋 3 · 2/5h": sets today, and how many of the waking hours so far got one.
-- The second number is the one grease-the-groove cares about. "🏋 off" says
-- the nudges are deliberately off, so a quiet afternoon is never a mystery.
local function repaint()
  if not bar then return end
  if snap.paused then bar:setTitle("🏋 off"); return end
  local t = snap.sets > 0 and ("🏋 " .. snap.sets) or "🏋"
  if snap.cov and snap.sofar then t = t .. " · " .. snap.cov .. "/" .. snap.sofar .. "h" end
  bar:setTitle(t)
end

-- One `gtg status` in the background. A failed or empty run keeps the last
-- snapshot rather than blanking the menu: stale is better than empty here.
local function fetch(after)
  if fetcher and fetcher:isRunning() then return end
  fetcher = hs.task.new(GTG, function(_, out)
    if out and out ~= "" then snap = parseStatus(out) end
    repaint()
    if after then after() end
  end, { "status" })
  if not fetcher or not fetcher:start() then repaint(); if after then after() end end
end

local function refresh() fetch() end

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

-- One typed line, wherever it was typed. A movement the CLI does not know
-- comes back as a question with the line in a text field: fix the spelling
-- and it resolves, or log it as it is and the log is what makes it known
-- from then on. Before this, the box showed a terminal command and stopped.
local function logText(text)
  local out = sh({ text })
  local unknown = out:match("unknown movement: ([^\n]+)")
  if not unknown then return out end
  local btn, edited = hs.dialog.textPrompt(
    "New movement: " .. unknown,
    "Not one it knows yet. Fix the spelling, or log it as it is.\n" ..
    "(gtg add \"...\" in a terminal also offers it every day.)",
    text, "Log it", "Cancel")
  edited = trim(edited or "")
  if btn ~= "Log it" or edited == "" then return "not logged: " .. unknown end
  return sh({ "--new", edited })
end

-- What to put on screen when it is over: the rows that landed, or the reason
-- there are none. Never a bare "nothing heard" while the reason sits unread in
-- stderr -- an alert that reports the wrong failure costs more than one that
-- reports nothing, because it sends you looking in the wrong place.
local function outcome(out, err)
  local rows = trim(out)
  if rows ~= "" then return rows end
  local unknown = err:match("unknown movement: ([^\n]+)")
  if unknown then return 'not a movement it knows:\n"' .. trim(unknown) .. '"' end
  local why = ""
  for line in trim(err):gmatch("[^\n]+") do
    if not line:match("^listening") and not line:match("^installing")
      and not line:match("^heard: ") and not line:match("^new%? log it") then
      why = line
    end
  end
  if why ~= "" then return why end
  return "nothing heard"
end

-- SAY IT. One key, speak, done.
--
-- The lowest-friction path there is, and the whole reason the interpreter
-- exists: speech arrives as sentences, and the strict parser was built for
-- commands. "ten ring dips and a thirty second back stretch with the
-- kettlebell" comes back from the recogniser as "10 ring dips and a 32nd
-- backstretch with a kettlebell", which nothing made of regular expressions
-- was ever going to read.
--
-- hs.task, never hs.execute: this takes seconds, and the rule this menu is
-- built around is that nothing blocks Hammerspoon's main thread.
local listening = false
local function sayIt()
  if listening then return end
  listening = true
  -- NOTHING SAYS "SPEAK" UNTIL THE MICROPHONE IS OPEN.
  --
  -- The Ping and the box used to fire the instant the key was pressed, while
  -- gtg-listen still had a process to start, an asset check to make and an
  -- audio engine to bring up -- measured at 0.7 to 1.0 seconds. Everything
  -- said in that window was never recorded at all. "I just did 5 Bulgarian
  -- split squats" arrived as "squats", and one word was enough for the reader
  -- downstream to pick the wrong movement and log a set that never happened.
  --
  -- So this box is deliberately quiet and says the opposite of go. The Ping
  -- comes later, when gtg-listen prints its readiness line, and that line is
  -- the only thing that means the microphone is live.
  local box = hs.alert.show("starting the mic\u{2026}", true)
  local ready = false

  -- BOTH callbacks accumulate.
  --
  -- hs.task hands streamed output to the STREAMING callback and then gives
  -- the completion callback empty strings. Reading the result only at
  -- completion therefore read nothing, and the alert said "nothing heard"
  -- immediately after visibly having heard something -- while hiding the real
  -- error, which was that the interpreter could not be found at all. One bug
  -- concealing another is the expensive kind.
  local got = { out = {}, err = {} }
  local function keep(o, e)
    if o and o ~= "" then got.out[#got.out + 1] = o end
    if e and e ~= "" then got.err[#got.err + 1] = e end
  end

  -- WHICHEVER CALLBACK FINISHES LAST DRAWS THE RESULT.
  --
  -- hs.task calls the streaming callback once more with a nil task after the
  -- process ends, and the order of that against the termination callback is
  -- not guaranteed. Drawing straight from termination therefore reads a
  -- buffer that a trailing chunk has not reached yet, which is the same class
  -- of bug as reading only the termination callback in the first place: an
  -- alert that confidently reports the wrong outcome. Caught in review.
  --
  -- The grace timer covers the ordering the other way, where termination
  -- lands first. Drawn once, guarded, so neither path can double it.
  local drawn = false
  local function draw()
    if drawn then return end
    drawn = true
    listening = false
    if box then hs.alert.closeSpecific(box) end
    hs.alert.show(outcome(table.concat(got.out), table.concat(got.err)), 4)
    refresh()
  end

  -- A WATCHDOG, because the worst outcome here is not a wrong alert.
  --
  -- `listening` guards against a second press, and only draw() clears it. If
  -- draw() ever fails to run -- a callback that never fires, a task that never
  -- reaps -- the hotkey is dead for the rest of the session and the only cure
  -- is reloading Hammerspoon, which nobody will connect to this. The two
  -- stages bound themselves at 20s and 25s, so 90s cannot fire early on a
  -- healthy run.
  hs.timer.doAfter(90, function()
    if not drawn then
      drawn = true
      listening = false
      if box then hs.alert.closeSpecific(box) end
      hs.alert.show("gtg say gave no answer", 3)
    end
  end)

  local ended = false
  local t = hs.task.new(GTG, function(_, out, err)
    keep(out, err)
    ended = true
    hs.timer.doAfter(0.25, draw)
  end, function(task, out, err)
    keep(out, err)
    -- task is nil on the final call. Nothing is still in flight then, so if
    -- the process has already been reaped there is nothing left to wait for.
    if task == nil then
      if ended then draw() end
      return true
    end
    local seen = table.concat(got.err)

    -- gtg-listen has opened the microphone. NOW invite speech.
    if not ready and seen:match("listening") then
      ready = true
      if box then hs.alert.closeSpecific(box) end
      box = hs.alert.show("\u{1F3A4}  SPEAK NOW", true)
      local ping = hs.sound.getByName("Ping")
      if ping then ping:play() end
    end

    -- The box stops claiming to listen once it has stopped. One that still
    -- says "listening" while a model reads the line teaches you to talk over
    -- it.
    local heard = seen:match("heard: ([^\n]+)")
    if heard and box and not drawn then
      hs.alert.closeSpecific(box)
      box = hs.alert.show('"' .. heard .. '"', true)
    end
    return true
  end, { "say" })

  if not t or not t:start() then
    listening = false
    if box then hs.alert.closeSpecific(box) end
    hs.alert.show("could not start gtg say", 3)
  end
end

local function logOther()
  local btn, text = hs.dialog.textPrompt(
    "Log a set",
    "What did you do? \"and\" or \";\" between sets.\n" ..
    "e.g.  10 ring crunches and pull-ups x5 and dead hang 30s",
    "", "Log it", "Cancel")
  if btn ~= "Log it" or trim(text) == "" then return end
  report(logText(text))
end

-- The reason this whole thing exists: a round done in the kitchen before you
-- sat down had nowhere to go, because the nudge can only ever stamp the moment
-- you answer it. And memory logged about none of them: two or three sets most
-- mornings, and the log shows almost nothing before the first nudge.
--
-- So it asks. ONE box, the whole morning in one line: "and" between sets,
-- and each set may carry its own @time. It used to ask again after every
-- entry until you said that was all, and that second box was the complaint.
-- The line is handed over whole, as ONE argument: the CLI pulls the @times
-- off itself, and it is the only thing that should, since a multi-word time
-- ("yesterday 7am") needs the same longest-prefix rule the terminal uses.
--
-- Every showing is stamped into the nudge log through `gtg note`, so
-- `gtg fires` can say how often this fires and how much it catches.
local function catchUp(reason)
  sh({ "note", "catch-up shown (" .. reason .. ")" })
  local logged = 0
  local btn, text = hs.dialog.textPrompt(
    "Before you sat down?",
    "Everything done away from the desk, in one line. Start with the time,\n" ..
    "\"and\" between sets, another @time where the time changed.\n" ..
    "e.g.  @7:15 pull-ups x5 and @7:40 ring dips x5 and dead hang 30s\n" ..
    "Times: 8am  8:00  -90m  \"yesterday 7am\"",
    "@", "Log it", "Nothing")
  text = trim(text or "")
  if btn == "Log it" and text ~= "" and text ~= "@" then
    local out = logText(text)
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
      -- A beat after the unlock, so the box lands on a settled screen. The
      -- snapshot is refreshed FIRST and the box is skipped while the nudges
      -- are off: "stop sending me these things" means this box too, and a
      -- cached answer from before the pause would have shown it anyway.
      hs.timer.doAfter(15, function()
        fetch(function() if not snap.paused then catchUp(why) end end)
      end)
    end
  end
end

-- Is a call on screen? The calendar was the meeting signal and it never fired
-- once in three weeks, and the microphone is no use here: Wispr Flow holds it
-- open whenever Ben dictates. The window list is what the machine actually
-- knows. Apps name a live call in their window title, so this returns the
-- first such title, or "".
--
-- OBSERVED, not yet acted on: gtg-nudge writes what this saw into the nudge
-- log at every fire, and `gtg fires` counts it against what Ben then did.
-- Only after a week of that does it get to suppress anything.
--
-- ponytail: a Meet in a BACKGROUND tab is invisible, since a browser window
-- is titled by its active tab. The observation week will show whether that
-- matters.
--   hs -c 'return gtgBar.meetingWindow()'
local MEETING = {
  { app = "^zoom%.us$",        title = "^Zoom Meeting" },
  { app = "^zoom%.us$",        title = "^Zoom Webinar" },
  { app = "Microsoft Teams",   title = "Meeting" },
  { app = "Microsoft Teams",   title = "Call" },
  { app = "^Slack$",           title = "Huddle" },
  -- Google Meet, any browser. Lua patterns are byte-wise and the en dash is
  -- three bytes, hence the + rather than a single class match.
  { app = ".",                 title = "^Meet [-–]+ " },
  { app = ".",                 title = "Google Meet" },
}
-- Pure, so the patterns can be checked without a call open:
--   hs -c 'return gtgBar.meetingMatch("zoom.us", "Zoom Meeting")'
function M.meetingMatch(app, title)
  for _, m in ipairs(MEETING) do
    if app:match(m.app) and title:match(m.title) then return true end
  end
  return false
end
function M.meetingWindow()
  for _, w in ipairs(hs.window.allWindows()) do
    local a = w:application()
    local app = a and a:name() or ""
    local t = w:title() or ""
    if M.meetingMatch(app, t) then return app .. ": " .. t end
  end
  return ""
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

-- Off for the rest of today, and back tomorrow morning by itself. One click,
-- because the moment this is wanted is the moment the tool is a nuisance, and
-- a nuisance that takes a submenu to silence gets ignored instead.
local function pauseToday()
  hs.alert.show(trim(sh({ "off" }):gsub("\n.*", "")), 3)
  refresh()
end

local function resume()
  hs.alert.show(trim(sh({ "on" })), 2)
  refresh()
end

local function buildMenu()
  local items = {}
  local n = snap.sets

  items[#items + 1] = {
    title = n .. (n == 1 and " set today" or " sets today") .. "  ·  " .. snap.where,
    disabled = true,
  }
  if snap.paused then
    items[#items + 1] = { title = "nudges off until " .. snap.paused, disabled = true }
  end
  items[#items + 1] = { title = "-" }

  if snap.pick ~= "" then
    items[#items + 1] = { title = "Did " .. snap.pick, fn = logNow }
  end
  -- First of the typing-free options and named with its key, because the
  -- point of it is never having to open this menu again.
  items[#items + 1] = { title = "Say a set…   ⌃⌥⌘V", fn = sayIt }
  items[#items + 1] = { title = "Log something else…", fn = logOther }
  items[#items + 1] = { title = "Log what I did before sitting down…", fn = function() catchUp("menu") end }
  items[#items + 1] = { title = "-" }
  if snap.paused then
    items[#items + 1] = { title = "Turn the nudges back on", fn = resume }
  else
    items[#items + 1] = { title = "Not today — stop the nudges", fn = pauseToday }
  end
  items[#items + 1] = { title = "Something got in the way…", fn = friction }
  items[#items + 1] = { title = "-" }

  if #snap.rows > 0 then
    local sub = {}
    for _, r in ipairs(snap.rows) do sub[#sub + 1] = { title = r, disabled = true } end
    items[#items + 1] = { title = "Today", menu = sub }
  end
  items[#items + 1] = { title = "History page…", fn = function() sh({ "page" }) end }
  items[#items + 1] = { title = "Refresh", fn = refresh }
  -- Drawn from the snapshot above, so the click never waited. Start the next
  -- one now: by the following open it is already current.
  fetch()
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
  -- Deleted and rebound rather than added to, so re-running this by hand does
  -- not leave two bindings racing for one key.
  if M.hotkey then M.hotkey:delete() end
  M.hotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "V", sayIt)
  refresh()
end

M.catchUp = catchUp
M.sayIt = sayIt

M.start()

-- Exposed for CLI testing, the same way spotifyDuck is:
--   hs -c "return #gtgBar.menu()"
gtgBar = M

return M
