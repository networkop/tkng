---
title: "calico"
menuTitle: "calico"
date: 2020-11-16T12:33:04+01:00
weight: 15
---

[Calico](https://docs.projectcalico.org/about/about-calico) is another example of a full-blown Kubernetes "networking solution" with functionality including network policy controller, kube-proxy replacement and network traffic observability. CNI functionality is still the core element of Calico and the focus of this chapter will be on how it satisfies the Kubernetes network model [requirements](/cni/#main-goals).


* **Connectivity** is set up by creating a `veth` link and moving one side of that link into a Pod's namespace. The other side of the link is left dangling in the node's root namespace. For each local Pod, Calico sets up a PodIP host-route pointing over the veth link.

{{% notice note %}}
One oddity of Calico CNI is that the node end of the veth link does not have an IP address. In order to provide Pod-to-Node egress connectivity, each `veth` link is set up with `proxy_arp` which makes root NS respond to any ARP request coming from the Pod (assuming that the node has a default route itself).
{{% /notice %}}

* **Reachability** can be established in two different ways:

    1. Static routes and overlays -- Calico supports IPIP and VXLAN and has an option to only setup tunnels for traffic crossing the L3 subnet boundary.

    2. BGP -- the most popular choice for on-prem deployments, it works by configuring a [Bird](https://bird.network.cz/) BGP speaker on every node and setting up peerings to ensure that reachability information gets propagated to every node. There are several [options](https://docs.projectcalico.org/networking/bgp) for how to set up this peering, including full-mesh between nodes, dedicated route-reflector node and external peering with the physical network.

{{% notice info %}}
The above two modes are not mutually exclusive, BGP can be used with IPIP in public cloud environments. For a complete list of networking options for both on-prem and public cloud environments, refer to [this guide](https://docs.projectcalico.org/networking/determine-best-networking).
{{% /notice %}}

For demonstration purposes, we'll use a BGP-based configuration option with external off-cluster route-reflector. The fully converged and populated IP and MAC tables will look like this:

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=5Q_VDU4fQs1RRTjQc7gX&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


### Lab

Assuming that the lab environment is already [set up](/lab/), calico can be enabled with the following commands:

```bash
make calico 
```

Check that the calico-node daemonset has all pods in `READY` state:

```bash
$ kubectl -n calico-system get daemonset
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
calico-node   3         3         3       3            3           kubernetes.io/os=linux   61s
```

Now we need to "kick" all Pods to restart and pick up the new CNI plugin:

```bash
make nuke-all-pods
```

To make sure kube-proxy and calico set up the right set of NAT rules, existing NAT tables need to be flushed and re-populated:

```
make flush-nat && make calico-restart
```

Build and start a GoBGP-based route reflector: 

```
make gobgp-build && make gobgp-rr
```

Finally, reconfigure Calico's BGP daemonset to peer with the GoBGP route reflector:

```
make gobgp-calico-patch 
```

--- 

Here's how the information from the diagram can be validated (using `worker2` as an example):

1. Pod IP and default route

```bash
$ NODE=k8s-guide-worker2 make tshoot
bash-5.0# ip -4 -br addr show dev eth0
eth0@if2         UP             10.244.190.5/32 

bash-5.0# ip route
default via 169.254.1.1 dev eth0 
169.254.1.1 dev eth0 scope link 
```

Note how the default route is pointing to the fake next-hop address `169.254.1.1`. This will be the same for all Pods and this IP will resolve to the same MAC address configured on all veth links:

```
bash-5.0# ip neigh
169.254.1.1 dev eth0 lladdr ee:ee:ee:ee:ee:ee REACHABLE
```

2. Node's routing table

```bash
$ docker exec k8s-guide-worker2 ip route
default via 172.18.0.1 dev eth0 
10.244.175.0/24 via 172.18.0.4 dev eth0 proto bird 
10.244.190.0 dev calid7f7f4e15dd scope link 
blackhole 10.244.190.0/24 proto bird 
10.244.190.1 dev calid599cd3d268 scope link 
10.244.190.2 dev cali82aeec08a68 scope link 
10.244.190.3 dev calid2e34ad38c6 scope link 
10.244.190.4 dev cali4a822ce5458 scope link 
10.244.190.5 dev cali0ad20b06c15 scope link 
10.244.236.0/24 via 172.18.0.5 dev eth0 proto bird 
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.3 
```

A few interesting things to note in the above output:

* The 2 x /24 routes programmed by `bird` are the PodCIDR ranges of the other two nodes.
* The blackhole /24 route is the PodCIDR of the local node.
* Inside the local PodCIDR there's a /32 host-route configured for each running Pod.

3. BGP RIB of the GoBGP route reflector

```
docker exec gobgp gobgp global rib

   Network              Next Hop             AS_PATH              Age        Attrs
*> 10.244.175.0/24      172.18.0.4                                00:05:04   [{Origin: i} {LocalPref: 100}]
*> 10.244.190.0/24      172.18.0.3                                00:05:04   [{Origin: i} {LocalPref: 100}]
*> 10.244.236.0/24      172.18.0.5                                00:05:03   [{Origin: i} {LocalPref: 100}]

```

### A day in the life of a Packet

Let's track what happens when Pod-1 (actual name is net-tshoot-rg2lp) tries to talk to Pod-3 (net-tshoot-6wszq).

{{% notice note %}}
We'll assume that the ARP and MAC tables are converged and fully populated. In order to do that issue a ping from Pod-1 to Pod-3's IP (10.244.236.0)
{{% /notice %}}

0. Check the peer interface index of the veth link of Pod-1:

```
$ kubectl -n default exec net-tshoot-rg2lp -- ip -br addr show dev eth0
3: eth0@if14: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1410 qdisc noqueue state UP mode DEFAULT group default 
    link/ether b2:24:13:ec:77:42 brd ff:ff:ff:ff:ff:ff link-netnsid 0
```

This information (if14) will be used in step 2 to identify the node side of the veth link.

1. Pod-1 wants to send a packet to `10.244.236.0`. Its network stack performs a route lookup:

```bash
$ kubectl -n default exec net-tshoot-rg2lp -- ip route get 10.244.236.0
10.244.236.0 via 169.254.1.1 dev eth0 src 10.244.175.4 uid 0 
    cache 
```

2. The nexthop IP is `169.254.1.1` on `eth0`, ARP table lookup is needed to get the destination MAC:

```bash
$ kubectl -n default exec net-tshoot-rg2lp -- ip neigh show 169.254.1.1
169.254.1.1 dev eth0 lladdr ee:ee:ee:ee:ee:ee STALE
```

As mentioned above, the node side of the veth link doesn't have any IP configured:

```
$ docker exec k8s-guide-worker ip addr show dev if14       
14: calic8441ae7134@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1410 qdisc noqueue state UP group default 
    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netns cni-262ff521-1b00-b1c9-f0d5-0943a48a2ddc
```

So in order to respond to an ARP request for `169.254.1.1`, all veth links have proxy ARP enabled:
```
$ docker exec k8s-guide-worker cat /proc/sys/net/ipv4/conf/calic8441ae7134/proxy_arp
1
```

3. The packet reaches the root namespace of the ingress node, where another L3 lookup takes place:

```
$ docker exec k8s-guide-worker ip route get 10.244.236.0 fibmatch
10.244.236.0/24 via 172.18.0.5 dev eth0 proto bird 
```

4. The packet is sent to the target node where another FIB lookup is performed:

```
$ docker exec k8s-guide-control-plane ip route get 10.244.236.0 fibmatch
10.244.236.0 dev cali0ec6986a945 scope link
```

The target IP is reachable over the `veth` link so ARP is used to determine the destination MAC address:

```
docker exec k8s-guide-control-plane ip neigh show 10.244.236.0
10.244.236.0 dev cali0ec6986a945 lladdr de:85:25:60:86:5b STALE
```

5. Finally, the packet gets delivered to the `eth0` interface of the target pod:

```
kubectl exec net-tshoot-6wszq -- ip -br addr show dev eth0
eth0@if2         UP             10.244.236.0/32 fe80::dc85:25ff:fe60:865b/64 
```

### SNAT functionality

SNAT functionality for traffic egressing the cluster is done in two stages:

1. `cali-POSTROUTING` chain is inserted at the top of the POSTROUTING chain.

2. Inside that chain `cali-nat-outgoin` is SNAT'ing all egress traffic originating from `cali40masq-ipam-pools`.

```
iptables -t nat -vnL
<...>
Chain POSTROUTING (policy ACCEPT 5315 packets, 319K bytes)
 pkts bytes target     prot opt in     out     source               destination         
 7844  529K cali-POSTROUTING  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:O3lYWMrLQYEMJtB5 */ 
<...>
Chain cali-POSTROUTING (1 references)
 pkts bytes target     prot opt in     out     source               destination         
 7844  529K cali-fip-snat  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:Z-c7XtVd2Bq7s_hA */
 7844  529K cali-nat-outgoing  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:nYKhEzDlr11Jccal */
<...>
Chain cali-nat-outgoing (1 references)
 pkts bytes target     prot opt in     out     source               destination         
    1    84 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:flqWnvo8yq4ULQLa */ match-set cali40masq-ipam-pools src ! match-set cali40all-ipam-pools dst random-fully
 
```

Calico configures all IPAM pools as ipsets for a more efficient matching within iptables. These pools can be viewed on each individual node:

```
$ docker exec k8s-guide-control-plane ipset -L cali40masq-ipam-pools
Name: cali40masq-ipam-pools
Type: hash:net
Revision: 6
Header: family inet hashsize 1024 maxelem 1048576
Size in memory: 512
References: 1
Number of entries: 1
Members:
10.244.128.0/17
```

### Caveats and Gotchas

* Calico support GoBGP-based routing, but only as an [experimental feature](https://github.com/projectcalico/calico-bgp-daemon).
* BGP configs are generated from templates based on the contents of the Calico [datastore](https://docs.projectcalico.org/getting-started/kubernetes/hardway/the-calico-datastore). This makes the customization of the generated BGP config very [problematic](https://github.com/projectcalico/calico/issues/1604). 



