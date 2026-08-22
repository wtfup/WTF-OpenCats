#!/usr/bin/env python3
"""Migrate the entire WTF HR candidate database into the ATS.

All 115k candidates, not a sample. Everyone becomes a searchable ATS record;
the ones who match an open role are additionally placed on that role's pipeline.

Why a staging table instead of INSERT statements: 115k candidates plus their
enrichment is roughly a million rows. Emitting that as individual INSERTs
produces a ~400 MB script that takes hours to apply. Postgres COPY (text
format) and MySQL LOAD DATA share the same escaping convention -- tab
delimited, \\N for NULL, backslash escapes -- so the export streams straight
into a staging table, and the real tables are then populated with a handful of
set-based INSERT ... SELECT statements.

Everything is idempotent: re-running skips candidates whose email is already
present, skips extra fields already attached, and skips pipeline rows that
already exist.

Steps:
    1. export   -- pull the whole candidate table out of Postgres as TSV
    2. stage    -- create the staging table and LOAD DATA the TSV into it
    3. transform-- populate candidate, extra_field and candidate_joborder
    4. index    -- add the indexes the ATS search actually needs at this size
"""

import argparse
import json
import subprocess

PG_CONTAINER = "wtf-hr-db"
PG_USER = "wtf"
PG_DB = "wtf_hr"

DATA_ITEM_CANDIDATE = 100
EXTRA_FIELD_TEXT = 1

# Columns pulled from Postgres, in order. Kept in one place because the staging
# DDL, the COPY and the LOAD DATA column list must agree exactly.
COLUMNS = [
    ("src_id",              "id::text"),
    ("first_name",          "first_name"),
    ("last_name",           "last_name"),
    ("email",               "lower(btrim(email))"),
    ("phone",               "phone"),
    ("city",                "city"),
    ("current_company",     "current_company"),
    ("current_designation", "current_designation"),
    ("skills",              "left(skills, 2000)"),
    ("annual_salary",       "annual_salary"),
    ("linkedin",            "linkedin_profile_url"),
    ("source",              "source"),
    ("headline",            "left(headline, 500)"),
    ("summary",             "left(summary, 2000)"),
    # --- enrichment ---------------------------------------------------------
    ("role_family",         "role_family"),
    ("seniority",           "enrich_seniority"),
    ("gym_industry",        "enrich_gym_industry::text"),
    ("primary_brand",       "primary_brand"),
    ("primary_brand_role",  "primary_brand_role"),
    ("brand_fits",          "left(brand_fits::text, 1000)"),
    ("fit_score",           "fit_score::text"),
    ("enrich_pillar",       "enrich_pillar"),
    ("enrich_one_line",     "left(enrich_one_line, 1000)"),
    ("enrich_confidence",   "enrich_confidence"),
    ("enrich_profile_id",   "enrich_profile_id"),
    ("enrich_brand",        "enrich_brand"),
    ("enrich_department",   "enrich_department"),
    ("enrich_salary_lpa",   "enrich_salary_lpa::text"),
    ("enrich_notice_days",  "enrich_notice_days::text"),
    ("exp_years",           "coalesce(exp_total_years, enrich_years)::text"),
    ("exp_fitness_years",   "exp_fitness_years::text"),
    ("experience_years",    "experience_years"),
    ("fitness_subrole",     "fitness_subrole"),
    ("ld_subrole",          "ld_subrole"),
    ("priority_tier",       "priority_p1_p4"),
    ("priority_score",      "priority_score::text"),
    ("industry",            "industry"),
    ("department",          "department"),
    ("preferred_locations", "left(preferred_locations, 500)"),
    ("notice_period",       "notice_period"),
    ("ug_degree",           "ug_degree"),
    ("ug_specialization",   "ug_specialization"),
    ("pg_degree",           "pg_degree"),
    ("hr_status",           "status"),
    ("consent",             "CASE WHEN consent_at IS NOT NULL THEN 'yes' ELSE 'no' END"),
    ("last_contacted",      "to_char(last_contacted_at, 'YYYY-MM-DD')"),
    ("last_reply",          "to_char(last_reply_at, 'YYYY-MM-DD')"),
]

