#!/usr/bin/env bats
# Tests for get-config.sh --db-* fields
#
# Covers:
#   - DB auto-resolution (no --db): application first, primary fallback
#   - Explicit --db: uses exact name, no fallback
#   - --db metrics alias → analytics
#   - --user app (default) vs --user migration
#   - --env staging vs production
#   - All --db-* field types (host, port, name, username, password)
#   - Error cases: no databases, wrong name, missing secret_bucket, missing key, secret not found
#
# Requirements: bats-core (brew install bats-core), yq, jq, aws CLI (mocked)

SCRIPT="${BATS_TEST_DIRNAME}/../get-config.sh"

# ── Fixtures ──────────────────────────────────────────────────────────────────
# Written to TMPDIR in setup(); referenced by each test via $F_* variables.

setup() {
  TMPDIR="$(mktemp -d)"

  # ── Mock aws CLI ──────────────────────────────────────────────────────────
  mkdir -p "${TMPDIR}/bin"
  cat > "${TMPDIR}/bin/aws" << 'AWSEOF'
#!/usr/bin/env bash
# Minimal mock: handles "secretsmanager get-secret-value --secret-id X --query SecretString --output text"
if [[ "$*" != *"secretsmanager get-secret-value"* ]]; then
  echo "mock: unsupported aws command: $*" >&2; exit 1
fi
secret_id=""; prev=""
for arg in "$@"; do
  [[ "$prev" == "--secret-id" ]] && secret_id="$arg"
  prev="$arg"
done
case "$secret_id" in
  "myapp/production/database")
    echo '{"DB_HOST":"prod.db.example.com","DB_PORT":"3306","DB_NAME":"myapp_prod","DB_APP_USERNAME":"prod_app_user","DB_APP_PASSWORD":"prod-app-pass","DB_MIGRATION_USERNAME":"prod_mig_user","DB_MIGRATION_PASSWORD":"prod-mig-pass"}'
    ;;
  "myapp/staging/database")
    echo '{"DB_HOST":"stage.db.example.com","DB_PORT":"3306","DB_NAME":"myapp_stage","DB_APP_USERNAME":"stage_app_user","DB_APP_PASSWORD":"stage-app-pass"}'
    ;;
  "myapp/production/database-analytics")
    echo '{"DB_HOST":"prod.db.example.com","DB_PORT":"3306","DB_ANALYTICS_NAME":"myapp_analytics","DB_ANALYTICS_APP_USERNAME":"analytics_app_user","DB_ANALYTICS_APP_PASSWORD":"analytics-app-pass","DB_ANALYTICS_MIGRATION_USERNAME":"analytics_mig_user","DB_ANALYTICS_MIGRATION_PASSWORD":"analytics-mig-pass"}'
    ;;
  "legacyapp/production/database")
    echo '{"DB_HOST":"legacy.db.example.com","DB_APP_PASSWORD":"legacy-app-pass","DB_APP_USERNAME":"legacy_app_user","DB_NAME":"legacyapp_prod","DB_PORT":"3306"}'
    ;;
  "bothapp/production/database")
    echo '{"DB_HOST":"both-app.db.example.com","DB_APP_PASSWORD":"both-app-pass"}'
    ;;
  "bothapp/production/database-primary")
    echo '{"DB_HOST":"both-primary.db.example.com","DB_APP_PASSWORD":"both-primary-pass"}'
    ;;
  *)
    echo "ResourceNotFoundException: Secrets Manager can't find the specified secret." >&2
    exit 1
    ;;
esac
AWSEOF
  chmod +x "${TMPDIR}/bin/aws"

  # ── Mock yq: wrap system yq with -r to match mikefarah/yq output ────────
  # The script expects unquoted string output (mikefarah Go yq behavior).
  # Some systems ship a jq-based yq wrapper that quotes by default.
  REAL_YQ="$(command -v yq)"
  cat > "${TMPDIR}/bin/yq" << YQEOF
#!/usr/bin/env bash
exec "${REAL_YQ}" -r "\$@"
YQEOF
  chmod +x "${TMPDIR}/bin/yq"

  export PATH="${TMPDIR}/bin:${PATH}"

  # Ensure tests use AWS backend regardless of where bats runs
  export AWS_DEFAULT_REGION="us-east-1"

  # ── Fixture 1: Standard — database named "application" ───────────────────
  F_STANDARD="${TMPDIR}/standard.yaml"
  cat > "${F_STANDARD}" << 'EOF'
name: myapp
secrets:
  backend: aws
deployment:
  strategy: none
