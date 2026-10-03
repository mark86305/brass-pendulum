-- =====================================================================
-- SpeculativeGPT — Database Schema Group 1
-- Scheduling, window runs, run steps, trading tracks, and system state
--
-- Draft G1-D4 | 2026-09-12 | PROPOSED — NOT APPLIED
-- Supersedes G1-D3 (approved baseline 2026-09-11). Companion to
-- Requirements v1.3 and Handover H-005 (H-006 pending).
--
-- Changes in this draft:
--   C-1  New run type month_end_checkpoint, used only in the V2 slot on
--        the last trading day of the month. Steps: broker_sync, then
--        liquidation. It exists so the 2:35 PM checkpoint can record what
--        the patient month-end attempt closed and finish that liquidation
--        event. A verification_checkpoint cannot do this: its steps are
--        broker_sync and exit_placement, neither of which may touch
--        liquidation records, and exit_placement must never run against a
--        position the system is trying to close. This also lets the W2
--        month-end run end as soon as its orders are placed, instead of
--        holding the one-run-at-a-time lock until 2:30 PM and causing the
--        candidate track's run to be recorded as missed.
--   C-2  New run type owner_resolution, owner-triggered. Steps: broker_sync,
--        then resolution. It is how the owner records the outcome of an
--        unmatched position (an early assignment, a manual trade, a symbol
--        the system does not trade). Broker Sync runs first so whatever the
--        owner actually did in IBKR is recorded as executions before the
--        attestation is written. Folding this into the next scheduled run
--        was rejected: the track is halted and costing money, and the owner
--        should not have to wait for the next window to clear it.
--   C-7  Stale header and comment references to H-003 and v1.2 refreshed.
--
-- Carried forward from G1-D3 (2026-09-11 Group 3 session):
--   G3-D7  New step exit_placement. Trading window: broker_sync,
--          reconciliation, exit_placement, bot_a..bot_d. Checkpoint:
--          broker_sync, exit_placement. Month-end close seeded:
--          broker_sync, reconciliation, liquidation.
--   G3-D9  Per-track Halt on trading_track (set by automatic failures on
--          that track), alongside the owner's global Halt in system_state.
--          window_run snapshots track_halted.
--
-- Owner decisions reflected in this draft (2026-09-10 session):
--   D1  Trading tracks: PRIMARY + at most one CANDIDATE, each on its own account.
--   D2  Schedule: W1 10:30 (entries expire 12:00, check 12:05)
--                 W2 13:00 (entries expire 14:30, check 14:35)
--                 W3 15:00 (entries expire 15:55, check 16:30)
--       Entry orders use broker-enforced good-till-time expiry (TWS API).
--   D3  Off  = full stop; nothing runs, including checkpoints.
--       Halt = everything runs except new entry orders (enforced in Bot D).
--   D4  Early-close days: no new entries; exits and checks continue.
--   D5  IBKR connection: TWS API via IB Gateway, both versions pinned and
--       recorded on every run.
--   D6  Every window starts with broker_sync (record fills since last sync)
--       before reconciliation compares positions.
-- Target: Supabase Postgres 15+. Validated locally on Postgres 16.
--
-- Conventions that apply to every schema group:
--   1. All tables live in schema "sgpt", not "public". Supabase exposes
--      "public" through its auto-generated API; "sgpt" is exposed only
--      if we deliberately choose to later.
--   2. Row Level Security is enabled on every table with no policies,
--      which means default deny for API roles. Bots connect server-side
--      with a privileged role. Dashboard access is designed later.
--   3. Every timestamp is timestamptz (stored as UTC). Trading dates and
--      wall-clock slot times are America/New_York.
--   4. Coded values are text + CHECK constraints rather than Postgres
--      ENUM types, because CHECK constraints are easy to change later.
--   5. Audit rows are append-only. Triggers enforce safety invariants
--      only. Business logic never lives in a trigger.
--   6. The application role must not be granted TRUNCATE, because
--      TRUNCATE bypasses the row-level guards below.
-- =====================================================================

create schema if not exists sgpt;

