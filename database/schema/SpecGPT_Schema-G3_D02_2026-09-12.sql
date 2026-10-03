-- =====================================================================
-- SpeculativeGPT — Database Schema Group 3
-- Bot D verification, trades (positions), legs, broker orders, broker
-- executions, reconciliation records, and liquidation events
--
-- Draft G3-D2 | 2026-09-12 | PROPOSED — NOT APPLIED
-- Supersedes G3-D1 (approved baseline 2026-09-11). Companion to
-- Requirements v1.3 and Handover H-005 (H-006 pending).
--
-- Corrections in this draft (H-005 Section 5):
--   C-1  The patient month-end attempt places a closing order on every
--        position at once, and the 2:35 PM month_end_checkpoint run
--        records what those orders did. Two rules changed: one position
--        at a time now applies to aggressive liquidation only, which is
--        what Requirements 8.3 always said; and a liquidation event may
--        now be continued by a later run on the same track instead of
--        only by the run that created it.
--   C-3  One liquidation event per run per STEP, not per run. A month-end
--        run whose Reconciliation step triggers a liquidation can still
--        record its month-end liquidation in its Liquidation step.
--   C-4  A liquidation whose run failed or was abandoned can be recorded
--        as stopped by a later run on the same track, with where it
--        stopped. interrupted_liquidation_v is the alert source.
--   C-2 (part)  A liquidation that closed nothing can no longer be
--        recorded as completed by accident, and a liquidation covering a
--        whole track cannot complete while any active trade remains on
--        that track.
--   C-2  Unmatched positions. A position IBKR reports that matches no
--        recorded trade's legs is never closed by the system. It is
--        recorded, the track Halt is already on, the owner is alerted, and
--        the owner resolves it in IBKR and records what they did. Two new
--        tables: unmatched_position and trade_quantity_adjustment. The
--        adjustment is how a trade stranded by an early assignment reaches
--        zero open quantity — by an owner-attested written-off quantity that
--        the open-quantity calculation includes, NOT by a status that skips
--        the calculation. Quantities stay computed, never asserted.
--   C-7  Stale "NOT APPROVED" header and v1.2/H-003 references refreshed.
--        Also made explicit: the database now rejects a thesis-invalidation
--        close outright. Requirements v1.3 and H-005 both state that it
--        already did; it did not. Nothing could execute such a close, but a
--        trade could be marked closing with that reason and strand itself.
--
-- Depends on: Group 1 Draft 4, Group 2 Draft 2
--
-- Owner decisions reflected in this draft (2026-09-11 session):
--   G3-D1  Exits: one target + one stop per trade at MVP. Schema is
--          tier-ready (exit_tier column); code builds tier 1 only.
--   G3-D2  One active trade per instrument PER TRACK.
--   G3-D3  Month-end close: W2 patient limit at mid until 14:30; W3
--          limit priced to fill immediately. Steps: broker_sync,
--          reconciliation, liquidation.
--   G3-D4  No new entry orders on the last trading day of the month.
--   G3-D5  Liquidation urgency: patient (month-end attempt one only) or
--          aggressive (everything else).
--   G3-D6  No option leg may expire on or before the last trading day of
--          the month the trade opens in.
--   G3-D7  exit_placement step (Group 1 amendment).
--   G3-D9  Reconciliation response: recheck first; one instrument still
--          wrong = liquidate that position + halt the track; two or more
--          = liquidate the track + halt the track. Halt is set BEFORE the
--          liquidation event can be recorded.
--   G3-D12 Close All Positions applies to ONE chosen track and sets that
--          track's Halt first. Other tracks are untouched. (Owner, 2026-09-11)
--   G3-D10 Reconciliation records live in Group 3.
--   Automatic liquidation runs inside the reconciliation step.
--
-- How the pieces fit:
--   bot_c_decision (proposal) -> bot_d_verification (one per proposal)
--     -> trade (only when verification outcome = submitted)
--       -> trade_leg (contracts, write-once, before the entry order)
--       -> broker_order (entry, exit_target, exit_stop, close)
--       -> broker_execution (every IBKR fill, deduplicated on exec ID)
--   reconciliation_check -> reconciliation_mismatch
--     -> liquidation_event -> liquidation_item -> broker_order (close)
--
-- Design principle: quantities are never stored as running counters.
-- Filled quantity lives on each broker order (as IBKR reports it, in
-- order units) and open quantity is computed from those orders when
-- needed, so a counter can never drift out of step with the orders.
--
-- Conventions: see Group 1 header (sgpt schema, RLS default deny,
--   timestamptz, text + CHECK, append-only audit rows, invariants-only
--   triggers, no TRUNCATE grant).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Link keys added to earlier groups so Group 3 foreign keys can
--    prove that related rows agree (same run, same track, same account).
-- ---------------------------------------------------------------------
alter table sgpt.window_run
    add constraint window_run_id_track_uq unique (window_run_id, track_code),
    add constraint window_run_id_track_account_uq unique (window_run_id, track_code, broker_account_id);

alter table sgpt.bot_c_decision
    add constraint bot_c_decision_type_uq unique (window_run_id, instrument_code, decision_type);

-- =====================================================================
-- SHARED HELPERS
-- =====================================================================

-- Returns the run row, or raises if the run is not currently running.
-- This is the zombie-write protection used throughout Group 3.
create function sgpt.require_running_run(p_run uuid, p_what text)
returns sgpt.window_run language plpgsql as $$
declare r sgpt.window_run;
begin
    select * into r from sgpt.window_run where window_run_id = p_run;
    if r.window_run_id is null then
        raise exception '%: run % not found', p_what, p_run;
    end if;
    if r.status <> 'running' then
        raise exception '%: run % is %, not running — late write from an abandoned process?',
            p_what, r.run_label, r.status;
    end if;
    return r;
end $$;

-- Raises unless one of the named steps is the step currently running.
-- Ties each money-moving write to the step that is allowed to make it.
create function sgpt.require_step_running(p_run uuid, p_steps text[], p_what text)
returns void language plpgsql as $$
begin
    if not exists (select 1 from sgpt.window_run_step
                    where window_run_id = p_run
                      and status = 'running'
                      and step_code = any (p_steps)) then
        raise exception '%: allowed only while step % is running', p_what, p_steps;
    end if;
end $$;

-- Raises unless new entries are allowed right now for this run.
-- Checked when the trade is created AND again when the entry order is
-- written, because a Halt can be set in between.
create function sgpt.assert_entries_allowed(r sgpt.window_run, p_what text)
returns void language plpgsql as $$
declare v_day record;
begin
    if r.run_type <> 'trading_window' then
        raise exception '%: entries only in trading windows, not %', p_what, r.run_type;
    end if;
    if (select is_halted from sgpt.system_state) then
        raise exception '%: rejected — global Halt is on', p_what;
    end if;
    if (select is_halted from sgpt.trading_track where track_code = r.track_code) then
        raise exception '%: rejected — track % is halted', p_what, r.track_code;
    end if;
    select * into v_day from sgpt.trading_day_v where trade_date = r.trade_date;
    if v_day.trade_date is null then
        raise exception '%: rejected — % is not a trading day in the calendar', p_what, r.trade_date;
    end if;
    if v_day.is_early_close then
        raise exception '%: rejected — % is an early-close day (no new entries)', p_what, r.trade_date;
    end if;
    if v_day.is_last_trading_day_of_month then
        raise exception '%: rejected — % is the last trading day of the month (no new entries)',
            p_what, r.trade_date;
    end if;
end $$;

-- Order status vocabulary, in one place.
create function sgpt.order_is_working(p_status text) returns boolean
language sql immutable as $$
    select p_status in ('pending_submit', 'working', 'cancel_requested')
$$;

-- =====================================================================
-- 1. bot_d_verification
--    One row per Bot C proposal. Bot D's check against live conditions
--    and its one decision: submit, or kill with a reason. Written for
--    every proposal, including those not submitted because of a Halt,
--    so the audit trail shows what would have happened.
-- =====================================================================
create table sgpt.bot_d_verification (
    window_run_id          uuid not null,
    instrument_code        text not null,
    decision_type          text not null default 'proposal' check (decision_type = 'proposal'),
    live_entry_cost        numeric(12,2),        -- from IBKR live quote; null if unavailable
    cost_variance_pct      numeric(7,2),         -- (live - expected) / expected * 100
    cost_tolerance_pct     numeric(5,2) not null check (cost_tolerance_pct > 0 and cost_tolerance_pct <= 25),
    available_cash         numeric(14,2),
    cash_covers_max_loss   boolean,
    portfolio_mode_ok      boolean,
    blackout_clear         boolean,
    outcome                text not null check (outcome in (
                               'submitted',
                               'killed_cost_tolerance',
                               'killed_cash_coverage',
                               'killed_portfolio_mode',
                               'killed_blackout',
                               'killed_quote_unavailable',
                               'not_submitted_system_halted',
                               'not_submitted_track_halted',
                               'not_submitted_early_close',
                               'not_submitted_last_trading_day')),
    verification_summary   text,
    created_at             timestamptz not null default now(),
    primary key (window_run_id, instrument_code),
    constraint bot_d_verification_outcome_uq unique (window_run_id, instrument_code, outcome),
    -- Can only exist for a Bot C row whose decision_type is 'proposal'.
    constraint bot_d_verification_proposal_fk foreign key (window_run_id, instrument_code, decision_type)
        references sgpt.bot_c_decision (window_run_id, instrument_code, decision_type),
    -- A submission requires every check to have passed.
    constraint bot_d_submitted_chk check (
        outcome <> 'submitted'
        or (live_entry_cost is not null
            and cost_variance_pct is not null
            and abs(cost_variance_pct) <= cost_tolerance_pct
            and cash_covers_max_loss
            and portfolio_mode_ok
            and blackout_clear)
    )
);

