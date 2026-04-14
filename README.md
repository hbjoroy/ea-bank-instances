# ea-bank-instances

GitOps deployment repository for Bjorøy Bank instances. Each branch represents
a deployable bank instance, managed by ArgoCD.

## Architecture

```
main branch           — shared config, ArgoCD ApplicationSet, templates
├── argocd/           — ApplicationSet + Project manifests
└── templates/        — starter Chart.yaml + values for new instances

Instance branches (one per bank):
├── minoa-bank        → ArgoCD app "minoa-bank"    (Minoa Bank)
├── isdalen           → ArgoCD app "isdalen"        (Isdalen Bank)
└── bragd-rtgs        → ArgoCD app "bragd-rtgs"     (Bragd Central Bank)
```

## Wrapper Chart Pattern

Each instance branch contains a Helm "wrapper chart" that references the main
bank chart as an OCI dependency:

```
Chart.yaml     — declares bjoroy-bank (or bragd-rtgs-chart) as a dependency
values.yaml    — instance-specific overrides (instanceId, domain, bankId, etc.)
```

To update an instance:
1. Bump the dependency version in `Chart.yaml`
2. Adjust `values.yaml` if needed
3. Open a PR to the instance branch
4. Review + merge → ArgoCD auto-syncs → Helm upgrade

## Adding a New Bank Instance

1. Create a new branch from `main`
2. Copy `templates/Chart.yaml` and `templates/values.yaml`
3. Edit with your instance details (instanceId, domain, IBAN prefix, etc.)
4. Push the branch — ArgoCD ApplicationSet discovers it automatically
5. The new bank deploys to a namespace matching the branch name

## ArgoCD Setup

Apply the ApplicationSet manifest (requires ArgoCD installed in cluster):

```bash
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/applicationset.yaml
```

## Repository Layout

| Path | Purpose |
|------|---------|
| `argocd/project.yaml` | ArgoCD project with RBAC |
| `argocd/applicationset.yaml` | Git branch generator — one app per branch |
| `templates/values.yaml` | Starter values for new bank instances |
| `templates/Chart.yaml` | Starter wrapper chart |

## Related Repositories

| Repo | Description |
|------|-------------|
| [ea-bank-core](https://github.com/SparebankenVest/ea-bank-core) | Core banking platform (images + bjoroy-bank chart) |
| [ea-bragd-rtgs](https://github.com/hbjoroy/ea-bragd-rtgs) | Bragd Central Bank (RTGS/INST clearing) |
| [ea-bank-docs](https://github.com/SparebankenVest/ea-bank-docs) | Documentation (Hugo site) |
