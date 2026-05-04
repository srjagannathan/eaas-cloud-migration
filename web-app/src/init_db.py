"""Run once at startup to create tables and seed demo data."""
import os
import psycopg2

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://contoso:contoso@localhost:5432/contoso")


def init():
    conn = psycopg2.connect(DATABASE_URL)
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                account_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                account_type TEXT NOT NULL,
                balance NUMERIC(15,2) DEFAULT 0,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS transactions (
                transaction_id TEXT PRIMARY KEY,
                account_id TEXT REFERENCES accounts(account_id),
                amount NUMERIC(15,2) NOT NULL,
                description TEXT,
                transaction_type TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
        """)
        cur.execute("SELECT COUNT(*) FROM accounts")
        if cur.fetchone()[0] == 0:
            cur.execute("""
                INSERT INTO accounts (account_id, name, account_type, balance) VALUES
                ('ACC-001', 'Contoso Operations', 'checking', 1250000.00),
                ('ACC-002', 'Contoso Payroll', 'checking', 890000.00),
                ('ACC-003', 'Contoso Reserves', 'savings', 5000000.00)
            """)
    conn.commit()
    conn.close()


if __name__ == "__main__":
    init()
    print("Database initialized.")
