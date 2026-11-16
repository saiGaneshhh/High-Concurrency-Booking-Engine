-- BookMyShow-style ticketing schema (MySQL 8.0.16+)
-- Run: mysql -u <user> -p < schema.sql

DROP DATABASE IF EXISTS bookmyshow;
CREATE DATABASE bookmyshow CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE bookmyshow;

-- ---------------------------------------------------------------
-- Master data
-- ---------------------------------------------------------------
CREATE TABLE cities (
  city_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name       VARCHAR(100) NOT NULL,
  state      VARCHAR(100) NOT NULL,
  PRIMARY KEY (city_id),
  UNIQUE KEY uq_city (name, state)
) ENGINE=InnoDB;

CREATE TABLE theatres (
  theatre_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  city_id    INT UNSIGNED NOT NULL,
  name       VARCHAR(150) NOT NULL,
  address    VARCHAR(255) NOT NULL,
  PRIMARY KEY (theatre_id),
  UNIQUE KEY uq_theatre (city_id, name),
  CONSTRAINT fk_theatre_city FOREIGN KEY (city_id) REFERENCES cities (city_id)
) ENGINE=InnoDB;

CREATE TABLE screens (
  screen_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  theatre_id INT UNSIGNED NOT NULL,
  name       VARCHAR(50)  NOT NULL,            -- e.g. 'Audi 1'
  PRIMARY KEY (screen_id),
  UNIQUE KEY uq_screen (theatre_id, name),     -- also serves theatre -> screens lookup
  CONSTRAINT fk_screen_theatre FOREIGN KEY (theatre_id) REFERENCES theatres (theatre_id)
) ENGINE=InnoDB;

CREATE TABLE seat_types (
  seat_type_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name         VARCHAR(30) NOT NULL,           -- SILVER / GOLD / PREMIUM / RECLINER
  PRIMARY KEY (seat_type_id),
  UNIQUE KEY uq_seat_type (name)
) ENGINE=InnoDB;

-- Physical seats of a screen (static layout, never changes per show)
CREATE TABLE seats (
  seat_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
  screen_id    INT UNSIGNED NOT NULL,
  seat_type_id TINYINT UNSIGNED NOT NULL,
  row_label    CHAR(2)  NOT NULL,              -- 'A', 'B', ...
  seat_number  SMALLINT UNSIGNED NOT NULL,
  PRIMARY KEY (seat_id),
  UNIQUE KEY uq_seat_position (screen_id, row_label, seat_number),
  CONSTRAINT fk_seat_screen FOREIGN KEY (screen_id)    REFERENCES screens (screen_id),
  CONSTRAINT fk_seat_type   FOREIGN KEY (seat_type_id) REFERENCES seat_types (seat_type_id)
) ENGINE=InnoDB;

CREATE TABLE languages (
  language_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name        VARCHAR(30) NOT NULL,
  PRIMARY KEY (language_id),
  UNIQUE KEY uq_language (name)
) ENGINE=InnoDB;

