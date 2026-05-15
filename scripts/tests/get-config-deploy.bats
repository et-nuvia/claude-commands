#!/usr/bin/env bats
# Tests for get-config.sh --deploy-* fields
#
# Covers:
#   - All 4 deployment strategies: blue-green, standard, single, none
#   - Color resolution: active/inactive/blue/green explicit
#   - IP type: private (default), public, --ip-type override, ip_access setting
#   - Region 3-level fallback: color-level → env-level → top-level
#   - Method fallback: env-level → top-level → "pipeline" default
#   - --env staging vs production
#   - Strategy auto-detection from YAML structure (no explicit strategy field)
#   - All deploy fields: ip, instance, method, region, rds-host, containers, firebase
#   - Error cases: missing active, missing instance, missing region, missing rds-host
#
# Note: env_type() returns "work" on macOS (Darwin), "home" on Linux.
# All fixtures use the key matching the current platform.

SCRIPT="${BATS_TEST_DIRNAME}/../get-config.sh"

setup() {
  TMPDIR="$(mktemp -d)"

  # Determine platform key: env_type() returns "work" on Darwin, "home" on Linux
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PLATFORM_KEY="work"
  else
    PLATFORM_KEY="home"
  fi

  # Wrap yq to always pass -r (raw output) so jq-wrapper yq (kislyuk/yq)
  # returns unquoted strings like mikefarah/yq does natively.
  # The script's yq_get() calls `yq "$filter" "$file"` without -r.
  REAL_YQ="$(command -v yq)"
  YQ_BIN="${TMPDIR}/bin"
  mkdir -p "$YQ_BIN"
  cat > "${YQ_BIN}/yq" << WRAPPER
#!/usr/bin/env bash
# If the first arg looks like a jq filter (starts with .), inject -r
if [[ "\$1" == .* ]]; then
  exec "$REAL_YQ" -r "\$@"
else
  exec "$REAL_YQ" "\$@"
fi
WRAPPER
  chmod +x "${YQ_BIN}/yq"
  export PATH="${YQ_BIN}:${PATH}"

  # ── Fixture: Blue-green (canonical) ──────────────────────────────────────
  # staging: active=green  |  production: active=blue
  # ip_access: private (default)  |  region: us-west-1 at top level
  F_BG="${TMPDIR}/blue-green.yaml"
  cat > "$F_BG" << EOF
name: myapp
deployment:
  strategy: blue-green
  ip_access: private
  region: us-west-1
  ${PLATFORM_KEY}:
    staging:
      method: ssm
      active: green
      blue:
        instance_id: i-stg-blue
        private_ip: 172.16.1.10
        public_ip: 54.1.2.3
      green:
        instance_id: i-stg-green
        private_ip: 172.16.1.20
        public_ip: 54.4.5.6
      rds_host: staging.rds.example.com
      firebase_project: myapp-staging
      containers: [frontend, backend]
    production:
      method: ssm
      active: blue
      blue:
        instance_id: i-prod-blue
        private_ip: 172.16.1.30
        public_ip: 54.7.8.9
      green:
        instance_id: i-prod-green
        private_ip: 172.16.1.40
        public_ip: 54.10.11.12
      rds_host: prod.rds.example.com
      firebase_project: myapp-production
      containers: [frontend, backend, worker]
EOF

  # ── Fixture: Blue-green with ip_access=public ─────────────────────────────
  F_BG_PUB="${TMPDIR}/blue-green-public.yaml"
  sed 's/ip_access: private/ip_access: public/' "$F_BG" > "$F_BG_PUB"

  # ── Fixture: Blue-green — region at env level only ─────────────────────────
  # Tests that level-2 (env) wins when top-level is absent
  F_BG_REGION_ENV="${TMPDIR}/bg-region-env.yaml"
  cat > "$F_BG_REGION_ENV" << EOF
name: myapp
deployment:
  strategy: blue-green
  ip_access: private
  ${PLATFORM_KEY}:
    staging:
      method: ssm
      active: green
      region: eu-west-1
      blue:
        instance_id: i-stg-blue
        private_ip: 172.16.1.10
        public_ip: 54.1.2.3
      green:
        instance_id: i-stg-green
        private_ip: 172.16.1.20
        public_ip: 54.4.5.6
      rds_host: staging.rds.example.com
      containers: [frontend]
    production:
      method: ssm
      active: blue
      region: eu-west-1
      blue:
        instance_id: i-prod-blue
        private_ip: 172.16.1.30
        public_ip: 54.7.8.9
      green:
        instance_id: i-prod-green
        private_ip: 172.16.1.40
        public_ip: 54.10.11.12
      rds_host: prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Blue-green — region at color level only ──────────────────────
  # Tests that level-1 (color) wins when env and top-level are absent
  F_BG_REGION_COLOR="${TMPDIR}/bg-region-color.yaml"
  cat > "$F_BG_REGION_COLOR" << EOF
name: myapp
deployment:
  strategy: blue-green
  ip_access: private
  ${PLATFORM_KEY}:
    staging:
      method: ssm
      active: green
      blue:
        instance_id: i-stg-blue
        private_ip: 172.16.1.10
        public_ip: 54.1.2.3
        region: ap-southeast-1
      green:
        instance_id: i-stg-green
        private_ip: 172.16.1.20
        public_ip: 54.4.5.6
        region: ap-southeast-1
      rds_host: staging.rds.example.com
      containers: [frontend]
    production:
      method: ssm
      active: blue
      blue:
        instance_id: i-prod-blue
        private_ip: 172.16.1.30
        public_ip: 54.7.8.9
        region: ap-southeast-1
      green:
        instance_id: i-prod-green
        private_ip: 172.16.1.40
        public_ip: 54.10.11.12
        region: ap-southeast-1
      rds_host: prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Blue-green — no region anywhere (should error) ───────────────
  F_BG_NO_REGION="${TMPDIR}/bg-no-region.yaml"
  cat > "$F_BG_NO_REGION" << EOF
name: myapp
deployment:
  strategy: blue-green
  ip_access: private
  ${PLATFORM_KEY}:
    staging:
      method: ssm
      active: green
      blue:
        instance_id: i-stg-blue
        private_ip: 172.16.1.10
        public_ip: 54.1.2.3
      green:
        instance_id: i-stg-green
        private_ip: 172.16.1.20
        public_ip: 54.4.5.6
      rds_host: staging.rds.example.com
      containers: [frontend]
    production:
      method: ssm
      active: blue
      blue:
        instance_id: i-prod-blue
        private_ip: 172.16.1.30
        public_ip: 54.7.8.9
      green:
        instance_id: i-prod-green
        private_ip: 172.16.1.40
        public_ip: 54.10.11.12
      rds_host: prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Blue-green — method at top level only ────────────────────────
  # Tests that method falls back from missing env-level to top-level
  F_BG_METHOD_TOP="${TMPDIR}/bg-method-top.yaml"
  cat > "$F_BG_METHOD_TOP" << EOF
name: myapp
deployment:
  strategy: blue-green
  ip_access: private
  region: us-west-1
  method: ssh
  ${PLATFORM_KEY}:
    staging:
      active: green
      blue:
        instance_id: i-stg-blue
        private_ip: 172.16.1.10
        public_ip: 54.1.2.3
      green:
        instance_id: i-stg-green
        private_ip: 172.16.1.20
        public_ip: 54.4.5.6
      rds_host: staging.rds.example.com
      containers: [frontend]
    production:
      active: blue
      blue:
        instance_id: i-prod-blue
        private_ip: 172.16.1.30
        public_ip: 54.7.8.9
      green:
        instance_id: i-prod-green
        private_ip: 172.16.1.40
        public_ip: 54.10.11.12
      rds_host: prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Blue-green — missing active field ────────────────────────────
  F_BG_NO_ACTIVE="${TMPDIR}/bg-no-active.yaml"
  cat > "$F_BG_NO_ACTIVE" << EOF
name: myapp
deployment:
  strategy: blue-green
  ip_access: private
  region: us-west-1
  ${PLATFORM_KEY}:
    staging:
      method: ssm
      blue:
        instance_id: i-stg-blue
        private_ip: 172.16.1.10
        public_ip: 54.1.2.3
      green:
        instance_id: i-stg-green
        private_ip: 172.16.1.20
        public_ip: 54.4.5.6
      rds_host: staging.rds.example.com
      containers: [frontend]
    production:
      method: ssm
      blue:
        instance_id: i-prod-blue
        private_ip: 172.16.1.30
        public_ip: 54.7.8.9
      rds_host: prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Standard ─────────────────────────────────────────────────────
  F_STANDARD="${TMPDIR}/standard.yaml"
  cat > "$F_STANDARD" << EOF
name: myapp
deployment:
  strategy: standard
  ip_access: private
  region: us-east-1
  ${PLATFORM_KEY}:
    staging:
      method: ssh
      instance_id: i-std-staging
      private_ip: 10.0.1.100
      public_ip: 52.1.2.3
      rds_host: std-staging.rds.example.com
      firebase_project: myapp-std-staging
      containers: [frontend, backend]
    production:
      method: ssh
      instance_id: i-std-prod
      private_ip: 10.0.1.200
      public_ip: 52.4.5.6
      rds_host: std-prod.rds.example.com
      containers: [frontend, backend, worker]
EOF

  # ── Fixture: Single ───────────────────────────────────────────────────────
  F_SINGLE="${TMPDIR}/single.yaml"
  cat > "$F_SINGLE" << EOF
name: myapp
deployment:
  strategy: single
  ip_access: public
  region: us-east-2
  ${PLATFORM_KEY}:
    server:
      method: ssh
      instance_id: i-single-server
      private_ip: 192.168.1.100
      public_ip: 54.100.101.102
      rds_host: single.rds.example.com
      containers: [frontend, backend]
EOF

  # ── Fixture: None (pipeline-only) ────────────────────────────────────────
  F_NONE="${TMPDIR}/none.yaml"
  cat > "$F_NONE" << 'EOF'
name: myapp
deployment:
  strategy: none
EOF

  # ── Fixture: Auto-detect blue-green (no strategy field) ───────────────────
  F_AUTO_BG="${TMPDIR}/auto-bg.yaml"
  cat > "$F_AUTO_BG" << EOF
name: myapp
deployment:
  ip_access: private
  region: us-west-2
  ${PLATFORM_KEY}:
    staging:
      method: ssm
      active: green
      blue:
        instance_id: i-auto-stg-blue
        private_ip: 172.16.2.10
        public_ip: 54.20.21.22
      green:
        instance_id: i-auto-stg-green
        private_ip: 172.16.2.20
        public_ip: 54.23.24.25
      rds_host: auto-staging.rds.example.com
      containers: [frontend]
    production:
      method: ssm
      active: blue
      blue:
        instance_id: i-auto-prod-blue
        private_ip: 172.16.2.30
        public_ip: 54.26.27.28
      green:
        instance_id: i-auto-prod-green
        private_ip: 172.16.2.40
        public_ip: 54.29.30.31
      rds_host: auto-prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Auto-detect standard (no strategy field) ────────────────────
  F_AUTO_STD="${TMPDIR}/auto-standard.yaml"
  cat > "$F_AUTO_STD" << EOF
name: myapp
deployment:
  ip_access: private
  region: us-east-1
  ${PLATFORM_KEY}:
    staging:
      method: ssh
      instance_id: i-auto-std-staging
      private_ip: 10.0.2.100
      public_ip: 52.10.11.12
      rds_host: auto-std-staging.rds.example.com
      containers: [frontend]
    production:
      method: ssh
      instance_id: i-auto-std-prod
      private_ip: 10.0.2.200
      public_ip: 52.13.14.15
      rds_host: auto-std-prod.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Auto-detect single (no strategy field) ───────────────────────
  F_AUTO_SINGLE="${TMPDIR}/auto-single.yaml"
  cat > "$F_AUTO_SINGLE" << EOF
name: myapp
deployment:
  ip_access: public
  region: us-east-2
  ${PLATFORM_KEY}:
    server:
      method: ssh
      instance_id: i-auto-single
      private_ip: 192.168.2.100
      public_ip: 54.200.201.202
      rds_host: auto-single.rds.example.com
      containers: [frontend]
EOF

  # ── Fixture: Auto-detect none (no strategy field, no servers) ─────────────
  F_AUTO_NONE="${TMPDIR}/auto-none.yaml"
  cat > "$F_AUTO_NONE" << 'EOF'
name: myapp
EOF
}