create trigger bot_d_verification_guard_trg
    before insert or update or delete on sgpt.bot_d_verification
    for each row execute function sgpt.bot_output_guard();

-- =====================================================================
-- 2. trade
--    The permanent trade ID and the position's life:
--      entry_working -> open -> (closing) -> closed
--      entry_working -> not_opened            (entry finished, nothing filled)
--      entry_working -> closing               (liquidation while entry works)
--      closing       -> not_opened            (entry cancelled, nothing filled)
--    Only one active (entry_working, open, closing) trade per instrument
--    per track (G3-D2).
-- =====================================================================
create table sgpt.trade (
    trade_id                  uuid primary key default gen_random_uuid(),
    trade_ref                 text not null unique,   -- permanent human/broker key, set by guard
    window_run_id             uuid not null,          -- the run whose Bot D opened it
    track_code                text not null,
    broker_account_id         uuid not null,
    instrument_code           text not null references sgpt.instrument (instrument_code),
    verification_outcome      text not null default 'submitted' check (verification_outcome = 'submitted'),
    trade_date                date not null,
    trade_type                text not null check (trade_type in (
                                  'long_call', 'long_put',
                                  'bull_call_spread', 'bear_put_spread',
                                  'bull_put_spread', 'bear_call_spread',
                                  'straddle', 'long_etf')),
    direction                 text not null check (direction in ('bullish', 'bearish', 'neutral')),
    requested_quantity        integer not null check (requested_quantity > 0),  -- order units (combos or shares)
    status                    text not null default 'entry_working' check (status in (
                                  'entry_working', 'not_opened', 'open', 'closing', 'closed')),
    opened_at                 timestamptz,   -- first confirmed fill
    closing_started_at        timestamptz,
    closed_at                 timestamptz,
    close_reason              text check (close_reason in (
                                  'target', 'stop', 'month_end',
                                  'reconciliation_single', 'reconciliation_systemic',
                                  'owner_close_all', 'owner_resolution',
                                  'thesis_invalidation')),
        -- owner_resolution: closed out by the owner's resolution of an
        -- unmatched position (C-2). It did not exit by the strategy's own
        -- rules, so Group 4 excludes it from qualifying trades.
        -- thesis_invalidation: reserved and REJECTED by the guard until the
        -- open-position review component is designed (V13-D1).
    status_detail             text,
    updated_by_window_run_id  uuid not null references sgpt.window_run (window_run_id),
    row_version               integer not null default 1,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),

    -- The trade's track and account must be the ones its run was using.
    constraint trade_run_fk foreign key (window_run_id, track_code, broker_account_id)
        references sgpt.window_run (window_run_id, track_code, broker_account_id),
    -- A trade can only exist for a proposal that Bot D verified and submitted.
    constraint trade_verification_fk foreign key (window_run_id, instrument_code, verification_outcome)
        references sgpt.bot_d_verification (window_run_id, instrument_code, outcome),
    -- One trade per proposal.
    constraint trade_one_per_proposal_uq unique (window_run_id, instrument_code),

    constraint trade_status_fields_chk check (
        (status in ('open', 'closing', 'closed') or opened_at is null)
        and (status not in ('open', 'closed') or opened_at is not null)
        and ((status = 'closing') <= (closing_started_at is not null))
        and ((status = 'closed') = (closed_at is not null))
        and ((status in ('closing', 'closed')) = (close_reason is not null))
    )
);

create unique index trade_one_active_per_track_instrument_uq
    on sgpt.trade (track_code, instrument_code)
    where status in ('entry_working', 'open', 'closing');

create index trade_active_idx on sgpt.trade (track_code, status)
    where status in ('entry_working', 'open', 'closing');

-- =====================================================================
-- 3. trade_leg
--    The contracts that make up the trade, written once by Bot D before
--    the entry order is sent. Exits and closes act on the same legs as a
--    single combo order (no legging, Requirements 3.3).
-- =====================================================================
create table sgpt.trade_leg (
    trade_id        uuid not null references sgpt.trade (trade_id),
    leg_number      smallint not null check (leg_number between 1 and 4),
    sec_type        text not null check (sec_type in ('OPT', 'STK')),
    ibkr_con_id     bigint not null,               -- IBKR contract ID
    symbol          text not null,                 -- underlying; must match the trade's instrument
    option_right    text check (option_right in ('C', 'P')),
    strike          numeric(12,4),
    expiration      date,
    entry_action    text not null check (entry_action in ('BUY', 'SELL')),
    ratio           smallint not null default 1 check (ratio > 0),
    created_at      timestamptz not null default now(),
    primary key (trade_id, leg_number),
    constraint trade_leg_contract_uq unique (trade_id, ibkr_con_id),
    constraint trade_leg_fields_chk check (
        (sec_type = 'OPT' and option_right is not null and strike is not null and expiration is not null)
        or
        (sec_type = 'STK' and option_right is null and strike is null and expiration is null)
    )
);

-- =====================================================================
-- 4. broker_order
--    Every order sent to IBKR. order_ref is our reference, sent as
--    IBKR's orderRef so executions can be matched back to the trade.
--    Status is updated by Broker Sync; quantity and prices never change.
-- =====================================================================
create table sgpt.broker_order (
    broker_order_id                uuid primary key default gen_random_uuid(),
    trade_id                       uuid not null references sgpt.trade (trade_id),
    broker_account_id              uuid not null references sgpt.broker_account (broker_account_id),
    order_role                     text not null check (order_role in (
                                       'entry', 'exit_target', 'exit_stop', 'close')),
    exit_tier                      smallint check (exit_tier between 1 and 5),   -- tier-ready (G3-D1)
    order_ref                      text not null unique,   -- set by guard
    ibkr_order_id                  integer,                -- session-scoped; set once when known
    ibkr_perm_id                   bigint,                 -- IBKR permanent ID; set once when known
    oca_group                      text,                   -- target and stop share one (one cancels other)
    action                         text not null check (action in ('BUY', 'SELL')),
    order_type                     text not null check (order_type in ('LMT', 'STP', 'STP LMT')),
    limit_price                    numeric(12,4),
    stop_price                     numeric(12,4),
    time_in_force                  text not null check (time_in_force in ('GTD', 'GTC', 'DAY')),
    good_till                      timestamptz,
    quantity                       integer not null check (quantity > 0),
    filled_quantity                integer not null default 0 check (filled_quantity >= 0),
    avg_fill_price                 numeric(12,4),
    status                         text not null default 'pending_submit' check (status in (
                                       'pending_submit', 'working', 'cancel_requested',
                                       'filled', 'cancelled', 'expired', 'rejected')),
    status_detail                  text,
    liquidation_event_id           uuid,
    liquidation_item_seq           smallint,
    submitted_by_window_run_id     uuid not null references sgpt.window_run (window_run_id),
    last_synced_by_window_run_id   uuid not null references sgpt.window_run (window_run_id),
    created_at                     timestamptz not null default now(),
    last_status_at                 timestamptz not null default now(),
    finished_at                    timestamptz,

    constraint broker_order_perm_id_uq unique (broker_account_id, ibkr_perm_id),
    constraint broker_order_fill_chk check (
        filled_quantity <= quantity
        and ((status = 'filled') = (filled_quantity = quantity))
        and (filled_quantity = 0 or avg_fill_price is not null)
        and (sgpt.order_is_working(status) = (finished_at is null))
    ),
    constraint broker_order_role_fields_chk check (
        (order_role = 'entry'
            and order_type = 'LMT' and limit_price is not null
            and time_in_force = 'GTD'
            and exit_tier is null and oca_group is null and liquidation_event_id is null)
        or
        (order_role = 'exit_target'
            and order_type = 'LMT' and limit_price is not null
            and time_in_force in ('GTC', 'GTD')
            and exit_tier is not null and oca_group is not null and liquidation_event_id is null)
        or
        (order_role = 'exit_stop'
            and order_type in ('STP', 'STP LMT') and stop_price is not null
            and (order_type = 'STP' or limit_price is not null)
            and time_in_force in ('GTC', 'GTD')
            and exit_tier is not null and oca_group is not null and liquidation_event_id is null)
        or
        -- Closes are limit orders (G3-D3). Until thesis-invalidation exits
        -- are designed, every close belongs to a liquidation item.
        (order_role = 'close'
            and order_type = 'LMT' and limit_price is not null
            and time_in_force in ('DAY', 'GTD')
            and exit_tier is null and oca_group is null
            and liquidation_event_id is not null and liquidation_item_seq is not null)
    ),
    constraint broker_order_gtd_chk check (time_in_force <> 'GTD' or good_till is not null)
);

-- One entry order per trade.
create unique index broker_order_one_entry_uq
    on sgpt.broker_order (trade_id) where order_role = 'entry';

