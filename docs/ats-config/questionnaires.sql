-- =============================================================================
-- WTF (Witness the Fitness Private Limited) — Career Portal Questionnaire Seed
-- Target: OpenCATS 0.10.0 on MariaDB, database `cats`
-- =============================================================================
--
-- WHAT THIS FILE DOES
--   Seeds 5 screening questionnaires (grouped by role family, not one per job
--   order) and attaches each to the right subset of the 15 currently-live,
--   questionnaire-less public job orders on https://careers.wtfgyms.com/careers/.
--
-- WHY 5 QUESTIONNAIRES, NOT 15
--   OpenCATS renders a questionnaire once, before the candidate reaches the
--   resume-upload step of the public apply flow (modules/careers/CareersUI.php,
--   ~line 836 "Applicant has completed their application, check to see if a
--   questionnaire is tied to this job order"). Fifteen near-identical
--   questionnaires would mean fifteen places to keep in sync every time a
--   screening question changes, for no applicant-facing benefit. Grouping by
--   role family (what the job actually screens for) instead of by job order
--   (an org-chart accident) keeps maintenance to 5 places and lets one
--   questionnaire serve every job order that shares the same hiring bar:
--
--     1. Fitness Delivery & Coaching Screening   -> job orders 1, 7
--        Client-facing, certification-driven floor roles (WTF Gyms Personal
--        Trainer, WTF Academy Fitness Educator).
--     2. Gym Operations, Sales & Franchise Screening -> job orders 2,3,4,5,6,10
--        Centre-based operations/sales/service plus partner- and
--        franchise-facing roles (WTF Gyms, WTF Powered Gyms, WTF Franchisee
--        Gyms, WTF Go) — the common thread is roster/weekend flexibility and
--        multi-site travel, not job title.
--     3. Corporate & Professional Roles Screening -> job orders 8,12,14,15
--        Head-office, qualification-driven roles with no shift/centre
--        dependency (WTF Amplify, WTF Everyday, WTF Enterprise x2).
--     4. Specialist Clinical Roles Screening      -> job orders 9, 11
--        Licensed/registered health professionals (WTF Reboot, WTF
--        Metabolic) — screened on credential + clinical population, not on
--        sales or shift questions that don't apply to them.
--     5. Technical & Field Service Screening      -> job order 13
--        On-site equipment technician (WTF Equipments) — the only role that
--        screens on trade certification + own-vehicle field travel.
--
--   Every one of the 15 job orders named in this file appears in exactly one
--   group above (2+6+4+2+1 = 15), so nothing is left unattached and nothing
--   is double-attached.
--
-- WHERE THE `type` INTEGER VALUES COME FROM (do not change these without
-- re-checking the same constants)
--   lib/Questionnaire.php:36  define('QUESTIONNAIRE_QUESTION_TYPE_TEXT',     1);
--   lib/Questionnaire.php:37  define('QUESTIONNAIRE_QUESTION_TYPE_SELECT',   2);
--   lib/Questionnaire.php:38  define('QUESTIONNAIRE_QUESTION_TYPE_CHECKBOX', 3);
--   lib/Questionnaire.php:39  define('QUESTIONNAIRE_QUESTION_TYPE_RADIO',    4);
--   Confirmed against the render switch in
--   modules/settings/CareerPortalQuestionnaireShow.tpl (the same template the
--   public apply flow includes via modules/careers/CareersUI.php:896), which
--   branches on exactly these four values: TEXT -> <textarea>, RADIO -> radio
--   buttons, CHECKBOX -> checkboxes, SELECT -> <select> dropdown.
--
-- HOW A QUESTIONNAIRE ATTACHES TO A JOB ORDER (the linkage requested)
--   Table `joborder`, column `questionnaire_id` (nullable INT, no FK
--   constraint in the schema — db/cats_schema.sql:745), holding the PK of
--   `career_portal_questionnaire`. Read side: lib/JobOrders.php:438 (and
--   :547, :676) select it as `joborder.questionnaire_id as questionnaireID`
--   in every job-order fetch used by the careers module. Write side:
--   lib/JobOrders.php:213 sets it in the same UPDATE that saves the rest of
--   the job order. modules/careers/CareersUI.php:843-854 is what actually
--   reads it at apply-time: if job_order.questionnaire_id is truthy and
--   career_portal_questionnaire.get() returns a row, the questionnaire is
--   shown before the application is accepted; otherwise the applicant skips
--   straight to "Thanks for your submission". We attach via a plain UPDATE
--   in SECTION C below, guarded by `questionnaire_id IS NULL` so re-running
--   this file never clobbers a questionnaire a recruiter attaches by hand
--   afterwards.
--
-- A SCHEMA DETAIL THAT WOULD SILENTLY BREAK THIS SEED IF IGNORED
--   Questionnaire::getQuestions() (lib/Questionnaire.php:146-176) fetches
--   questions with:
--     FROM career_portal_questionnaire_question a
--     RIGHT JOIN career_portal_questionnaire_answer b
--     ON a.career_portal_questionnaire_question_id = b.career_portal_questionnaire_question_id
--   Because this is a RIGHT JOIN anchored on the *answer* table, a question
--   with zero rows in career_portal_questionnaire_answer never appears in
--   the result set at all — not as a question with no options, just
--   invisible. This is why OpenCATS's own bulk question-loader,
--   Questionnaire::addQuestions() (lib/Questionnaire.php:271-324), always
--   inserts a placeholder answer row for every TEXT-type question (text='',
--   action_is_active=1, position=1 — see the literal addAnswer() call at
--   lib/Questionnaire.php:289-300). This file follows the exact same
--   convention: every TEXT question below gets one empty placeholder answer
--   row, or it would render as if it did not exist.
--
-- A SECOND SCHEMA DETAIL THAT MATTERS FOR EVERY NON-TEXT ANSWER
--   career_portal_questionnaire_answer.action_is_active defaults to 0
--   (db/cats_schema.sql:317), but Questionnaire::doActions()
--   (lib/Questionnaire.php:545-674) — which runs immediately after a
--   candidate submits the questionnaire and actually saves the candidate
--   record — initializes `$isActive = 1` (line 554) and then only flips it
--   to 0 if a *selected* answer's action_is_active is falsy (line 630:
--   `if (!$answer['actionIsActive']) $isActive = 0;`). In other words, the
--   table's own default silently deactivates any candidate who picks an
--   answer we forgot to set action_is_active on. Every answer row in this
--   file sets action_is_active = 1 explicitly for that reason; none of our
--   screening questions are meant to auto-deactivate an applicant without a
--   human looking at them first.
--
-- WHERE ANSWER-DRIVEN ACTIONS ARE USED (requirement: at least one
-- nationally-recognised certification should mark the candidate hot)
--   - Fitness Delivery & Coaching Screening, Q1: choosing "ACE, NASM, or K11
--     certified (nationally recognised)" sets action_is_hot = 1 and tags
--     action_key_skills. K11 and ACE/NASM are the certifications actually
--     recognised across the Indian gym-industry hiring market this ATS
--     serves.
--   - Corporate & Professional Roles Screening, Q2: choosing "Yes - CA, CFA,
--     CPA, or equivalent finance qualification" likewise sets
--     action_is_hot = 1 — the second nationally-recognised-credential
--     example, for the Finance Manager / HR Business Partner side of the
--     house.
--   - Specialist Clinical Roles Screening, Q1: confirming the
--     licence/registration required to practise sets action_is_hot = 1 —
--     for a regulated clinical role, holding the legally-required
--     credential at all is itself the high-signal answer.
--   Several other answers use action_key_skills / action_notes /
--   action_can_relocate to enrich the candidate record without necessarily
--   marking hot (e.g. capturing a preferred centre, or "own vehicle for
--   field travel").
--
-- WHY "No" / "less experience" / "no certification" answers sit at
-- position 1
--   CareerPortalQuestionnaireShow.tpl pre-checks the *first* answer of a
--   RADIO question automatically (`<?php if ($nochecked) { $nochecked =
--   false; echo ' checked'; } ?>` on the first loop iteration — see that
--   template around the RADIO branch) and a <select> likewise displays its
--   first <option> by default. An inattentive applicant who never touches
--   the control therefore submits whatever sits at position 1. Every
--   RADIO/SELECT question in this file puts the weakest / most conservative
--   answer at position 1, so an untouched control never falsely triggers a
--   hot flag or an inflated experience/qualification signal. Binary
--   confirmation questions ("I am willing to...", "I have my own
--   vehicle...") are modelled as a single CHECKBOX answer instead of a
--   two-option RADIO for the same reason: an unchecked checkbox has no
--   pre-selection bias at all, whereas a Yes/No RADIO would always default
--   to whichever option happened to be listed first.
--
-- IDEMPOTENCY / THE MariaDB SELF-REFERENCE GOTCHA
--   MariaDB refuses "INSERT INTO t ... WHERE NOT EXISTS (SELECT 1 FROM t
--   WHERE ...)" with ERROR 1093 ("You can't specify target table 't' for
--   update in FROM clause") whenever the subquery names the same table the
--   INSERT targets — even buried inside a WHERE NOT EXISTS, not just a
--   literal outer FROM. Every existence check below wraps the target table
--   in its own derived table, e.g. `(SELECT title FROM
--   career_portal_questionnaire) x`, exactly as specified for this task:
--     INSERT ... SELECT ... FROM DUAL
--     WHERE NOT EXISTS (SELECT 1 FROM (SELECT title FROM t) x WHERE x.title = '...')
--   MariaDB materializes the derived table first, which decouples it from
--   the "same table as the INSERT target" check.
--
--   To avoid repeating that pattern with a fragile hand-copied title/text
--   string every time a question or answer needs its parent's ID, this file
--   captures each parent ID into a session variable immediately after its
--   own idempotent INSERT (`SELECT ... INTO @var FROM ... LIMIT 1`). That
--   SELECT is its own statement, entirely separate from the INSERT, so it
--   is never subject to the self-reference restriction above — it runs
--   (and correctly finds the row) whether the preceding INSERT actually
--   fired this run or was skipped because the row already existed. Session
--   variables persist only for this connection, which matches how such
--   seed files are normally executed (`mariadb -u <user> -p cats < this_file.sql`
--   or a client's `SOURCE` command, both single-session).
--
-- HOW TO RUN
--   mariadb -u <user> -p cats < questionnaires.sql
--   (or) mysql -u <user> -p cats < questionnaires.sql
--   Safe to re-run any number of times: every INSERT is guarded by a
--   NOT EXISTS check, and the job-order attachment in SECTION C only ever
--   sets questionnaire_id when it is currently NULL.
-- =============================================================================


START TRANSACTION;


-- -----------------------------------------------------------------------------
-- SECTION A — Questionnaire headers
-- -----------------------------------------------------------------------------

INSERT INTO career_portal_questionnaire (title, description, is_active)
SELECT
    'Fitness Delivery & Coaching Screening',
    'Screening for client-facing, certification-driven roles: Personal Trainer (WTF Gyms) and Fitness Educator (WTF Academy).',
    1
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT title FROM career_portal_questionnaire) x
    WHERE x.title = 'Fitness Delivery & Coaching Screening'
);

