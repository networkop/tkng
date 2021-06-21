---
title: "IPTABLES"
date: 2020-09-13T17:33:04+01:00
weight: 10
---

Most of the focus of this section will be on the standard node-local proxy implementation called  [`kube-proxy`](https://kubernetes.io/docs/concepts/overview/components/#kube-proxy). It is used by default by most of the Kubernetes orchestrators and is installed as a daemonset on top of an newly bootstrapped cluster:


```
$ kubectl get daemonset -n kube-system -l k8s-app=kube-proxy
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kube-proxy   3         3         3       3            3           kubernetes.io/os=linux   2d16h
```

The default mode of operation for `kube-proxy` is `iptables`, as it provides support for a wider set of operating systems without requiring extra kernel modules and has a "good enough" performance characteristics for the majority of small to medium-sized clusters. 

This area of Kubernetes networking is one of the most poorly documented. On the one hand, there are [blogposts](https://medium.com/google-cloud/understanding-kubernetes-networking-services-f0cb48e4cc82) that cover parts of the `kube-proxy` dataplane, on the other hand there's an amazing [diagram](https://docs.google.com/drawings/d/1MtWL8qRTs6PlnJrW4dh8135_S9e2SaawT410bJuoBPk/edit) created by [Tim Hockin](https://twitter.com/thockin) that shows a complete logical flow of packet forwarding decisions but provides very little context and is quite difficult to trace for specific flows. The goal of this article is to bridge the gap between these two extremes and provide a high level of detail while maintaining an easily consumable format.

So for demonstration purposes, we'll use the following topology with a "web" deployment and two pods scheduled on different worker nodes. The packet forwarding logic for ClusterIP-type services has two distinct paths within the dataplane, which is what we're gonna be focusing on next:

1. **Pod-to-Service** communication (purple packets) -- implemented entirely within an egress node and relies on CNI for pod-to-pod reachability.
2. **Any-to-Service** communication (grey packets) -- includes any externally-originated and, most notable, node-to-service traffic flows.

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=nEL34B1qbs_s_G34E68V&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


The above diagram shows a slightly simplified sequence of match/set actions implemented inside Netfilter's NAT table. The lab section below will show a more detailed view of this dataplane along verification commands.

{{% notice note %}}
One key thing to remember is that none of the ClusterIPs implemented this way are visible in the Linux routing table. The whole dataplane is implemented entirely within iptable's NAT table, which makes it both very flexible and extremely difficult to troubleshoot at the same time.
{{% /notice %}}

### Lab Setup

To make sure that lab is in the right state, reset it to a blank state:

```bash
make up && make reset
```

Now let's spin up a new deployment and expose it with a ClusterIP service:

```bash
$ kubectl create deploy web --image=nginx --replicas=2
$ kubectl expose deploy web --port 80
```

The result of the above two commands can be verified like this:

```bash
$ kubectlget deploy web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    2/2     2            2           160m
$ kubectlget svc web
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
web    ClusterIP   10.96.94.225    <none>        8080/TCP   31s
```

The simplest way to test connectivity would be to connect to the assigned ClusterIP `10.96.94.225` from one of the nodes, e.g.:

```bash
$ docker exec k8s-guide-worker curl -s 10.96.94.225 | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
```

One last thing before moving on, let's set up the following bash alias as a shortcut to `k8s-guide-worker`'s NAT iptable:

```bash
$ alias d="docker exec k8s-guide-worker iptables -t nat -nvL"
```

### Use case #1: Pod-to-Service communication

According to Tim's [diagram](https://docs.google.com/drawings/d/1MtWL8qRTs6PlnJrW4dh8135_S9e2SaawT410bJuoBPk/edit) all Pod-to-Service packets get intercepted by the `OUTPUT` chain:

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ d OUTPUT
Chain OUTPUT (policy ACCEPT 84 packets, 5040 bytes)
 pkts bytes target     prot opt in     out     source               destination
  313 18736 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
   36  2242 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            172.16.0.190
{{< / highlight >}}

These packets get redirected to the `KUBE-SERVICES` chain, where they get matched against _all_ configured ClusterIPs, eventually reaching these lines:

{{< highlight bash "linenos=false,hl_lines=3" >}}
$ d KUBE-SERVICES | grep 10.96.94.225
    3   180 KUBE-MARK-MASQ  tcp  --  *      *      !10.244.0.0/16        10.96.94.225         /* default/web cluster IP */ tcp dpt:80
    3   180 KUBE-SVC-LOLE4ISW44XBNF3G  tcp  --  *      *       0.0.0.0/0            10.96.94.225         /* default/web cluster IP */ tcp dpt:80
{{< / highlight >}}

Since the sourceIP of the packet belongs to a Pod (`10.244.0.0/16` is the PodCIDR range), the second line gets matched and the lookup continues in the service-specific chain. Here we have two Pods matching the same label-selector (`--replicas=2`) and both chains are configured with equal distribution probability:

{{< highlight bash "linenos=false,hl_lines=4 12" >}}
$ d KUBE-SVC-LOLE4ISW44XBNF3G
Chain KUBE-SVC-LOLE4ISW44XBNF3G (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-SEP-MHDQ23KUGG7EGFMW  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ statistic mode random probability 0.50000000000
    0     0 KUBE-SEP-ZA2JI7K7LSQNKDOS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */
{{< / highlight >}}

Let's assume that in this case the first rule gets matched, so our packet continues on to the next chain where it gets DNAT'ed to the target IP of the destination Pod (`10.244.1.3`):

{{< highlight bash "linenos=false,hl_lines=5" >}}
$ d KUBE-SEP-MHDQ23KUGG7EGFMW
Chain KUBE-SEP-MHDQ23KUGG7EGFMW (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       10.244.1.3           0.0.0.0/0            /* default/web */
    3   180 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ tcp to:10.244.1.3:80
{{< / highlight >}}

From here on our packet remains unmodified and continues along its forwarding path set up by a [CNI plugin](/cni/kindnet/) until it reaches the target Node and gets sent directly to the destination Pod.



### Use case #2: Any-to-Service communication

Let's assume that the `k8s-guide-worker` node (IP `172.18.0.12`) is sending a packet to our ClusterIP service. This packet gets intercepted in the `OUTPUT` chain and continues to the `KUBE-SERVICES` where it gets redirected via the `KUBE-MARK-MASQ` chain:

{{< highlight bash "linenos=false,hl_lines=4 8" >}}
$ d OUTPUT
Chain OUTPUT (policy ACCEPT 224 packets, 13440 bytes)
 pkts bytes target     prot opt in     out     source               destination
 4540  272K KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
   42  2661 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            172.16.0.190

$ d KUBE-SERVICES | grep 10.96.94.225
    3   180 KUBE-MARK-MASQ  tcp  --  *      *      !10.244.0.0/16        10.96.94.225         /* default/web cluster IP */ tcp dpt:80
    3   180 KUBE-SVC-LOLE4ISW44XBNF3G  tcp  --  *      *       0.0.0.0/0            10.96.94.225         /* default/web cluster IP */ tcp dpt:80
{{< / highlight >}}

The purpose of this chain is to mark all packets that will need to get SNAT'ed before they get sent to the final destination:

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ d KUBE-MARK-MASQ
Chain KUBE-MARK-MASQ (19 references)
 pkts bytes target     prot opt in     out     source               destination
    3   180 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK or 0x4000
    {{< / highlight >}}

Since `MARK` is not a [terminating target](https://gist.github.com/mcastelino/c38e71eb0809d1427a6650d843c42ac2#targets), the lookup continues down the `KUBE-SERVICES` chain where our packets gets DNAT'ed to one of the randomly selected backend endpoints (as shown above). 

However, this time, before it gets sent to its final destination, the packet gets another detour via the `KUBE-POSTROUTING` chain:


{{< highlight bash "linenos=false,hl_lines=4" >}}
$ d POSTROUTING
Chain POSTROUTING (policy ACCEPT 140 packets, 9413 bytes)
 pkts bytes target     prot opt in     out     source               destination
  715 47663 KUBE-POSTROUTING  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes postrouting rules */
    0     0 DOCKER_POSTROUTING  all  --  *      *       0.0.0.0/0            172.16.0.190
  657 44150 KIND-MASQ-AGENT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type !LOCAL /* kind-masq-agent: ensure nat POSTROUTING directs all non-LOCAL destination traffic to our custom KIND-MASQ-AGENT chain */
{{< / highlight >}}

Here all packets with a special SNAT mark (0x4000) fall through to the last rule and get SNAT'ed to the IP of the outgoing interface, which in this case is the veth interface connected to the Pod:

{{< highlight bash "linenos=false,hl_lines=6" >}}
$ d KUBE-POSTROUTING
Chain KUBE-POSTROUTING (1 references)
 pkts bytes target     prot opt in     out     source               destination
  463 31166 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            mark match ! 0x4000/0x4000
    2   120 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK xor 0x4000
    2   120 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service traffic requiring SNAT */ random-fully
{{< / highlight >}}


The final `MASQUERADE` action ensures that the return packets follow the same way back, even if they were originated outside of the Kubernetes cluster.

{{% notice info %}}
The above sequence of lookups may look long an inefficient but bear in mind that this is only done once, for the first packet of the flow and the remainder of the session gets offloaded to Netfilter's connection tracking system.
{{% /notice %}}



### Additional Reading

* [**Netfilter Packet flow** ](https://upload.wikimedia.org/wikipedia/commons/3/37/Netfilter-packet-flow.svg)
* [**Logical diagram of kube-proxy in iptables mode**](https://docs.google.com/drawings/d/1MtWL8qRTs6PlnJrW4dh8135_S9e2SaawT410bJuoBPk/edit)
* [**Alternative kube-proxy implementations**](https://arthurchiao.art/blog/cracking-k8s-node-proxy/)
* [**Kubernetes networking demystified**](https://www.cncf.io/blog/2020/01/30/kubernetes-networking-demystified-a-brief-guide/)