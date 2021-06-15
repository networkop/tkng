---
title: "ClusterIP"
date: 2020-09-13T17:33:04+01:00
weight: 40
---

When people say that Kubernetes networking is difficult, they very often refer to this type of service. One of the reasons for this perception is that all of its complexity is hidden behind a very minimalistic API. A common way of defining a Service only takes 5 lines of configuration (plus the standard metadata):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: clusterIP-example
spec:
  ports:
  - name: http
    port: 80
  selector:
    app: my-backend-app
```

Quite unexpectedly, these 5 lines can generate a large amount of state inside the cluster as each Service has to be implemented on all worker nodes and its state grows prortionally to the number of backend Endpoints. In order to better understand the mechanisms behind it, the remainder of this chapter will be broken down into the following sections:

- **Control Plane** will examine the mechanics of interaction between user input, the API server and distributed node-local agents.
- **Data Plane** will cover some of the standard implementations, including iptables, ipvs and eBPF.
- **Optimisations** will look at how control plane can be tuned to provide better scalability.

