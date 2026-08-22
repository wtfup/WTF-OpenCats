#!/usr/bin/env bash
# URL routing contract for the deployed WTF-OpenCats site.
#
# Guards the bug where php_fastcgi's default try_files ended in a bare
# "index.php" catch-all, so ANY unknown path was served by the root index.php.
# The app rendered, but the browser's base URL was a directory that does not
# exist, OpenCATS' relative asset paths resolved against it, and every
# stylesheet/script/image 404'd -- an unstyled page that looks like a dead
# product. Recorded failure before the fix:
#
#   /careers/login  code=200   (expected 404)
#   /login          code=200   (expected 302)
#   /foo/bar        code=200   (expected 404)
#
# Usage: test/smoke/url-routing.sh [base-url]
set -uo pipefail

BASE="${1:-https://careers.wtfgyms.com}"
PASS=0
FAIL=0

# expect <path> <expected-code> <description> [expected-location-substring]
expect() {
    local path="$1" want="$2" desc="$3" loc_want="${4:-}"
    local out code loc
    out=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE$path" 2>/dev/null)
    code="${out%% *}"
    loc="${out#* }"

    if [ "$code" != "$want" ]; then
        printf '  FAIL  %-34s got %s, want %s   (%s)\n' "$path" "$code" "$want" "$desc"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ -n "$loc_want" ] && [[ "$loc" != *"$loc_want"* ]]; then
        printf '  FAIL  %-34s redirects to %s, want *%s*\n' "$path" "$loc" "$loc_want"
        FAIL=$((FAIL + 1))
        return
    fi
    printf '  ok    %-34s %s\n' "$path" "$code"
    PASS=$((PASS + 1))
}

echo "URL routing contract against $BASE"

echo
echo "Unknown paths must 404, not render an unstyled app page:"
expect /careers/login          404 "the exact URL that triggered the bug report"
expect /careers/login/         404 "trailing-slash variant"
expect /careers/dashboard      404 "another plausible guess under /careers"
expect /foo/bar                404 "arbitrary junk path"
expect /admin                  404 "common guess, must not leak the ATS"

echo
echo "Real entry points must work:"
expect /                       302 "bare host sends candidates to the job board" /careers/
expect /careers/               200 "public job board"
expect "/index.php?m=login"    200 "canonical ATS login"

echo
echo "Staff shortcuts must redirect to the ATS login:"
expect /login                  302 "memorable login URL"      "m=login"
expect /login/                 302 "trailing-slash variant"   "m=login"
expect /ats                    302 "alternate shortcut"       "m=login"
expect /ats/                   302 "trailing-slash variant"   "m=login"

echo
echo "Public feeds must serve, not 500:"
expect /rss/                   200 "job feed linked from the career portal footer"

echo
echo "Security blocks must stay closed:"
expect /attachments/           404 "candidate resumes"
expect /config.php             404 "database credentials"
expect /installwizard.php      404 "installer"
expect /db/cats_schema.sql     404 "schema dump"
expect /.git/config            404 "git metadata"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