-- ---------------------------------------------------------------------
-- 1. market_calendar
--    One row per calendar date. Loaded ahead of time from a maintained
--    exchange calendar, editable by the owner for unscheduled closures.
--    Derived facts (last trading day, days remaining) live in a view,
--    not in stored columns, so a late calendar correction cannot leave
--    them stale.
-- ---------------------------------------------------------------------
create table sgpt.market_calendar (
    trade_date       date primary key,
    is_trading_day   boolean     not null,
    market_open_et   time,
    market_close_et  time,
    is_early_close   boolean     not null default false,
    source           text        not null,   -- e.g. 'exchange_calendars:XNYS', 'owner_manual'
    note             text,                   -- e.g. 'Unscheduled closure'
    loaded_at        timestamptz not null default now(),
    constraint market_calendar_hours_chk check (
        (is_trading_day
            and market_open_et  is not null
            and market_close_et is not null
            and market_open_et < market_close_et)
        or
        (not is_trading_day
            and market_open_et  is null
            and market_close_et is null
            and not is_early_close)
    )
);

create view sgpt.trading_day_v as
select
    c.trade_date,
    c.market_open_et,
    c.market_close_et,
    c.is_early_close,
    c.trade_date = max(c.trade_date) over month_w          as is_last_trading_day_of_month,
    (count(*) over month_desc_w) - 1                        as trading_days_after_today_in_month
from sgpt.market_calendar c
where c.is_trading_day
window
    month_w      as (partition by date_trunc('month', c.trade_date)),
    month_desc_w as (partition by date_trunc('month', c.trade_date)
                     order by c.trade_date desc);

-- ---------------------------------------------------------------------
-- 2. schedule_slot
--    The daily schedule as data. The host scheduler only "ticks" every
--    few minutes; the runner reads this table to decide which slot is
--    due. That makes window times DST-proof, host-independent, and
--    changeable without touching cron configuration.
-- ---------------------------------------------------------------------
create table sgpt.schedule_slot (
    slot_code                 text primary key
                                check (slot_code ~ '^[A-Z][A-Z0-9_]{1,15}$'),
    slot_kind                 text not null
                                check (slot_kind in ('trading_window', 'verification_checkpoint')),
    display_name              text not null,
    scheduled_time_et         time not null,
    max_start_delay_minutes   smallint not null default 10
                                check (max_start_delay_minutes between 1 and 60),
    entry_order_expiry_et     time,      -- trading windows only; runner caps at market close on early-close days
    min_minutes_before_close  smallint,  -- trading windows only; skip if closer to close
    verifies_slot_code        text references sgpt.schedule_slot (slot_code),
    sort_order                smallint not null unique,
    is_active                 boolean  not null default true,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),
    constraint schedule_slot_code_kind_uq unique (slot_code, slot_kind),
    constraint schedule_slot_kind_fields_chk check (
        (slot_kind = 'trading_window'
            and verifies_slot_code is null
            and min_minutes_before_close is not null
            and entry_order_expiry_et is not null
            and entry_order_expiry_et > scheduled_time_et)
        or
        (slot_kind = 'verification_checkpoint'
            and verifies_slot_code is not null
            and entry_order_expiry_et is null
            and min_minutes_before_close is null)
    )
);

-- Sequencing proof for the open item "no checkpoint may conflict with a
-- subsequent trading window". This view must return zero rows before
-- any deployment. It is a deploy-time check, not a runtime check.
create view sgpt.schedule_conflict_v as
select c.slot_code,
       'checkpoint runs at or before its window''s entry orders expire'::text as problem
from sgpt.schedule_slot c
join sgpt.schedule_slot w on w.slot_code = c.verifies_slot_code
where c.is_active and w.is_active
  and c.scheduled_time_et <= w.entry_order_expiry_et
union all
select c.slot_code,
       'next trading window starts less than 5 minutes after this checkpoint'
from sgpt.schedule_slot c
join sgpt.schedule_slot w on w.slot_code = c.verifies_slot_code
where c.is_active and w.is_active
  and exists (
      select 1
      from sgpt.schedule_slot n
      where n.is_active
        and n.slot_kind = 'trading_window'
        and n.scheduled_time_et > w.scheduled_time_et
        and n.scheduled_time_et < c.scheduled_time_et + interval '5 minutes')
