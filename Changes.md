# Change history for significant pattern releases

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

v1.0 - March 2026

* Updated workload deployment script to check both clusters for workload instead of just the primary, in case
a failover was in progress at the time.
* Update ACM to 2.15 and golang-external-secrets. Move to 0.2 golang-secrets chart to allow use of v1 API. This is
in prep to move to OCP 4.20 as the default.
* Change machine instance type for submariner to allow deployment on 4.20.
* rdr chart previously used hardcoded and undocumented Vault secrets. Exposed these as variables and referenced
previously documented AWS secret instead of creating a new one with the same material).
* When OCP 4.20+ support is ready, there will be a v1.1 branch to use it.
* Externalize all charts to prep for subsequent demo pattern.