STAGING = "wtf_hr_stage"

# Enrichment promoted into ATS custom fields.
EXTRA_FIELDS = [
    ("WTF Role Family",            "role_family"),
    ("WTF Seniority",              "seniority"),
    ("WTF Gym Industry",           "gym_industry"),
    ("WTF Fitness Subrole",        "fitness_subrole"),
    ("WTF L&D Subrole",            "ld_subrole"),
    ("WTF Primary Brand",          "primary_brand"),
    ("WTF Primary Brand Role",     "primary_brand_role"),
    ("WTF Brand Fits",             "brand_fits"),
    ("WTF Fit Score",              "fit_score"),
    ("WTF Pillar",                 "enrich_pillar"),
    ("WTF AI Summary",             "enrich_one_line"),
    ("WTF Enrich Confidence",      "enrich_confidence"),
    ("WTF Profile ID",             "enrich_profile_id"),
    ("WTF Enrich Brand",           "enrich_brand"),
    ("WTF Enrich Department",      "enrich_department"),
    ("WTF Salary (LPA)",           "enrich_salary_lpa"),
    ("WTF Notice (days)",          "enrich_notice_days"),
    ("WTF Total Experience (yrs)", "exp_years"),
    ("WTF Fitness Experience (yrs)", "exp_fitness_years"),
    ("WTF Experience (raw)",       "experience_years"),
    ("WTF Priority Tier",          "priority_tier"),
    ("WTF Priority Score",         "priority_score"),
    ("WTF Industry",               "industry"),
    ("WTF Department",             "department"),
    ("WTF Preferred Locations",    "preferred_locations"),
    ("WTF Notice Period",          "notice_period"),
    ("WTF UG Degree",              "ug_degree"),
    ("WTF UG Specialization",      "ug_specialization"),
    ("WTF PG Degree",              "pg_degree"),
    ("WTF Current Designation",    "current_designation"),
    ("WTF Outreach Status",        "hr_status"),
    ("WTF Outreach Consent",       "consent"),
    ("WTF Last Contacted",         "last_contacted"),
    ("WTF Last Reply",             "last_reply"),
    ("WTF Source DB ID",           "src_id"),
]

# Which staged candidates belong on which open role's pipeline. Expressed in
# the enrichment vocabulary rather than keyword guesswork. A candidate can
# legitimately match more than one role.
ROLE_MATCHES = [
    ("Personal Trainer",
     "role_family = 'fitness-delivery' AND gym_industry = 'true' "
     "AND seniority IN ('junior','mid')"),
    ("Club Manager",
     "role_family IN ('fitness-delivery','gym-membership-sales') "
     "AND gym_industry = 'true' AND seniority IN ('senior','lead')"),
    ("Membership Sales Executive",
     "role_family = 'gym-membership-sales' AND gym_industry = 'true' "
     "AND seniority IN ('junior','mid')"),
    ("Front Desk Executive",
     "role_family = 'admin-facilities' AND gym_industry = 'true' "
     "AND seniority = 'junior'"),
    ("Partner Success Manager",
     "role_family IN ('sales-management','b2b-field-sales') "
     "AND seniority IN ('mid','senior')"),
    ("Franchise Development Manager",
     "role_family IN ('b2b-field-sales','sales-management') "
     "AND seniority IN ('senior','lead')"),
    ("Fitness Educator",
     "role_family = 'fitness-delivery' AND gym_industry = 'true' "
     "AND seniority IN ('senior','lead','mid')"),
    ("Performance Marketing Manager",
     "role_family = 'performance-marketing' AND seniority IN ('mid','senior','lead')"),
    ("Physiotherapist",
     "current_designation LIKE '%physio%'"),
    ("Operations Executive",
     "role_family = 'general-ops' AND seniority IN ('junior','mid')"),
    ("Clinical Nutritionist",
     "(current_designation LIKE '%nutrition%' OR current_designation LIKE '%dietic%')"),
    ("Category Manager",
     "role_family IN ('procurement-supplychain','general-ops') "
     "AND seniority IN ('mid','senior','lead')"),
    ("Service Technician",
     "role_family = 'admin-facilities' AND seniority = 'junior' "
     "AND (current_designation LIKE '%technic%' OR current_designation LIKE '%engineer%' "
     "OR current_designation LIKE '%maintenance%')"),
    ("HR Business Partner",
     "role_family = 'hr-recruiting' AND seniority IN ('mid','senior','lead')"),
    ("Finance Manager",
     "role_family = 'finance-accounting' AND seniority IN ('mid','senior','lead')"),
]


