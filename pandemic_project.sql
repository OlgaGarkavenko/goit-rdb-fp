-- =====================================================================
-- Фінальний проєкт: датасет infectious_cases (PostgreSQL 15+)
-- Запуск з кореня репозиторію:  psql -d <db> -f sql/pandemic_project.sql
-- =====================================================================



-- Завдання 1. Завантаження даних

-- Створення схеми pandemic і вибір її за замовчуванням
CREATE SCHEMA IF NOT EXISTS pandemic;
SET search_path TO pandemic;
SHOW search_path;

-- Таблиця infectious_cases для імпорту
DROP TABLE IF EXISTS infectious_cases_normalized;
DROP TABLE IF EXISTS entities;
DROP TABLE IF EXISTS infectious_cases;

-- Сирі дані імпортуються «як є»: усі колонки TEXT, бо в CSV
-- відсутні значення записані порожніми рядками. Типізація - на етапі нормалізації.
CREATE TABLE infectious_cases (
    entity                TEXT,
    code                  TEXT,
    year                  TEXT,
    number_yaws           TEXT,
    polio_cases           TEXT,
    cases_guinea_worm     TEXT,
    number_rabies         TEXT,
    number_malaria        TEXT,
    number_hiv            TEXT,
    number_tuberculosis   TEXT,
    number_smallpox       TEXT,
    number_cholera_cases  TEXT
);

-- Імпорт CSV (client-side, через psql)
\copy pandemic.infectious_cases FROM 'data/infectious_cases.csv' WITH (FORMAT csv, HEADER true);

-- Перегляд імпортованих даних
SELECT *
FROM infectious_cases
LIMIT 10;

-- Загальна структура датасету
SELECT
    COUNT(*)                                   AS n_rows,
    COUNT(DISTINCT entity)                     AS n_entities,
    COUNT(DISTINCT (entity, code))             AS n_entity_code_pairs,
    COUNT(*) FILTER (WHERE code IS NULL OR TRIM(code) = '') AS rows_without_code,
    MIN(year::INTEGER)                         AS min_year,
    MAX(year::INTEGER)                         AS max_year
FROM infectious_cases;

-- Кількість заповнених значень по кожній хворобі
SELECT
    COUNT(NULLIF(TRIM(number_yaws), '')) AS number_yaws,
    COUNT(NULLIF(TRIM(polio_cases), '')) AS polio_cases,
    COUNT(NULLIF(TRIM(cases_guinea_worm), '')) AS cases_guinea_worm,
    COUNT(NULLIF(TRIM(number_rabies), '')) AS number_rabies,
    COUNT(NULLIF(TRIM(number_malaria), '')) AS number_malaria,
    COUNT(NULLIF(TRIM(number_hiv), '')) AS number_hiv,
    COUNT(NULLIF(TRIM(number_tuberculosis), '')) AS number_tuberculosis,
    COUNT(NULLIF(TRIM(number_smallpox), '')) AS number_smallpox,
    COUNT(NULLIF(TRIM(number_cholera_cases), '')) AS number_cholera_cases
FROM infectious_cases;



-- Завдання 2. Нормалізація до 3НФ

-- Допоміжна функція try_numeric
-- Допоміжна функція: безпечне перетворення тексту на NUMERIC.
-- Порожні або нечислові значення -> NULL (а не помилка або 0).
CREATE OR REPLACE FUNCTION try_numeric(p_value TEXT)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_value ~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$' THEN TRIM(p_value)::NUMERIC
    END
$$;

-- Таблиця entities (унікальні Entity + Code)
DROP TABLE IF EXISTS infectious_cases_normalized;
DROP TABLE IF EXISTS entities;

-- Довідник унікальних комбінацій Entity + Code
CREATE TABLE entities (
    id      SERIAL PRIMARY KEY,
    entity  TEXT NOT NULL,
    code    TEXT,
    CONSTRAINT uq_entities_entity_code UNIQUE NULLS NOT DISTINCT (entity, code)
);

INSERT INTO entities (entity, code)
SELECT DISTINCT
    TRIM(entity),
    NULLIF(TRIM(code), '')
FROM infectious_cases
ORDER BY 1, 2;

