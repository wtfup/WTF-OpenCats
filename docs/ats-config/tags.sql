-- =============================================================================
-- WTF (Witness the Fitness Private Limited) — Candidate Tag Taxonomy Seed
-- Target: OpenCATS 0.10.0 on MariaDB, database `cats`
-- =============================================================================
--
-- WHAT THIS FILE DOES
--   1. Adds a UNIQUE index on candidate_tag(candidate_id, tag_id) if missing,
--      so a candidate can never be linked to the same tag twice and so
--      INSERT IGNORE (below) has something to IGNORE against.
--   2. Seeds a two-level tag taxonomy (6 parent "group" tags, 34 child tags)
--      under `tag`, one child set per AI-enrichment field already present
--      in `extra_field` (data_item_type = 100 = candidate).
--   3. Bulk-applies the appropriate child tag to every one of the ~115,215
--      migrated candidates by joining `extra_field` straight to `tag`,
--      with no per-row / correlated subqueries.
--
-- SAFETY / RE-RUN BEHAVIOUR
--   Every statement in this file is idempotent:
--     - Tag creation only inserts a row when no tag with that exact title
--       exists yet (see the MariaDB gotcha explained just below).
--     - Bulk tagging uses INSERT IGNORE against the new UNIQUE index, so
--       re-running the file after candidates/enrichment change simply
--       fills in gaps and touches nothing that is already tagged.
--   Statements are NOT wrapped in one big transaction. The ALTER TABLE step
--   causes an implicit commit in InnoDB anyway (so a surrounding
--   transaction would buy nothing), and keeping each INSERT independent
--   means that if this script is killed partway through on the t3.small
--   box, whatever already ran stays committed and a re-run safely picks
--   up where it left off — nothing needs to be rolled back or replayed
--   from scratch.
--
-- THE MariaDB SELF-REFERENCE GOTCHA (read this before touching the tag
-- inserts below)
--   MariaDB/MySQL refuse "INSERT INTO tag ... SELECT ... FROM tag" style
--   statements — including when `tag` only appears inside a WHERE NOT
--   EXISTS or scalar subquery, not literally in the outer FROM — with:
--     ERROR 1093 (HY000): You can't specify target table 'tag' for update
--     in FROM clause
--   The fix used throughout this file is to wrap every reference to `tag`
--   that appears inside one of these INSERT ... SELECT statements in its
--   own derived table, e.g. `(SELECT title FROM tag) t`. MariaDB
--   materializes the derived table first, which decouples it from the
--   "same table as the INSERT target" check. This is why every existence
--   check and every parent-id lookup below looks one layer more nested
--   than you'd write by hand — that nesting is load-bearing, not
--   decorative.
--
-- PERFORMANCE NOTES (t3.small, 1.9 GB RAM, 115,215 candidates,
-- ~2.1M extra_field rows)
--   - The bulk-apply statements are each a single INSERT ... SELECT with
--     plain equality joins (extra_field -> small literal map -> tag).
--     There is no correlated subquery per candidate and no GROUP BY
--     anywhere in this file — every "many rows in, many rows out"
--     operation is a flat join, so the optimizer can do it in one pass.
--   - Each bulk-apply statement filters extra_field by `field_name`
--     first (assumed indexed) and `data_item_type = 100` second (very
--     low cardinality), which narrows 2.1M rows down to ~115k before any
--     join happens.
--   - The literal "map" derived tables (UNION ALL of a handful of rows)
--     are tiny (2-16 rows) and get hashed/materialized once per
--     statement, not once per candidate.
--   - `tag` itself stays well under a few hundred rows even with this
--     taxonomy applied, so the `JOIN tag t ON t.title = ...` in the
--     bulk-apply statements is effectively free regardless of candidate
--     volume — it does not need (and MariaDB does not require) an index
--     on tag.title to perform well at this scale.
--
-- HOW TO RUN
--   mariadb -u <user> -p cats < tags.sql
--   (or) mysql -u <user> -p cats < tags.sql
--   The stored procedure block below uses DELIMITER, which is a client-
--   side directive understood by the mariadb/mysql CLI clients. If you
--   are piping this file through a driver that does not honor DELIMITER
--   (e.g. a naive multi-statement API call), run that one block manually
--   first — everything after it is plain, delimiter-free SQL.
--
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1: UNIQUE index on candidate_tag(candidate_id, tag_id)
-- -----------------------------------------------------------------------------
-- Why a stored procedure instead of `ALTER TABLE ... ADD INDEX IF NOT EXISTS`:
-- that clause is only reliable on fairly recent MariaDB (10.5+), and OpenCATS
-- installs in the wild sit on a wide range of MariaDB versions. Checking
-- INFORMATION_SCHEMA.STATISTICS ourselves works identically on every MariaDB
-- version this ATS is realistically deployed on, and gives the same
-- idempotent guarantee.