INSERT INTO career_portal_questionnaire (title, description, is_active)
SELECT
    'Gym Operations, Sales & Franchise Screening',
    'Screening for centre-based operations, sales, and partner/franchise-facing roles across WTF Gyms, WTF Powered Gyms, WTF Franchisee Gyms and WTF Go.',
    1
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT title FROM career_portal_questionnaire) x
    WHERE x.title = 'Gym Operations, Sales & Franchise Screening'
);

INSERT INTO career_portal_questionnaire (title, description, is_active)
SELECT
    'Corporate & Professional Roles Screening',
    'Screening for head-office roles based in Noida: Performance Marketing Manager (WTF Amplify), Category Manager (WTF Everyday), HR Business Partner and Finance Manager (WTF Enterprise).',
    1
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT title FROM career_portal_questionnaire) x
    WHERE x.title = 'Corporate & Professional Roles Screening'
);

INSERT INTO career_portal_questionnaire (title, description, is_active)
SELECT
    'Specialist Clinical Roles Screening',
    'Screening for licensed clinical roles: Physiotherapist (WTF Reboot) and Clinical Nutritionist (WTF Metabolic).',
    1
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT title FROM career_portal_questionnaire) x
    WHERE x.title = 'Specialist Clinical Roles Screening'
);

INSERT INTO career_portal_questionnaire (title, description, is_active)
SELECT
    'Technical & Field Service Screening',
    'Screening for the Service Technician role at WTF Equipments, covering on-site gym equipment installation and repair across the NCR.',
    1
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT title FROM career_portal_questionnaire) x
    WHERE x.title = 'Technical & Field Service Screening'
);

