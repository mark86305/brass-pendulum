-- =====================================================================
-- SpeculativeGPT — Schema Group 4: audit and revisions
-- Draft G4-D1 | 2026-09-12 | PROPOSED — NOT APPLIED
--
-- Depends on: Group 1 Draft 4, Group 2 Draft 2, Group 3 Draft 2.
-- Companion to Requirements v1.3 and Handover H-005 (H-006 pending).
-- Target: Supabase Postgres 15+. Validated locally on Postgres 16.
--
-- Sections in this draft:
--   1. account_value_snapshot   what the account was worth, from Broker Sync
--   2. capital_baseline         the capital preservation levels, in DOLLARS
--   3. external_cash_flow       the owner's deposits and withdrawals
--
-- Still to come in Group 4: strategy revisions and the revision-triggering
-- parameter list, the operator control log, the Halt log, the notification
-- record, and qualification counting.
--
-- Design decisions carried into this draft (2026-09-12 session):
--   S12-D10  Capital preservation levels are stored as DOLLAR amounts, not
--            as a percentage of a moving baseline. A percentage assumes the
--            owner's tolerance for loss scales linearly with account size,
--            and it does not: 30% of $10,000 is an acceptable cost of
--            learning, 30% of $1,000,000 is not. The implied percentage is
--            computed for display and never stored.
--   S12-D11  The baseline ratchets on owner action, not automatically, and
--            takes effect at the next monthly reset so each month stays a
--            clean comparison period (Requirements 10.2). The owner's
--            immediate tools are unchanged: Manual Risk Multiplier, Halt,
--            Close All.
--   S12-D12  A baseline carries a mode. 'observing' means the level exists
--            to be watched, not relied on — which is what the first two
--            months of paper trading are for. 'active' means it is the real
--            limit. Leaving paper trading with a band still in observing
--            mode is a go-live check.
--   S12-D13  External cash flows carry TWO dates: when the money settled and
--            the month it counts from. Money that arrives on the 28th to go
--            live on the 1st must not move position sizing, the capital
--            baseline or the ownership calculation for those four days.
--
-- INTENTIONAL DEBT, recorded so it is revisited on purpose:
--   Lowering a capital baseline is treated exactly like raising it — an
--   operator control, no qualification. That is right while this is paper
--   trading with one track and the owner's own money. It stops being right
--   at the LLC transition, when outside money is in the account. Revisit
--   then; it is a guard and a log entry, not a migration.
-- =====================================================================

-- =====================================================================
-- 1. account_value_snapshot
--    What IBKR said the account was worth at a moment in time. Written
--    only by Broker Sync, so account value can never be asserted by the
--    part of the system that is about to act on it. Never updated.
--    Feeds: Bot C position sizing as a percentage of portfolio, the
--    capital preservation comparison, month-start capital parity between
--    tracks, monthly mark-to-market, external cash-flow detection, and
--    the dashboard.
-- =====================================================================
create table sgpt.account_value_snapshot (
    account_value_snapshot_id uuid primary key default gen_random_uuid(),
    window_run_id             uuid not null,
    track_code                text not null,
    broker_account_id         uuid not null,
    as_of                     timestamptz not null,   -- as IBKR reported it
    net_liquidation_value     numeric(16,2) not null,
    total_cash                numeric(16,2) not null,
    position_market_value     numeric(16,2) not null,
    available_funds           numeric(16,2),
    unrealized_pnl            numeric(16,2),
    realized_pnl              numeric(16,2),
    recorded_at               timestamptz not null default now(),

    constraint account_value_snapshot_run_fk
        foreign key (window_run_id, track_code, broker_account_id)
        references sgpt.window_run (window_run_id, track_code, broker_account_id),
    -- Broker Sync runs once per run, so one snapshot per run per account.
    constraint account_value_snapshot_one_per_run_uq unique (window_run_id, broker_account_id)
);

create index account_value_snapshot_track_idx
    on sgpt.account_value_snapshot (track_code, as_of desc);