SELECT *
FROM entities
ORDER BY id
LIMIT 10;

-- Таблиця infectious_cases_normalized
-- Таблиця показників: замість Entity/Code - зовнішній ключ entity_id
CREATE TABLE infectious_cases_normalized (
    id                    SERIAL PRIMARY KEY,
    entity_id             INTEGER NOT NULL REFERENCES entities (id),
    year                  INTEGER NOT NULL,
    number_yaws           NUMERIC,
    polio_cases           NUMERIC,
    cases_guinea_worm     NUMERIC,
    number_rabies         NUMERIC,
    number_malaria        NUMERIC,
    number_hiv            NUMERIC,
    number_tuberculosis   NUMERIC,
    number_smallpox       NUMERIC,
    number_cholera_cases  NUMERIC,
    CONSTRAINT uq_cases_entity_year UNIQUE (entity_id, year)
);

INSERT INTO infectious_cases_normalized (
    entity_id, year,
    number_yaws, polio_cases, cases_guinea_worm, number_rabies, number_malaria,
    number_hiv, number_tuberculosis, number_smallpox, number_cholera_cases
)
SELECT
    e.id,
    ic.year::INTEGER,
    try_numeric(ic.number_yaws),
    try_numeric(ic.polio_cases),
    try_numeric(ic.cases_guinea_worm),
    try_numeric(ic.number_rabies),
    try_numeric(ic.number_malaria),
    try_numeric(ic.number_hiv),
    try_numeric(ic.number_tuberculosis),
    try_numeric(ic.number_smallpox),
    try_numeric(ic.number_cholera_cases)
FROM infectious_cases AS ic
JOIN entities AS e
  ON e.entity = TRIM(ic.entity)
 AND e.code IS NOT DISTINCT FROM NULLIF(TRIM(ic.code), '')
ORDER BY e.id, ic.year::INTEGER;

SELECT *
FROM infectious_cases_normalized
ORDER BY id
LIMIT 10;

-- Структура нормалізованих таблиць
SELECT
    table_name,
    ordinal_position AS pos,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'pandemic'
  AND table_name IN ('entities', 'infectious_cases_normalized')
ORDER BY table_name, ordinal_position;

-- Перевірка нормалізації без втрат
-- Перевірка без втрат: кількість рядків збігається,
-- а JOIN нормалізованих таблиць відтворює оригінал (EXCEPT = 0 рядків)
SELECT
    (SELECT COUNT(*) FROM infectious_cases)            AS raw_rows,
    (SELECT COUNT(*) FROM infectious_cases_normalized) AS normalized_rows,
    (SELECT COUNT(*) FROM entities)                    AS entity_rows,
    (
        SELECT COUNT(*) FROM (
            SELECT TRIM(entity), NULLIF(TRIM(code), ''), year::INTEGER,
                   try_numeric(number_rabies), try_numeric(number_malaria)
            FROM infectious_cases
            EXCEPT
            SELECT e.entity, e.code, n.year, n.number_rabies, n.number_malaria
            FROM infectious_cases_normalized AS n
            JOIN entities AS e ON e.id = n.entity_id
        ) AS diff
    ) AS rows_lost_or_changed;



-- Завдання 3. Аналіз Number_rabies

-- AVG / MIN / MAX / SUM для Number_rabies, топ-10
SELECT
    e.id                              AS entity_id,
    e.entity,
    e.code,
    ROUND(AVG(n.number_rabies), 4)    AS avg_rabies,
    MIN(n.number_rabies)              AS min_rabies,
    MAX(n.number_rabies)              AS max_rabies,
    ROUND(SUM(n.number_rabies), 4)    AS sum_rabies
FROM infectious_cases_normalized AS n
JOIN entities AS e
  ON e.id = n.entity_id
WHERE n.number_rabies IS NOT NULL
GROUP BY e.id, e.entity, e.code
ORDER BY AVG(n.number_rabies) DESC
LIMIT 10;



-- Завдання 4. Колонка різниці в роках