DELIMITER $$

DROP PROCEDURE IF EXISTS wtf_tags_add_candidate_tag_unique_index $$

CREATE PROCEDURE wtf_tags_add_candidate_tag_unique_index()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME   = 'candidate_tag'
          AND INDEX_NAME   = 'uq_candidate_tag_candidate_id_tag_id'
    ) THEN
        ALTER TABLE candidate_tag
            ADD UNIQUE INDEX uq_candidate_tag_candidate_id_tag_id (candidate_id, tag_id);
    END IF;
END $$

DELIMITER ;

CALL wtf_tags_add_candidate_tag_unique_index();
DROP PROCEDURE IF EXISTS wtf_tags_add_candidate_tag_unique_index;


-- -----------------------------------------------------------------------------
-- STEP 2: Parent (group) tags
-- -----------------------------------------------------------------------------
-- Six top-level groups, one per enrichment field. tag_parent_id is NULL for
-- all of them (they ARE the top level). All titles are namespaced "WTF:" /
-- "WTF <Group>:" so they can never collide with a recruiter's own free-text
-- tags (e.g. a human-created tag literally titled "Senior") — collision would
-- silently reuse the wrong tag_id via the idempotency check below, since that
-- check keys purely on exact title match against the whole `tag` table.

INSERT INTO tag (tag_parent_id, title, description)
SELECT NULL,
       'WTF: Business Vertical',
       'Line-of-business / role-family classification derived from AI enrichment (extra_field "WTF Role Family").'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF: Business Vertical');

INSERT INTO tag (tag_parent_id, title, description)
SELECT NULL,
       'WTF: Seniority',
       'Candidate seniority level derived from AI enrichment (extra_field "WTF Seniority").'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF: Seniority');

INSERT INTO tag (tag_parent_id, title, description)
SELECT NULL,
       'WTF: Industry',
       'Whether the candidate''s background is in the gym/fitness industry, derived from AI enrichment (extra_field "WTF Gym Industry").'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF: Industry');

INSERT INTO tag (tag_parent_id, title, description)
SELECT NULL,
       'WTF: Priority',
       'Outreach priority tier assigned during AI enrichment (extra_field "WTF Priority Tier").'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF: Priority');

INSERT INTO tag (tag_parent_id, title, description)
SELECT NULL,
       'WTF: Outreach',
       'Whether the candidate has given consent to be contacted, derived from AI enrichment (extra_field "WTF Outreach Consent").'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF: Outreach');

INSERT INTO tag (tag_parent_id, title, description)
SELECT NULL,
       'WTF: Fitness Speciality',
       'Gym-floor / fitness role specialization, derived from AI enrichment (extra_field "WTF Fitness Subrole").'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF: Fitness Speciality');


-- -----------------------------------------------------------------------------
-- STEP 3: Child tags, one per enrichment value, linked to their parent group
-- -----------------------------------------------------------------------------
-- Pattern for every child tag:
--   tag_parent_id = (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p
--                     WHERE p.title = '<parent title>')
--   guarded by the same derived-table NOT EXISTS idiom as the parents.
-- The parent-id lookup also has to go through a derived table for the exact
-- same reason as the existence check (see the gotcha note at the top of this
-- file) — `tag` cannot be referenced directly anywhere inside a SELECT that
-- feeds an INSERT INTO tag.

