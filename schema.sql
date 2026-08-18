-- ============================================================================
-- HR & Corporate Management Cockpit — Phase 0 Database Schema
-- Target: SQLite (encrypted at rest via SQLCipher at the application layer)
-- IMPORTANT: application must execute `PRAGMA foreign_keys = ON;` on every
-- connection open — SQLite does not enable FK enforcement by default.
-- ============================================================================

PRAGMA foreign_keys = ON;

-- ============================================================================
-- SECTION 1: CORE REFERENCE DATA
-- ============================================================================

CREATE TABLE company (
    id              TEXT PRIMARY KEY,              -- UUID
    code            TEXT NOT NULL UNIQUE,           -- e.g. 'TTIB','TTLIB','TTMWM'
    name            TEXT NOT NULL,
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Department is a lightweight master list, scoped per company, but a
-- department NAME may recur across companies (e.g., "HR & GA" exists in
-- both TTIB and TTMWM) — treated as distinct rows, not shared, since
-- reporting lines and headcount differ per entity.
CREATE TABLE department (
    id              TEXT PRIMARY KEY,
    company_id      TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    name            TEXT NOT NULL,
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (company_id, name)
);

CREATE TABLE position (
    id              TEXT PRIMARY KEY,
    company_id      TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    title           TEXT NOT NULL,
    job_grade       TEXT,                            -- nullable; see DECISION REQUIRED #4
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (company_id, title, job_grade)
);

-- ============================================================================
-- SECTION 2: PERSON / EMPLOYMENT HISTORY MODEL  (core of this revision)
-- ============================================================================

-- PERSON = the durable identity. One row per real human being, regardless
-- of how many companies/episodes they have worked across.
CREATE TABLE person (
    id                  TEXT PRIMARY KEY,             -- UUID, the durable identity
    full_name           TEXT NOT NULL,
    full_name_local     TEXT,                          -- Thai-script name if different
    date_of_birth       TEXT,                          -- nullable, see DECISION REQUIRED #1
    national_id_hash    TEXT,                           -- hashed, NOT plaintext; optional matching key
    email               TEXT,
    phone               TEXT,
    is_active_person     INTEGER NOT NULL DEFAULT 1 CHECK (is_active_person IN (0,1)),
                          -- becomes 0 only if the Person record itself is
                          -- deprecated/merged into another (see merge_log)
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at          TEXT NOT NULL DEFAULT (datetime('now')),
    source_type         TEXT NOT NULL DEFAULT 'Manual Entry'
                          CHECK (source_type IN
                            ('Manual Entry','Excel Import','CSV Import',
                             'System Generated','Migration','API','Other')),
    created_by          TEXT NOT NULL DEFAULT 'system',
    updated_by          TEXT
);

CREATE INDEX idx_person_full_name ON person(full_name);
CREATE INDEX idx_person_national_id_hash ON person(national_id_hash);

-- If two Person records are later confirmed to be the same human being
-- (discovered after both already exist), record the merge decision here
-- rather than silently deleting one — preserves audit trail per Section 20
-- ("prefer reversible data operations").
CREATE TABLE person_merge_log (
    id                  TEXT PRIMARY KEY,
    surviving_person_id TEXT NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
    merged_person_id    TEXT NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
    reason              TEXT NOT NULL,
    decided_by          TEXT NOT NULL,
    decided_at          TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (merged_person_id)   -- a merged-away person can only be merged once
);

-- EMPLOYMENT EPISODE = one continuous period of employment at ONE company.
-- A company-to-company transfer closes one episode and opens a new one.
-- Internal promotions/department moves WITHIN the same company/episode are
-- tracked in employment_episode_change (below), not as a new episode.
CREATE TABLE employment_episode (
    id                      TEXT PRIMARY KEY,
    person_id               TEXT NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
    company_id              TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    employee_number         TEXT NOT NULL,       -- unique WITHIN a company, not globally
    start_date              TEXT NOT NULL,
    end_date                TEXT,                 -- NULL = ongoing
    employment_status       TEXT NOT NULL DEFAULT 'Active'
                              CHECK (employment_status IN
                                ('Active','On Leave','Transferred',
                                 'Resigned','Terminated','Retired','Other')),
    employment_type         TEXT
                              CHECK (employment_type IS NULL OR employment_type IN
                                ('Permanent','Fixed-Term','Probation','Contractor','Intern')),
    department_id           TEXT REFERENCES department(id) ON DELETE RESTRICT,
    position_id             TEXT REFERENCES position(id) ON DELETE RESTRICT,
    manager_person_id       TEXT REFERENCES person(id) ON DELETE SET NULL,
    location                TEXT,
    movement_type            TEXT              -- how this episode began
                              CHECK (movement_type IS NULL OR movement_type IN
                                ('New Hire','Internal Transfer In','Rehire','Other')),
    probation_end_date       TEXT,
    notes                     TEXT,
    source_type               TEXT NOT NULL DEFAULT 'Manual Entry'
                              CHECK (source_type IN
                                ('Manual Entry','Excel Import','CSV Import',
                                 'System Generated','Migration','API','Other')),
    source_import_batch_id     TEXT REFERENCES import_batch(id) ON DELETE SET NULL,
                              -- Forward reference: import_batch is defined later
                              -- in Section 5. SQLite does not validate FK target
                              -- existence at CREATE TABLE time, only at INSERT
                              -- time (with PRAGMA foreign_keys=ON), so this is
                              -- safe as long as import_batch exists before any
                              -- row here sets this column.
    created_at                TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at                TEXT NOT NULL DEFAULT (datetime('now')),
    created_by                 TEXT NOT NULL DEFAULT 'system',
    updated_by                 TEXT,

    UNIQUE (company_id, employee_number, start_date),
    CHECK (end_date IS NULL OR end_date >= start_date)
);

CREATE INDEX idx_episode_person ON employment_episode(person_id);
CREATE INDEX idx_episode_company ON employment_episode(company_id);
CREATE INDEX idx_episode_status ON employment_episode(employment_status);
CREATE INDEX idx_episode_dates ON employment_episode(start_date, end_date);

-- Point-in-time changes WITHIN a single episode: promotions, department
-- moves, manager changes, job grade changes — without ending the episode.
CREATE TABLE employment_episode_change (
    id                  TEXT PRIMARY KEY,
    episode_id          TEXT NOT NULL REFERENCES employment_episode(id) ON DELETE CASCADE,
    effective_date       TEXT NOT NULL,
    change_type          TEXT NOT NULL
                          CHECK (change_type IN
                            ('Promotion','Department Change','Position Change',
                             'Manager Change','Grade Change','Location Change','Other')),
    previous_department_id  TEXT REFERENCES department(id),
    new_department_id       TEXT REFERENCES department(id),
    previous_position_id     TEXT REFERENCES position(id),
    new_position_id           TEXT REFERENCES position(id),
    previous_manager_id       TEXT REFERENCES person(id),
    new_manager_id             TEXT REFERENCES person(id),
    notes                      TEXT,
    created_at                 TEXT NOT NULL DEFAULT (datetime('now')),
    created_by                  TEXT NOT NULL DEFAULT 'system'
);

CREATE INDEX idx_episode_change_episode ON employment_episode_change(episode_id, effective_date);

-- ============================================================================
-- SECTION 3: TASK / QUICK CAPTURE
-- ============================================================================

CREATE TABLE quick_capture (
    id              TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    company_id      TEXT REFERENCES company(id) ON DELETE SET NULL,
    category        TEXT,
    priority        TEXT CHECK (priority IS NULL OR priority IN ('Low','Medium','Normal','High','Urgent')),
                      -- WIDENED in Stage C1 (see Section 15 note at end of
                      -- file): original set was ('Low','Medium','High').
                      -- 'Normal' and 'Urgent' added per the C1 spec's
                      -- explicit Low/Normal/High/Urgent priority scheme.
                      -- 'Medium' is kept so it remains a non-breaking
                      -- superset — no existing row or code path is
                      -- invalidated by this widening.
    due_date        TEXT,
    note            TEXT,
    status          TEXT NOT NULL DEFAULT 'Inbox'
                      CHECK (status IN ('Inbox','Converted','Archived','Deleted')),
    converted_task_id TEXT REFERENCES task(id) ON DELETE SET NULL,
                                 -- Forward reference to task, defined immediately
                                 -- below — safe per the same SQLite behavior noted
                                 -- above for source_import_batch_id.
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE task (
    id                          TEXT PRIMARY KEY,
    title                       TEXT NOT NULL,
    company_id                  TEXT REFERENCES company(id) ON DELETE SET NULL,
    category                    TEXT,
    priority                    TEXT CHECK (priority IS NULL OR priority IN ('Low','Medium','Normal','High','Urgent')),
                                  -- WIDENED in Stage C1 — see note on
                                  -- quick_capture.priority above; same
                                  -- non-breaking superset rationale.
    due_date                    TEXT,
    status                      TEXT NOT NULL DEFAULT 'Open'
                                  CHECK (status IN
                                    ('Inbox','Open','In Progress','Waiting For',
                                     'Completed','Cancelled','Archived')),
    owner                        TEXT NOT NULL DEFAULT 'me',
    notes                        TEXT,
    recurrence_rule               TEXT,             -- nullable; e.g. iCal RRULE subset
    management_attention_flag      INTEGER NOT NULL DEFAULT 0 CHECK (management_attention_flag IN (0,1)),

    -- Waiting For sub-fields (required at application layer when status = 'Waiting For')
    waiting_for_party             TEXT,
    waiting_for_what               TEXT,
    waiting_for_expected_date       TEXT,
    waiting_for_followup_date        TEXT,

    source_capture_id              TEXT REFERENCES quick_capture(id) ON DELETE SET NULL,

    created_at                      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at                      TEXT NOT NULL DEFAULT (datetime('now')),

    CHECK (
        status <> 'Waiting For' OR
        (waiting_for_party IS NOT NULL AND waiting_for_what IS NOT NULL
         AND waiting_for_expected_date IS NOT NULL AND waiting_for_followup_date IS NOT NULL)
    )
);

CREATE INDEX idx_task_status ON task(status);
CREATE INDEX idx_task_due_date ON task(due_date);
CREATE INDEX idx_task_followup ON task(waiting_for_followup_date);
CREATE INDEX idx_task_company ON task(company_id);

-- ============================================================================
-- SECTION 4: DOCUMENT VAULT
-- ============================================================================

CREATE TABLE document (
    id                  TEXT PRIMARY KEY,
    storage_uuid         TEXT NOT NULL UNIQUE,     -- internal encrypted file reference
    display_name          TEXT NOT NULL,
    classification         TEXT NOT NULL
                          CHECK (classification IN
                            ('Internal','Confidential','Highly Confidential','Personal Data')),
    company_id             TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    document_type            TEXT NOT NULL,
    owner                     TEXT NOT NULL DEFAULT 'me',
    retention_period_months     INTEGER,
    retention_review_date        TEXT,
    active_version_id             TEXT,          -- points to document_version.id (set after insert)
    status                        TEXT NOT NULL DEFAULT 'Active'
                              CHECK (status IN ('Active','Archived','Destroyed')),
    created_at                    TEXT NOT NULL DEFAULT (datetime('now')),
    created_by                     TEXT NOT NULL DEFAULT 'me'
);

CREATE TABLE document_version (
    id                  TEXT PRIMARY KEY,
    document_id          TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    version_number         INTEGER NOT NULL,
    storage_uuid             TEXT NOT NULL UNIQUE,   -- each version is a separate encrypted blob
    file_size_bytes            INTEGER,
    uploaded_at                 TEXT NOT NULL DEFAULT (datetime('now')),
    uploaded_by                  TEXT NOT NULL DEFAULT 'me',
    UNIQUE (document_id, version_number)
);

CREATE INDEX idx_document_classification ON document(classification);
CREATE INDEX idx_document_company ON document(company_id);
CREATE INDEX idx_document_retention ON document(retention_review_date);

-- ============================================================================
-- SECTION 5: IMPORT SYSTEM
-- ============================================================================

CREATE TABLE import_mapping_template (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL UNIQUE,
    target_entity    TEXT NOT NULL DEFAULT 'employment_episode',
    mapping_json      TEXT NOT NULL,   -- {"Employee ID":"employee_number", ...}
    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE import_batch (
    id                      TEXT PRIMARY KEY,
    file_name                TEXT NOT NULL,
    file_type                 TEXT NOT NULL CHECK (file_type IN ('xlsx','xls','csv')),
    imported_by                TEXT NOT NULL DEFAULT 'me',
    imported_at                 TEXT NOT NULL DEFAULT (datetime('now')),
    mapping_template_id          TEXT REFERENCES import_mapping_template(id) ON DELETE SET NULL,
    row_count                     INTEGER NOT NULL DEFAULT 0,
    success_count                  INTEGER NOT NULL DEFAULT 0,
    updated_count                   INTEGER NOT NULL DEFAULT 0,
    skipped_count                    INTEGER NOT NULL DEFAULT 0,
    failed_count                      INTEGER NOT NULL DEFAULT 0,
    warning_count                      INTEGER NOT NULL DEFAULT 0,
    validation_result_json               TEXT,      -- full validation report, for audit/review
    status                                 TEXT NOT NULL DEFAULT 'Draft'
                              CHECK (status IN ('Draft','Previewed','Committed','Rolled Back')),
    rolled_back_at                          TEXT,
    rolled_back_by                           TEXT
);

CREATE TABLE import_row_result (
    id                  TEXT PRIMARY KEY,
    import_batch_id      TEXT NOT NULL REFERENCES import_batch(id) ON DELETE CASCADE,
    row_number             INTEGER NOT NULL,
    raw_row_json             TEXT NOT NULL,          -- original source row, preserved as-is
    outcome                    TEXT NOT NULL
                          CHECK (outcome IN ('New','Updated','Skipped','Failed','Warning')),
    result_person_id             TEXT REFERENCES person(id) ON DELETE SET NULL,
    result_episode_id              TEXT REFERENCES employment_episode(id) ON DELETE SET NULL,
    error_messages                  TEXT,           -- JSON array
    warning_messages                 TEXT           -- JSON array
);

CREATE INDEX idx_import_row_batch ON import_row_result(import_batch_id);

-- Person matching decisions made during import (or manual linking) — every
-- non-exact match requires a logged human decision per Section 10.
CREATE TABLE person_match_decision (
    id                      TEXT PRIMARY KEY,
    import_row_result_id      TEXT REFERENCES import_row_result(id) ON DELETE CASCADE,
    candidate_person_id         TEXT NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
    match_confidence              TEXT NOT NULL
                          CHECK (match_confidence IN
                            ('Exact Match','High Confidence Match','Possible Match','No Match')),
    matched_on_fields                TEXT NOT NULL,   -- JSON array, e.g. ["full_name","company"]
    decision                          TEXT NOT NULL
                          CHECK (decision IN ('Confirmed Link','Rejected - New Person','Deferred')),
    decided_by                          TEXT NOT NULL DEFAULT 'me',
    decided_at                           TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================================
-- SECTION 6: COMPLIANCE / AUDIT / CONTRACT
-- ============================================================================

CREATE TABLE compliance_item (
    id                  TEXT PRIMARY KEY,
    company_id            TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    requirement             TEXT NOT NULL,
    category                  TEXT NOT NULL,      -- PDPA / OIC / Lloyd's / ISO / Labour Law / Internal
    frequency                  TEXT,               -- e.g. 'Quarterly','Annual','One-off'
    responsible_person           TEXT NOT NULL DEFAULT 'me',
    due_date                      TEXT,
    status                         TEXT NOT NULL DEFAULT 'Not Started'
                          CHECK (status IN
                            ('Not Started','In Progress','Under Review','Compliant','Non-Compliant')),
    risk_level                      TEXT CHECK (risk_level IS NULL OR risk_level IN ('Low','Medium','High')),
    last_review_date                  TEXT,
    next_review_date                   TEXT,
    notes                                TEXT,
    created_at                            TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at                             TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_compliance_company ON compliance_item(company_id);
CREATE INDEX idx_compliance_next_review ON compliance_item(next_review_date);

CREATE TABLE audit_finding (
    id                  TEXT PRIMARY KEY,
    company_id            TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    source_compliance_id    TEXT REFERENCES compliance_item(id) ON DELETE SET NULL,
    finding                   TEXT NOT NULL,
    source                     TEXT NOT NULL,      -- Internal/External/ISO/BOD
    severity                    TEXT NOT NULL CHECK (severity IN ('Low','Medium','High')),
    root_cause                    TEXT,
    corrective_action                TEXT,
    preventive_action                 TEXT,
    owner                               TEXT NOT NULL DEFAULT 'me',
    due_date                            TEXT,
    verification_date                    TEXT,
    status                                 TEXT NOT NULL DEFAULT 'Open'
                          CHECK (status IN
                            ('Open','Root Cause Identified','Action In Progress',
                             'Pending Verification','Closed')),
    created_at                             TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at                              TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_audit_company ON audit_finding(company_id);
CREATE INDEX idx_audit_status ON audit_finding(status);

CREATE TABLE contract (
    id                  TEXT PRIMARY KEY,
    company_id            TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    contract_name           TEXT NOT NULL,
    counterparty              TEXT NOT NULL,
    contract_type               TEXT,
    owner                         TEXT NOT NULL DEFAULT 'me',
    start_date                     TEXT,
    end_date                        TEXT,
    renewal_date                     TEXT,
    notice_period_days                 INTEGER,
    auto_renewal                        INTEGER NOT NULL DEFAULT 0 CHECK (auto_renewal IN (0,1)),
    key_obligation                       TEXT,
    risk_level                            TEXT CHECK (risk_level IS NULL OR risk_level IN ('Low','Medium','High')),
    status                                  TEXT NOT NULL DEFAULT 'Draft'
                          CHECK (status IN
                            ('Draft','Under Review','Pending Approval','Active',
                             'Renewed','Expired','Terminated')),
    created_at                              TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at                               TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date)
);

CREATE INDEX idx_contract_company ON contract(company_id);
CREATE INDEX idx_contract_end_date ON contract(end_date);

-- ============================================================================
-- SECTION 7: GOVERNANCE / SNAPSHOT / PRESIDENT REPORT
-- (Phase 0 schema, Phase 1.5 UI — per locked decision)
-- ============================================================================

CREATE TABLE governance_meeting (
    id                  TEXT PRIMARY KEY,
    company_id            TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    meeting_type            TEXT NOT NULL CHECK (meeting_type IN ('BOD','AGM','EGM')),
    meeting_date              TEXT,
    status                      TEXT NOT NULL DEFAULT 'Planning'
                          CHECK (status IN
                            ('Planning','Agenda Set','Documents Prepared','Meeting Held',
                             'Minutes Drafted','Minutes Finalized','Resolutions Filed','Closed')),
    agenda_summary                TEXT,
    resolutions_summary             TEXT,
    filing_deadline                  TEXT,
    created_at                        TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE governance_action (
    id                  TEXT PRIMARY KEY,
    meeting_id            TEXT NOT NULL REFERENCES governance_meeting(id) ON DELETE CASCADE,
    description             TEXT NOT NULL,
    owner_person_id           TEXT REFERENCES person(id) ON DELETE SET NULL,
    due_date                   TEXT,
    status                       TEXT NOT NULL DEFAULT 'Open'
                          CHECK (status IN ('Open','In Progress','Completed','Cancelled')),
    created_at                    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE snapshot (
    id                  TEXT PRIMARY KEY,
    snapshot_date          TEXT NOT NULL,
    company_scope             TEXT NOT NULL DEFAULT 'All',   -- 'All' or a company_id
    rollup_json                TEXT NOT NULL,                 -- captured counts, immutable
    narrative_notes               TEXT,
    status                          TEXT NOT NULL DEFAULT 'Finalized' CHECK (status IN ('Draft','Finalized')),
    created_at                       TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (snapshot_date, company_scope)
);

CREATE TABLE president_report (
    id                  TEXT PRIMARY KEY,
    company_scope          TEXT NOT NULL DEFAULT 'All',
    period_type              TEXT NOT NULL CHECK (period_type IN ('Monthly','Quarterly','Custom')),
    period_start               TEXT,
    period_end                  TEXT,
    template                      TEXT NOT NULL CHECK (template IN ('A - Monthly Summary','B - Issue Action Risk')),
    recommendations_text            TEXT,
    exported_format                  TEXT CHECK (exported_format IS NULL OR exported_format IN ('PDF','Excel')),
    exported_at                       TEXT,
    included_highly_confidential        INTEGER NOT NULL DEFAULT 0 CHECK (included_highly_confidential IN (0,1)),
    created_at                            TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================================
-- SECTION 8: JUNCTION TABLES (explicit, per locked architectural decision)
-- ============================================================================

CREATE TABLE task_employee_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, person_id)
);

CREATE TABLE task_contract_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    contract_id TEXT NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, contract_id)
);

CREATE TABLE task_compliance_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    compliance_id TEXT NOT NULL REFERENCES compliance_item(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, compliance_id)
);

CREATE TABLE task_audit_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    audit_finding_id TEXT NOT NULL REFERENCES audit_finding(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, audit_finding_id)
);

CREATE TABLE task_governance_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    governance_action_id TEXT NOT NULL REFERENCES governance_action(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, governance_action_id)
);

CREATE TABLE task_document_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, document_id)
);

