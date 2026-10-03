-- =====================================================================
-- SpeculativeGPT — Group 1 invariant tests (Draft G1-D4)
-- D4 changes: T97–T99 cover the new month_end_checkpoint run type (C-1).
-- Carried from D3: helper snapshots track_halted; T7/T8 reflect the
-- seven-step trading window; T19A–T19D cover G3-D7 and G3-D9.
-- Run against a disposable database AFTER g1_schema.sql.
-- Every block raises an exception if the invariant does NOT hold.
-- Prints "G1 TESTS PASSED" at the end.
-- =====================================================================
\set ON_ERROR_STOP on

-- Fixture: one September 2026 week plus month end, one paper account, one track.
insert into sgpt.market_calendar (trade_date, is_trading_day, market_open_et, market_close_et, is_early_close, source) values
    ('2026-09-10', true,  '09:30', '16:00', false, 'test'),
    ('2026-09-11', true,  '09:30', '16:00', false, 'test'),
    ('2026-09-12', false, null,    null,    false, 'test'),
    ('2026-09-29', true,  '09:30', '16:00', false, 'test'),
    ('2026-09-30', true,  '09:30', '16:00', false, 'test'),
    ('2026-11-27', true,  '09:30', '13:00', true,  'test');

insert into sgpt.broker_account (ibkr_account_id, environment, legal_owner, display_name, credential_ref)
values ('DU0000001', 'paper', 'personal', 'Personal paper', 'IBKR_PERSONAL_PAPER');

-- Group 4 adds the foreign key from trading_track and window_run to
-- strategy_revision, so the fixture seeds a real revision rather than
-- inventing an identifier. This is why all four schema files are applied
-- before any test file is run.
insert into sgpt.strategy_revision (strategy_revision_id, description, trading_affecting,
    state, activated_at, activated_code_version, owner_note)
values ('R-20260901-MULTI-01', 'Test baseline revision.', true, 'running', now(), 'testsha',
        'Seeded by the Group 1 test fixture.');

insert into sgpt.trading_track (track_code, role, broker_account_id, strategy_revision_id, run_priority)
select 'PRIMARY', 'primary', broker_account_id, 'R-20260901-MULTI-01', 1 from sgpt.broker_account;