union all
select c.slot_code,
       'verifies_slot_code does not point at a trading window'
from sgpt.schedule_slot c
join sgpt.schedule_slot w on w.slot_code = c.verifies_slot_code
where w.slot_kind <> 'trading_window'
union all
select w.slot_code,
       'entry orders expire at or after the 16:00 regular close (no after-hours entries)'
from sgpt.schedule_slot w
where w.is_active and w.slot_kind = 'trading_window'
  and w.entry_order_expiry_et >= time '16:00'
union all
-- GLD, SLV, UNG, and XME options trade until 16:15, so exits on those can
-- still fill after 16:00. The day's last checkpoint must see that final state.
select c.slot_code,
       'final checkpoint runs before 16:20 (some ETF options trade until 16:15)'
from sgpt.schedule_slot c
where c.is_active and c.slot_kind = 'verification_checkpoint'
  and c.scheduled_time_et = (select max(x.scheduled_time_et) from sgpt.schedule_slot x
                              where x.is_active and x.slot_kind = 'verification_checkpoint')
  and c.scheduled_time_et < time '16:20';

-- ---------------------------------------------------------------------
-- 3. broker_account
--    One row per IBKR account the system may trade. Credentials are
--    NEVER stored here — only the name of the secret in the host's
--    secret store. Account numbers are sensitive; mask in the dashboard.
-- ---------------------------------------------------------------------
create table sgpt.broker_account (
    broker_account_id  uuid primary key default gen_random_uuid(),
    broker             text not null default 'IBKR' check (broker = 'IBKR'),
    ibkr_account_id    text not null unique,
    environment        text not null check (environment in ('paper', 'live')),
    legal_owner        text not null check (legal_owner in ('personal', 'llc')),
    display_name       text not null,
    credential_ref     text not null,   -- secret name, e.g. 'IBKR_PERSONAL_PAPER'
    is_active          boolean not null default true,
    created_at         timestamptz not null default now(),
    retired_at         timestamptz,
    constraint broker_account_retired_chk check (is_active or retired_at is not null)
);

-- ---------------------------------------------------------------------
-- 4. trading_track
--    A track is one strategy revision trading one broker account.
--    PRIMARY = the strategy of record. CANDIDATE = a revision earning
--    its 20 qualifying paper trades. Phase 1 has one row (PRIMARY on
--    the paper account). The Paper/Live toggle is a change to the
--    PRIMARY track's broker_account_id.
--    Each track runs its own IB Gateway session (paper and live use
--    separate IBKR usernames) and its own pinned copy of the runner, so a
--    candidate can test new strategy code or a new IBKR platform version
--    while the primary track keeps running the approved versions.
-- ---------------------------------------------------------------------
create table sgpt.trading_track (
    track_code                 text primary key check (track_code ~ '^[A-Z][A-Z0-9_]{1,15}$'),
    role                       text not null check (role in ('primary', 'candidate')),
    broker_account_id          uuid not null references sgpt.broker_account (broker_account_id),
    strategy_revision_id       text not null,   -- FK to strategy_revision added in Group 4
    run_priority               smallint not null unique,   -- lower value runs first in a slot
    portfolio_mode             text not null default 'normal'
                                 check (portfolio_mode in ('normal', 'capital_preservation')),
    portfolio_mode_changed_at  timestamptz,
    -- Per-track Halt (G3-D9). Set automatically by a reconciliation failure
    -- on this track, before any liquidation begins. Released only by the owner.
    -- Blocks new entry orders on this track only. The global Halt lives in
    -- system_state. Entries are rejected if either is on.
    is_halted                  boolean not null default false,
    halted_at                  timestamptz,
    halt_reason                text,
    halted_by_window_run_id    uuid,   -- FK added after window_run exists
    is_active                  boolean not null default true,
    row_version                integer not null default 1,
    created_at                 timestamptz not null default now(),
    updated_at                 timestamptz not null default now(),
    updated_by                 text not null default 'system',
    constraint trading_track_halt_chk check (
        (is_halted and halted_at is not null and halt_reason is not null)
        or
        (not is_halted and halted_at is null and halt_reason is null
            and halted_by_window_run_id is null)
    )
);