CREATE TABLE document_employee_link (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (document_id, person_id)
);

CREATE TABLE document_contract_link (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    contract_id TEXT NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (document_id, contract_id)
);

CREATE TABLE document_compliance_link (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    compliance_id TEXT NOT NULL REFERENCES compliance_item(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (document_id, compliance_id)
);

CREATE TABLE document_audit_link (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    audit_finding_id TEXT NOT NULL REFERENCES audit_finding(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (document_id, audit_finding_id)
);

CREATE TABLE document_governance_link (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    governance_action_id TEXT NOT NULL REFERENCES governance_action(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (document_id, governance_action_id)
);

-- ============================================================================
-- SECTION 9: SECURITY / RECOVERY KEY
-- ============================================================================

CREATE TABLE security_setting (
    id                          TEXT PRIMARY KEY DEFAULT 'singleton',
    passphrase_hash               TEXT NOT NULL,        -- Argon2id verification hash, never the passphrase itself
    kdf_salt                        TEXT NOT NULL,
    recovery_key_enabled              INTEGER NOT NULL DEFAULT 0 CHECK (recovery_key_enabled IN (0,1)),
    recovery_key_wrapped_secret          TEXT,            -- master key wrapped BY the recovery key, never plaintext
    recovery_key_hash                     TEXT,            -- verification hash of the recovery key itself
    recovery_key_created_at                TEXT,
    recovery_key_last_regenerated_at         TEXT,
    auto_lock_timeout_minutes                  INTEGER NOT NULL DEFAULT 10,
    CHECK (
        (recovery_key_enabled = 0) OR
        (recovery_key_enabled = 1 AND recovery_key_wrapped_secret IS NOT NULL AND recovery_key_hash IS NOT NULL)
    )
);

CREATE TABLE recovery_event (
    id                  TEXT PRIMARY KEY,
    event_type            TEXT NOT NULL CHECK (event_type IN
                            ('Recovery Key Generated','Recovery Key Regenerated',
                             'Recovery Performed - New Passphrase Set','Recovery Key Disabled')),
    occurred_at              TEXT NOT NULL DEFAULT (datetime('now')),
    notes                     TEXT
);

-- ============================================================================
-- SECTION 10: BACKUP (3-LEVEL MODEL)
-- ============================================================================

CREATE TABLE backup_event (
    id                  TEXT PRIMARY KEY,
    level                 INTEGER NOT NULL CHECK (level IN (1,2,3)),
    event_type              TEXT NOT NULL,     -- 'Backup Created','Off-Machine Copy Confirmed','Restore Test'
    occurred_at               TEXT NOT NULL DEFAULT (datetime('now')),
    file_reference               TEXT,           -- backup archive identifier, not a raw path
    integrity_hash                 TEXT,
    result                          TEXT CHECK (result IS NULL OR result IN ('Success','Failure','Issues Found')),
    findings_notes                    TEXT,
    next_due_date                      TEXT
);

CREATE INDEX idx_backup_level_date ON backup_event(level, occurred_at);

-- ============================================================================
-- SECTION 11: WEEKLY REVIEW SESSION LOG
-- ============================================================================

CREATE TABLE weekly_review_session (
    id                  TEXT PRIMARY KEY,
    started_at             TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at             TEXT,
    items_reviewed_count       INTEGER,
    notes                        TEXT
);

-- ============================================================================
-- SECTION 12: SYSTEM-WIDE AUDIT LOG (append-only)
-- ============================================================================

CREATE TABLE audit_log (
    id                  TEXT PRIMARY KEY,
    occurred_at            TEXT NOT NULL DEFAULT (datetime('now')),
    actor                    TEXT NOT NULL DEFAULT 'me',
    action                     TEXT NOT NULL CHECK (action IN
                          ('Create','Update','Delete','Export','View Sensitive',
                           'Login','Login Failed','Backup','Import','Permanent Destroy',
                           'Recovery')),
    entity_type                 TEXT NOT NULL,
    entity_id                     TEXT,
    old_value_json                  TEXT,
    new_value_json                    TEXT,
    classification_involved              TEXT,
    notes                                  TEXT
);

CREATE INDEX idx_audit_log_entity ON audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_log_action ON audit_log(action);
CREATE INDEX idx_audit_log_date ON audit_log(occurred_at);

-- ============================================================================
-- SECTION 13 (ADDITIVE, Stage A): AUDIT LOG IMMUTABILITY ENFORCEMENT
-- Added during Stage A Core Foundation implementation to close a gap
-- identified while building the audit module: the Phase 0 design required
-- "Audit log rows must not be editable by a normal application user" but
-- the original schema.sql relied on application-layer discipline only.
-- This is an ADDITIVE enforcement mechanism (new triggers), not a
-- redesign of any existing table — no existing table definition, column,
-- or constraint above is changed by this section.
-- ============================================================================

CREATE TRIGGER trg_audit_log_no_update
BEFORE UPDATE ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'audit_log rows are immutable and cannot be updated');
END;

CREATE TRIGGER trg_audit_log_no_delete
BEFORE DELETE ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'audit_log rows are immutable and cannot be deleted');
END;

-- ============================================================================
-- SECTION 14 (ADDITIVE, Stage B3): FINANCE & COST MANAGEMENT
-- Added per the B3 spec. Purely additive — no existing table (all 38 from
-- Phase 0 plus the Section 13 audit triggers) is altered. Reuses the
-- existing person/employment_episode/company/department/document model
-- rather than duplicating employee master data, per the B3 "Critical
-- Architecture Principle" instruction.
--
-- Money is stored as INTEGER cents (never FLOAT/REAL) to avoid floating-
-- point rounding errors in financial calculations, per the B3 instruction
-- "Do NOT store money as floating-point values."
-- ============================================================================

CREATE TABLE cost_center (
    id              TEXT PRIMARY KEY,
    company_id      TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    code            TEXT NOT NULL,
    name            TEXT NOT NULL,
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (company_id, code)
);

-- Configurable expense categories (Section 4 — "Do NOT hard-code the
-- categories permanently"). Ships with no rows; the application seeds the
-- suggested Staff Cost / General Expense lists on first run as ordinary
-- editable data, not as a hard-coded enum.
CREATE TABLE expense_category (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL UNIQUE,
    category_type   TEXT NOT NULL CHECK (category_type IN ('Staff Cost', 'General Expense')),
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE budget (
    id                  TEXT PRIMARY KEY,
    fiscal_year         INTEGER NOT NULL,
    company_id          TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    department_id       TEXT REFERENCES department(id) ON DELETE RESTRICT,
    cost_center_id      TEXT REFERENCES cost_center(id) ON DELETE RESTRICT,
    category_id         TEXT NOT NULL REFERENCES expense_category(id) ON DELETE RESTRICT,
    annual_amount_cents INTEGER NOT NULL CHECK (annual_amount_cents >= 0),
    currency            TEXT NOT NULL DEFAULT 'THB',
    owner               TEXT,
    notes               TEXT,
    status              TEXT NOT NULL DEFAULT 'Draft' CHECK (status IN ('Draft','Approved','Closed')),
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    created_by          TEXT NOT NULL DEFAULT 'me',
    -- One budget line per (year, company, department, cost_center, category)
    -- combination — department/cost_center are nullable, so this uniqueness
    -- is enforced at the application layer (see finance.rs), not here,
    -- since SQLite UNIQUE treats NULLs as distinct and would not catch
    -- duplicates where both are NULL.
    UNIQUE (fiscal_year, company_id, department_id, cost_center_id, category_id)
);

CREATE INDEX idx_budget_year_company ON budget(fiscal_year, company_id);

-- Monthly allocation breakdown of an annual budget. Sum of all 12 months
-- for a given budget_id should reconcile to budget.annual_amount_cents —
-- enforced at the application layer in finance.rs (a CHECK constraint
-- cannot sum across sibling rows in SQLite).
CREATE TABLE budget_monthly_allocation (
    id                  TEXT PRIMARY KEY,
    budget_id           TEXT NOT NULL REFERENCES budget(id) ON DELETE CASCADE,
    month               INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    amount_cents        INTEGER NOT NULL CHECK (amount_cents >= 0),
    UNIQUE (budget_id, month)
);

CREATE TABLE expense (
    id                      TEXT PRIMARY KEY,
    expense_date            TEXT NOT NULL,
    fiscal_year             INTEGER NOT NULL,
    month                   INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    company_id              TEXT NOT NULL REFERENCES company(id) ON DELETE RESTRICT,
    department_id           TEXT REFERENCES department(id) ON DELETE RESTRICT,
    cost_center_id          TEXT REFERENCES cost_center(id) ON DELETE RESTRICT,
    category_id             TEXT NOT NULL REFERENCES expense_category(id) ON DELETE RESTRICT,
    description             TEXT NOT NULL,
    amount_cents            INTEGER NOT NULL CHECK (amount_cents >= 0),
    currency                TEXT NOT NULL DEFAULT 'THB',
    vendor_payee            TEXT,
    -- Staff-cost linkage: reuses the EXISTING person/employment_episode
    -- model rather than duplicating employee master data (Section 2/6).
    employee_person_id      TEXT REFERENCES person(id) ON DELETE RESTRICT,
    employment_episode_id   TEXT REFERENCES employment_episode(id) ON DELETE RESTRICT,
    budget_id               TEXT REFERENCES budget(id) ON DELETE SET NULL,
    status                  TEXT NOT NULL DEFAULT 'Draft' CHECK (status IN ('Draft','Submitted','Void')),
    approval_status         TEXT NOT NULL DEFAULT 'Pending' CHECK (approval_status IN ('Pending','Approved','Rejected')),
    payment_status           TEXT NOT NULL DEFAULT 'Unpaid' CHECK (payment_status IN ('Unpaid','Paid','Partially Paid')),
    notes                    TEXT,
    created_at               TEXT NOT NULL DEFAULT (datetime('now')),
    created_by                TEXT NOT NULL DEFAULT 'me',
    updated_at                 TEXT NOT NULL DEFAULT (datetime('now')),
    updated_by                  TEXT
);

CREATE INDEX idx_expense_company_period ON expense(company_id, fiscal_year, month);
CREATE INDEX idx_expense_category ON expense(category_id);
CREATE INDEX idx_expense_employee ON expense(employee_person_id);
CREATE INDEX idx_expense_budget ON expense(budget_id);

-- Reuses the EXISTING Document Vault rather than a separate repository
-- (Section 15). Mirrors the shape of task_document_link /
-- document_employee_link from Phase 0's junction-table pattern.
CREATE TABLE expense_document_link (
    id              TEXT PRIMARY KEY,
    expense_id      TEXT NOT NULL REFERENCES expense(id) ON DELETE CASCADE,
    document_id     TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (expense_id, document_id)
);

-- ============================================================================
-- SECTION 15 (ADDITIVE, Stage C1): WORK MANAGEMENT FOUNDATION
-- Added for Quick Capture -> Task -> Weekly Review workflow.
--
-- Per the explicit product decision carried into this stage: this system
-- is single-user, with NO approval workflow and NO RBAC. Nothing below
-- introduces an approval/approver/multi-level-approval concept anywhere.
-- task.status intentionally has no "Pending Approval"/"Approved"/"Rejected"
-- values — see the CHECK constraint on `task` above (Section 3), unchanged
-- from Phase 0 and already free of approval states.
--
-- Two categories of change here:
--   (a) True ALTER TABLE ADD COLUMN additions (task.completed_date,
--       task.department_id) — zero-risk, cannot invalidate existing rows.
--   (b) The priority CHECK widening applied directly to the quick_capture
--       and task CREATE TABLE statements above (SQLite cannot ALTER a
--       CHECK constraint in place) — flagged there with inline comments;
--       documented here again for visibility. Given this system has not
--       shipped with real user data yet, editing the constraint in place
--       was judged lower-risk than either breaking the new Low/Normal/
--       High/Urgent requirement or leaving 'Normal'/'Urgent' silently
--       unusable.
-- ============================================================================

ALTER TABLE task ADD COLUMN completed_date TEXT;
ALTER TABLE task ADD COLUMN department_id TEXT REFERENCES department(id) ON DELETE SET NULL;

-- Task <-> Expense linkage (Section 19: "Task -> Expense" cross-module
-- compatibility), mirroring the existing task_*_link junction-table
-- pattern from Phase 0 exactly — same shape as task_employee_link etc.
CREATE TABLE task_expense_link (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    expense_id TEXT NOT NULL REFERENCES expense(id) ON DELETE CASCADE,
    relationship_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (task_id, expense_id)
);

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