create index broker_order_trade_idx on sgpt.broker_order (trade_id, order_role);
create index broker_order_working_idx on sgpt.broker_order (broker_account_id)
    where status in ('pending_submit', 'working', 'cancel_requested');

-- sgpt.trade_quantities is defined in section 6.5, after the owner
-- adjustment table it now has to account for.

-- =====================================================================
-- 5. broker_execution
--    Every execution IBKR reports, recorded exactly once (unique on the
--    account and IBKR execution ID). Executions that do not match one of
--    our orders are still recorded with broker_order_id null — those are
--    exactly what reconciliation needs to see (e.g. a manual trade).
-- =====================================================================
create table sgpt.broker_execution (
    broker_execution_id          bigint generated always as identity primary key,
    broker_account_id            uuid not null references sgpt.broker_account (broker_account_id),
    ibkr_exec_id                 text not null,
    corrects_ibkr_exec_id        text,          -- IBKR correction of an earlier execution, if any
    broker_order_id              uuid references sgpt.broker_order (broker_order_id),  -- null = unmatched
    reported_order_ref           text,          -- orderRef exactly as IBKR reported it
    ibkr_perm_id                 bigint,
    ibkr_con_id                  bigint not null,
    symbol                       text not null,
    sec_type                     text not null, -- as reported: OPT, STK, BAG, ...
    option_right                 text check (option_right in ('C', 'P')),
    strike                       numeric(12,4),
    expiration                   date,
    side                         text not null check (side in ('BOT', 'SLD')),
    quantity                     numeric(14,4) not null check (quantity > 0),
    price                        numeric(12,4) not null,
    executed_at                  timestamptz not null,
    commission                   numeric(10,4),  -- arrives separately; set once
    commission_currency          text,
    ibkr_realized_pnl            numeric(14,4),
    commission_recorded_at       timestamptz,
    recorded_by_window_run_id    uuid not null references sgpt.window_run (window_run_id),
    recorded_at                  timestamptz not null default now(),
    constraint broker_execution_exec_id_uq unique (broker_account_id, ibkr_exec_id),
    constraint broker_execution_commission_chk check (
        (commission is null) = (commission_recorded_at is null)
    )
);

create index broker_execution_order_idx on sgpt.broker_execution (broker_order_id);
create index broker_execution_unmatched_idx on sgpt.broker_execution (broker_account_id, executed_at)
    where broker_order_id is null;

-- =====================================================================
-- 6. reconciliation_check and reconciliation_mismatch
--    check_seq 1 is the first comparison; check_seq 2 is the recheck,
--    allowed only after a mismatch. A liquidation can only point at a
--    recheck (check_seq 2), so "recheck before acting" is enforced.
-- =====================================================================
create table sgpt.reconciliation_check (
    window_run_id        uuid not null references sgpt.window_run (window_run_id),
    check_seq            smallint not null check (check_seq in (1, 2)),
    checked_at           timestamptz not null default now(),
    result               text not null check (result in ('match', 'mismatch')),
    mismatch_count       smallint not null check (mismatch_count >= 0),
    expected_positions   jsonb not null,   -- what the database said we hold
    actual_positions     jsonb not null,   -- what IBKR said the account holds
    check_summary        text,
    primary key (window_run_id, check_seq),
    constraint reconciliation_result_chk check ((result = 'match') = (mismatch_count = 0))
);

create table sgpt.reconciliation_mismatch (
    window_run_id      uuid not null,
    check_seq          smallint not null,
    symbol             text not null,      -- as IBKR reports it; may not be one of our instruments
    instrument_code    text references sgpt.instrument (instrument_code),
    trade_id           uuid references sgpt.trade (trade_id),   -- null if no trade explains it
    expected_detail    jsonb not null,
    actual_detail      jsonb not null,
    note               text,
    primary key (window_run_id, check_seq, symbol),
    constraint reconciliation_mismatch_check_fk foreign key (window_run_id, check_seq)
        references sgpt.reconciliation_check (window_run_id, check_seq)
);

-- =====================================================================
-- 6.5 unmatched_position and trade_quantity_adjustment  (C-2)
--    A position IBKR reports that matches no recorded trade's legs — the
--    stock and remaining leg left by an early assignment, a manual trade,
--    or a symbol the system does not trade. The system NEVER closes it.
--    There is no path from these rows to a closing order: only a Halt that
--    is already on, an urgent alert, and the owner's resolution.
--    Automatically closing a position the software does not understand is
--    where a software error can do the most damage — an assigned short
--    call turned into an unintended short stock position, for example.
-- =====================================================================
create table sgpt.unmatched_position (
    unmatched_position_id      uuid primary key default gen_random_uuid(),
    window_run_id              uuid not null,       -- the run that found it
    track_code                 text not null,
    broker_account_id          uuid not null,
    reconciliation_check_seq   smallint not null check (reconciliation_check_seq = 2),
        -- only a confirmed recheck, never a first look — same rule as liquidation
    symbol                     text not null,       -- as IBKR reports it
    sec_type                   text not null check (sec_type in ('OPT', 'STK')),
    ibkr_con_id                bigint,
    option_right               text check (option_right in ('C', 'P')),
    strike                     numeric(12,4),
    expiration                 date,
    ibkr_quantity              numeric(14,4) not null,   -- signed; negative is short
    expected_detail            jsonb not null,      -- what the database expected
    actual_detail              jsonb not null,      -- what IBKR reports
    suspected_trade_id         uuid references sgpt.trade (trade_id),
    suspected_cause            text not null check (suspected_cause in (
                                   'early_assignment', 'exercise', 'manual_trade',
                                   'unknown_symbol', 'broker_correction', 'unknown')),
        -- recorded honestly as a guess; the owner's resolution is the record of fact
    status                     text not null default 'awaiting_owner'
                                 check (status in ('awaiting_owner', 'resolved')),
    detected_at                timestamptz not null default now(),

    -- Owner resolution, written by an owner_resolution run.
    resolved_by_window_run_id  uuid references sgpt.window_run (window_run_id),
    resolved_at                timestamptz,
    resolution_action          text check (resolution_action in (
                                   'closed_in_ibkr', 'position_kept',
                                   'identified_as_ours', 'no_action_needed')),
    owner_note                 text,

    constraint unmatched_position_run_fk foreign key (window_run_id, track_code, broker_account_id)
        references sgpt.window_run (window_run_id, track_code, broker_account_id),
    constraint unmatched_position_recheck_fk foreign key (window_run_id, reconciliation_check_seq)
        references sgpt.reconciliation_check (window_run_id, check_seq),
    constraint unmatched_position_contract_chk check (
        (sec_type = 'OPT' and option_right is not null and strike is not null and expiration is not null)
        or
        (sec_type = 'STK' and option_right is null and strike is null and expiration is null)
    ),
    constraint unmatched_position_resolution_chk check (
        (status = 'awaiting_owner'
            and resolved_at is null and resolved_by_window_run_id is null
            and resolution_action is null and owner_note is null)
        or
        (status = 'resolved'
            and resolved_at is not null and resolved_by_window_run_id is not null
            and resolution_action is not null and owner_note is not null)
    )
);

create index unmatched_position_open_idx on sgpt.unmatched_position (track_code)
    where status = 'awaiting_owner';

-- One quantity written off a trade by owner attestation, and only ever as
-- part of resolving an unmatched position. This is what lets a trade left
-- short a leg by an early assignment reach zero open quantity: the amount
-- that left the account outside our own orders is recorded, with who said
-- so and why, and the open-quantity calculation includes it. The
-- alternative — a status that closes the trade and skips the calculation —
-- was rejected: it would put a hole in the one rule that holds throughout
-- Groups 1 to 3, that open quantity is always computed and never asserted.
create table sgpt.trade_quantity_adjustment (
    trade_quantity_adjustment_id uuid primary key default gen_random_uuid(),
    trade_id                   uuid not null references sgpt.trade (trade_id),
    unmatched_position_id      uuid not null references sgpt.unmatched_position (unmatched_position_id),
    quantity                   integer not null check (quantity > 0),  -- order units
    reason                     text not null check (reason in (
                                   'early_assignment', 'exercise',
                                   'manual_close', 'broker_correction')),
    owner_note                 text not null,
    recorded_by_window_run_id  uuid not null references sgpt.window_run (window_run_id),
    recorded_at                timestamptz not null default now()
);

create index trade_quantity_adjustment_trade_idx
    on sgpt.trade_quantity_adjustment (trade_id);

-- Quantities for one trade, computed from its orders and from any
-- owner-attested adjustment. Used by guards and by the dashboard view
-- below. Never stored.
create function sgpt.trade_quantities(p_trade uuid,
    out entry_filled integer, out exited_filled integer, out adjusted_quantity integer,
    out open_quantity integer, out working_orders integer, out working_exits integer,
    out entry_finished boolean)
