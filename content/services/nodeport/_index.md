---
title: "NodePort"
date: 2020-09-13T17:33:04+01:00
weight: 60
---

[NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#nodeport) builds on top of the ClusterIP Service and provides a way to expose a group of Pods to the outside world. At the API level, the only difference from the ClusterIP is the mandatory service type which has to be set to `NodePort`, the rest of the values can remain the same.

{{< highlight yaml "linenos=false,hl_lines=14 " >}}
apiVersion: v1
kind: Service
metadata:
  labels:
    app: FE
  name: FE
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: FE
  type: NodePort
{{< / highlight >}}


Whenever a new Kubernetes cluster gets built, one of the available configuration parameters is `service-node-port-range` which defines a range of ports to use for NodePort allocation and usually defaults to `30000-32767`. One interesting thing about NodePort allocation is that it is not managed by a controller. The configured port range value eventually gets passed to the `kube-apiserver` as an [argument](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/) and allocation happens as the API server [saves a Service resource](https://github.com/kubernetes/kubernetes/blob/b6d83f0ba3f155a4f6af9b37bf5511f66327cd5b/pkg/registry/core/service/storage/rest.go#L191) into its persistent storage (e.g. etcd cluster); a unique port is allocated for [both Nodeport and LoadBalancer](https://github.com/kubernetes/kubernetes/blob/b6d83f0ba3f155a4f6af9b37bf5511f66327cd5b/pkg/registry/core/service/storage/rest.go#L229) services. So by the time the Service definition makes it to the persistent storage, it already contains a couple of extra fields:

{{< highlight yaml "linenos=false,hl_lines=8 10 " >}}
apiVersion: v1
kind: Service
metadata:
  labels:
    app: FE
  name: FE
spec:
  clusterIP: 10.96.75.104
  ports:
  - nodePort: 30171
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: FE
  type: NodePort
{{< / highlight >}}

One of the side-effects of this kind of behaviour is that ClusterIP and NodePort values are immutable -- they cannot be changed throughout the lifecycle of an object. The only way to change or update an existing Service is to provide the right metadata and omit both ClusterIP and NodePort values from the spec.

From the networking point of view, NodePort's implementation is very easy to understand:

* For each port in the NodePort Service, API server allocated a unique port from the `service-node-port-range`.
* This port is programmed in the dataplane of each Node by the `kube-proxy` (or its equivalent) -- the most common implementations with [IPTables](/services/nodeport/#iptables-implementation), [IPVS](/services/nodeport/#ipvs-implementation) and [eBPF](/services/nodeport/#cilium-ebpf-implementation) are covered in the [Lab section](/services/nodeport/#lab) below.
* Any incoming packet matching one of the configured NodePorts will get destination NAT'ed to one of the healthy Endpoints and source NAT'ed (via masquerade/overload) to the address of the incoming interface. 
* The reply packet coming from the Pod will get reverse NAT'ed using the connection tracking entry set up by the incoming packet.

{{% notice note %}}
Both DNAT and SNAT can be avoided by using Direct server return (DSR) and `service.spec.externalTrafficPolicy` respectively. This is discussed in the [Optimisations chapter](/services/optimisations/)
{{% /notice %}}


The following diagram shows network connectivity for a couple of hypothetical NodePort Services. 

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=VX9x875tuyiW0x4ccqrl&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


{{% notice note %}}
One important thing worth remembering is that a NodePort Service is rarely used on its own. Most of the time, you'd use a [LoadBalancer](/services/loadbalancer/) type service which builds on top of the NodePort. That being said, NodePort services _can_ be quite useful on their own in environments where `LoadBalancer` is not available or in more static setups utilising [`spec.externalIPs`](https://kubernetes.io/docs/concepts/services-networking/service/#external-ips). 
{{% /notice %}}


## Lab

### Preparation

Refer to the respective chapters for the instructions on how to setup the [IPTables](/services/clusterip/dataplane/iptables/#lab-setup), [IPVS](/services/clusterip/dataplane/ipvs/#lab-setup) or [Cilium eBPF](/services/clusterip/dataplane/ebpf/#preparation) data planes.  Once the required data plane is configured, setup a test deployment with 3 Pods and expose it via a NodePort Service:

```
$ make deployment && make scale-up && make nodeport
kubectl create deployment web --image=nginx
deployment.apps/web created
kubectl scale --replicas=3 deployment/web
deployment.apps/web scaled
kubectl expose deployment web --port=80 --type=NodePort
service/web exposed
```

Confirm the assigned NodePort (e.g. `30510` in the output below) and take a note of the Endpoint addresses:

```
$ kubectl get svc web
NAME   TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web    NodePort   10.96.132.141   <none>        80:30510/TCP   43s
$ kubectl get ep
NAME   ENDPOINTS                                   AGE
web    10.244.1.6:80,10.244.2.7:80,10.244.2.8:80   45s
```

To verify that a NodePort service is functioning, first, determine IPs of each one of the cluster Nodes:

```
$ make node-ip-1
control-plane:192.168.224.3
$ make node-ip-2
worker:192.168.224.2
$ make node-ip-3
worker2:192.168.224.4
```

Combine each IP with the assigned NodePort value and check that there is external reachability from your host OS:

```
$ curl -s 192.168.224.3:30510 | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
$ curl -s 192.168.224.2:30510 | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
$ curl -s 192.168.224.4:30510 | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
```

{{% notice note %}}
NodePort and Endpoint addresses will differ between each one of the below scenarios.
{{% /notice %}}

Finally, setup the following command aliases:

```bash
NODE=k8s-guide-worker2
alias ipt="docker exec $NODE iptables -t nat -nvL"
alias ipv="docker exec $NODE ipvsadm -ln"
alias ips="docker exec $NODE ipset list"
alias cilium="kubectl -n cilium exec $(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].
metadata.name}') --"
```

---

### IPTables Implementation

According to Tim's [IPtables diagram](https://docs.google.com/drawings/d/1MtWL8qRTs6PlnJrW4dh8135_S9e2SaawT410bJuoBPk/edit), external packets get first intercepted in the `PREROUTING` chain and redirected to the `KUBE-SERVICES` chain:

```
$ ipt PREROUTING
Chain PREROUTING (policy ACCEPT 1 packets, 60 bytes)
 pkts bytes target     prot opt in     out     source               destination
  493 32442 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
    0     0 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1
```

The `KUBE-NODEPORTS` chain is appended to the bottom of the `KUBE-SERVICES` chain and uses [ADDRTYPE](https://ipset.netfilter.org/iptables-extensions.man.html) to only match packets that are destined to one of the locally configured addresses:

```
$ ipt KUBE-SERVICES | grep NODEPORT
    1    60 KUBE-NODEPORTS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service nodeports; NOTE: this must be the last rule in this chain */ ADDRTYPE match dst-type LOCAL
```

Each of the configured NodePort Services will have two entries -- one to enable SNAT masquerading in the `KUBE-POSTROUTING` chain (see [ClusterIP walkthrough](/clusterip/dataplane/iptables/#use-case-2-any-to-service-communication) for more details) and another one for Endpoint-specific DNAT actions:

```
$ ipt KUBE-NODEPORTS
Chain KUBE-NODEPORTS (1 references)
 pkts bytes target     prot opt in     out     source               destination
    1    60 KUBE-MARK-MASQ  tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ tcp dpt:30510
    1    60 KUBE-SVC-LOLE4ISW44XBNF3G  tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ tcp dpt:30510
```

Inside the `KUBE-SVC-*` chain there will be one entry per each healthy backend Endpoint with random probability to ensure equal traffic distribution:

```
$ ipt KUBE-SVC-LOLE4ISW44XBNF3G
Chain KUBE-SVC-LOLE4ISW44XBNF3G (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-SEP-PJHHG4YJTBHVHUTY  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ statistic mode random probability 0.33333333349
    0     0 KUBE-SEP-4OIMBIYGK4QJUGT7  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ statistic mode random probability 0.50000000000
    1    60 KUBE-SEP-R53NX34J3PCIETEY  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */
```

This is where the final Destination NAT translation takes place, each of the above chains translates the original destination IP and NodePort to the address of one of the Endpoints:

```
$ ipt KUBE-SEP-3BXOQLMOWG4452TJ
Chain KUBE-SEP-PJHHG4YJTBHVHUTY (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       10.244.1.6           0.0.0.0/0            /* default/web */
    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ tcp to:10.244.1.6:80
$ ipt KUBE-SEP-4OIMBIYGK4QJUGT7
Chain KUBE-SEP-4OIMBIYGK4QJUGT7 (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       10.244.2.7           0.0.0.0/0            /* default/web */
    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ tcp to:10.244.2.7:80
$ ipt KUBE-SEP-R53NX34J3PCIETEY
Chain KUBE-SEP-R53NX34J3PCIETEY (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       10.244.2.8           0.0.0.0/0            /* default/web */
    1    60 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ tcp to:10.244.2.8:80
```    

You may have noticed the presence of `KUBE-MARK-MASQ` in the above chains, this rule exists to account for a corner case of Pod talking to its own Service via a [ClusterIP](/services/clusterip/dataplane/iptables/#use-case-1-pod-to-service-communication) (i.e. Pod itself is a part of the Service it's trying to talk to) and the random distribution selecting itself as the destination. In this case, both source and destination IPs will be the same and this rule exists to ensure that the packets get SNAT'ed to prevent packets from being dropped.

---

### IPVS Implementation

IPVS data plane still relies on IPTables for a [number of corner cases](https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/#iptables-ipset-in-ipvs-proxier), which is why we can see a similar rule, matching all `LOCAL` packets and redirecting them to the `KUBE-NODE-PORT` chain:

```
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
```

However, its is implemented is slightly different and makes use of [IP sets](https://ipset.netfilter.org/), reducing the time complexity of a lookup from O(N) to O(1):

```
$ ipt KUBE-NODE-PORT
Chain KUBE-NODE-PORT (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Kubernetes nodeport TCP port for masquerade purpose */ match-set KUBE-NODE-PORT-TCP dst
```

A set of all configure NodePorts is maintained inside the `KUBE-NODE-PORT-TCP` ipset:

```
$ ips KUBE-NODE-PORT-TCP                                                                                   ▼
Name: KUBE-NODE-PORT-TCP
Type: bitmap:port
Revision: 3
Header: range 0-65535
Size in memory: 8264
References: 1
Number of entries: 1
Members:
30064
```

Assuming we've got `30064` allocated as a NodePort, we can see all interfaces that are listening for incoming packets for this Service:

```
$ ipv | grep 30064
TCP  192.168.224.2:30064 rr
TCP  10.244.1.1:30064 rr
TCP  127.0.0.1:30064 rr
```

The IPVS configuration for each individual listener is the same and contains a set of backend Endpoint addresses with the default round-robin traffic distribution:

```
$ ipv
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  192.168.224.2:30064 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.7:80                Masq    1      0          0
  -> 10.244.2.8:80                Masq    1      0          0
  ````

----

### Cilium eBPF Implementation

The way Cilium deals with NodePort Services is quite complicated so we'll try to focus only on the relevant "happy" code paths ignoring corner cases and interaction with other services, like firewalling or encryption. 

At boot time, Cilium attaches a pair of eBPF programs to a set of Node's external network interfaces (they can be picked automatically or defined in configuration). In our case, we only have one external interface `eth0` and we can see eBPF programs attached to it using bpftool:

```
$ cilium bpftool net | grep eth0
eth0(19) clsact/ingress bpf_netdev_eth0.o:[from-netdev] id 6098
eth0(19) clsact/egress bpf_netdev_eth0.o:[to-netdev] id 6104
```

Let's focus on the ingress part and walk through the [source code](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L943) of the `from-netdev` program. During the first few steps, the [SKB data structure](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/include/linux/bpf.h#L4183) gets first passed to the `handle_netdev` function ([source](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L916)) and on to the `do_netdev` function ([source](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L815)) which handles [IPSec](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L821), [security identity](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L840) and [logging](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L843) operations. At the end, a [tail call](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L884) transfers the control over to the `handle_ipv4` function ([source](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_host.c#L449)) which is where most of the forwarding decisions take place.

One of the first things that happen inside `handle_ipv4` is the following check which confirms that Cilium was [configured](https://github.com/cilium/cilium/blob/b673586b820ae7b44301d088a10367b0b8eeeb05/install/kubernetes/cilium/values.yaml#L1021) to process NodePort Services and the packet is coming from an external source, in which case the SKB context is passed over to the `nodeport_lb4` function:

```c
#ifdef ENABLE_NODEPORT
	if (!from_host) {
		if (ctx_get_xfer(ctx) != XFER_PKT_NO_SVC &&
		    !bpf_skip_nodeport(ctx)) {
			ret = nodeport_lb4(ctx, secctx);
			if (ret < 0)
				return ret;
		}
		/* Verifier workaround: modified ctx access. */
		if (!revalidate_data(ctx, &data, &data_end, &ip4))
			return DROP_INVALID;
	}
#endif /* ENABLE_NODEPORT */
```

The `nodeport_lb4` function ([source](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/nodeport.h#L1742)) deals with anything related to NodePort Service load-balancing and address translation. Initially, it builds a 4-tuple which will be used for internal connection tracking and attempts to extract a Service map lookup key:

```c
tuple.nexthdr = ip4->protocol;
tuple.daddr = ip4->daddr;
tuple.saddr = ip4->saddr;

l4_off = l3_off + ipv4_hdrlen(ip4);

ret = lb4_extract_key(ctx, ip4, l4_off, &key, &csum_off, CT_EGRESS);
```

The key gets build with the destination [IP](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1050) and [L4 port](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1054) of an ingress packet. Similar to Cilium's [ClusterIP implementation](/services/clusterip/dataplane/ebpf/#a-day-in-the-life-of-a-packet) (and for the same reasons) the lookup is performed in two stages and the first one is only used to determine the total number of backend Endpoints (`svc->count`):


```c
struct lb4_service *lb4_lookup_service(struct lb4_key *key,
				       const bool scope_switch)
{
	struct lb4_service *svc;

	key->scope = LB_LOOKUP_SCOPE_EXT;
	key->backend_slot = 0;
	svc = map_lookup_elem(&LB4_SERVICES_MAP_V2, key);
	if (svc) {
		if (!scope_switch || !lb4_svc_is_local_scope(svc))
			return svc->count ? svc : NULL;
		key->scope = LB_LOOKUP_SCOPE_INT;
		svc = map_lookup_elem(&LB4_SERVICES_MAP_V2, key);
		if (svc && svc->count)
			return svc;
	}

	return NULL;
}
```

For example, this is how a map lookup for a packet going to `172.18.0.6:30171` would look like:
```bash
cilium bpftool map lookup pinned /sys/fs/bpf/tc/globals/cilium_lb4_services_v2 key 0xac 0x12 0x00 0x06 0x75 0xdb 0x00 0x00 0x00 0x00 0x00 0x00
key: ac 12 00 06 75 db 00 00  00 00 00 00  value: 00 00 00 00 03 00 00 08  42 00 00 00
```

The returned [result](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/common.h#L767) sets the count to the number of healthy backend Endpoints (`0x03` in our case) which is then used in the second lookup inside the `lb4_local` function ([source](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1336)):


```c
if (backend_id == 0) {
	/* No CT entry has been found, so select a svc endpoint */
	backend_id = lb4_select_backend_id(ctx, key, tuple, svc);
	backend = lb4_lookup_backend(ctx, backend_id);
	if (backend == NULL)
		goto drop_no_service;
}

```

This time, the exact `backend_id` is determined either [randomly](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1151) of using a [MAGLEV](https://cilium.io/blog/2020/11/10/cilium-19#maglev) [hash lookup](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1171). The value of `backend_id` is used to look up the destination IP and port of the target Endpoint:

```
static __always_inline struct lb4_backend *__lb4_lookup_backend(__u16 backend_id)
{
	return map_lookup_elem(&LB4_BACKEND_MAP, &backend_id);
}
```

With this information in hand, the control flow is [passed](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1482) from the `lb4_local` to the `lb4_xlate` function:

```c
	return lb_skip_l4_dnat() ? CTX_ACT_OK :
	       lb4_xlate(ctx, &new_daddr, &new_saddr, &saddr,
			 tuple->nexthdr, l3_off, l4_off, csum_off, key,
			 backend, has_l4_header, skip_l3_xlate);
```


As its name suggests, `lb4_xlate` ([source](https://github.com/cilium/cilium/blob/b4af6c1ac755ea0565e3f70b12b0bf9cb2cc4156/bpf/lib/lb.h#L1183)) performs L4 [header re-writes](https://github.com/cilium/cilium/blob/b4af6c1ac755ea0565e3f70b12b0bf9cb2cc4156/bpf/lib/lb.h#L1229) and [checksum updates](https://github.com/cilium/cilium/blob/b4af6c1ac755ea0565e3f70b12b0bf9cb2cc4156/bpf/lib/lb.h#L1213) to finish the translation of the original packet which now has the destination IP and port of one of the backend Endpoints:

```
if (likely(backend->port) && key->dport != backend->port &&
    (nexthdr == IPPROTO_TCP || nexthdr == IPPROTO_UDP) &&
    has_l4_header) {
	__be16 tmp = backend->port;

	/* Port offsets for UDP and TCP are the same */
	ret = l4_modify_port(ctx, l4_off, TCP_DPORT_OFF, csum_off,
			     tmp, key->dport);
	if (IS_ERR(ret))
		return ret;
}

return CTX_ACT_OK;
```

At this point, with the packet fully translated and connection tracking entries updated, the control flow returns to the `handle_ipv4` [function](https://github.com/cilium/cilium/blob/b4af6c1ac755ea0565e3f70b12b0bf9cb2cc4156/bpf/bpf_host.c#L495) where a [Cilium endpoint](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/common.h#L238) is [looked up](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/eps.h#L37) and its details are used to call the `bpf_redirect_neigh` eBPF [helper function](https://github.com/libbpf/libbpf/blob/1778e0b1bdd924c27e8e877bcd22520c0590862b/include/uapi/linux/bpf.h#L4492) to redirect the packet straight to the target interface, similar to how it was described in the [Cilium CNI chapter](/cni/cilium/#5-ebpf-packet-processing-on-ingress-node):


```c
	/* Lookup IPv4 address in list of local endpoints and host IPs */
	ep = lookup_ip4_endpoint(ip4);
	if (ep) {
		/* Let through packets to the node-ip so they are processed by
		 * the local ip stack.
		 */
		if (ep->flags & ENDPOINT_F_HOST)
			return CTX_ACT_OK;

		return ipv4_local_delivery(ctx, ETH_HLEN, secctx, ip4, ep,
					   METRIC_INGRESS, from_host);
	}
```

