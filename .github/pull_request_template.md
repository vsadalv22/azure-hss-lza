## Summary

<!-- Describe WHAT changed and WHY. Link to the GitHub Issue or design decision. -->

Closes #<!-- issue number -->

## Type of Change

- [ ] 🔧 Bug fix (non-breaking)
- [ ] ✨ New feature / module
- [ ] 💥 Breaking change (module interface or topology change)
- [ ] 📋 Policy change
- [ ] 🔒 Security hardening
- [ ] 📝 Documentation only
- [ ] 🔄 Refactor (no functional change)

## Checklist

### Code Quality
- [ ] Bicep lint passes locally (`az bicep lint --file <file>`)
- [ ] No hardcoded IPs or passwords in any file
- [ ] All new params have `@description()` decorators
- [ ] All new string params with known patterns have `@pattern()` validators
- [ ] `effectiveTags` / `tags` applied to all new resources

### Security
- [ ] No secrets committed (Gitleaks scan passes)
- [ ] Checkov scan passes (or suppressions documented in `.checkov.yaml`)
- [ ] New resources have diagnostic settings → Log Analytics
- [ ] New critical resources have CanNotDelete resource lock

### Testing
- [ ] What-if run completed and output reviewed (paste summary below)
- [ ] Tested in `dev` branch before raising to `main`
- [ ] No unexpected resource deletions in what-if output

### Documentation
- [ ] `CHANGELOG.md` updated with this change
- [ ] Runbook / docs updated if operational steps changed
- [ ] `docs/avm-module-versions.md` updated if AVM versions changed

## What-If Summary

```
<!-- Paste abbreviated az deployment what-if output here -->
```

## Rollback Plan

<!-- What is the safe rollback if this breaks production? -->