language sql stable as $$
    select o.entry_filled, o.exited_filled, a.adjusted,
           (o.entry_filled - o.exited_filled - a.adjusted)::int,
           o.working_orders, o.working_exits, o.entry_finished
    from (select
            coalesce(sum(filled_quantity) filter (where order_role = 'entry'), 0)::int as entry_filled,
            coalesce(sum(filled_quantity) filter (where order_role <> 'entry'), 0)::int as exited_filled,
            (count(*) filter (where sgpt.order_is_working(status)))::int as working_orders,
            (count(*) filter (where sgpt.order_is_working(status)
                                and order_role in ('exit_target', 'exit_stop')))::int as working_exits,
            coalesce(bool_or(order_role = 'entry' and not sgpt.order_is_working(status)), false) as entry_finished
          from sgpt.broker_order
          where trade_id = p_trade) o,
         (select coalesce(sum(quantity), 0)::int as adjusted
            from sgpt.trade_quantity_adjustment
           where trade_id = p_trade) a
$$;

-- =====================================================================
-- 7. liquidation_event and liquidation_item
--    One shared liquidation function, one record shape. The event
--    identifies the trigger; items record each position closed, oldest
--    first, one at a time, never skipping ahead.
-- =====================================================================
create table sgpt.liquidation_event (
    liquidation_event_id       uuid primary key default gen_random_uuid(),
    window_run_id              uuid not null,
    track_code                 text not null,
    step_code                  text not null check (step_code in ('reconciliation', 'liquidation')),
    trigger_type               text not null check (trigger_type in (
                                   'reconciliation_single', 'reconciliation_systemic',
                                   'owner_close_all', 'month_end')),
    urgency                    text not null check (urgency in ('patient', 'aggressive')),
    halt_scope                 text not null check (halt_scope in ('none', 'track')),
    reconciliation_check_seq   smallint,
    -- The run currently holding this event. Equals window_run_id until a
    -- later run continues it (the month-end checkpoint) or stops it (C-1, C-4).
    last_updated_by_window_run_id uuid not null references sgpt.window_run (window_run_id),
    status                     text not null default 'in_progress' check (status in (
                                   'in_progress', 'completed', 'partial', 'stopped')),
        -- partial: the patient month-end attempt worked as designed and did
        -- not close everything. Attempt two at W3 covers the remainder.
        -- It is NOT a failure and must not be recorded as stopped.
    no_positions_to_close      boolean not null default false,
    started_at                 timestamptz not null default now(),
    finished_at                timestamptz,
    stopped_reason             text,
    stopped_at_item_seq        smallint,
    summary                    text,
    -- C-3: one event per run per step, so a month-end run can record both a
    -- reconciliation liquidation and its month-end liquidation.
    constraint liquidation_event_one_per_step_uq unique (window_run_id, step_code),
    constraint liquidation_event_run_fk foreign key (window_run_id, track_code)
        references sgpt.window_run (window_run_id, track_code),
    constraint liquidation_event_recheck_fk foreign key (window_run_id, reconciliation_check_seq)
        references sgpt.reconciliation_check (window_run_id, check_seq),
    constraint liquidation_event_trigger_chk check (
        (trigger_type in ('reconciliation_single', 'reconciliation_systemic')
            and step_code = 'reconciliation' and reconciliation_check_seq = 2
            and urgency = 'aggressive' and halt_scope = 'track')
        or
        (trigger_type = 'owner_close_all'
            and step_code = 'liquidation' and reconciliation_check_seq is null
            and urgency = 'aggressive' and halt_scope = 'track')
        or
        (trigger_type = 'month_end'
            and step_code = 'liquidation' and reconciliation_check_seq is null
            and halt_scope = 'none')
    ),
    constraint liquidation_event_status_chk check (
        ((status = 'in_progress') = (finished_at is null))
        and ((status = 'stopped') = (stopped_reason is not null))
        and (status <> 'partial' or urgency = 'patient')
        and (not no_positions_to_close or status in ('in_progress', 'completed'))
    )
);

create table sgpt.liquidation_item (
    liquidation_event_id   uuid not null references sgpt.liquidation_event (liquidation_event_id),
    item_seq               smallint not null check (item_seq > 0),
    trade_id               uuid not null references sgpt.trade (trade_id),
    trade_sort_at          timestamptz not null,   -- opened_at (or created_at if not yet opened); set by guard
    status                 text not null default 'pending' check (status in (
                               'pending', 'cancelling_orders', 'close_submitted',
                               'closed_confirmed', 'already_closed',
                               'not_filled', 'failed')),
        -- not_filled: a patient month-end closing order finished without
        -- filling. Expected, not a failure; attempt two covers the trade.
    started_at             timestamptz,
    finished_at            timestamptz,
    failure_reason         text,
    primary key (liquidation_event_id, item_seq),
    constraint liquidation_item_trade_uq unique (liquidation_event_id, trade_id),
    constraint liquidation_item_status_chk check (
        ((status in ('closed_confirmed', 'already_closed', 'not_filled', 'failed'))
            = (finished_at is not null))
        and ((status = 'failed') = (failure_reason is not null))
        and ((status = 'pending') = (started_at is null))
    )
);

alter table sgpt.broker_order
    add constraint broker_order_liquidation_item_fk
    foreign key (liquidation_event_id, liquidation_item_seq)
    references sgpt.liquidation_item (liquidation_event_id, item_seq);

-- =====================================================================
-- GUARD TRIGGERS (invariants only)
-- =====================================================================

-- trade --------------------------------------------------------------
create function sgpt.trade_guard() returns trigger
language plpgsql as $$
declare
    r   sgpt.window_run;
    d   sgpt.bot_c_decision;
    q   record;
begin
    if tg_op = 'DELETE' then
        raise exception 'trade % is a permanent record and cannot be deleted', old.trade_ref;
    end if;

    if tg_op = 'INSERT' then
        r := sgpt.require_running_run(new.window_run_id, 'trade insert');
        perform sgpt.require_step_running(new.window_run_id, array['bot_d'], 'trade insert');
        perform sgpt.assert_entries_allowed(r, 'trade insert');
        if new.status <> 'entry_working' then
            raise exception 'trade must be created in entry_working status';
        end if;
        if new.trade_date <> r.trade_date then
            raise exception 'trade_date % does not match run date %', new.trade_date, r.trade_date;
        end if;
        if new.updated_by_window_run_id <> new.window_run_id then
            raise exception 'a new trade must be stamped with its opening run';
        end if;
        select * into d from sgpt.bot_c_decision
         where window_run_id = new.window_run_id and instrument_code = new.instrument_code;
        if d.trade_type is distinct from new.trade_type or d.direction is distinct from new.direction then
            raise exception 'trade type/direction must match the Bot C proposal (% %)', d.trade_type, d.direction;
        end if;
        new.trade_ref := format('SG-%s-%s-%s-%s', to_char(new.trade_date, 'YYMMDD'),
                                coalesce(r.slot_code, 'OWN'), new.track_code, new.instrument_code);
        return new;
    end if;

    -- UPDATE
    r := sgpt.require_running_run(new.updated_by_window_run_id, 'trade update');
    if r.track_code <> old.track_code then
        raise exception 'trade %: can only be updated by a run of track %', old.trade_ref, old.track_code;
    end if;
    if row(new.trade_id, new.trade_ref, new.window_run_id, new.track_code, new.broker_account_id,
           new.instrument_code, new.trade_date, new.trade_type, new.direction,
           new.requested_quantity, new.created_at)
       is distinct from
       row(old.trade_id, old.trade_ref, old.window_run_id, old.track_code, old.broker_account_id,
           old.instrument_code, old.trade_date, old.trade_type, old.direction,
           old.requested_quantity, old.created_at)
    then
        raise exception 'trade %: identity columns are immutable', old.trade_ref;
    end if;
    if old.status in ('not_opened', 'closed') then
        raise exception 'trade % is final (status %) and cannot be changed', old.trade_ref, old.status;
    end if;

    if new.status <> old.status then
        if not ((old.status = 'entry_working' and new.status in ('not_opened', 'open', 'closing'))
             or (old.status = 'open'          and new.status in ('closing', 'closed'))
             or (old.status = 'closing'       and new.status in ('closed', 'not_opened'))) then
            raise exception 'trade %: illegal status change % -> %', old.trade_ref, old.status, new.status;
        end if;
        -- Thesis-invalidation exits are deferred (V13-D1). Reserved, rejected.
        if new.close_reason = 'thesis_invalidation' then
            raise exception 'trade %: thesis-invalidation closes are not built yet and are rejected', old.trade_ref;
        end if;
        -- C-2: an owner-resolution close is only legitimate where the owner
        -- actually attested to the quantity that left the account.
        if new.close_reason = 'owner_resolution'
           and not exists (select 1 from sgpt.trade_quantity_adjustment
                            where trade_id = old.trade_id) then
            raise exception 'trade %: an owner_resolution close needs the owner-attested quantity adjustment', old.trade_ref;
        end if;
        q := sgpt.trade_quantities(old.trade_id);
        if new.status = 'not_opened' and not (q.entry_finished and q.entry_filled = 0 and q.working_orders = 0) then
            raise exception 'trade %: not_opened requires a finished, unfilled entry and no working orders', old.trade_ref;
        end if;
        if new.status = 'open' and not (q.entry_finished and q.entry_filled > 0) then
            raise exception 'trade %: open requires a finished entry order with a filled quantity', old.trade_ref;
        end if;
        if new.status = 'closed' and not (q.entry_filled > 0 and q.open_quantity = 0 and q.working_orders = 0) then
            raise exception 'trade %: closed requires zero open quantity and no working orders (open %, working %)',
                old.trade_ref, q.open_quantity, q.working_orders;
        end if;
        if old.status = 'closing' and new.status = 'closed' and new.close_reason is distinct from old.close_reason then
            raise exception 'trade %: close_reason is fixed once closing starts', old.trade_ref;
        end if;
    end if;

    new.row_version := old.row_version + 1;
    new.updated_at  := now();
    return new;
