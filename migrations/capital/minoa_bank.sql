-- Separate recognition evidence from both the certified opening and interest dating.
CREATE TABLE IF NOT EXISTS core.opening_capital_receipts (
    capital_source_id uuid PRIMARY KEY,
    transaction_id uuid UNIQUE NOT NULL REFERENCES core.transactions(id),
    opening_id uuid UNIQUE NOT NULL REFERENCES core.deposit_openings(id),
    effective_bank_date date NOT NULL,
    external_settled_at timestamptz NOT NULL,
    external_account_id uuid NOT NULL,
    participant text NOT NULL,
    source_reference text NOT NULL,
    cash_account_id uuid NOT NULL REFERENCES core.ledger_accounts(id),
    equity_account_id uuid NOT NULL REFERENCES core.ledger_accounts(id),
    amount numeric NOT NULL CHECK (amount > 0 AND amount = round(amount, 2)),
    currency text NOT NULL CHECK (currency='NOK'),
    recorded_at timestamptz NOT NULL,
    recorded_by text NOT NULL DEFAULT session_user,
    CHECK (cash_account_id <> equity_account_id)
);
DROP TRIGGER IF EXISTS immutable_opening_capital ON core.opening_capital_receipts;
CREATE TRIGGER immutable_opening_capital BEFORE UPDATE OR DELETE ON core.opening_capital_receipts
FOR EACH ROW EXECUTE FUNCTION core.reject_settled_interest_change();

CREATE OR REPLACE FUNCTION core.guard_opening_capital_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='transactions' THEN
        IF EXISTS (SELECT 1 FROM core.opening_capital_receipts WHERE transaction_id=OLD.id) THEN
            RAISE EXCEPTION 'Opening capital transaction is sealed';
        END IF;
    ELSE
        IF (TG_OP <> 'INSERT' AND EXISTS (SELECT 1 FROM core.opening_capital_receipts WHERE transaction_id=OLD.transaction_id))
        OR (TG_OP <> 'DELETE' AND EXISTS (SELECT 1 FROM core.opening_capital_receipts WHERE transaction_id=NEW.transaction_id)) THEN
            RAISE EXCEPTION 'Opening capital postings are sealed';
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END
$$;
DROP TRIGGER IF EXISTS sealed_capital_transaction ON core.transactions;
CREATE TRIGGER sealed_capital_transaction BEFORE UPDATE OR DELETE ON core.transactions
FOR EACH ROW EXECUTE FUNCTION core.guard_opening_capital_source();
DROP TRIGGER IF EXISTS sealed_capital_postings ON core.postings;
CREATE TRIGGER sealed_capital_postings BEFORE INSERT OR UPDATE OR DELETE ON core.postings
FOR EACH ROW EXECUTE FUNCTION core.guard_opening_capital_source();

CREATE OR REPLACE FUNCTION core.recognize_opening_capital(
    bank_id uuid, source_id uuid, effective_day date, settlement_time timestamptz,
    external_account uuid, source_participant text, source_ref text, cash_id uuid, funding numeric
) RETURNS core.opening_capital_receipts LANGUAGE plpgsql AS $$
DECLARE
    receipt core.opening_capital_receipts;
    opening core.deposit_openings;
    tx_id uuid := gen_random_uuid();
    equity_id uuid;
    booking_time timestamptz;