-- Capture each questionnaire's PK for use below, regardless of whether the
-- INSERT above fired this run or the row already existed.
SELECT career_portal_questionnaire_id INTO @q1 FROM career_portal_questionnaire WHERE title = 'Fitness Delivery & Coaching Screening' LIMIT 1;
SELECT career_portal_questionnaire_id INTO @q2 FROM career_portal_questionnaire WHERE title = 'Gym Operations, Sales & Franchise Screening' LIMIT 1;
SELECT career_portal_questionnaire_id INTO @q3 FROM career_portal_questionnaire WHERE title = 'Corporate & Professional Roles Screening' LIMIT 1;
SELECT career_portal_questionnaire_id INTO @q4 FROM career_portal_questionnaire WHERE title = 'Specialist Clinical Roles Screening' LIMIT 1;
SELECT career_portal_questionnaire_id INTO @q5 FROM career_portal_questionnaire WHERE title = 'Technical & Field Service Screening' LIMIT 1;


-- =============================================================================
-- SECTION B — Questions and answers, one block per questionnaire
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B1. Fitness Delivery & Coaching Screening  (-> job orders 1, 7)
-- -----------------------------------------------------------------------------

-- Q1: certification held. type=4 RADIO (lib/Questionnaire.php:39). Weakest
-- answer ("None yet") at position 1 so an untouched, pre-checked radio never
-- falsely fires the hot flag (see header note on pre-selection bias).
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q1, 'Which nationally recognised fitness certification do you currently hold?', NULL, NULL, 1, 1, 4
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q1
      AND x.text = 'Which nationally recognised fitness certification do you currently hold?'
);
SELECT career_portal_questionnaire_question_id INTO @q1_1 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q1 AND text = 'Which nationally recognised fitness certification do you currently hold?' LIMIT 1;

