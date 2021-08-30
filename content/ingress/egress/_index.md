---
title: "Egress"
date: 2020-09-13T17:33:04+01:00
weight: 70
summary: "Egress traffic engineering"
---

Egress is a very loosely defined term in the Kubernetes ecosystem. Unlike its counterpart, egress traffic is not controlled by any standard Kubernetes API or a proxy. This is because most of the egress traffic is not revenue-generating and, in fact, can be completely optional. For situations when a Pod needs to communicate with an external service, it would make sense to do this via an API gateway rather than allow direct communication and most of the service meshes provide this functionality, e.g. Consul's [Terminating Gateway](https://www.consul.io/docs/connect/gateways/terminating-gateway) or OSM's [Egress Policy API](https://docs.openservicemesh.io/docs/guides/traffic_management/egress/). However, we still need a way to allow for Pod-initiated external communication, without a service mesh integration, and this is how it can be done:

1. By default, traffic leaving a Pod will follow the default route out of a Node and will get masqueraded (SNAT'ed) to the address of the outgoing interface. This is normally provisioned by a CNI plugin option, e.g. the `ipMasq` option of the [bridge plugin](https://www.cni.dev/plugins/current/main/bridge/#network-configuration-reference), or by a separate agent, e.g. [`ip-masq-agent`](https://github.com/kubernetes-sigs/ip-masq-agent).
2. For security reasons, some or all egress traffic can get redirected to an "egress gateway" deployed on a subset of Kubernetes Nodes. The operation, UX and redirection mechanism are implementation-specific and can work at an application level, e.g. Istio's [Egress Gateway](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/), or at an IP level, e.g. Cilium's [Egress Gateway](https://docs.cilium.io/en/stable/gettingstarted/egress-gateway/).

In both cases, the end result is that a packet leaves one of the Kubernetes Nodes, SNAT'ed to the address of the egress interface. The rest of the forwarding is done by the underlying network.

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=g6ESgU9g5ULUhjZ5bZWG&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


## Lab

The way direct local egress works has already been described in the CNI part of this guide. Refer to the respective sections of the [kindnet](http://localhost:1313/cni/kindnet/#snat-functionality), [flannel](http://localhost:1313/cni/flannel/#snat-functionality), [weave](http://localhost:1313/cni/weave/#snat-functionality), [calico](http://localhost:1313/cni/calico/#snat-functionality) and [cilium](http://localhost:1313/cni/cilium/#snat-functionality) chapters for more details.

For this lab exercise, we’ll focus on how Cilium implements the Egress Gateway functionality via a custom resource called `CiliumEgressNATPolicy`.

### Preparation


Assuming that the lab environment is already [set up](/lab/), Cilium can be enabled with the following command:

```bash
make cilium 
```

Wait for the Cilium daemonset to initialize:

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

Deploy an "external" [echo server](https://github.com/mpolden/echoip) that will be used to check the source IP of the incoming request:

```
make egress-prep
```

By default, we should have a `net-tshoot` daemonset running on all Nodes:

```
$ kubectl -n default get pod -owide
NAME               READY   STATUS    RESTARTS   AGE     IP           NODE                      NOMINATED NODE   READINESS GATES
net-tshoot-5ngbc   1/1     Running   0          4h53m   10.0.0.174   k8s-guide-control-plane   <none>           <none>
net-tshoot-gcj27   1/1     Running   0          4h53m   10.0.2.86    k8s-guide-worker2         <none>           <none>
net-tshoot-pcgf8   1/1     Running   0          4h53m   10.0.1.42    k8s-guide-worker          <none>           <none>
```

We can use these Pods to verify the (default) local egress behaviour by sending an HTTP GET to the echo server:

```
$ kubectl -n default get pod -l name=net-tshoot -o name | xargs -I{} kubectl -n default exec {} -- wget -q -O - echo
172.18.0.5
172.18.0.3
172.18.0.6
```

These are the same IPs that are assigned to our lab Nodes:

```
$ make node-ip-1 && make node-ip-2 && make node-ip-3
control-plane:172.18.0.3
worker:172.18.0.5
worker2:172.18.0.6
```

Finally, we can enable the `CiliumEgressNATPolicy`  that will NAT all traffic from Pods in the default namespace to the IP of the control-plane node:

```
make egress-setup
```

This can be verified by re-running the earlier command:

```
$ kubectl -n default get pod -l name=net-tshoot -o name | xargs -I{} kubectl -n default exec {} -- wget -q -O - echo
172.18.0.3
172.18.0.3
172.18.0.3
```

We can see that now all three requests appear to have come from the same Node.


### Walkthrough

Now let's briefly walk through how Cilium implements the above NAT policy. The Cilium CNI chapter [explains](http://localhost:1313/cni/cilium/#2-nodes-ebpf-programs) how certain eBPF programs get attached to different interfaces. In our case, we're looking at a program attached to all `lxc` interfaces and processing incoming packets a Pod called [`from-container`](https://github.com/cilium/cilium/blob/18513dbc1379a2d439163876e50dd68b009169fd/bpf/bpf_lxc.c#L970). Inside this program, a packet goes through several functions before it eventually gets to the `handle_ipv4_from_lxc` function ([source](https://github.com/cilium/cilium/blob/18513dbc1379a2d439163876e50dd68b009169fd/bpf/bpf_lxc.c#L510)) which does the bulk of work in IPv4 packet processing. The relevant part of this function is this one:

 ```c
 #ifdef ENABLE_EGRESS_GATEWAY
	{
		struct egress_info *info;
		struct endpoint_key key = {};

		info = lookup_ip4_egress_endpoint(ip4->saddr, ip4->daddr);
		if (!info)
			goto skip_egress_gateway;

		/* Encap and redirect the packet to egress gateway node through a tunnel.
		 * Even if the tunnel endpoint is on the same host, follow the same data
		 * path to be consistent. In future, it can be optimized by directly
		 * direct to external interface.
		 */
		ret = encap_and_redirect_lxc(ctx, info->tunnel_endpoint, encrypt_key,
					     &key, SECLABEL, monitor);
		if (ret == IPSEC_ENDPOINT)
			goto encrypt_to_stack;
		else
			return ret;
	}
skip_egress_gateway:
#endif
```

Here, our packet's source and destination IPs get passed to the `lookup_ip4_egress_endpoint` which performs a lookup in the following map:


```
$ NODE=k8s-guide-worker2
$ cilium=$(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
$ kubectl -n cilium exec -it $cilium -- bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_egress_v4
key: 30 00 00 00 0a 00 00 1f  ac 12 00 00  value: ac 12 00 03 ac 12 00 03
key: 30 00 00 00 0a 00 01 d1  ac 12 00 00  value: ac 12 00 03 ac 12 00 03
key: 30 00 00 00 0a 00 02 0e  ac 12 00 00  value: ac 12 00 03 ac 12 00 03
Found 3 elements
```

The above can be translated as the following:

* Match all packets with source IP `10.0.0.174`, `10.0.2.86` or `10.0.1.42` (all Pods in the default namespace) and destination prefix of `172.18.0.0/16`
* Return the value with egress IP of `172.18.0.3` and tunnel endpoint of `172.18.0.3`.

The returned value is used in the `encap_and_redirect_lxc` function call that encapsulates the packet and forwards it to the Node with IP `172.18.0.3`.

On the egress Node, our packet gets processed by the `from-overlay` function ([source](https://github.com/cilium/cilium/blob/18513dbc1379a2d439163876e50dd68b009169fd/bpf/bpf_overlay.c#L289)), and eventually falls through to the local network stack. The local network stack has the default route pointing out the `eth0` interface, which is where our packet gets forwarded next.

At this point, Cilium applies its configured IP masquerade [policy](https://docs.cilium.io/en/v1.9/concepts/networking/masquerading/) using either IPTables or eBPF translation. The eBPF masquerading is implemented as a part of the `to-netdev` ([source](https://github.com/cilium/cilium/blob/18513dbc1379a2d439163876e50dd68b009169fd/bpf/bpf_host.c#L1010)) program attached to the egress direction of the `eth0` interface. 

```c
#if defined(ENABLE_NODEPORT) && \
	(!defined(ENABLE_DSR) || \
	 (defined(ENABLE_DSR) && defined(ENABLE_DSR_HYBRID)) || \
	 defined(ENABLE_MASQUERADE) || \
	 defined(ENABLE_EGRESS_GATEWAY))
	if ((ctx->mark & MARK_MAGIC_SNAT_DONE) != MARK_MAGIC_SNAT_DONE) {
		ret = handle_nat_fwd(ctx);
		if (IS_ERR(ret))
			return send_drop_notify_error(ctx, 0, ret,
						      CTX_ACT_DROP,
						      METRIC_EGRESS);
	}
#endif
```

From `handle_nat_fwd` function ([source](https://github.com/cilium/cilium/blob/18513dbc1379a2d439163876e50dd68b009169fd/bpf/lib/nodeport.h#L2179)) the processing goes through `tail_handle_nat_fwd_ipv4`, `nodeport_nat_ipv4_fwd` and eventually gets to the `snat_v4_process` function ([source](https://github.com/cilium/cilium/blob/18513dbc1379a2d439163876e50dd68b009169fd/bpf/lib/nat.h#L504)) where all of the NAT translations take place. All new packets will fall through to the `snat_v4_new_mapping` function where a new random source port will be allocated to the packet:

```c
#pragma unroll
	for (retries = 0; retries < SNAT_COLLISION_RETRIES; retries++) {
		if (!snat_v4_lookup(&rtuple)) {
			ostate->common.created = bpf_mono_now();
			rstate.common.created = ostate->common.created;

			ret = snat_v4_update(otuple, ostate, &rtuple, &rstate);
			if (!ret)
				break;
		}

		port = __snat_clamp_port_range(target->min_port,
					       target->max_port,
					       retries ? port + 1 :
					       get_prandom_u32());
		rtuple.dport = ostate->to_sport = bpf_htons(port);
	}
```

Finally, once the new source port has been selected and the connection tracking entry for subsequent packets set up, the packet gets its headers updated and before being sent out of the egress interface:

```c
	return dir == NAT_DIR_EGRESS ?
	       snat_v4_rewrite_egress(ctx, &tuple, state, off, ipv4_has_l4_header(ip4)) :
	       snat_v4_rewrite_ingress(ctx, &tuple, state, off);
```