-- Колонка різниці в роках (вбудовані функції)
SELECT
    n.id,
    e.entity,
    e.code,
    n.year,
    MAKE_DATE(n.year, 1, 1)                                         AS year_start_date,
    CURRENT_DATE                                                    AS today,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, MAKE_DATE(n.year, 1, 1)))::INTEGER AS years_diff
FROM infectious_cases_normalized AS n
JOIN entities AS e
  ON e.id = n.entity_id
ORDER BY n.id
LIMIT 10;



-- Завдання 5. Власні функції

-- Функція fn_years_since
-- Функція 1: рік -> різниця в повних роках між CURRENT_DATE та 1 січня цього року
CREATE OR REPLACE FUNCTION fn_years_since(p_year INTEGER)
RETURNS INTEGER
LANGUAGE sql
STABLE                       -- залежить від CURRENT_DATE, тому не IMMUTABLE
AS $$
    SELECT EXTRACT(YEAR FROM AGE(CURRENT_DATE, MAKE_DATE(p_year, 1, 1)))::INTEGER
$$;

SELECT
    1996                  AS input_year,
    MAKE_DATE(1996, 1, 1) AS year_start_date,
    CURRENT_DATE          AS today,
    fn_years_since(1996)  AS years_diff;

-- Використання fn_years_since у запиті
SELECT
    n.id,
    e.entity,
    n.year,
    MAKE_DATE(n.year, 1, 1)                                         AS year_start_date,
    CURRENT_DATE                                                    AS today,
    fn_years_since(n.year)                                          AS years_diff_fn,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, MAKE_DATE(n.year, 1, 1)))::INTEGER AS years_diff_builtin
FROM infectious_cases_normalized AS n
JOIN entities AS e
  ON e.id = n.entity_id
ORDER BY n.id
LIMIT 10;

-- Перевірка fn_years_since проти Завдання 4
-- Функція дає той самий результат, що й вбудовані функції з Завдання 4, для всіх рядків
SELECT
    COUNT(*) AS n_rows_checked,
    COUNT(*) FILTER (
        WHERE fn_years_since(year)
              <> EXTRACT(YEAR FROM AGE(CURRENT_DATE, MAKE_DATE(year, 1, 1)))::INTEGER
    ) AS n_mismatches
FROM infectious_cases_normalized;

-- Функція fn_avg_cases_per_period
-- Функція 2: кількість захворювань за рік / довільний дільник
CREATE OR REPLACE FUNCTION fn_avg_cases_per_period(
    p_cases_per_year NUMERIC,
    p_divider        NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_divider IS NULL OR p_divider = 0 THEN
        RAISE EXCEPTION 'fn_avg_cases_per_period: divider must be non-zero (got %)', p_divider;
    END IF;
    RETURN p_cases_per_year / p_divider;
END;
$$;

SELECT
    ROUND(fn_avg_cases_per_period(1200, 12), 2) AS per_month_1200,
    ROUND(fn_avg_cases_per_period(1200, 4), 2)  AS per_quarter_1200,
    ROUND(fn_avg_cases_per_period(1200, 2), 2)  AS per_half_year_1200;

-- Числові значення Number_rabies
-- Скільки записів Number_rabies мають числове значення (лише їх передаємо у функцію)
SELECT
    COUNT(*)                                                    AS total_rows,
    COUNT(*) FILTER (WHERE number_rabies ~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$')     AS numeric_rows,
    COUNT(*) FILTER (WHERE number_rabies IS NULL
                        OR number_rabies !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$')    AS non_numeric_or_empty_rows
FROM infectious_cases;

-- Середня кількість на місяць / квартал / півріччя
SELECT
    entity,
    code,
    year::INTEGER                                                       AS year,
    number_rabies::NUMERIC                                              AS rabies_per_year,
    ROUND(fn_avg_cases_per_period(number_rabies::NUMERIC, 12), 4)       AS avg_per_month,
    ROUND(fn_avg_cases_per_period(number_rabies::NUMERIC, 4), 4)        AS avg_per_quarter,
    ROUND(fn_avg_cases_per_period(number_rabies::NUMERIC, 2), 4)        AS avg_per_half_year
FROM infectious_cases
WHERE number_rabies ~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'       -- лише числові значення
ORDER BY entity, year::INTEGER
LIMIT 10;