INSERT INTO career_portal_questionnaire_answer
    (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_1, @q1, 'None yet - I am currently pursuing a certification', NULL, NULL, 0, 1, 0, NULL, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x
    WHERE x.career_portal_questionnaire_question_id = @q1_1 AND x.text = 'None yet - I am currently pursuing a certification'
);
INSERT INTO career_portal_questionnaire_answer
    (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_1, @q1, 'A state or gym-specific certification (not nationally accredited)', NULL, NULL, 0, 1, 0, NULL, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x
    WHERE x.career_portal_questionnaire_question_id = @q1_1 AND x.text = 'A state or gym-specific certification (not nationally accredited)'
);
-- High-signal answer: nationally recognised certification -> hot (requirement 3).
INSERT INTO career_portal_questionnaire_answer
    (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_1, @q1, 'ACE, NASM, or K11 certified (nationally recognised)', NULL, NULL, 1, 1, 0, 'Certified Personal Trainer (ACE/NASM/K11)', 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x
    WHERE x.career_portal_questionnaire_question_id = @q1_1 AND x.text = 'ACE, NASM, or K11 certified (nationally recognised)'
);

-- Q2: years of experience. type=2 SELECT (lib/Questionnaire.php:37).
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q1, 'How many years of hands-on personal training or group fitness coaching experience do you have?', NULL, NULL, 1, 2, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q1 AND x.text = 'How many years of hands-on personal training or group fitness coaching experience do you have?'
);
SELECT career_portal_questionnaire_question_id INTO @q1_2 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q1 AND text = 'How many years of hands-on personal training or group fitness coaching experience do you have?' LIMIT 1;

INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_2, @q1, 'Less than 1 year', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_2 AND x.text = 'Less than 1 year');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_2, @q1, '1 to 3 years', NULL, NULL, 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_2 AND x.text = '1 to 3 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_2, @q1, '3 to 5 years', NULL, NULL, 0, 1, 0, NULL, 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_2 AND x.text = '3 to 5 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_2, @q1, 'More than 5 years', NULL, NULL, 1, 1, 0, 'Senior Personal Trainer', 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_2 AND x.text = 'More than 5 years');

-- Q3: notice period. type=1 TEXT (lib/Questionnaire.php:36). Needs the
-- empty placeholder answer row described in the header note, or this
-- question is invisible on the career portal (RIGHT JOIN quirk).
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q1, 'What is your current notice period, in days? (Enter 0 if you can join immediately.)', 0, 50, 1, 3, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q1 AND x.text = 'What is your current notice period, in days? (Enter 0 if you can join immediately.)'
);
SELECT career_portal_questionnaire_question_id INTO @q1_3 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q1 AND text = 'What is your current notice period, in days? (Enter 0 if you can join immediately.)' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_3, @q1, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_3 AND x.text = '');

-- Q4: expected CTC. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q1, 'What is your expected monthly CTC, in INR?', 0, 50, 1, 4, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q1 AND x.text = 'What is your expected monthly CTC, in INR?'
);
SELECT career_portal_questionnaire_question_id INTO @q1_4 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q1 AND text = 'What is your expected monthly CTC, in INR?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_4, @q1, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_4 AND x.text = '');

-- Q5: shift/weekend willingness. type=3 CHECKBOX (lib/Questionnaire.php:38),
-- modelled as a single unchecked-by-default confirmation (see header note).
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q1, 'I am willing to work rotational shifts, including early mornings, evenings, and weekends', NULL, NULL, 0, 5, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q1 AND x.text = 'I am willing to work rotational shifts, including early mornings, evenings, and weekends'
);
SELECT career_portal_questionnaire_question_id INTO @q1_5 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q1 AND text = 'I am willing to work rotational shifts, including early mornings, evenings, and weekends' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_5, @q1, 'Yes, I confirm', NULL, 'Confirmed availability for rotational/weekend shifts', 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_5 AND x.text = 'Yes, I confirm');

-- Q6: preferred centre. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q1, 'Which WTF Gyms or WTF Academy centre are you applying to, or would prefer?', NULL, NULL, 0, 6, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q1 AND x.text = 'Which WTF Gyms or WTF Academy centre are you applying to, or would prefer?'
);
SELECT career_portal_questionnaire_question_id INTO @q1_6 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q1 AND text = 'Which WTF Gyms or WTF Academy centre are you applying to, or would prefer?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_6, @q1, 'No preference - any NCR centre', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_6 AND x.text = 'No preference - any NCR centre');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_6, @q1, 'Noida Sector 18', NULL, 'Preferred centre: Noida Sector 18', 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_6 AND x.text = 'Noida Sector 18');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_6, @q1, 'Noida Sector 62', NULL, 'Preferred centre: Noida Sector 62', 0, 1, 0, NULL, 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_6 AND x.text = 'Noida Sector 62');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q1_6, @q1, 'Greater Noida', NULL, 'Preferred centre: Greater Noida', 0, 1, 0, NULL, 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q1_6 AND x.text = 'Greater Noida');


-- -----------------------------------------------------------------------------
-- B2. Gym Operations, Sales & Franchise Screening  (-> job orders 2,3,4,5,6,10)
-- -----------------------------------------------------------------------------