end $$;

create trigger trade_guard_trg
    before insert or update or delete on sgpt.trade
    for each row execute function sgpt.trade_guard();

-- trade_leg ----------------------------------------------------------
create function sgpt.trade_leg_guard() returns trigger
language plpgsql as $$
declare
    t              sgpt.trade;
    v_last_day     date;
    v_month_end    date;
begin
    if tg_op <> 'INSERT' then
        raise exception 'trade_leg rows are write-once: no updates or deletes';
    end if;
    select * into t from sgpt.trade where trade_id = new.trade_id;
    perform sgpt.require_running_run(t.window_run_id, 'trade_leg insert');
    if t.status <> 'entry_working'
       or exists (select 1 from sgpt.broker_order where trade_id = new.trade_id) then
        raise exception 'trade %: legs must be written before the entry order is sent', t.trade_ref;
    end if;
    if new.symbol <> t.instrument_code then
        raise exception 'trade %: leg symbol % does not match instrument %', t.trade_ref, new.symbol, t.instrument_code;
    end if;
    if (t.trade_type = 'long_etf') <> (new.sec_type = 'STK') then
        raise exception 'trade %: long_etf uses shares; every other trade type uses options', t.trade_ref;
    end if;

    -- G3-D6: no option may expire on or before the last trading day of the
    -- month the trade opens in. Fail safe if the calendar is not loaded
    -- through the end of that month.
    if new.sec_type = 'OPT' then
        v_month_end := (date_trunc('month', t.trade_date) + interval '1 month - 1 day')::date;
        if not exists (select 1 from sgpt.market_calendar where trade_date = v_month_end) then
            raise exception 'trade %: market calendar not loaded through % — cannot verify expiration rule',
                t.trade_ref, v_month_end;
        end if;
        select max(trade_date) into v_last_day
          from sgpt.market_calendar
         where is_trading_day and trade_date between date_trunc('month', t.trade_date)::date and v_month_end;
        if new.expiration <= v_last_day then
            raise exception 'trade %: option expiring % is on or before the last trading day of the month (%)',
                t.trade_ref, new.expiration, v_last_day;
        end if;
    end if;
    return new;
end $$;

create trigger trade_leg_guard_trg
    before insert or update or delete on sgpt.trade_leg
    for each row execute function sgpt.trade_leg_guard();

-- broker_order -------------------------------------------------------
create function sgpt.broker_order_guard() returns trigger
language plpgsql as $$
declare
    r            sgpt.window_run;
    t            sgpt.trade;
    q            record;
    v_legs       int;
    v_expected   int;
    v_entry_act  text;
    v_expiry     timestamptz;
    v_item       sgpt.liquidation_item;
    v_role_code  text;
    v_working    int;
begin
    if tg_op = 'DELETE' then
        raise exception 'broker_order % is a permanent record and cannot be deleted', old.order_ref;
    end if;

    if tg_op = 'INSERT' then
        -- Serialize all order writes for one trade.
        select * into t from sgpt.trade where trade_id = new.trade_id for update;
        r := sgpt.require_running_run(new.submitted_by_window_run_id, 'broker_order insert');
        if r.track_code <> t.track_code or r.broker_account_id <> t.broker_account_id
           or new.broker_account_id <> t.broker_account_id then
            raise exception 'order for trade %: run track/account does not match the trade', t.trade_ref;
        end if;
        if new.status <> 'pending_submit' or new.filled_quantity <> 0 then
            raise exception 'orders must be inserted as pending_submit with nothing filled';
        end if;
        if new.last_synced_by_window_run_id <> new.submitted_by_window_run_id then
            raise exception 'a new order must be stamped with its submitting run';
        end if;
        q := sgpt.trade_quantities(new.trade_id);
        select action into v_entry_act from sgpt.broker_order
         where trade_id = new.trade_id and order_role = 'entry';

        if new.order_role = 'entry' then
            perform sgpt.require_step_running(r.window_run_id, array['bot_d'], 'entry order');
            perform sgpt.assert_entries_allowed(r, 'entry order');
            if t.status <> 'entry_working' or t.window_run_id <> r.window_run_id then
                raise exception 'entry order for trade %: trade must be entry_working and opened by this run', t.trade_ref;
            end if;
            if new.quantity <> t.requested_quantity then
                raise exception 'entry order quantity % must equal requested quantity %', new.quantity, t.requested_quantity;
            end if;
            select count(*) into v_legs from sgpt.trade_leg where trade_id = new.trade_id;
            v_expected := case when t.trade_type in ('long_call', 'long_put', 'long_etf') then 1 else 2 end;
            if v_legs <> v_expected then
                raise exception 'entry order for trade %: % legs recorded, % required for %',
                    t.trade_ref, v_legs, v_expected, t.trade_type;
            end if;
            -- Broker-enforced expiry no later than this window's entry expiry,
            -- and never at or after the 16:00 close (no after-hours entries).
            select (r.trade_date + s.entry_order_expiry_et) at time zone 'America/New_York'
              into v_expiry from sgpt.schedule_slot s where s.slot_code = r.slot_code;
            if new.good_till > v_expiry
               or new.good_till >= (r.trade_date + time '16:00') at time zone 'America/New_York' then
                raise exception 'entry order for trade %: good_till % is later than the window expiry %',
                    t.trade_ref, new.good_till, v_expiry;
            end if;
            v_role_code := 'E';

        elsif new.order_role in ('exit_target', 'exit_stop') then
            perform sgpt.require_step_running(r.window_run_id, array['exit_placement'], 'exit order');
            if t.status <> 'open' then
                raise exception 'exit order for trade %: trade is %, exits are only placed on open trades',
                    t.trade_ref, t.status;
            end if;
            if not q.entry_finished or q.entry_filled = 0 then
                raise exception 'exit order for trade %: entry order has not finished with a fill', t.trade_ref;
            end if;
            if new.action = v_entry_act then
                raise exception 'exit order for trade %: action must be opposite the entry (%)', t.trade_ref, v_entry_act;
            end if;
            -- Working exits of this role, plus this one, may never exceed what we hold.
            select coalesce(sum(quantity - filled_quantity), 0) into v_working
              from sgpt.broker_order
             where trade_id = new.trade_id and order_role = new.order_role
               and sgpt.order_is_working(status);
            if v_working + new.quantity > q.open_quantity then
                raise exception 'exit order for trade %: % working + % new exceeds open quantity %',
                    t.trade_ref, v_working, new.quantity, q.open_quantity;
            end if;
            v_role_code := case new.order_role when 'exit_target' then 'T' else 'S' end;

        else  -- close
            perform sgpt.require_step_running(r.window_run_id, array['reconciliation', 'liquidation'], 'close order');
            if t.status <> 'closing' then
                raise exception 'close order for trade %: trade must be in closing status, not %', t.trade_ref, t.status;
            end if;
            select * into v_item from sgpt.liquidation_item
             where liquidation_event_id = new.liquidation_event_id and item_seq = new.liquidation_item_seq;
            if v_item.trade_id is distinct from new.trade_id
               or coalesce(v_item.status, '') not in ('cancelling_orders', 'close_submitted') then
                raise exception 'close order for trade %: liquidation item must be this trade and in progress', t.trade_ref;
            end if;
            if (select window_run_id from sgpt.liquidation_event
                 where liquidation_event_id = new.liquidation_event_id) is distinct from r.window_run_id then
                raise exception 'close order for trade %: liquidation event belongs to a different run', t.trade_ref;
            end if;
            -- Cancel-exits-first (H-003 2.4): nothing else may still be working.
            if q.working_orders > 0 then
                raise exception 'close order for trade %: % order(s) still working — cancel and confirm them first',
                    t.trade_ref, q.working_orders;
            end if;
            -- Never close more than we hold (prevents an unintended short).
            if new.quantity > q.open_quantity then
                raise exception 'close order for trade %: quantity % exceeds open quantity %',
                    t.trade_ref, new.quantity, q.open_quantity;
            end if;
            if new.action = v_entry_act then
                raise exception 'close order for trade %: action must be opposite the entry (%)', t.trade_ref, v_entry_act;
            end if;
            v_role_code := 'C';
        end if;

        new.order_ref := format('%s-%s%s', t.trade_ref, v_role_code,
            (select count(*) + 1 from sgpt.broker_order
              where trade_id = new.trade_id and order_role = new.order_role));
        return new;
    end if;

    -- UPDATE (Broker Sync recording what IBKR reports)
    r := sgpt.require_running_run(new.last_synced_by_window_run_id, 'broker_order update');
    if r.broker_account_id <> old.broker_account_id then
        raise exception 'order %: can only be updated by a run on the same account', old.order_ref;
    end if;
    if row(new.broker_order_id, new.trade_id, new.broker_account_id, new.order_role, new.exit_tier,
           new.order_ref, new.oca_group, new.action, new.order_type, new.limit_price, new.stop_price,
           new.time_in_force, new.good_till, new.quantity, new.liquidation_event_id,
           new.liquidation_item_seq, new.submitted_by_window_run_id, new.created_at)
       is distinct from
       row(old.broker_order_id, old.trade_id, old.broker_account_id, old.order_role, old.exit_tier,
           old.order_ref, old.oca_group, old.action, old.order_type, old.limit_price, old.stop_price,
           old.time_in_force, old.good_till, old.quantity, old.liquidation_event_id,
           old.liquidation_item_seq, old.submitted_by_window_run_id, old.created_at)
    then
        raise exception 'order %: identity, quantity, and price columns are immutable', old.order_ref;
    end if;
    if not sgpt.order_is_working(old.status) then
        raise exception 'order % is final (status %) and cannot be changed', old.order_ref, old.status;
    end if;
    if (old.ibkr_order_id is not null and new.ibkr_order_id is distinct from old.ibkr_order_id)
       or (old.ibkr_perm_id is not null and new.ibkr_perm_id is distinct from old.ibkr_perm_id) then
        raise exception 'order %: IBKR order IDs are set once and cannot change', old.order_ref;
    end if;
    if new.filled_quantity < old.filled_quantity then
        raise exception 'order %: filled quantity cannot decrease (% -> %)', old.order_ref,
            old.filled_quantity, new.filled_quantity;
    end if;
    if new.status <> old.status and not (
           (old.status = 'pending_submit')
        or (old.status = 'working'          and new.status in ('cancel_requested', 'filled', 'cancelled', 'expired', 'rejected'))
        or (old.status = 'cancel_requested' and new.status in ('filled', 'cancelled', 'expired'))) then
        raise exception 'order %: illegal status change % -> %', old.order_ref, old.status, new.status;
    end if;
    new.last_status_at := now();
    return new;