teardown() {
  rm -rf "$TMPDIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# STRATEGY: blue-green
# ─────────────────────────────────────────────────────────────────────────────

# ── deploy-ip ──────────────────────────────────────────────────────────────

@test "bg: deploy-ip returns active (green) private IP for staging" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "172.16.1.20" ]  # green is active in staging
}

@test "bg: deploy-ip returns active (blue) private IP for production" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "172.16.1.30" ]  # blue is active in production
}

@test "bg: deploy-ip --color inactive returns inactive private IP" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env staging --color inactive
  [ "$status" -eq 0 ]
  [ "$output" = "172.16.1.10" ]  # blue is inactive in staging
}

@test "bg: deploy-ip --color blue returns blue private IP" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env staging --color blue
  [ "$status" -eq 0 ]
  [ "$output" = "172.16.1.10" ]
}

@test "bg: deploy-ip --color green returns green private IP" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env staging --color green
  [ "$status" -eq 0 ]
  [ "$output" = "172.16.1.20" ]
}

@test "bg: deploy-ip uses public IP when ip_access=public" {
  run "$SCRIPT" --deploy-ip --file "$F_BG_PUB" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "54.4.5.6" ]  # green public IP
}

@test "bg: deploy-ip --ip-type public overrides ip_access=private" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env staging --ip-type public
  [ "$status" -eq 0 ]
  [ "$output" = "54.4.5.6" ]  # green public IP
}

