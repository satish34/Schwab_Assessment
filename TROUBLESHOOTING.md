# Troubleshooting

This document records material technical issues, their causes, fixes, and
verification. No credentials or private state are stored here.

## Selected assessment scenario

**Issue:** App A's application events were one-line JSON, but Spring framework
warnings and exceptions still used Logback's plain-text format. That mixed log
stream would produce inconsistent Cloud Logging fields and unreliable BigQuery
queries; multiline stacks could also split one failure into many records.

**Resolution:** App A now uses one custom Logback layout for framework and
application output. It maps Cloud severity, emits the same frozen 19 fields,
escapes messages, and bounds stack traces to one JSON line. Integration tests
cover both warnings and multiline exceptions.

**Verification:** The focused logging tests and the full App A suite pass. A
read-only container smoke captured only parseable one-line JSON, with every
framework and application event matching the frozen schema.

In plain language: the application produced two kinds of logs, so one query
could not read them reliably. The fix made every log use one predictable shape.