end $$;

create trigger broker_order_guard_trg
    before insert or update or delete on sgpt.broker_order
    for each row execute function sgpt.broker_order_guard();

-- broker_execution ---------------------------------------------------
create function sgpt.broker_execution_guard() returns trigger
language plpgsql as $$
declare
    r  sgpt.window_run;
begin
    if tg_op = 'DELETE' then
        raise exception 'broker_execution rows are permanent records and cannot be deleted';
    end if;
    if tg_op = 'INSERT' then
        r := sgpt.require_running_run(new.recorded_by_window_run_id, 'broker_execution insert');
        if r.broker_account_id <> new.broker_account_id then
            raise exception 'execution %: recording run is on a different account', new.ibkr_exec_id;
        end if;
        if new.broker_order_id is not null
           and (select broker_account_id from sgpt.broker_order
                 where broker_order_id = new.broker_order_id) <> new.broker_account_id then
            raise exception 'execution %: matched order belongs to a different account', new.ibkr_exec_id;
        end if;
        return new;
    end if;
    -- UPDATE: only the commission report may be added, once.
    perform sgpt.require_running_run(new.recorded_by_window_run_id, 'broker_execution update');
    if old.commission is not null then
        raise exception 'execution %: commission already recorded; executions are otherwise write-once', old.ibkr_exec_id;
    end if;
    if row(new.broker_execution_id, new.broker_account_id, new.ibkr_exec_id, new.corrects_ibkr_exec_id,
           new.broker_order_id, new.reported_order_ref, new.ibkr_perm_id, new.ibkr_con_id, new.symbol,
           new.sec_type, new.option_right, new.strike, new.expiration, new.side, new.quantity,
           new.price, new.executed_at, new.recorded_at)
       is distinct from
       row(old.broker_execution_id, old.broker_account_id, old.ibkr_exec_id, old.corrects_ibkr_exec_id,
           old.broker_order_id, old.reported_order_ref, old.ibkr_perm_id, old.ibkr_con_id, old.symbol,
           old.sec_type, old.option_right, old.strike, old.expiration, old.side, old.quantity,
           old.price, old.executed_at, old.recorded_at)
    then
        raise exception 'execution %: only commission fields may be added after recording', old.ibkr_exec_id;
    end if;
    return new;
end $$;

create trigger broker_execution_guard_trg
    before insert or update or delete on sgpt.broker_execution
    for each row execute function sgpt.broker_execution_guard();

-- reconciliation -----------------------------------------------------
create function sgpt.reconciliation_guard() returns trigger
language plpgsql as $$
begin
    if tg_op <> 'INSERT' then
        raise exception '% rows are write-once: no updates or deletes', tg_table_name;
    end if;
    perform sgpt.require_running_run(new.window_run_id, tg_table_name || ' insert');
    perform sgpt.require_step_running(new.window_run_id, array['reconciliation'], tg_table_name || ' insert');
    if tg_table_name = 'reconciliation_check' and new.check_seq = 2
       and not exists (select 1 from sgpt.reconciliation_check
                        where window_run_id = new.window_run_id and check_seq = 1 and result = 'mismatch') then
        raise exception 'a recheck is only allowed after a first check that found a mismatch';
    end if;
    if tg_table_name = 'reconciliation_mismatch'
       and (select result from sgpt.reconciliation_check
             where window_run_id = new.window_run_id and check_seq = new.check_seq) <> 'mismatch' then
        raise exception 'mismatch rows can only be attached to a check whose result is mismatch';
    end if;
    return new;
end $$;

create trigger reconciliation_check_guard_trg
    before insert or update or delete on sgpt.reconciliation_check
    for each row execute function sgpt.reconciliation_guard();
create trigger reconciliation_mismatch_guard_trg
    before insert or update or delete on sgpt.reconciliation_mismatch
    for each row execute function sgpt.reconciliation_guard();

-- unmatched_position (C-2) -------------------------------------------
-- Recorded by Reconciliation, only against a confirmed recheck, and only
-- once the track Halt is on. Resolved only by an owner_resolution run, in
-- its resolution step, on the same track. Never deleted.
create function sgpt.unmatched_position_guard() returns trigger
language plpgsql as $$
declare
    r sgpt.window_run;
    c sgpt.reconciliation_check;
begin
    if tg_op = 'DELETE' then
        raise exception 'unmatched_position rows are permanent records and cannot be deleted';
    end if;

    if tg_op = 'INSERT' then
        r := sgpt.require_running_run(new.window_run_id, 'unmatched_position insert');
        perform sgpt.require_step_running(new.window_run_id, array['reconciliation'],
                                          'unmatched_position insert');
        if new.status <> 'awaiting_owner' then
            raise exception 'an unmatched position must be recorded awaiting_owner';
        end if;
        select * into c from sgpt.reconciliation_check
         where window_run_id = new.window_run_id and check_seq = new.reconciliation_check_seq;
        if c.result is distinct from 'mismatch' then
            raise exception 'an unmatched position must point at a recheck that confirmed the mismatch';
        end if;
        -- Halt first, exactly as for a liquidation: new entries stay blocked
        -- even if everything after this fails.
        if not (select is_halted from sgpt.trading_track where track_code = new.track_code) then
            raise exception 'set the track Halt before recording an unmatched position on track %',
                new.track_code;
        end if;
        if new.suspected_trade_id is not null
           and (select track_code from sgpt.trade where trade_id = new.suspected_trade_id) <> new.track_code then
            raise exception 'the suspected trade belongs to a different track';
        end if;
        return new;
    end if;

    -- UPDATE: the owner's resolution, and nothing else.
    if old.status = 'resolved' then
        raise exception 'unmatched position is already resolved and cannot be changed';
    end if;
    if row(new.unmatched_position_id, new.window_run_id, new.track_code, new.broker_account_id,
           new.reconciliation_check_seq, new.symbol, new.sec_type, new.ibkr_con_id,
           new.option_right, new.strike, new.expiration, new.ibkr_quantity,
           new.expected_detail, new.actual_detail, new.suspected_trade_id,
           new.suspected_cause, new.detected_at)
       is distinct from
       row(old.unmatched_position_id, old.window_run_id, old.track_code, old.broker_account_id,
           old.reconciliation_check_seq, old.symbol, old.sec_type, old.ibkr_con_id,
           old.option_right, old.strike, old.expiration, old.ibkr_quantity,
           old.expected_detail, old.actual_detail, old.suspected_trade_id,
           old.suspected_cause, old.detected_at)
    then
        raise exception 'unmatched position: only the owner resolution may be added';
    end if;
    if new.status <> 'resolved' then
        raise exception 'an unmatched position may only change to resolved';
    end if;
    r := sgpt.require_running_run(new.resolved_by_window_run_id, 'unmatched_position resolution');
    if r.run_type <> 'owner_resolution' then
        raise exception 'an unmatched position is resolved by an owner_resolution run, not a % run', r.run_type;
    end if;
    if r.track_code <> old.track_code then
        raise exception 'unmatched position: only a run on track % may resolve it', old.track_code;
    end if;
    perform sgpt.require_step_running(r.window_run_id, array['resolution'],
                                      'unmatched_position resolution');
    return new;
end $$;

create trigger unmatched_position_guard_trg
    before insert or update or delete on sgpt.unmatched_position
    for each row execute function sgpt.unmatched_position_guard();