-- 3a. WTF: Business Vertical  (from extra_field 'WTF Role Family', 16 values)

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Fitness Delivery',
       'WTF Role Family = fitness-delivery'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Fitness Delivery');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Gym Membership Sales',
       'WTF Role Family = gym-membership-sales'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Gym Membership Sales');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Admin & Facilities',
       'WTF Role Family = admin-facilities'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Admin & Facilities');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: HR & Recruiting',
       'WTF Role Family = hr-recruiting'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: HR & Recruiting');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Software & Product',
       'WTF Role Family = software-product'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Software & Product');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Brand, Content & Creative',
       'WTF Role Family = brand-content-creative'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Brand, Content & Creative');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Data & Analytics',
       'WTF Role Family = data-analytics'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Data & Analytics');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: B2B Field Sales',
       'WTF Role Family = b2b-field-sales'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: B2B Field Sales');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Finance & Accounting',
       'WTF Role Family = finance-accounting'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Finance & Accounting');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Sales Management',
       'WTF Role Family = sales-management'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Sales Management');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Legal & Compliance',
       'WTF Role Family = legal-compliance'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Legal & Compliance');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: General Ops',
       'WTF Role Family = general-ops'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: General Ops');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Performance Marketing',
       'WTF Role Family = performance-marketing'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Performance Marketing');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Customer Support',
       'WTF Role Family = customer-support'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Customer Support');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Procurement & Supply Chain',
       'WTF Role Family = procurement-supplychain'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Procurement & Supply Chain');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Business Vertical'),
       'WTF Vertical: Unclassified',
       'WTF Role Family = unclassified (enrichment could not confidently classify this candidate)'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Vertical: Unclassified');

-- 3b. WTF: Seniority  (from extra_field 'WTF Seniority', 4 values)

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Seniority'),
       'WTF Seniority: Junior',
       'WTF Seniority = junior'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Seniority: Junior');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Seniority'),
       'WTF Seniority: Mid',
       'WTF Seniority = mid'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Seniority: Mid');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Seniority'),
       'WTF Seniority: Senior',
       'WTF Seniority = senior'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Seniority: Senior');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Seniority'),
       'WTF Seniority: Lead',
       'WTF Seniority = lead'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Seniority: Lead');

-- 3c. WTF: Industry  (from extra_field 'WTF Gym Industry', 2 values: 'true'/'false')

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Industry'),
       'WTF Industry: Gym/Fitness Background',
       'WTF Gym Industry = true'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Industry: Gym/Fitness Background');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Industry'),
       'WTF Industry: Non-Gym Background',
       'WTF Gym Industry = false'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Industry: Non-Gym Background');

-- 3d. WTF: Priority  (from extra_field 'WTF Priority Tier', 4 values)

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Priority'),
       'WTF Priority: P1',
       'WTF Priority Tier = P1'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Priority: P1');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Priority'),
       'WTF Priority: P2',
       'WTF Priority Tier = P2'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Priority: P2');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Priority'),
       'WTF Priority: P3',
       'WTF Priority Tier = P3'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Priority: P3');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Priority'),
       'WTF Priority: P4',
       'WTF Priority Tier = P4'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Priority: P4');

-- 3e. WTF: Outreach  (from extra_field 'WTF Outreach Consent', 2 values: 'yes'/'no')

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Outreach'),
       'WTF Outreach: Consent Given',
       'WTF Outreach Consent = yes'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Outreach: Consent Given');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Outreach'),
       'WTF Outreach: No Consent',
       'WTF Outreach Consent = no'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Outreach: No Consent');

-- 3f. WTF: Fitness Speciality  (from extra_field 'WTF Fitness Subrole', 6 values)

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Fitness Speciality'),
       'WTF Fitness Role: Personal Trainer',
       'WTF Fitness Subrole = personal-trainer'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Fitness Role: Personal Trainer');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Fitness Speciality'),
       'WTF Fitness Role: Group Fitness Coach',
       'WTF Fitness Subrole = group-fitness-coach'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Fitness Role: Group Fitness Coach');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Fitness Speciality'),
       'WTF Fitness Role: Floor Fitness Manager',
       'WTF Fitness Subrole = floor-fitness-manager'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Fitness Role: Floor Fitness Manager');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Fitness Speciality'),
       'WTF Fitness Role: Head Coach',
       'WTF Fitness Subrole = head-coach'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Fitness Role: Head Coach');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Fitness Speciality'),
       'WTF Fitness Role: Area Fitness Head',
       'WTF Fitness Subrole = area-fitness-head'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Fitness Role: Area Fitness Head');