-- At most one active PRIMARY and one active CANDIDATE.
create unique index trading_track_one_active_role_uq
    on sgpt.trading_track (role) where is_active;

-- Two active tracks may never share an account (positions would mix and
-- reconciliation plus the one-trade-per-instrument rule would break).
create unique index trading_track_one_active_account_uq
    on sgpt.trading_track (broker_account_id) where is_active;

-- ---------------------------------------------------------------------
-- 5. window_run
--    One row per execution of automation that can touch the broker or
--    write trading records. window_run_id is the key every downstream
--    record carries. Scheduler-fired runs record a row even when they
--    skip, so the audit trail distinguishes "off" from "broken".
-- ---------------------------------------------------------------------
create table sgpt.window_run (
    window_run_id           uuid primary key default gen_random_uuid(),
    run_label               text not null unique,   -- human search key, e.g. 2026-09-10_W1_PRIMARY
    run_type                text not null check (run_type in (
                                'trading_window', 'verification_checkpoint',
                                'month_end_close', 'month_end_checkpoint',
                                'manual_liquidation', 'owner_resolution')),
    trigger_source          text not null check (trigger_source in ('scheduler', 'owner')),
    trade_date              date not null references sgpt.market_calendar (trade_date),
    track_code              text not null references sgpt.trading_track (track_code),
    slot_code               text,
    slot_kind               text,
    scheduled_for           timestamptz,
    status                  text not null check (status in (
                                'running', 'completed', 'failed', 'stopped',
                                'skipped', 'abandoned')),
    skip_reason             text check (skip_reason in (
                                'system_off', 'market_closed',
                                'early_close', 'another_run_in_progress',
                                'start_window_missed', 'track_inactive')),
    failed_step_code        text,
    status_detail           text,
    started_at              timestamptz not null default now(),
    finished_at             timestamptz,

    -- State snapshot taken at the moment the run was claimed. Immutable.
    strategy_revision_id    text not null,
    broker_account_id       uuid not null references sgpt.broker_account (broker_account_id),
    account_environment     text not null check (account_environment in ('paper', 'live')),
    portfolio_mode          text not null check (portfolio_mode in ('normal', 'capital_preservation')),
    manual_risk_multiplier  numeric(4,2) not null,
    system_enabled          boolean not null,
    system_halted           boolean not null,
    track_halted            boolean not null,
    code_version            text not null,   -- git commit SHA of the deployed runner
    ibkr_gateway_version    text not null,   -- pinned offline IB Gateway build, e.g. '10.37.1'
    ibkr_api_version        text not null,   -- pinned TWS API client library version
    owner_note              text,

    constraint window_run_slot_fk foreign key (slot_code, slot_kind)
        references sgpt.schedule_slot (slot_code, slot_kind),
    constraint window_run_id_type_uq unique (window_run_id, run_type),

    constraint window_run_trigger_chk check (
        (trigger_source = 'scheduler'
            and run_type in ('trading_window', 'verification_checkpoint',
                             'month_end_close', 'month_end_checkpoint')
            and slot_code is not null and scheduled_for is not null)
        or
        (trigger_source = 'owner'
            and run_type in ('manual_liquidation', 'owner_resolution')
            and slot_code is null and scheduled_for is null)
    ),
    constraint window_run_slot_kind_chk check (
        slot_kind is null
        or (run_type in ('verification_checkpoint', 'month_end_checkpoint')
                and slot_kind = 'verification_checkpoint')
        or (run_type in ('trading_window', 'month_end_close') and slot_kind = 'trading_window')
    ),
    constraint window_run_status_fields_chk check (
        ((status = 'running') = (finished_at is null))
        and ((status = 'skipped') = (skip_reason is not null))
        and (status not in ('failed', 'stopped', 'abandoned') or status_detail is not null)
        and (finished_at is null or finished_at >= started_at)
    )
);

-- Idempotency: a scheduler that fires twice cannot create two runs for
-- the same slot, date, and track. This is the double-order protection.
create unique index window_run_one_per_slot_uq
    on sgpt.window_run (trade_date, slot_code, track_code)
    where trigger_source = 'scheduler';

