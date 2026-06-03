---
name: release
description: Create a new release by bumping version and updating changelog
tags: [release, version, changelog]
---

# Release Skill

This skill automates the release process for the VMware Migration Kit by:
1. Determining the next version number
2. Updating all version references
3. Collecting changelog entries from recent commits or user input
4. Creating a release commit

## Usage

```
/release [VERSION] [--changelog "Changelog entry 1" "Entry 2" ...]
```

**Arguments:**
- `VERSION` (optional): Specific version to release (e.g., `2.2.5`, `2.3.0`, `3.0.0`). If omitted, auto-increments patch version.
- `--changelog` (optional): List of changelog entries. If omitted, will prompt for entries or extract from recent commits.

## Examples

```bash
# Auto-increment patch version (2.2.4 → 2.2.5) and prompt for changelog
/release

# Specific version with changelog entries
/release 2.3.0 --changelog "Major refactor of migration engine" "Add support for vSphere 9"

# Minor version bump, interactive changelog
/release 2.3.0
```

## What it does

1. **Read current version** from `galaxy.yml`
2. **Determine next version**:
   - If VERSION provided: use it
   - If not: increment patch (e.g., 2.2.4 → 2.2.5)
3. **Collect changelog entries**:
   - If `--changelog` provided: use those entries
   - If not: analyze recent commits since last version tag or ask user
4. **Update files**:
   - `galaxy.yml`: version field
   - `CHANGELOG.md`: add new version section with entries
   - `aee/execution-environment.yml`: tarball reference
   - `aee/requirements.yml`: collection source path
5. **Create git commit** (optional): "Bump release to vX.Y.Z"

## Files Modified

- `galaxy.yml`
- `CHANGELOG.md`
- `aee/execution-environment.yml`
- `aee/requirements.yml`

## Prerequisites

- Must be on a clean git branch
- Must have write access to the repository

---

# Implementation

You are responsible for:

1. **Reading the current version** from `galaxy.yml` (line 3: `version: X.Y.Z`)

2. **Parsing the version argument** (if provided) or auto-incrementing:
   ```
   Current: 2.2.4
   Auto-increment patch: 2.2.5
   Minor bump: 2.3.0
   Major bump: 3.0.0
   ```

3. **Getting changelog entries** by either:
   - Using provided `--changelog` entries
   - Analyzing git commits since last version tag: `git log v2.2.4..HEAD --oneline`
   - Asking the user with AskUserQuestion

4. **Updating galaxy.yml**:
   ```yaml
   version: 2.2.5  # old: 2.2.4
   ```

5. **Updating CHANGELOG.md** by adding new section at the end:
   ```markdown
   ## v2.2.5
   
   - Changelog entry 1
   - Changelog entry 2
   - Changelog entry 3
   ```

6. **Updating aee/execution-environment.yml**:
   ```yaml
   additional_build_files:
     - src: ../os_migrate-vmware_migration_kit-2.2.5.tar.gz  # old: 2.2.4
       dest: tmp/
   ```

7. **Updating aee/requirements.yml**:
   ```yaml
   - name: os_migrate.vmware_migration_kit
     type: file
     source: tmp/os_migrate-vmware_migration_kit-2.2.5.tar.gz  # old: 2.2.4
   ```

8. **Creating a git commit** (ask user first):
   ```bash
   git add galaxy.yml CHANGELOG.md aee/execution-environment.yml aee/requirements.yml
   git commit -m "Bump release to v2.2.5"
   ```

9. **Show summary** of what was changed and next steps (e.g., "Push and create PR")

## Important Notes

- **Always validate the version format**: Must be semantic versioning (MAJOR.MINOR.PATCH)
- **Preserve changelog formatting**: Follow existing CHANGELOG.md structure
- **Check for unreleased changes**: If no commits since last tag and no changelog provided, warn the user
- **Don't create git tag**: The tag should be created manually or by CI after PR merge
- **Verify current branch**: Warn if on `main` branch (should create feature branch first)

## Error Handling

- If version already exists in CHANGELOG.md: error and exit
- If no changelog entries provided/found: prompt user
- If uncommitted changes exist: warn user
- If version format invalid: error with example
