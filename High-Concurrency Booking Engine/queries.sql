USE bookmyshow;

-- ===============================================================
-- P2: all shows on a given date at a given theatre, with timings
-- (movie-wise listing as in the BookMyShow UI)
-- ===============================================================
SET @theatre_id = 1;
SET @show_date  = CURDATE();

SELECT m.movie_id,
       m.title,
       m.certification,
       l.name                          AS language,
       sh.format,
       sh.show_id,
       TIME_FORMAT(sh.start_time, '%h:%i %p') AS show_time,
       scr.name                        AS screen
FROM   screens scr
JOIN   shows     sh ON sh.screen_id   = scr.screen_id
JOIN   movies    m  ON m.movie_id     = sh.movie_id
JOIN   languages l  ON l.language_id  = sh.language_id
WHERE  scr.theatre_id = @theatre_id
  AND  sh.show_date   = @show_date
  AND  sh.status      = 'SCHEDULED'
ORDER BY m.title, l.name, sh.format, sh.start_time;

-- Index usage: uq_screen (theatre_id, name) finds the theatre's few screens, then
-- uq_screen_slot (screen_id, show_date, start_time) is a range seek per screen,
-- already in start_time order.

-- UI-shaped variant: one row per movie with all timings in a single cell
SELECT m.title, l.name AS language, sh.format,
       GROUP_CONCAT(TIME_FORMAT(sh.start_time, '%h:%i %p') ORDER BY sh.start_time SEPARATOR ' | ') AS show_times
FROM   screens scr
JOIN   shows sh     ON sh.screen_id  = scr.screen_id
JOIN   movies m     ON m.movie_id    = sh.movie_id
JOIN   languages l  ON l.language_id = sh.language_id
WHERE  scr.theatre_id = @theatre_id AND sh.show_date = @show_date AND sh.status = 'SCHEDULED'
GROUP BY m.movie_id, m.title, l.name, sh.format
ORDER BY m.title;

-- Variant with live availability (fast: uses idx_show_status)
SELECT sh.show_id, m.title, TIME_FORMAT(sh.start_time, '%h:%i %p') AS show_time,
       SUM(ss.status = 'AVAILABLE'
           OR (ss.status = 'HELD' AND ss.hold_expires_at <= NOW(3))) AS seats_left
FROM   screens scr
JOIN   shows sh      ON sh.screen_id = scr.screen_id
JOIN   movies m      ON m.movie_id   = sh.movie_id
JOIN   show_seats ss ON ss.show_id   = sh.show_id
WHERE  scr.theatre_id = @theatre_id AND sh.show_date = @show_date AND sh.status = 'SCHEDULED'
GROUP BY sh.show_id, m.title, sh.start_time
ORDER BY m.title, sh.start_time;

-- The 7-day date picker (MySQL 8 recursive CTE)
WITH RECURSIVE d (day_offset, picker_date) AS (
  SELECT 0, CURDATE()
  UNION ALL
  SELECT day_offset + 1, DATE_ADD(picker_date, INTERVAL 1 DAY) FROM d WHERE day_offset < 6
)
SELECT picker_date, DATE_FORMAT(picker_date, '%a %d %b') AS label FROM d;


-- ===============================================================
-- Concurrency: seat hold -> confirm -> expire -> webhook
-- (app issues these inside transactions; shown here as templates)
-- ===============================================================

-- ---- 1. HOLD seats (isolation: READ COMMITTED recommended) ------
-- Parameters: @show_id, seat ids (sorted ASC to avoid deadlocks), @user_id, @n (seat count)
START TRANSACTION;

INSERT INTO bookings (booking_ref, user_id, show_id, status, total_amount, hold_expires_at)
VALUES (@ref, @user_id, @show_id, 'PENDING', @total, NOW(3) + INTERVAL 5 MINUTE);
SET @booking_id = LAST_INSERT_ID();

-- ONE atomic conditional UPDATE. InnoDB takes row locks, re-evaluates the WHERE on the
-- latest committed row, so two users racing for the same seat: exactly one matches.
-- Expired holds are taken over in the same statement (no sweeper race).
UPDATE show_seats
SET    status = 'HELD',
       booking_id = @booking_id,
       hold_expires_at = NOW(3) + INTERVAL 5 MINUTE,
       version = version + 1
WHERE  show_id = @show_id
  AND  seat_id IN (101, 102, 103)           -- sorted ascending
  AND (status = 'AVAILABLE'
       OR (status = 'HELD' AND hold_expires_at <= NOW(3)));

-- App: if ROW_COUNT() <> @n  -> ROLLBACK (someone else got a seat) else COMMIT.
-- All-or-nothing: partial holds can never leak.
COMMIT;

-- ---- 2. CONFIRM (called from payment-success webhook) -----------
START TRANSACTION;

UPDATE show_seats
SET    status = 'BOOKED', hold_expires_at = NULL, version = version + 1
WHERE  booking_id = @booking_id
  AND  status = 'HELD'
  AND  hold_expires_at > NOW(3);            -- hold must still be ours and alive

-- App: ROW_COUNT() = seat count  -> continue; else ROLLBACK and trigger refund
--      (payment arrived after the hold expired / seat re-held by someone else).
UPDATE bookings SET status = 'CONFIRMED'
WHERE  booking_id = @booking_id AND status = 'PENDING';

UPDATE payments SET status = 'SUCCESS'
WHERE  gateway = @gateway AND gateway_txn_id = @txn_id;
COMMIT;

-- ---- 3. EXPIRE holds (cron every 10-30s; also an optional MySQL EVENT) ----
START TRANSACTION;
UPDATE show_seats
SET    status = 'AVAILABLE', booking_id = NULL, hold_expires_at = NULL, version = version + 1
WHERE  status = 'HELD' AND hold_expires_at <= NOW(3)
LIMIT  1000;                                 -- batch to keep locks short
UPDATE bookings SET status = 'EXPIRED'
WHERE  status = 'PENDING' AND hold_expires_at <= NOW(3)
LIMIT  1000;
COMMIT;
-- Correctness never depends on this job: the HOLD query already treats expired holds as free.

-- ---- 4. IDEMPOTENT webhook ingestion ----------------------------
-- Step A: claim the event. Duplicate deliveries hit uq_gateway_event and insert 0 rows.
INSERT IGNORE INTO payment_webhook_events (gateway, gateway_event_id, event_type, payload)
VALUES (@gateway, @event_id, @event_type, @payload_json);
-- App: if ROW_COUNT() = 0 -> already seen -> return HTTP 200 immediately, do nothing.
-- Step B (same transaction as the confirm in section 2):
UPDATE payment_webhook_events SET processed_at = NOW(3)
WHERE  gateway = @gateway AND gateway_event_id = @event_id;
-- If processing crashes, the transaction rolls back including Step A, so the gateway's
-- retry is processed normally.

-- ---- 5. Optimistic variant (alternative for low-contention flows) --
-- UPDATE show_seats SET status='HELD', ..., version = version + 1
-- WHERE show_seat_id = @id AND version = @version_read_earlier;   -- 0 rows => retry/abort

-- ---- 6. Pessimistic variant (explicit lock) ---------------------
-- START TRANSACTION;
-- SELECT show_seat_id, status, hold_expires_at FROM show_seats
--  WHERE show_id = @show_id AND seat_id IN (101,102,103)
--  ORDER BY seat_id FOR UPDATE SKIP LOCKED;   -- fewer rows than requested => contention
