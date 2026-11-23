-- Operator-attested effective date for a previously missing central-bank link.
-- The source is captured separately from the update time on funding_accounts.
CREATE TABLE IF NOT EXISTS treasury.funding_link_corrections (
    funding_account_id uuid NOT NULL REFERENCES treasury.funding_accounts(id),
    link_version timestamptz NOT NULL,
    effective_from date NOT NULL,
    ledger_account_id uuid NOT NULL,
    currency varchar(3) NOT NULL,
    source_transaction_id uuid NOT NULL UNIQUE,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    recorded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (funding_account_id, link_version)
);
CREATE OR REPLACE FUNCTION treasury.protect_funding_link_correction() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'funding link correction receipts are immutable';
END $$;
CREATE OR REPLACE TRIGGER protect_funding_link_correction
BEFORE UPDATE OR DELETE ON treasury.funding_link_corrections
FOR EACH ROW EXECUTE FUNCTION treasury.protect_funding_link_correction();