-- Q1: years of operations/sales experience. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'Total years of experience in gym or fitness centre operations, membership sales, customer service, or franchise management?', NULL, NULL, 1, 1, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'Total years of experience in gym or fitness centre operations, membership sales, customer service, or franchise management?'
);
SELECT career_portal_questionnaire_question_id INTO @q2_1 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'Total years of experience in gym or fitness centre operations, membership sales, customer service, or franchise management?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_1, @q2, 'Less than 1 year', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_1 AND x.text = 'Less than 1 year');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_1, @q2, '1 to 3 years', NULL, NULL, 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_1 AND x.text = '1 to 3 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_1, @q2, '3 to 5 years', NULL, NULL, 0, 1, 0, NULL, 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_1 AND x.text = '3 to 5 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_1, @q2, 'More than 5 years', NULL, NULL, 1, 1, 0, 'Senior Gym Operations Experience', 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_1 AND x.text = 'More than 5 years');

-- Q2: fitness-industry background. type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'I have prior experience specifically within the fitness, gym, or wellness industry', NULL, NULL, 0, 2, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'I have prior experience specifically within the fitness, gym, or wellness industry'
);
SELECT career_portal_questionnaire_question_id INTO @q2_2 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'I have prior experience specifically within the fitness, gym, or wellness industry' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_2, @q2, 'Yes, I confirm', NULL, NULL, 0, 1, 0, 'Fitness Industry Experience', 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_2 AND x.text = 'Yes, I confirm');

-- Q3: notice period. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'What is your current notice period, in days? (Enter 0 if you can join immediately.)', 0, 50, 1, 3, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'What is your current notice period, in days? (Enter 0 if you can join immediately.)'
);
SELECT career_portal_questionnaire_question_id INTO @q2_3 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'What is your current notice period, in days? (Enter 0 if you can join immediately.)' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_3, @q2, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_3 AND x.text = '');

-- Q4: expected CTC. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'What is your expected monthly CTC, in INR?', 0, 50, 1, 4, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'What is your expected monthly CTC, in INR?'
);
SELECT career_portal_questionnaire_question_id INTO @q2_4 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'What is your expected monthly CTC, in INR?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_4, @q2, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_4 AND x.text = '');

-- Q5: weekend/roster willingness. type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'I am willing to work weekends and rotational week-offs, as is standard for gym-floor and franchise-facing roles', NULL, NULL, 0, 5, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'I am willing to work weekends and rotational week-offs, as is standard for gym-floor and franchise-facing roles'
);
SELECT career_portal_questionnaire_question_id INTO @q2_5 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'I am willing to work weekends and rotational week-offs, as is standard for gym-floor and franchise-facing roles' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_5, @q2, 'Yes, I confirm', NULL, 'Confirmed availability for weekend/rotational roster', 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_5 AND x.text = 'Yes, I confirm');

-- Q6: location/relocation. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'Which location are you open to working from?', NULL, NULL, 0, 6, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'Which location are you open to working from?'
);
SELECT career_portal_questionnaire_question_id INTO @q2_6 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'Which location are you open to working from?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_6, @q2, 'Noida only', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_6 AND x.text = 'Noida only');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_6, @q2, 'Delhi NCR (Noida, Greater Noida, Delhi, Gurugram)', NULL, NULL, 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_6 AND x.text = 'Delhi NCR (Noida, Greater Noida, Delhi, Gurugram)');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_6, @q2, 'Open to relocate anywhere in India for a WTF Franchisee Gyms role', NULL, NULL, 0, 1, 1, 'Open to Relocate', 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_6 AND x.text = 'Open to relocate anywhere in India for a WTF Franchisee Gyms role');

-- Q7: own transport (relevant to multi-site/franchise travel). type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q2, 'I have a valid driving licence and my own two-wheeler or vehicle for local travel between centres or franchise sites', NULL, NULL, 0, 7, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q2 AND x.text = 'I have a valid driving licence and my own two-wheeler or vehicle for local travel between centres or franchise sites'
);
SELECT career_portal_questionnaire_question_id INTO @q2_7 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q2 AND text = 'I have a valid driving licence and my own two-wheeler or vehicle for local travel between centres or franchise sites' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q2_7, @q2, 'Yes, I confirm', NULL, NULL, 0, 1, 0, 'Own Vehicle', 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q2_7 AND x.text = 'Yes, I confirm');


-- -----------------------------------------------------------------------------
-- B3. Corporate & Professional Roles Screening  (-> job orders 8,12,14,15)
-- -----------------------------------------------------------------------------

