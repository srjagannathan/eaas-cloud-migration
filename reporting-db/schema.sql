-- Contoso Financial Reporting Database Schema
-- Managed via this file. Alembic migrations in Phase 2.
-- Target: RDS Postgres 15, multi-AZ, read replica for BI queries.

CREATE TABLE IF NOT EXISTS accounts (
    account_id   TEXT        PRIMARY KEY,
    name         TEXT        NOT NULL,
    account_type TEXT        NOT NULL CHECK (account_type IN ('checking', 'savings', 'investment')),
    balance      NUMERIC(15,2) NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transactions (
    transaction_id   TEXT        PRIMARY KEY,
    account_id       TEXT        NOT NULL REFERENCES accounts(account_id),
    amount           NUMERIC(15,2) NOT NULL,
    description      TEXT,
    transaction_type TEXT        NOT NULL CHECK (transaction_type IN ('debit', 'credit')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transactions_account_id ON transactions(account_id);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC);

-- View used by reporting teams (routes to read replica in cloud)
CREATE OR REPLACE VIEW daily_summary AS
SELECT
    DATE(created_at)          AS txn_date,
    transaction_type,
    COUNT(*)                  AS txn_count,
    SUM(amount)               AS total_amount
FROM transactions
GROUP BY DATE(created_at), transaction_type
ORDER BY txn_date DESC;

-- Grant read-only access for reporting team users
-- In cloud: these are IAM-authenticated RDS users on the read replica endpoint
-- DO NOT grant to the primary connection string
-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO reporting_team;