-- trade_quantity_adjustment (C-2) ------------------------------------
-- Write-once. Only inside an owner_resolution run's resolution step, only
-- against an unmatched position still awaiting the owner, and never for
-- more than the trade actually holds — so this can never invent a position
-- or create a short.
create function sgpt.trade_quantity_adjustment_guard() returns trigger
language plpgsql as $$
declare
    r sgpt.window_run;
    t sgpt.trade;
    u sgpt.unmatched_position;
    q record;
begin
    if tg_op <> 'INSERT' then
        raise exception 'trade_quantity_adjustment rows are write-once: no updates or deletes';
    end if;
    r := sgpt.require_running_run(new.recorded_by_window_run_id, 'trade_quantity_adjustment insert');
    if r.run_type <> 'owner_resolution' then
        raise exception 'a quantity adjustment may only be recorded by an owner_resolution run, not a % run', r.run_type;
    end if;
    perform sgpt.require_step_running(r.window_run_id, array['resolution'],
                                      'trade_quantity_adjustment insert');
    select * into t from sgpt.trade where trade_id = new.trade_id for update;
    if t.track_code <> r.track_code then
        raise exception 'trade %: a quantity adjustment must come from a run on its own track', t.trade_ref;
    end if;
    select * into u from sgpt.unmatched_position where unmatched_position_id = new.unmatched_position_id;
    if u.status <> 'awaiting_owner' then
        raise exception 'the unmatched position being resolved is already %', u.status;
    end if;
    if u.track_code <> t.track_code then
        raise exception 'the unmatched position is on track %, the trade on track %', u.track_code, t.track_code;
    end if;
    if t.status not in ('entry_working', 'open', 'closing') then
        raise exception 'trade % is % and needs no quantity adjustment', t.trade_ref, t.status;
    end if;
    q := sgpt.trade_quantities(new.trade_id);
    if new.quantity > q.open_quantity then
        raise exception 'trade %: adjustment of % exceeds the open quantity %',
            t.trade_ref, new.quantity, q.open_quantity;
    end if;
    return new;
end $$;

create trigger trade_quantity_adjustment_guard_trg
    before insert or update or delete on sgpt.trade_quantity_adjustment
    for each row execute function sgpt.trade_quantity_adjustment_guard();

-- trading_track (C-2) ------------------------------------------------
-- A track Halt cannot be released while an unmatched position on that
-- track is still unresolved. The owner still decides when to release it;
-- this only stops the release happening before the thing that caused the
-- Halt has been explained. Resuming entries into an account holding a
-- position the system cannot account for is the exact failure the Halt
-- exists to prevent.
create function sgpt.trading_track_halt_release_guard() returns trigger
language plpgsql as $$
declare v_open int;
begin
    if old.is_halted and not new.is_halted then
        select count(*) into v_open from sgpt.unmatched_position
         where track_code = old.track_code and status = 'awaiting_owner';
        if v_open > 0 then
            raise exception 'cannot release the Halt on track %: % unmatched position(s) still unresolved',
                old.track_code, v_open;
        end if;
    end if;
    return new;
end $$;

create trigger trading_track_halt_release_guard_trg
    before update on sgpt.trading_track
    for each row execute function sgpt.trading_track_halt_release_guard();

-- liquidation_event --------------------------------------------------
create function sgpt.liquidation_event_guard() returns trigger
language plpgsql as $$
declare
    r            sgpt.window_run;   -- the run acting now
    o            sgpt.window_run;   -- the run that created the event
    v_check      sgpt.reconciliation_check;
    v_rows       int;
    v_unfinished int;
    v_items      int;
    v_active     int;
begin
    if tg_op = 'DELETE' then
        raise exception 'liquidation_event rows are permanent records and cannot be deleted';
    end if;

    if tg_op = 'INSERT' then
        new.last_updated_by_window_run_id := new.window_run_id;
        r := sgpt.require_running_run(new.window_run_id, 'liquidation_event insert');
        if new.status <> 'in_progress' then
            raise exception 'liquidation events must be inserted in_progress';
        end if;
        perform sgpt.require_step_running(new.window_run_id, array[new.step_code], 'liquidation_event insert');
        if not ((new.trigger_type in ('reconciliation_single', 'reconciliation_systemic')
                    and r.run_type in ('trading_window', 'month_end_close'))
             or (new.trigger_type = 'owner_close_all' and r.run_type = 'manual_liquidation')
             or (new.trigger_type = 'month_end' and r.run_type = 'month_end_close')) then
            raise exception 'liquidation trigger % cannot run in a % run', new.trigger_type, r.run_type;
        end if;
        if new.urgency = 'patient' and not (new.trigger_type = 'month_end' and r.slot_code = 'W2') then
            raise exception 'patient pricing is only for month-end attempt one (W2)';
        end if;
        -- Recheck-first and the one-versus-many rule.
        if new.trigger_type like 'reconciliation%' then
            select * into v_check from sgpt.reconciliation_check
             where window_run_id = new.window_run_id and check_seq = 2;
            select count(*) into v_rows from sgpt.reconciliation_mismatch
             where window_run_id = new.window_run_id and check_seq = 2;
            if v_check.result is distinct from 'mismatch' or v_rows <> v_check.mismatch_count then
                raise exception 'liquidation requires a confirmed recheck mismatch with every mismatch recorded';
            end if;
            if (new.trigger_type = 'reconciliation_single') <> (v_check.mismatch_count = 1) then
                raise exception 'trigger % does not match % confirmed mismatch(es)', new.trigger_type, v_check.mismatch_count;
            end if;
        end if;
        -- Halt first (G3-D9): the Halt must already be on before the event exists.
        if new.halt_scope = 'track'
           and not (select is_halted from sgpt.trading_track where track_code = new.track_code) then
            raise exception 'set the track Halt before recording a % liquidation', new.trigger_type;
        end if;
        return new;
    end if;

    -- UPDATE
    if old.status <> 'in_progress' then
        raise exception 'liquidation event is final (status %)', old.status;
    end if;

    -- Who is acting now, and are they entitled to act on this event?
    -- Until C-1 this was always the creating run, which is what stranded an
    -- interrupted liquidation in_progress forever (C-4) and stopped the
    -- 2:35 PM checkpoint from finishing the patient month-end attempt (C-1).
    r := sgpt.require_running_run(new.last_updated_by_window_run_id, 'liquidation_event update');
    if r.track_code <> old.track_code then
        raise exception 'liquidation event: only a run on track % may update it', old.track_code;
    end if;
    perform sgpt.require_step_running(r.window_run_id, array['reconciliation', 'liquidation'],
                                      'liquidation_event update');
    if r.window_run_id <> old.window_run_id then
        select * into o from sgpt.window_run where window_run_id = old.window_run_id;
        if new.status = 'stopped' then
            null;   -- C-4: recovering a liquidation whose run failed or was abandoned
        elsif old.trigger_type = 'month_end' and old.urgency = 'patient'
              and r.run_type = 'month_end_checkpoint' and r.trade_date = o.trade_date then
            null;   -- C-1: the 2:35 PM checkpoint finishing month-end attempt one
        else
            raise exception 'liquidation event started by %: a later run may only stop it, or finish the patient month-end attempt',
                o.run_label;
        end if;
    end if;

    if row(new.liquidation_event_id, new.window_run_id, new.track_code, new.step_code, new.trigger_type,
           new.urgency, new.halt_scope, new.reconciliation_check_seq, new.started_at)
       is distinct from
       row(old.liquidation_event_id, old.window_run_id, old.track_code, old.step_code, old.trigger_type,
           old.urgency, old.halt_scope, old.reconciliation_check_seq, old.started_at)
    then
        raise exception 'liquidation event: identity columns are immutable';
    end if;

    -- Partial means "the patient attempt worked as designed and did not close
    -- everything". Nothing else may end that way; an aggressive liquidation
    -- that did not finish is stopped, and the owner is alerted.
    if new.status = 'partial' and old.urgency <> 'patient' then
        raise exception 'liquidation event: partial belongs to the patient month-end attempt only';
    end if;

    select count(*) into v_items from sgpt.liquidation_item
     where liquidation_event_id = old.liquidation_event_id;

    if new.status in ('completed', 'partial') then
        -- A patient attempt may finish with positions that did not fill;
        -- nothing else may.
        select count(*) into v_unfinished from sgpt.liquidation_item
         where liquidation_event_id = old.liquidation_event_id
           and status not in ('closed_confirmed', 'already_closed')
           and not (new.status = 'partial' and status = 'not_filled');
        if v_unfinished > 0 then
            raise exception 'liquidation event cannot complete: % item(s) not confirmed closed', v_unfinished;
        end if;
    end if;

    if new.status = 'completed' then
        -- C-2 (part): a liquidation that closed nothing must say so out loud.
        -- Before this, an event with no items completed silently while a
        -- position was still sitting in the account.
        if v_items = 0 and not new.no_positions_to_close then
            raise exception 'liquidation event cannot complete with no positions recorded unless it records that there was nothing to close';
        end if;
        if v_items > 0 and new.no_positions_to_close then
            raise exception 'no_positions_to_close cannot be set on a liquidation holding % position(s)', v_items;
        end if;
        -- A liquidation that covers the whole track cannot be recorded as
        -- successful while the track still holds an active trade.
        if old.trigger_type in ('reconciliation_systemic', 'owner_close_all', 'month_end') then
            select count(*) into v_active from sgpt.trade
             where track_code = old.track_code
               and status in ('entry_working', 'open', 'closing');
            if v_active > 0 then
                raise exception 'liquidation event cannot complete: % active trade(s) still open on track %',
                    v_active, old.track_code;
            end if;
        end if;
    end if;

    if new.status = 'partial' and v_items = 0 then
        raise exception 'a partial liquidation must have recorded the positions it worked on';
    end if;

    if new.status = 'stopped' and new.stopped_at_item_seq is null and v_items > 0 then
        raise exception 'a stopped liquidation must record the item where it stopped';
    end if;
    return new;