-- Helper to insert a scheduler run with a correct state snapshot.
create function pg_temp.claim(p_date date, p_slot text, p_type text, p_status text default 'running',
                              p_skip text default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    insert into sgpt.window_run (run_type, trigger_source, trade_date, track_code, slot_code, slot_kind,
        scheduled_for, status, skip_reason, strategy_revision_id, broker_account_id, account_environment,
        portfolio_mode, manual_risk_multiplier, system_enabled, system_halted, track_halted, code_version,
        ibkr_gateway_version, ibkr_api_version)
    select p_type, 'scheduler', p_date, t.track_code, s.slot_code, s.slot_kind,
           (p_date + s.scheduled_time_et) at time zone 'America/New_York', p_status, p_skip,
           t.strategy_revision_id, t.broker_account_id, b.environment, t.portfolio_mode, 1.00, true, false, t.is_halted, 'testsha',
           '10.37.1', '10.37.2'
    from sgpt.trading_track t
    join sgpt.broker_account b using (broker_account_id)
    join sgpt.schedule_slot s on s.slot_code = p_slot
    where t.track_code = 'PRIMARY'
    returning window_run_id into v_id;
    return v_id;
end $$;

-- T0: seeded schedule has no sequencing conflicts.
do $$ begin
    if exists (select 1 from sgpt.schedule_conflict_v) then
        raise exception 'T0 FAIL: schedule_conflict_v returned rows';
    end if;
end $$;

-- T1: conflict view catches a W2 order expiry that overruns V2.
do $$ begin
    begin
        update sgpt.schedule_slot set entry_order_expiry_et = '14:40' where slot_code = 'W2';
        if not exists (select 1 from sgpt.schedule_conflict_v where slot_code = 'V2') then
            raise exception 'T1 FAIL: conflict not detected';
        end if;
        raise exception 'rollback';
    exception when raise_exception then
        if sqlerrm like 'T1 FAIL%' then raise; end if;
    end;
end $$;

-- T2: month-end math. Sept 30 is last trading day; Sept 29 has 1 day after it.
do $$ begin
    if not (select is_last_trading_day_of_month from sgpt.trading_day_v where trade_date = '2026-09-30') then
        raise exception 'T2 FAIL: 2026-09-30 not flagged last trading day';
    end if;
    if (select trading_days_after_today_in_month from sgpt.trading_day_v where trade_date = '2026-09-29') <> 1 then
        raise exception 'T2 FAIL: remaining-days count wrong';
    end if;
end $$;

-- T3: scheduler double-fire for the same slot is rejected.
do $$
declare v uuid;
begin
    v := pg_temp.claim('2026-09-10', 'W1', 'trading_window');
    begin
        perform pg_temp.claim('2026-09-10', 'W1', 'trading_window', 'skipped', 'another_run_in_progress');
        raise exception 'T3 FAIL: duplicate slot claim accepted';
    exception when unique_violation then null;
    end;
end $$;

-- T4: a second concurrently running run anywhere is rejected (mutex).
do $$ begin
    begin
        perform pg_temp.claim('2026-09-10', 'V1', 'verification_checkpoint');
        raise exception 'T4 FAIL: second running run accepted';
    exception when unique_violation then null;
    end;
end $$;

-- T5: steps must follow the defined order (Bot A before reconciliation is rejected).
do $$
declare v uuid := (select window_run_id from sgpt.window_run where run_label = '2026-09-10_W1_PRIMARY');
begin
    begin
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (v, 'trading_window', 1, 'bot_a', 'running');
        raise exception 'T5 FAIL: bot_a accepted as first step';
    exception when foreign_key_violation then null;
    end;
end $$;

-- T6: next step cannot start while the prior step is still running.
do $$
declare v uuid := (select window_run_id from sgpt.window_run where run_label = '2026-09-10_W1_PRIMARY');
begin
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v, 'trading_window', 1, 'broker_sync', 'running');
    begin
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (v, 'trading_window', 2, 'reconciliation', 'running');
        raise exception 'T6 FAIL: reconciliation started while broker_sync running';
    exception when raise_exception then
        if sqlerrm like 'T6 FAIL%' then raise; end if;
    end;
end $$;

-- T7: run cannot be marked completed with steps outstanding.
do $$
declare v uuid := (select window_run_id from sgpt.window_run where run_label = '2026-09-10_W1_PRIMARY');
begin
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v and step_code = 'broker_sync';
    begin
        update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = v;
        raise exception 'T7 FAIL: run completed with 1 of 7 steps';
    exception when raise_exception then
        if sqlerrm like 'T7 FAIL%' then raise; end if;
    end;
end $$;

-- T8: a failed step automatically fails the run, and no further step can start.
do $$
declare v uuid := (select window_run_id from sgpt.window_run where run_label = '2026-09-10_W1_PRIMARY');
begin
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v, 'trading_window', 2, 'reconciliation', 'running');
    update sgpt.window_run_step set status = 'failed', finished_at = now(), error_code = 'SYSTEMIC_MISMATCH'
     where window_run_id = v and step_code = 'reconciliation';
    if (select status from sgpt.window_run where window_run_id = v) <> 'failed' then
        raise exception 'T8 FAIL: run not failed after step failure';
    end if;
    begin
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (v, 'trading_window', 3, 'exit_placement', 'running');
        raise exception 'T8 FAIL: exit_placement started after run failed';
    exception when raise_exception then
        if sqlerrm like 'T8 FAIL%' then raise; end if;
    end;
end $$;