-- =====================================================================
-- 2. capital_baseline
--    The capital preservation levels for one track, in dollars, for one
--    effective month. A new row supersedes rather than overwrites, so what
--    the limit was at any past moment stays readable.
-- =====================================================================
create table sgpt.capital_baseline (
    capital_baseline_id       uuid primary key default gen_random_uuid(),
    track_code                text not null references sgpt.trading_track (track_code),
    effective_month           date not null,          -- first day of the month it governs
    baseline_value            numeric(16,2) not null check (baseline_value > 0),
        -- the account value the levels were set from; context, not a limit
    engage_level              numeric(16,2) not null check (engage_level > 0),
        -- at or below this, the track enters capital preservation mode
    release_level             numeric(16,2) not null check (release_level > 0),
        -- at or above this, the track leaves it
    mode                      text not null check (mode in ('observing', 'active')),
    owner_note                text not null,
    set_by                    text not null default 'owner' check (set_by in ('owner', 'system')),
    set_at                    timestamptz not null default now(),

    constraint capital_baseline_month_chk check (effective_month = date_trunc('month', effective_month)::date),
    constraint capital_baseline_one_per_month_uq unique (track_code, effective_month),
    -- Engage strictly below release: a band, not a line. Without the gap a
    -- track sitting exactly at the level would flap in and out of capital
    -- preservation on every snapshot.
    constraint capital_baseline_band_chk check (engage_level < release_level),
    -- Neither level may sit above the value they were derived from.
    constraint capital_baseline_ceiling_chk check (release_level <= baseline_value)
);

-- The baseline governing each track right now. Empty for a track that has
-- never had one set, which is a state the dashboard must show plainly
-- rather than treat as zero.
create view sgpt.current_capital_baseline_v as
select distinct on (track_code)
       track_code, capital_baseline_id, effective_month, baseline_value,
       engage_level, release_level, mode, owner_note, set_at,
       round(100.0 * (baseline_value - engage_level) / baseline_value, 2) as implied_engage_drawdown_pct,
       round(100.0 * (baseline_value - release_level) / baseline_value, 2) as implied_release_drawdown_pct
  from sgpt.capital_baseline
 where effective_month <= date_trunc('month', current_date)::date
 order by track_code, effective_month desc;

-- =====================================================================
-- 3. external_cash_flow
--    The owner's deposits and withdrawals. Every return figure the system
--    produces subtracts these, which is what separates what the strategy
--    earned from what the owner put in or took out.
-- =====================================================================
create table sgpt.external_cash_flow (
    external_cash_flow_id     uuid primary key default gen_random_uuid(),
    track_code                text not null references sgpt.trading_track (track_code),
    broker_account_id         uuid not null references sgpt.broker_account (broker_account_id),
    direction                 text not null check (direction in ('deposit', 'withdrawal')),
    amount                    numeric(16,2) not null check (amount > 0),
        -- always positive; direction carries the sign, so a negative
        -- deposit cannot be recorded by accident
    settled_on                date not null,          -- when the money actually hit the account
    effective_month           date not null,          -- the month it counts from
    owner_note                text not null,
    recorded_by               text not null default 'owner' check (recorded_by in ('owner', 'system')),
    recorded_by_window_run_id uuid references sgpt.window_run (window_run_id),
    recorded_at               timestamptz not null default now(),

    constraint external_cash_flow_month_chk check (effective_month = date_trunc('month', effective_month)::date),
    -- Money cannot count from before it arrived.
    constraint external_cash_flow_effective_chk
        check (effective_month >= date_trunc('month', settled_on)::date)
);

create index external_cash_flow_track_idx on sgpt.external_cash_flow (track_code, effective_month);

-- =====================================================================
-- 4. GUARDS
-- =====================================================================

-- account_value_snapshot ---------------------------------------------
create function sgpt.account_value_snapshot_guard() returns trigger
language plpgsql as $$
begin
    if tg_op <> 'INSERT' then
        raise exception 'account_value_snapshot rows are write-once: no updates or deletes';
    end if;
    perform sgpt.require_running_run(new.window_run_id, 'account_value_snapshot insert');
    -- Only Broker Sync records account value. Nothing that is about to act
    -- on the number may also be the thing that wrote it.
    perform sgpt.require_step_running(new.window_run_id, array['broker_sync'],
                                      'account_value_snapshot insert');
    if new.as_of > now() + interval '1 minute' then
        raise exception 'account value snapshot is dated in the future';
    end if;
    return new;