-- Mutual exclusion: only one run anywhere in the system may be running.
-- Covers overlapping windows, slow checkpoints, and manual liquidation.
create unique index window_run_single_running_uq
    on sgpt.window_run ((true))
    where status = 'running';

alter table sgpt.trading_track
    add constraint trading_track_halted_by_fk
    foreign key (halted_by_window_run_id) references sgpt.window_run (window_run_id);

create index window_run_date_idx  on sgpt.window_run (trade_date, track_code);
create index window_run_track_idx on sgpt.window_run (track_code, started_at desc);

-- Missed-run detection. A scheduled slot with no window_run row after its
-- start deadline means the scheduler itself did not fire. The external
-- watchdog alerts on effective_status = 'missed'.
create view sgpt.scheduled_run_status_v as
select
    d.trade_date,
    s.slot_code,
    s.slot_kind,
    t.track_code,
    (d.trade_date + s.scheduled_time_et) at time zone 'America/New_York' as scheduled_for,
    r.window_run_id,
    r.run_label,
    r.status,
    r.skip_reason,
    case
        when r.window_run_id is not null then r.status
        when now() > ((d.trade_date + s.scheduled_time_et) at time zone 'America/New_York')
                     + make_interval(mins => s.max_start_delay_minutes::int)
            then 'missed'
        else 'pending'
    end as effective_status
from sgpt.market_calendar d
cross join sgpt.schedule_slot s
cross join sgpt.trading_track t
left join sgpt.window_run r
       on r.trade_date     = d.trade_date
      and r.slot_code      = s.slot_code
      and r.track_code     = t.track_code
      and r.trigger_source = 'scheduler'
where d.is_trading_day
  and s.is_active
  and t.is_active
  and d.trade_date <= (now() at time zone 'America/New_York')::date;

-- ---------------------------------------------------------------------
-- 6. run_type_step
--    The required step sequence for each run type, as data. The step
--    table's foreign key makes an out-of-order step impossible to write.
--    month_end_close runs on the last trading day of the month in the W2
--    (patient pricing) and W3 (aggressive pricing) slots, per G3-D3.
--    month_end_checkpoint runs on that same day in the V2 slot (C-1).
-- ---------------------------------------------------------------------
create table sgpt.run_type_step (
    run_type   text     not null check (run_type in (
                   'trading_window', 'verification_checkpoint',
                   'month_end_close', 'month_end_checkpoint',
                   'manual_liquidation', 'owner_resolution')),
    step_seq   smallint not null check (step_seq > 0),
    step_code  text     not null check (step_code in (
                   'broker_sync', 'reconciliation', 'exit_placement',
                   'bot_a', 'bot_b', 'bot_c', 'bot_d', 'liquidation',
                   'resolution')),
    primary key (run_type, step_seq),
    constraint run_type_step_code_uq unique (run_type, step_code),
    constraint run_type_step_fk_target_uq unique (run_type, step_code, step_seq)
);

-- broker_sync pulls executions and order status from IBKR since the last
-- sync and records fills (including exits that filled between windows),
-- matched to our trade IDs. reconciliation then compares positions, so an
-- expected exit is never mistaken for a discrepancy. A checkpoint is simply
-- a broker_sync on its own. Liquidation syncs first so it never sells a
-- position that a broker-side exit already closed.
-- exit_placement (G3-D7) places the approved target and stop for any trade
-- whose entry order has finished with a filled quantity. It runs after
-- reconciliation in a trading window and after broker_sync at a checkpoint,
-- so Window 3 fills are protected before the next morning's open. It never
-- places exits on a trade that is being closed. Month-end close does not
-- run it.
insert into sgpt.run_type_step (run_type, step_seq, step_code) values
    ('trading_window',          1, 'broker_sync'),
    ('trading_window',          2, 'reconciliation'),
    ('trading_window',          3, 'exit_placement'),
    ('trading_window',          4, 'bot_a'),
    ('trading_window',          5, 'bot_b'),
    ('trading_window',          6, 'bot_c'),
    ('trading_window',          7, 'bot_d'),
    ('verification_checkpoint', 1, 'broker_sync'),
    ('verification_checkpoint', 2, 'exit_placement'),
    ('month_end_close',         1, 'broker_sync'),
    ('month_end_close',         2, 'reconciliation'),
    ('month_end_close',         3, 'liquidation'),
    -- C-1: the V2 slot on the last trading day of the month. Records what
    -- the patient attempt closed and finishes that liquidation event. No
    -- exit_placement: month-end close never places exits.
    ('month_end_checkpoint',    1, 'broker_sync'),
    ('month_end_checkpoint',    2, 'liquidation'),
    ('manual_liquidation',      1, 'broker_sync'),
    ('manual_liquidation',      2, 'liquidation'),
    -- C-2: the owner records what they did in IBKR about an unmatched
    -- position. Broker Sync first, so the broker's own record of the
    -- owner's action lands before the owner's attestation.
    ('owner_resolution',        1, 'broker_sync'),
    ('owner_resolution',        2, 'resolution');

