#!/usr/bin/env bash

# Copyright The Helm Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

DEFAULT_HELM_VERSION=v3.13.2
ARCH=$(uname)
ARCH="${ARCH,,}-amd64" # Official helm is available only for x86_64
GITHUB_ACTIONS="${GITHUB_ACTIONS:-false}"

show_help() {
  cat <<EOF
Usage: $(basename "$0") <options>

    -h, --help                    Display help
    -v, --version                 The helm version to use (default: $DEFAULT_HELM_VERSION)"
    -d, --charts-dir              The charts directory (default either: helm, chart or charts)
    -u, --oci-user                The OCI registry user
    -r, --oci-registry            The OCI registry
    -p, --name-pattern            Modifies repository and release tag naming (ex. '{chartName}-chart')
    -i, --install-only            Just install helm and don't release any charts
        --skip-dependencies       Skip dependencies update from "Chart.yaml" to dir "charts/" before packaging (default: false)
        --skip-existing           Skip package upload if release exists
    -l, --mark-as-latest          Mark the created GitHub release as 'latest' (default: true)
EOF
}

errexit() {
  >&2 echo "$*"
  exit 1
}

main() {
  local version="$DEFAULT_HELM_VERSION"
  local charts_dir=
  local oci_user=
  local oci_registry=
  local install_dir=
  local install_only=
  local skip_dependencies=false
  local skip_existing=false
  local mark_as_latest=true
  local name_pattern=

  parse_command_line "$@"

  : "${OCI_REGISTRY_TOKEN:?Environment variable OCI_REGISTRY_TOKEN must be set}"

  REPO_ROOT=$(git rev-parse --show-toplevel)
  pushd "$REPO_ROOT" >/dev/null

  find_charts_dir
  echo 'Looking up latest tag...'

  local latest_tag
  latest_tag=$(lookup_latest_tag)

  echo "Discovering changed charts since '$latest_tag'..."
  local changed_charts=()
  readarray -t changed_charts <<<"$(lookup_changed_charts "$latest_tag")"

  echo "${changed_charts[@]}"

  if [[ -n "${changed_charts[*]}" ]]; then
    install_helm

    for chart in "${changed_charts[@]}"; do
      package_chart "$chart"
    done

    release_charts
    echo "changed_charts=$(
      IFS=,
      echo "${changed_charts[*]}"
    )" >changed_charts.txt
  else
    echo "Nothing to do. No chart changes detected."
    echo "changed_charts=" >changed_charts.txt
  fi

  echo "chart_version=${latest_tag}" >chart_version.txt
  popd >/dev/null
}

parse_command_line() {
  while [ "${1:-}" != "-" ]; do
    case "${1:-}" in
    -h | --help)
      show_help
      exit
      ;;
    -v | --version)
      if [[ -n "${2:-}" ]]; then
        version="$2"
        shift
      else
        echo "ERROR: '-v|--version' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -d | --charts-dir)
      if [[ -n "${2:-}" ]]; then
        charts_dir="$2"
        shift
      else
        echo "ERROR: '-d|--charts-dir' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -u | --user)
      if [[ -n "${2:-}" ]]; then
        oci_user="$2"
        shift
      else
        echo "ERROR: '--oci-user' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -r | --registry)
      if [[ -n "${2:-}" ]]; then
        oci_registry="$2"
        shift
      else
        echo "ERROR: '--oci-registry' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -n | --install-dir)
      if [[ -n "${2:-}" ]]; then
        install_dir="$2"
        shift
      fi
      ;;
    -i | --install-only)
      if [[ -n "${2:-}" ]]; then
        install_only="$2"
        shift
      fi
      ;;
    --skip-dependencies)
      if [[ -n "${2:-}" ]]; then
        skip_dependencies="$2"
        shift
      fi
      ;;
    --skip-existing)
      if [[ -n "${2:-}" ]]; then
        skip_existing="$2"
        shift
      fi
      ;;
    -l | --mark-as-latest)
      if [[ -n "${2:-}" ]]; then
        mark_as_latest="$2"
        shift
      fi
      ;;
    -p | --name-pattern)
      if [[ -n "${2:-}" ]]; then
        name_pattern="$2"
        shift
      fi
      ;;
    *)
      break
      ;;
    esac

    shift
  done

  if [[ -z "$oci_user" ]]; then
    echo "ERROR: '-u|--oci-user' is required." >&2
    show_help
    exit 1
  fi

  if [[ -z "$oci_registry" ]]; then
    echo "ERROR: '-r|--oci-registry' is required." >&2
    show_help
    exit 1
  fi

  if [[ -n $name_pattern && $name_pattern != *"{chartName}"* ]]; then
    echo "ERROR: Name pattern must contain '{chartName}' field." >&2
    show_help
    exit 1
  fi

  if [[ -z "$install_dir" ]]; then
    # use /tmp or RUNNER_TOOL_CACHE in GitHub Actions
    install_dir="${RUNNER_TOOL_CACHE:-/tmp}/cra/$ARCH"

    export HELM_CACHE_HOME="${install_dir}/.cache"
    export HELM_CONFIG_HOME="${install_dir}/.config"
    export HELM_DATA_HOME="${install_dir}.share"
  fi

  if [[ -n "$install_only" ]]; then
    echo "Will install helm tool and don't release any charts..."
    install_helm
    exit 0
  fi
}