-- T9: final runs are immutable and undeletable.
do $$
declare v uuid := (select window_run_id from sgpt.window_run where run_label = '2026-09-10_W1_PRIMARY');
begin
    begin
        update sgpt.window_run set status_detail = 'rewritten history' where window_run_id = v;
        raise exception 'T9 FAIL: final run modified';
    exception when raise_exception then
        if sqlerrm like 'T9 FAIL%' then raise; end if;
    end;
    begin
        delete from sgpt.window_run where window_run_id = v;
        raise exception 'T9 FAIL: run deleted';
    exception when raise_exception then
        if sqlerrm like 'T9 FAIL%' then raise; end if;
    end;
end $$;

-- T10: late write from a zombie process after its run was abandoned is rejected.
do $$
declare v uuid;
begin
    v := pg_temp.claim('2026-09-10', 'V1', 'verification_checkpoint');   -- mutex free again
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v, 'verification_checkpoint', 1, 'broker_sync', 'running');
    update sgpt.window_run set status = 'abandoned', finished_at = now(),
           status_detail = 'Sweeper: exceeded hard timeout' where window_run_id = v;
    begin
        update sgpt.window_run_step set status = 'completed', finished_at = now() where window_run_id = v;
        raise exception 'T10 FAIL: zombie step completion accepted';
    exception when raise_exception then
        if sqlerrm like 'T10 FAIL%' then raise; end if;
    end;
    update sgpt.window_run_step set status = 'abandoned', finished_at = now() where window_run_id = v;
end $$;

-- T11: skipped runs record a reason and do not take the mutex.
do $$ begin
    perform pg_temp.claim('2026-11-27', 'W2', 'trading_window', 'skipped', 'early_close');
    perform pg_temp.claim('2026-11-27', 'W1', 'trading_window');   -- would fail if skip held the mutex
    if (select finished_at from sgpt.window_run where run_label = '2026-11-27_W2_PRIMARY') is null then
        raise exception 'T11 FAIL: skipped run has no finished_at';
    end if;
end $$;

-- T12: a clean trading window completes when all seven steps complete.
do $$
declare v uuid := (select window_run_id from sgpt.window_run where run_label = '2026-11-27_W1_PRIMARY');
        s record;
begin
    for s in select step_seq, step_code from sgpt.run_type_step where run_type = 'trading_window' order by step_seq loop
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (v, 'trading_window', s.step_seq, s.step_code, 'running');
        update sgpt.window_run_step set status = 'completed', finished_at = now()
         where window_run_id = v and step_code = s.step_code;
    end loop;
    update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = v;
end $$;

-- T13: risk multiplier fat-finger (20.0 instead of 2.0) is rejected; version bumps on change.
do $$ begin
    begin
        update sgpt.system_state set manual_risk_multiplier = 20.0;
        raise exception 'T13 FAIL: multiplier 20.0 accepted';
    exception when check_violation or numeric_value_out_of_range then null;
    end;
    update sgpt.system_state set manual_risk_multiplier = 0.50, updated_by = 'owner';
    if (select row_version from sgpt.system_state) <> 2 then
        raise exception 'T13 FAIL: row_version not bumped';
    end if;
end $$;

-- T14: two active tracks cannot share one broker account.
do $$ begin
    begin
        insert into sgpt.trading_track (track_code, role, broker_account_id, strategy_revision_id, run_priority)
        select 'CANDIDATE', 'candidate', broker_account_id, 'R-20260901-MULTI-01', 2 from sgpt.broker_account;
        raise exception 'T14 FAIL: second track on same account accepted';
    exception when unique_violation then null;
    end;
end $$;

-- T15: missed-run view reports W3 on 2026-09-10 as missed (no row was ever written).
do $$ begin
    if (select effective_status from sgpt.scheduled_run_status_v
         where trade_date = '2026-09-10' and slot_code = 'W3') is distinct from 'missed' then
        raise exception 'T15 FAIL: missing W3 not reported as missed';
    end if;