@test "bg: deploy-ip --ip-type private overrides ip_access=public" {
  run "$SCRIPT" --deploy-ip --file "$F_BG_PUB" --env staging --ip-type private
  [ "$status" -eq 0 ]
  [ "$output" = "172.16.1.20" ]  # green private IP
}

# ── deploy-instance ────────────────────────────────────────────────────────

@test "bg: deploy-instance returns active (green) instance for staging" {
  run "$SCRIPT" --deploy-instance --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "i-stg-green" ]
}

@test "bg: deploy-instance returns active (blue) instance for production" {
  run "$SCRIPT" --deploy-instance --file "$F_BG" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "i-prod-blue" ]
}

@test "bg: deploy-instance --color inactive returns inactive instance" {
  run "$SCRIPT" --deploy-instance --file "$F_BG" --env staging --color inactive
  [ "$status" -eq 0 ]
  [ "$output" = "i-stg-blue" ]
}

@test "bg: deploy-instance --color green returns green instance" {
  run "$SCRIPT" --deploy-instance --file "$F_BG" --env production --color green
  [ "$status" -eq 0 ]
  [ "$output" = "i-prod-green" ]
}

# ── deploy-method ──────────────────────────────────────────────────────────

@test "bg: deploy-method returns env-level method" {
  run "$SCRIPT" --deploy-method --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "ssm" ]
}