install_helm() {
  if [[ ! -x "$install_dir/helm" ]]; then
    mkdir -p "$install_dir"

    echo "Installing Helm ($version) to $install_dir..."
    curl -sSLo helm.tar.gz "https://get.helm.sh/helm-${version}-${ARCH}.tar.gz"
    curl -sSL "https://get.helm.sh/helm-${version}-${ARCH}.tar.gz.sha256sum" | \
      sed 's/helm-.*/helm.tar.gz/' > helm.sha256sum

    if ( ! sha256sum -c helm.sha256sum ); then
      rm -f helm.tar.gz helm.sha256sum
      errexit "ERROR: Aborting helm checksum is invalid"
    fi

    tar -C "$install_dir/.." -xzf helm.tar.gz "$ARCH/helm"
    rm -f helm.tar.gz helm.sha256sum
  else
    echo "Helm is found in the install directory"
  fi

  echo 'Setting PATH to use helm from the install directory...'
  export PATH="$install_dir:$PATH"
}

lookup_latest_tag() {
  git fetch --tags >/dev/null 2>&1

  if ! git describe --tags --abbrev=0 HEAD~ 2>/dev/null; then
    git rev-list --max-parents=0 --first-parent HEAD
  fi
}

filter_charts() {
  local charts=()
  while read -r path; do
    if [[ -f "$path" && ${path##*/} == "Chart.yaml" ]]; then
      charts+=("${path%/Chart.yaml}")
    elif [[ -f "$path/Chart.yaml" ]]; then
      charts+=("$path")
    fi
  done
  echo "${charts[@]}"
}

find_charts_dir() {
  local cdirs=()

  if [ -n "$charts_dir" ]; then
    return
  fi

  if [ -d "helm" ]; then cdirs+=(helm); fi
  if [ -d "chart" ]; then cdirs+=(chart); fi
  if [ -d "charts" ]; then cdirs+=(charts); fi

  if (( "${#cdirs[@]}" > 1 )); then
    errexit "ERROR: Can't use several default directories: helm, chart and charts"
  elif (( "${#cdirs[@]}" == 0 )); then
    errexit "ERROR: No charts directory use --charts-dir"
  fi

  # shellcheck disable=SC2128
  # get the first element
  charts_dir="$cdirs"
}

lookup_changed_charts() {
  local commit="$1"

  local changed_files
  changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")

  local depth=$(($(tr "/" "\n" <<<"$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1))
  local fields="1-${depth}"

  cut -d '/' -f "$fields" <<<"$changed_files" | uniq | filter_charts
}

package_chart() {
  local chart="$1" flags=
  ( $skip_dependencies ) || flags="-u"

  echo "Packaging chart '$chart'..."
  helm package "$chart" $flags -d "${install_dir}/package/$chart"
}

gh_cli() {
  if ( ! $GITHUB_ACTIONS ); then
    >&2 echo "dry run: gh $*"
    return
  fi
  echo gh "$@"
}

chart_description() {
  sed -nE '/^\s*description:\s/ { s/^\s*description:\s*//; p }' < "$REPO_ROOT/$1/Chart.yaml"
}

release_exists() {
  # fields: release tagName date
  gh_cli release ls | tr -s '[:blank:]' | sed -E 's/\sLatest//' | cut -f 1 | grep -q "$1"
}

get_chart_tag() {
  local chartFile="$1" chart chart_version tag
  chartFile="$(ls -1 *.tgz)"
  read -r chart chart_version<<< "$(echo "${chartFile%.tgz}" | sed -E 's/-([0-9.]*)$/ \1/')"

  if [ -n "$name_pattern" ]; then
    tag="${name_pattern//\{chartName\}/$chart}"
  fi
  tag="${tag:-$chart}-$chart_version"

  echo "$tag"
}

release_charts() {
  local changed_charts chart_dir chart tagName chartFile
  oci_registry="${oci_registry#oci://}"

  echo "$OCI_REGISTRY_TOKEN" | echo helm registry login -u "${oci_user}" --password-stdin "${oci_registry}"

  # get the changed charts
  eval "$(cat changed_charts.txt)"

  pushd "${install_dir}/package" >/dev/null

  ## Improve: for repos containing not only charts, we might want to have a special release naming

  # shellcheck disable=SC2012
  for chart_dir in $changed_charts; do
    local flags=
    local releaseExists=true

    pushd "$chart_dir" >/dev/null
    chartFile="$(ls -1 *.tgz)"
    tag=$(get_chart_tag "$chartFile")

    # shellcheck disable=SC2001
    read -r chart <<< "$( echo "$tag" | sed -e 's/-\([0-9.]*\)$//' )"
    ( release_exists "$tag" ) || releaseExists=false

    if ( $skip_existing && $releaseExists ); then
      echo "Release already exists. Skipping $tag..."
      continue
    elif ( ! $releaseExists ); then
      ( ! $mark_as_latest ) || flags="--latest"
      # shellcheck disable=SC2086
      gh_cli release create "$tag" $flags --notes "$(chart_description "$chart_dir")"
    fi

    helm push "$chartFile" "oci://${oci_registry}/${tag%-*}"
    gh_cli release upload "$tag" "$chartFile"
    popd >/dev/null
  done
  popd >/dev/null
}

main "$@"