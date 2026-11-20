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

   ```sql
   SELECT COALESCE(json_agg(plan ORDER BY plan.name), '[]'::json)
   FROM (
       SELECT name, definition_namespace, definition_name, definition_version, enabled
       FROM admin.schedules
   ) AS plan;
   ```

   Run the query with `psql -XAt -v ON_ERROR_STOP=1` to save raw JSON.
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
   respectively. For an older image or another module, obtain the queue
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
returns nonzero. The report covers the provided candidate evidence and can be
retained with release sign-off.
