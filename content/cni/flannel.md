---
title: "flannel"
menuTitle: "flannel"
date: 2020-09-13T17:33:04+01:00
weight: 12
---

[Flannel](https://github.com/coreos/flannel) is another example of a dual CNI plugin design:

* **Connectivity** is taken care of by the `flannel` binary. This binary is a `metaplugin` -- a plugin that wraps other reference CNI plugins. In the [simplest case](https://github.com/containernetworking/plugins/tree/master/plugins/meta/flannel#operation), it generates a `bridge` plugin configuration and "delegates" the connectivity setup to it.

* **Reachability** is taken care of by the Daemonset running `flanneld`. Here's an approximate sequence of actions of what happens when the daemon starts:
    1. It queries the Kubernetes Node API to discover its local `PodCIDR` and `ClusterCIDR`. This information is saved in the `/run/flannel/subnet.env` and is used by the flannel metaplugin to generate the `host-local` IPAM configuration.
    2. It creates a vxlan interfaces called `flannel.1` and updates the Kubernetes Node object with its MAC address (along with its own Node IP).
    3. Using Kubernetes API, it discovers the VXLAN MAC information of other Nodes and builds a local unicast head-end replication (HER) table for its vxlan interface.

{{% notice info %}}
This plugin assumes that daemons have a way to exchange information (e.g. VXLAN MAC). Previously, this required a separate database (hosted etcd) which was considered a big disadvantage. The new version of the plugin uses Kubernetes API to store that information in annotations of a Node API object.
{{% /notice %}}

The fully converged IP and MAC tables will look like this:

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=jdjgs82ws8dfcGyB_vlg&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}





### Lab

Assuming that the lab is already [setup](/lab/), flannel can be enabled with the following 3 commands:

```bash
make flannel
```

Check that the flannel daemonset has reached the `READY` state:

```bash
$ kubectl -n kube-system get daemonset -l app=flannel
NAME              DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
kube-flannel-ds   3         3         3       3            3           <none>          90s
```

Now we need to "kick" all Pods to restart and pick up the new CNI plugin:

```bash
make nuke-all-pods
```

Here's how the information from the diagram can be validated (using `worker2` as an example):

1. Pod IP and default route

```bash
$ NODE=k8s-guide-worker2 make tshoot
bash-5.0# ip route get 1.1
1.1.0.0 via 10.244.2.1 dev eth0 src 10.244.2.6 uid 0
```

2. Node routing table

```bash
$ docker exec -it k8s-guide-worker2 ip route
default via 172.18.0.1 dev eth0
10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink
10.244.1.0/24 via 10.244.1.0 dev flannel.1 onlink
10.244.2.0/24 dev cni0 proto kernel scope link src 10.244.2.1
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.2
```

3. Static ARP entries for NextHops

```bash
$ docker exec -it k8s-guide-worker2 ip neigh | grep PERM
10.244.1.0 dev flannel.1 lladdr ce:0a:4f:22:a4:2a PERMANENT
10.244.0.0 dev flannel.1 lladdr 5a:11:99:ab:8c:22 PERMANENT

```

4. VXLAN forwarding database

```bash
$ docker exec -it k8s-guide-worker2 bridge fdb show dev flannel.1
5a:11:99:ab:8c:22 dst 172.18.0.3 self permanent
ce:0a:4f:22:a4:2a dst 172.18.0.4 self permanent
```

### A day in the life of a Packet

Let's track what happens when Pod-1 tries to talk to Pod-3.

{{% notice note %}}
We'll assume that the ARP and MAC tables are converged and fully populated.
{{% /notice %}}

1\. Pod-1 wants to send a packet to `10.244.0.2`. Its network stack looks up the routing table to find the NextHop IP:

```bash
$ kubectl exec -it net-tshoot-4sg7g -- ip route get 10.244.0.2
10.244.0.2 via 10.244.1.1 dev eth0 src 10.244.1.6 uid 0
```

2\. The packet reaches the `cbr0` bridge in the root network namespace, where the lookup is performed again:

```bash
$ docker exec -it k8s-guide-worker ip route get 10.244.0.2
10.244.0.2 via 10.244.0.0 dev flannel.1 src 10.244.1.0 uid 0
```

3\. The NextHop and the outgoing interfaces are set, the ARP table lookup returns the static entry provisioned by the `flanneld`:

```bash
$ docker exec -it k8s-guide-worker ip neigh get 10.244.0.0 dev flannel.1
10.244.0.0 dev flannel.1 lladdr 5a:11:99:ab:8c:22 PERMANENT
```

4\. Next, the FDB of the VXLAN interface is consulted to find out the destination VTEP IP:

```bash
$ docker exec -it k8s-guide-worker bridge fdb | grep 5a:11:99:ab:8c:22
5a:11:99:ab:8c:22 dev flannel.1 dst 172.18.0.3 self permanent
```

5\. The packet is VXLAN-encapsulated and sent to the `control-node` where `flannel.1` matches the VNI and the VXLAN MAC:

```bash
$ docker exec -it k8s-guide-control-plane ip link show flannel.1
3: flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN mode DEFAULT group default
    link/ether 5a:11:99:ab:8c:22 brd ff:ff:ff:ff:ff:ff
```

6\. The packet gets decapsulated and its original destination IP looked up in the main routing table:

```bash
$ docker exec -it k8s-guide-control-plane ip route get 10.244.0.2
10.244.0.2 dev cni0 src 10.244.0.1 uid 0
```

7\. The ARP and bridge tables are then consulted to find the outgoing veth interface:

```bash
$ docker exec -it k8s-guide-control-plane ip neigh get 10.244.0.2 dev cni0
10.244.0.2 dev cni0 lladdr 7e:46:23:43:6f:ec REACHABLE
$ docker exec -it k8s-guide-control-plane bridge fdb get 7e:46:23:43:6f:ec br cni0
7e:46:23:43:6f:ec dev vethaabf9eb2 master cni0
```

8\. Finally, the packet arrives in the Pod-3's network namespace where it gets processed by the local network stack:

```bash
$ kubectl exec -it net-tshoot-rkg46 -- ip route get 10.244.0.2
local 10.244.0.2 dev lo src 10.244.0.2 uid 0
```

### SNAT functionality

Similar to [kindnet](/cni/kindnet/) `flanneld` sets up the SNAT rules to enable egress connectivity for the Pods, the only difference is that it does this directly inside the `POSTROUTING` chain:

```bash
Chain POSTROUTING (policy ACCEPT 327 packets, 20536 bytes)
 pkts bytes target     prot opt in     out     source               destination
    0     0 RETURN     all  --  *      *       10.244.0.0/16        10.244.0.0/16
    0     0 MASQUERADE  all  --  *      *       10.244.0.0/16       !224.0.0.0/4          random-fully
    0     0 RETURN     all  --  *      *      !10.244.0.0/16        10.244.0.0/24
    0     0 MASQUERADE  all  --  *      *      !10.244.0.0/16        10.244.0.0/16        random-fully
```

### Caveats and Gotchas

* The official [installation manifest](https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml) does not install the CNI binary by default. This binary is distributed as a part of [reference CNI plugins](https://github.com/containernetworking/plugins/releases) and needs to be installed separately.
* flannel can run in a `direct routing` mode, which acts by installing static routes for hosts on the same subnet.
* flannel can use generic UDP encapsulation instead of VXLAN