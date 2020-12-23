---
title: "Headless"
date: 2020-09-13T17:33:04+01:00
weight: 30
draft: true 
---

This type of service does not perform any load-balancing and only enables DNS-based Service Discovery, as documented in the [DNS Spec](https://github.com/kubernetes/dns/blob/master/docs/specification.md#24---records-for-a-headless-service). Although this is the simplest and the most basic type of Service, its use is mainly limited to stateful applications like databases and clusters. In this case the assumption is that clients have some prior knowledge about the application they're going to be communicating with, e.g. number of nodes, naming structure, and can handle failover and load-balancing on their own.

To

```yaml
apiVersion: v1
kind: Service
metadata:
  name: headless
  namespace: default
spec:
  clusterIP: None
  ports:
  - name: http
    port: 8080
  selector:
    app: database
```


Endpoints example

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  labels:
    service.kubernetes.io/headless: ""
  name: headless
  namespace: default
subsets:
- addresses:
  - hostname: database-0
    ip: 10.244.0.12
    nodeName: k8s-guide-control-plane
    targetRef:
      kind: Pod
      name: database-0
      namespace: default
  ports:
  - name: http
    port: 8080
    protocol: TCP
```
{{% notice info %}}

In order to optimise the work of kube-proxy and other controllers that may need to read Endpoints, their Controller annotates all objects with the `service.kubernetes.io/headless` label:
{{% /notice %}}


{{< gist networkop cc2f49248321e6547d880ea1406704ea >}}