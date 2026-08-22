#!/usr/bin/env bash
# Configuration contract for the live ATS.
#
# The URL smoke test proves the site serves. This proves the ATS is actually
# CONFIGURED -- that the candidate database, its enrichment, and the recruiter
# tooling built on top of it are present. An external audit found the system
# working but essentially unused: no tags, no lists, no questionnaires, no
# custom fields. These assertions are what "configured" means, so that state
# cannot silently return.
#
# Runs against production over SSM because the database is not exposed.
#
# Usage: test/smoke/ats-config.sh
set -uo pipefail

INSTANCE="i-0bc921f273f40cf6e"
PROFILE="wtf-labs"
REGION="ap-south-1"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

read -r -d '' QUERY <<'SQL' || true
SELECT 'candidates', COUNT(*) FROM candidate
UNION ALL SELECT 'custom_fields', COUNT(*) FROM extra_field_settings WHERE data_item_type = 100
UNION ALL SELECT 'enrichment_values', COUNT(*) FROM extra_field
UNION ALL SELECT 'pipeline_rows', COUNT(*) FROM candidate_joborder
UNION ALL SELECT 'job_orders', COUNT(*) FROM joborder
UNION ALL SELECT 'public_jobs', COUNT(*) FROM joborder WHERE public = 1
UNION ALL SELECT 'companies', COUNT(*) FROM company
UNION ALL SELECT 'departments', COUNT(*) FROM company_department
UNION ALL SELECT 'tags', COUNT(*) FROM tag
UNION ALL SELECT 'candidate_tags', COUNT(*) FROM candidate_tag
UNION ALL SELECT 'saved_lists', COUNT(*) FROM saved_list
UNION ALL SELECT 'list_entries', COUNT(*) FROM saved_list_entry
UNION ALL SELECT 'questionnaires', COUNT(*) FROM career_portal_questionnaire
UNION ALL SELECT 'questions', COUNT(*) FROM career_portal_questionnaire_question
UNION ALL SELECT 'mail_configured', COUNT(*) FROM settings WHERE settings_type = 1 AND setting = 'fromAddress' AND value <> ''
UNION ALL SELECT 'mail_from_name', COUNT(*) FROM settings WHERE settings_type = 1 AND setting = 'fromName' AND value <> ''
UNION ALL SELECT 'email_templates', COUNT(*) FROM email_template WHERE disabled = 0
SQL

# SSM treats each element of `commands` as one line of the generated script.
# Passing the whole block as a single multi-line element collapses the newlines,
# so line 1 becomes `cd /opt/opencats/docker DBU=$(...)` and the run dies with
# "cd: too many arguments". Hence: build the array properly, in a params file.
QUERY="$QUERY" python3 - "$WORK/params.json" <<'PY'
import json, os, sys
q = " ".join(os.environ["QUERY"].split())
lines = [
    "cd /opt/opencats/docker",
    """DBU=$(grep -oP "DATABASE_USER.\\s*,\\s*.\\K[^']+" /srv/cats/config/config.php)""",
    """DBP=$(grep -oP "DATABASE_PASS.\\s*,\\s*.\\K[^']+" /srv/cats/config/config.php)""",
    """DBN=$(grep -oP "DATABASE_NAME.\\s*,\\s*.\\K[^']+" /srv/cats/config/config.php)""",
    'docker compose -f docker-compose.prod.yml exec -T mariadb '
    'mariadb -u"$DBU" -p"$DBP" "$DBN" -N -B -e ' + json.dumps(q),
]
json.dump({"commands": lines}, open(sys.argv[1], "w"))
PY

CMD=$(aws ssm send-command --instance-ids "$INSTANCE" \
        --document-name AWS-RunShellScript \
        --parameters "file://$WORK/params.json" \
        --profile "$PROFILE" --region "$REGION" \
        --query 'Command.CommandId' --output text) || exit 1

for _ in $(seq 1 40); do
    ST=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
           --profile "$PROFILE" --region "$REGION" --query 'Status' --output text 2>/dev/null)
    [ "$ST" != "InProgress" ] && [ "$ST" != "Pending" ] && break
    sleep 3
done

OUT=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
        --profile "$PROFILE" --region "$REGION" --query 'StandardOutputContent' --output text)

if [ -z "$OUT" ]; then
    echo "no output from the database; SSM status was: $ST"
    aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
        --profile "$PROFILE" --region "$REGION" --query 'StandardErrorContent' --output text | tail -5
    exit 1
fi

get() { printf '%s\n' "$OUT" | awk -v k="$1" -F'\t' '$1==k {print $2; exit}'; }

# at_least <key> <minimum> <why it matters>
at_least() {
    local key="$1" want="$2" why="$3" got
    got=$(get "$key"); got=${got:-0}
    if [ "$got" -ge "$want" ] 2>/dev/null; then
        printf '  ok    %-18s %s\n' "$key" "$got"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %-18s %s, want >= %s   (%s)\n' "$key" "$got" "$want" "$why"
        FAIL=$((FAIL + 1))
    fi
}

echo "ATS configuration contract"
echo
echo "Candidate database:"
at_least candidates         100000  "the HR database migration is the point of this system"
at_least enrichment_values 1000000  "enrichment is what makes the candidate data worth searching"
at_least custom_fields          30  "enrichment needs somewhere to live"
at_least pipeline_rows       10000  "candidates must be matched onto open roles"

echo
echo "Hiring structure:"
at_least job_orders   15 "the eleven businesses need live vacancies"
at_least public_jobs  15 "every role should reach the public portal"
at_least companies     2 "Witness the Fitness plus Internal Postings"
at_least departments  11 "one department per WTF business"

echo
echo "Recruiter tooling (an audit found all of this empty):"
at_least tags              10 "tags are how recruiters slice 115k candidates"
at_least candidate_tags 50000 "tags are worthless unless actually applied"
at_least saved_lists       10 "talent pools save re-running the same search"
at_least list_entries    1000 "pools are worthless unless populated"
at_least questionnaires     4 "screening questions filter applicants at intake"
at_least questions         20 "a questionnaire with no questions screens nothing"

echo
echo "Outbound email:"
at_least mail_configured 1 "candidates get no confirmation without a sender"
at_least mail_from_name  1 "a bare address in the From column reads like machine output"
at_least email_templates 5 "status changes and alerts need templates"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
