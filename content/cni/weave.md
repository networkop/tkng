---
title: "weave"
menuTitle: "weave"
date: 2020-10-17T12:33:04+01:00
weight: 14
---

[Weave Net](https://www.weave.works/docs/net/latest/overview/) is one of the "heavyweight" CNI plugins with a wide range of features and its own separate contorl plane to disseminate routing information between nodes. The scope of the plugin extends far beyond the base CNI functionality examined in this chapter and includes Network Policies, Encryption, Multicast and support for other container orchestration platforms (Swarm, Mesos). 

Following a similar pattern, let's examine how `weave` achieves the base CNI plugin functionality:

* **Connectivity** is setup by the `weave-net` binary by attaching all pods to the `weave` Linux bridge. The bridge is, in turn, attached to the Open vSwitch's kernel datapath which forwards the packets over the vxlan interface towards the target node.

{{% notice info %}}
Although it would have been possible to attach containers directly to the OVS datapath (ODP), Linux bridge plays the role of an egress router for all local pods so that ODP is only used for pod-to-pod forwarding.
{{% /notice %}}

* **Reachability** is establish by two separate mechanisms:

    1. [Weave Mesh](https://github.com/weaveworks/mesh) helps agents discover each other, check health, connectivity and exchange node-local details, e.g. IPs for VXLAN tunnel endpoint.
    2. OVS datapath acts as a standard learning L2 switch with flood-and-learn behaviour being [programmed](https://github.com/weaveworks/go-odp) by the local agent (based on information distributed by the Mesh). All pods get their IPs from a single cluster-wide subnet and see their peers as if they were attached to a single broadcast domain.


{{% notice info %}}
The cluster-wide CIDR range is still split into multiple non-overlapping ranges, which may look like a node-local pod CIDRs, however all Pod IPs still have the same prefix length as the cluster CIDR, effectively making them part of a single L3 subnet.
{{% /notice %}}


The fully converged and populated IP and MAC tables will look like this:

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=GzriSjSBuyDBEbTt2saz&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}




### Lab


Assuming that the lab is already [set up](/lab/), weave can be enabled with the following commands:

```bash
make weave 
```

Check that the weave daemonset has reached the `READY` state:

```bash
$ kubectl -n kube-system get daemonset -l name=weave-net
NAME        DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
weave-net   3         3         3       3            3           <none>          30s
```

Now we need to "kick" all Pods to restart and pick up the new CNI plugin:

```bash
make nuke-all-pods
```

To make sure kube-proxy and weave set up the right set of NAT rules, existing NAT tables need to be flushed and repopulated:

```
make flush-nat && make weave-restart
```

--- 

Here's how the information from the diagram can be validated (using `worker2` as an example):

1. Pod IP and default route

```bash
$ NODE=k8s-guide-worker2 make tshoot
bash-5.0# ip route
default via 10.44.0.0 dev eth0 
10.32.0.0/12 dev eth0 proto kernel scope link src 10.44.0.7 
```

2. Node routing table

```bash
$ docker exec -it k8s-guide-worker2 ip route
default via 172.18.0.1 dev eth0 
10.32.0.0/12 dev weave proto kernel scope link src 10.44.0.0 
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.4 
```

3. ODP configuration and flows (ouput ommited for brevity)


```
WEAVEPOD=$(kubectl get pods -n kube-system -l name=weave-net --field-selector spec.nodeName=k8s-guide-worker2 -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $WEAVEPOD -n kube-system -- /home/weave/weave --local report  
```

### A day in the life of a Packet

Let's track what happens when Pod-1 (actual name is net-tshoot-22drp) tries to talk to Pod-3 (net-tshoot-pbp7z).

{{% notice note %}}
We'll assume that the ARP and MAC tables are converged and fully populated. In order to do that issue a ping command from Pod-1 to Pod-3's IP (10.40.0.1)
{{% /notice %}}


1. Pod-1 wants to send a packet to `10.40.0.1`. Its network stack looks up the routing table:

```bash
$ kubectl exec -it net-tshoot-22drp -- ip route get 10.40.0.1
10.40.0.1 dev eth0 src 10.32.0.4 uid 0 
    cache 
```

2. Since the target IP is from a directly-connected network, the next step is to check its local ARP table:

```bash
$ kubectl exec -it net-tshoot-22drp -- ip neigh show 10.40.0.1
10.40.0.1 dev eth0 lladdr d6:8d:31:c4:95:85 STALE
```

3. The packet is sent out of the veth interface and hits the `weave` bridge in the root NS, where a L2 lookup is performed:

```
$ docker exec -it k8s-guide-worker bridge fdb get d6:8d:31:c4:95:85 br weave
d6:8d:31:c4:95:85 dev vethwe-bridge master weave
```

4. The packet is sent from the `weave` bridge down to the OVS kernel datapath over a veth link:

```
$ docker exec -it k8s-guide-worker ip link | grep vethwe-
12: vethwe-datapath@vethwe-bridge: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1376 qdisc noqueue master datapath state UP mode DEFAULT group default 
13: vethwe-bridge@vethwe-datapath: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1376 qdisc noqueue master weave state UP mode DEFAULT group default 
```

5. The ODP does a flow lookup to determine what actions to apply to the packet (the output is redacted for brevity)

```
$ WEAVEPOD=$(kubectl get pods -n kube-system -l name=weave-net --field-selector spec.nodeName=k8s-guide-worker -o jsonpath='{.items[0].metadata.name}')
$ kubectl exec -it $WEAVEPOD -n kube-system -- /home/weave/weave --local report 
<...>
        {
          "FlowKeys": [
            "UnknownFlowKey{type: 22, key: 00000000, mask: 00000000}",
            "EthernetFlowKey{src: 0a:75:b7:d0:31:58, dst: d6:8d:31:c4:95:85}",
            "UnknownFlowKey{type: 25, key: 00000000000000000000000000000000, mask: 00000000000000000000000000000000}",
            "UnknownFlowKey{type: 23, key: 0000, mask: 0000}",
            "InPortFlowKey{vport: 1}",
            "UnknownFlowKey{type: 24, key: 00000000, mask: 00000000}"
          ],
          "Actions": [
            "SetTunnelAction{id: 0000000000ade6da, ipv4src: 172.18.0.3, ipv4dst: 172.18.0.2, ttl: 64, df: true}",
            "OutputAction{vport: 2}"
          ],
          "Packets": 2,
          "Bytes": 84,
          "Used": 258933878
        },
<...>
```

6. ODP encapsulates the original packet into a VXLAN frame ands sends the packet out of its local vxlan port:

```
$ kubectl exec -it $WEAVEPOD -n kube-system -- /home/weave/weave --local report   | jq '.Router.OverlayDiagnostics.fastdp.Vports[2]' 
{
  "ID": 2,
  "Name": "vxlan-6784",
  "TypeName": "vxlan"
}
```

7. The VXLAN frame gets L2-switched by the `kind` bridge and arrives at the `control-plane` node, where another ODP lookup is performed

```
$ WEAVEPOD=$(kubectl get pods -n kube-system -l name=weave-net --field-selector spec.nodeName=k8s-guide-control-plane -o jsonpath='{.items[0].metadata.name}')
$ kubectl exec -it $WEAVEPOD -n kube-system -- /home/weave/weave --local report 
<...>
          {
            "FlowKeys": [
              "UnknownFlowKey{type: 22, key: 00000000, mask: 00000000}",
              "UnknownFlowKey{type: 24, key: 00000000, mask: 00000000}",
              "UnknownFlowKey{type: 25, key: 00000000000000000000000000000000, mask: 00000000000000000000000000000000}",
              "TunnelFlowKey{id: 0000000000ade6da, ipv4src: 172.18.0.3, ipv4dst: 172.18.0.2}",
              "InPortFlowKey{vport: 2}",
              "UnknownFlowKey{type: 23, key: 0000, mask: 0000}",
              "EthernetFlowKey{src: 0a:75:b7:d0:31:58, dst: d6:8d:31:c4:95:85}"
            ],
            "Actions": [
              "OutputAction{vport: 1}"
            ],
            "Packets": 3,
            "Bytes": 182,
            "Used": 259264545
          },
<...>
```

8. The output port is the veth link connecting ODP to the `weave` bridge:

```
$ kubectl exec -it $WEAVEPOD -n kube-system -- /home/weave/weave --local report   | jq '.Router.OverlayDiagnostics.fastdp.Vports[1]' 
{
  "ID": 1,
  "Name": "vethwe-datapath",
  "TypeName": "netdev"
}
```

9. Following another L2 lookup in the `weave` bridge, the packet is sent down the veth link connected to the target Pod-3:

```
$ docker exec -it k8s-guide-control-plane bridge fdb get d6:8d:31:c4:95:85 br weave
d6:8d:31:c4:95:85 dev vethwepl6be12f5 master weave 
```

10. Finally, the packet gets delivered to the `eth0` interface of the target pod:

```
$ kubectl exec -it net-tshoot-pbp7z -- ip link show dev eth0 
16: eth0@if17: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1376 qdisc noqueue state UP mode DEFAULT group default 
    link/ether d6:8d:31:c4:95:85 brd ff:ff:ff:ff:ff:ff link-netnsid 0
```

### SNAT functionality

SNAT functionality for traffic egressing the cluster is done in two stages:

1. All packets that don't match the cluster CIDR range, get sent to the IP of the local `weave` bridge which sends them down the default route already configured in the root namespace.

2. A new `WEAVE` chain gets appended to the POSTROUTING chain which matches all packets from the cluster IP range `10.32.0.0/12` destined to all non-cluster IPs `!10.32.0.0/12` and translates all flows leaving the node (`MASQUERADE`):

```
iptables -t nat -vnL
<...>
Chain POSTROUTING (policy ACCEPT 6270 packets, 516K bytes)
 pkts bytes target     prot opt in     out     source               destination         
51104 4185K WEAVE      all  --  *      *       0.0.0.0/0            0.0.0.0/0    
<...>
Chain WEAVE (1 references)
 pkts bytes target     prot opt in     out     source               destination         
    4   336 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set weaver-no-masq-local dst /* Prevent SNAT to locally running containers */
    0     0 RETURN     all  --  *      *       10.32.0.0/12         224.0.0.0/4         
    0     0 MASQUERADE  all  --  *      *      !10.32.0.0/12         10.32.0.0/12        
    2   120 MASQUERADE  all  --  *      *       10.32.0.0/12        !10.32.0.0/12    
```


### Caveats and Gotchas

* The official installation guide contains a number of [things to watch out for](https://www.weave.works/docs/net/latest/kubernetes/kube-addon/#-things-to-watch-out-for).
* Addition/Deletion or intermittent connectivity to nodes [results](https://github.com/weaveworks/weave/issues/3645) in flow invalidation on all nodes, which, for a brief period of time, disupts all connections until the flood-and-learn re-populates all forwarding tables.



### Additional reading:

[Weave's IPAM](https://www.weave.works/docs/net/latest/tasks/ipam/ipam/)   
[Overlay Method Selection](https://github.com/weaveworks/weave/blob/master/docs/fastdp.md)   
[OVS dataplane Implementation Details](http://www.openvswitch.org//support/ovscon2016/8/0935-pumputis.pdf)   


