resource "google_compute_security_policy" "currency_edge" {
  count = var.enable_cloud_armor ? 1 : 0

  project = var.project_id
  name    = "currency-edge-waf"

  description     = "Rate limiting with preview-only OWASP SQLi and XSS detection."
  type            = "CLOUD_ARMOR"
  deletion_policy = "DELETE"

  rule {
    priority    = 1000
    action      = "deny(403)"
    preview     = true
    description = "Preview OWASP CRS 4.22 SQL injection signatures."

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v422-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    priority    = 1010
    action      = "deny(403)"
    preview     = true
    description = "Preview OWASP CRS 4.22 cross-site scripting signatures."

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v422-stable', {'sensitivity': 1})"
      }
    }
  }

  # The failover gate intentionally sends one request per second. A
  # 120-request threshold leaves room for its health checks while still
  # bounding a single abusive client. A much larger repeated burst triggers a
  # one-minute ban; evidence generation runs only after the normal release gates.
  rule {
    priority    = 2000
    action      = "rate_based_ban"
    preview     = false
    description = "Per-client-IP rate limit with a repeat-offender ban."

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action   = "allow"
      exceed_action    = "deny(429)"
      enforce_on_key   = "IP"
      ban_duration_sec = 60

      rate_limit_threshold {
        count        = 120
        interval_sec = 60
      }

      ban_threshold {
        count        = 600
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 2147483647
    action      = "allow"
    preview     = false
    description = "Allow traffic that did not match a higher-priority rule."

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
