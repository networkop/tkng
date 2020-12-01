---
title: "Services"
date: 2020-09-13T17:33:04+01:00
summary: "Cluster load-balancing solutions"
weight: 20
---

Services are one of the most powerful and, as a result, complex abstractions in Kubernetes. It is, also, a very heavily overloaded term which makes Services even more confusing for people approaching Kubernetes for the first time. This chapter will provide a high-level overview of different types of Services, their goals and how they relate to other cluster elements and APIs.

{{% notice info %}}
A lot of ideas and concepts in this chapter are based on numerous talks and presentations on this topic. It's difficult to make concrete attributions, however most credit goes to members of [Network Special Interest Group](https://github.com/kubernetes/community/tree/master/sig-network).
{{% /notice %}}

## Services Hierarchy

A good starting point to understand a Kubernetes Service is to think of it as a distributed load-balancer. Similar to traditional load-balancers, its data model can be reduced to the following two components:

1. **Grouping of backend Pods** -- all Pods with similar labels represent a single service and can receive and process incoming traffic for that service. 
2. **Methods of exposure** -- each group of Pods can be exposed either internally, to other Pods in a cluster, or externally, to end users or external services in a number of different ways. 

All Services implement the above functionality, but each in a slightly different way, built for its own unqiue usecase. In order to understand various Service types, it helps to view them as an "hierarchy" -- starting from the simplest, with each subsequent type building on top of the previous one. The table below is an attempt to explore and explain this hierarchy:

| Type      | Description | 
| ----------| ----------- |
| **Headless** | The simplest form of load-balancing involving only DNS. Nothing is programmed in the dataplane and no load-balancer VIP is assigned, however DNS query will return IPs for all backend Pods. The most typical use-case for this is stateful workloads (e.g. databases), where clients need stable and predictable DNS name and can handle loss of connectivity and failover on their own. |
| **ClusterIP** | The most common type, assigns a unique ClusterIP (VIP) to a set of matching backend Pods. DNS lookup of a Service name returns the allocated ClusterIP. All ClusterIPs are configured in the dataplane of each node as DNAT rules -- destination ClusterIP is translated to one of the PodIPs. These NAT translations always happen on the egress (client-side) node which means that Pod-to-Pod reachability must be provided externally (by a [CNI plugin](/cni)).  |
| **NodePort** | Builds on top of the ClusterIP Service by allocating a unique static port in the root namespace of each Node and mapping it (via Port Translation) to the port exposed by the backend Pods. The incoming traffic can hit _any_ cluster Node and, as long as destination port matches the NodePort, it will get forwarded to one of the healthy backend Pods. |
| **LoadBalancer** |  Attracts external user traffic to a Kubernetes cluster. Each LoadBalancer Service instance is assigned with a unique, externally routable IP address which is advertised to the underlying physical network via BGP or gARP. This Service type is implemented outside of the main kube controller -- either by the underlying cloud as an external L4 load-balancer or with a cluster add-on like [MetalLB](https://github.com/metallb/metall.) or [Porter](https://github.com/kubesphere/porter). |

{{% notice note %}}
One Service type that doesn't fit with the rest is `ExternalName`. It instructs DNS cluster add-on (e.g. CoreDNS) to respond with a CNAME, redirecting all queries for this service's DNS to an external FQDN, which can simplify interacting with external services (for more details see the [Design Spec](https://github.com/kubernetes/community/blob/b3349d5b1354df814b67bbdee6890477f3c250cb/contributors/design-proposals/network/service-external-name.md#motivation)). 
{{% /notice %}}

The following diagram illustrates how different Service types can be combined to expose a stateful application:

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=xy2cxxoLWAjYxmtAeYh4&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


{{% notice info %}}
Although not directly connected, Services often rely on Deployments and StatefulSets to create the required number of Pods with a unqiue set of labels. 
{{% /notice %}}

## Service APIs and Implementation

Services have a relatively small and simple API. At the very least they expect the following to be defined:

* Explicit list of backend **ports** that needs to be exposed.
* Label **selector** to understand which Pods are the potential candidates. 
* A Service **type** which defaults to `ClusterIP`.

```yaml
kind: Service
apiVersion: v1
metadata:
  name: service-example
spec:
  ports:
    - name: http
      port: 80
      targetPort: 80
  selector:
      app: nginx
  type: LoadBalancer
```

{{% notice note %}}
Some services may not have any label selectors, in which case the list of backend Pods can still be constructed manually. 
{{% /notice %}}

Service's internal architecture consists of two loosely-coupled components:

* Kubernetes **control plane** -- internal controller running inside the `kube-controller-manager` binary, that react to API events and builds internal representation of each service instance. This internal representation is a special **Endpoints** object that gets created for every Service instance and contains a list of healthy backend endpoints (PodIP + port).
* Distributed **data plane** --  a set of Node-local agents that read **Endpoints** objects and program their local data plane. This is most commonly implemented with `kube-proxy` with various competing implementations from 3rd-party Kubernetes networking providers like Cilium, Calico, kube-router and others.

Another less critical, but nonetheless important components is DNS. Internally, DNS add-on is just a Pod running in a cluster that caches `Service` and `Endpoints` objects and responds to incoming queries according to the DNS-Based Service Discovery [specification](https://github.com/kubernetes/dns/blob/master/docs/specification.md). This specification defines the format for incoming queries and the expected structure for responses.

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=HR_OWBqgmX47NSTQvTWL&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}

## Services Optimisations

* externalTrafficPolicy
* Topology-aware routing
* EndpointSlices