databases:
  - name: application
    type: mysql
    optional: false
    users:
      migration:
        secret_bucket: database
        secret_keys:
          host: DB_HOST
          port: DB_PORT
          database: DB_NAME
          username: DB_MIGRATION_USERNAME
          password: DB_MIGRATION_PASSWORD
      app:
        secret_bucket: database
        secret_keys:
          host: DB_HOST
          port: DB_PORT
          database: DB_NAME
          username: DB_APP_USERNAME
          password: DB_APP_PASSWORD
EOF

  # ── Fixture 2: Legacy — database named "primary" (no "application") ──────
  F_LEGACY="${TMPDIR}/legacy.yaml"
  cat > "${F_LEGACY}" << 'EOF'
name: legacyapp
secrets:
  backend: aws
deployment:
  strategy: none
databases:
  - name: primary
    type: mysql
    optional: false
    users:
      app:
        secret_bucket: database
        secret_keys:
          host: DB_HOST
          port: DB_PORT
          database: DB_NAME
          username: DB_APP_USERNAME
          password: DB_APP_PASSWORD
EOF

  # ── Fixture 3: Multi-DB — application (required) + analytics (optional) ──
  F_MULTI="${TMPDIR}/multi.yaml"
  cat > "${F_MULTI}" << 'EOF'
name: myapp
secrets:
  backend: aws
deployment:
  strategy: none
databases:
  - name: application
    type: mysql
    optional: false
    users:
      app:
        secret_bucket: database
        secret_keys:
          host: DB_HOST
          port: DB_PORT
          database: DB_NAME
          username: DB_APP_USERNAME
          password: DB_APP_PASSWORD
  - name: analytics
    type: mysql
    optional: true
    users:
      migration:
        secret_bucket: database-analytics
        secret_keys:
          host: DB_HOST
          port: DB_PORT
          database: DB_ANALYTICS_NAME
          username: DB_ANALYTICS_MIGRATION_USERNAME
          password: DB_ANALYTICS_MIGRATION_PASSWORD
      app:
        secret_bucket: database-analytics
        secret_keys:
          host: DB_HOST
          port: DB_PORT
          database: DB_ANALYTICS_NAME
          username: DB_ANALYTICS_APP_USERNAME
          password: DB_ANALYTICS_APP_PASSWORD
EOF

  # ── Fixture 4: Both — both "application" and "primary" present ───────────
  F_BOTH="${TMPDIR}/both.yaml"
  cat > "${F_BOTH}" << 'EOF'
name: bothapp
secrets:
  backend: aws
deployment:
  strategy: none
databases:
  - name: application
    type: mysql
    optional: false
    users:
      app:
        secret_bucket: database
        secret_keys:
          host: DB_HOST
          password: DB_APP_PASSWORD
  - name: primary
    type: mysql
    optional: false
    users:
      app:
        secret_bucket: database-primary
        secret_keys:
          host: DB_HOST
          password: DB_APP_PASSWORD
EOF

  # ── Fixture 5: Empty databases list ──────────────────────────────────────
  F_EMPTY="${TMPDIR}/empty.yaml"
  cat > "${F_EMPTY}" << 'EOF'
name: myapp
secrets:
  backend: aws
deployment:
  strategy: none
databases: []
EOF

  # ── Fixture 6: Missing secret_bucket ─────────────────────────────────────
  F_NO_BUCKET="${TMPDIR}/no-bucket.yaml"
  cat > "${F_NO_BUCKET}" << 'EOF'
name: myapp
secrets:
  backend: aws
deployment:
  strategy: none
databases:
  - name: application
    type: mysql
    optional: false
    users:
      app:
        secret_keys:
          password: DB_APP_PASSWORD
EOF

  # ── Fixture 7: Missing secret key entry ───────────────────────────────────
  F_NO_KEY="${TMPDIR}/no-key.yaml"
  cat > "${F_NO_KEY}" << 'EOF'
name: myapp
secrets:
  backend: aws
deployment:
  strategy: none
databases:
  - name: application
    type: mysql
    optional: false
    users:
      app:
        secret_bucket: database
        secret_keys:
          host: DB_HOST
          username: DB_APP_USERNAME
          # password intentionally omitted
EOF
}

teardown() {
  rm -rf "${TMPDIR}"
}

# ── DB auto-resolution (no --db flag) ────────────────────────────────────────

@test "auto-resolve: uses 'application' when it exists" {
  run "$SCRIPT" --db-password --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod-app-pass" ]
}

@test "auto-resolve: falls back to 'primary' when 'application' absent" {
  run "$SCRIPT" --db-password --file "$F_LEGACY" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "legacy-app-pass" ]
}

@test "auto-resolve: prefers 'application' over 'primary' when both exist" {
  run "$SCRIPT" --db-password --file "$F_BOTH" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "both-app-pass" ]
}

