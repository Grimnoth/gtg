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
  return rows, tonumber(out:match("(%d+) set%(s%)")) or 0
end

local function refresh()
  if not bar then return end
  local _, n = todaySets()
  bar:setTitle(n > 0 and ("🏋 " .. n) or "🏋")
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
-- you answer it.
local function logEarlier()
  local btn, text = hs.dialog.textPrompt(
    "Log a set you did earlier",
    "Start with the time, then what you did.\n" ..
    "e.g.  @8am 10 ring crunches; pull-ups x5\n" ..
    "Times: 8am  8:00  14:30  -90m  \"yesterday 7am\"",
    "@", "Log it", "Cancel")
  if btn ~= "Log it" then return end
  text = trim(text)
  if text == "" or text == "@" then return end
  -- Handed over whole, as ONE argument. The CLI pulls the @time off itself,
  -- and it is the only thing that should: a multi-word time ("yesterday 7am")
  -- needs the same longest-prefix rule the terminal uses, and splitting it
  -- here would be a second, worse copy of that rule.
  report(sh({ text }))
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
  items[#items + 1] = { title = "Log a set I did earlier…", fn = logEarlier }
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
  refresh()
end

M.start()

-- Exposed for CLI testing, the same way spotifyDuck is:
--   hs -c "return #gtgBar.menu()"
gtgBar = M

return M