BEGIN
    IF num_nonnulls(bank_id, source_id, effective_day, settlement_time, external_account,
                    source_participant, source_ref, cash_id, funding) <> 9
       OR trim(source_participant)='' OR trim(source_ref)='' OR funding<=0 OR funding<>round(funding,2)
       OR funding::text IN ('NaN','Infinity','-Infinity') THEN
        RAISE EXCEPTION 'Invalid source or amount';
    END IF;
    SELECT o.* INTO STRICT opening FROM core.deposit_openings o JOIN admin.bank_calendar_opening_releases r
      ON r.opening_id=o.id AND r.bank_instance_id=o.bank_instance_id AND r.first_bank_date=o.first_bank_date
      WHERE o.bank_instance_id=bank_id FOR UPDATE OF o;
    IF opening.first_bank_date<>effective_day OR settlement_time >= opening.cutoff_at THEN
        RAISE EXCEPTION 'Initial capital must settle before the certified opening and be recognized on the first bank day';
    END IF;
    SELECT * INTO receipt FROM core.opening_capital_receipts WHERE opening_id=opening.id OR capital_source_id=source_id;
    IF FOUND THEN
        IF (receipt.opening_id,receipt.capital_source_id,receipt.effective_bank_date,receipt.external_settled_at,
            receipt.external_account_id,receipt.participant,receipt.source_reference,receipt.cash_account_id,receipt.amount)
           IS DISTINCT FROM (opening.id,source_id,effective_day,settlement_time,external_account,source_participant,source_ref,cash_id,funding) THEN
            RAISE EXCEPTION 'Conflicting opening capital receipt';
        END IF;
        RETURN receipt;
    END IF;
    LOCK TABLE admin.schedule_runs IN SHARE MODE;
    IF EXISTS (SELECT 1 FROM admin.schedule_runs r JOIN admin.schedules s ON r.schedule_id=s.id
               WHERE r.bank_instance_id=bank_id AND r.bank_date>=effective_day
               AND s.definition_name IN ('daily-reconciliation','daily-position','eod-batch','month-end-batch')
               AND (r.status='started' OR (r.status='completed' AND r.terminal_evidence IS NOT NULL))) THEN
        RAISE EXCEPTION 'Affected bank day has active or certified processing';
    END IF;
    PERFORM 1 FROM core.ledger_accounts WHERE id=cash_id AND account_type='nostro'
        AND account_subtype='nostro_bragd' AND currency='NOK' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expected a NOK Bragd nostro'; END IF;
    IF EXISTS (SELECT 1 FROM core.transactions WHERE reference=source_id::text OR end_to_end_id=source_id::text) THEN
        RAISE EXCEPTION 'Source already referenced outside an opening capital receipt';
    END IF;
    SELECT id INTO STRICT equity_id FROM (SELECT COALESCE(
       (SELECT id FROM core.ledger_accounts WHERE account_type='general_ledger' AND account_subtype='paid_in_capital' AND currency='NOK'),
       gen_random_uuid()) AS id) equity;
    INSERT INTO core.ledger_accounts(id,account_type,account_subtype,currency)
        VALUES(equity_id,'general_ledger','paid_in_capital','NOK') ON CONFLICT (id) DO NOTHING;
    booking_time := clock_timestamp();
    INSERT INTO core.transactions(id,reference,description,timestamp,end_to_end_id)
        VALUES(tx_id,source_id::text,source_ref,booking_time,source_id::text);
    INSERT INTO core.postings(id,transaction_id,account_id,amount,currency) VALUES
        (gen_random_uuid(),tx_id,cash_id,funding,'NOK'),
        (gen_random_uuid(),tx_id,equity_id,-funding,'NOK');
    INSERT INTO core.opening_capital_receipts(capital_source_id,transaction_id,opening_id,effective_bank_date,
        external_settled_at,external_account_id,participant,source_reference,cash_account_id,equity_account_id,amount,currency,recorded_at)
        VALUES(source_id,tx_id,opening.id,effective_day,settlement_time,external_account,source_participant,source_ref,
               cash_id,equity_id,funding,'NOK',booking_time) RETURNING * INTO receipt;
    RETURN receipt;
END
$$;
CREATE OR REPLACE VIEW core.opening_capital_legs AS
SELECT p.id AS posting_id, r.effective_bank_date,
       CASE p.account_id WHEN r.cash_account_id THEN 'central_bank_funding'
                         WHEN r.equity_account_id THEN 'paid_in_capital' END AS role
FROM core.opening_capital_receipts r JOIN core.postings p ON p.transaction_id=r.transaction_id;

CREATE OR REPLACE VIEW core.ledger_api_postings AS
SELECT p.id, p.transaction_id, p.account_id, p.amount, p.currency,
       p.economic_role AS interest_role, capital.role AS economic_role
FROM core.typed_postings p LEFT JOIN core.opening_capital_legs capital ON capital.posting_id=p.id;
