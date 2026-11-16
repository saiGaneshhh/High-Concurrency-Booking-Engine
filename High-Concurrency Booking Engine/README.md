# BookMyShow-scale Ticketing Backend: Schema & Locking Design

Files: `schema.sql` (DDL + sample data, MySQL 8.0.16+), `queries.sql` (P2 + concurrency flows).

## 1. Entities and tables

| Table | Purpose | Key attributes |
|---|---|---|
| `cities` | Cities served | **city_id** PK, name, state |
| `theatres` | A cinema in a city | **theatre_id** PK, city_id FK, name, address |
| `screens` | An auditorium in a theatre | **screen_id** PK, theatre_id FK, name |
| `seat_types` | Pricing tier | **seat_type_id** PK, name |
| `seats` | Physical seat layout of a screen | **seat_id** PK, screen_id FK, seat_type_id FK, row_label, seat_number |
| `languages` | Lookup | **language_id** PK, name |
| `movies` | Movie catalogue | **movie_id** PK, title, duration_minutes, certification, release_date |
| `shows` | A movie screened on a screen at a date/time | **show_id** PK, movie_id, screen_id, language_id, format, show_date, start_time, status |
| `show_prices` | Price of a seat tier for a show | **(show_id, seat_type_id)** PK, price |
| `users` | Customers | **user_id** PK, name, email, phone |
| `bookings` | A user's purchase attempt | **booking_id** PK, booking_ref, user_id, show_id, status, total_amount, hold_expires_at |
| `show_seats` | Per-show seat inventory and lock unit | **show_seat_id** PK, show_id, seat_id, status, booking_id, hold_expires_at, version |
| `payments` | Gateway payment attempts | **payment_id** PK, booking_id, gateway, gateway_txn_id, amount, status |
| `payment_webhook_events` | Idempotency ledger | **event_pk** PK, gateway, gateway_event_id, event_type, payload, processed_at |

Relationships: city 1-N theatre 1-N screen 1-N seat; movie 1-N show N-1 screen; show 1-N show_seat N-1 seat; booking 1-N show_seat (via `booking_id`); booking 1-N payment.

## 2. Sample rows

**cities**: (1, Vijayawada, Andhra Pradesh), (2, Hyderabad, Telangana)

**theatres**: (1, city 1, PVR Trendset Mall, MG Road), (2, city 1, INOX Benz Circle, Benz Circle)

**screens**: (1, theatre 1, Audi 1), (2, theatre 1, Audi 2), (3, theatre 2, Audi 1)

**seats**: (1, screen 1, SILVER, A, 1), (2, screen 1, SILVER, A, 2), (11, screen 1, GOLD, C, 1), (16, screen 1, RECLINER, D, 1)

**movies**: (1, Pushpa 2: The Rule, 200 min, UA), (2, Interstellar (Re-release), 169 min, UA)

**shows**: (1, movie 1, screen 1, Telugu, 2D, today, 10:00), (2, movie 1, screen 1, Telugu, 2D, today, 14:30), (4, movie 2, screen 2, English, IMAX, today, 11:00)

**show_prices**: (show 1, SILVER, 150), (show 1, GOLD, 250), (show 1, RECLINER, 450)

**show_seats**:

| show_seat_id | show_id | seat_id | status | booking_id | hold_expires_at | version |
|---|---|---|---|---|---|---|
| 1 | 1 | 1 (A1) | BOOKED | 1 | NULL | 1 |
| 2 | 1 | 2 (A2) | BOOKED | 1 | NULL | 1 |
| 11 | 1 | 11 (C1) | HELD | 2 | now + 5 min | 1 |
| 12 | 1 | 12 (C2) | AVAILABLE | NULL | NULL | 0 |

**bookings**: (1, BMS7K2P9QX, user 1, show 1, CONFIRMED, 300.00), (2, BMS3H8D1ZA, user 2, show 1, PENDING, 250.00, hold_expires_at = now + 5 min)

**payments**: (1, booking 1, razorpay, pay_Nx81kD02aQ, 300.00, SUCCESS), (2, booking 2, razorpay, pay_Nx93pL77bT, 250.00, INITIATED)

**payment_webhook_events**: (1, razorpay, evt_Nx81kD02zz, payment.captured, processed_at set)

## 3. Normalization

