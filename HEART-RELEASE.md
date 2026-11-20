# Verify Minoa Heart queue coverage

Run the release preflight against the chart, intended schedule rows, staged OCI
definitions and worker images that the candidate will use. A failure blocks
release sign-off. The script renders the checked-in Minoa chart and optional
candidate override file locally with Argo CD's release name `minoa` and
namespace `minoa-bank`. It performs no Argo CD sync or database writes.

## Prepare the candidate inputs

1. Build `check-heart-release` from the candidate Core revision with
   `cargo build --locked -p definitions-service --bin check-heart-release`.
2. Export all schedule rows after applying candidate migrations to a restored
   or release-verification database. For a new instance, use the packaged
   chart's migration and seed. Keep the disabled rows so the report identifies
   deliberate exclusions.

   ```sh
   psql -XAt -v ON_ERROR_STOP=1 -f scripts/export-heart-schedules.sql > schedules.json
   ```

   Connect with read-only credentials. The export includes the mandatory
   schedule dependencies as well as enabled and disabled jobs.
3. Stage the exact YAML artifacts selected for this release in a directory.
   Use the candidate OCI digests and the instance's enabled manifest entries.
   Keep different versions in separate files. The checker resolves each
   schedule against the YAML's actual namespace, name and version.
   The savings fan-out schedule also requires `default/daily-savings-interest:1.0.0`,
   which the Core worker starts for each agreement. Include that child artifact
   and the images that handle its calculation and settlement queues.
4. Obtain a queue report from each worker image that should cover the plans.
   Use the exact image reference and the Heart namespace rendered by Helm.
   Workers without an explicit namespace use `default`. Collect the reports
   into a JSON array with an `image` field on each item.

   ```sh
   docker run --rm --network=none --entrypoint /usr/local/bin/service \
     -e HEART_NAMESPACE=default "$ACCOUNTING_IMAGE" --print-heart-queues |
     jq --arg image "$ACCOUNTING_IMAGE" '. + {image: $image}' > accounting-worker.json
   jq -s . accounting-worker.json core-worker.json > workers.json
   ```

   Core, Admin and Payment images use `/usr/local/bin/core-api`,
   `/usr/local/bin/admin-api` and `/usr/local/bin/payment-engine`,
   respectively. The Treasury worker uses `/usr/local/bin/service` like
   Accounting. For an older image or another module, obtain the queue
   inventory from the owner of that exact image before counting it as
   evidence. Do not substitute a different image tag or source revision.

## Release check

```sh
./scripts/check-heart-release.sh \
  /path/to/check-heart-release schedules.json staged-definitions/ workers.json
```

An optional final argument adds candidate Helm values on top of the checked-in
Minoa values. For each enabled schedule, every queue task must have a matching
worker on the same Heart endpoint and namespace. A scaled-down deployment, a
missing definition or an inventory from another image cannot provide coverage.
A deliberately disabled schedule is shown as `SKIP`. An enabled schedule with
missing coverage prints its exact process, node, queue and candidate images and
returns nonzero. The gate also rejects an enabled recurring plan whose mandatory
recurring prerequisite is disabled or missing from the export. The stock
closed-day calendar leaves the new savings batch disabled while EOD requires it.
Keep dependent jobs parked while preparing the pilot, or include the approved
enabled savings plan in the candidate inputs. Retain the report with release
sign-off.

## Verify an Accounting release candidate

Accounting's normal **CI — Build & Publish** job reports a candidate worker
image and a Heart manifest, both pinned by SHA-256. Use those two references
from the same job. Add the worker's complete `git-…@sha256:…` suffix to a
local candidate values file as `bjoroy-bank.accounting.accountingApi.imageTag`.
Keep the ordinary Minoa registry and the other candidate chart overrides.
For month-end, use the candidate umbrella chart with the Accounting chart
that renders `accountingApi.bankTimezone`. Minoa sets this to `Europe/Oslo`
and preflight checks the actual deployment environment. The currently checked-in
umbrella `0.12.93` does not render this setting.

Authenticate Docker and ORAS to the OCI registry. Use a Docker host that can
run the published worker architecture (ARM64), and install Helm, ORAS, jq,
Python 3 and PyYAML. Prepare the schedule export as above. Supply staged Core
and Treasury definitions and queue reports for the other worker images, omitting
Accounting definitions and the Accounting worker report.

```sh
./scripts/check-accounting-heart-candidate.sh \
  /path/to/check-heart-release schedules.json "$ACCOUNTING_MANIFEST" \
  other-definitions/ other-workers.json candidate-values.yaml
```

The script pulls each Accounting artifact by digest, checks the YAML identity
and content hash, and runs the exact rendered Accounting image to list its
registered queues. Retain the image and manifest digests and the preflight
report together for release review.

