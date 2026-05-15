#!/usr/bin/env bats

# Test suite for analyze-config-usage.sh
# Covers: duplicate pattern detection, verification mode

setup() {
    # Create temp directory for test scripts
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p scripts/lib

    # Copy the analyze script
    cp "$BATS_TEST_DIRNAME/../analyze-config-usage.sh" scripts/
    chmod +x scripts/analyze-config-usage.sh

    # Create dummy lib/project-config.sh (not tested, just needed for sourcing)
    touch scripts/lib/project-config.sh
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# No duplicates found
# =============================================================================

@test "analyze: exits 0 when no duplicates found" {
    # Create script with unique pattern
    cat > scripts/unique.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    unique_field=.some.unique.path)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 0 ]
    [[ "$output" =~ "✓ No duplicates found" ]]
}

@test "analyze: exits 0 when only one script exists" {
    cat > scripts/only-one.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 0 ]
    [[ "$output" =~ "✓ No duplicates found" ]]
}

@test "analyze: exits 0 when scripts have different patterns" {
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config app_name=.name)
EOF

    cat > scripts/script2.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 0 ]
    [[ "$output" =~ "✓ No duplicates found" ]]
}

# =============================================================================
# Duplicates found
# =============================================================================

@test "analyze: exits 1 when duplicates found (2 scripts)" {
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    backend=.secrets.backend)
EOF

    cat > scripts/script2.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Found 2 scripts with pattern" ]]
    [[ "$output" =~ "app_name backend" ]]
}

@test "analyze: exits 1 when duplicates found (3 scripts)" {
    # Create 3 scripts with identical pattern
    for i in 1 2 3; do
        cat > "scripts/script${i}.sh" << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    secrets_backend=.secrets.backend)
EOF
    done

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Found 3 scripts with pattern" ]]
    [[ "$output" =~ "app_name secrets_backend" ]]
}

@test "analyze: detects multiple duplicate patterns" {
    # Pattern 1: app_name + backend (2 scripts)
    cat > scripts/rotate1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    cat > scripts/rotate2.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    # Pattern 2: host + port (2 scripts)
    cat > scripts/deploy1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config host=.deployment.staging.host port=.deployment.staging.port)
EOF

    cat > scripts/deploy2.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config host=.deployment.staging.host port=.deployment.staging.port)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "app_name backend" ]]
    [[ "$output" =~ "host port" ]]
    [[ "$output" =~ "Summary: 2 duplicate patterns" ]]
}

# =============================================================================
# Pattern detection edge cases
# =============================================================================

@test "analyze: ignores scripts in lib/ directory" {
    mkdir -p scripts/lib

    # Create duplicate in lib (should be ignored)
    cat > scripts/lib/helper.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    # Create duplicate in scripts (should be detected if another exists)
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 0 ]
    [[ "$output" =~ "✓ No duplicates found" ]]
}

@test "analyze: ignores analyze-config-usage.sh itself" {
    # The analyze script itself won't be scanned
    cat > scripts/other.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config test=.test)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 0 ]
}

@test "analyze: handles multiline get_project_config calls" {
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config \
    field1=.path.one \
    field2=.path.two \
    field3=.path.three)
EOF

    cat > scripts/script2.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config \
    field1=.path.one \
    field2=.path.two \
    field3=.path.three)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "field1 field2 field3" ]]
}

@test "analyze: normalizes whitespace in patterns" {
    # Script 1 with extra spaces
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config \
    app_name=.name    \
    backend=.secrets.backend   )
EOF

    # Script 2 with minimal spacing
    cat > scripts/script2.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Found 2 scripts with pattern" ]]
}

@test "analyze: alphabetically sorts keys within pattern" {
    # Script 1 with fields in one order
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config \
    backend=.secrets.backend \
    app_name=.name)
EOF

    # Script 2 with fields in different order
    cat > scripts/script2.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config \
    app_name=.name \
    backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Found 2 scripts with pattern" ]]
    # Pattern should be normalized (sorted): app_name backend
    [[ "$output" =~ "app_name backend" ]]
}

# =============================================================================
# Mode flags
# =============================================================================

@test "analyze: --verify mode always exits 0" {
    # Even with duplicates, verify mode exits 0 (for now)
    cat > scripts/script1.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    cat > scripts/script2.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --verify

    [ "$status" -eq 0 ]
    [[ "$output" =~ "✓ Config patterns verified" ]]
}

@test "analyze: --cache-only mode returns empty JSON" {
    run scripts/analyze-config-usage.sh --cache-only

    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

@test "analyze: --full is default mode" {
    cat > scripts/test.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config test=.test)
EOF

    run scripts/analyze-config-usage.sh scripts

    [ "$status" -eq 0 ]
    [[ "$output" =~ "Scanning for duplicate" ]]
}

# =============================================================================
# Output format
# =============================================================================

@test "analyze: shows script filenames when duplicates found" {
    cat > scripts/rotate-database.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    cat > scripts/rotate-generic.sh << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config app_name=.name backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "rotate-database.sh" ]]
    [[ "$output" =~ "rotate-generic.sh" ]]
}

@test "analyze: shows count of duplicate scripts" {
    for i in 1 2 3 4; do
        cat > "scripts/script${i}.sh" << 'EOF'
#!/usr/bin/env bash
CONFIG=$(get_project_config same=.same)
EOF
    done

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Found 4 scripts with pattern" ]]
}

# =============================================================================
# Real-world scenarios
# =============================================================================

@test "analyze: detects app_name + secrets_backend pattern (3 scripts)" {
    # Simulate the real pattern we found
    cat > scripts/rollback-secret.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    secrets_backend=.secrets.backend)
EOF

    cat > scripts/rotate-database.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    secrets_backend=.secrets.backend)
EOF

    cat > scripts/rotate-generic.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_project_config \
    app_name=.name \
    secrets_backend=.secrets.backend)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Found 3 scripts with pattern" ]]
    [[ "$output" =~ "app_name secrets_backend" ]]
}

@test "analyze: after helper migration, no duplicates remain" {
    # Simulate after applying get_app_secrets_config() helper
    cat > scripts/rollback-secret.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_app_secrets_config)
EOF

    cat > scripts/rotate-database.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_app_secrets_config)
EOF

    cat > scripts/rotate-generic.sh << 'EOF'
#!/usr/bin/env bash
source lib/project-config.sh
CONFIG=$(get_app_secrets_config)
EOF

    run scripts/analyze-config-usage.sh --full scripts

    [ "$status" -eq 0 ]
    [[ "$output" =~ "✓ No duplicates found" ]]
}
