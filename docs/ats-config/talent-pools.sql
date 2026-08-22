-- =============================================================================
-- WTF (Witness the Fitness Private Limited) -- Talent Pool Saved Lists
-- Target: OpenCATS 0.10.0, MariaDB, database `cats`
-- =============================================================================
--
-- WHAT THIS FILE DOES
-- 13 static candidate saved lists ("talent pools"), each populated by deriving
-- membership from the AI enrichment stored in `extra_field`
-- (data_item_type = 100, i.e. DATA_ITEM_CANDIDATE -- see constants.php:57).
-- Nothing is hand-listed; every list is an INSERT ... SELECT over extra_field.
--
-- HOW SAVED LISTS ACTUALLY WORK IN THIS CODEBASE (research notes, cited)
--
-- 1. `number_entries` is NOT a computed/derived column -- it is a plain
--    denormalized counter that the app maintains by hand on every mutation:
--    lib/SavedLists.php:425-463 `updateSavedListItemCountAndTimeStamp()` runs
--    `SELECT COUNT(saved_list_entry_id) ... WHERE saved_list_id = X` and then
--    `UPDATE saved_list SET number_entries = <count>`, and it is invoked from
--    every entry add/remove path (addEntryMany at :396, removeEntryMany at
--    :417, updateDataItemSavedLists at :508/:537). Nothing in the schema
--    (db/cats_schema.sql:832-846, no trigger) keeps this in sync automatically.
--    The UI also renders this stored value verbatim rather than recomputing
--    it: modules/lists/dataGrids.php:68-69 does
--        'select' => 'number_entries as numberEntries',
--        'pagerRender' => 'return $rsData[\'numberEntries\'];'
--    for the "Show Lists" grid, and modules/lists/List.tpl:18 /
--    QuickActionAddToListModal.tpl:15,26 use the same stored value to drive
--    the delete-list confirmation dialog. => If we only insert
--    saved_list_entry rows and never touch number_entries, every pool would
--    show "(0)" in the UI despite having real members. So every pool below
--    ends with an UPDATE that recomputes number_entries, mirroring what
--    updateSavedListItemCountAndTimeStamp() does.
--
-- 2. `is_dynamic` must be the literal value 0 for a STATIC list, not just
--    "falsy"/NULL. lib/SavedLists.php:89-134 `getAll()` -- the method that
--    powers the "Add to list" quick-action popup (ListsUI.php:248-261 and
--    :291-304, both call getAll($dataItemType, STATIC_LISTS)) -- appends
--    `AND is_dynamic = false` at SavedLists.php:105 when asked for
--    STATIC_LISTS. A NULL there would not satisfy that predicate. We set
--    is_dynamic = 0 explicitly on every list (matches the schema DEFAULT '0'
--    in db/cats_schema.sql:836, and matches how the app itself creates a
--    static list in `newListName()`, SavedLists.php:192-210, which always
--    sets is_dynamic = 0).
--
-- 3. `datagrid_instance` and `parameters` do NOT need values for a static
--    candidate list to render correctly, and we deliberately leave them at
--    their column defaults (empty string / NULL), same as the app itself:
--      - `newListName()` (SavedLists.php:192-210), the app's own "create a
--        static list" INSERT, never sets these two columns at all.
--      - `showList()` (modules/lists/ListsUI.php:155-223), which renders a
--        saved list's contents, computes the datagrid to use for a STATIC
--        list from `$listRS['dataItemType']` via a hardcoded PHP switch
--        (ListsUI.php:177-194; DATA_ITEM_CANDIDATE => hardcoded string
--        'candidates:candidatesSavedListByViewDataGrid'). It never reads
--        `$listRS['datagridInstance']` for that branch, so whatever is
--        stored in the `datagrid_instance` column of `saved_list` is inert
--        for static candidate lists. (Dynamic lists are a different, unused
--        code path here -- irrelevant since every pool below is static.)
--
-- IDEMPOTENCY
-- Every INSERT is guarded so re-running this file is a no-op. MariaDB
-- refuses to reference the table being inserted into directly inside a
-- correlated subquery of the same statement ("You can't specify target
-- table ... for update in FROM clause"), so per the required workaround we
-- always wrap the guard table in a derived table:
--     WHERE NOT EXISTS (SELECT 1 FROM (SELECT ... FROM t) x WHERE ...)
-- This is applied both when creating a list (guard on saved_list.description,
-- which is what lib/SavedLists.php:142-161 `getIDByDescription()` also keys
-- on) and when inserting members (guard on the (saved_list_id, data_item_id)
-- pair in saved_list_entry).
--
-- PERFORMANCE
-- - `extra_field` has ~2.1M rows; every filter here starts from an equality
--   match on (field_name, value[, data_item_type]), which is exactly what
--   the assumed indexes extra_field(field_name) and
--   extra_field(data_item_id, data_item_type) are for. Two-condition pools
--   join extra_field to itself on data_item_id instead of using an
--   IN-subquery, so the optimizer can pick the smaller side first and do an
--   index lookup for the second condition per row, rather than materializing
--   a huge IN-list or doing a GROUP BY/HAVING count(*) over millions of rows.
-- - NOTE: the base db/cats_schema.sql only ships `KEY assoc_id (data_item_id)`
--   on extra_field (db/cats_schema.sql:597-606). The composite
--   (data_item_id, data_item_type) index and the (field_name) index are
--   assumed to already exist per the task brief (e.g. added by the
--   enrichment-import migration) -- this file does not create them. If they
--   are missing, every query below is still correct, just full-scan slow at
--   2.1M rows on a t3.small.
-- - No explicit START TRANSACTION/COMMIT wraps the whole file on purpose:
--   on a 1.9GB t3.small a single giant transaction over 13 pools risks
--   memory/lock pressure for no benefit, since every statement is
--   independently idempotent. If the box dies partway through, simply
--   re-run the file -- completed pools are skipped, incomplete ones resume.
-- - `created_by` is hardcoded to user_id 1 (the admin account) per the task
--   brief.
--
-- CAPPING
-- Only one pool (#12, "Never Contacted (Gym Industry)") is capped -- see
-- that section for why. All others are naturally bounded well under
-- "tens of thousands" once both conditions are applied, so they are left
-- uncapped (sizes noted per-pool below are derived from the exact
-- field-value counts given in the brief; anything not given a count in the
-- brief -- WTF Seniority, WTF Priority Tier, and every WTF Fitness Subrole
-- value besides personal-trainer -- is estimated assuming a roughly even
-- split across that field's values, and is called out as an estimate).
--
-- =============================================================================

USE `cats`;


-- =============================================================================
-- POOL 1: WTF - Personal Trainers (Gym Floor)
-- Filter: WTF Fitness Subrole = personal-trainer AND WTF Gym Industry = true
-- Expected size: <= 4,664 (exact count of the personal-trainer subrole);
--   realistically close to that ceiling since a personal-trainer subrole tag
--   should almost always co-occur with Gym Industry = true.
-- Why: single largest identifiable frontline hiring line (gym floor trainer
--   headcount) -- the pool a floor-staffing recruiter reaches for constantly.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Personal Trainers (Gym Floor)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Personal Trainers (Gym Floor)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Fitness Subrole'
       AND ef1.value = 'personal-trainer'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Gym Industry'
       AND ef2.value = 'true'
    WHERE sl.description = 'WTF - Personal Trainers (Gym Floor)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Personal Trainers (Gym Floor)';


-- =============================================================================
-- POOL 2: WTF - Group Fitness Coaches
-- Filter: WTF Fitness Subrole = group-fitness-coach AND WTF Gym Industry = true
-- Expected size: estimate only -- the brief gives no count for this subrole
--   value. fitness-delivery (the parent role family) totals 11,767, of which
--   4,664 are tagged personal-trainer; the remaining ~7,103 are split across
--   5 other subrole values, so group-fitness-coach is roughly in the
--   1,000-1,600 range. Treat as a rough planning estimate, not a guarantee.
-- Why: group-class staffing is a distinct hiring motion from 1:1 personal
--   training (different shift patterns, different comp), so it deserves its
--   own pool rather than being buried inside pool 1 or the whole
--   fitness-delivery family.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Group Fitness Coaches', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Group Fitness Coaches'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Fitness Subrole'
       AND ef1.value = 'group-fitness-coach'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Gym Industry'
       AND ef2.value = 'true'
    WHERE sl.description = 'WTF - Group Fitness Coaches'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Group Fitness Coaches';


-- =============================================================================
-- POOL 3: WTF - Membership Sales (Junior)
-- Filter: WTF Role Family = gym-membership-sales AND WTF Seniority = junior
-- Expected size: estimate -- gym-membership-sales totals 18,249; seniority
--   counts are not given, so assuming a roughly even split across the 4
--   seniority values, ~25% => ~4,560. Actual split is very likely skewed
--   junior-heavy for a high-volume front-line sales role, so this is
--   probably a floor rather than the true count.
-- Why: gym-membership-sales is the single biggest role family (18,249
--   candidates) and every new gym opening needs a wave of entry-level sales
--   reps -- this is the highest-volume recurring hiring motion in the company.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Membership Sales (Junior)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Membership Sales (Junior)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'gym-membership-sales'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Seniority'
       AND ef2.value = 'junior'
    WHERE sl.description = 'WTF - Membership Sales (Junior)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Membership Sales (Junior)';


-- =============================================================================
-- POOL 4: WTF - Membership Sales (Senior/Lead)
-- Filter: WTF Role Family = gym-membership-sales AND WTF Seniority IN (senior, lead)
-- Expected size: estimate -- ~2 of 4 seniority buckets of the 18,249-strong
--   family, so roughly ~9,100 assuming an even split (again likely an
--   overestimate for the same reason as pool 3 -- senior/lead is usually the
--   smaller half of a sales funnel, not the bigger one).
-- Why: separates the sales-leadership bench (team leads, cluster managers)
--   from the entry-level pipeline in pool 3 -- different comp band, different
--   hiring cadence. `IN ('senior','lead')` here is a literal 2-value list on
--   an already row-narrowed self-join, not a correlated IN-subquery, so it
--   does not conflict with the "avoid IN-subqueries" performance guidance.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Membership Sales (Senior/Lead)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Membership Sales (Senior/Lead)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'gym-membership-sales'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Seniority'
       AND ef2.value IN ('senior', 'lead')
    WHERE sl.description = 'WTF - Membership Sales (Senior/Lead)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Membership Sales (Senior/Lead)';


-- =============================================================================
-- POOL 5: WTF - Multi-site Managers (Sr/Lead, Gym)
-- Filter: WTF Role Family IN (admin-facilities, general-ops)
--         AND WTF Seniority IN (senior, lead)
--         AND WTF Gym Industry = true
-- Expected size: estimate -- admin-facilities (19,005) + general-ops (2,067)
--   = 21,072 candidates, times ~50% for senior/lead, times ~28% for
--   Gym Industry = true (32,217 / 115,215 overall) => roughly ~2,000-3,500.
--   All three factors are independence assumptions since no joint counts are
--   given, so treat this as a ballpark.
-- Why: the operations/facilities role families are the closest proxy this
--   dataset has for "runs a gym location day-to-day"; restricting to
--   senior/lead plus Gym Industry = true targets people who can plausibly
--   run one or more physical sites, rather than corporate back-office ops.
--   This extends the 2-condition self-join pattern to a 3rd extra_field
--   join, still all keyed on data_item_id rather than any IN-subquery.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Multi-site Managers (Sr/Lead, Gym)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Multi-site Managers (Sr/Lead, Gym)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value IN ('admin-facilities', 'general-ops')
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Seniority'
       AND ef2.value IN ('senior', 'lead')
    JOIN extra_field ef3
        ON ef3.data_item_id = ef1.data_item_id
       AND ef3.data_item_type = 100
       AND ef3.field_name = 'WTF Gym Industry'
       AND ef3.value = 'true'
    WHERE sl.description = 'WTF - Multi-site Managers (Sr/Lead, Gym)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Multi-site Managers (Sr/Lead, Gym)';


-- =============================================================================
-- POOL 6: WTF - Fitness Delivery Leadership (Sr/Lead)
-- Filter: WTF Role Family = fitness-delivery AND WTF Seniority IN (senior, lead)
-- Expected size: estimate -- fitness-delivery totals 11,767; ~50% for
--   senior/lead => roughly ~5,900.
-- Why: head coaches / area fitness heads are a distinct hiring line from the
--   floor trainer pool (#1) and the group-coach pool (#2) -- this is the
--   bench for promoting or laterally hiring fitness-delivery leadership,
--   independent of which subrole they came up through.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Fitness Delivery Leadership (Sr/Lead)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Fitness Delivery Leadership (Sr/Lead)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'fitness-delivery'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Seniority'
       AND ef2.value IN ('senior', 'lead')
    WHERE sl.description = 'WTF - Fitness Delivery Leadership (Sr/Lead)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Fitness Delivery Leadership (Sr/Lead)';


-- =============================================================================
-- POOL 7: WTF - Corporate Finance & Accounting
-- Filter: WTF Role Family = finance-accounting
-- Expected size: 4,633 (exact -- given directly in the brief).
-- Why: single-condition pool -- finance-accounting is small enough on its own
--   (well under "tens of thousands") that narrowing further would just make
--   it less useful; the whole family is the standing pipeline for the CFO
--   org across all eleven lines of business.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Corporate Finance & Accounting', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Corporate Finance & Accounting'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'finance-accounting'
       AND ef1.data_item_type = 100
    WHERE sl.description = 'WTF - Corporate Finance & Accounting'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Corporate Finance & Accounting';


-- =============================================================================
-- POOL 8: WTF - Corporate Legal & Compliance
-- Filter: WTF Role Family = legal-compliance
-- Expected size: 2,120 (exact -- given directly in the brief).
-- Why: same reasoning as pool 7 -- small, specialist, single-condition;
--   legal-compliance hiring needs across 11 lines of business (contracts,
--   labor law, gym-safety regulation) are niche enough that the whole family
--   is the useful unit, no further slicing needed.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Corporate Legal & Compliance', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Corporate Legal & Compliance'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'legal-compliance'
       AND ef1.data_item_type = 100
    WHERE sl.description = 'WTF - Corporate Legal & Compliance'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Corporate Legal & Compliance';


-- =============================================================================
-- POOL 9: WTF - Software & Product (Sr/Lead)
-- Filter: WTF Role Family = software-product AND WTF Seniority IN (senior, lead)
-- Expected size: estimate -- software-product totals 15,162; ~50% for
--   senior/lead => roughly ~7,600.
-- Why: the raw software-product family (15,162) is too broad to be a useful
--   "reach for it" shortlist -- it spans everything from junior QA to staff
--   engineers. Restricting to senior/lead gives recruiters the bar-raising
--   bench for tech leadership hires, separate from the broad IC pipeline.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Software & Product (Sr/Lead)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Software & Product (Sr/Lead)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'software-product'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Seniority'
       AND ef2.value IN ('senior', 'lead')
    WHERE sl.description = 'WTF - Software & Product (Sr/Lead)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Software & Product (Sr/Lead)';


-- =============================================================================
-- POOL 10: WTF - HR & Recruiting (Contactable)
-- Filter: WTF Role Family = hr-recruiting AND WTF Outreach Consent = yes
-- Expected size: estimate -- hr-recruiting totals 13,043; outreach-consent
--   "yes" is 40,013 / 115,215 = ~34.7% overall. Assuming that ratio holds
--   within this family (no joint count given), ~13,043 * 0.347 =~ 4,530.
-- Why: hr-recruiting alone (13,043) is a reasonable size but includes people
--   who should not be messaged; gating on Outreach Consent = yes turns it
--   into an immediately actionable, compliant outreach list rather than a
--   raw category dump the recruiter still has to filter by hand.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - HR & Recruiting (Contactable)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - HR & Recruiting (Contactable)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'hr-recruiting'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Outreach Consent'
       AND ef2.value = 'yes'
    WHERE sl.description = 'WTF - HR & Recruiting (Contactable)'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - HR & Recruiting (Contactable)';


-- =============================================================================
-- POOL 11: WTF - P1 Priority, Contactable
-- Filter: WTF Priority Tier = P1 AND WTF Outreach Consent = yes
-- Expected size: estimate -- no distribution is given for Priority Tier.
--   Naively assuming an even 25% per tier against the 40,013 consenting
--   candidates gives ~10,000, but P1 ("highest priority") tiers are
--   typically deliberately kept small in a 4-tier scheme, so the real number
--   is more likely in the low thousands. Either way this is bounded above by
--   40,013 (total Outreach Consent = yes).
-- Why: this is the single most operationally important pool in the file --
--   the exact intersection called out in the brief. It is the ready-to-call
--   shortlist: whatever the business has flagged as top priority AND that
--   we are actually allowed to contact. Every other pool here is a sourcing
--   aid; this one is a daily-use outbound worklist.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - P1 Priority, Contactable', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - P1 Priority, Contactable'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Priority Tier'
       AND ef1.value = 'P1'
       AND ef1.data_item_type = 100
    JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Outreach Consent'
       AND ef2.value = 'yes'
    WHERE sl.description = 'WTF - P1 Priority, Contactable'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - P1 Priority, Contactable';


-- =============================================================================
-- POOL 12: WTF - Never Contacted (Gym Industry)
-- Filter: WTF Gym Industry = true AND no WTF Last Contacted row exists at all
--   ("absent" per the brief, not an empty string -- so this must be an
--   anti-join, not an equality self-join like every other pool above).
-- CAP: capped at 5,000 rows, ordered by highest WTF Total Experience (yrs)
--   first, then by data_item_id as a deterministic tiebreaker.
--   Why cap: this pool is bounded above by the full Gym Industry = true
--   population (32,217), and could plausibly retain most of that if
--   outreach has historically been light -- i.e. it could land squarely in
--   "tens of thousands" of rows. A saved list that size is not a working
--   shortlist, it is close to the entire gym-industry population, and would
--   invite an untargeted mass-contact run. Capping to the top 5,000 by
--   experience gives recruiters the most qualified never-contacted
--   candidates first; re-running this file recomputes the exact same
--   top-5,000 (same underlying data => same ORDER BY result => the
--   idempotency guard below correctly inserts nothing new).
-- Why (business): every other pool assumes a positive tag; this is the one
--   pool that surfaces a *gap* in the recruiting funnel -- gym-industry
--   candidates the team has never reached out to at all -- which is exactly
--   the kind of pool a saved list is for, since it can't be expressed as a
--   quick keyword search.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Never Contacted (Gym Industry)', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Never Contacted (Gym Industry)'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Gym Industry'
       AND ef1.value = 'true'
       AND ef1.data_item_type = 100
    LEFT JOIN extra_field ef2
        ON ef2.data_item_id = ef1.data_item_id
       AND ef2.data_item_type = 100
       AND ef2.field_name = 'WTF Last Contacted'
    LEFT JOIN extra_field ef3
        ON ef3.data_item_id = ef1.data_item_id
       AND ef3.data_item_type = 100
       AND ef3.field_name = 'WTF Total Experience (yrs)'
    WHERE sl.description = 'WTF - Never Contacted (Gym Industry)'
      AND ef2.extra_field_id IS NULL
    ORDER BY CAST(ef3.value AS DECIMAL(6,2)) DESC, ef1.data_item_id ASC
    LIMIT 5000
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Never Contacted (Gym Industry)';


-- =============================================================================
-- POOL 13: WTF - Procurement & Supply Chain
-- Filter: WTF Role Family = procurement-supplychain
-- Expected size: 220 (exact -- given directly in the brief).
-- Why: the smallest and most specialized corporate function in the company.
--   Precisely because it is so small, sourcing more candidates for it takes
--   real effort, so recruiters need the entire existing pool on one list
--   with zero further filtering rather than re-deriving it from search every
--   time.
-- =============================================================================

INSERT INTO saved_list (description, data_item_type, is_dynamic, created_by, number_entries, date_created, date_modified)
SELECT 'WTF - Procurement & Supply Chain', 100, 0, 1, 0, NOW(), NOW()
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT description FROM saved_list) x
    WHERE x.description = 'WTF - Procurement & Supply Chain'
);

INSERT INTO saved_list_entry (saved_list_id, data_item_type, data_item_id, date_created)
SELECT v.saved_list_id, 100, v.data_item_id, NOW()
FROM (
    SELECT sl.saved_list_id AS saved_list_id, ef1.data_item_id AS data_item_id
    FROM saved_list sl
    JOIN extra_field ef1
        ON ef1.field_name = 'WTF Role Family'
       AND ef1.value = 'procurement-supplychain'
       AND ef1.data_item_type = 100
    WHERE sl.description = 'WTF - Procurement & Supply Chain'
) v
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT saved_list_id, data_item_id FROM saved_list_entry) sle
    WHERE sle.saved_list_id = v.saved_list_id AND sle.data_item_id = v.data_item_id
);

UPDATE saved_list
SET number_entries = (SELECT COUNT(*) FROM saved_list_entry sle WHERE sle.saved_list_id = saved_list.saved_list_id),
    date_modified = NOW()
WHERE description = 'WTF - Procurement & Supply Chain';


-- =============================================================================
-- VERIFICATION (read-only, safe to run any time)
-- =============================================================================

SELECT
    saved_list_id,
    description,
    number_entries,
    is_dynamic,
    date_created
FROM saved_list
WHERE data_item_type = 100
  AND description LIKE 'WTF - %'
ORDER BY saved_list_id ASC;
