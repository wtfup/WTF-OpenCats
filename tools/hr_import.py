#!/usr/bin/env python3
"""Load matched candidates from the WTF HR outreach database into the ATS.

The HR database (Postgres `wtf_hr`, 115k candidates) is where candidates are
FOUND. The ATS is where they are WORKED. This moves a matched slice of the
former into the latter and drops each person onto the right job order pipeline.

Deliberately not a full 115k dump:

  * Candidate search in this ATS runs on SQL LIKE, not Sphinx. Loading six
    figures of records would slow the search everyone actually uses.
  * The enrichment (role_family, seniority, gym-industry) is the valuable part
    and OpenCATS has no column for it, so it rides along in extra fields.
  * Consent is recorded for only a third of the HR database. Consent state
    travels with every record so nobody has to guess who may be emailed.

Matching rules live in ROLE_MATCHES: one entry per open job order, expressed in
the enrichment vocabulary rather than keyword guesswork.

Usage:
    ./tools/hr_import.py --job-ids '{"Personal Trainer": 1}' --dry-run
    ./tools/hr_import.py --job-ids "$(cat /tmp/jobids.json)" --apply
"""

import argparse
import json
import subprocess

PG_CONTAINER = "wtf-hr-db"
PG_USER = "wtf"
PG_DB = "wtf_hr"

DATA_ITEM_CANDIDATE = 100
EXTRA_FIELD_TEXT = 1

# Enrichment carried into the ATS as custom fields, in display order.
EXTRA_FIELDS = [
    "WTF Role Family",
    "WTF Seniority",
    "WTF Gym Industry",
    "WTF Primary Brand",
    "WTF Total Experience (yrs)",
    "WTF Current Designation",
    "WTF Notice Period",
    "WTF Outreach Consent",
    "WTF Source DB ID",
]

# One entry per open job order. `where` is raw SQL over the enriched columns.
ROLE_MATCHES = [
    {"job": "Personal Trainer",
     "where": "role_family = 'fitness-delivery' AND enrich_gym_industry IS TRUE "
              "AND enrich_seniority IN ('junior','mid')", "limit": 400},
    {"job": "Club Manager",
     "where": "role_family IN ('fitness-delivery','gym-membership-sales') "
              "AND enrich_gym_industry IS TRUE AND enrich_seniority IN ('senior','lead')",
     "limit": 200},
    {"job": "Membership Sales Executive",
     "where": "role_family = 'gym-membership-sales' AND enrich_gym_industry IS TRUE "
              "AND enrich_seniority IN ('junior','mid')", "limit": 400},
    {"job": "Front Desk Executive",
     "where": "role_family = 'admin-facilities' AND enrich_gym_industry IS TRUE "
              "AND enrich_seniority = 'junior'", "limit": 400},
    {"job": "Partner Success Manager",
     "where": "role_family IN ('sales-management','b2b-field-sales') "
              "AND enrich_seniority IN ('mid','senior')", "limit": 200},
    {"job": "Franchise Development Manager",
     "where": "role_family IN ('b2b-field-sales','sales-management') "
              "AND enrich_seniority IN ('senior','lead')", "limit": 150},
    {"job": "Fitness Educator",
     "where": "role_family = 'fitness-delivery' AND enrich_gym_industry IS TRUE "
              "AND enrich_seniority IN ('senior','lead','mid')", "limit": 200},
    {"job": "Performance Marketing Manager",
     "where": "role_family = 'performance-marketing' "
              "AND enrich_seniority IN ('mid','senior','lead')", "limit": 200},
    # Too few to rely on the role_family bucket; match the actual title.
    {"job": "Physiotherapist",
     "where": "(current_designation ILIKE '%physio%' OR role ILIKE '%physio%')",
     "limit": 100},
    {"job": "Operations Executive",
     "where": "role_family = 'general-ops' AND enrich_seniority IN ('junior','mid')",
     "limit": 200},
    {"job": "Clinical Nutritionist",
     "where": "(current_designation ILIKE '%nutrition%' OR current_designation ILIKE '%dietic%' "
              "OR role ILIKE '%nutrition%')", "limit": 100},
    {"job": "Category Manager",
     "where": "role_family IN ('procurement-supplychain','general-ops') "
              "AND enrich_seniority IN ('mid','senior','lead')", "limit": 150},
    {"job": "Service Technician",
     "where": "role_family = 'admin-facilities' AND enrich_seniority = 'junior' "
              "AND (current_designation ILIKE '%technic%' OR current_designation ILIKE '%engineer%' "
              "OR current_designation ILIKE '%maintenance%')", "limit": 150},
    {"job": "HR Business Partner",
     "where": "role_family = 'hr-recruiting' AND enrich_seniority IN ('mid','senior','lead')",
     "limit": 200},
    {"job": "Finance Manager",
     "where": "role_family = 'finance-accounting' AND enrich_seniority IN ('mid','senior','lead')",
     "limit": 200},
]

