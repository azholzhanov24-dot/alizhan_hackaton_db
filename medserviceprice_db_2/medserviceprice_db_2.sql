-- =============================================================================
-- MedServicePrice.kz — ФИНАЛЬНАЯ СХЕМА БАЗЫ ДАННЫХ
-- PostgreSQL 12+  |  Хакатон 2025
-- Полностью идемпотентный скрипт (безопасен для повторного запуска)
-- =============================================================================

-- =============================================================================
-- 0. ОЧИСТКА СТРУКТУРЫ (Обратный порядок удаления с учетом зависимостей)
-- =============================================================================
DROP TABLE IF EXISTS system_logs        CASCADE;
DROP TABLE IF EXISTS search_logs        CASCADE;
DROP TABLE IF EXISTS parser_jobs        CASCADE;
DROP TABLE IF EXISTS parser_sources     CASCADE;
DROP TABLE IF EXISTS price_history      CASCADE;
DROP TABLE IF EXISTS prices             CASCADE;
DROP TABLE IF EXISTS raw_service_entries CASCADE;
DROP TABLE IF EXISTS service_aliases    CASCADE;
DROP TABLE IF EXISTS services           CASCADE;
DROP TABLE IF EXISTS categories         CASCADE;
DROP TABLE IF EXISTS clinics            CASCADE;
DROP TABLE IF EXISTS clinic_chains      CASCADE;

DROP TYPE IF EXISTS currency_enum       CASCADE;
DROP TYPE IF EXISTS parser_status_enum  CASCADE;
DROP TYPE IF EXISTS job_status_enum     CASCADE;
DROP TYPE IF EXISTS log_level_enum      CASCADE;

DROP FUNCTION IF EXISTS trg_set_updated_at()  CASCADE;
DROP FUNCTION IF EXISTS trg_log_price_change() CASCADE;

-- Активация криптографического расширения для генерации UUID
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- =============================================================================
-- 1. ГЛОБАЛЬНЫЕ ENUM-ТИПЫ ДАННЫХ
-- =============================================================================
CREATE TYPE currency_enum AS ENUM (
    'KZT', 
    'USD'
);

CREATE TYPE parser_status_enum AS ENUM (
    'idle', 
    'pending', 
    'ok', 
    'error', 
    'disabled'
);

CREATE TYPE job_status_enum AS ENUM (
    'running', 
    'success', 
    'failed', 
    'partial'
);

CREATE TYPE log_level_enum AS ENUM (
    'debug', 
    'info', 
    'warning', 
    'error', 
    'critical'
);


