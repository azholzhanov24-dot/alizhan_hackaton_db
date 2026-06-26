-- =============================================================================
-- DATABASE SCHEMA FOR MEDSERVICEPRICE.KZ AGGREGATOR PLATFORM
-- SYSTEM: PostgreSQL (pgAdmin friendly)
-- CHARACTERISTIC: Completely RERUNNABLE (Idempotent script)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CLEANUP REVERSE ORDER (Safe to run multiple times)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS system_logs CASCADE;
DROP TABLE IF EXISTS search_logs CASCADE;
DROP TABLE IF EXISTS parser_jobs CASCADE;
DROP TABLE IF EXISTS parser_sources CASCADE;
DROP TABLE IF EXISTS price_history CASCADE;
DROP TABLE IF EXISTS prices CASCADE;
DROP TABLE IF EXISTS service_aliases CASCADE;
DROP TABLE IF EXISTS services CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS clinics CASCADE;

-- Extension activation for UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- 1. CLINICS TABLE
-- Stores master data of various medical centers, hospitals, and laboratories.
-- =============================================================================
CREATE TABLE clinics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL UNIQUE,
    city VARCHAR(100) NOT NULL,
    address TEXT NOT NULL,
    phone VARCHAR(100),
    website VARCHAR(255),
    logo_url VARCHAR(255),
    latitude NUMERIC(10, 8),
    longitude NUMERIC(11, 8),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE clinics IS 'Master directory of medical clinics and laboratories in Kazakhstan.';
COMMENT ON COLUMN clinics.slug IS 'URL-friendly unique identifier generated from the clinic name.';


-- =============================================================================
-- 2. CATEGORIES TABLE
-- Represents high-level medical groups (e.g., Diagnostics, Laboratory).
-- =============================================================================
CREATE TABLE categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE categories IS 'High-level medical service categorizations.';


-- =============================================================================
-- 3. SERVICES (CANONICAL DIRECTORY) TABLE
-- The standardized clinical catalog for the application mapping layer.
-- =============================================================================
CREATE TABLE services (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    canonical_name VARCHAR(255) NOT NULL UNIQUE,
    description TEXT,
    category_id UUID NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_services_category FOREIGN KEY (category_id)
        REFERENCES categories (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
);

COMMENT ON TABLE services IS 'The unified canonical medical services reference directory.';


-- =============================================================================
-- 4. SERVICE ALIASES TABLE
-- Stores diverse synonyms, codes, and acronyms parsed from target sites.
-- =============================================================================
CREATE TABLE service_aliases (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    service_id UUID NOT NULL,
    alias_name VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_aliases_service FOREIGN KEY (service_id)
        REFERENCES services (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

COMMENT ON TABLE service_aliases IS 'Dictionary of raw alternative names mapping to unified canonical services.';


-- =============================================================================
-- 5. PRICES (LIVE TRANSACTIONS) TABLE
-- Tracks real-time active price records scraped from online clinical resources.
-- =============================================================================
CREATE TABLE prices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id UUID NOT NULL,
    service_id UUID NOT NULL,
    price NUMERIC(12, 2) NOT NULL,
    currency VARCHAR(10) NOT NULL DEFAULT 'KZT',
    source_url TEXT NOT NULL,
    last_updated TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_prices_clinic FOREIGN KEY (clinic_id)
        REFERENCES clinics (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT fk_prices_service FOREIGN KEY (service_id)
        REFERENCES services (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,
    CONSTRAINT chk_positive_price CHECK (price >= 0.00)
);

COMMENT ON TABLE prices IS 'Active transactional price listing for clinic services.';


-- =============================================================================
-- 6. PRICE HISTORY TABLE
-- Appends log differentials whenever existing live costs fluctuate over time.
-- =============================================================================
CREATE TABLE price_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    price_id UUID NOT NULL,
    old_price NUMERIC(12, 2) NOT NULL,
    new_price NUMERIC(12, 2) NOT NULL,
    changed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_history_price FOREIGN KEY (price_id)
        REFERENCES prices (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

COMMENT ON TABLE price_history IS 'Historical ledger tracking system price fluctuations over time.';


-- =============================================================================
-- 7. PARSER SOURCES TABLE
-- Manifest containing registered crawler engines pointing to endpoints.
-- =============================================================================
CREATE TABLE parser_sources (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clinic_id UUID NOT NULL,
    url TEXT NOT NULL,
    parser_name VARCHAR(100) NOT NULL,
    last_success TIMESTAMP WITH TIME ZONE,
    last_error TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'IDLE',
    CONSTRAINT fk_sources_clinic FOREIGN KEY (clinic_id)
        REFERENCES clinics (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

COMMENT ON TABLE parser_sources IS 'Target endpoints configurations managed by automated crawler daemons.';


-- =============================================================================
-- 8. PARSER JOBS TABLE
-- Execution state logger auditing scheduled task batch jobs.
-- =============================================================================
CREATE TABLE parser_jobs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    parser_source_id UUID NOT NULL,
    started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP WITH TIME ZONE,
    status VARCHAR(50) NOT NULL,
    processed_records INTEGER DEFAULT 0,
    created_records INTEGER DEFAULT 0,
    updated_records INTEGER DEFAULT 0,
    errors_count INTEGER DEFAULT 0,
    CONSTRAINT fk_jobs_source FOREIGN KEY (parser_source_id)
        REFERENCES parser_sources (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

COMMENT ON TABLE parser_jobs IS 'Audit trail recording routine crawler performance statistics.';


-- =============================================================================
-- 9. SEARCH LOGS TABLE
-- Captures verbatim input query data issued by platform end-users.
-- =============================================================================
CREATE TABLE search_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    query VARCHAR(255) NOT NULL,
    results_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE search_logs IS 'Telemetry repository capturing platform internal user analytics.';


-- =============================================================================
-- 10. SYSTEM LOGS TABLE
-- Unified diagnostic table mapping operational runtime logs from the back-end.
-- =============================================================================
CREATE TABLE system_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    level VARCHAR(50) NOT NULL,
    module VARCHAR(100) NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE system_logs IS 'Central application debugging diagnostics matrix.';


-- =============================================================================
-- INDEX DEFINITIONS (RERUNNABLE)
-- Indices built dynamically using IF NOT EXISTS clause.
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_services_canonical_name ON services (canonical_name);
CREATE INDEX IF NOT EXISTS idx_service_aliases_name ON service_aliases (alias_name);
CREATE INDEX IF NOT EXISTS idx_clinics_name ON clinics (name);
CREATE INDEX IF NOT EXISTS idx_clinics_city ON clinics (city);
CREATE INDEX IF NOT EXISTS idx_services_category_id ON services (category_id);
CREATE INDEX IF NOT EXISTS idx_prices_live_lookup ON prices (price, last_updated DESC);
CREATE INDEX IF NOT EXISTS idx_prices_clinic_service ON prices (clinic_id, service_id);
CREATE INDEX IF NOT EXISTS idx_price_history_lookup ON price_history (price_id, changed_at DESC);