-- ---------------------------------------------------------------------
-- 7. window_run_step
--    One row per step actually started within a run. Steps that never
--    ran have no row. This is the table you read at 2:00 AM.
-- ---------------------------------------------------------------------
create table sgpt.window_run_step (
    window_run_step_id  bigint generated always as identity primary key,
    window_run_id       uuid     not null,
    run_type            text     not null,
    step_seq            smallint not null,
    step_code           text     not null,
    status              text     not null check (status in (
                            'running', 'completed', 'failed', 'abandoned')),
    started_at          timestamptz not null default now(),
    finished_at         timestamptz,
    outcome_summary     text,    -- plain-English result for the audit log
    error_code          text,
    error_detail        jsonb,   -- never secrets, tokens, or credentials
    constraint window_run_step_run_fk foreign key (window_run_id, run_type)
        references sgpt.window_run (window_run_id, run_type),
    constraint window_run_step_def_fk foreign key (run_type, step_code, step_seq)
        references sgpt.run_type_step (run_type, step_code, step_seq),
    constraint window_run_step_seq_uq  unique (window_run_id, step_seq),
    constraint window_run_step_code_uq unique (window_run_id, step_code),
    constraint window_run_step_status_chk check (
        ((status = 'running') = (finished_at is null))
        and (status <> 'failed' or error_code is not null)
    )
);

-- ---------------------------------------------------------------------
-- 8. system_state
--    Exactly one row. Global switches that apply to every track.
--    is_enabled = false (Off): the scheduler still fires but records every
--      run, including checkpoints, as skipped with reason system_off.
--    is_halted = true (global Halt): every run proceeds normally, including
--      broker_sync, reconciliation, all four bots, and exit-order placement;
--      Bot D records "not submitted: system halted" instead of placing new
--      entry orders. Released only by the owner.
--    Every change will be written to the operator control log by a
--    trigger added in Group 4, so no code path can change state silently.
-- ---------------------------------------------------------------------
create table sgpt.system_state (
    singleton                boolean primary key default true check (singleton),
    is_enabled               boolean not null default false,   -- system starts OFF
    is_halted                boolean not null default false,
    halted_at                timestamptz,
    halt_reason              text,
    halted_by_window_run_id  uuid references sgpt.window_run (window_run_id),
    manual_risk_multiplier   numeric(4,2) not null default 1.00
                               check (manual_risk_multiplier between 0.25 and 2.00),
    row_version              integer not null default 1,
    updated_at               timestamptz not null default now(),
    updated_by               text not null default 'system',
    constraint system_state_halt_chk check (
        (is_halted and halted_at is not null and halt_reason is not null)
        or
        (not is_halted and halted_at is null and halt_reason is null
            and halted_by_window_run_id is null)
    )
);

insert into sgpt.system_state default values;

-- =====================================================================
-- Guard triggers (invariants only)
-- =====================================================================

-- window_run: fill run_label, allow only legal status transitions,
-- freeze identity and snapshot columns, forbid deletes, and refuse to
-- mark a run completed unless every defined step completed.
create function sgpt.window_run_guard() returns trigger
language plpgsql as $$
declare
    v_defined   int;
    v_completed int;