end $$;

-- T16: a trading window slot without an entry-order expiry is rejected.
do $$ begin
    begin
        insert into sgpt.schedule_slot (slot_code, slot_kind, display_name, scheduled_time_et,
               entry_order_expiry_et, min_minutes_before_close, sort_order)
        values ('W4', 'trading_window', 'Bad window', '11:00', null, 60, 70);
        raise exception 'T16 FAIL: trading window without expiry accepted';
    exception when check_violation then null;
    end;
end $$;

-- T17: conflict view flags a final checkpoint before 16:20 and entries expiring at the close.
do $$ begin
    begin
        update sgpt.schedule_slot set scheduled_time_et = '16:05' where slot_code = 'V3';
        update sgpt.schedule_slot set entry_order_expiry_et = '16:00' where slot_code = 'W3';
        if not exists (select 1 from sgpt.schedule_conflict_v where slot_code = 'V3' and problem like 'final checkpoint%') then
            raise exception 'T17 FAIL: early final checkpoint not flagged';
        end if;
        if not exists (select 1 from sgpt.schedule_conflict_v where slot_code = 'W3' and problem like 'entry orders expire%') then
            raise exception 'T17 FAIL: 16:00 entry expiry not flagged';
        end if;
        raise exception 'rollback';
    exception when raise_exception then
        if sqlerrm like 'T17 FAIL%' then raise; end if;
    end;
end $$;

-- T18: Halt is not a reason to skip a run (only Off is).
do $$ begin
    begin
        perform pg_temp.claim('2026-09-11', 'W1', 'trading_window', 'skipped', 'system_halted');
        raise exception 'T18 FAIL: system_halted accepted as skip reason';
    exception when check_violation then null;
    end;
end $$;

-- T19: the recorded IBKR platform versions cannot be rewritten on a run.
do $$
declare v uuid;
begin
    v := pg_temp.claim('2026-09-11', 'W1', 'trading_window');
    begin
        update sgpt.window_run set ibkr_gateway_version = '10.99' where window_run_id = v;
        raise exception 'T19 FAIL: gateway version rewritten';
    exception when raise_exception then
        if sqlerrm like 'T19 FAIL%' then raise; end if;
    end;
    update sgpt.window_run set status = 'abandoned', finished_at = now(), status_detail = 'test cleanup'
     where window_run_id = v;
end $$;

-- T19A: month-end close is defined and completes after its three steps (G3-D7).
do $$
declare v uuid;
        s record;
begin
    v := pg_temp.claim('2026-09-30', 'W2', 'month_end_close');
    for s in select step_seq, step_code from sgpt.run_type_step where run_type = 'month_end_close' order by step_seq loop
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (v, 'month_end_close', s.step_seq, s.step_code, 'running');
        update sgpt.window_run_step set status = 'completed', finished_at = now()
         where window_run_id = v and step_code = s.step_code;
    end loop;
    update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = v;
    if (select count(*) from sgpt.run_type_step where run_type = 'month_end_close') <> 3 then
        raise exception 'T19A FAIL: month_end_close should have 3 steps';
    end if;
end $$;

-- T19B: a checkpoint cannot complete without its exit_placement step.
do $$
declare v uuid;
begin
    v := pg_temp.claim('2026-09-29', 'V1', 'verification_checkpoint');
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v, 'verification_checkpoint', 1, 'broker_sync', 'running');
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v and step_code = 'broker_sync';
    begin
        update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = v;
        raise exception 'T19B FAIL: checkpoint completed without exit_placement';
    exception when raise_exception then
        if sqlerrm like 'T19B FAIL%' then raise; end if;
    end;
    update sgpt.window_run set status = 'abandoned', finished_at = now(), status_detail = 'test cleanup'
     where window_run_id = v;
end $$;

