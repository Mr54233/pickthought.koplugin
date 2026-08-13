-- Unit tests for weread/lib/book_reviews.lua.
-- Run from the repo root with a plain Lua interpreter:
--   lua spec/book_reviews_spec.lua

package.path = "./?.lua;" .. package.path
local BookReviews = require("weread.lib.book_reviews")

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

local function test(name, fn)
    current_test = name
    fn()
end

test("normalizes nested gateway reviews", function()
    local result = BookReviews.normalize_list({
        reviewsCnt = 12,
        reviewsHasMore = 1,
        reviews = {
            {
                idx = 7,
                review = {
                    review = {
                        reviewId = "r1",
                        author = { nick = "读者甲" },
                        content = "第一段<br>第二段 &amp; 尾声",
                        star = 100,
                        createTime = 1700000000,
                        isFinish = 1,
                    },
                },
            },
        },
    })
    eq(result.total_count, 12, "total count")
    eq(result.has_more, true, "has more")
    eq(#result.items, 1, "item count")
    eq(result.items[1].author, "读者甲", "author")
    eq(result.items[1].content, "第一段\n第二段 & 尾声", "plain content")
    eq(result.items[1].rating, 10, "100-point star normalized to 10")
    eq(result.items[1].is_finish, true, "finished")
    eq(result.items[1].idx, 7, "idx")
end)

test("uses html content when plain content is empty", function()
    local item = BookReviews.normalize_item({
        review = {
            review = {
                htmlContent = "<p>很好</p><p>值得读&#33;</p>",
                author = "某读者",
            },
        },
    })
    eq(item.content, "很好\n\n值得读!", "html fallback")
    eq(item.author, "某读者", "string author")
end)

test("truncates previews by UTF-8 characters", function()
    eq(BookReviews.preview("一二三四五", 3), "一二三…", "Chinese preview")
    eq(BookReviews.preview("abc", 3), "abc", "exact preview")
end)

test("formats review ratings on a ten-point scale", function()
    eq(BookReviews.normalize_item({ star = 60 }).rating, 6, "60 becomes 6")
    eq(BookReviews.normalize_item({ star = 100 }).rating, 10, "100 becomes 10")
    eq(BookReviews.format_rating(6), "6.0", "one decimal place")
end)

test("formats string and millisecond dates", function()
    eq(BookReviews.format_date("2026/7/9 00:00:00"), "2026-07-09", "string date")
    eq(BookReviews.format_date("2026年7月"), "2026年7月", "displayable date text")
    eq(
        BookReviews.format_date(1700000000000),
        os.date("%Y-%m-%d", 1700000000),
        "millisecond timestamp"
    )
end)

if failures > 0 then
    error(string.format("%d/%d checks failed", failures, checks))
end
print(string.format("OK: %d checks", checks))