INSERT INTO tag (tag_parent_id, title, description)
SELECT (SELECT tag_id FROM (SELECT tag_id, title FROM tag) p WHERE p.title = 'WTF: Fitness Speciality'),
       'WTF Fitness Role: Not Gym Fitness',
       'WTF Fitness Subrole = not-gym-fitness (candidate is not in a gym-floor fitness role)'
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM tag) t WHERE t.title = 'WTF Fitness Role: Not Gym Fitness');


-- -----------------------------------------------------------------------------
-- STEP 4: Bulk-apply tags to all 115,215 candidates from their extra_field
-- enrichment
-- -----------------------------------------------------------------------------
-- `tag` is NOT the INSERT target in this section (`candidate_tag` is), so
-- none of these SELECTs need the derived-table workaround from Step 3 —
-- referencing `tag` directly here is fine.
--
-- Each block is: extra_field (filtered to one field_name + data_item_type =
-- 100) JOIN a small literal value->tag_title map JOIN tag. That is a flat,
-- three-way equality join with no correlated subquery and no GROUP BY, and
-- it is safe to re-run because of INSERT IGNORE + the UNIQUE index added in
-- Step 1.

-- 4a. WTF Role Family -> WTF: Business Vertical

INSERT IGNORE INTO candidate_tag (candidate_id, tag_id)
SELECT ef.data_item_id, t.tag_id
FROM extra_field ef
JOIN (
    SELECT 'fitness-delivery'      AS raw_value, 'WTF Vertical: Fitness Delivery'           AS tag_title UNION ALL
    SELECT 'gym-membership-sales',                'WTF Vertical: Gym Membership Sales'                    UNION ALL
    SELECT 'admin-facilities',                    'WTF Vertical: Admin & Facilities'                      UNION ALL
    SELECT 'hr-recruiting',                       'WTF Vertical: HR & Recruiting'                         UNION ALL
    SELECT 'software-product',                    'WTF Vertical: Software & Product'                      UNION ALL
    SELECT 'brand-content-creative',              'WTF Vertical: Brand, Content & Creative'               UNION ALL
    SELECT 'data-analytics',                      'WTF Vertical: Data & Analytics'                        UNION ALL
    SELECT 'b2b-field-sales',                     'WTF Vertical: B2B Field Sales'                         UNION ALL
    SELECT 'finance-accounting',                  'WTF Vertical: Finance & Accounting'                    UNION ALL
    SELECT 'sales-management',                    'WTF Vertical: Sales Management'                        UNION ALL
    SELECT 'legal-compliance',                    'WTF Vertical: Legal & Compliance'                      UNION ALL
    SELECT 'general-ops',                         'WTF Vertical: General Ops'                             UNION ALL
    SELECT 'performance-marketing',               'WTF Vertical: Performance Marketing'                   UNION ALL
    SELECT 'customer-support',                    'WTF Vertical: Customer Support'                        UNION ALL
    SELECT 'procurement-supplychain',             'WTF Vertical: Procurement & Supply Chain'              UNION ALL
    SELECT 'unclassified',                        'WTF Vertical: Unclassified'
) map ON map.raw_value = ef.value
JOIN tag t ON t.title = map.tag_title
WHERE ef.field_name = 'WTF Role Family'
  AND ef.data_item_type = 100;

-- 4b. WTF Seniority -> WTF: Seniority

INSERT IGNORE INTO candidate_tag (candidate_id, tag_id)
SELECT ef.data_item_id, t.tag_id
FROM extra_field ef
JOIN (
    SELECT 'junior' AS raw_value, 'WTF Seniority: Junior' AS tag_title UNION ALL
    SELECT 'mid',                 'WTF Seniority: Mid'                 UNION ALL
    SELECT 'senior',              'WTF Seniority: Senior'              UNION ALL
    SELECT 'lead',                'WTF Seniority: Lead'
) map ON map.raw_value = ef.value
JOIN tag t ON t.title = map.tag_title
WHERE ef.field_name = 'WTF Seniority'
  AND ef.data_item_type = 100;

