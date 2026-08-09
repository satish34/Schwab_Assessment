# 30-lb

This stack reads `10-global` local state and looks up the six standalone zonal
App A NEGs created by GKE. It refuses the wrong project, network, subnets, NEG
type, NEG names, or a region with fewer than two registered endpoints.

The core path serves HTTP through one `EXTERNAL_MANAGED` global Application
Load Balancer. If `10-global` exports both a domain and `risk-cert-map`, this
stack adds HTTPS on the same reserved IP and redirects HTTP to the trusted
hostname. It does not create NEGs, register endpoints, or configure any
multi-cluster API.

Apply only after the NEG gate passes. For teardown, destroy this stack while
the App A Services and NEGs still exist, then remove the Services and wait for
NEG garbage collection before destroying the clusters.