def export_tsv(path):
    """COPY the whole candidate table out of Postgres in MySQL-compatible TSV."""
    select = ", ".join(expr for _, expr in COLUMNS)
    sql = ("COPY (SELECT {} FROM candidates WHERE email IS NOT NULL "
           "AND btrim(email) <> '') TO STDOUT").format(select)
    with open(path, "wb") as fh:
        p = subprocess.run(
            ["docker", "exec", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
             "-c", sql],
            stdout=fh, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise SystemExit("export failed:\n" + p.stderr.decode())
    return sum(1 for _ in open(path, "rb"))


def staging_ddl():
    cols = ",\n  ".join("`{}` TEXT COLLATE utf8mb4_unicode_ci".format(name)
                        for name, _ in COLUMNS)
    return (
        "DROP TABLE IF EXISTS `{s}`;\n"
        "CREATE TABLE `{s}` (\n  {c}\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 "
        "COLLATE=utf8mb4_unicode_ci;\n"
    ).format(s=STAGING, c=cols)


def load_sql(remote_tsv):
    cols = ", ".join("`{}`".format(name) for name, _ in COLUMNS)
    return (
        "LOAD DATA LOCAL INFILE '{f}' INTO TABLE `{s}` "
        "CHARACTER SET utf8mb4 ({c});\n"
        "ALTER TABLE `{s}` ADD INDEX idx_email (email(191));\n"
    ).format(f=remote_tsv, s=STAGING, c=cols)


def transform_sql(job_ids, user_id=1):
    out = []

    for pos, (name, _) in enumerate(EXTRA_FIELDS, start=1):
        out.append(
            "INSERT INTO extra_field_settings (field_name, date_created, data_item_type, "
            "extra_field_type, position) SELECT '{n}', NOW(), {t}, {ft}, {p} FROM DUAL "
            "WHERE NOT EXISTS (SELECT 1 FROM (SELECT field_name, data_item_type FROM "
            "extra_field_settings) s WHERE s.field_name = '{n}' AND s.data_item_type = {t});"
            .format(n=name, t=DATA_ITEM_CANDIDATE, ft=EXTRA_FIELD_TEXT, p=pos))

    # Candidates. Deduplicated on email against what is already in the ATS, and
    # against duplicates inside the export itself (GROUP BY email).
    out.append("""
INSERT INTO candidate
  (last_name, first_name, phone_cell, city, country, source, notes, key_skills,
   current_employer, entered_by, owner, date_created, date_modified, email1,
   web_site, current_pay, is_active, is_admin_hidden, is_hot)
SELECT
  /* Every VARCHAR is truncated to its declared width. The HR export carries
     free-text that is routinely longer than the ATS columns -- names with
     qualifications appended, multi-line city strings, pasted salary text --
     and MariaDB rejects the whole statement on the first overflow rather than
     truncating. Both name columns are also NOT NULL and have blanks in the
     source, hence the '-' fallback. */
  LEFT(COALESCE(NULLIF(TRIM(s.last_name),''), '-'), 64),
  LEFT(COALESCE(NULLIF(TRIM(s.first_name),''), '-'), 64),
  LEFT(s.phone, 40), LEFT(s.city, 64), 'IN', LEFT('WTF HR DB', 128),
  TRIM(BOTH ' | ' FROM CONCAT_WS(' | ',
      NULLIF(s.headline,''), NULLIF(s.summary,''), NULLIF(s.enrich_one_line,''),
      CONCAT('Imported from WTF HR database (id ', s.src_id, ')'))),
  LEFT(s.skills, 2000), LEFT(s.current_company, 128),
  {u}, {u}, NOW(), NOW(), LEFT(s.email, 128), LEFT(s.linkedin, 128),
  LEFT(s.annual_salary, 64), 1, 0, 0
FROM (SELECT * FROM `{s}` GROUP BY email) s
LEFT JOIN candidate c ON c.email1 = s.email
WHERE c.candidate_id IS NULL;""".format(u=user_id, s=STAGING))

    # Enrichment as extra fields, one statement per field, non-empty only.
    for name, col in EXTRA_FIELDS:
        out.append("""
INSERT INTO extra_field (data_item_id, field_name, value, data_item_type)
SELECT c.candidate_id, '{n}', LEFT(s.{col},2000), {t}
FROM (SELECT email, {col} FROM `{s}` GROUP BY email) s
JOIN candidate c ON c.email1 = s.email
LEFT JOIN extra_field e
  ON e.data_item_id = c.candidate_id AND e.field_name = '{n}'
WHERE e.extra_field_id IS NULL
  AND s.{col} IS NOT NULL AND s.{col} <> '' AND s.{col} <> '\\\\N';"""
                   .format(n=name, col=col, t=DATA_ITEM_CANDIDATE, s=STAGING))

    # Pipelines for candidates who match an open role. Status 100 = No Contact.
    for job, where in ROLE_MATCHES:
        jid = job_ids.get(job)
        if not jid:
            out.append("/* no job order id for {} -- skipped */".format(job))
            continue
        out.append("""
INSERT INTO candidate_joborder
  (candidate_id, joborder_id, site_id, status, date_created, date_modified,
   rating_value, added_by)
SELECT c.candidate_id, {j}, 1, 100, NOW(), NOW(), 0, {u}
FROM (SELECT email FROM `{s}` WHERE {w} GROUP BY email) s
JOIN candidate c ON c.email1 = s.email
LEFT JOIN candidate_joborder p
  ON p.candidate_id = c.candidate_id AND p.joborder_id = {j}
WHERE p.candidate_joborder_id IS NULL;   /* {job} */""".format(
            j=jid, u=user_id, s=STAGING, w=where, job=job))

    return "\n".join(out) + "\n"


def index_sql():
    """Indexes that matter once the table is six figures rather than three."""
    return """
/* Candidate search filters on these; without indexes every lookup is a scan. */
CREATE INDEX idx_cand_email1   ON candidate (email1(191));
CREATE INDEX idx_cand_lastname ON candidate (last_name(64));
CREATE INDEX idx_cand_city     ON candidate (city(48));
CREATE INDEX idx_cand_employer ON candidate (current_employer(64));
CREATE INDEX idx_ef_lookup     ON extra_field (field_name(64), value(64));
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--job-ids", required=True)
    ap.add_argument("--tsv", default="/tmp/wtf_hr_candidates.tsv")
    ap.add_argument("--remote-tsv", default="/srv/cats/import/wtf_hr_candidates.tsv")
    ap.add_argument("--sql-out", default="/tmp/wtf_hr_migrate.sql")
    ap.add_argument("--skip-export", action="store_true")
    args = ap.parse_args()

    job_ids = json.loads(args.job_ids)

    if not args.skip_export:
        n = export_tsv(args.tsv)
        print("exported {} candidate rows -> {}".format(n, args.tsv))

    script = (staging_ddl() + "\n" + load_sql(args.remote_tsv) + "\n"
              + transform_sql(job_ids) + "\n" + index_sql())
    with open(args.sql_out, "w") as fh:
        fh.write(script)
    print("migration SQL -> {} ({} KB)".format(args.sql_out, len(script) // 1024))
    print("\nrole -> pipeline rules: {}".format(len(ROLE_MATCHES)))
    print("extra fields per candidate: {}".format(len(EXTRA_FIELDS)))


if __name__ == "__main__":
    main()
