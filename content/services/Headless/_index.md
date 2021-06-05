---
title: "Headless"
date: 2020-09-13T17:33:04+01:00
weight: 30
draft: false 
---

This type of service does not perform any load-balancing and only implements DNS Service Discovery, based on the Kubernetes [DNS Spec](https://github.com/kubernetes/dns/blob/master/docs/specification.md#24---records-for-a-headless-service). Although this is the simplest and the most basic type of Service, its use is mainly limited to stateful applications like databases and clusters. In these use case the assumption is that clients have some prior knowledge about the application they're going to be communicating with, e.g. number of nodes, naming structure, and can handle failover and load-balancing on their own.

Some typical examples of stateful applications that use this kind of service are:

* [zookeeper](https://github.com/bitnami/charts/blob/master/bitnami/zookeeper/templates/svc-headless.yaml)
* [etcd](https://github.com/bitnami/charts/blob/master/bitnami/etcd/templates/svc-headless.yaml)
* [consul](https://github.com/hashicorp/consul-helm/blob/master/templates/server-service.yaml)

The only thing that makes a service "Headless" is the `clusterIP: None` which, on the one hand, tells dataplane agents to ignore this resource and, on the other hand, tells the DNS plugin that it needs [special type of processing](https://github.com/coredns/coredns/blob/5b9b079dabc7f71463cea3f0c6a92f338935039d/plugin/kubernetes/kubernetes.go#L461). The rest of the API parameters look similar to any other Service:


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

The corresponding Endpoints resources are still creates for every healthy backend Pod, with the only notable distinction being the absence of hash in Pods name and presence of the hostname field.

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

In order to optimise the work of kube-proxy and other controllers that may need to read Endpoints, their Controller annotates all objects with the `service.kubernetes.io/headless` label.
{{% /notice %}}


## Implementation

This type of service is implemented entirely within a DNS plugin. The following is a simplified version of the [actual code](https://github.com/coredns/coredns/blob/5b9b079dabc7f71463cea3f0c6a92f338935039d/plugin/kubernetes/kubernetes.go#L383) from CoreDNS's kubernetes plugin:

{{< gist networkop cc2f49248321e6547d880ea1406704ea >}}


CoreDNS builds an internal representation of Services, containing only the information that may be relevant to DNS (IPs, port numbers) and dropping all of the other details. This information is later used to build a DNS response.


### Lab

Assuming that the lab is already [setup](/lab/), we can install a stateful application (consul) with the following command:

```bash
make headless
```

Check that the consul statefulset has been deployed:

```bash
$ kubect get sts
NAME            READY   AGE
consul-server   3/3     25m
```

Now we should be able to see one Headless Services in the default namespace:

```bash
$ kubect get svc consul-server
NAME            TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                                                                   AGE
consul-server   ClusterIP   None         <none>        8500/TCP,8301/TCP,8301/UDP,8302/TCP,8302/UDP,8300/TCP,8600/TCP,8600/UDP   29m
```

To interact with this service, we can do a DNS query from any of the `net-tshoot` Pods:

```
 kubectl exec -it net-tshoot-8kqh6 -- dig consul-server +search

; <<>> DiG 9.16.11 <<>> consul-server +search
;; global options: +cmd
;; Got answer:
;; WARNING: .local is reserved for Multicast DNS
;; You are currently testing what happens when an mDNS query is leaked to DNS
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 2841
;; flags: qr aa rd; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 1
;; WARNING: recursion requested but not available

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
; COOKIE: fe116ac7ab444725 (echoed)
;; QUESTION SECTION:
;consul-server.default.svc.cluster.local. IN A

;; ANSWER SECTION:
consul-server.default.svc.cluster.local. 13 IN A 10.244.2.8
consul-server.default.svc.cluster.local. 13 IN A 10.244.1.8
consul-server.default.svc.cluster.local. 13 IN A 10.244.0.6

;; Query time: 0 msec
;; SERVER: 10.96.0.10#53(10.96.0.10)
;; WHEN: Sat Jun 05 15:30:09 UTC 2021
;; MSG SIZE  rcvd: 245
```

Application interacting with this StatefulSet can make use of DNS SRV lookup to find individual hostnames and port numbers exposed by the backend Pods:

```
$ kubectl exec -it net-tshoot-8kqh6 -- dig consul-server +search srv +short
0 4 8301 consul-server-2.consul-server.default.svc.cluster.local.
0 4 8600 consul-server-2.consul-server.default.svc.cluster.local.
0 4 8300 consul-server-2.consul-server.default.svc.cluster.local.
0 4 8500 consul-server-2.consul-server.default.svc.cluster.local.
0 4 8302 consul-server-2.consul-server.default.svc.cluster.local.
0 4 8301 consul-server-1.consul-server.default.svc.cluster.local.
0 4 8600 consul-server-1.consul-server.default.svc.cluster.local.
0 4 8300 consul-server-1.consul-server.default.svc.cluster.local.
0 4 8500 consul-server-1.consul-server.default.svc.cluster.local.
0 4 8302 consul-server-1.consul-server.default.svc.cluster.local.
0 4 8301 consul-server-0.consul-server.default.svc.cluster.local.
0 4 8600 consul-server-0.consul-server.default.svc.cluster.local.
0 4 8300 consul-server-0.consul-server.default.svc.cluster.local.
0 4 8500 consul-server-0.consul-server.default.svc.cluster.local.
0 4 8302 consul-server-0.consul-server.default.svc.cluster.local.
```