-- Q1: years of relevant professional experience. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q3, 'Total years of relevant professional experience in this function (marketing, category management, HR, or finance)?', NULL, NULL, 1, 1, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q3 AND x.text = 'Total years of relevant professional experience in this function (marketing, category management, HR, or finance)?'
);
SELECT career_portal_questionnaire_question_id INTO @q3_1 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q3 AND text = 'Total years of relevant professional experience in this function (marketing, category management, HR, or finance)?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_1, @q3, 'Less than 2 years', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_1 AND x.text = 'Less than 2 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_1, @q3, '2 to 5 years', NULL, NULL, 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_1 AND x.text = '2 to 5 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_1, @q3, '5 to 8 years', NULL, NULL, 0, 1, 0, NULL, 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_1 AND x.text = '5 to 8 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_1, @q3, 'More than 8 years', NULL, NULL, 1, 1, 0, 'Senior Professional Experience', 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_1 AND x.text = 'More than 8 years');

-- Q2: professional qualification. type=4 RADIO. Second nationally-recognised-
-- certification example (requirement 3): CA/CFA/CPA -> hot.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q3, 'Do you hold a professional qualification relevant to this role, such as an MBA, CA, CFA, or CPA?', NULL, NULL, 0, 2, 4
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q3 AND x.text = 'Do you hold a professional qualification relevant to this role, such as an MBA, CA, CFA, or CPA?'
);
SELECT career_portal_questionnaire_question_id INTO @q3_2 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q3 AND text = 'Do you hold a professional qualification relevant to this role, such as an MBA, CA, CFA, or CPA?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_2, @q3, 'No, graduate degree only', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_2 AND x.text = 'No, graduate degree only');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_2, @q3, 'Yes - MBA or equivalent postgraduate degree', NULL, NULL, 0, 1, 0, 'MBA Qualified', 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_2 AND x.text = 'Yes - MBA or equivalent postgraduate degree');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_2, @q3, 'Yes - CA, CFA, CPA, or equivalent finance qualification', NULL, NULL, 1, 1, 0, 'Chartered Accountant/CFA Qualified', 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_2 AND x.text = 'Yes - CA, CFA, CPA, or equivalent finance qualification');

-- Q3: notice period. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q3, 'What is your current notice period, in days?', 0, 50, 1, 3, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q3 AND x.text = 'What is your current notice period, in days?'
);
SELECT career_portal_questionnaire_question_id INTO @q3_3 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q3 AND text = 'What is your current notice period, in days?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_3, @q3, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_3 AND x.text = '');

-- Q4: current CTC. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q3, 'What is your current fixed annual CTC, in INR?', 0, 50, 1, 4, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q3 AND x.text = 'What is your current fixed annual CTC, in INR?'
);
SELECT career_portal_questionnaire_question_id INTO @q3_4 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q3 AND text = 'What is your current fixed annual CTC, in INR?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_4, @q3, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_4 AND x.text = '');

-- Q5: expected CTC. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q3, 'What is your expected annual CTC, in INR?', 0, 50, 1, 5, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q3 AND x.text = 'What is your expected annual CTC, in INR?'
);
SELECT career_portal_questionnaire_question_id INTO @q3_5 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q3 AND text = 'What is your expected annual CTC, in INR?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_5, @q3, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_5 AND x.text = '');

-- Q6: in-office availability. type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q3, 'I am able to work out of the WTF Enterprise head office in Noida, with limited work-from-home flexibility', NULL, NULL, 0, 6, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q3 AND x.text = 'I am able to work out of the WTF Enterprise head office in Noida, with limited work-from-home flexibility'
);
SELECT career_portal_questionnaire_question_id INTO @q3_6 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q3 AND text = 'I am able to work out of the WTF Enterprise head office in Noida, with limited work-from-home flexibility' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q3_6, @q3, 'Yes, I confirm', NULL, 'Confirmed in-office availability at Noida HQ', 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q3_6 AND x.text = 'Yes, I confirm');


-- -----------------------------------------------------------------------------
-- B4. Specialist Clinical Roles Screening  (-> job orders 9, 11)
-- -----------------------------------------------------------------------------

-- Q1: licence/registration held. type=4 RADIO. Third high-signal example
-- (requirement 3): for a regulated clinical role, holding the legally
-- required credential at all is the hot signal.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q4, 'Do you hold the degree and registration required to practise (BPT/MPT with State Physiotherapy Council registration, or a nutrition/dietetics degree with RD or equivalent registration)?', NULL, NULL, 1, 1, 4
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q4 AND x.text = 'Do you hold the degree and registration required to practise (BPT/MPT with State Physiotherapy Council registration, or a nutrition/dietetics degree with RD or equivalent registration)?'
);
SELECT career_portal_questionnaire_question_id INTO @q4_1 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q4 AND text = 'Do you hold the degree and registration required to practise (BPT/MPT with State Physiotherapy Council registration, or a nutrition/dietetics degree with RD or equivalent registration)?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_1, @q4, 'No', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_1 AND x.text = 'No');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_1, @q4, 'Yes', NULL, NULL, 1, 1, 0, 'Licensed Clinical Professional', 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_1 AND x.text = 'Yes');