CREATE TABLE movies (
  movie_id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  title            VARCHAR(200) NOT NULL,
  duration_minutes SMALLINT UNSIGNED NOT NULL,
  certification    ENUM('U','UA','A','S') NOT NULL,
  release_date     DATE NOT NULL,
  PRIMARY KEY (movie_id),
  UNIQUE KEY uq_movie (title, release_date)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- Shows and pricing
-- ---------------------------------------------------------------
CREATE TABLE shows (
  show_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  movie_id    INT UNSIGNED NOT NULL,
  screen_id   INT UNSIGNED NOT NULL,
  language_id TINYINT UNSIGNED NOT NULL,
  format      ENUM('2D','3D','IMAX','4DX') NOT NULL DEFAULT '2D',
  show_date   DATE NOT NULL,
  start_time  TIME NOT NULL,
  status      ENUM('SCHEDULED','CANCELLED','COMPLETED') NOT NULL DEFAULT 'SCHEDULED',
  PRIMARY KEY (show_id),
  -- a screen cannot start two shows at the same moment
  UNIQUE KEY uq_screen_slot (screen_id, show_date, start_time),
  KEY idx_show_movie (movie_id, show_date),
  CONSTRAINT fk_show_movie    FOREIGN KEY (movie_id)    REFERENCES movies (movie_id),
  CONSTRAINT fk_show_screen   FOREIGN KEY (screen_id)   REFERENCES screens (screen_id),
  CONSTRAINT fk_show_language FOREIGN KEY (language_id) REFERENCES languages (language_id)
) ENGINE=InnoDB;

CREATE TABLE show_prices (
  show_id      BIGINT UNSIGNED  NOT NULL,
  seat_type_id TINYINT UNSIGNED NOT NULL,
  price        DECIMAL(10,2)    NOT NULL CHECK (price >= 0),
  PRIMARY KEY (show_id, seat_type_id),
  CONSTRAINT fk_sp_show FOREIGN KEY (show_id)      REFERENCES shows (show_id),
  CONSTRAINT fk_sp_type FOREIGN KEY (seat_type_id) REFERENCES seat_types (seat_type_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- Users, bookings, payments
-- ---------------------------------------------------------------
CREATE TABLE users (
  user_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name       VARCHAR(120) NOT NULL,
  email      VARCHAR(190) NOT NULL,
  phone      VARCHAR(20)  NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  UNIQUE KEY uq_user_email (email),
  UNIQUE KEY uq_user_phone (phone)
) ENGINE=InnoDB;

CREATE TABLE bookings (
  booking_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  booking_ref     CHAR(10) NOT NULL,                       -- customer-facing code
  user_id         BIGINT UNSIGNED NOT NULL,
  show_id         BIGINT UNSIGNED NOT NULL,
  status          ENUM('PENDING','CONFIRMED','EXPIRED','CANCELLED') NOT NULL DEFAULT 'PENDING',
  total_amount    DECIMAL(10,2) NOT NULL,
  hold_expires_at DATETIME(3) NOT NULL,                    -- PENDING bookings die at this time
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (booking_id),
  UNIQUE KEY uq_booking_ref (booking_ref),
  KEY idx_booking_user (user_id, created_at),
  KEY idx_booking_sweep (status, hold_expires_at),
  CONSTRAINT fk_booking_user FOREIGN KEY (user_id) REFERENCES users (user_id),
  CONSTRAINT fk_booking_show FOREIGN KEY (show_id) REFERENCES shows (show_id)
) ENGINE=InnoDB;

-- Per-show seat inventory. THE concurrency hot spot: one row per (show, seat).
-- The row is the lock unit; UNIQUE(show_id, seat_id) makes duplicates impossible.
CREATE TABLE show_seats (
  show_seat_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  show_id         BIGINT UNSIGNED NOT NULL,
  seat_id         INT UNSIGNED NOT NULL,
  status          ENUM('AVAILABLE','HELD','BOOKED') NOT NULL DEFAULT 'AVAILABLE',
  booking_id      BIGINT UNSIGNED NULL,
  hold_expires_at DATETIME(3) NULL,
  version         INT UNSIGNED NOT NULL DEFAULT 0,         -- optimistic-lock counter / audit
  PRIMARY KEY (show_seat_id),
  UNIQUE KEY uq_show_seat (show_id, seat_id),
  KEY idx_show_status (show_id, status),                   -- seat-map + availability counts
  KEY idx_hold_sweep (status, hold_expires_at),            -- expired-hold sweeper
  KEY idx_ss_booking (booking_id),
  CONSTRAINT fk_ss_show    FOREIGN KEY (show_id)    REFERENCES shows (show_id),
  CONSTRAINT fk_ss_seat    FOREIGN KEY (seat_id)    REFERENCES seats (seat_id),
  CONSTRAINT fk_ss_booking FOREIGN KEY (booking_id) REFERENCES bookings (booking_id),
  -- state-machine integrity enforced by the DB itself
  CONSTRAINT chk_ss_state CHECK (
       (status = 'AVAILABLE' AND booking_id IS NULL     AND hold_expires_at IS NULL)
    OR (status = 'HELD'      AND booking_id IS NOT NULL AND hold_expires_at IS NOT NULL)
    OR (status = 'BOOKED'    AND booking_id IS NOT NULL AND hold_expires_at IS NULL)
  )
) ENGINE=InnoDB;

CREATE TABLE payments (
  payment_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  booking_id     BIGINT UNSIGNED NOT NULL,
  gateway        VARCHAR(30) NOT NULL,                     -- 'razorpay', 'stripe', ...
  gateway_txn_id VARCHAR(100) NOT NULL,
  amount         DECIMAL(10,2) NOT NULL,
  status         ENUM('INITIATED','SUCCESS','FAILED','REFUNDED') NOT NULL DEFAULT 'INITIATED',
  created_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (payment_id),
  UNIQUE KEY uq_gateway_txn (gateway, gateway_txn_id),
  KEY idx_payment_booking (booking_id),
  CONSTRAINT fk_payment_booking FOREIGN KEY (booking_id) REFERENCES bookings (booking_id)
) ENGINE=InnoDB;

-- Idempotency ledger: a webhook delivered N times is processed exactly once.
CREATE TABLE payment_webhook_events (
  event_pk        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  gateway         VARCHAR(30)  NOT NULL,
  gateway_event_id VARCHAR(100) NOT NULL,                  -- the gateway's unique event id
  event_type      VARCHAR(60)  NOT NULL,                   -- 'payment.captured', ...
  payload         JSON NOT NULL,
  received_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  processed_at    DATETIME(3) NULL,
  PRIMARY KEY (event_pk),
  UNIQUE KEY uq_gateway_event (gateway, gateway_event_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- Sample data
-- ---------------------------------------------------------------
INSERT INTO cities (name, state) VALUES ('Vijayawada', 'Andhra Pradesh'), ('Hyderabad', 'Telangana');

INSERT INTO theatres (city_id, name, address) VALUES
  (1, 'PVR Trendset Mall', 'MG Road, Vijayawada'),
  (1, 'INOX Benz Circle',  'Benz Circle, Vijayawada');

INSERT INTO screens (theatre_id, name) VALUES (1, 'Audi 1'), (1, 'Audi 2'), (2, 'Audi 1');

INSERT INTO seat_types (name) VALUES ('SILVER'), ('GOLD'), ('RECLINER');

-- Audi 1 (screen 1): rows A-B silver, row C gold, row D recliner; 5 seats per row
INSERT INTO seats (screen_id, seat_type_id, row_label, seat_number) VALUES
  (1,1,'A',1),(1,1,'A',2),(1,1,'A',3),(1,1,'A',4),(1,1,'A',5),
  (1,1,'B',1),(1,1,'B',2),(1,1,'B',3),(1,1,'B',4),(1,1,'B',5),
  (1,2,'C',1),(1,2,'C',2),(1,2,'C',3),(1,2,'C',4),(1,2,'C',5),
  (1,3,'D',1),(1,3,'D',2),(1,3,'D',3),(1,3,'D',4),(1,3,'D',5);
-- Audi 2 (screen 2): single gold row
INSERT INTO seats (screen_id, seat_type_id, row_label, seat_number) VALUES
  (2,2,'A',1),(2,2,'A',2),(2,2,'A',3),(2,2,'A',4),(2,2,'A',5);

INSERT INTO languages (name) VALUES ('Telugu'), ('Hindi'), ('English');

INSERT INTO movies (title, duration_minutes, certification, release_date) VALUES
  ('Pushpa 2: The Rule', 200, 'UA', '2024-12-05'),
  ('Interstellar (Re-release)', 169, 'UA', '2025-02-07'),
  ('Kalki 2898 AD', 181, 'UA', '2024-06-27');

-- Shows for the next 3 days at PVR Trendset (screens 1 & 2)
INSERT INTO shows (movie_id, screen_id, language_id, format, show_date, start_time) VALUES
  (1,1,1,'2D',  CURDATE(),                        '10:00:00'),
  (1,1,1,'2D',  CURDATE(),                        '14:30:00'),
  (1,1,1,'2D',  CURDATE(),                        '19:15:00'),
  (2,2,3,'IMAX',CURDATE(),                        '11:00:00'),
  (2,2,3,'IMAX',CURDATE(),                        '18:45:00'),
  (3,2,1,'3D',  CURDATE(),                        '22:00:00'),
  (1,1,1,'2D',  DATE_ADD(CURDATE(), INTERVAL 1 DAY), '10:00:00'),
  (2,2,3,'IMAX',DATE_ADD(CURDATE(), INTERVAL 1 DAY), '15:00:00');

-- Per-show prices
INSERT INTO show_prices (show_id, seat_type_id, price)
SELECT s.show_id, st.seat_type_id,
       CASE st.name WHEN 'SILVER' THEN 150 WHEN 'GOLD' THEN 250 ELSE 450 END
FROM shows s CROSS JOIN seat_types st;

-- Generate the per-show seat inventory (all AVAILABLE) from each screen's layout
INSERT INTO show_seats (show_id, seat_id)
SELECT sh.show_id, se.seat_id
FROM shows sh JOIN seats se ON se.screen_id = sh.screen_id;

INSERT INTO users (name, email, phone) VALUES
  ('Ravi Kumar',  'ravi@example.com',  '+919800000001'),
  ('Sneha Reddy', 'sneha@example.com', '+919800000002');

-- Sample confirmed booking: Ravi, show 1, seats A1 + A2 (2 x 150)
INSERT INTO bookings (booking_ref, user_id, show_id, status, total_amount, hold_expires_at)
VALUES ('BMS7K2P9QX', 1, 1, 'CONFIRMED', 300.00, NOW(3));

UPDATE show_seats ss
JOIN seats se ON se.seat_id = ss.seat_id
SET ss.status = 'BOOKED', ss.booking_id = 1, ss.version = ss.version + 1
WHERE ss.show_id = 1 AND se.row_label = 'A' AND se.seat_number IN (1, 2);

-- Sample in-flight booking: Sneha holds C1 for 5 minutes on show 1
INSERT INTO bookings (booking_ref, user_id, show_id, status, total_amount, hold_expires_at)
VALUES ('BMS3H8D1ZA', 2, 1, 'PENDING', 250.00, NOW(3) + INTERVAL 5 MINUTE);

UPDATE show_seats ss
JOIN seats se ON se.seat_id = ss.seat_id
SET ss.status = 'HELD', ss.booking_id = 2,
    ss.hold_expires_at = NOW(3) + INTERVAL 5 MINUTE, ss.version = ss.version + 1
WHERE ss.show_id = 1 AND se.row_label = 'C' AND se.seat_number = 1;

INSERT INTO payments (booking_id, gateway, gateway_txn_id, amount, status)
VALUES (1, 'razorpay', 'pay_Nx81kD02aQ', 300.00, 'SUCCESS'),
       (2, 'razorpay', 'pay_Nx93pL77bT', 250.00, 'INITIATED');

INSERT INTO payment_webhook_events (gateway, gateway_event_id, event_type, payload, processed_at)
VALUES ('razorpay', 'evt_Nx81kD02zz', 'payment.captured',
        JSON_OBJECT('payment_id','pay_Nx81kD02aQ','amount',30000,'status','captured'), NOW(3));
