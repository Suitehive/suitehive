-- Suitehive: one database per service (database-per-service, see docs/design/01-hld.md §10).
-- Runs once, when the postgres volume is first initialized.
CREATE DATABASE suitehive_auth;
CREATE DATABASE suitehive_mail;
CREATE DATABASE suitehive_calendar;