end $$;

create trigger account_value_snapshot_guard_trg
    before insert or update or delete on sgpt.account_value_snapshot
    for each row execute function sgpt.account_value_snapshot_guard();

-- capital_baseline ---------------------------------------------------
-- A baseline takes effect at a monthly reset and is frozen once its month
-- begins. A pending one — for a month that has not started — may still be
-- corrected, because nothing has acted on it yet.
create function sgpt.capital_baseline_guard() returns trigger
language plpgsql as $$
declare
    v_this_month date := date_trunc('month', current_date)::date;
    v_existing   int;
begin
    if tg_op = 'DELETE' then
        raise exception 'capital_baseline rows are permanent records and cannot be deleted';
    end if;

    if tg_op = 'INSERT' then
        if new.effective_month < v_this_month then
            raise exception 'a capital baseline cannot be backdated to %', new.effective_month;
        end if;
        -- The first baseline for a track may start this month; after that a
        -- change waits for the next monthly reset, so each month stays a
        -- clean comparison period.
        select count(*) into v_existing from sgpt.capital_baseline
         where track_code = new.track_code and effective_month <= v_this_month;
        if v_existing > 0 and new.effective_month <= v_this_month then
            raise exception 'a capital baseline change takes effect at the next monthly reset, not during %',
                v_this_month;
        end if;
        return new;
    end if;

    -- UPDATE: only while the month it governs has not started.
    if old.effective_month <= v_this_month then
        raise exception 'the capital baseline for % is in force and cannot be changed', old.effective_month;
    end if;
    if row(new.capital_baseline_id, new.track_code, new.effective_month, new.set_at)
       is distinct from
       row(old.capital_baseline_id, old.track_code, old.effective_month, old.set_at) then
        raise exception 'capital baseline: identity columns are immutable';
    end if;
    return new;
end $$;

create trigger capital_baseline_guard_trg
    before insert or update or delete on sgpt.capital_baseline
    for each row execute function sgpt.capital_baseline_guard();

-- external_cash_flow -------------------------------------------------
-- Write-once. The effective month defaults to the next month when the
-- money lands in the last week, which matches the owner's practice of
-- funding late in the month for the next one, but it stays an editable
-- field on the way in: the record states what happened, it does not
-- enforce when the owner may move money.
create function sgpt.external_cash_flow_guard() returns trigger
language plpgsql as $$
declare v_month_end date;
begin
    if tg_op <> 'INSERT' then
        raise exception 'external_cash_flow rows are write-once: no updates or deletes';
    end if;
    if new.effective_month is null then
        v_month_end := (date_trunc('month', new.settled_on) + interval '1 month - 1 day')::date;
        new.effective_month := case
            when v_month_end - new.settled_on < 7
                then (date_trunc('month', new.settled_on) + interval '1 month')::date
            else date_trunc('month', new.settled_on)::date
        end;
    end if;
    if (select broker_account_id from sgpt.trading_track where track_code = new.track_code)
       <> new.broker_account_id then
        raise exception 'cash flow: broker account does not belong to track %', new.track_code;
    end if;
    if new.recorded_by_window_run_id is not null then
        perform sgpt.require_running_run(new.recorded_by_window_run_id, 'external_cash_flow insert');
    end if;
    return new;
end $$;

create trigger external_cash_flow_guard_trg
    before insert or update or delete on sgpt.external_cash_flow
    for each row execute function sgpt.external_cash_flow_guard();

-- =====================================================================
-- 5. ROW LEVEL SECURITY
-- =====================================================================
alter table sgpt.account_value_snapshot enable row level security;
alter table sgpt.capital_baseline       enable row level security;
alter table sgpt.external_cash_flow     enable row level security;

