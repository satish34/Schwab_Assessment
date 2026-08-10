# 30-lb

This stack reads `10-global` local state and looks up the six standalone zonal
App A NEGs created by GKE. It refuses the wrong project, network, subnets, NEG
type, NEG names, an empty zonal NEG, or a region with fewer than three
registered endpoints.

With no domain configured, `public_endpoint` is the HTTP origin on the reserved
global IP, for example `http://136.69.29.22`. The application API is
`GET <public_endpoint>/api/exchange-rates`; the output is not the API route
itself.

When `10-global` exports both a trusted domain and its Certificate Manager map
ID, this stack adds HTTPS on the same reserved IP, changes `public_endpoint` to
`https://<domain>`, and removes the port 80 forwarding rule and target HTTP
proxy. The trusted deployment therefore exposes only port 443; it never creates
a self-signed certificate or private key.

The stack owns the `EXTERNAL_MANAGED` load-balancer graph. It does not create
NEGs, register endpoints, or configure a multi-cluster API.

Apply only after the NEG gate passes. For teardown, destroy this stack while
the App A Services and NEGs still exist, then remove the Services and wait for
NEG garbage collection before destroying the clusters.
