-- ---------------------------------------------------------------------------
-- 0005_ola_source.sql — allow 'ola' as a provider.
--
-- The importer can now be pointed at Ola Maps, and both `mechanics.source` and
-- `search_tiles.source` are the `mechanic_source` enum, so the value has to
-- exist before a row can carry it. Without this an Ola import fails on insert
-- with "invalid input value for enum".
-- ---------------------------------------------------------------------------

alter type mechanic_source add value if not exists 'ola';