-- =====================================================================
-- 6. strategy_revision
--    One row per distinct testable version of the strategy. The revision
--    identifier is R-YYYYMMDD-SUBSYSTEM-NN, so it sorts chronologically
--    and says on sight which part of the system changed.
--    Qualification counts are COMPUTED from trade records (V13-D8), never
--    stored as an incremented number: a stored counter can be double
--    counted, missed, or reset by a bug, and when it is wrong nothing in
--    the record shows that it is wrong.
-- =====================================================================
create table sgpt.strategy_revision (
    strategy_revision_id      text primary key
        check (strategy_revision_id ~ '^R-[0-9]{8}-(BOTA|BOTB|BOTC|BOTD|EXEC|SCHED|RISK|MULTI)-[0-9]{2}$'),
    parent_revision_id        text references sgpt.strategy_revision (strategy_revision_id),
    description               text not null,
    -- The classification that drives the 20-trade rule. System level, or
    -- anything touching risk tolerance, placement, purchase or sale, is
    -- trading-affecting and restarts the count.
    trading_affecting         boolean not null,
    state                     text not null default 'draft' check (state in (
                                  'draft', 'running', 'approved', 'retired', 'rejected')),
    created_at                timestamptz not null default now(),
    activated_at              timestamptz,
    finished_at               timestamptz,
    activated_code_version    text,
    owner_note                text,

    constraint strategy_revision_state_chk check (
        ((state = 'draft') = (activated_at is null))
        and ((state in ('approved', 'retired', 'rejected')) = (finished_at is not null))
    )
);

-- =====================================================================
-- 7. revision_parameter
--    Which settings are revision-triggering and which are operator
--    controls, as data the system can check rather than a convention
--    somebody remembers. Seeded with what Requirements v1.3 has decided;
--    the full list is completed before the first paper trade.
-- =====================================================================
create table sgpt.revision_parameter (
    parameter_code            text primary key,
    subsystem                 text not null check (subsystem in (
                                  'bot_a', 'bot_b', 'bot_c', 'bot_d',
                                  'execution', 'scheduling', 'risk', 'platform')),
    display_name              text not null,
    classification            text not null check (classification in (
                                  'revision_triggering', 'operator_control')),
    description               text not null
);

insert into sgpt.revision_parameter (parameter_code, subsystem, display_name, classification, description) values
    ('system_enabled',          'platform',   'On/Off',                  'operator_control',
     'Master switch. Blocks all scheduled runs.'),
    ('system_halt',             'risk',       'Global Halt',             'operator_control',
     'Blocks new entries on every track. Exits, reconciliation and liquidation continue.'),
    ('track_halt',              'risk',       'Track Halt',              'operator_control',
     'Blocks new entries on one track. Set automatically by failures on that track; released only by the owner.'),
    ('environment_mode',        'platform',   'Paper/Live',              'operator_control',
     'Which broker account the tracks trade in.'),
    ('manual_risk_multiplier',  'risk',       'Manual Risk Multiplier',  'operator_control',
     'Scales position size after a trade otherwise qualifies. Cannot make a non-qualifying trade qualify.'),
    ('broker_credentials',      'platform',   'IBKR credentials',        'operator_control',
     'Credential reference only. The secret itself is never stored in this database.'),
    ('capital_baseline',        'risk',       'Capital preservation band','operator_control',
     'Engage and release levels in dollars. Takes effect at the next monthly reset.'),
    ('window_time',             'scheduling', 'Window and checkpoint times','revision_triggering',
     'Changes when orders work and when exits are placed (V13-D4).'),
    ('entry_order_expiry',      'scheduling', 'Entry order expiry',      'revision_triggering',
     'Changes how long an entry order works (V13-D4).'),
    ('position_size_pct',       'bot_c',      'Position sizing bands',   'revision_triggering',
     'Percentage of portfolio committed at each conviction level.'),
    ('profit_target',           'bot_c',      'Profit target',           'revision_triggering',
     'Where a winning trade exits.'),
    ('stop_loss',               'bot_c',      'Stop loss',               'revision_triggering',
     'Where a losing trade exits.'),
    ('conviction_threshold',    'bot_c',      'Conviction threshold',    'revision_triggering',
     'The score a candidate must reach before a trade is proposed.'),
    ('option_filters',          'bot_c',      'Option selection filters', 'revision_triggering',
     'Delta range, days to expiration, open interest and spread limits.'),
    ('indicator_parameters',    'bot_b',      'Indicator parameters',    'revision_triggering',
     'Lookbacks, thresholds and weights used to score instruments.'),
    ('instrument_universe',     'bot_a',      'Instrument universe',     'revision_triggering',
     'Which instruments are scanned.'),
    ('cost_tolerance',          'bot_d',      'Cost tolerance',          'revision_triggering',
     'How far the achievable price may drift from the proposal before the trade is abandoned.');

