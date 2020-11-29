---
title: "Services"
date: 2020-09-13T17:33:04+01:00
summary: "Cluster load-balancing solutions"
weight: 20
---

Services are one of the most powerful and, as a result, complex abstractions in Kubernetes. It is, also, a very heavily overloaded term which makes Services even more confusing for people approaching Kubernetes for the first time. This chapter will give a high-level overview of different types of Services, their goals and how they relate to other cluster elements and APIs.

{{% notice info %}}
A lot of ideas and concepts in this chapter are based on numerous talks and presentations on this topic. It's difficult to make concrete attributions, however most credit goes to members of [Network Special Interest Group](https://github.com/kubernetes/community/tree/master/sig-network).
{{% /notice %}}

## Services 101

A good starting point to understand Services is to think of them as a distributed load-balancer. Similar to traditional load-balancers, their data model can be reduced to the following two elements:

1. **Group of backend Pods** -- all Pods with similar labels represent a single service and can receive and process incoming traffic for that service. 
2. **Method of Exposure** -- each group of Pods can be exposed either internally, to other Pods in a cluster, or externally, to end users or external services. 

Although not directly connected, Services often rely on Deployments to create the required number of Pods with a unqiue set of labels. These Pods then receive an equal share of traffic (by default) destined for that service IP.




## Services Hierarchy

There are different types of Services, each one with its unique use case. These Services are sometimes grouped into an "hierarchy" starting from the simplest type, with each subsequent type building on top of the previous one. The table below is an attempt to explore and explain this hierarchy:

| Type      | Description | 
| ----------| ----------- |
| **Headless** | The simplest form of load-balancing involving only DNS. Nothing is programmed in the dataplane and no load-balancer VIP is assigned, however DNS query will return IPs for all backend Pods. The most typical use-case for this is stateful workloads (e.g. databases), where clients need stable and predictable DNS name and can handle loss of connectivity and failover on their own. |
| **ClusterIP** | The most common type, assigns a unique ClusterIP (VIP) to a set of matching backend Pods. DNS lookup of a Service hostname returns the allocated ClusterIP. All ClusterIPs are configured in the dataplane of each node as DNAT rules -- destination ClusterIP is translated to one of the PodIPs. Those DNAT rules are limited to match only a specific set of ports exposed by the backend Pods. |
| **NodePort** | Builds on top of the ClusterIP Service by allocating a unique static port on each Node and mapping that port to the backend port exposed by the backend Pods. The incoming traffic can hit _any_ cluster Node and, as long as destination port matches the NodePort, it will get routed to one of the healthy backend Pods. |
| **LoadBalancer** |  Attracts external user traffic to the correct NodePort. Each LoadBalancer Service instance is assigned with a unique, externally routable IP address and NATs all traffic to the corresponding NodePort. This Service type is implemented outside of main kube controllers -- either by the underlying cloud [IaaS](cni/iaas/) or with a cluster add-on like [MetalLB](https://github.com/metallb/metall.) or [Porter](https://github.com/kubesphere/porter).|

The following diagram illustrates how different Service types can be combined to expose a stateful application. 

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=xy2cxxoLWAjYxmtAeYh4&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


## Services APIs and implementations



These labels are used by the `kube-controller-manager` to build the **Endpoints** object


## Services Optimisations

* externalTrafficPolicy
* Topology-aware routing
* EndpointSlices