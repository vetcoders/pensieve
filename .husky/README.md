# .husky/ (managed by vibecrafted-hooks-template)

Hooks here are installed from `vibecrafted/templates/hooks/`.

- Activator: **lefthook**
- Tweak behavior in `config.env` (opt-in flags).
- Drop repo-specific extensions in `local/<hook>.d/*.sh` (auto-discovered).
- Failed warn logs land in `warns/` (gitignored, rolling retention).

Re-run the installer to refresh:

```
bash /path/to/vibecrafted/templates/hooks/install.sh --activator lefthook
```

Switch activator: re-run with a different `--activator` flag and remove
the old activator's config file at repo root (`lefthook.yml` /
`.pre-commit-config.yaml`).
