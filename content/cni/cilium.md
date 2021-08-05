---
title: "cilium"
menuTitle: "cilium"
date: 2020-12-20T12:33:04+01:00
weight: 16
---

[Cilium](https://docs.cilium.io/en/v1.9/) is one of the most advanced and powerful Kubernetes networking solutions. At its core, it utilizes the power of [eBPF](https://ebpf.io/) to perform a wide range of functionality ranging from traffic filtering for [NetworkPolicies](https://docs.cilium.io/en/v1.9/concepts/kubernetes/policy) all the way to CNI and [kube-proxy replacement](https://docs.cilium.io/en/v1.9/gettingstarted/kubeproxy-free/). Arguably, CNI is the least important part of Cilium as it doesn't add as much values as, say, Host-Reachable Services, and is often dropped in favour of other CNI plugins (see [CNI chaining](https://docs.cilium.io/en/v1.9/gettingstarted/cni-chaining/#id1)). However, it still exists and satisfies the Kubernetes network model [requirements](/cni/#main-goals) in a very unique way, which is why it is worth exploring it separately from the rest of the Cilium functionality.


* **Connectivity** is set up by creating a `veth` link and moving one side of that link into a Pod's namespace. The other side of the link is left dangling in the node's root namespace. Cilium attaches eBPF programs to ingress TC hooks of these links in order to intercept all incoming packets for further processing.

{{% notice note %}}
One thing to note is that `veth` links in the root namespace do not have any IP address configured and most of the network connectivity and forwarding is performed within eBPF programs.
{{% /notice %}}

* **Reachability** is implemented differently, depending on Cilium's configuration:

    1. In the `tunnel` mode, Cilium sets up a number of VXLAN or Geneve interfaces and forwards traffic over them.

    2. In the `native-routing` mode, Cilium does nothing to setup reachability, assuming that it will be provided externally. This is normally done either by the underlying SDN (for cloud use-cases) or by native OS routing (for on-prem use-cases) which can be orchestrated with static routes or [BGP](https://docs.cilium.io/en/v1.9/gettingstarted/bird/).


For demonstration purposes, we'll use a VXLAN-based configuration option and the following network topology:

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=xih7dsaNVfet26WuHxSm&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


## Lab


### Preparation


Assuming that the lab environment is already [set up](/lab/), Cilium can be enabled with the following command:

```bash
make cilium 
```

Wait for Cilium daemonset to initialize:

```bash
make cilium-wait
```

Now we need to "kick" all Pods to restart and pick up the new CNI plugin:

```bash
make nuke-all-pods
```

To make sure there's is no interference from `kube-proxy` we'll remove it completely along with any IPTables rules set up by it:

```
make nuke-kube-proxy
```

Check that the cilium is healthy:

```bash
$ make cilium-check | grep health
Cilium health daemon:       Ok
Controller Status:      	40/40 healthy
Cluster health:         	3/3 reachable   (2021-08-02T19:52:07Z)
```

### Walkthrough

Here's how the information from the above diagram can be validated (using `worker2` as an example):

#### 1. Pod IP and default route

```bash
$ NODE=k8s-guide-worker2 make tshoot
bash-5.0# ip -4 -br addr show dev eth0
eth0@if24        UP             10.0.0.210/32 

bash-5.0# ip route
default via 10.0.0.215 dev eth0 mtu 1450 
10.0.0.215 dev eth0 scope link 
```

The default route has its nexthop statically pinned to `eth0@if24`, which is also where ARP requests are sent:

```
bash-5.0# ip neigh
10.0.0.215 dev eth0 lladdr da:0c:20:4a:86:f7 REACHABLE
```

As mentioned above, the peer side of `eth0@if24` does not have any IP configured, so ARP resolution requires a bit of eBPF magic, described below.

#### 2. Node's eBPF programs:

Find out the name of the Cilium agent running on Node `worker-2`:

```bash
NODE=k8s-guide-worker2
cilium=$(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
```

Each Cilium agent contains a copy of [`bpftool`](https://twitter.com/qeole/status/1101452445153222656) which can be used to retrieve the list of eBPF programs along with their points attachment:

```bash
$ kubectl -n cilium exec -it $cilium -- bpftool net show 
xdp:

tc:
cilium_net(9) clsact/ingress bpf_host_cilium_net.o:[to-host] id 2746
cilium_host(10) clsact/ingress bpf_host.o:[to-host] id 2734
cilium_host(10) clsact/egress bpf_host.o:[from-host] id 2740
cilium_vxlan(11) clsact/ingress bpf_overlay.o:[from-overlay] id 2291
cilium_vxlan(11) clsact/egress bpf_overlay.o:[to-overlay] id 2719
eth0(17) clsact/ingress bpf_netdev_eth0.o:[from-netdev] id 2754
eth0(17) clsact/egress bpf_netdev_eth0.o:[to-netdev] id 2775
lxc_health(18) clsact/ingress bpf_lxc.o:[from-container] id 2794
lxcdae72534e167(20) clsact/ingress bpf_lxc.o:[from-container] id 2806
lxcb79e11918044(22) clsact/ingress bpf_lxc.o:[from-container] id 2828
lxc473b3117af85(24) clsact/ingress bpf_lxc.o:[from-container] id 2895
```

Each interface is listed together with its link index, so it's easy to spot the program attached to `eth0@if24`. 

{{% notice info %}}
Attached eBPF programs can also be discovered using `tc filter show dev lxc473b3117af85 ingress` command.
{{% /notice %}}

Use `bpftool prog show id` to view additional information about a program, including a list of attached eBPF maps:

```bash
kubectl -n cilium exec -it $cilium -- bpftool prog show id 2895
2895: sched_cls  tag 8ac62d31226a84ef  gpl
	loaded_at 2020-12-20T09:52:11+0000  uid 0
	xlated 28984B  jited 16726B  memlock 32768B  map_ids 450,143,165,145,151,152,338,227,449,148,147,149,167,166,146,141,339,150
```



The program itself can be found on Cilium's [Github page](https://github.com/cilium/cilium) in `bpf/bpf_lxc.c`. The code is very readable and easy to follow even for people not familiar with C. Below is an abridged version of the [from-container](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L816) program, showing only the relevant code paths:

```c
/* Attachment/entry point is ingress for veth, egress for ipvlan. */
__section("from-container")
int handle_xgress(struct __ctx_buff *ctx)
{
    switch (proto) {
	case bpf_htons(ETH_P_IP):
		invoke_tailcall_if(__or(__and(is_defined(ENABLE_IPV4), is_defined(ENABLE_IPV6)),
					is_defined(DEBUG)),
				   CILIUM_CALL_IPV4_FROM_LXC, tail_handle_ipv4);
		break;
	case bpf_htons(ETH_P_ARP):
		ep_tail_call(ctx, CILIUM_CALL_ARP);
        break;
    }
}
```

Inside the `handle_xgress` function, packet's Ethernet protocol number is examined to determine what to do with it next. Following the path an ARP packet would take as an example, the next call is to [`CILIUM_CALL_ARP`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L816) program:

```c
/*
 * ARP responder for ARP requests from container
 * Respond to IPV4_GATEWAY with NODE_MAC
 */
__section_tail(CILIUM_MAP_CALLS, CILIUM_CALL_ARP)
int tail_handle_arp(struct __ctx_buff *ctx)
{
    union macaddr mac = NODE_MAC;
	union macaddr smac;
    __be32 sip;
	__be32 tip;
    return arp_respond(ctx, &mac, tip, &smac, sip, 0);
}
```

This leads to the `cilium/bpf/lib/apr.h` where ARP reply is first [prepared](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/arp.h#L79) and then [sent back](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/arp.h#L86) to the ingress interface using the redirect action:

```c
static __always_inline int
arp_respond(struct __ctx_buff *ctx, union macaddr *smac, __be32 sip,
	    union macaddr *dmac, __be32 tip, int direction)
{
	int ret = arp_prepare_response(ctx, smac, sip, dmac, tip);

	return ctx_redirect(ctx, ctx_get_ifindex(ctx), direction);
}
```

As is the case with all of the stateless ARP responders, a reply is crafted out of the original packet by swapping some of the fields while populating the other ones with well-known information (e.g. source MAC):

```c
arp_prepare_response(struct __ctx_buff *ctx, union macaddr *smac, __be32 sip,
		     union macaddr *dmac, __be32 tip)
{
	__be16 arpop = bpf_htons(ARPOP_REPLY);

	if (eth_store_saddr(ctx, smac->addr, 0) < 0 ||
	    eth_store_daddr(ctx, dmac->addr, 0) < 0 ||
	    ctx_store_bytes(ctx, 20, &arpop, sizeof(arpop), 0) < 0 ||
	    /* sizeof(macadrr)=8 because of padding, use ETH_ALEN instead */
	    ctx_store_bytes(ctx, 22, smac, ETH_ALEN, 0) < 0 ||
	    ctx_store_bytes(ctx, 28, &sip, sizeof(sip), 0) < 0 ||
	    ctx_store_bytes(ctx, 32, dmac, ETH_ALEN, 0) < 0 ||
	    ctx_store_bytes(ctx, 38, &tip, sizeof(tip), 0) < 0)
		return DROP_WRITE_ERROR;

	return 0;
}
```


#### 3. Node's eBPF maps.

`bpftool` is also helpful to view the list eBPF maps together with their persistent pinned location. The following command returns a structured list of all `lpm_trie`-type eBPF maps:

```
$ kubectl -n cilium exec -it $cilium -- bpftool map list --bpffs -j | jq '.[] | select( .type == "lpm_trie" )' | jq

{
  "bytes_key": 12,
  "bytes_memlock": 3215360,
  "bytes_value": 1,
  "flags": 1,
  "frozen": 0,
  "id": 168,
  "max_entries": 65536,
  "pinned": [
    "/sys/fs/bpf/tc/globals/cilium_lb4_source_range"
  ],
  "type": "lpm_trie"
}
{
  "bytes_key": 12,
  "bytes_memlock": 3215360,
  "bytes_value": 1,
  "flags": 1,
  "frozen": 0,
  "id": 176,
  "max_entries": 65536,
  "pinned": [],
  "type": "lpm_trie"
}
{
  "bytes_key": 12,
  "bytes_memlock": 3215360,
  "bytes_value": 1,
  "flags": 1,
  "frozen": 0,
  "id": 222,
  "max_entries": 65536,
  "pinned": [],
  "type": "lpm_trie"
}
{
  "bytes_key": 24,
  "bytes_memlock": 36868096,
  "bytes_value": 12,
  "flags": 1,
  "frozen": 0,
  "id": 338,
  "max_entries": 512000,
  "pinned": [
    "/sys/fs/bpf/tc/globals/cilium_ipcache"
  ],
  "type": "lpm_trie"
}
{
  "bytes_key": 24,
  "bytes_memlock": 36868096,
  "bytes_value": 12,
  "flags": 1,
  "frozen": 0,
  "id": 368,
  "max_entries": 512000,
  "pinned": [],
  "type": "lpm_trie"
}
{
  "bytes_key": 24,
  "bytes_memlock": 36868096,
  "bytes_value": 12,
  "flags": 1,
  "frozen": 0,
  "id": 428,
  "max_entries": 512000,
  "pinned": [],
  "type": "lpm_trie"
}

```    

One of the most interesting maps in the above list is `IPCACHE`, it is used to perform effecient IP Longest-Prefix Match lookups. Examine the contents of this map:


```
kubectl -n cilium exec -it $cilium -- bpftool map dump id 338 | head -n5
key:
40 00 00 00 00 00 00 01  0a 00 00 b9 00 00 00 00
00 00 00 00 00 00 00 00
value:
fe 6f 00 00 00 00 00 00  00 00 00 00
```


The key for the lookup is based on the [`ipcache_key`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/maps.h#L134) data structure:

```c
struct ipcache_key {
	struct bpf_lpm_trie_key lpm_key;
	__u16 pad1;
	__u8 pad2;
	__u8 family;
	union {
		struct {
			__u32		ip4;
			__u32		pad4;
			__u32		pad5;
			__u32		pad6;
		};
		union v6addr	ip6;
	};
} 
```

The returned value is based on the [`remote_endpoint_info`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/common.h#L223) data structure:

```c
struct remote_endpoint_info {
	__u32		sec_label;
	__u32		tunnel_endpoint;
	__u8		key;
};
```

#### 4. Control plane information.

eBPF maps are populated by Cilium agents running as daemonset and every agent posts information about its local environment to custom Kubernetes resources. For example, Cilium [Endpoints](https://docs.cilium.io/en/v1.9/concepts/terminology/#endpoints) can be viewed like this:

```bash
$ kubectl get ciliumendpoints.cilium.io net-tshoot-l8vwz -oyaml
apiVersion: cilium.io/v2
kind: CiliumEndpoint
metadata:
  name: net-tshoot-l8vwz
  namespace: default
status:
  encryption: {}
  external-identifiers:
    container-id: d6effe0cc6d567e4776a3701851d9ab278ff128adede9419c8fda34daf6b46ef
    k8s-namespace: default
    k8s-pod-name: net-tshoot-l8vwz
    pod-name: default/net-tshoot-l8vwz
  id: 92
  identity:
    id: 53731
    labels:
    - k8s:io.cilium.k8s.policy.cluster=default
    - k8s:io.cilium.k8s.policy.serviceaccount=default
    - k8s:io.kubernetes.pod.namespace=default
    - k8s:name=net-tshoot
  networking:
    addressing:
    - ipv4: 10.0.0.210
    node: 172.18.0.6
  state: ready

```

---

## A day in the life of a Packet

Now let's track what happens when Pod-1 tries to talk to Pod-3.

{{% notice note %}}
We'll assume that the ARP and MAC tables are converged and fully populated and we're tracing the first packet of a flow with no active conntrack entries.
{{% /notice %}}

Setup pointer variables for Pod-1, Pod-3 and Cilium agents running on egress and ingress Nodes:

```
NODE1=k8s-guide-worker
cilium1=$(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE1 -o jsonpath='{.items[0].metadata.name}')
pod1=$(kubectl get -l name=net-tshoot pods -n default --field-selector spec.nodeName=$NODE1 -o jsonpath='{.items[0].metadata.name}')
NODE3=k8s-guide-control-plane
cilium3=$(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE3 -o jsonpath='{.items[0].metadata.name}')
pod3=$(kubectl get -l name=net-tshoot pods -n default --field-selector spec.nodeName=$NODE3 -o jsonpath='{.items[0].metadata.name}')
```

#### 1. Check the routing table of Pod-1:

```
kubectl -n default exec -it $pod1 -- ip route get 10.0.1.110
10.0.1.110 via 10.0.2.184 dev eth0 src 10.0.2.99 uid 0 
    cache mtu 1450 
```

#### 2. Check the interface indices of Pod-1's veth link:
```
kubectl -n default exec -it $pod1 -- ip link show dev eth0
23: eth0@if24: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default 
    link/ether b2:10:ef:6b:fa:0a brd ff:ff:ff:ff:ff:ff link-netnsid 0
```

#### 3. Find the eBPF program attached to that interface


```
kubectl -n cilium exec -it $cilium1 -- bpftool net show | grep 24 

lxcda722d56d553(24) clsact/ingress bpf_lxc.o:[from-container] id 2901
```

#### 4. eBPF Packet processing on egress Node

{{% notice note %}}
For the sake of brevity, code walkthrough is reduced to a sequence of function calls only stopping at points when packet forwarding decisions are made.
{{% /notice %}}


1. Packet's header information is passed to the `handle_xgress`, defined in [`bpf/bpf_lxc.c`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c), where its Ethertype is [checked](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L841).
2. All IPv4 packets are [dispatched](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L770) to `handle_ipv4_from_lxc` via an intermediate [`tail_handle_ipv4`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L767) function.
3. Most of the packet processing decisions are made inside [`handle_ipv4_from_lxc`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L443). At some point the execution flow reaches [this part](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L538) of the function where destination IP lookup is [triggered](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L1299).
4. The `lookup_ip4_remote_endpoint` function is defined inside [`bpf/lib/eps.h`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/eps.h#L83) and uses `IPCACHE` eBPF map to look up information about a remote endpoint:

```c
#define lookup_ip4_remote_endpoint(addr) \
	ipcache_lookup4(&IPCACHE_MAP, addr, V4_CACHE_KEY_LEN)

ipcache_lookup4(struct bpf_elf_map *map, __be32 addr, __u32 prefix)
{
	struct ipcache_key key = {
		.lpm_key = { IPCACHE_PREFIX_LEN(prefix), {} },
		.family = ENDPOINT_KEY_IPV4,
		.ip4 = addr,
	};
	key.ip4 &= GET_PREFIX(prefix);
	return map_lookup_elem(map, &key);
}
```

To simulate a map lookup, we can use `bpftool map lookup` command and point it at a pinned location of the IPCACHE map. The key is based on the [`ipcache_key`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/maps.h#L134) struct with destination IP `10.0.1.110`, prefix length and [ENDPOINT_KEY_IPV4](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/common.h#L176) values specified:

```
kubectl -n cilium exec -it $cilium1 -- bpftool map lookup pinned /sys/fs/bpf/tc/globals/cilium_ipcache key hex 40 00 00 00 00 00 00 01 0a 00 01 6e 00 00 00 00 00 00 00 00 00 00 00 00
key:
40 00 00 00 00 00 00 01  0a 00 01 6e 00 00 00 00
00 00 00 00 00 00 00 00
value:
e3 d1 00 00 ac 12 00 05  00 00 00 00
```

The result contains one important value which will be used later to build an outer IP header:

* Target Node IP -- 172.18.0.5 (from `0xac 0x12 0x00 0x05`)

5. Once the lookup results are [processed](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L544), execution continues in `handle_ipv4_from_lxc` function and eventually reaches [this](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L681) encapsulation directive.

6. All encapsulation-related functions are defined inside [`cilium/bpf/lib/encap.h`](https://github.com/cilium/cilium/blob/v1.9.1/cilium/bpf/lib/encap.h) and the packet gets [VXLAN-encapsulated](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/encap.h#L136) and [redirected](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/encap.h#L153) straight to the egress VXLAN interface.

7. At this point the packet has all the necessary headers and is delivered to the ingress Node by the underlay (in our case it's docker's Linux bridge).


#### 5. eBPF packet processing on ingress Node

1. Once the VXLAN packet reaches the target Node, it triggers another eBPF hook:

```
kubectl -n cilium exec $cilium3 -- bpftool net show | grep vxlan

cilium_vxlan(5) clsact/ingress bpf_overlay.o:[from-overlay] id 2729
cilium_vxlan(5) clsact/egress bpf_overlay.o:[to-overlay] id 2842
```

2. This time it's the [`from-overlay`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c#L270) program located inside [`bpf/bpf_overlay.c`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c). 
3. All IPv4 packets get [processed](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c#L309) by the [`handle_ipv4`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c#L161) function.
4. Inside this function execution flow reaches [the point](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c#L225) where another map lookup is triggered. This lookup is needed to identify the local interface that's supposed to receive this packet and build the correct Ethernet header.
5. The [`lookup_ip4_endpoint`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/eps.h#L41) function is defined inside [`bpf/lib/eps.h`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/eps.h):

```c
static __always_inline __maybe_unused struct endpoint_info *
__lookup_ip4_endpoint(__u32 ip)
{
	struct endpoint_key key = {};

	key.ip4 = ip;
	key.family = ENDPOINT_KEY_IPV4;

	return map_lookup_elem(&ENDPOINTS_MAP, &key);
}
```

The `ENDPOINTS_MAP` is [pinned](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/maps.h#L17) in the file called [cilium_lxc](https://github.com/cilium/cilium/blob/v1.9.1/pkg/maps/lxcmap/lxcmap.go#L28) which can be found next to the `IPCACHE` map in `/sys/fs/bpf/tc/globals/` directory. The key for the lookup can be built based on the [`endpoint_key`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/common.h#L184) data structure by plugging in values of destination IP (10.0.1.110) and IPv4 [address family](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/common.h#L176). The resulting lookup will look similar to this:

```bash
kubectl -n cilium exec -it $cilium3 -- bpftool map lookup pinned /sys/fs/bpf/tc/globals/cilium_lxc key hex 0a 00 01 6e 00 00 00 00  00 00 00 00 00 00 00 00 01 00 00 00
key:
0a 00 01 6e 00 00 00 00  00 00 00 00 00 00 00 00
01 00 00 00
value:
0b 00 00 00 00 00 d6 07  00 00 00 00 00 00 00 00
6a 8c ee 3a 73 d5 00 00  3e 43 da fb c7 04 00 00
00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
```

The value gets read into the [`endpoint_info`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/common.h#L202) struct and contains the following information:

* Interface index of the host side of the veth link -- `0x0b`
* MAC address of the host side of the veth link -- `3e:43:da:fb:c7`
* MAC address of the Pod side of the veth link -- `6a:8c:ee:3a:73:d5`
* Endpoint ID (`lxc_id`) which is used in dynamic egress policy lookup -- `0xd6 0x07`

6. At this point the [lookup result](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c#L225) gets [passed](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_overlay.c#L233) to [`ipv4_local_delivery`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/l3.h#L103) which does two things:

* [Populates](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/l3.h#L50) source and destination MAC addresses and [decrements](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/l3.h#L45) TTL.
* Makes a [tail-call](https://github.com/cilium/cilium/blob/v1.9.1/bpf/lib/l3.h#L139) to another eBPF program identified by the `lxc_id`.

7. The last call is made to the [`to-container`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L1439) program that passes the packet's context through [`ipv4_policy`](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L1098) where, finally, it gets [redirected](https://github.com/cilium/cilium/blob/v1.9.1/bpf/bpf_lxc.c#L1247) the destination `veth` interface.


### SNAT functionality

Although Cilium supports eBPF-based masquerading, in the current lab this functionality had to be disabled due to its reliance on the [Host-Reachable Service](https://docs.cilium.io/en/v1.9/gettingstarted/host-services/#host-services) feature which is [known](https://docs.cilium.io/en/v1.9/gettingstarted/kind/#troubleshooting) to have problems with kind.

In our case Cilium falls back to traditional IPTables-based masquerading of external traffic:

```
$ docker exec  k8s-guide-worker2 iptables -t nat -vnL CILIUM_POST_nat | head -n3
Chain CILIUM_POST_nat (1 references)
 pkts bytes target     prot opt in     out     source               destination         
    8   555 MASQUERADE  all  --  *      !cilium_+  10.0.0.0/24         !10.0.0.0/24          /* cilium masquerade non-cluster */
```

{{% notice info %}}
Due to a [known issue](https://docs.cilium.io/en/v1.9/gettingstarted/kind/#unable-to-contact-k8s-api-server) with kind, make sure to run `make cilium-unhook` when you're finished with this Cilium lab to detach eBPF programs from the host cgroup.
{{% /notice %}}


### Caveats and Gotchas

* Cilium's kubeproxy-free functionality depends on recent Linux kernel versions and contains a number of known [limitations](https://docs.cilium.io/en/v1.9/gettingstarted/kubeproxy-free/#limitations).
* Since eBPF programs get loaded into the kernel, simulating a cluster on a shared kernel (e.g. with kind) may lead to unexpected issues. For full functionality testing, it is recommended to run each node in a dedicated VM, e.g. with something like [Firecracker](https://github.com/firecracker-microvm/firecracker) and [Ignite](https://github.com/weaveworks/ignite).



### Additional Reading

* [Cilium Code Walk Through Series](http://arthurchiao.art/blog/cilium-code-series/) including [Life of a Packet in Cilium](http://arthurchiao.art/blog/cilium-life-of-a-packet-pod-to-service/).

* [Cilium Datapath](https://docs.cilium.io/en/v1.9/concepts/ebpf/) from the official documentation site.

* [bpftool use-cases](https://twitter.com/qeole/status/1101452445153222656)