---
title: "Data Plane"
date: 2020-09-13T17:33:04+01:00
weight: 20
---

Dataplane implementations is 


{{% notice note %}}

Most of the focus of this chapter will be on the standard node-local agent implementation called  [`kube-proxy`](https://kubernetes.io/docs/concepts/overview/components/#kube-proxy), installed by default by most of the Kubernetes orchestrators. However, since the emphasis is on the dataplane packet forwarding, it's safe to assume that other implementations will behave in a similar same way, even if the underlying implementation is different.


{{% /notice %}}