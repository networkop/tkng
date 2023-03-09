---
title: "eBPF"
date: 2020-09-13T17:33:04+01:00
weight: 40
---

eBPF has emerged as a new alternative to IPTables and IPVS mechanisms implemented by `kube-proxy` with the promise to reduce CPU utilization and latency, improve throughput and increase scale. 
As of today, there are two implementations of Kubernetes Service's data plane in eBPF -- one from [Calico](https://docs.projectcalico.org/maintenance/ebpf/enabling-bpf) and one from [Cilium](https://docs.cilium.io/en/latest/gettingstarted/kubeproxy-free/).
Since Cilium was the first product to introduce `kube-proxy`-less data plane, we'll focus on its implementation in this chapter. However it should be noted that there is no "standard" way to implement the Services data plane in eBPF, so Calico's approach may be different. 

Cilium's `kube-proxy` replacement is called [Host-Reachable Services](https://docs.cilium.io/en/v1.10/gettingstarted/host-services/#host-services) and it literally makes any ClusterIP reachable from the host (Kubernetes Node). It does that by attaching eBPF programs to cgroup hooks, intercepting all system calls and transparently modifying the ones that are destined to ClusterIP VIPs. Since Cilium attaches them to the root cgroup, it affects all sockets of all processes on the host. As of today, Cilium's implementation supports the following syscalls, which cover most of the use-cases but [depend](https://docs.cilium.io/en/latest/gettingstarted/kubeproxy-free/#limitations) on the underlying Linux kernel version:

```
$ bpftool cgroup tree /run/cilium/cgroupv2/
CgroupPath
ID       AttachType      AttachFlags     Name
/run/cilium/cgroupv2
2005     connect4
1970     connect6
2007     post_bind4
2002     post_bind6
2008     sendmsg4
2003     sendmsg6
2009     recvmsg4
2004     recvmsg6
2006     getpeername4
1991     getpeername6
```

This is what typically happens when a client, e.g. a process inside a Pod, tries to communicate with a remote ClusterIP:

* Client's network application invokes one of the syscalls.
* eBPF program attached to this syscall's hook is executed.
* The input to this eBPF program contains a number of socket parameters like destination IP and port number.
* These input details are compared to existing ClusterIP Services and if no match is found, control flow is returned to the Linux kernel.
* In case one of the existing Services did match, the eBPF program selects one of the backend Endpoints and "redirects" the syscall to it by modifying its destination address, before passing it back to the Linux kernel.
* Subsequent data is exchanged over the opened socket by calling `read()` and `write()` without any involvement from the eBPF program.

It's very important to understand that in this case, the destination NAT translation happens at the syscall level, before the packet is even built by the kernel. What this means is that the first packet to leave the client network namespace already has the right destination IP and port number and can be forwarded by a separate data plane managed by a CNI plugin (in most cases though the entire data plane is managed by the same plugin).

{{% notice info %}}
A somewhat similar idea has previously been implemented by a product called Appswitch. See [1](https://hci.stanford.edu/cstr/reports/2017-01.pdf), [2](https://appswitch.readthedocs.io/en/latest/index.html), [3](https://networkop.co.uk/post/2018-05-29-appswitch-sdn/) for more details.
{{% /notice %}}

Below is a high-level diagram of what happens when a Pod on Node `worker-2` tries to communicate with a ClusterIP `10.96.32.28:80`. See [section below](/services/clusterip/dataplane/ebpf/#a-day-in-the-life-of-a-packet) for a detailed code walkthrough.

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=oxqjjDhMhjtZh66px_17&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


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

In order to have a working ClusterIP to test against, create a deployment with 3 nginx Pods and examine the assigned ClusterIP and IPs of the backend Pods:

```
make deployment && make scale-up && make cluster-ip
$ kubectl get svc web
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.32.28     <none>        80/TCP    5s
$ kubectl get ep web
NAME   ENDPOINTS                                 AGE
web    10.0.0.234:80,10.0.0.27:80,10.0.2.76:80   11m
```

Now let's see what happens when a client tries to communicate with this Service.

## A day in the life of a Packet

First, let's take a look at the first few packets of a client session. Keep a close eye on the destination IP of the captured packets:
```
$ NODE=k8s-guide-worker2 make tshoot
bash-5.1# tcpdump -enni any -q &
bash-5.1# tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on any, link-type LINUX_SLL (Linux cooked v1), capture size 262144 bytes

bash-5.1# curl -s 10.96.32.28 | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
20:11:29.780374 eth0  Out ifindex 24 aa:24:9c:63:2e:7d 10.0.2.202.45676 > 10.0.0.27.80: tcp 0
20:11:29.781996 eth0  In  ifindex 24 2a:89:e2:43:42:6e 10.0.0.27.80 > 10.0.2.202.45676: tcp 0
20:11:29.782014 eth0  Out ifindex 24 aa:24:9c:63:2e:7d 10.0.2.202.45676 > 10.0.0.27.80: tcp 0
20:11:29.782297 eth0  Out ifindex 24 aa:24:9c:63:2e:7d 10.0.2.202.45676 > 10.0.0.27.80: tcp 75
```

The first TCP packet sent at `20:11:29.780374` already contains the destination IP of one of the backend Pods. This kind of behaviour can very easily [enhance](https://cilium.io/blog/2018/08/07/istio-10-cilium) but also [trip up](https://github.com/linkerd/linkerd2/issues/5932#issuecomment-811747872) applications relying on [traffic interception](https://docs.openservicemesh.io/docs/tasks/traffic_management/iptables_redirection/).

Now let's take a close look at the "happy path" of the eBPF program responsible for this. The above `curl` command would try to connect to an IPv4 address and would invoke the [`connect()`](https://man7.org/linux/man-pages/man2/connect.2.html) syscall, to which the `connect4` eBPF program is attached ([source](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_sock.c#L446)).

{{< highlight c "linenos=false,hl_lines=7 " >}}
__section("connect4")
int sock4_connect(struct bpf_sock_addr *ctx)
{
	if (sock_is_health_check(ctx))
		return __sock4_health_fwd(ctx);

	__sock4_xlate_fwd(ctx, ctx, false);
	return SYS_PROCEED;
}
{{< / highlight >}}


Most of the processing is done inside the [`__sock4_xlate_fwd`](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_sock.c#L328) function; we'll break it down into multiple parts for simplicity and omit some of the less important bits that cover special use cases like `sessionAffinity` and `externalTrafficPolicy`. Note that regardless of what happens in the above function, the returned value is always `SYS_PROCEED`, which returns the control flow back to the kernel.

The first thing that happens inside this function is the Services map lookup based on the destination IP and port:

{{< highlight c "linenos=false,hl_lines=8-9 13 " >}}
static __always_inline int __sock4_xlate_fwd(struct bpf_sock_addr *ctx,
					     struct bpf_sock_addr *ctx_full,
					     const bool udp_only)
{
	struct lb4_backend *backend;
	struct lb4_service *svc;
	struct lb4_key key = {
		.address	= ctx->user_ip4,
		.dport		= ctx_dst_port(ctx),
	}, orig_key = key;
	struct lb4_service *backend_slot;

	svc = lb4_lookup_service(&key, true);
	if (!svc)
		svc = sock4_wildcard_lookup_full(&key, in_hostns);
	if (!svc)
		return -ENXIO;
{{< / highlight >}}

Kubernetes Services can have an arbitrary number of Endpoints, depending on the number of matching Pods, however eBPF maps have [fixed size](https://docs.cilium.io/en/latest/concepts/ebpf/maps/#ebpf-maps), so storing variable-size values is not possible. In order to overcome that, the lookup process is broken into two steps:

* The first lookup is done just with the destination IP and port and the returned value tells how many Endpoints are currently associated with the Service.
* The second lookup is done with the same destination IP and port _plus_ an additional field called `backend_slot` which corresponds to one of the backend Endpoints.

During the first lookup `backend_slot` is set to 0. The returned value contains [a number of fields](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/common.h#L767) but the most important one at this stage is `count` -- the total number of Endpoints for this Service. 

{{< highlight c "linenos=false,hl_lines=8-9 15 " >}}
static __always_inline
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
{{< / highlight >}}

Let's look inside the eBPF map and see what entries match that last two octets of our ClusterIP `10.96.32.28`:

{{< highlight bash "linenos=false,hl_lines=5 " >}}
$ NODE=k8s-guide-worker2
$ cilium=$(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
$ kubectl -n cilium exec -it $cilium -- bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_lb4_services_v2 | grep "20 1c"
key: 0a 60 20 1c 00 50 03 00  00 00 00 00  value: 0b 00 00 00 00 00 00 07  00 00 00 00
key: 0a 60 20 1c 00 50 00 00  00 00 00 00  value: 00 00 00 00 03 00 00 07  00 00 00 00
key: 0a 60 20 1c 00 50 01 00  00 00 00 00  value: 09 00 00 00 00 00 00 07  00 00 00 00
key: 0a 60 20 1c 00 50 02 00  00 00 00 00  value: 0a 00 00 00 00 00 00 07  00 00 00 00
{{< / highlight >}}

If the `backend_slot` is set to 0, the key would only contain the IP and port of the Service, so that second line would match the first lookup and the [returned value](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/common.h#L767) can be interpreted as:

* `backend_id = 0`
* `count = 3`

Now the eBPF program knows that the total number of Endpoints is 3 but it still hasn't picked one yet. The control returns to the `__sock4_xlate_fwd` function where the `count` information is used to update the lookup `key.backend_slot`:

{{< highlight c "linenos=false,hl_lines=4 " >}}
	if (backend_id == 0) {
		backend_from_affinity = false;

		key.backend_slot = (sock_select_slot(ctx_full) % svc->count) + 1;
		backend_slot = __lb4_lookup_backend_slot(&key);
		if (!backend_slot) {
			update_metrics(0, METRIC_EGRESS, REASON_LB_NO_BACKEND_SLOT);
			return -ENOENT;
		}

		backend_id = backend_slot->backend_id;
		backend = __lb4_lookup_backend(backend_id);
	}
{{< / highlight >}}

This is where the backend selection takes place either randomly (for TCP) or based on the [socket cookie](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/bpf_sock.c#L101) (for UDP):

{{< highlight c "linenos=false,hl_lines=5 " >}}
static __always_inline __maybe_unused
__u64 sock_select_slot(struct bpf_sock_addr *ctx)
{
	return ctx->protocol == IPPROTO_TCP ?
	       get_prandom_u32() : sock_local_cookie(ctx);
}
{{< / highlight >}}

The [second lookup](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/lb.h#L1095) is performed in the same map, but now the key contains the previously selected `backend_slot`:

{{< highlight c "linenos=false,hl_lines=4 " >}}
static __always_inline
struct lb4_service *__lb4_lookup_backend_slot(struct lb4_key *key)
{
	return map_lookup_elem(&LB4_SERVICES_MAP_V2, key);
}
{{< / highlight >}}

The lookup result will contain either one of the values from rows 1, 3 or 4 and will have a non-zero value for `backend_id` -- `0b 00`, `09 00` or `0a 00`:

{{< highlight c "linenos=false,hl_lines=2 4 5 " >}}
$ kubectl -n cilium exec -it $cilium -- bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_lb4_services_v2 | grep "20 1c"
key: 0a 60 20 1c 00 50 03 00  00 00 00 00  value: 0b 00 00 00 00 00 00 07  00 00 00 00
key: 0a 60 20 1c 00 50 00 00  00 00 00 00  value: 00 00 00 00 03 00 00 07  00 00 00 00
key: 0a 60 20 1c 00 50 01 00  00 00 00 00  value: 09 00 00 00 00 00 00 07  00 00 00 00
key: 0a 60 20 1c 00 50 02 00  00 00 00 00  value: 0a 00 00 00 00 00 00 07  00 00 00 00
{{< / highlight >}}

Using this value we can now extract IP and port details of the backend Pod:


```c
static __always_inline struct lb4_backend *__lb4_lookup_backend(__u16 backend_id)
{
	return map_lookup_elem(&LB4_BACKEND_MAP, &backend_id);
}
```

Let's assume that the `backend_id` that got chosen before was `0a 00` and look up the details in the eBPF map:

```
$ kubectl -n cilium exec -it $cilium -- bpftool map lookup pinned /sys/fs/bpf/tc/globals/cilium_lb4_backends key 0x0a 0x00
key: 0a 00  value: 0a 00 00 1b 00 50 00 00
```

The [returned value](https://github.com/cilium/cilium/blob/4145278ccc6e90739aa100c9ea8990a0f561ca95/bpf/lib/common.h#L782) can be interpreted as:

* **Address** = `10.0.0.27`
* **Port** = `80`

Finally, the eBPF program does the socket-based NAT translation, i.e. re-writing of the destination IP and port with the values returned from the eariler lookup:

{{< highlight c "linenos=false,hl_lines=1 2 " >}}

	ctx->user_ip4 = backend->address;
	ctx_set_port(ctx, backend->port);

	return 0;
{{< / highlight >}}


At this stage, the eBPF program returns and execution flow continues inside the Linux kernel networking stack all the way until the packet is built and sent out of the egress interface. The packet continues along the path built by the [CNI portion](/cni/cilium) of Cilium.

This is all that's required to replace the biggest part of `kube-proxy`'s functionality. One big difference with `kube-proxy` implementation is that NAT translation only happens for traffic originating from one of the Kubernetes nodes, e.g. [externally originated](https://docs.projectcalico.org/networking/advertise-service-ips) ClusterIP traffic is not currently supported. This is why we haven't considered the **Any-to-Service** communication use case, as we did for IPTables and IPVS.


{{% notice info %}}
Due to a [known issue](https://docs.cilium.io/en/v1.9/gettingstarted/kind/#unable-to-contact-k8s-api-server) with kind, make sure to run `make cilium-unhook` when you're finished with this Cilium lab to detach eBPF programs from the host cgroup.
{{% /notice %}}


### Additional reading

[Cilium socket LB presentation](https://docs.google.com/presentation/d/1w2zlpGWV7JUhHYd37El_AUZzyUNSvDfktrF5MJ5G8Bs/edit#slide=id.g746fc02b5b_2_0)

[Kubernetes Without kube-proxy](https://docs.cilium.io/en/latest/gettingstarted/kubeproxy-free/)