-- =============================================================================
-- 2. ТАБЛИЦА: CLINIC_CHAINS (СЕТИ КЛИНИК)
-- =============================================================================
CREATE TABLE clinic_chains (
    id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    name       VARCHAR(255) NOT NULL UNIQUE,
    website    VARCHAR(500),
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE clinic_chains IS 'Сети клиник (например Олимп, KDL). Один филиал = одна запись clinics.';


-- =============================================================================
-- 3. ТАБЛИЦА: CLINICS (МЕДИЦИНСКИЕ КЛИНИКИ И ФИЛИАЛЫ)
-- =============================================================================
CREATE TABLE clinics (
    id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    chain_id   UUID         REFERENCES clinic_chains(id) ON DELETE SET NULL,
    name       VARCHAR(255) NOT NULL,
    slug       VARCHAR(255) NOT NULL UNIQUE,
    city       VARCHAR(100) NOT NULL,
    address    TEXT,
    phone      VARCHAR(100),
    website    VARCHAR(500),
    logo_url   VARCHAR(500),
    latitude   NUMERIC(9,6) CHECK (latitude BETWEEN -90 AND 90),
    longitude  NUMERIC(9,6) CHECK (longitude BETWEEN -180 AND 180),
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT chk_clinics_name_not_blank CHECK (btrim(name) <> '')
);

COMMENT ON TABLE clinics IS 'Справочник клиник и лабораторий Казахстана. Один ряд = один адрес/филиал.';
COMMENT ON COLUMN clinics.slug IS 'URL-friendly уникальный идентификатор, генерируется из названия клиники.';
COMMENT ON COLUMN clinics.chain_id IS 'Ссылка на сеть клиник. NULL — самостоятельная клиника.';


-- =============================================================================
-- 4. ТАБЛИЦА: CATEGORIES (КАТЕГОРИИ МЕДИЦИНСКИХ УСЛУГ)
-- =============================================================================
CREATE TABLE categories (
    id          SERIAL       PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE categories IS 'Высокоуровневые группы медуслуг: Лаборатория, УЗИ, МРТ, КТ, Консультации, Стоматология.';


-- =============================================================================
-- 5. ТАБЛИЦА: SERVICES (КАНОНИЧЕСКИЙ СПРАВОЧНИК УСЛУГ)
-- =============================================================================
CREATE TABLE services (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_name VARCHAR(255) NOT NULL,
    description    TEXT,
    category_id    INTEGER      NOT NULL REFERENCES categories(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_services_name_category UNIQUE (canonical_name, category_id),
    CONSTRAINT chk_services_name_not_blank CHECK (btrim(canonical_name) <> '')
);

COMMENT ON TABLE services IS 'Нормализованный справочник медуслуг. Всё, что парсер найдёт, привязывается через service_aliases к записи в этой таблице.';


-- =============================================================================
-- 6. ТАБЛИЦА: SERVICE_ALIASES (СИНОНИМЫ И АЛЬТЕРНАТИВНЫЕ НАЗВАНИЯ УСЛУГ)
-- =============================================================================
CREATE TABLE service_aliases (
    id         SERIAL       PRIMARY KEY,
    service_id UUID         NOT NULL REFERENCES services(id) ON DELETE CASCADE ON UPDATE CASCADE,
    alias_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_service_aliases_name UNIQUE (alias_name),
    CONSTRAINT chk_alias_name_not_blank CHECK (btrim(alias_name) <> '')
);

COMMENT ON TABLE service_aliases IS 'Синонимы, коды и аббревиатуры для нормализации: ОАК / CBC / Общий анализ крови → services.id.';


-- =============================================================================
-- 7. ТАБЛИЦА: RAW_SERVICE_ENTRIES (СЫРЫЕ ДАННЫЕ ИЗ ПАРСЕРОВ)
-- =============================================================================
CREATE TABLE raw_service_entries (
    id                BIGSERIAL     PRIMARY KEY,
    clinic_id         UUID          NOT NULL REFERENCES clinics(id) ON DELETE CASCADE,
    parser_job_id     BIGINT,       -- Внешний ключ связывается ниже через ALTER TABLE
    service_name_raw  VARCHAR(500)  NOT NULL,
    price_raw         NUMERIC(12,2),
    currency_raw      currency_enum NOT NULL DEFAULT 'KZT',
    duration_days_raw INTEGER,
    source_url        VARCHAR(1000),
    service_id        UUID          REFERENCES services(id) ON DELETE SET NULL,
    is_matched        BOOLEAN       NOT NULL DEFAULT FALSE,
    parsed_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT chk_raw_price_nonnegative CHECK (price_raw IS NULL OR price_raw >= 0)
);

COMMENT ON TABLE raw_service_entries IS 'Сырой слой (raw-layer): данные как пришли с сайта клиники. is_matched=false / service_id IS NULL = непривязанная очередь разметки.';


-- =============================================================================
-- 8. ТАБЛИЦА: PRICES (ТЕКУЩИЕ АКТУАЛЬНЫЕ ЦЕНЫ)
-- =============================================================================
CREATE TABLE prices (
    id           BIGSERIAL     PRIMARY KEY,
    clinic_id    UUID          NOT NULL REFERENCES clinics(id) ON DELETE CASCADE ON UPDATE CASCADE,
    service_id   UUID          NOT NULL REFERENCES services(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    price        NUMERIC(12,2) NOT NULL,
    currency     currency_enum NOT NULL DEFAULT 'KZT',
    source_url   VARCHAR(1000),
    last_updated TIMESTAMPTZ   NOT NULL DEFAULT now(),
    is_available BOOLEAN       NOT NULL DEFAULT TRUE,

    CONSTRAINT chk_prices_nonnegative CHECK (price >= 0),
    CONSTRAINT uq_prices_clinic_service UNIQUE (clinic_id, service_id)
);

COMMENT ON TABLE prices IS 'Актуальный прайс: одна строка на пару клиника+услуга. При повторном запуске парсер делает UPSERT, а не INSERT нового дубля.';


-- =============================================================================
-- 9. ТАБЛИЦА: PRICE_HISTORY (ИСТОРИЯ ИЗМЕНЕНИЯ СТОИМОСТИ)
-- =============================================================================
CREATE TABLE price_history (
    id         BIGSERIAL     PRIMARY KEY,
    price_id   BIGINT        NOT NULL REFERENCES prices(id) ON DELETE CASCADE ON UPDATE CASCADE,
    old_price  NUMERIC(12,2) NOT NULL,
    new_price  NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT chk_history_nonnegative CHECK (old_price >= 0 AND new_price >= 0)
);

COMMENT ON TABLE price_history IS 'Лог изменений цены. Пишется триггером автоматически — руками не трогать.';


-- =============================================================================
-- 10. ТАБЛИЦА: PARSER_SOURCES (ИСТОЧНИКИ ДЛЯ СБОРА ДАННЫХ)
-- =============================================================================
CREATE TABLE parser_sources (
    id           SERIAL             PRIMARY KEY,
    clinic_id    UUID               NOT NULL REFERENCES clinics(id) ON DELETE CASCADE ON UPDATE CASCADE,
    url          VARCHAR(1000)      NOT NULL,
    parser_name  VARCHAR(100)       NOT NULL,
    last_success TIMESTAMPTZ,
    last_error   TEXT,
    status       parser_status_enum NOT NULL DEFAULT 'pending',
    created_at   TIMESTAMPTZ        NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ        NOT NULL DEFAULT now(),

    CONSTRAINT uq_parser_sources_clinic_url UNIQUE (clinic_id, url)
);

COMMENT ON TABLE parser_sources IS 'Зарегистрированные URL-источники для каждой клиники. Один источник — один парсер.';


-- =============================================================================
-- 11. ТАБЛИЦА: PARSER_JOBS (ЛОГИ ЗАПУСКОВ ПАРСЕРА)
-- =============================================================================
CREATE TABLE parser_jobs (
    id                BIGSERIAL       PRIMARY KEY,
    parser_source_id  INTEGER         NOT NULL REFERENCES parser_sources(id) ON DELETE CASCADE ON UPDATE CASCADE,
    started_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    finished_at       TIMESTAMPTZ,
    status            job_status_enum NOT NULL DEFAULT 'running',
    processed_records INTEGER         NOT NULL DEFAULT 0,
    created_records   INTEGER         NOT NULL DEFAULT 0,
    updated_records   INTEGER         NOT NULL DEFAULT 0,
    errors_count      INTEGER         NOT NULL DEFAULT 0,

    CONSTRAINT chk_jobs_counts_nonnegative CHECK (
        processed_records >= 0 AND created_records >= 0 AND updated_records >= 0 AND errors_count >= 0
    ),
    CONSTRAINT chk_jobs_finished_after_started CHECK (
        finished_at IS NULL OR finished_at >= started_at
    )
);

COMMENT ON TABLE parser_jobs IS 'Журнал каждого запуска парсера: сколько обработано, создано, обновлено, ошибок.';


-- =============================================================================
-- 12. СВЯЗЫВАНИЕ ВНЕШНИХ КЛЮЧЕЙ (ALTER TABLE)
-- =============================================================================
ALTER TABLE raw_service_entries
    ADD CONSTRAINT fk_raw_entries_parser_job
    FOREIGN KEY (parser_job_id) REFERENCES parser_jobs(id) ON DELETE SET NULL;


-- =============================================================================
-- 13. ТАБЛИЦА: SEARCH_LOGS (АНАЛИТИКА ПОИСКОВЫХ ЗАПРОСОВ)
-- =============================================================================
CREATE TABLE search_logs (
    id            BIGSERIAL    PRIMARY KEY,
    query         VARCHAR(500) NOT NULL,
    results_count INTEGER      NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT chk_search_results_nonnegative CHECK (results_count >= 0)
);

COMMENT ON TABLE search_logs IS 'Телеметрия: что искали пользователи. Помогает приоритизировать нормализацию.';


-- =============================================================================
-- 14. ТАБЛИЦА: SYSTEM_LOGS (СИСТЕМНЫЙ ЖУРНАЛ СОБЫТИЙ)
-- =============================================================================
CREATE TABLE system_logs (
    id         BIGSERIAL      PRIMARY KEY,
    level      log_level_enum NOT NULL DEFAULT 'info',
    module     VARCHAR(100)   NOT NULL,
    message    TEXT           NOT NULL,
    created_at TIMESTAMPTZ    NOT NULL DEFAULT now()
);

COMMENT ON TABLE system_logs IS 'Централизованный журнал событий backend/парсера.';


-- =============================================================================
-- 15. ПОДПРОГРАММЫ И СТРУКТУРНЫЕ ИНДЕКСЫ
-- =============================================================================

-- Полнотекстовый поиск (GIN) по медицинским услугам и их синонимам
CREATE INDEX idx_services_fts        ON services        USING gin (to_tsvector('russian', canonical_name));
CREATE INDEX idx_aliases_fts         ON service_aliases USING gin (to_tsvector('russian', alias_name));
CREATE INDEX idx_aliases_service_id  ON service_aliases (service_id);

-- Полнотекстовый поиск (GIN) по названиям клиник
CREATE INDEX idx_clinics_fts         ON clinics         USING gin (to_tsvector('russian', name));

-- Поиск и фильтрация клиник (Город / Локация)
CREATE INDEX idx_clinics_city        ON clinics (city);
CREATE INDEX idx_clinics_coords      ON clinics (latitude, longitude);

-- Индексация справочников структуры услуг
CREATE INDEX idx_services_category   ON services (category_id);

-- Оптимизация витрины цен и выборок агрегатора
CREATE INDEX idx_prices_service      ON prices (service_id);
CREATE INDEX idx_prices_clinic       ON prices (clinic_id);
CREATE INDEX idx_prices_price        ON prices (price);
CREATE INDEX idx_prices_updated      ON prices (last_updated DESC);

-- Индексация хронологии изменения цен
CREATE INDEX idx_price_history_pid   ON price_history (price_id, changed_at DESC);

-- Индексы оптимизации необработанного и сырого слоя парсера (Очередь разметки)
CREATE INDEX idx_raw_unmatched       ON raw_service_entries (clinic_id) WHERE service_id IS NULL;
CREATE INDEX idx_raw_clinic          ON raw_service_entries (clinic_id);
CREATE INDEX idx_raw_service         ON raw_service_entries (service_id);
CREATE INDEX idx_raw_job             ON raw_service_entries (parser_job_id);

-- Индексация источников и фоновых задач парсинга
CREATE INDEX idx_parser_src_clinic   ON parser_sources (clinic_id);
CREATE INDEX idx_parser_jobs_src     ON parser_jobs (parser_source_id);
CREATE INDEX idx_parser_jobs_started ON parser_jobs (started_at DESC);

-- Индексация системных журналов и аналитики
CREATE INDEX idx_search_logs_date    ON search_logs (created_at DESC);
CREATE INDEX idx_system_logs_date    ON system_logs (created_at DESC);
CREATE INDEX idx_system_logs_level   ON system_logs (level);


-- =============================================================================
-- 16. ТРИГГЕРЫ АВТОМАТИЗАЦИИ СУЩНОСТЕЙ
-- =============================================================================

-- 16.1 Функция-обработчик обновления временной метки (updated_at)
CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- Назначение триггеров обновления дат для мастер-таблиц
CREATE TRIGGER trig_clinics_updated_at
    BEFORE UPDATE ON clinics
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

CREATE TRIGGER trig_services_updated_at
    BEFORE UPDATE ON services
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

CREATE TRIGGER trig_categories_updated_at
    BEFORE UPDATE ON categories
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

CREATE TRIGGER trig_parser_sources_updated_at
    BEFORE UPDATE ON parser_sources
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();


-- 16.2 Функция-обработчик автоматического ведения истории цен (price_history)
CREATE OR REPLACE FUNCTION trg_log_price_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.price IS DISTINCT FROM OLD.price THEN
        INSERT INTO price_history (price_id, old_price, new_price, changed_at)
        VALUES (OLD.id, OLD.price, NEW.price, now());
    END IF;
    RETURN NEW;
END;
$$;

-- Назначение триггера логирования ценовых колебаний
CREATE TRIGGER trig_prices_log_change
    AFTER UPDATE ON prices
    FOR EACH ROW EXECUTE FUNCTION trg_log_price_change();


-- =============================================================================
-- 17. НАПОЛНЕНИЕ СТАТИЧЕСКИХ ДАННЫХ (БАЗОВЫЕ КАТЕГОРИИ УСЛУГ)
-- =============================================================================
INSERT INTO categories (name, description) VALUES
    ('Лаборатория',  'Анализы крови, мочи и прочие лабораторные исследования'),
    ('УЗИ',          'Ультразвуковая диагностика'),
    ('МРТ',          'Магнитно-резонансная томография'),
    ('КТ',           'Компьютерная томография'),
    ('Консультации', 'Приёмы врачей-специалистов'),
    ('Стоматология', 'Стоматологические услуги')
ON CONFLICT (name) DO NOTHING;