-- =====================================================================
-- 8. operator_control_log
--    Every change the owner makes to a control, with what it was, what it
--    became, and why. This is also where a stood-down protection is
--    recorded: at MVP the 20-trade rule is advisory, and a promotion made
--    short of the count is written down with the owner's reason rather
--    than left as an absence. A record that only shows successful
--    promotions looks clean because nothing bad is written down, which is
--    indistinguishable from nothing bad having happened.
-- =====================================================================
create table sgpt.operator_control_log (
    operator_control_log_id   uuid primary key default gen_random_uuid(),
    control_code              text not null check (control_code in (
                                  'system_enabled', 'system_halt', 'track_halt',
                                  'environment_mode', 'manual_risk_multiplier',
                                  'broker_credentials', 'capital_baseline',
                                  'platform_upgrade', 'revision_state',
                                  'qualification_override')),
    track_code                text references sgpt.trading_track (track_code),  -- null = system wide
    prior_value               text,
    new_value                 text,
    owner_note                text not null,
    active_strategy_revision_id text not null references sgpt.strategy_revision (strategy_revision_id),
    changed_by                text not null default 'owner' check (changed_by in ('owner', 'system')),
    window_run_id             uuid references sgpt.window_run (window_run_id),
    changed_at                timestamptz not null default now(),

    constraint operator_control_log_changed_chk check (prior_value is distinct from new_value)
);

create index operator_control_log_recent_idx on sgpt.operator_control_log (changed_at desc);

-- =====================================================================
-- 9. halt_log
--    Which Halt, when, why, and which run set it. A Halt set automatically
--    must name the run that set it; a Halt released must name the owner,
--    because only the owner releases one.
-- =====================================================================
create table sgpt.halt_log (
    halt_log_id               uuid primary key default gen_random_uuid(),
    halt_scope                text not null check (halt_scope in ('system', 'track')),
    track_code                text references sgpt.trading_track (track_code),
    action                    text not null check (action in ('set', 'released')),
    reason                    text not null,
    set_by                    text not null check (set_by in ('owner', 'system')),
    window_run_id             uuid references sgpt.window_run (window_run_id),
    occurred_at               timestamptz not null default now(),

    constraint halt_log_scope_chk check ((halt_scope = 'track') = (track_code is not null))
);

create index halt_log_recent_idx on sgpt.halt_log (occurred_at desc);

-- =====================================================================
-- 10. The foreign keys Group 1 was waiting for
-- =====================================================================
alter table sgpt.trading_track
    add constraint trading_track_revision_fk
    foreign key (strategy_revision_id) references sgpt.strategy_revision (strategy_revision_id);

alter table sgpt.window_run
    add constraint window_run_revision_fk
    foreign key (strategy_revision_id) references sgpt.strategy_revision (strategy_revision_id);

-- =====================================================================
-- 11. COUNTING VIEWS — computed, never stored
-- =====================================================================

-- A trade counts toward qualification if it exited by its own rules
-- (V13-D7). Forced closes stay in every performance figure, labelled, but
-- do not count: they neither penalise a candidate for noise nor inflate
-- its record with lucky exits.
create view sgpt.qualifying_trade_v as
select t.trade_id, t.trade_ref, t.track_code, t.closed_at, t.close_reason,
       r.strategy_revision_id,
       (t.close_reason in ('target', 'stop', 'month_end')) as counts_toward_qualification
from sgpt.trade t
join sgpt.window_run r on r.window_run_id = t.window_run_id
where t.status = 'closed';

