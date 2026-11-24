-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL

DROP SCHEMA IF EXISTS q2_fees CASCADE;
CREATE SCHEMA q2_fees;
SET search_path = q2_fees, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202406171', 'Clement Mwitwa', 5000.00),
    ('202406172', 'Mary Banda',     3000.00),
    ('202406173', 'Peter Phiri',    4000.00);   -- student 3 starts with no payments

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- COALESCE makes a student with no payments owe the full fee.
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_fee - v_paid;
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'paid_on must not be NULL';
    END IF;

    -- Lock the student row so two simultaneous payments cannot together exceed the balance.
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    -- fee_due is never changed; the audit row is written by the trigger, not here.
    INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

/* ---- (a) continued: six payments through the procedure (student 3 has none) ---- */
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 2000, CURRENT_DATE - 1);   -- Mary is now fully settled

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;   -- 6 rows, written only by the trigger
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;  -- 1500, 0, 4000

-- Rejection tests
DO $$ BEGIN PERFORM fn_fee_balance(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, -50, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 4000.01, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT * FROM students ORDER BY student_id;      -- fee_due unchanged

/* ===================== (e) View ===================== */
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;   -- settled students are excluded

SELECT * FROM v_fee_balances ORDER BY student_number;   -- Mary (fully paid) is absent

/* ===================== (f) Index ===================== */
-- Justification: queries filter by ONE student (equality) and a paid_on RANGE.
-- Equality column first, range column second lets the B-tree narrow to one student's
-- payments and then read only the requested dates, already sorted.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE      -- rerun replaces the existing summary row
        SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every day at 01:00 (pg_cron time zone), summarise the previous day.
SELECT cron.schedule('q2_refresh_collections_daily', '0 1 * * *',
                     $$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$$);

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun: still one row
SELECT * FROM daily_collections;                 -- expected: count 4, total 4000.00
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q2_refresh_collections_daily';
