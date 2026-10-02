-- DEMO.LUA: a Lua script, run by a Linux program on LexOS
-- (lua /LINUX/DEMO.LUA)
local esc = string.char(27)
local function color(c, s) return esc .. "[" .. c .. "m" .. s .. esc .. "[0m" end

print(color("1;36", "Lua " .. _VERSION:sub(5) .. " on LexOS"))
print()

-- Fibonacci, and the time it took
local t = os.clock()
local a, b = 0, 1
for i = 1, 30 do a, b = b, a + b end
print(("fib(30) = %d   (%.3f s)"):format(a, os.clock() - t))

-- a table, sorted
local langs = { "Lua", "C", "asm", "BASIC", "HG" }
table.sort(langs, function(x, y) return x:lower() < y:lower() end)
print("sorted: " .. table.concat(langs, ", "))

-- the files in /DEMOS (io.popen needs a shell: BusyBox's, if it's there)
local f = io.open("/DEMOS/README.MD")
if f then
  local n = 0
  for _ in f:lines() do n = n + 1 end
  f:close()
  print("/DEMOS/README.MD has " .. n .. " lines")
end

-- a little picture
for y = -6, 6 do
  local line = {}
  for x = -20, 20 do
    local inside = (x / 20) ^ 2 + (y / 6) ^ 2 <= 1
    line[#line + 1] = inside and color("33", "*") or " "
  end
  print(table.concat(line))
end
print(os.date("Today is %A, %d %B %Y, %H:%M"))