@test "bg: deploy-method falls back to top-level method when env-level absent" {
  run "$SCRIPT" --deploy-method --file "$F_BG_METHOD_TOP" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "ssh" ]
}

# ── deploy-region (3-level fallback) ──────────────────────────────────────

@test "bg: deploy-region from top-level (level 3)" {
  run "$SCRIPT" --deploy-region --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "us-west-1" ]
}

@test "bg: deploy-region from env level (level 2) overrides top-level" {
  run "$SCRIPT" --deploy-region --file "$F_BG_REGION_ENV" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "eu-west-1" ]
}

@test "bg: deploy-region from color level (level 1) overrides env-level" {
  run "$SCRIPT" --deploy-region --file "$F_BG_REGION_COLOR" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "ap-southeast-1" ]
}

@test "bg: deploy-region errors when not configured at any level" {
  run "$SCRIPT" --deploy-region --file "$F_BG_NO_REGION" --env staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"region"* ]]
}

# ── deploy-rds-host ────────────────────────────────────────────────────────

@test "bg: deploy-rds-host returns staging RDS hostname" {
  run "$SCRIPT" --deploy-rds-host --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "staging.rds.example.com" ]
}

@test "bg: deploy-rds-host returns production RDS hostname" {
  run "$SCRIPT" --deploy-rds-host --file "$F_BG" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "prod.rds.example.com" ]
}