-- The running count shown beside every revision's results (V13-D8).
-- Twenty is the minimum before promotion may be considered, never an
-- automatic approval.
create view sgpt.revision_qualification_v as
select sr.strategy_revision_id, sr.state, sr.trading_affecting, sr.activated_at,
       count(q.trade_id) filter (where q.counts_toward_qualification) as qualifying_trades,
       count(q.trade_id) filter (where not q.counts_toward_qualification) as forced_close_trades,
       count(q.trade_id) as closed_trades,
       20 as qualifying_trades_required,
       (count(q.trade_id) filter (where q.counts_toward_qualification) >= 20) as minimum_met
from sgpt.strategy_revision sr
left join sgpt.qualifying_trade_v q on q.strategy_revision_id = sr.strategy_revision_id
group by sr.strategy_revision_id, sr.state, sr.trading_affecting, sr.activated_at;

-- Platform version changes, read off the version stamps every run already
-- carries. No separate record is needed, and none can be forgotten.
create view sgpt.platform_version_change_v as
select run_label, trade_date, at_time,
       prior_code_version, code_version,
       prior_gateway_version, ibkr_gateway_version,
       prior_api_version, ibkr_api_version
from (
    select w.run_label, w.trade_date, w.started_at as at_time,
           w.code_version, w.ibkr_gateway_version, w.ibkr_api_version,
           lag(w.code_version)          over o as prior_code_version,
           lag(w.ibkr_gateway_version)  over o as prior_gateway_version,
           lag(w.ibkr_api_version)      over o as prior_api_version
    from sgpt.window_run w
    window o as (order by w.started_at, w.window_run_id)
) x
where prior_code_version is not null
  and (code_version <> prior_code_version
       or ibkr_gateway_version <> prior_gateway_version
       or ibkr_api_version <> prior_api_version);

-- Go-live readiness: qualifying trades closed since the LATER of the
-- revision's activation and the most recent platform version change. A
-- forced IBKR upgrade restarts the count rather than being waved through,
-- because otherwise the exception quietly swallows the rule.
create view sgpt.go_live_readiness_v as
select sr.strategy_revision_id,
       sr.activated_at,
       (select max(at_time) from sgpt.platform_version_change_v) as last_platform_change,
       greatest(sr.activated_at,
                coalesce((select max(at_time) from sgpt.platform_version_change_v), sr.activated_at)) as counting_from,
       count(q.trade_id) as qualifying_trades_since,
       20 as qualifying_trades_required
from sgpt.strategy_revision sr
left join sgpt.qualifying_trade_v q
       on q.strategy_revision_id = sr.strategy_revision_id
      and q.counts_toward_qualification
      and q.closed_at >= greatest(sr.activated_at,
             coalesce((select max(at_time) from sgpt.platform_version_change_v), sr.activated_at))
where sr.state in ('running', 'approved')
group by sr.strategy_revision_id, sr.activated_at;

-- =====================================================================
-- 12. GUARDS for sections 6 to 9
-- =====================================================================
create function sgpt.strategy_revision_guard() returns trigger
language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'strategy_revision rows are permanent records and cannot be deleted';
    end if;
    if tg_op = 'INSERT' then
        if new.state <> 'draft' and new.activated_at is null then
            raise exception 'a revision must record when it became live';
        end if;
        return new;
    end if;
    -- Legal state moves only.
    if new.state <> old.state
       and not ((old.state = 'draft'    and new.state in ('running', 'rejected'))
             or (old.state = 'running'  and new.state in ('approved', 'rejected'))
             or (old.state = 'approved' and new.state = 'retired')) then
        raise exception 'revision %: illegal state change % -> %', old.strategy_revision_id, old.state, new.state;
    end if;
    -- The classification drives the 20-trade rule, so it cannot be
    -- rewritten once trades have been taken under it.
    if old.state <> 'draft' and new.trading_affecting is distinct from old.trading_affecting then
        raise exception 'revision %: the trading-affecting classification is fixed once the revision is live',
            old.strategy_revision_id;
    end if;
    if row(new.strategy_revision_id, new.parent_revision_id, new.created_at)
       is distinct from row(old.strategy_revision_id, old.parent_revision_id, old.created_at) then
        raise exception 'revision: identity columns are immutable';
    end if;
    return new;
