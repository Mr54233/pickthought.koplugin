#!/usr/bin/env python3
"""
Verify WeRead MP article fetching flow.

Tests:
1. /web/mp/articles WITHOUT x-wr-ticket → expects -2041
2. /web/mp/articles WITH x-wr-ticket → expects success (if ticket is fresh)
3. /web/mp/content WITHOUT any WPA → expects success (no WPA needed)

Usage:
    # Test that articles fail without ticket and content works:
    python3 scripts/verify_mp_articles.py --cookie "wr_skey=XXX; wr_vid=XXX; ..."

    # Test with a fresh x-wr-ticket (copy from browser DevTools):
    python3 scripts/verify_mp_articles.py --cookie "..." --ticket "t03tserver..."

Or set WEREAD_COOKIE env var.
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
import urllib.parse

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/148.0.0.0 Safari/537.36"
)

BOOK_ID = "MP_WXS_3286016687"


def http_get(url, cookie, extra_headers=None):
    headers = {
        "Accept": "application/json, text/plain, */*",
        "Referer": "https://weread.qq.com/",
        "Cookie": cookie,
        "User-Agent": UA,
    }
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode("utf-8", errors="replace"), resp.status


def main():
    parser = argparse.ArgumentParser(description="Verify WeRead MP article flow")
    parser.add_argument("--cookie", default=os.environ.get("WEREAD_COOKIE", ""))
    parser.add_argument("--ticket", default="", help="Fresh x-wr-ticket from browser")
    parser.add_argument("--book-id", default=BOOK_ID)
    args = parser.parse_args()

    if not args.cookie:
        print("ERROR: provide --cookie or set WEREAD_COOKIE", file=sys.stderr)
        sys.exit(1)

    articles_url = (
        f"https://weread.qq.com/web/mp/articles"
        f"?bookId={urllib.parse.quote(args.book_id, safe='')}&offset=0"
    )

    # Test 1: articles WITHOUT ticket
    print("=" * 60)
    print("Test 1: /web/mp/articles WITHOUT x-wr-ticket")
    print("Expected: errCode -2041 (WPA required)")
    print("=" * 60)
    body, status = http_get(articles_url, args.cookie)
    data = json.loads(body)
    err = data.get("errCode", "none")
    print(f"  Status: {status}, errCode: {err}")
    if err == -2041:
        print("  PASS: correctly requires WPA")
    elif err == 0 or "reviews" in data:
        print("  UNEXPECTED: works without ticket!")
    print()

    # Test 2: articles WITH ticket (if provided)
    if args.ticket:
        print("=" * 60)
        print("Test 2: /web/mp/articles WITH x-wr-ticket")
        print("=" * 60)
        body2, status2 = http_get(articles_url, args.cookie, {"x-wr-ticket": args.ticket})
        data2 = json.loads(body2)
        err2 = data2.get("errCode", "none")
        reviews = data2.get("reviews", [])
        if err2 == -2041:
            print(f"  FAIL: ticket expired or invalid (errCode={err2})")
        elif reviews:
            articles = []
            for g in reviews:
                for sub in g.get("subReviews", []):
                    r = sub.get("review", {})
                    mp = r.get("mpInfo", {})
                    articles.append({
                        "reviewId": r.get("reviewId", ""),
                        "title": mp.get("title", ""),
                    })
            print(f"  PASS: got {len(articles)} articles")
            for i, a in enumerate(articles[:3]):
                print(f"    [{i+1}] {a['title']}")
        else:
            print(f"  Result: {data2}")
        print()
    else:
        print("(Skipping Test 2: no --ticket provided)")
        print()

    # Test 3: /web/mp/content WITHOUT WPA
    print("=" * 60)
    print("Test 3: /web/mp/content WITHOUT WPA")
    print("Expected: works (content doesn't need WPA)")
    print("=" * 60)
    review_id = f"{args.book_id}_9gm5eWle7VrEYNiwBGaaOQ"
    content_url = (
        f"https://weread.qq.com/web/mp/content"
        f"?reviewId={urllib.parse.quote(review_id, safe='')}"
    )
    try:
        body3, status3 = http_get(content_url, args.cookie, {"Accept": "text/html,*/*"})
        has_content = "js_content" in body3
        title_match = re.search(r'og:title.*?content="(.*?)"', body3)
        title = title_match.group(1) if title_match else "(unknown)"
        print(f"  Status: {status3}, size: {len(body3)} bytes")
        print(f"  Title: {title}")
        print(f"  Has content: {has_content}")
        if has_content:
            print("  PASS: content works without WPA")
        else:
            print("  WARN: no js_content div found")
    except urllib.error.HTTPError as e:
        print(f"  FAIL: HTTP {e.code}")
    print()

    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print("- Article LIST (/web/mp/articles): requires x-wr-ticket (WPA)")
    print("- Article CONTENT (/web/mp/content): works without WPA")
    print("- Strategy: cache article list after first fetch with ticket,")
    print("  then download individual articles freely")


if __name__ == "__main__":
    main()