# psql -tA emits one row per line, so a newline inside any value shifts every
# following column and the row no longer parses. Flatten whitespace in the
# query itself rather than trying to reassemble broken rows afterwards.
def _nl(col):
    return "regexp_replace(coalesce({}::text,''), '[\\r\\n\\t]+', ' ', 'g')".format(col)


SELECT_COLUMNS = ", ".join([
    "id",
    _nl("first_name"), _nl("last_name"), _nl("email"), _nl("phone"), _nl("city"),
    _nl("current_company"), _nl("current_designation"), _nl("skills"),
    _nl("annual_salary"), _nl("linkedin_profile_url"), _nl("source"),
    _nl("headline"), _nl("role_family"), _nl("enrich_seniority"),
    "coalesce(enrich_gym_industry::text,'')",
    _nl("primary_brand"), "coalesce(exp_total_years::text,'')",
    _nl("notice_period"),
    "CASE WHEN consent_at IS NOT NULL THEN 'yes' ELSE 'no' END",
])

FIELD_NAMES = [
    "src_id", "first_name", "last_name", "email", "phone", "city",
    "current_company", "current_designation", "skills", "annual_salary",
    "linkedin", "source", "headline", "role_family", "seniority",
    "gym_industry", "primary_brand", "exp_years", "notice_period", "consent",
]

SEP = "\x1f"


