---
title: "DNS"
date: 2020-09-13T17:33:04+01:00
weight: 100
summary: "The role and configuration of DNS"
---

DNS plays a central role in Kubernetes service discovery. As it was mentioned in the [Services chapter](/services/), DNS is an integral part of Service's operation and, while implementation is not baked into core Kubernetes controllers, [DNS specification](https://github.com/kubernetes/dns/blob/master/docs/specification.md) is very explicit about the behaviour expected from it. 

## Kubernetes Service Discovery

## KubeDNS vs CoreDNS

https://kubernetes.io/blog/2018/07/10/coredns-ga-for-kubernetes-cluster-dns/

## CoreDNS implementation

## Node-local caches
https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/


## Epic bugs
https://github.com/kubernetes/kubernetes/issues/56903
https://www.weave.works/blog/racy-conntrack-and-dns-lookup-timeouts
https://github.com/kubernetes/kubernetes/issues/62628