end $$;

create trigger liquidation_event_guard_trg
    before insert or update or delete on sgpt.liquidation_event
    for each row execute function sgpt.liquidation_event_guard();

-- liquidation_item ---------------------------------------------------
create function sgpt.liquidation_item_guard() returns trigger
language plpgsql as $$
declare
    e          sgpt.liquidation_event;
    r          sgpt.window_run;
    t          sgpt.trade;
begin
    if tg_op = 'DELETE' then
        raise exception 'liquidation_item rows are permanent records and cannot be deleted';
    end if;
    select * into e from sgpt.liquidation_event where liquidation_event_id = new.liquidation_event_id;
    -- The run currently holding the event is the run allowed to write its items.
    r := sgpt.require_running_run(e.last_updated_by_window_run_id, 'liquidation_item ' || lower(tg_op));
    if r.track_code <> e.track_code then
        raise exception 'liquidation item: only a run on track % may update it', e.track_code;
    end if;
    select * into t from sgpt.trade where trade_id = new.trade_id;

    if tg_op = 'INSERT' then
        if e.status <> 'in_progress' then
            raise exception 'cannot add items to a % liquidation event', e.status;
        end if;
        -- A later run may finish or stop a liquidation; it may never widen it.
        if e.last_updated_by_window_run_id <> e.window_run_id then
            raise exception 'positions may only be added by the run that started the liquidation';
        end if;
        if new.status <> 'pending' then
            raise exception 'liquidation items must be inserted pending';
        end if;
        if t.track_code <> e.track_code or t.status not in ('entry_working', 'open', 'closing') then
            raise exception 'trade % is not an active trade on track %', t.trade_ref, e.track_code;
        end if;
        -- C-2: the system never closes a position it cannot account for.
        -- Everything else on the track follows the normal response.
        if exists (select 1 from sgpt.unmatched_position u
                    where u.status = 'awaiting_owner' and u.suspected_trade_id = t.trade_id) then
            raise exception 'trade % has an unresolved unmatched position: the owner must resolve it, the system does not close it',
                t.trade_ref;
        end if;
        if e.trigger_type = 'reconciliation_single'
           and not exists (select 1 from sgpt.reconciliation_mismatch m
                            where m.window_run_id = e.window_run_id and m.check_seq = 2
                              and (m.trade_id = t.trade_id or m.instrument_code = t.instrument_code)) then
            raise exception 'single-instrument liquidation may only close the mismatched instrument';
        end if;
        new.trade_sort_at := coalesce(t.opened_at, t.created_at);
        if new.item_seq <> (select coalesce(max(item_seq), 0) + 1 from sgpt.liquidation_item
                             where liquidation_event_id = new.liquidation_event_id) then
            raise exception 'liquidation items must be numbered consecutively';
        end if;
        -- Oldest first (Requirements 8.3): no active trade on this track that is
        -- not already in this event may be older than the one being added.
        if e.trigger_type <> 'reconciliation_single' and exists (
               select 1 from sgpt.trade o
                where o.track_code = e.track_code
                  and o.status in ('entry_working', 'open', 'closing')
                  and o.trade_id <> t.trade_id
                  and coalesce(o.opened_at, o.created_at) < new.trade_sort_at
                  and not exists (select 1 from sgpt.liquidation_item i
                                   where i.liquidation_event_id = e.liquidation_event_id
                                     and i.trade_id = o.trade_id)) then
            raise exception 'liquidation must proceed oldest position first: an active trade older than % is not yet in this liquidation',
                t.trade_ref;
        end if;
        return new;
    end if;

    -- UPDATE
    if row(new.liquidation_event_id, new.item_seq, new.trade_id, new.trade_sort_at)
       is distinct from row(old.liquidation_event_id, old.item_seq, old.trade_id, old.trade_sort_at) then
        raise exception 'liquidation item: identity columns are immutable';
    end if;
    if old.status in ('closed_confirmed', 'already_closed', 'not_filled', 'failed') then
        raise exception 'liquidation item % is final (status %)', old.item_seq, old.status;
    end if;
    if new.status <> old.status then
        if not ((old.status = 'pending'           and new.status in ('cancelling_orders', 'close_submitted', 'already_closed', 'failed'))
             or (old.status = 'cancelling_orders' and new.status in ('close_submitted', 'already_closed', 'failed'))
             or (old.status = 'close_submitted'   and new.status in ('closed_confirmed', 'not_filled', 'failed'))) then
            raise exception 'liquidation item %: illegal status change % -> %', old.item_seq, old.status, new.status;
        end if;
        if new.status = 'not_filled' and e.urgency <> 'patient' then
            raise exception 'liquidation item %: not_filled belongs to the patient month-end attempt only', old.item_seq;
        end if;
        -- One position at a time is an AGGRESSIVE liquidation rule
        -- (Requirements 8.3). The patient month-end attempt places a closing
        -- order on every position at once, because each order works until
        -- 2:30 PM and a slow first fill would block every position behind it.
        if e.urgency = 'aggressive' and old.status = 'pending' and exists (
               select 1 from sgpt.liquidation_item
                where liquidation_event_id = old.liquidation_event_id
                  and item_seq < old.item_seq
                  and status not in ('closed_confirmed', 'already_closed')) then
            raise exception 'liquidation item % cannot start: an earlier position is not confirmed closed', old.item_seq;
        end if;
        if new.status in ('closed_confirmed', 'already_closed') and t.status not in ('closed', 'not_opened') then
            raise exception 'liquidation item %: trade % is still %', old.item_seq, t.trade_ref, t.status;
        end if;
    end if;
    return new;
end $$;

create trigger liquidation_item_guard_trg
    before insert or update or delete on sgpt.liquidation_item
    for each row execute function sgpt.liquidation_item_guard();

-- =====================================================================
-- VIEWS
-- =====================================================================

-- Current positions with computed quantities. Reconciliation's
-- "expected positions" and the dashboard's Current Positions screen.
create view sgpt.trade_position_v as
select t.trade_id, t.trade_ref, t.track_code, t.instrument_code, t.trade_type, t.direction,
       t.status, t.requested_quantity, t.opened_at, t.closing_started_at, t.close_reason,
       q.entry_filled, q.exited_filled, q.adjusted_quantity, q.open_quantity,
       q.working_orders, q.working_exits, q.entry_finished
from sgpt.trade t
cross join lateral sgpt.trade_quantities(t.trade_id) q;

-- Open trades with no working exit orders. Exit placement's to-do list,
-- and a dashboard warning when a position is unprotected.
create view sgpt.unprotected_open_trade_v as
select * from sgpt.trade_position_v
where status = 'open' and open_quantity > 0 and working_exits = 0;

-- C-4: liquidations left in progress by a run that is no longer running.
-- This is the alert source for "liquidation stopped" and the work list for
-- the next run on that track, which records the event as stopped.
-- The patient month-end attempt is deliberately excluded until its
-- month_end_checkpoint has run: between 1:05 PM and 2:35 PM its event is
-- SUPPOSED to be in progress with its creating run finished.
create view sgpt.interrupted_liquidation_v as
select e.liquidation_event_id, e.window_run_id, e.track_code, e.trigger_type,
       e.urgency, e.started_at, r.run_label as owning_run, r.status as owning_run_status,
       (select count(*) from sgpt.liquidation_item i
         where i.liquidation_event_id = e.liquidation_event_id
           and i.status not in ('closed_confirmed', 'already_closed', 'not_filled')) as unfinished_items
from sgpt.liquidation_event e
join sgpt.window_run r on r.window_run_id = e.last_updated_by_window_run_id
where e.status = 'in_progress'
  and r.status <> 'running'
  and not (e.trigger_type = 'month_end' and e.urgency = 'patient'
           and not exists (select 1 from sgpt.window_run c
                            where c.trade_date = r.trade_date
                              and c.track_code = e.track_code
                              and c.run_type = 'month_end_checkpoint'
                              and c.status in ('running', 'completed')));

-- =====================================================================
-- Row Level Security: enabled, no policies = default deny for API roles.
-- =====================================================================
alter table sgpt.bot_d_verification     enable row level security;
alter table sgpt.trade                  enable row level security;
alter table sgpt.trade_leg              enable row level security;
alter table sgpt.broker_order           enable row level security;
alter table sgpt.broker_execution       enable row level security;
alter table sgpt.reconciliation_check   enable row level security;
alter table sgpt.reconciliation_mismatch enable row level security;
alter table sgpt.liquidation_event      enable row level security;
alter table sgpt.liquidation_item       enable row level security;
alter table sgpt.unmatched_position     enable row level security;
alter table sgpt.trade_quantity_adjustment enable row level security;
