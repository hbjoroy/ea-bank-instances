-- Additive migration for deployed Accounting 842c819. Run atomically with psql -1.
ALTER TABLE accounting.journal_entries ADD COLUMN IF NOT EXISTS effective_bank_date DATE;
ALTER TABLE accounting.journal_entries ADD COLUMN IF NOT EXISTS capital_source_id UUID;
CREATE UNIQUE INDEX IF NOT EXISTS journal_capital_source
    ON accounting.journal_entries(capital_source_id) WHERE capital_source_id IS NOT NULL;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='accounting.journal_entries'::regclass
                   AND conname='journal_capital_evidence') THEN
        ALTER TABLE accounting.journal_entries ADD CONSTRAINT journal_capital_evidence CHECK (
            (capital_source_id IS NULL AND effective_bank_date IS NULL)
            OR (capital_source_id IS NOT NULL AND effective_bank_date IS NOT NULL AND source='sync'
                AND core_transaction_id IS NOT NULL AND core_transaction_timestamp IS NOT NULL
                AND interest_bank_date IS NULL AND NOT savings_movement));
    END IF;
END $$;

CREATE OR REPLACE FUNCTION accounting.monthend_journal_digest(bank_day DATE, bank_timezone TEXT)
RETURNS TEXT LANGUAGE SQL STABLE SET TimeZone='UTC' AS $$
    SELECT encode(sha256(convert_to(COALESCE(string_agg(
        encode(sha256(convert_to((jsonb_build_array(
            e.id,e.period_id,e.reference,e.source,e.core_transaction_id,e.core_transaction_timestamp,
            e.interest_bank_date,e.posted_at,e.savings_movement,l.id,l.gl_account_code,l.currency,l.debit,l.credit,
            c.name,c.account_class,c.account_group,c.normal_side,c.is_group,c.is_active
        ) || CASE WHEN e.capital_source_id IS NULL THEN '[]'::jsonb
             ELSE jsonb_build_array(e.effective_bank_date,e.capital_source_id) END)::text,'UTF8')),'hex'),'' ORDER BY e.id,l.id),''),'UTF8')),'hex')
    FROM accounting.journal_entries e
    LEFT JOIN accounting.journal_lines l ON l.entry_id=e.id
    LEFT JOIN accounting.chart_of_accounts c ON c.code=l.gl_account_code
    WHERE COALESCE(e.effective_bank_date,e.interest_bank_date,(COALESCE(e.core_transaction_timestamp,e.posted_at) AT TIME ZONE bank_timezone)::date)<=bank_day
$$;

CREATE OR REPLACE FUNCTION accounting.guard_monthend_journal() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE hdr accounting.journal_entries%ROWTYPE; old_hdr accounting.journal_entries%ROWTYPE;
BEGIN
    -- A shared writer lock makes the final digest and close a single boundary.
    PERFORM pg_advisory_xact_lock_shared(83032,1);
    IF TG_TABLE_NAME='journal_lines' THEN
        IF TG_OP<>'DELETE' THEN SELECT * INTO hdr FROM accounting.journal_entries WHERE id=NEW.entry_id; END IF;
        IF TG_OP<>'INSERT' THEN SELECT * INTO old_hdr FROM accounting.journal_entries WHERE id=OLD.entry_id; END IF;
    ELSE
        IF TG_OP<>'DELETE' THEN hdr := NEW; END IF;
        IF TG_OP<>'INSERT' THEN old_hdr := OLD; END IF;
    END IF;
    IF EXISTS(SELECT 1 FROM accounting.monthend_closes c
        WHERE c.period_id IN (hdr.period_id,old_hdr.period_id)
        OR COALESCE(hdr.effective_bank_date,hdr.interest_bank_date,(COALESCE(hdr.core_transaction_timestamp,hdr.posted_at) AT TIME ZONE c.bank_timezone)::date)<=c.bank_date
        OR COALESCE(old_hdr.effective_bank_date,old_hdr.interest_bank_date,(COALESCE(old_hdr.core_transaction_timestamp,old_hdr.posted_at) AT TIME ZONE c.bank_timezone)::date)<=c.bank_date)
    THEN RAISE EXCEPTION 'certified bank month cannot receive or change journal movements'; END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION accounting.protect_deposit_opening() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o accounting.deposit_openings%ROWTYPE; ids uuid[];
BEGIN
    SELECT * INTO o FROM accounting.deposit_openings WHERE singleton;
    IF FOUND THEN
        IF TG_TABLE_NAME='journal_entries' THEN
            IF TG_OP<>'INSERT' AND (OLD.id=ANY(o.booked_entries) OR EXISTS(SELECT 1 FROM accounting.deposit_opening_sources s WHERE s.core_transaction_id=OLD.core_transaction_id)) THEN
                RAISE EXCEPTION 'sealed original or opening journal %',OLD.id;
            END IF;
            IF TG_OP<>'DELETE' AND (NEW.source='deposit_opening' OR EXISTS(SELECT 1 FROM accounting.deposit_opening_sources s WHERE s.core_transaction_id=NEW.core_transaction_id)
                    OR coalesce(NEW.core_transaction_timestamp,NEW.posted_at)<o.cutoff_at OR coalesce(NEW.effective_bank_date,NEW.interest_bank_date)<o.first_bank_date) THEN
                RAISE EXCEPTION 'new or changed journal crosses certified opening';
            END IF;
        ELSE
            ids:=CASE TG_OP WHEN 'INSERT' THEN ARRAY[NEW.entry_id] WHEN 'DELETE' THEN ARRAY[OLD.entry_id] ELSE ARRAY[OLD.entry_id,NEW.entry_id] END;
            IF EXISTS(SELECT 1 FROM accounting.journal_entries j WHERE j.id=ANY(ids) AND (j.id=ANY(o.booked_entries) OR EXISTS(SELECT 1 FROM accounting.deposit_opening_sources s WHERE s.core_transaction_id=j.core_transaction_id))) THEN
                RAISE EXCEPTION 'sealed original or opening lines';
            END IF;
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