def pg(sql):
    out = subprocess.run(
        ["docker", "exec", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
         "-tAF", SEP, "-c", sql],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("postgres query failed:\n" + out.stderr)
    return [ln.split(SEP) for ln in out.stdout.splitlines() if ln.strip()]


def q(v):
    if v is None:
        return "NULL"
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"


def build_sql(job_rows, job_ids, user_id=1):
    out = ["SET NAMES utf8mb4;", ""]

    for pos, name in enumerate(EXTRA_FIELDS, start=1):
        out.append(
            "INSERT INTO extra_field_settings (field_name, date_created, data_item_type, "
            "extra_field_type, position) SELECT {n}, NOW(), {t}, {ft}, {p} FROM DUAL "
            "WHERE NOT EXISTS (SELECT 1 FROM (SELECT field_name, data_item_type FROM "
            "extra_field_settings) s WHERE s.field_name = {n} AND s.data_item_type = {t});"
            .format(n=q(name), t=DATA_ITEM_CANDIDATE, ft=EXTRA_FIELD_TEXT, p=pos))
    out.append("")

    for job, rows in job_rows.items():
        jid = job_ids.get(job)
        if not jid:
            out.append("/* skipped {}: no matching job order id */".format(job))
            continue
        out.append("/* ---- {} -> job order {} : {} candidates ---- */".format(
            job, jid, len(rows)))
        for r in rows:
            d = dict(zip(FIELD_NAMES, r))
            email = d["email"].strip()
            if not email:
                continue
            notes = " | ".join(x for x in [
                d["headline"],
                ("Current: " + d["current_designation"]) if d["current_designation"] else "",
                ("Source: " + d["source"]) if d["source"] else "",
                "Imported from WTF HR database (id " + d["src_id"] + ")",
            ] if x)

            out.append(
                "INSERT INTO candidate (last_name, first_name, phone_cell, city, state, "
                "country, source, notes, key_skills, current_employer, entered_by, owner, "
                "date_created, date_modified, email1, web_site, current_pay, is_active, "
                "is_admin_hidden, is_hot) SELECT {ln},{fn},{ph},{ci},'','IN',{src},{no},{ks},"
                "{ce},{u},{u},NOW(),NOW(),{em},{ws},{pay},1,0,0 FROM DUAL WHERE NOT EXISTS "
                "(SELECT 1 FROM (SELECT email1 FROM candidate) c WHERE c.email1 = {em});".format(
                    ln=q(d["last_name"] or "-"), fn=q(d["first_name"] or "-"),
                    ph=q(d["phone"][:30]), ci=q(d["city"][:60]), src=q("WTF HR DB"),
                    no=q(notes[:4000]), ks=q(d["skills"][:2000]),
                    ce=q(d["current_company"][:120]), u=user_id, em=q(email),
                    ws=q(d["linkedin"][:200]), pay=q(d["annual_salary"][:60])))

            for fname, fval in [
                ("WTF Role Family", d["role_family"]),
                ("WTF Seniority", d["seniority"]),
                ("WTF Gym Industry", "yes" if d["gym_industry"] == "t" else "no"),
                ("WTF Primary Brand", d["primary_brand"]),
                ("WTF Total Experience (yrs)", d["exp_years"]),
                ("WTF Current Designation", d["current_designation"]),
                ("WTF Notice Period", d["notice_period"]),
                ("WTF Outreach Consent", d["consent"]),
                ("WTF Source DB ID", d["src_id"]),
            ]:
                if not fval:
                    continue
                out.append(
                    "INSERT INTO extra_field (data_item_id, field_name, value, data_item_type) "
                    "SELECT c.candidate_id, {f}, {v}, {t} FROM candidate c WHERE c.email1 = {em} "
                    "AND NOT EXISTS (SELECT 1 FROM (SELECT data_item_id, field_name FROM "
                    "extra_field) e WHERE e.data_item_id = c.candidate_id AND e.field_name = {f});"
                    .format(f=q(fname), v=q(str(fval)[:2000]),
                            t=DATA_ITEM_CANDIDATE, em=q(email)))

            out.append(
                "INSERT INTO candidate_joborder (candidate_id, joborder_id, site_id, status, "
                "date_created, date_modified, rating_value, added_by) SELECT c.candidate_id, "
                "{j}, 1, 100, NOW(), NOW(), 0, {u} FROM candidate c WHERE c.email1 = {em} "
                "AND NOT EXISTS (SELECT 1 FROM (SELECT candidate_id, joborder_id FROM "
                "candidate_joborder) p WHERE p.candidate_id = c.candidate_id "
                "AND p.joborder_id = {j});".format(j=jid, u=user_id, em=q(email)))
        out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--job-ids", required=True, help="JSON map: job title -> joborder_id")
    ap.add_argument("--only")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", default="/tmp/hr_import.sql")
    args = ap.parse_args()

    job_ids = json.loads(args.job_ids)
    matches = [m for m in ROLE_MATCHES if not args.only or m["job"] == args.only]

    job_rows, total, seen = {}, 0, set()
    for m in matches:
        rows = pg("SELECT {c} FROM candidates WHERE email IS NOT NULL AND email <> '' "
                  "AND ({w}) ORDER BY (last_contacted_at IS NULL) DESC, "
                  "coalesce(priority_score,0) DESC, id LIMIT {l};".format(
                      c=SELECT_COLUMNS, w=m["where"], l=m["limit"]))
        fresh = []
        for r in rows:
            if len(r) != len(FIELD_NAMES):
                continue
            e = r[3].strip().lower()
            if not e or e in seen:
                continue
            seen.add(e)
            fresh.append(r)
        job_rows[m["job"]] = fresh
        total += len(fresh)
        print("{:<32} {:>5} matched".format(m["job"], len(fresh)))

    print("\ntotal unique candidates: {}".format(total))
    script = build_sql(job_rows, job_ids)
    with open(args.out, "w") as fh:
        fh.write(script)
    print("SQL written to {} ({} statements, {} KB)".format(
        args.out, script.count(";"), len(script) // 1024))
    if not args.apply:
        print("\ndry run -- nothing applied")


if __name__ == "__main__":
    main()
