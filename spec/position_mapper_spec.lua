-- Unit tests for weread/lib/position_mapper.lua.
-- Run from the repo root with:
--   lua spec/position_mapper_spec.lua

package.path = "./?.lua;" .. package.path
local Mapper = require("weread.lib.position_mapper")

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function near(got, want, tolerance, label)
    checks = checks + 1
    if math.abs(got - want) > tolerance then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %.6f, want %.6f",
            current_test, label, got, want))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

test("full book maps overall position to chapter", function()
    local position = assert(Mapper.local_to_remote(chapters, 0.25, {
        is_full_book = true,
    }))
    eq(position.percent, 25, "integer percent")
    eq(position.chapter_uid, 22, "chapter uid")
    eq(position.chapter_idx, 2, "chapter idx")
    eq(position.chapter_offset, 150, "chapter offset")
end)

test("full book end maps to last chapter end", function()
    local position = assert(Mapper.local_to_remote(chapters, 1, {
        is_full_book = true,
    }))
    eq(position.percent, 100, "percent")
    eq(position.chapter_uid, 33, "chapter uid")
    eq(position.chapter_offset, 600, "chapter offset")
end)

test("single chapter computes whole book percent", function()
    local position = assert(Mapper.local_to_remote(chapters, 0.5, {
        current_chapter_uid = 22,
        is_full_book = false,
    }))
    eq(position.chapter_offset, 150, "chapter offset")
    eq(position.percent, 25, "whole book percent")
    near(position.fraction, 0.25, 0.0001, "whole book fraction")
end)

test("single chapter requires a known chapter", function()
    local position, reason = Mapper.local_to_remote(chapters, 0.5, {
        current_chapter_uid = 99,
        is_full_book = false,
    })
    eq(position, nil, "position rejected")
    eq(reason, "current_chapter_not_found", "reason")
end)

test("remote offset is authoritative", function()
    local normalized = assert(Mapper.normalize_remote({
        progress = 99,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
    }, "book", "gateway", chapters))
    near(normalized.percent, 25, 0.0001, "recomputed percent")
    eq(normalized.position_basis, "chapter_offset", "basis")
end)

test("remote full book position maps to overall fraction", function()
    local target = assert(Mapper.remote_to_local(chapters, {
        percent = 99,
        chapter_uid = 22,
        chapter_offset = 150,
    }, { is_full_book = true }))
    near(target.fraction, 0.25, 0.0001, "fraction")
    eq(target.requires_chapter_open, false, "no chapter switch")
end)

test("remote single chapter requests chapter switch", function()
    local target = assert(Mapper.remote_to_local(chapters, {
        percent = 25,
        chapter_uid = 22,
        chapter_offset = 150,
    }, {
        is_full_book = false,
        current_chapter_uid = 11,
    }))
    near(target.fraction, 0.5, 0.0001, "chapter fraction")
    eq(target.requires_chapter_open, true, "chapter switch")
    eq(target.chapter.chapterUid, 22, "target chapter")
end)

test("remote source conflict chooses newest but flags conflict", function()
    local selected = Mapper.choose_remote(
        { percent = 20, updated_at = 10, source = "web" },
        { percent = 40, updated_at = 20, source = "gateway" },
        2
    )
    eq(selected.source, "gateway", "newest selected")
    eq(selected.conflict, true, "conflict flagged")
end)

test("compare uses percentage point threshold", function()
    local state = Mapper.compare({ percent = 25 }, { percent = 28 }, 2)
    eq(state, "remote_ahead", "remote ahead")
    state = Mapper.compare({ percent = 25 }, { percent = 24 }, 2)
    eq(state, "same", "within threshold")
    state = Mapper.compare(
        { percent = 25, chapter_uid = 11 },
        { percent = 25, chapter_uid = 22 },
        2
    )
    eq(state, "different", "chapter mismatch is not same")
end)

test("missing remote offset falls back to raw percent", function()
    local normalized = assert(Mapper.normalize_remote({
        progress = 40,
        chapterUid = 22,
    }, "book", "web", chapters))
    eq(normalized.position_basis, "raw_percent", "basis")
    eq(normalized.percent, 40, "raw percent preserved")
end)

print(string.format("position_mapper_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