-- 4c. WTF Gym Industry -> WTF: Industry

INSERT IGNORE INTO candidate_tag (candidate_id, tag_id)
SELECT ef.data_item_id, t.tag_id
FROM extra_field ef
JOIN (
    SELECT 'true'  AS raw_value, 'WTF Industry: Gym/Fitness Background' AS tag_title UNION ALL
    SELECT 'false',               'WTF Industry: Non-Gym Background'
) map ON map.raw_value = ef.value
JOIN tag t ON t.title = map.tag_title
WHERE ef.field_name = 'WTF Gym Industry'
  AND ef.data_item_type = 100;

-- 4d. WTF Priority Tier -> WTF: Priority

INSERT IGNORE INTO candidate_tag (candidate_id, tag_id)
SELECT ef.data_item_id, t.tag_id
FROM extra_field ef
JOIN (
    SELECT 'P1' AS raw_value, 'WTF Priority: P1' AS tag_title UNION ALL
    SELECT 'P2',              'WTF Priority: P2'              UNION ALL
    SELECT 'P3',              'WTF Priority: P3'              UNION ALL
    SELECT 'P4',              'WTF Priority: P4'
) map ON map.raw_value = ef.value
JOIN tag t ON t.title = map.tag_title
WHERE ef.field_name = 'WTF Priority Tier'
  AND ef.data_item_type = 100;

-- 4e. WTF Outreach Consent -> WTF: Outreach

INSERT IGNORE INTO candidate_tag (candidate_id, tag_id)
SELECT ef.data_item_id, t.tag_id
FROM extra_field ef
JOIN (
    SELECT 'yes' AS raw_value, 'WTF Outreach: Consent Given' AS tag_title UNION ALL
    SELECT 'no',                'WTF Outreach: No Consent'
) map ON map.raw_value = ef.value
JOIN tag t ON t.title = map.tag_title
WHERE ef.field_name = 'WTF Outreach Consent'
  AND ef.data_item_type = 100;

-- 4f. WTF Fitness Subrole -> WTF: Fitness Speciality

INSERT IGNORE INTO candidate_tag (candidate_id, tag_id)
SELECT ef.data_item_id, t.tag_id
FROM extra_field ef
JOIN (
    SELECT 'personal-trainer'      AS raw_value, 'WTF Fitness Role: Personal Trainer'      AS tag_title UNION ALL
    SELECT 'group-fitness-coach',                 'WTF Fitness Role: Group Fitness Coach'                UNION ALL
    SELECT 'floor-fitness-manager',               'WTF Fitness Role: Floor Fitness Manager'              UNION ALL
    SELECT 'head-coach',                          'WTF Fitness Role: Head Coach'                         UNION ALL
    SELECT 'area-fitness-head',                   'WTF Fitness Role: Area Fitness Head'                  UNION ALL
    SELECT 'not-gym-fitness',                     'WTF Fitness Role: Not Gym Fitness'
) map ON map.raw_value = ef.value
JOIN tag t ON t.title = map.tag_title
WHERE ef.field_name = 'WTF Fitness Subrole'
  AND ef.data_item_type = 100;


-- -----------------------------------------------------------------------------
-- OPTIONAL — sanity checks (left commented out; this file must not be run
-- against a server as part of authoring it, and these are for a human
-- operator to uncomment and run manually after applying the seed)
-- -----------------------------------------------------------------------------

-- Expect 40 rows (6 parent + 34 child):
-- SELECT COUNT(*) FROM tag WHERE title LIKE 'WTF%';

-- Expect ~= 115215 * (# of the 6 fields actually populated per candidate),
-- i.e. up to ~691290 if every candidate has all six enrichment fields:
-- SELECT COUNT(*) FROM candidate_tag ct JOIN tag t ON t.tag_id = ct.tag_id WHERE t.title LIKE 'WTF%';

-- Per-group breakdown:
-- SELECT parent.title AS group_title, COUNT(*) AS candidates_tagged
-- FROM candidate_tag ct
-- JOIN tag child  ON child.tag_id = ct.tag_id
-- JOIN tag parent ON parent.tag_id = child.tag_parent_id
-- GROUP BY parent.title;