## Stage the reviewed definition for Minoa

After the coverage check, copy each selected artifact from Accounting's
candidate repository into the corresponding Minoa instance repository, using
the digest from the reviewed candidate manifest. For month-end close:

```sh
oras cp "$REGISTRY/bank-platform/accounting/month-end-batch@$DEFINITION_DIGEST" \
        "$REGISTRY/minoa/accounting/month-end-batch:git-$ACCOUNTING_REVISION"
oras manifest fetch --descriptor \
  "$REGISTRY/minoa/accounting/month-end-batch@$DEFINITION_DIGEST"
```

Record the selection in a reviewed copy of the existing Minoa Accounting
manifest. Preserve its existing production and replaced entries. Check that
there is only one candidate for `month-end-batch` before promotion. The new
entry uses name `month-end-batch`, the version from the reviewed artifact,
state `candidate` and ref `accounting/month-end-batch@sha256:…` with the copied
digest. Use a definitions-service build that supports digest references before
publishing this instance manifest. The existing Accounting definitions
promotion endpoint loads the pinned artifact into Heart. Schedule activation
and the Helm image pin go through the normal reviewed release.

## Verify Minoa and Isdalen separately

Rocket's Argo CD ApplicationSet takes Minoa from the `minoa-bank` branch and
uses release name `minoa` in namespace `minoa-bank`. It takes Isdalen from
`isdalen` and uses `isdalen` as both release name and namespace. The instance
IDs used for databases and OCI are `minoa` and `isdalen`. The checked-in
ApplicationSet requires a sync operation for each bank. Check the live
Application before changing its Git branch to confirm the effective sync policy.

Capture each application's deployed Git revision, actual pod image digests
and existing enabled schedule export. Record the existing OCI manifest digest
for each domain. Use a separate restored database and verification output
directory per bank. Before migration, obtain a recoverable checkpoint for the
bank, Heart, Accounting and Treasury databases. Quiesce the writers before
taking the checkpoint and prove the restore outside the target. The database
names in the rendered chart are `<instance>_bank`, `<instance>_heart`,
`<instance>_accounting` and `<instance>_treasury`.

To verify Isdalen's published candidate against its own exported plans, pass
its wrapper chart, release name and namespace to the same script:

```sh
./scripts/check-accounting-heart-candidate.sh \
  /path/to/check-heart-release isdalen-schedules.json "$ACCOUNTING_MANIFEST" \
  other-definitions/ isdalen-workers.json isdalen-candidate-values.yaml \
  /path/to/isdalen-chart isdalen isdalen
```

After sync, check each application's sync revision and health, the Core and
Accounting migration job logs, the actual running image IDs, and Heart
readiness. Before starting a new schedule, confirm the live Heart keyed
lookup route gives the expected explicit key-not-found response for a fresh
key and that the exact workflow versions can be read. Use the scheduler and
Accounting logs, admin schedule runs and open alerts to verify the first
selected date. Preserve run IDs, terminal outcomes and posted ledger evidence.

Before financial work resumes, rollback can restore the recorded Git and OCI
manifest revisions and verify that prior pods are running. After migration or
posting, keep dispatch paused and reconcile the run journal and ledger before
choosing a database or definition recovery point. Reverting Git changes alone
does not revert committed database work.

## Approve and apply the deposit opening

Use two reviewed instance revisions. The first sets
`bjoroy-bank.bankCalendarCutover.version` to `deposit-interest-v1` and enables
`bjoroy-bank.accounting.accountingApi.requireDepositOpening`. Keep
`openingApproval` empty. This revision prepares the Core opening while the
scheduler and Accounting imports wait. Sync the reviewed definitions to
Heart before the preparation job runs.

After the first sync, an authenticated ledger operator can read
`GET /api/schedules/calendar-activation` through the normal admin host. Use the
returned `bank_instance_id`, `bank_timezone` and `first_bank_date` to read
`GET /accounting-api/deposit-opening/plan` with the same operator session. The
plan contains per-currency differences and its SHA-256 digest. Review the plan
for each bank before approval.

The second revision supplies `bankInstanceId`, `firstBankDate`, `sha256` and
`approvedBy` under `bjoroy-bank.bankCalendarCutover.openingApproval`. Record the
approval or change reference in `approvedBy`. The Accounting apply job checks
the digest before any new posting. The following verification job matches the
committed Accounting receipt to the Core opening, bank and approved date.
Only that final receipt releases dispatch. Recheck
`/api/schedules/calendar-activation` for `opening_applied: true` and the reviewed
`opening_sha256` after the second sync. Keep the reviewed revisions and opening
receipts with the release evidence.