- **1NF**: every column is atomic and every table has a primary key. Multi-timing lists are produced at query time (`GROUP_CONCAT`), never stored. The webhook `payload` JSON is an opaque audit blob, not queried relationally.
- **2NF**: tables with composite keys have no partial dependencies. `show_prices (show_id, seat_type_id) -> price` depends on the whole key. Everything else uses a single-column surrogate key.
- **3NF**: no transitive dependencies. Theatre details are not copied into `shows` (`show -> screen -> theatre -> city`). A seat's tier lives in `seats`, not `show_seats`. Language, seat type and city are lookups. The seat's price is derived through `show_prices`, not stored per seat.
- **BCNF**: every non-trivial determinant is a candidate key. The extra candidate keys are declared as UNIQUE constraints and are the only other determinants: `seats(screen_id, row_label, seat_number)`, `shows(screen_id, show_date, start_time)`, `show_seats(show_id, seat_id)`, `bookings(booking_ref)`, `payments(gateway, gateway_txn_id)`, `payment_webhook_events(gateway, gateway_event_id)`.
- Deliberate, controlled redundancy: `bookings.hold_expires_at` and `show_seats.hold_expires_at` (the booking deadline vs. the seat lock deadline), and `bookings.total_amount` (a price snapshot so later price edits don't change history). These are write-once snapshots, not update anomalies.

## 4. Concurrency and locking strategy

**Unit of locking = one `show_seats` row.** Rows are created up front (one per seat per show), so locking never depends on "does a row exist yet" and `UNIQUE(show_id, seat_id)` makes duplicate inventory impossible.

1. **Hold (no double booking).** One conditional `UPDATE ... WHERE status='AVAILABLE' OR (status='HELD' AND hold_expires_at <= NOW(3))` over the requested seats, in ascending seat order. InnoDB row-locks each candidate and re-checks the predicate against the latest committed row. If two users race, one gets `ROW_COUNT() = n` and the other gets fewer, so the loser rolls back. This is all-or-nothing (no partial holds) and deadlock-safe (consistent lock order).
2. **Timed holds.** The deadline is stored in the row (`hold_expires_at`) and compared with the database clock. Expiry is therefore correct even if the sweeper is late, because the hold query treats expired holds as free. A sweeper (cron/MySQL EVENT every 10-30 s, batched with `LIMIT`) just tidies status and marks bookings `EXPIRED`. **Redis layer** (production hot path): `SET seat:{show}:{seat} {booking} NX EX 300` is used as a fast gate to reject obviously contended seats and absorb bursts before touching MySQL. MySQL remains the source of truth, so losing Redis never causes a double booking (the worst case is a few extra rejected DB attempts).
3. **No lost holds.** On confirm, `UPDATE ... WHERE booking_id=? AND status='HELD' AND hold_expires_at > NOW(3)` must affect exactly the booked seat count. If payment arrives after expiry, the confirm fails and the payment is refunded instead of silently overwriting someone else's hold.
4. **Idempotent webhooks.** `INSERT IGNORE` into `payment_webhook_events` keyed by the gateway's event id. If 0 rows are inserted, it is a duplicate delivery and the handler returns 200 and stops. The claim and the confirm run in one transaction, so a crash rolls back both and the gateway's retry is processed cleanly. `payments (gateway, gateway_txn_id)` is also unique.
5. **Pessimistic vs optimistic.** Pessimistic (`SELECT ... FOR UPDATE SKIP LOCKED`) suits hot shows: high contention makes optimistic retries wasteful. The `version` column supports optimistic updates for low-contention paths such as admin edits, and doubles as an audit counter. The default path is the single atomic UPDATE, which gets pessimistic safety with one round trip.
6. **State integrity in the DB.** The `chk_ss_state` CHECK constraint forbids impossible rows (e.g. `BOOKED` with no booking, `AVAILABLE` with a leftover hold timer).
7. **Isolation.** Use `READ COMMITTED` for these transactions to reduce gap locking; the unique and primary keys make that safe.
8. **Burst handling (Redis/queue).** For opening-day spikes, place requests for a hot show into a per-show queue (e.g. a Redis stream or SQS FIFO keyed by `show_id`) so one worker serialises seat attempts per show and DB lock waits stay short.

## 5. Indexes (query paths)

| Index | Serves |
|---|---|
| `screens uq_screen (theatre_id, name)` | theatre to screens |
| `shows uq_screen_slot (screen_id, show_date, start_time)` | **P2**: range seek per screen, already time-ordered |
| `show_seats uq_show_seat (show_id, seat_id)` | hold/confirm row lookup, duplicate prevention |
| `show_seats idx_show_status (show_id, status)` | seat map, availability counts |
| `show_seats idx_hold_sweep (status, hold_expires_at)` | expired-hold sweeper |
| `bookings idx_booking_sweep (status, hold_expires_at)` | booking expiry |
| `payments uq_gateway_txn`, `payment_webhook_events uq_gateway_event` | idempotency |

## 6. P2 query

See `queries.sql` (listing, UI-grouped, availability and 7-day date-picker variants). Core query:

```sql
SELECT m.title, l.name AS language, sh.format, sh.show_id,
       TIME_FORMAT(sh.start_time, '%h:%i %p') AS show_time, scr.name AS screen
FROM   screens scr
JOIN   shows sh     ON sh.screen_id  = scr.screen_id
JOIN   movies m     ON m.movie_id    = sh.movie_id
JOIN   languages l  ON l.language_id = sh.language_id
WHERE  scr.theatre_id = @theatre_id AND sh.show_date = @show_date AND sh.status = 'SCHEDULED'
ORDER BY m.title, l.name, sh.format, sh.start_time;
```

## 7. Load test (to add in the PR)

Suggested k6 or Python script: 5,000 virtual users contend for 50 seats of one show. Assertions: `COUNT(*) = number of BOOKED seats` and no `show_seats` row ever has two bookings; replay each webhook 3x and verify a single confirmation; let holds expire and verify seats return to the pool.