-- Q2: years of clinical experience. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q4, 'Years of clinical or patient-facing experience after qualification?', NULL, NULL, 1, 2, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q4 AND x.text = 'Years of clinical or patient-facing experience after qualification?'
);
SELECT career_portal_questionnaire_question_id INTO @q4_2 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q4 AND text = 'Years of clinical or patient-facing experience after qualification?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_2, @q4, 'Less than 1 year', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_2 AND x.text = 'Less than 1 year');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_2, @q4, '1 to 3 years', NULL, NULL, 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_2 AND x.text = '1 to 3 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_2, @q4, '3 to 5 years', NULL, NULL, 0, 1, 0, NULL, 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_2 AND x.text = '3 to 5 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_2, @q4, 'More than 5 years', NULL, NULL, 1, 1, 0, 'Senior Clinical Experience', 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_2 AND x.text = 'More than 5 years');

-- Q3: client population / speciality. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q4, 'Which client population have you primarily worked with?', NULL, NULL, 0, 3, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q4 AND x.text = 'Which client population have you primarily worked with?'
);
SELECT career_portal_questionnaire_question_id INTO @q4_3 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q4 AND text = 'Which client population have you primarily worked with?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_3, @q4, 'General wellness or preventive care', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_3 AND x.text = 'General wellness or preventive care');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_3, @q4, 'Weight management or lifestyle disorders', NULL, NULL, 0, 1, 0, 'Weight Management / Lifestyle Disorders', 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_3 AND x.text = 'Weight management or lifestyle disorders');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_3, @q4, 'Post-surgical rehabilitation', NULL, NULL, 0, 1, 0, 'Post-Surgical Rehabilitation', 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_3 AND x.text = 'Post-surgical rehabilitation');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_3, @q4, 'Sports and orthopaedic rehabilitation', NULL, NULL, 0, 1, 0, 'Sports & Orthopaedic Rehabilitation', 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_3 AND x.text = 'Sports and orthopaedic rehabilitation');

-- Q4: notice period. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q4, 'What is your current notice period, in days?', 0, 50, 1, 4, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q4 AND x.text = 'What is your current notice period, in days?'
);
SELECT career_portal_questionnaire_question_id INTO @q4_4 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q4 AND text = 'What is your current notice period, in days?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_4, @q4, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_4 AND x.text = '');

-- Q5: expected CTC. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q4, 'What is your expected monthly CTC, in INR?', 0, 50, 1, 5, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q4 AND x.text = 'What is your expected monthly CTC, in INR?'
);
SELECT career_portal_questionnaire_question_id INTO @q4_5 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q4 AND text = 'What is your expected monthly CTC, in INR?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_5, @q4, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_5 AND x.text = '');

-- Q6: full-time on-site availability. type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q4, 'I am able to be based full-time at our Noida clinical or wellness centre', NULL, NULL, 0, 6, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q4 AND x.text = 'I am able to be based full-time at our Noida clinical or wellness centre'
);
SELECT career_portal_questionnaire_question_id INTO @q4_6 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q4 AND text = 'I am able to be based full-time at our Noida clinical or wellness centre' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q4_6, @q4, 'Yes, I confirm', NULL, 'Confirmed full-time availability at Noida clinical centre', 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q4_6 AND x.text = 'Yes, I confirm');


-- -----------------------------------------------------------------------------
-- B5. Technical & Field Service Screening  (-> job order 13)
-- -----------------------------------------------------------------------------

-- Q1: years of equipment-service experience. type=2 SELECT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q5, 'Years of hands-on experience servicing or repairing gym and fitness equipment (treadmills, strength machines, electricals)?', NULL, NULL, 1, 1, 2
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q5 AND x.text = 'Years of hands-on experience servicing or repairing gym and fitness equipment (treadmills, strength machines, electricals)?'
);
SELECT career_portal_questionnaire_question_id INTO @q5_1 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q5 AND text = 'Years of hands-on experience servicing or repairing gym and fitness equipment (treadmills, strength machines, electricals)?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_1, @q5, 'Less than 1 year', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_1 AND x.text = 'Less than 1 year');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_1, @q5, '1 to 3 years', NULL, NULL, 0, 1, 0, NULL, 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_1 AND x.text = '1 to 3 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_1, @q5, '3 to 5 years', NULL, NULL, 0, 1, 0, NULL, 3 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_1 AND x.text = '3 to 5 years');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_1, @q5, 'More than 5 years', NULL, NULL, 1, 1, 0, 'Senior Equipment Technician', 4 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_1 AND x.text = 'More than 5 years');

-- Q2: trade certification. type=4 RADIO.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q5, 'Do you hold an ITI or diploma certification in Electrical, Mechanical, or Electronics?', NULL, NULL, 0, 2, 4
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q5 AND x.text = 'Do you hold an ITI or diploma certification in Electrical, Mechanical, or Electronics?'
);
SELECT career_portal_questionnaire_question_id INTO @q5_2 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q5 AND text = 'Do you hold an ITI or diploma certification in Electrical, Mechanical, or Electronics?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_2, @q5, 'No', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_2 AND x.text = 'No');
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_2, @q5, 'Yes', NULL, NULL, 0, 1, 0, 'ITI/Diploma Certified Technician', 2 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_2 AND x.text = 'Yes');