# ── deploy-containers ──────────────────────────────────────────────────────

@test "bg: deploy-containers returns staging container list" {
  run "$SCRIPT" --deploy-containers --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontend"* ]]
  [[ "$output" == *"backend"* ]]
}

@test "bg: deploy-containers returns production container list (includes worker)" {
  run "$SCRIPT" --deploy-containers --file "$F_BG" --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker"* ]]
}

# ── deploy-firebase ────────────────────────────────────────────────────────

@test "bg: deploy-firebase returns staging firebase project" {
  run "$SCRIPT" --deploy-firebase --file "$F_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "myapp-staging" ]
}

@test "bg: deploy-firebase returns production firebase project" {
  run "$SCRIPT" --deploy-firebase --file "$F_BG" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "myapp-production" ]
}

# ── Error cases ────────────────────────────────────────────────────────────

@test "bg: error when active field missing (deploy-ip with --color active)" {
  run "$SCRIPT" --deploy-ip --file "$F_BG_NO_ACTIVE" --env staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"active"* ]]
}

@test "bg: error when active field missing (deploy-instance)" {
  run "$SCRIPT" --deploy-instance --file "$F_BG_NO_ACTIVE" --env staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"active"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# STRATEGY: standard
# ─────────────────────────────────────────────────────────────────────────────

@test "std: deploy-ip returns staging private IP" {
  run "$SCRIPT" --deploy-ip --file "$F_STANDARD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "10.0.1.100" ]
}

@test "std: deploy-ip returns production private IP" {
  run "$SCRIPT" --deploy-ip --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "10.0.1.200" ]
}

@test "std: deploy-ip --ip-type public returns public IP" {
  run "$SCRIPT" --deploy-ip --file "$F_STANDARD" --env staging --ip-type public
  [ "$status" -eq 0 ]
  [ "$output" = "52.1.2.3" ]
}

@test "std: deploy-instance returns staging instance" {
  run "$SCRIPT" --deploy-instance --file "$F_STANDARD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "i-std-staging" ]
}

@test "std: deploy-instance returns production instance" {
  run "$SCRIPT" --deploy-instance --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [ "$output" = "i-std-prod" ]
}

@test "std: deploy-region from top-level default" {
  run "$SCRIPT" --deploy-region --file "$F_STANDARD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "us-east-1" ]
}

@test "std: deploy-rds-host returns staging RDS" {
  run "$SCRIPT" --deploy-rds-host --file "$F_STANDARD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "std-staging.rds.example.com" ]
}

@test "std: deploy-firebase returns staging firebase project" {
  run "$SCRIPT" --deploy-firebase --file "$F_STANDARD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "myapp-std-staging" ]
}

@test "std: deploy-containers production includes worker" {
  run "$SCRIPT" --deploy-containers --file "$F_STANDARD" --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# STRATEGY: single
# ─────────────────────────────────────────────────────────────────────────────

@test "single: deploy-ip returns server public IP (ip_access=public)" {
  run "$SCRIPT" --deploy-ip --file "$F_SINGLE"
  [ "$status" -eq 0 ]
  [ "$output" = "54.100.101.102" ]
}

@test "single: deploy-ip --ip-type private returns private IP" {
  run "$SCRIPT" --deploy-ip --file "$F_SINGLE" --ip-type private
  [ "$status" -eq 0 ]
  [ "$output" = "192.168.1.100" ]
}

@test "single: deploy-ip ignores --env (same server regardless)" {
  run "$SCRIPT" --deploy-ip --file "$F_SINGLE" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "54.100.101.102" ]
}

