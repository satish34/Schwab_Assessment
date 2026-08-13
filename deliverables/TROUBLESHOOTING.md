# Troubleshooting scenario: mixed Java log formats

## Symptom

App A's application events were valid one-line JSON, but Spring/Logback warnings
and exception output still used plain text. A multiline framework exception
could become several Cloud Logging entries, so the exported BigQuery table did
not have one reliable shape for all Java events.

## Investigation and root cause

The request logger serialized its own event object, but framework loggers still
used Logback's default encoder. Cloud Logging was behaving correctly; the
process itself emitted two formats. Changing a BigQuery query would only hide
the inconsistency and would leave future framework failures hard to correlate.

## Fix

App A now routes framework and application console output through one frozen
Logback layout. It:

- maps Java levels to Cloud severity;
- emits the same bounded structured fields on one physical line;
- JSON-escapes messages and multiline exceptions;
- bounds stack traces; and
- emits a safe fallback JSON event if serialization itself fails.

The design never logs authorization headers, ID tokens, credentials, request
bodies, or raw exception text to public callers.

## Verification

`ConsoleLoggingIntegrationTest` injects a multiline framework exception and a
warning, parses each captured line as JSON, and checks the frozen schema.
`StructuredLoggerTest` covers application events and schema seeds. The deployed
`30fd8e9d...` evidence then proves same-trace Java and .NET structured rows,
while the BigQuery gate proves trace joins and typed latency/status fields.

## Interview lesson

The durable fix belongs at the producer boundary. A log sink cannot reliably
repair mixed or multiline process output after emission; enforcing one schema
in code makes Logging, BigQuery, Error Reporting, and Grafana consumers simpler
and testable.