-- Q3: notice period. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q5, 'What is your current notice period, in days?', 0, 50, 1, 3, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q5 AND x.text = 'What is your current notice period, in days?'
);
SELECT career_portal_questionnaire_question_id INTO @q5_3 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q5 AND text = 'What is your current notice period, in days?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_3, @q5, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_3 AND x.text = '');

-- Q4: expected CTC. type=1 TEXT.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q5, 'What is your expected monthly CTC, in INR?', 0, 50, 1, 4, 1
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q5 AND x.text = 'What is your expected monthly CTC, in INR?'
);
SELECT career_portal_questionnaire_question_id INTO @q5_4 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q5 AND text = 'What is your expected monthly CTC, in INR?' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_4, @q5, '', NULL, NULL, 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_4 AND x.text = '');

-- Q5: own transport for field visits. type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q5, 'I have a valid driving licence and my own two-wheeler for daily field travel to partner and franchise gyms across the NCR', NULL, NULL, 0, 5, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q5 AND x.text = 'I have a valid driving licence and my own two-wheeler for daily field travel to partner and franchise gyms across the NCR'
);
SELECT career_portal_questionnaire_question_id INTO @q5_5 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q5 AND text = 'I have a valid driving licence and my own two-wheeler for daily field travel to partner and franchise gyms across the NCR' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_5, @q5, 'Yes, I confirm', NULL, 'Confirmed own vehicle for field travel', 0, 1, 0, 'Own Vehicle', 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_5 AND x.text = 'Yes, I confirm');

-- Q6: shift / on-call willingness. type=3 CHECKBOX.
INSERT INTO career_portal_questionnaire_question
    (career_portal_questionnaire_id, text, minimum_length, maximum_length, required, position, type)
SELECT @q5, 'I am willing to work rotational shifts and be on-call for urgent equipment breakdown support', NULL, NULL, 0, 6, 3
FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_id, text FROM career_portal_questionnaire_question) x
    WHERE x.career_portal_questionnaire_id = @q5 AND x.text = 'I am willing to work rotational shifts and be on-call for urgent equipment breakdown support'
);
SELECT career_portal_questionnaire_question_id INTO @q5_6 FROM career_portal_questionnaire_question
    WHERE career_portal_questionnaire_id = @q5 AND text = 'I am willing to work rotational shifts and be on-call for urgent equipment breakdown support' LIMIT 1;
INSERT INTO career_portal_questionnaire_answer (career_portal_questionnaire_question_id, career_portal_questionnaire_id, text, action_source, action_notes, action_is_hot, action_is_active, action_can_relocate, action_key_skills, position)
SELECT @q5_6, @q5, 'Yes, I confirm', NULL, 'Confirmed availability for on-call breakdown support', 0, 1, 0, NULL, 1 FROM DUAL WHERE NOT EXISTS (
    SELECT 1 FROM (SELECT career_portal_questionnaire_question_id, text FROM career_portal_questionnaire_answer) x WHERE x.career_portal_questionnaire_question_id = @q5_6 AND x.text = 'Yes, I confirm');


-- -----------------------------------------------------------------------------
-- SECTION C — Attach each questionnaire to its job orders
-- -----------------------------------------------------------------------------
-- Linkage: joborder.questionnaire_id -> career_portal_questionnaire.career_portal_questionnaire_id
-- (lib/JobOrders.php:213 write side, :438/:547/:676 read side; consumed at
-- apply-time in modules/careers/CareersUI.php:843-854). Guarded by
-- `questionnaire_id IS NULL` so this is idempotent AND never overwrites a
-- questionnaire a recruiter has since attached by hand.

UPDATE joborder
SET questionnaire_id = @q1
WHERE joborder_id IN (1, 7)
  AND questionnaire_id IS NULL;

UPDATE joborder
SET questionnaire_id = @q2
WHERE joborder_id IN (2, 3, 4, 5, 6, 10)
  AND questionnaire_id IS NULL;

UPDATE joborder
SET questionnaire_id = @q3
WHERE joborder_id IN (8, 12, 14, 15)
  AND questionnaire_id IS NULL;

UPDATE joborder
SET questionnaire_id = @q4
WHERE joborder_id IN (9, 11)
  AND questionnaire_id IS NULL;

UPDATE joborder
SET questionnaire_id = @q5
WHERE joborder_id IN (13)
  AND questionnaire_id IS NULL;


COMMIT;


-- -----------------------------------------------------------------------------
-- OPTIONAL: verification query (read-only, not executed by this file — run
-- by hand after loading if you want to eyeball the result)
-- -----------------------------------------------------------------------------
-- SELECT jo.joborder_id, jo.title, cpq.title AS questionnaire
-- FROM joborder jo
-- LEFT JOIN career_portal_questionnaire cpq
--   ON cpq.career_portal_questionnaire_id = jo.questionnaire_id
-- WHERE jo.joborder_id IN (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15)
-- ORDER BY jo.joborder_id;