end $$;

create trigger strategy_revision_guard_trg
    before insert or update or delete on sgpt.strategy_revision
    for each row execute function sgpt.strategy_revision_guard();

-- The control log and the Halt log are evidence. Write once, keep forever.
create function sgpt.audit_log_guard() returns trigger
language plpgsql as $$
begin
    if tg_op <> 'INSERT' then
        raise exception '% rows are write-once: no updates or deletes', tg_table_name;
    end if;
    if tg_table_name = 'operator_control_log' then
        -- An automatic change must name the run that made it; an owner
        -- change must not pretend a run made it.
        if (new.changed_by = 'system') <> (new.window_run_id is not null) then
            raise exception 'operator control log: a system change names its run, an owner change does not';
        end if;
        if new.window_run_id is not null then
            perform sgpt.require_running_run(new.window_run_id, 'operator_control_log insert');
        end if;
    else
        if (new.set_by = 'system') <> (new.window_run_id is not null) then
            raise exception 'halt log: an automatic Halt names its run, an owner action does not';
        end if;
        -- Only the owner releases a Halt (Requirements 5.2).
        if new.action = 'released' and new.set_by <> 'owner' then
            raise exception 'a Halt is released by the owner, not by the system';
        end if;
    end if;
    return new;
end $$;

create trigger operator_control_log_guard_trg
    before insert or update or delete on sgpt.operator_control_log
    for each row execute function sgpt.audit_log_guard();

create trigger halt_log_guard_trg
    before insert or update or delete on sgpt.halt_log
    for each row execute function sgpt.audit_log_guard();

create function sgpt.revision_parameter_guard() returns trigger
language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'revision_parameter rows are permanent: retire a parameter, do not delete it';
    end if;
    return new;
end $$;

create trigger revision_parameter_guard_trg
    before delete on sgpt.revision_parameter
    for each row execute function sgpt.revision_parameter_guard();

alter table sgpt.strategy_revision      enable row level security;
alter table sgpt.revision_parameter     enable row level security;
alter table sgpt.operator_control_log   enable row level security;
alter table sgpt.halt_log               enable row level security;

-- =====================================================================
-- 13. broker_order_status_history
--     Every status an order actually passed through, with when and which
--     run observed it, plus the raw words IBKR used.
--     Written by an AFTER trigger, not by the bots: a bot cannot forget to
--     record a transition, cannot record one that did not happen, and the
--     history cannot drift from the row it describes, because it is
--     derived from the change itself.
--     Trade status history is deliberately NOT kept. A trade's statuses
--     are already fully timestamped on the trade row (created, opened,
--     closing started, closed), so a history table would restate columns
--     that already exist. Order status is where the churn is, and where
--     IBKR and this database can disagree.
-- =====================================================================
create table sgpt.broker_order_status_history (
    broker_order_status_history_id bigint generated always as identity primary key,
    broker_order_id           uuid not null references sgpt.broker_order (broker_order_id),
    prior_status              text,          -- null on the first row, when the order was created
    new_status                text not null,
    status_detail             text,
    ibkr_status_raw           text,          -- IBKR's own words, in case they stop mapping onto ours
    filled_quantity           integer not null,
    observed_by_window_run_id uuid not null references sgpt.window_run (window_run_id),
    changed_at                timestamptz not null default now()
);

create index broker_order_status_history_order_idx
    on sgpt.broker_order_status_history (broker_order_id, changed_at);

create function sgpt.broker_order_status_history_write() returns trigger
language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        insert into sgpt.broker_order_status_history (broker_order_id, prior_status, new_status,
            status_detail, filled_quantity, observed_by_window_run_id, changed_at)
        values (new.broker_order_id, null, new.status, new.status_detail,
                new.filled_quantity, new.submitted_by_window_run_id, new.last_status_at);
    elsif new.status is distinct from old.status then
        -- Only a real change. A sync that re-reads the same status is not
        -- an event and does not belong in the history.
        insert into sgpt.broker_order_status_history (broker_order_id, prior_status, new_status,
            status_detail, filled_quantity, observed_by_window_run_id, changed_at)
        values (new.broker_order_id, old.status, new.status, new.status_detail,
                new.filled_quantity, new.last_synced_by_window_run_id, new.last_status_at);
    end if;
    return null;