-- T19C: a track Halt requires a time and a reason; release clears all halt fields.
do $$ begin
    begin
        update sgpt.trading_track set is_halted = true where track_code = 'PRIMARY';
        raise exception 'T19C FAIL: track halt without time and reason accepted';
    exception when check_violation then null;
    end;
    update sgpt.trading_track set is_halted = true, halted_at = now(), halt_reason = 'test'
     where track_code = 'PRIMARY';
    begin
        update sgpt.trading_track set is_halted = false where track_code = 'PRIMARY';
        raise exception 'T19C FAIL: release left stale halt fields';
    exception when check_violation then null;
    end;
    update sgpt.trading_track set is_halted = false, halted_at = null, halt_reason = null
     where track_code = 'PRIMARY';
end $$;

-- T19D: the track_halted snapshot on a run cannot be rewritten.
do $$
declare v uuid;
begin
    v := pg_temp.claim('2026-09-29', 'V2', 'verification_checkpoint');
    begin
        update sgpt.window_run set track_halted = true where window_run_id = v;
        raise exception 'T19D FAIL: track_halted snapshot rewritten';
    exception when raise_exception then
        if sqlerrm like 'T19D FAIL%' then raise; end if;
    end;
    update sgpt.window_run set status = 'abandoned', finished_at = now(), status_detail = 'test cleanup'
     where window_run_id = v;
end $$;

-- =====================================================================
-- C-1: the month_end_checkpoint run type
-- =====================================================================

-- T97: a month_end_checkpoint belongs in a verification-checkpoint slot.
-- It records what the patient month-end attempt closed; it is not a window.
do $$ begin
    begin
        perform pg_temp.claim('2026-11-27', 'W2', 'month_end_checkpoint');
        raise exception 'T97 FAIL: month_end_checkpoint accepted in a trading-window slot';
    exception when others then
        if sqlerrm like 'T97 FAIL%' then raise; end if;
        if position('window_run_slot_kind_chk' in sqlerrm) = 0 then
            raise exception 'T97 FAIL: expected slot-kind rejection, got [%]', sqlerrm;
        end if;
    end;
end $$;

-- T98: its step sequence is broker_sync then liquidation, and nothing else.
-- exit_placement must never run at month-end close: it would place exits on
-- a position the system is trying to close.
do $$
declare v uuid;
begin
    v := pg_temp.claim('2026-11-27', 'V2', 'month_end_checkpoint');
    if (select array_agg(step_code order by step_seq) from sgpt.run_type_step
         where run_type = 'month_end_checkpoint') <> array['broker_sync', 'liquidation'] then
        raise exception 'T98 FAIL: unexpected month_end_checkpoint step sequence';
    end if;
    begin
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (v, 'month_end_checkpoint', 1, 'exit_placement', 'running');
        raise exception 'T98 FAIL: exit_placement accepted in a month_end_checkpoint';
    exception when others then
        if sqlerrm like 'T98 FAIL%' then raise; end if;
        if position('window_run_step_def_fk' in sqlerrm) = 0 then
            raise exception 'T98 FAIL: expected step-definition rejection, got [%]', sqlerrm;
        end if;
    end;

    -- T99: the run cannot be completed until both of its steps completed.
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v, 'month_end_checkpoint', 1, 'broker_sync', 'running');
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v and step_code = 'broker_sync';
    begin
        update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = v;
        raise exception 'T99 FAIL: month_end_checkpoint completed with its liquidation step unrun';
    exception when others then
        if sqlerrm like 'T99 FAIL%' then raise; end if;
        if position('of 2 defined steps completed' in sqlerrm) = 0 then
            raise exception 'T99 FAIL: expected step-count rejection, got [%]', sqlerrm;
        end if;
    end;
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v, 'month_end_checkpoint', 2, 'liquidation', 'running');
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v and step_code = 'liquidation';
    update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = v;
end $$;

select 'G1 TESTS PASSED' as result;