begin
    if tg_op = 'DELETE' then
        raise exception 'window_run % is a permanent audit record and cannot be deleted',
            old.run_label;
    end if;

    if tg_op = 'INSERT' then
        if new.status not in ('running', 'skipped') then
            raise exception 'window_run must be inserted as running or skipped, not %', new.status;
        end if;
        if new.status = 'skipped' and new.finished_at is null then
            new.finished_at := new.started_at;
        end if;
        if new.run_label is null then
            new.run_label := case
                when new.trigger_source = 'scheduler' then
                    format('%s_%s_%s', new.trade_date, new.slot_code, new.track_code)
                else
                    format('%s_OWNER_%s_%s_%s', new.trade_date, upper(new.run_type),
                           to_char(new.started_at at time zone 'America/New_York', 'HH24MISS'),
                           new.track_code)
            end;
        end if;
        return new;
    end if;

    -- UPDATE
    if old.status <> 'running' then
        raise exception 'window_run % is final (status %) and cannot be changed',
            old.run_label, old.status;
    end if;

    if row(new.window_run_id, new.run_label, new.run_type, new.trigger_source,
           new.trade_date, new.track_code, new.slot_code, new.slot_kind,
           new.scheduled_for, new.started_at, new.strategy_revision_id,
           new.broker_account_id, new.account_environment, new.portfolio_mode,
           new.manual_risk_multiplier, new.system_enabled, new.system_halted, new.track_halted,
           new.code_version, new.ibkr_gateway_version, new.ibkr_api_version)
       is distinct from
       row(old.window_run_id, old.run_label, old.run_type, old.trigger_source,
           old.trade_date, old.track_code, old.slot_code, old.slot_kind,
           old.scheduled_for, old.started_at, old.strategy_revision_id,
           old.broker_account_id, old.account_environment, old.portfolio_mode,
           old.manual_risk_multiplier, old.system_enabled, old.system_halted, old.track_halted,
           old.code_version, old.ibkr_gateway_version, old.ibkr_api_version)
    then
        raise exception 'window_run %: identity and state-snapshot columns are immutable',
            old.run_label;
    end if;

    if new.status = 'skipped' then
        raise exception 'window_run %: a started run cannot become skipped', old.run_label;
    end if;

    if new.status = 'completed' then
        select count(*) into v_defined
          from sgpt.run_type_step where run_type = new.run_type;
        select count(*) into v_completed
          from sgpt.window_run_step
         where window_run_id = new.window_run_id and status = 'completed';
        if v_defined = 0 or v_completed <> v_defined then
            raise exception 'cannot complete window_run %: % of % defined steps completed',
                old.run_label, v_completed, v_defined;
        end if;
    end if;

    return new;
end;
$$;

create trigger window_run_guard_trg
    before insert or update or delete on sgpt.window_run
    for each row execute function sgpt.window_run_guard();

-- window_run_step: a step may start only inside a running run, only after
-- every earlier step completed, and only in the next sequence position.
-- Late writes from a process whose run was abandoned are rejected.
create function sgpt.window_run_step_guard() returns trigger
language plpgsql as $$
declare
    v_run_status text;
    v_next_seq   int;
begin
    if tg_op = 'DELETE' then
        raise exception 'window_run_step rows are permanent audit records and cannot be deleted';
    end if;

    select status into v_run_status
      from sgpt.window_run
     where window_run_id = new.window_run_id
       for update;   -- serializes concurrent step writes for one run

    if tg_op = 'INSERT' then
        if v_run_status is distinct from 'running' then
            raise exception 'cannot start step %: run status is %, not running',
                new.step_code, coalesce(v_run_status, 'missing');
        end if;
        if new.status <> 'running' then
            raise exception 'steps must be inserted in running status';
        end if;
        if exists (select 1 from sgpt.window_run_step
                    where window_run_id = new.window_run_id
                      and status <> 'completed') then
            raise exception 'cannot start step %: an earlier step in this run has not completed',
                new.step_code;
        end if;
        select coalesce(max(step_seq), 0) + 1 into v_next_seq
          from sgpt.window_run_step
         where window_run_id = new.window_run_id;
        if new.step_seq <> v_next_seq then
            raise exception 'step % is out of order: expected position %, got %',
                new.step_code, v_next_seq, new.step_seq;
        end if;
        return new;
    end if;

    -- UPDATE
    if old.status <> 'running' then
        raise exception 'step % is final (status %) and cannot be changed',
            old.step_code, old.status;
    end if;
    if row(new.window_run_id, new.run_type, new.step_seq, new.step_code, new.started_at)
       is distinct from
       row(old.window_run_id, old.run_type, old.step_seq, old.step_code, old.started_at)
    then
        raise exception 'step %: identity columns are immutable', old.step_code;
    end if;
    if v_run_status <> 'running' and new.status <> 'abandoned' then
        raise exception 'step % rejected: its run is % — late write from an abandoned process?',
            old.step_code, v_run_status;
    end if;
    return new;