end $$;

create trigger broker_order_status_history_trg
    after insert or update on sgpt.broker_order
    for each row execute function sgpt.broker_order_status_history_write();

create function sgpt.broker_order_status_history_guard() returns trigger
language plpgsql as $$
begin
    raise exception 'broker_order_status_history is written by the database and is never edited or deleted';
end $$;

create trigger broker_order_status_history_guard_trg
    before update or delete on sgpt.broker_order_status_history
    for each row execute function sgpt.broker_order_status_history_guard();

-- =====================================================================
-- 14. notification
--     What the system told the owner, when, and whether it got there.
--     Delivery method is not decided yet (email is the default starting
--     point), so the channel is recorded rather than assumed, and a
--     failed send is a recorded fact rather than a silent one — an alert
--     that was never delivered is the most dangerous kind.
-- =====================================================================
create table sgpt.notification (
    notification_id           uuid primary key default gen_random_uuid(),
    urgency                   text not null check (urgency in ('urgent', 'normal', 'digest')),
    category                  text not null check (category in (
                                  'reconciliation', 'liquidation', 'unmatched_position',
                                  'halt', 'run_failure', 'order_failure',
                                  'month_end', 'qualification', 'daily_summary', 'other')),
    subject                   text not null,
    body                      text not null,
    track_code                text references sgpt.trading_track (track_code),
    window_run_id             uuid references sgpt.window_run (window_run_id),
    trade_id                  uuid references sgpt.trade (trade_id),
    liquidation_event_id      uuid references sgpt.liquidation_event (liquidation_event_id),
    unmatched_position_id     uuid references sgpt.unmatched_position (unmatched_position_id),
    channel                   text not null check (channel in ('email', 'sms', 'push', 'dashboard_only')),
    delivery_status           text not null default 'pending' check (delivery_status in (
                                  'pending', 'sent', 'failed')),
    delivery_detail           text,
    attempts                  smallint not null default 0 check (attempts >= 0),
    created_at                timestamptz not null default now(),
    sent_at                   timestamptz,

    constraint notification_delivery_chk check (
        ((delivery_status = 'sent') = (sent_at is not null))
        and ((delivery_status = 'failed') <= (delivery_detail is not null))
    )
);

create index notification_undelivered_idx on sgpt.notification (created_at)
    where delivery_status <> 'sent';

create function sgpt.notification_guard() returns trigger
language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'notification rows are permanent records and cannot be deleted';
    end if;
    if tg_op = 'INSERT' then
        if new.delivery_status <> 'pending' then
            raise exception 'a notification is recorded before it is sent, not after';
        end if;
        -- An urgent alert the owner can only see by logging in is not an alert.
        if new.urgency = 'urgent' and new.channel = 'dashboard_only' then
            raise exception 'an urgent notification needs a channel that reaches the owner';
        end if;
        return new;
    end if;
    if old.delivery_status = 'sent' then
        raise exception 'notification is already sent and cannot be changed';
    end if;
    if row(new.notification_id, new.urgency, new.category, new.subject, new.body,
           new.track_code, new.window_run_id, new.trade_id, new.created_at)
       is distinct from
       row(old.notification_id, old.urgency, old.category, old.subject, old.body,
           old.track_code, old.window_run_id, old.trade_id, old.created_at) then
        raise exception 'notification: the message itself is immutable; only delivery may be updated';
    end if;
    if new.attempts < old.attempts then
        raise exception 'notification: the attempt count cannot go backwards';
    end if;
    return new;
end $$;

create trigger notification_guard_trg
    before insert or update or delete on sgpt.notification
    for each row execute function sgpt.notification_guard();

alter table sgpt.broker_order_status_history enable row level security;
alter table sgpt.notification                enable row level security;
