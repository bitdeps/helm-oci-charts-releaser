# _OCI charts releaser_ Action

A GitHub action for single chart or multi-chart repositories that performs push and github releases creation for the hosted charts.

## Usage

### Pre-requisites

1. A GitHub repo containing a directory with your Helm charts (one of the following folders named `/charts`, `/chart` or `helm`, if you want
   to maintain your charts in a different directory, you must include a `charts_dir` input in the workflow).
1. Create a workflow `.yml` file in your `.github/workflows` directory. An [example workflow](#example-workflow) is available below.
   For more information, reference the GitHub Help Documentation for [Creating a workflow file](https://help.github.com/en/articles/configuring-a-workflow#creating-a-workflow-file)

### Inputs

- `version`: The helm version to use (default: v3.13.2)
- `charts_dir`: The charts directory
- **`oci_registry`**: The OCI registry host
- **`oci_username`**: The username used to login to the OCI registry
- **`oci_password`**: The OCI user's password
- **`github-token`**: Github Actions token must be provided to manage release creation and update.
- `name_pattern`: Modifies repository and release tag naming. For instance you chart is named as app, but you want it to be released to GH and pushed into OCI as app-chart, you can set *name_pattern* to `{chartName}-chart`.
- `skip_helm_install`: Skip helm installation (default: false)
- `skip_dependencies`: Skip dependencies update from "Chart.yaml" to dir "charts/" before packaging (default: false)
- `skip_existing`: Skip package upload if release/tag already exists
- `mark_as_latest`: When you set this to `false`, it will mark the created GitHub release not as 'latest'.

### Outputs

- `changed_charts`: A comma-separated list of charts that were released on this run. Will be an empty string if no updates were detected, will be unset if `--skip_packaging` is used: in the latter case your custom packaging step is responsible for setting its own outputs if you need them.
- `chart_version`: The version of the most recently generated charts; will be set even if no charts have been updated since the last run.

### Example Workflow

Create a workflow (eg: `.github/workflows/release.yml`):

```yaml
name: Release Charts

on:
  push:
    branches:
      - main

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
        with:
          fetch-depth: 0

      - name: Configure Git
        run: |
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"

      - name: Run chart-releaser
        uses: bitdeps/charts-releaser-action@v0.1.0
        with:
            oci_registry: oci://gchr.io/myuser/charts-repo
            oci_username: registry-user
            ocu_password: ${{ secrets.REGISTRY_PASSWORD }}
            github_token: ${{ secrets.GITHUB_TOKEN }}
```

This uses under the hood uses Helm and gh cli (which is available to actions). Helm is used to login and push charts into an OCI registry, while gh cli is used to create and update the repository releases.

It does this – during every push to `main` – by checking each chart in your project, and whenever there's a new chart version, creates a corresponding [GitHub release](https://help.github.com/en/github/administering-a-repository/about-releases) named for the chart version, adds Helm chart artifacts to the release, and pushes the chart into the given OCI registry.