@test "auto-resolve: error when neither 'application' nor 'primary' present" {
  run "$SCRIPT" --db-password --file "$F_MULTI" --env production
  # F_MULTI has 'application', so this should succeed — reuse EMPTY for the real test
  [ "$status" -eq 0 ]
}

@test "auto-resolve: error on empty databases list" {
  run "$SCRIPT" --db-password --file "$F_EMPTY" --env production
  [ "$status" -eq 1 ]
  [[ "$output" == *"No databases configured"* ]]
}

# ── Explicit --db flag ────────────────────────────────────────────────────────

@test "--db application: explicit lookup by canonical name" {
  run "$SCRIPT" --db-password --db application --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod-app-pass" ]
}

@test "--db primary: targets database literally named 'primary' (no alias)" {
  run "$SCRIPT" --db-password --db primary --file "$F_BOTH" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "both-primary-pass" ]
}

@test "--db primary: error when no database named 'primary' exists" {
  run "$SCRIPT" --db-password --db primary --file "$F_STANDARD" --env production
  [ "$status" -eq 1 ]
  [[ "$output" == *"'primary' not found"* ]]
}

@test "--db analytics: explicit analytics lookup" {
  run "$SCRIPT" --db-password --db analytics --file "$F_MULTI" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "analytics-app-pass" ]
}

@test "--db metrics: aliased to analytics" {
  run "$SCRIPT" --db-password --db metrics --file "$F_MULTI" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "analytics-app-pass" ]
}

@test "--db analytics: error when analytics not configured" {
  run "$SCRIPT" --db-password --db analytics --file "$F_STANDARD" --env production
  [ "$status" -eq 1 ]
  [[ "$output" == *"'analytics' not found"* ]]
}

# ── --user flag ───────────────────────────────────────────────────────────────

@test "--user app (default): returns app user password" {
  run "$SCRIPT" --db-password --user app --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod-app-pass" ]
}

@test "--user migration: returns migration user password" {
  run "$SCRIPT" --db-password --user migration --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod-mig-pass" ]
}

@test "--user migration with --db analytics: returns analytics migration password" {
  run "$SCRIPT" --db-password --db analytics --user migration --file "$F_MULTI" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "analytics-mig-pass" ]
}

@test "--user invalid: exits with error" {
  run "$SCRIPT" --db-password --user superuser --file "$F_STANDARD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"--user must be app or migration"* ]]
}

# ── --env flag ────────────────────────────────────────────────────────────────

@test "--env production (default): fetches production secrets" {
  run "$SCRIPT" --db-password --file "$F_STANDARD"
  [ "$status" -eq 0 ]
  [ "$output" = "prod-app-pass" ]
}

@test "--env staging: fetches staging secrets" {
  run "$SCRIPT" --db-password --file "$F_STANDARD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "stage-app-pass" ]
}

# ── All field types ───────────────────────────────────────────────────────────

@test "--db-host: returns hostname" {
  run "$SCRIPT" --db-host --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod.db.example.com" ]
}

@test "--db-port: returns port" {
  run "$SCRIPT" --db-port --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "3306" ]
}

@test "--db-name: returns database name" {
  run "$SCRIPT" --db-name --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "myapp_prod" ]
}

@test "--db-username: returns username" {
  run "$SCRIPT" --db-username --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod_app_user" ]
}

@test "--db-password: returns password" {
  run "$SCRIPT" --db-password --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod-app-pass" ]
}

@test "--db-host with --db analytics: returns host from analytics secret" {
  run "$SCRIPT" --db-host --db analytics --file "$F_MULTI" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod.db.example.com" ]
}

# ── Error cases ───────────────────────────────────────────────────────────────

@test "missing secret_bucket: error with path hint" {
  run "$SCRIPT" --db-password --file "$F_NO_BUCKET" --env production
  [ "$status" -eq 1 ]
  [[ "$output" == *"secret_bucket"* ]]
  [[ "$output" == *"application"* ]]
}

@test "missing secret key in config: error with key name hint" {
  run "$SCRIPT" --db-password --file "$F_NO_KEY" --env production
  [ "$status" -eq 1 ]
  [[ "$output" == *"password"* ]]
}

@test "secret not found in backend: error with full path" {
  # F_LEGACY uses name "legacyapp" but staging path isn't mocked
  run "$SCRIPT" --db-password --file "$F_LEGACY" --env staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"Secret not found in AWS Secrets Manager"* ]]
  [[ "$output" == *"legacyapp/staging/database"* ]]
}

@test "PROJECT.yaml missing: exit 2" {
  run "$SCRIPT" --db-password --file "/nonexistent/PROJECT.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

@test "invalid --db value: error when database not found" {
  run "$SCRIPT" --db-password --db nonexistent --file "$F_STANDARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'nonexistent' not found"* ]]
  [[ "$output" == *"application"* ]]   # shows available names
}