end;
$$;

create trigger window_run_step_guard_trg
    before insert or update or delete on sgpt.window_run_step
    for each row execute function sgpt.window_run_step_guard();

-- A failed step fails its run immediately. The orchestrator cannot
-- "forget" to stop the sequence.
create function sgpt.window_run_step_fail_cascade() returns trigger
language plpgsql as $$
begin
    update sgpt.window_run
       set status           = 'failed',
           failed_step_code = new.step_code,
           finished_at      = now(),
           status_detail    = coalesce(status_detail,
                                format('Step %s failed: %s', new.step_code, new.error_code))
     where window_run_id = new.window_run_id
       and status = 'running';
    return null;
end;
$$;

create trigger window_run_step_fail_cascade_trg
    after update of status on sgpt.window_run_step
    for each row
    when (old.status = 'running' and new.status = 'failed')
    execute function sgpt.window_run_step_fail_cascade();

-- system_state: optimistic-concurrency version bump, no deletes.
-- Dashboard writes must use: UPDATE ... WHERE row_version = <expected>.
create function sgpt.system_state_guard() returns trigger
language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'system_state cannot be deleted';
    end if;
    new.row_version := old.row_version + 1;
    new.updated_at  := now();
    return new;
end;
$$;

create trigger system_state_guard_trg
    before update or delete on sgpt.system_state
    for each row execute function sgpt.system_state_guard();

create function sgpt.bump_row_version() returns trigger
language plpgsql as $$
begin
    new.row_version := old.row_version + 1;
    new.updated_at  := now();
    return new;
end;
$$;

create trigger trading_track_version_trg
    before update on sgpt.trading_track
    for each row execute function sgpt.bump_row_version();

-- =====================================================================
-- Row Level Security: enabled, no policies = default deny for API roles.
-- =====================================================================
alter table sgpt.market_calendar  enable row level security;
alter table sgpt.schedule_slot    enable row level security;
alter table sgpt.broker_account   enable row level security;
alter table sgpt.trading_track    enable row level security;
alter table sgpt.window_run       enable row level security;
alter table sgpt.run_type_step    enable row level security;
alter table sgpt.window_run_step  enable row level security;
alter table sgpt.system_state     enable row level security;

-- =====================================================================
-- Seed schedule — owner-approved 2026-09-10 (decision D2).
-- Times are America/New_York wall-clock.
-- =====================================================================
insert into sgpt.schedule_slot
    (slot_code, slot_kind, display_name, scheduled_time_et,
     entry_order_expiry_et, min_minutes_before_close, verifies_slot_code, sort_order)
values
    ('W1', 'trading_window',          'Window 1 — Morning',        '10:30', '12:00', 60,   null, 10),
    ('V1', 'verification_checkpoint', 'Window 1 verification',     '12:05', null,    null, 'W1', 20),
    ('W2', 'trading_window',          'Window 2 — Midday',         '13:00', '14:30', 60,   null, 30),
    ('V2', 'verification_checkpoint', 'Window 2 verification',     '14:35', null,    null, 'W2', 40),
    ('W3', 'trading_window',          'Window 3 — End of day',     '15:00', '15:55', 30,   null, 50),
    ('V3', 'verification_checkpoint', 'Window 3 verification',     '16:30', null,    null, 'W3', 60);
