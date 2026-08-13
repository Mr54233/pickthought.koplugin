-- 用法:luajit tests/run.lua(在仓库根目录)
local T = {passed = 0, failed = 0}
function T.case(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end
function T.ok(cond, label)
    if not cond then error(tostring(label or "assertion failed"), 2) end
end
function T.eq(got, want, label)
    if got ~= want then
        error(string.format("%s\n  got:  %s\n  want: %s",
            tostring(label or "not equal"), tostring(got), tostring(want)), 2)
    end
end
_G.T = T
_G.STUBS = require("tests.stubs")

local files = {
    "tests.test_smoke", "tests.test_epub_reader", "tests.test_annotation_style",
    "tests.test_epub_inject",
    "tests.test_binding", "tests.test_chapter_map", "tests.test_sync",
    "tests.test_sync_report", "tests.test_batch_sync",
    "tests.test_web_fetch", "tests.test_power_inhibit", "tests.test_sync_task",
    "tests.test_thought_db", "tests.test_thoughts",
    "tests.test_annotation_compat",
}
for _, name in ipairs(files) do
    local ok, err = pcall(require, name)
    if not ok and not tostring(err):find("module '" .. name .. "' not found", 1, true) then
        T.failed = T.failed + 1
        print("FAIL(load): " .. name .. "\n  " .. tostring(err))
    end
end

print(string.format("passed=%d failed=%d", T.passed, T.failed))
os.exit(T.failed == 0 and 0 or 1)
