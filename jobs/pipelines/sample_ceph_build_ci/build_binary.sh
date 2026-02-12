#!/bin/bash

# Set strict mode
set -ex

# Create the dist directory
mkdir -p dist

# Create the dist/version file required by setup_rpm/build_rpm
tarball="ceph-${VERSION}"

# Extract the RPM release number from the VERSION
RPM_VERSION=$(echo "${VERSION}" | rev | cut -d"." -f2- | rev)
PROJECT_VERSION=$(echo "${VERSION}" | rev | cut -d"-" -f2- | rev)
RPM_RELEASE=$(echo "${VERSION}" | rev | cut -d"-" -f1 | rev)

# Generates a spec from 'ceph.spec.in' to ensure dependencies match the version
if [ -f "ceph.spec.in" ]; then
    sed -e "s/@TARBALL_BASENAME@/${tarball}/g" \
        -e "s/@PROJECT_VERSION@/${PROJECT_VERSION}/g" \
        -e "s/@RPM_RELEASE@/${RPM_RELEASE}/g" \
        < ceph.spec.in > "dist/ceph.spec"
else
    echo "ERROR: Run this script from the root of your Ceph source tree."
    exit 1
fi

# Modify spec file for development naming/versioning
sed -i "s/^%setup.*/%setup -q -n %{name}-${VERSION}/" "dist/ceph.spec"
sed -i "s/^%autosetup.*/%autosetup -p1 -n %{name}-${VERSION}/" "dist/ceph.spec"
sed -i "s/%{name}-%{version}/${tarball}/" "dist/ceph.spec"

# Add git version
echo "${SHA1}" > src/.git_version
echo "${tarball}" >> src/.git_version

# Create Source Distribution
echo "Staging source for tarball..."
STAGING_DIR=$(mktemp -d)

# Use rsync -l to preserve symlinks and avoid the slow -h overhead
rsync -a --exclude=".git" --exclude="rpm" . "${STAGING_DIR}/${tarball}"

# We now tar the staged directory directly
echo "Creating tarball from staged directory..."
tar -cjf "dist/${tarball}.tar.bz2" -C "${STAGING_DIR}" "${tarball}"