ARG GRAFANA_BASE_IMAGE=grafana/grafana:13.1.0@sha256:121a7a9ece6dc10b969f1f96eed64b4f07dfac0d0b8abc070f7cb83bbde86f63
FROM ${GRAFANA_BASE_IMAGE}

ARG GRAFANA_BIGQUERY_VERSION=3.2.0
ARG GRAFANA_BIGQUERY_SHA256=6b1c2c457f4131608874553e14eab5c12f356f66114b2facea6d81bd323a74ea

USER root

RUN set -eux; \
    archive=/tmp/grafana-bigquery-datasource.zip; \
    plugin_dir=/usr/share/grafana/preinstalled-plugins/grafana-bigquery-datasource; \
    curl --fail --show-error --location --proto '=https' --tlsv1.2 \
      --output "$archive" \
      "https://storage.googleapis.com/grafana-plugins-catalog/grafana-bigquery-datasource/release/${GRAFANA_BIGQUERY_VERSION}/grafana-bigquery-datasource-${GRAFANA_BIGQUERY_VERSION}.zip"; \
    echo "${GRAFANA_BIGQUERY_SHA256}  ${archive}" | sha256sum -c -; \
    mkdir -p /usr/share/grafana/preinstalled-plugins; \
    unzip -q "$archive" -d /usr/share/grafana/preinstalled-plugins; \
    test -f "$plugin_dir/MANIFEST.txt"; \
    test -f "$plugin_dir/plugin.json"; \
    grep -Eq '"signatureType"[[:space:]]*:[[:space:]]*"grafana"' "$plugin_dir/MANIFEST.txt"; \
    grep -Eq '"signedByOrgName"[[:space:]]*:[[:space:]]*"Grafana Labs"' "$plugin_dir/MANIFEST.txt"; \
    grep -Eq '"plugin"[[:space:]]*:[[:space:]]*"grafana-bigquery-datasource"' "$plugin_dir/MANIFEST.txt"; \
    grep -Eq '"version"[[:space:]]*:[[:space:]]*"3\.2\.0"' "$plugin_dir/MANIFEST.txt"; \
    grep -Eq '"id"[[:space:]]*:[[:space:]]*"grafana-bigquery-datasource"' "$plugin_dir/plugin.json"; \
    grep -Eq '"version"[[:space:]]*:[[:space:]]*"3\.2\.0"' "$plugin_dir/plugin.json"; \
    rm -f "$archive"; \
    chown -R 472:0 /usr/share/grafana/preinstalled-plugins; \
    chmod -R a-w /usr/share/grafana/preinstalled-plugins

ENV GF_PATHS_PLUGINS=/usr/share/grafana/preinstalled-plugins

USER 472
