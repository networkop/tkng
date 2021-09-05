---
title: "DNS"
date: 2020-09-13T17:33:04+01:00
weight: 100
summary: "The role and configuration of DNS"
---

DNS plays a central role in Kubernetes service discovery. As it was mentioned in the [Services chapter](/services/), DNS is an essential part of how Services are consumed by end clients and, while implementation is not baked into core Kubernetes controllers, [DNS specification](https://github.com/kubernetes/dns/blob/master/docs/specification.md) is very explicit about the behaviour expected from such implementation. 

The DNS spec defines the rules for the format of the queries and the expected response content. All Kubernetes Services have at least one corresponding A/AAAA DNS record (some additionally support SRV and PTR) and the response format depends on the type of queried Service:

| Service Type | Response |
|--------------|----------|
| ClusterIP, NodePort, LoadBalancer | ClusterIP value | 
| Headless | List of Endpoint IPs |
| ExternalName | CNAME pointing to the value of `spec.externalName` |

{{% notice note %}}
Pods also have a corresponding A/AAAA record; see the [official docs](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pods) for more details.
{{% /notice %}}

Historically, there had been two implementations of this DNS spec -- one based on `dnsmasq` and another one based on `CoreDNS`, the latter had become the [default option](https://kubernetes.io/blog/2018/07/10/coredns-ga-for-kubernetes-cluster-dns/) for kubeadm since Kubernetes 1.11.



## Service Discovery -- Server side

CoreDNS implements the Kubernetes DNS spec in a [dedicated plugin](https://coredns.io/plugins/kubernetes/) that gets compiled into a static binary and deployed in a Kubernetes cluster as a Deployment and exposed as a ClusterIP service. This means that all communications with the DNS service inside a cluster are subject to the same network forwarding rules used by normal Pods and set up by the [CNI](/cni/) and [Services](/services/) plugins.

Since DNS speed and stability are considered [crucial](https://isitdns.com/) in any network-based communication, CoreDNS implementation is [highly optimised](https://github.com/coredns/deployment/blob/master/kubernetes/Scaling_CoreDNS.md) to minimise memory consumption and maximise query processing rate. In order to achieve that, CoreDNS stores only the [relevant parts](https://github.com/coredns/coredns/blob/a644eb4472ab61cdef8405b4e42bc9892f2e9295/plugin/kubernetes/object/service.go#L33) of [Services](https://github.com/coredns/coredns/blob/a644eb4472ab61cdef8405b4e42bc9892f2e9295/plugin/kubernetes/object/service.go#L12), [Pods](https://github.com/coredns/coredns/blob/a644eb4472ab61cdef8405b4e42bc9892f2e9295/plugin/kubernetes/object/pod.go#L13) and [Endpoints](https://github.com/coredns/coredns/blob/a644eb4472ab61cdef8405b4e42bc9892f2e9295/plugin/kubernetes/object/endpoint.go#L14) objects in its [local cache](https://github.com/coredns/coredns/blob/a644eb4472ab61cdef8405b4e42bc9892f2e9295/plugin/kubernetes/controller.go#L115) that is optimised to return a response in a [single lookup](https://github.com/coredns/coredns/blob/a644eb4472ab61cdef8405b4e42bc9892f2e9295/plugin/kubernetes/kubernetes.go#L495).

By default, CoreDNS also acts as a DNS proxy for all external domains (e.g. example.com) using the [`forward` plugin](https://coredns.io/plugins/forward/) and is often deployed with the [`cache` plugin](https://coredns.io/plugins/cache/) enabled. The entire CoreDNS configuration can be found in the `coredns` ConfigMap:

```yaml
apiVersion: v1
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
```

## Service Discovery -- Client side

DNS configuration inside a Pod is controlled by the `spec.dnsPolicy` and `spec.dnsConfig` [settings](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pod-s-dns-policy). By default, kubelet will configure the cluster DNS IP, stored in the configuration file and [hard-coded](https://github.com/kubernetes/kubernetes/blob/cde45fb161c5a4bfa7cfe45dfd814f6cc95433f7/cmd/kubeadm/app/constants/constants.go#L638) to the tenth IP of the ClusterIP range by the kubeadm.

```
root@k8s-guide-control-plane:/# cat /var/lib/kubelet/config.yaml 
apiVersion: kubelet.config.k8s.io/v1beta1
...
clusterDNS:
- 10.96.0.10
...
```
With the above default settings, this is how a Pod deployed in the default namespace would see its own `resolv.conf` file:

```
$ cat /etc/resolv.conf
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

The search domains and `ndots` value are configured so that any non-FQDN DNS query made by a Pod is first tried in all of the specified domains, which allows for internal cluster DNS schema to take precedence over the external DNS ([explanation](https://github.com/kubernetes/kubernetes/issues/33554)). For example, any Pod in the `default` Namespace, can lookup the ClusterIP of the `kubernetes` Service in a single lookup (the shell is running a `stern -n kube-system -l k8s-app=kube-dns` in the background):

```bash
$ kubectl -n default exec ds/net-tshoot -- dig kubernetes +search +short
10.96.0.1
coredns-558bd4d5db-sqhkz coredns [INFO] 10.244.0.5:36255 - 36946 "A IN kubernetes.default.svc.cluster.local. udp 77 false 4096" NOERROR qr,aa,rd 106 0.0002139s
```

The downside of this behaviour is that any external domain lookup will require at least 4 separate queries:

```
$ kubectl -n default exec ds/net-tshoot -- dig tkng.io +search +short
coredns-558bd4d5db-5jbgh coredns [INFO] 10.244.0.5:54816 - 13660 "A IN tkng.io.default.svc.cluster.local. udp 74 false 4096" NXDOMAIN qr,aa,rd 144 0.0002719s
coredns-558bd4d5db-5jbgh coredns [INFO] 10.244.0.5:38006 - 38084 "A IN tkng.io.svc.cluster.local. udp 66 false 4096" NXDOMAIN qr,aa,rd 136 0.0001705s
coredns-558bd4d5db-5jbgh coredns [INFO] 10.244.0.5:35302 - 4454 "A IN tkng.io.cluster.local. udp 62 false 4096" NXDOMAIN qr,aa,rd 132 0.0001219s
172.67.201.112
104.21.21.243
coredns-558bd4d5db-sqhkz coredns [INFO] 10.244.0.5:47052 - 6189 "A IN tkng.io. udp 48 false 4096" NOERROR qr,rd,ad 71 0.0183829s
```


## Optimisations

DNS is widely regarded as the main [source](https://isitdns.com/) of all IT problems, and Kubernetes is no exception (see [1](https://github.com/kubernetes/kubernetes/issues/56903), [2](https://www.weave.works/blog/racy-conntrack-and-dns-lookup-timeouts), [3](https://github.com/kubernetes/kubernetes/issues/62628), [4](https://pracucci.com/kubernetes-dns-resolution-ndots-options-and-why-it-may-affect-application-performances.html)). It's way of deployment and reliance on [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) mean that some Nodes could become connection bottlenecks while the CPU and Memory of the DNS Pods may remain relatively low. There are a number of optmisations that can be enabled to improve DNS performance at the expense of additional resource utilisation and complexity:

* The [**authopath** plugin](https://coredns.io/plugins/autopath/) can be enabled in CoreDNS to make it follow the chain of search paths on behalf of a client, thereby reducing the number of queries required by the client to just one.
* Each Kubernetes Node can run a [**NodeLocal DNSCache**](https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/) -- a daemonset of recursive DNS resolvers deployed on each Node designed to reduce the load on a centralised CoreDNS deployment by serving as a caching layer between the Pods and the DNS service.



## External DNS