@test "single: deploy-instance returns server instance ID" {
  run "$SCRIPT" --deploy-instance --file "$F_SINGLE"
  [ "$status" -eq 0 ]
  [ "$output" = "i-single-server" ]
}

@test "single: deploy-region from top-level" {
  run "$SCRIPT" --deploy-region --file "$F_SINGLE"
  [ "$status" -eq 0 ]
  [ "$output" = "us-east-2" ]
}

@test "single: deploy-method returns server method" {
  run "$SCRIPT" --deploy-method --file "$F_SINGLE"
  [ "$status" -eq 0 ]
  [ "$output" = "ssh" ]
}

@test "single: deploy-rds-host returns server RDS" {
  run "$SCRIPT" --deploy-rds-host --file "$F_SINGLE"
  [ "$status" -eq 0 ]
  [ "$output" = "single.rds.example.com" ]
}

@test "single: deploy-containers returns server containers" {
  run "$SCRIPT" --deploy-containers --file "$F_SINGLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"frontend"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# STRATEGY: none (pipeline-only)
# ─────────────────────────────────────────────────────────────────────────────

@test "none: deploy-ip returns 'pipeline'" {
  run "$SCRIPT" --deploy-ip --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: deploy-instance returns 'pipeline'" {
  run "$SCRIPT" --deploy-instance --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: deploy-method returns 'pipeline'" {
  run "$SCRIPT" --deploy-method --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: deploy-region returns 'pipeline'" {
  run "$SCRIPT" --deploy-region --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: deploy-rds-host returns 'pipeline'" {
  run "$SCRIPT" --deploy-rds-host --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: deploy-containers returns 'pipeline'" {
  run "$SCRIPT" --deploy-containers --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: deploy-firebase returns 'pipeline'" {
  run "$SCRIPT" --deploy-firebase --file "$F_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

@test "none: --env and --color are ignored, always returns 'pipeline'" {
  run "$SCRIPT" --deploy-ip --file "$F_NONE" --env staging --color inactive
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# STRATEGY AUTO-DETECTION (no explicit strategy field)
# ─────────────────────────────────────────────────────────────────────────────

@test "auto-detect: has active field → blue-green" {
  run "$SCRIPT" --deploy-instance --file "$F_AUTO_BG" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "i-auto-stg-green" ]  # green is active → confirmed blue-green behavior
}

@test "auto-detect: has env-level instance_id → standard" {
  run "$SCRIPT" --deploy-instance --file "$F_AUTO_STD" --env staging
  [ "$status" -eq 0 ]
  [ "$output" = "i-auto-std-staging" ]
}

@test "auto-detect: has server-level instance_id → single" {
  run "$SCRIPT" --deploy-instance --file "$F_AUTO_SINGLE"
  [ "$status" -eq 0 ]
  [ "$output" = "i-auto-single" ]
}

@test "auto-detect: no deployment structure → none (returns pipeline)" {
  run "$SCRIPT" --deploy-ip --file "$F_AUTO_NONE"
  [ "$status" -eq 0 ]
  [ "$output" = "pipeline" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

@test "invalid --env value: exits with code 3" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --env dev
  [ "$status" -eq 3 ]
  [[ "$output" == *"--env must be staging or production"* ]]
}

@test "invalid --color value: exits with code 3" {
  run "$SCRIPT" --deploy-ip --file "$F_BG" --color purple
  [ "$status" -eq 3 ]
  [[ "$output" == *"--color must be"* ]]
}

@test "no field specified: exits with code 3" {
  run "$SCRIPT" --file "$F_BG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"No field specified"* ]]
}

@test "unknown field: exits with code 3" {
  run "$SCRIPT" --deploy-foobar --file "$F_BG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"Unknown"* ]]
}

@test "PROJECT.yaml missing: exits with code 2" {
  run "$SCRIPT" --deploy-ip --file "/nonexistent/PROJECT.yaml"
  [ "$status" -eq 2 ]
}
